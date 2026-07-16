//+------------------------------------------------------------------+
//|                                                    Sub-Chart.mq5 |
//|     Subwindow panel that shows another timeframe as a live chart |
//|     Hardened: self-healing, collision-proof, click-proof, light  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.94"
#property indicator_separate_window
#property indicator_plots               0
#property indicator_buffers             0
#property indicator_minimum             0.0
#property indicator_maximum             0.0

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input string          InpSymbol           = "";            // Symbol (empty = current chart symbol)
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M30;    // Timeframe
input ENUM_CHART_MODE InpChartMode        = CHART_CANDLES; // Chart mode (candles/bars/line)
input int             InpScale            = 2;             // Scale 0-5 (enforced over the template)
input bool            InpShowDates        = false;         // Show date scale
input bool            InpShowPrices       = false;         // Show price scale
input bool            InpShowTicker       = false;         // Show symbol/TF text inside the panel
input bool            InpShowTradeLevels  = true;          // Show entry/SL/TP lines inside the panel
input bool            InpChartShift       = true;          // Gap between newest candle and the right edge
input int             InpShiftSizePercent = 0;             // Shift size % 10-50 (0 = same as main chart)
// Template applied INSIDE the panel (empty = plain candles). Indicators +
// cosmetics show; EAs never run. Scale/ticker/levels/shift above ALWAYS
// win over the template (applied after it, re-verified every second).
input string          InpTemplate         = "";            // Template name (e.g. "sub")

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
string g_symbol;   // resolved symbol
string g_objName;     // unique object name for THIS instance

// Cached geometry so resize events only touch the object when the
// subwindow size actually changed (CHART_CHANGE fires on every scroll
// and zoom -- without the cache, each of those would rewrite 4 object
// properties for nothing).
int  g_lastW   = -1;
int  g_lastH   = -1;
int  g_lastWin = -1;

// Template application state: applied once per (re)created panel.
// Reset whenever the panel is recreated, so a self-healed panel gets
// its template back automatically.
bool g_templateApplied = false;
bool g_loggedTplFail   = false; // log a template failure only ONCE
bool g_pendingAdoptCheck = false; // adopted panel awaiting the "template really inside?" test

// Inner chart config (mode + grid-off) applied once per (re)created
// panel, retried until the inner chart ID is ready -- and, when a
// template is set, only AFTER the template has been applied, so the
// asynchronous template load can never override these settings.
bool g_innerConfigured = false;

// Log-once for panel creation. The old version used a static flag that
// NEVER reset: one transient refusal at attach burned it forever, so a
// real failure later was never reported. This one resets on recovery.
bool g_loggedCreateFail = false;

// Log-once for a stuck inner-chart ID (twin of Float-Chart): a moment of
// "not ready" right after creation is normal; only reported once if it
// persists past the warm-up grace window, and reset on recovery.
bool g_loggedInnerFail = false;

//==================================================================
// WARM-UP GRACE (suite standard)
//==================================================================
// Right after attach/reinit the chart/object subsystem can transiently
// refuse creation or not yet expose the inner chart ID. Failures inside
// this grace window are retried silently; only a persistent one is
// logged, once.
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
}

//==================================================================
// STAGGERED STEADY-STATE VERIFICATION (v2.92, suite standard)
//==================================================================
// Once the panel is fully configured, the "snap settings back" check
// costs 4-6 SYNCHRONOUS queries into the inner chart. With several
// panels on one chart those bursts all landed in the same instant
// every second and competed with rendering (the heavy-drag feel).
// Now each instance verifies only every VERIFY_PERIOD_S seconds, on
// a phase derived from its own (unique) object name -- instances
// spread out naturally with zero cross-instance coordination. The
// fast paths (creation, template load, first config, self-heal) are
// NOT throttled -- they stay on the 1s cadence.
#define VERIFY_PERIOD_S 3
int g_verifyPhase = 0; // this instance's slot: 0..VERIFY_PERIOD_S-1
int g_timerCount  = 0; // timer ticks (seconds) since init

//+------------------------------------------------------------------+
//| One-time adoption check: is the adopted (possibly restart-       |
//| restored) inner chart actually carrying its template, or is it a |
//| naked shell? A restart restores the panel object but NOT its     |
//| inner indicators. MUST run before any template decision -- see   |
//| the call at the top of ApplyTemplate.                            |
//+------------------------------------------------------------------+
void ResolveAdoptCheck(const long innerId)
{
   if(!g_pendingAdoptCheck || innerId <= 0)
      return;
   g_pendingAdoptCheck = false;
   if(InpTemplate == "" || ChartIndicatorsTotal(innerId, 0) > 0)
      g_templateApplied = true;  // real content present -> trust it (TF-switch case)
   // else naked survivor (restart) -> leave false so ApplyTemplate reloads once
}

