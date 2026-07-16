//+------------------------------------------------------------------+
//|                                                  Float-Chart.mq5 |
//|  Floating mini chart of another timeframe (and optionally        |
//|  another symbol) on top of your current chart. Hardened:         |
//|  self-healing, collision-proof, click-proof, light.              |
//+------------------------------------------------------------------+
#property copyright   "Custom indicator"
#property version     "2.83"
#property description "Float-Chart: floating mini chart of another timeframe on your chart"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- inputs
input string          InpSymbol           = "";                // Symbol (empty = current symbol)
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M5;         // Timeframe to display
input int             InpScale            = 2;                 // Scale 0-5 (enforced over the template)

input ENUM_BASE_CORNER InpCorner          = CORNER_LEFT_LOWER; // Chart corner to anchor to
input int             InpXOffset          = 3;                 // X offset (pixels from corner)(275)
input int             InpYOffset          = 150;               // Y offset (pixels from corner)
input int             InpWidth            = 270;               // Width (pixels)
input int             InpHeight           = 150;               // Height (pixels)
input ENUM_CHART_MODE InpChartMode        = CHART_CANDLES;     // Chart mode (candles/bars/line)
input bool            InpShowDateScale    = false;             // Show date (time) scale
input bool            InpShowPriceScale   = false;             // Show price scale
input bool            InpShowTicker       = false;             // Show symbol/TF text inside the panel
input bool            InpShowTradeLevels  = false;             // Show entry/SL/TP lines inside the panel
input bool            InpChartShift       = false;             // Gap between newest candle and the right edge
input int             InpShiftSizePercent = 0;                 // Shift size % 10-50 (0 = same as main chart)
// Template applied INSIDE the panel (empty = plain candles). Indicators +
// cosmetics show; EAs never run. Scale/ticker/levels/shift above ALWAYS
// win over the template (applied after it, re-verified every second).
input string          InpTemplate         = "";                // Template name (e.g. "float")

//--- Global Variables
string g_symbol;   // resolved symbol
string g_objName;  // unique object name for THIS instance

// The float chart object hosts a real inner chart with its own ID, but
// that ID is often still 0 for a moment right after ObjectCreate -- so
// mode/grid settings applied immediately would be SILENTLY skipped
// (that was a real bug in v1.00). This flag makes the settings retry
// until the inner chart is actually ready.
bool g_innerConfigured = false;

// --- Debug/error logging state -------------------------------------------
// Each flag makes sure a given failure is only printed to the Experts log
// ONCE while it persists, instead of spamming it every tick/second. The
// flag resets as soon as the underlying condition clears, so a genuinely
// new failure later on still gets reported.
bool g_loggedCreateFail = false;
bool g_loggedInnerFail  = false;

// Template application state: applied ONCE per (re)created panel (never
// re-applied while the panel lives -- no fight loop with the config).
// Reset whenever the panel is recreated, so a self-healed panel gets
// its template back automatically.
bool g_templateApplied = false;
bool g_loggedTplFail   = false; // log a template failure only ONCE
bool g_pendingAdoptCheck = false; // adopted panel awaiting the "template really inside?" test

//==================================================================
// WARM-UP GRACE
//==================================================================
// Right after attach/reinit (input change, template reload), the
// chart/object subsystem can transiently refuse creation or not yet
// expose the inner chart ID -- that's a normal transient, not a
// failure: the next second retries and succeeds. During a short grace
// window after init this is retried silently; only if it persists
// past the window is it logged.
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
}

//==================================================================
// STAGGERED STEADY-STATE VERIFICATION (v2.82)
//==================================================================
// Once the panel is fully configured, the "snap settings back" check
// costs 4-6 SYNCHRONOUS queries into the inner chart. With several
// floats on one chart those bursts all landed in the same instant
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

   // FIX (v2.81): resolve the adoption check BEFORE deciding to load
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
      Print("Float-Chart: could not apply template '", InpTemplate,
            "' (error ", GetLastError(),
            "). If it exists, copy the .tpl into the MQL5 folder ",
            "(File -> Open Data Folder -> MQL5).");
      g_loggedTplFail = true;
   }
}