//+------------------------------------------------------------------+
//| Configure the chart INSIDE the panel (mode, grid). Retries until |
//| the inner chart ID is ready; with a template set, waits until    |
//| the template has been applied first (template load is async).    |
//+------------------------------------------------------------------+
// Resolve the shift-size target: explicit 10-50, or mirror the main chart.
double TargetShiftSize(void)
{
   if(InpShiftSizePercent >= 10 && InpShiftSizePercent <= 50)
      return (double)InpShiftSizePercent;
   return ChartGetDouble(0, CHART_SHIFT_SIZE); // main chart's gap
}

//==================================================================
// SYMBOL/PERIOD ENFORCEMENT (v2.94, suite standard)
//==================================================================
// The two properties that define WHAT the panel shows used to be
// one-shot writes in CreatePanel -- issued immediately after
// ObjectCreate, i.e. exactly inside the "inner chart ID not ready"
// race window where property writes are SILENTLY dropped (the same
// race already fixed for every setting EXCEPT these two). And with
// a template set, the async .tpl load can override the inner
// chart's symbol/period AFTER our write. Either way the panel
// showed the wrong timeframe FOREVER, because symbol/period were
// the only settings never verified.
// Now they are verified like everything else, and snapped back on
// mismatch. Enforcement is MISMATCH-ONLY: ChartSetSymbolPeriod
// triggers a full inner-chart rebuild, so it must never run
// unconditionally or the panel would rebuild every verify cycle.
ENUM_TIMEFRAMES TargetPeriod(void)
{
   // PERIOD_CURRENT input -> follow the main chart's period
   return (InpTimeframe == PERIOD_CURRENT)
          ? (ENUM_TIMEFRAMES)_Period
          : InpTimeframe;
}

bool SymbolPeriodOK(const long innerId)
{
   return (ChartSymbol(innerId) == g_symbol &&
           ChartPeriod(innerId) == TargetPeriod());
}

void EnforceSymbolPeriod(const long innerId)
{
   // Both channels, same pattern as the scale fix: the inner chart
   // directly (the reliable one) AND the host object properties.
   ChartSetSymbolPeriod(innerId, g_symbol, TargetPeriod());
   ObjectSetString (0, g_objName, OBJPROP_SYMBOL, g_symbol);
   ObjectSetInteger(0, g_objName, OBJPROP_PERIOD, TargetPeriod());
   ChartRedraw(innerId);
}