//+------------------------------------------------------------------+
//| Configure the chart INSIDE the panel (mode, grid, ticker, trade  |
//| levels). Retries until the inner chart ID is ready; with a       |
//| template set, waits until the template step is confirmed done    |
//| first (template load is async). Once configured, verifies every  |
//| second and snaps the properties back if anything flipped them.   |
//+------------------------------------------------------------------+
// Resolve the shift-size target: explicit 10-50, or mirror the main chart.
double TargetShiftSize(void)
{
   if(InpShiftSizePercent >= 10 && InpShiftSizePercent <= 50)
      return (double)InpShiftSizePercent;
   return ChartGetDouble(0, CHART_SHIFT_SIZE); // main chart's gap
}

//==================================================================
// SYMBOL/PERIOD ENFORCEMENT (v2.83)
//==================================================================
// The two properties that define WHAT the panel shows used to be
// one-shot writes in CreatePanel -- issued immediately after
// ObjectCreate, i.e. exactly inside the "inner chart ID not ready"
// race window where property writes are SILENTLY dropped (the very
// bug documented at the top of this file, fixed for every setting
// EXCEPT these two). And with a template set, the async .tpl load
// can override the inner chart's symbol/period AFTER our write.
// Either way the panel showed the wrong timeframe FOREVER, because
// symbol/period were the only settings never verified.
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
         Print("Float-Chart: inner chart ID isn't ready yet after warm-up. Will keep retrying..");
         g_loggedInnerFail = true;
      }
      return;
   }

   // One-time adoption check (shared helper -- see ResolveAdoptCheck).
   ResolveAdoptCheck(innerId);

   if(g_innerConfigured)
   {
      // Throttle (v2.82): steady-state verification only runs on this
      // instance's phase -- every VERIFY_PERIOD_S seconds instead of
      // every second. A flipped setting now snaps back within ~3s
      // instead of ~1s; in exchange, multiple floats stop bursting
      // synchronous queries into their inner charts in the same instant.
      if(g_timerCount % VERIFY_PERIOD_S != g_verifyPhase)
         return;

      // v2.83: symbol/period verified FIRST -- see the enforcement
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

      // v2.83: symbol/period enforced on the FIRST config too -- this
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
//| Create the float chart object with all properties                |
//+------------------------------------------------------------------+
bool CreatePanel(void)
{
   ResetLastError();
   if(!ObjectCreate(0, g_objName, OBJ_CHART, 0, 0, 0))
   {
      // Transient refusals happen during re-init -- retried every second.
      // Only a persistent failure past the grace window is reported, once.
      if(!StillWarmingUp() && !g_loggedCreateFail)
      {
         Print("Float-Chart ERROR: failed to create chart object, error code ", GetLastError(), ". Will keep retrying..");
         g_loggedCreateFail = true;
      }
      return false;
   }

   g_loggedCreateFail = false; // recovered -- future failures get reported again

   // position & size
   ObjectSetInteger(0, g_objName, OBJPROP_CORNER,    InpCorner);
   ObjectSetInteger(0, g_objName, OBJPROP_XDISTANCE, InpXOffset);
   ObjectSetInteger(0, g_objName, OBJPROP_YDISTANCE, InpYOffset);
   ObjectSetInteger(0, g_objName, OBJPROP_XSIZE,     InpWidth);
   ObjectSetInteger(0, g_objName, OBJPROP_YSIZE,     InpHeight);

   // what to display
   ObjectSetString (0, g_objName, OBJPROP_SYMBOL,      g_symbol);
   ObjectSetInteger(0, g_objName, OBJPROP_PERIOD,      InpTimeframe);
   ObjectSetInteger(0, g_objName, OBJPROP_CHART_SCALE, InpScale);
   ObjectSetInteger(0, g_objName, OBJPROP_DATE_SCALE,  InpShowDateScale);
   ObjectSetInteger(0, g_objName, OBJPROP_PRICE_SCALE, InpShowPriceScale);

   // Click-proof and invisible in the objects list -- a stray click on a
   // scalping chart must never grab and drag the panel (v1.00 had
   // SELECTABLE=true, a real hazard). Consistent with the rest of the suite.
   ObjectSetInteger(0, g_objName, OBJPROP_BACK,       false);
   ObjectSetInteger(0, g_objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_objName, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, g_objName, OBJPROP_HIDDEN,     true);

   // Fresh panel -> template (re)applied first, then the config -- in
   // that order; see ConfigureInnerChart.
   g_templateApplied = false;
   g_innerConfigured = false;
   ApplyTemplate();
   ConfigureInnerChart();

   ChartRedraw(0);
   return true;
}

//+------------------------------------------------------------------+
//| Make sure the panel exists and is fully configured.              |
//| Called lazily from timer / ticks -- creation no longer depends   |
//| on OnInit timing (the v1.00 "gone after input change" problem),  |
//| and a deleted panel is recreated automatically within a second.  |
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
   if(ObjectFind(0, g_objName) < 0)
      CreatePanel();
}