void ConfigureInnerChart(void)
{
   long innerId = ObjectGetInteger(0, g_objName, OBJPROP_CHART_ID);
   if(innerId <= 0)
   {
      // Inner chart not ready yet -- normal right after creation.
      // Retried every second by the timer; only report if it stays
      // stuck past the grace window (would mean the config never applies).
      if(!g_innerConfigured && !StillWarmingUp() && !g_loggedInnerFail)
      {
         Print("Sub-Chart: inner chart ID isn't ready yet after warm-up. Will keep retrying..");
         g_loggedInnerFail = true;
      }
      return;
   }

   // One-time adoption check (shared helper -- see ResolveAdoptCheck).
   ResolveAdoptCheck(innerId);

   if(g_innerConfigured)
   {
      // Throttle (v2.92): steady-state verification only runs on this
      // instance's phase -- every VERIFY_PERIOD_S seconds instead of
      // every second. A flipped setting now snaps back within ~3s
      // instead of ~1s; in exchange, multiple panels stop bursting
      // synchronous queries into their inner charts in the same instant.
      if(g_timerCount % VERIFY_PERIOD_S != g_verifyPhase)
         return;

      // v2.94: symbol/period verified FIRST -- see the enforcement
      // block above TargetPeriod. Mismatch -> switch and let the
      // rebuild settle; the rest is re-verified on the next phase.
      if(!SymbolPeriodOK(innerId))
      {
         EnforceSymbolPeriod(innerId);
         return;
      }

      // Verified enforcement: if anything flipped these properties after
      // the first apply (a template landing late from its async load, a
      // manual F8 click, a terminal quirk), snap them back. Cost when
      // everything matches: a handful of property reads. This is what
      // turns "inputs should win" into "inputs verified winning".
      bool tickerNow = (bool)ChartGetInteger(innerId, CHART_SHOW_TICKER);
      bool levelsNow = (bool)ChartGetInteger(innerId, CHART_SHOW_TRADE_LEVELS);
      bool shiftNow  = (bool)ChartGetInteger(innerId, CHART_SHIFT);
      long scaleNow  = ChartGetInteger(innerId, CHART_SCALE);
      bool sizeOK    = true;
      if(InpChartShift)
        {
         double sizeNow = ChartGetDouble(innerId, CHART_SHIFT_SIZE);
         sizeOK = (MathAbs(sizeNow - TargetShiftSize()) < 0.5);
        }
      if(tickerNow == InpShowTicker && levelsNow == InpShowTradeLevels &&
         shiftNow == InpChartShift && sizeOK && scaleNow == InpScale)
         return;
      // mismatch -> fall through and re-apply everything
   }
   else
   {
      // First apply: template first. Applying config before an async
      // template load finishes would just get overridden by it, so wait
      // until the template step is confirmed done (or no template set).
      if(InpTemplate != "" && !g_templateApplied)
         return;

      // v2.94: symbol/period enforced on the FIRST config too -- this
      // is the no-template failure path: the creation-time write raced
      // the inner chart coming up and was silently dropped. Mismatch ->
      // switch now, apply the rest of the config on the NEXT pass, so
      // it lands on the rebuilt chart instead of being wiped by it.
      if(!SymbolPeriodOK(innerId))
      {
         EnforceSymbolPeriod(innerId);
         return;
      }
   }

   ChartSetInteger(innerId, CHART_MODE, InpChartMode);
   ChartSetInteger(innerId, CHART_SHOW_GRID, false);
   ChartSetInteger(innerId, CHART_SHOW_TICKER, InpShowTicker);
   ChartSetInteger(innerId, CHART_SHOW_TRADE_LEVELS, InpShowTradeLevels);
   ChartSetInteger(innerId, CHART_SHIFT, InpChartShift);
   if(InpChartShift)
      ChartSetDouble(innerId, CHART_SHIFT_SIZE, TargetShiftSize());

   // Scale enforced HERE, after the template. Setting it only at object
   // creation (the old way) lost the race against the async template
   // load, so on first attach the template's saved zoom showed instead
   // of the input. Both channels set: the inner chart property AND the
   // host object property, so whichever governs the display obeys.
   ChartSetInteger(innerId, CHART_SCALE, InpScale);
   ObjectSetInteger(0, g_objName, OBJPROP_CHART_SCALE, InpScale);

   ChartRedraw(innerId);

   g_innerConfigured = true;
   g_loggedInnerFail = false; // recovered -- a future new failure gets reported again
}

//+------------------------------------------------------------------+
//| Apply the user's template to the chart INSIDE the panel          |
//+------------------------------------------------------------------+
void ApplyTemplate(void)
{
   if(g_templateApplied || InpTemplate == "")
      return;

   // The panel object hosts a real chart with its own ID -- that's what
   // the template must be applied to (NOT the main chart).
   long innerId = ObjectGetInteger(0, g_objName, OBJPROP_CHART_ID);
   if(innerId <= 0)
      return; // inner chart not ready yet -- retried by timer/ticks

   // FIX (v2.91): resolve the adoption check BEFORE deciding to load
   // the .tpl. It used to live only in ConfigureInnerChart, which runs
   // AFTER this function -- so on every timeframe switch the adopted
   // panel's template was needlessly RE-APPLIED (full inner-chart
   // rebuild + tpl reload in the middle of the TF-switch reinit storm
   // = the visible lag). An adopted panel that already carries its
   // indicators is now recognized here and the reload is skipped.
   ResolveAdoptCheck(innerId);
   if(g_templateApplied)
      return; // adopted survivor already has its template -- nothing to do

   // Accept the name with or without the .tpl extension.
   string tpl = InpTemplate;
   if(StringFind(tpl, ".tpl") < 0)
      tpl += ".tpl";

   // Search order quirk of ChartApplyTemplate: a plain name is looked up
   // near the indicator's own folder, a leading backslash means the MQL5
   // data folder root. Try both before declaring failure.
   ResetLastError();
   bool ok = ChartApplyTemplate(innerId, tpl);
   if(!ok)
      ok = ChartApplyTemplate(innerId, "\\" + tpl);

   if(ok)
   {
      g_templateApplied = true;
      g_loggedTplFail   = false;
      ChartRedraw(innerId);
   }
   else if(!g_loggedTplFail)
   {
      Print("Sub-Chart: could not apply template '", InpTemplate,
            "' (error ", GetLastError(),
            "). If it exists, copy the .tpl into the MQL5 folder ",
            "(File -> Open Data Folder -> MQL5).");
      g_loggedTplFail = true;
   }
}

//+------------------------------------------------------------------+
//| Create the panel object with all properties                      |
//+------------------------------------------------------------------+
bool CreatePanel(const int win, const int w, const int h)
{
   ResetLastError();
   if(!ObjectCreate(0, g_objName, OBJ_CHART, win, 0, 0))
   {
      // Transient refusals happen during re-init -- retried every second.
      // Only a persistent failure past the grace window is reported, once,
      // and the flag resets on recovery (the old static flag never did).
      if(!StillWarmingUp() && !g_loggedCreateFail)
      {
         Print("Sub-Chart ERROR: failed to create panel object, error code ", GetLastError(), ". Will keep retrying..");
         g_loggedCreateFail = true;
      }
      return false;
   }

   ObjectSetString (0, g_objName, OBJPROP_SYMBOL,      g_symbol);
   ObjectSetInteger(0, g_objName, OBJPROP_PERIOD,      InpTimeframe);
   ObjectSetInteger(0, g_objName, OBJPROP_CHART_SCALE, InpScale);
   ObjectSetInteger(0, g_objName, OBJPROP_DATE_SCALE,  InpShowDates);
   ObjectSetInteger(0, g_objName, OBJPROP_PRICE_SCALE, InpShowPrices);

   ObjectSetInteger(0, g_objName, OBJPROP_XDISTANCE, 0);
   ObjectSetInteger(0, g_objName, OBJPROP_YDISTANCE, 0);
   ObjectSetInteger(0, g_objName, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, g_objName, OBJPROP_YSIZE,     h);

   // Click-proof and invisible in the objects list -- a stray click on a
   // scalping chart must never grab and drag the panel.
   // added BACK/SELECTED for parity.
   ObjectSetInteger(0, g_objName, OBJPROP_BACK,       false);
   ObjectSetInteger(0, g_objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_objName, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, g_objName, OBJPROP_HIDDEN,     true);

   g_lastW   = w;
   g_lastH   = h;
   g_lastWin = win;

   g_loggedCreateFail = false; // recovered -- future failures get reported again

   // Fresh panel -> its inner chart needs the template (re)applied and
   // the mode/grid config re-done (in that order; see ConfigureInnerChart).
   g_templateApplied = false;
   g_innerConfigured = false;
   ApplyTemplate();
   ConfigureInnerChart();

   ChartRedraw(0);
   return true;
}

//+------------------------------------------------------------------+
//| Make sure the panel exists and fills the subwindow.              |
//| Called lazily from timer / ticks / chart events -- this is what  |
//| fixes the "gone after input change" problem: creation no longer  |
//| depends on OnInit timing, and a deleted panel is recreated       |
//| automatically within a second.                                   |
//+------------------------------------------------------------------+
// TICK path: existence check ONLY (one cheap host-side ObjectFind).
// The full EnsurePanel below runs verification/config/template -- ~6
// synchronous property queries INTO THE INNER CHART's message queue.
// Running that on every tick (the old way) flooded the inner chart
// with hundreds of blocking queries per second on fast markets, so it
// spent its time answering us instead of drawing -- the panel visibly
// lagged behind price. The 1s timer covers everything within a second;
// ticks only need to catch a deleted panel instantly.
void EnsureExists(void)
{
   if(ObjectFind(0, g_objName) >= 0)
      return; // normal tick cost: this one lookup

   // Panel missing (rare): gather the geometry CreatePanel needs.
   int win = ChartWindowFind();
   if(win < 0)
      return;
   int w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, win);
   if(w <= 0 || h <= 0)
      return;

   CreatePanel(win, w, h);
}