void EnsurePanel(void)
{
   // Missing (fresh attach, input change, "delete all objects", template
   // reload...) -> recreate. This is the self-healing.
   if(ObjectFind(0, g_objName) < 0)
   {
      CreatePanel();
      return;
   }

   // Panel exists: keep the template/config staircase moving until both
   // land, then the config runs its cheap per-second verification.
   ApplyTemplate();
   ConfigureInnerChart();
}

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
//--- if symbol input is empty, use the symbol of the chart we're attached to
   g_symbol = (InpSymbol == "" ? _Symbol : InpSymbol);

//--- Identity by CONFIGURATION, not live market: symbol -> "CHART" in
//--- follow mode (empty InpSymbol); corner+offsets distinguish floats on
//--- the same chart. Name never changes across symbol OR timeframe
//--- switches -> no orphans, no stale cleanup, no same-TF fight.
   string symTok = (InpSymbol == "" ? "CHART" : InpSymbol);
   string tf     = StringSubstr(EnumToString(InpTimeframe), 7);
   g_objName = StringFormat("FloatChart_%s_%s_c%d_x%d_y%d",
                            symTok, tf, (int)InpCorner, InpXOffset, InpYOffset);

//--- verification phase from the (unique) object name: different floats
//--- get different phases with no coordination (see VERIFY_PERIOD_S)
   g_verifyPhase = 0;
   for(int i = 0; i < StringLen(g_objName); i++)
      g_verifyPhase += (int)StringGetCharacter(g_objName, i);
   g_verifyPhase %= VERIFY_PERIOD_S;
   g_timerCount = 0;

//--- Adopt-or-create: OnDeinit deliberately leaves the panel alive on a
//--- TF switch, so if our object already exists, ADOPT it -- inner
//--- chart, loaded template and all. The switch then costs the panel
//--- literally nothing: no rebuild, no template reload, no blink.
   bool adopted = (ObjectFind(0, g_objName) >= 0);

   g_innerConfigured  = false;
   g_loggedCreateFail = false;
   g_loggedInnerFail  = false;
   // Adoption keeps the template ONLY if the survivor really has it. A
   // terminal restart restores the panel SHELL but NOT its inner
   // indicators (MT5 never persists inner-chart contents), so a naked
   // survivor must reload. Confirmed in ConfigureInnerChart via
   // ChartIndicatorsTotal -- start pessimistic here.
   g_templateApplied   = false;
   g_pendingAdoptCheck = adopted;
   g_loggedTplFail     = false;

//--- start the warm-up grace clock (see StillWarmingUp above)
   g_initTick = GetTickCount();

//--- 1-second timer: creation backstop + self-heal that works even with
//--- zero ticks (market closed, dead hours). The work per call is one
//--- ObjectFind -- negligible.
   EventSetTimer(1);

//--- try to show the panel immediately; if the object subsystem isn't
//--- ready during (re)init, the timer/first tick picks it up in a second
   EnsurePanel();

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
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
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
   EnsurePanel();
}
//+------------------------------------------------------------------+