// doConfig=true  -> full pass: self-heal + template/config + geometry
// doConfig=false -> event pass: self-heal + geometry ONLY (v2.92 fix).
// CHARTEVENT_CHART_CHANGE fires on every scroll/zoom and continuously
// during a drag-resize; running the template/config verification (4-6
// synchronous queries into the inner chart) on each of those events
// burst-flooded the inner chart during interaction -- the same pattern
// the tick-path fix killed, re-entering through the event door. The
// geometry cache below only skipped the ObjectSet calls, not the
// verification above them. Verification now lives on the timer ONLY.
void EnsurePanel(const bool doConfig)
{
   int win = ChartWindowFind();
   if(win < 0)
      return;              // window not resolvable yet -- retry next call

   int w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, win);
   if(w <= 0 || h <= 0)
      return;              // chart not laid out yet -- retry next call

   // Missing (fresh attach, input change, "delete all objects", template
   // reload...) -> recreate. This is the self-healing.
   if(ObjectFind(0, g_objName) < 0)
   {
      CreatePanel(win, w, h);
      return;
   }

   // Panel exists but the template and/or the mode+grid config couldn't
   // be applied yet (inner chart ID not ready at creation time, async
   // template load) -> keep trying until both land. Timer path only --
   // see the doConfig note above.
   if(doConfig)
   {
      ApplyTemplate();
      ConfigureInnerChart();
   }

   // Exists -> only touch it if the geometry actually changed.
   if(w != g_lastW || h != g_lastH || win != g_lastWin)
   {
      ObjectSetInteger(0, g_objName, OBJPROP_XDISTANCE, 0);
      ObjectSetInteger(0, g_objName, OBJPROP_YDISTANCE, 0);
      ObjectSetInteger(0, g_objName, OBJPROP_XSIZE,     w);
      ObjectSetInteger(0, g_objName, OBJPROP_YSIZE,     h);

      g_lastW   = w;
      g_lastH   = h;
      g_lastWin = win;

      ChartRedraw(0);
   }
}

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit(void)
{
//--- if symbol input is empty, use the symbol of the chart we're attached to
   g_symbol = (InpSymbol == "" ? _Symbol : InpSymbol);

   string tf = StringSubstr(EnumToString(InpTimeframe), 7); // "M30", "H1", ...

//--- Identity by CONFIGURATION, not live market: symbol -> "CHART" in
//--- follow mode (empty InpSymbol), so the name never changes across
//--- symbol OR timeframe switches -> no orphans, no stale cleanup, no
//--- same-TF fight. (A subwindow hosts one panel; no offset token needed.)
   string symTok = (InpSymbol == "" ? "CHART" : InpSymbol);
   g_objName = "SubChart_" + symTok + "_" + tf;

//--- verification phase from the (unique) object name: different panels
//--- get different phases with no coordination (see VERIFY_PERIOD_S)
   g_verifyPhase = 0;
   for(int i = 0; i < StringLen(g_objName); i++)
      g_verifyPhase += (int)StringGetCharacter(g_objName, i);
   g_verifyPhase %= VERIFY_PERIOD_S;
   g_timerCount = 0;

//--- subwindow name, e.g. "XAUUSDc M30"
   IndicatorSetString(INDICATOR_SHORTNAME, g_symbol + " " + tf);

//--- Adopt-or-create: OnDeinit deliberately leaves the panel alive on a
//--- TF switch, so if our object already exists, ADOPT it -- inner
//--- chart, loaded template and all. The switch then costs the panel
//--- literally nothing: no rebuild, no template reload, no blink.
   bool adopted = (ObjectFind(0, g_objName) >= 0);

   g_lastW   = -1;
   g_lastH   = -1;
   g_lastWin = -1;
   // Adoption keeps the template ONLY if the survivor really has it. A
   // terminal restart restores the panel SHELL but NOT its inner
   // indicators (MT5 never persists inner-chart contents), so a naked
   // survivor must reload. Confirmed in ConfigureInnerChart via
   // ChartIndicatorsTotal -- start pessimistic here.
   g_templateApplied = false;
   g_pendingAdoptCheck = adopted;
   g_loggedTplFail   = false;
   g_innerConfigured = false;
   g_loggedInnerFail = false;
   g_loggedCreateFail = false;

//--- start the warm-up grace clock (see StillWarmingUp above)
   g_initTick = GetTickCount();

//--- 1-second timer: creation backstop + self-heal that works even with
//--- zero ticks (market closed, dead hours). The work per call is one
//--- ObjectFind + two ChartGetInteger -- negligible.
   EventSetTimer(1);

//--- try to show the panel immediately; if the window isn't ready yet
//--- during (re)init, the timer/first tick picks it up within a second
   EnsurePanel(true);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   // Chart objects PERSIST across timeframe switches -- deleting the
   // panel here (the old way) forced a full rebuild + template reload
   // in the middle of the TF-switch reinit storm (the visible delay).
   // On REASON_CHARTCHANGE the panel is left alive for the next
   // instance to ADOPT. Real removal, input change and chart close
   // still clean up properly.
   if(reason != REASON_CHARTCHANGE)
      ObjectDelete(0, g_objName);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const int begin,
                const double &price[])
{
   EnsureExists(); // ticks: existence check only -- verification/config live on the 1s timer
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Timer: creation backstop + self-heal without needing a tick      |
//+------------------------------------------------------------------+
void OnTimer(void)
{
   g_timerCount++; // drives the staggered verification phase
   EnsurePanel(true);
}

//+------------------------------------------------------------------+
//| Keep the sub-chart filling the subwindow on any resize           |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
      EnsurePanel(false); // geometry only -- config/verify live on the timer
}
//+------------------------------------------------------------------+