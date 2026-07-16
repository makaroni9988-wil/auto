//+------------------------------------------------------------------+
//|                                              TL-N-Breakout.mq5   |
//|  Trendline break + structure break (N pattern) confluence        |
//|                                                                  |
//|  Replaces lines.mq5. Full 4-stage validated trendline engine     |
//|  plus the N-pattern state machine:                               |
//|                                                                  |
//|   Stage 1  Pivots: confirmed fractal swings, with an ATR-based   |
//|            liquidity-wick filter so freak spikes don't become    |
//|            line anchors (bad anchors = wrong slope = every       |
//|            touch/break after it is measured against a lie).      |
//|   Stage 2  Direction filter: resistance lines must descend,      |
//|            support lines must ascend. No random connections.     |
//|   Stage 3  Validation + touch scoring: slope by BAR INDEX (time  |
//|            slope is distorted by session gaps), ATR tolerance,   |
//|            candidate dies if any CLOSE crosses it between its    |
//|            anchors, most-touches candidate wins.                 |
//|   Stage 4  The N: after a CLOSE breaks the line (event 1,        |
//|            momentum), wait for a CLOSE beyond the last swing     |
//|            (event 2, structure) WITHOUT a close beyond the       |
//|            final extreme first (that would kill the N). Only     |
//|            event 1 + event 2 in sequence = confirmed signal.     |
//|                                                                  |
//|  Visual language (deliberately anti-front-run):                  |
//|   - solid colored line          = active validated trendline     |
//|   - dotted line + small dot     = TL broken. WARNING, NOT ENTRY. |
//|   - dashed horizontal level     = the structure level to beat    |
//|   - big arrow                   = confirmed N breakout = entry   |
//|                                                                  |
//|  Engine: closed bars only, new-bar gated, no repaint of printed  |
//|  arrows, warm-up safe, log-once, no journal noise in normal use. |
//|                                                                  |
//|  PANEL-ONLY BUILD (renders with indicator buffers): chart objects|
//|  are never displayed inside an OBJ_CHART float/sub panel, so this|
//|  build draws with buffer plots instead and shows correctly there.|
//|  The chart-object path has been removed entirely -- use the plain|
//|  lines-N.mq5 on a normal chart. Same engine, same alerts.        |
//|  Not available here (buffer limits): tooltips, dotted style at   |
//|  width > 1 (printed arrows/dots persist as write-once buffers).  |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   8

// Panel plots. Trendlines flip solid/dot per scan; levels/arrows/dots
#property indicator_type1 DRAW_LINE    // resistance trendline  (buffer 0)
#property indicator_type2 DRAW_LINE    // support trendline     (buffer 1)
#property indicator_type3 DRAW_LINE    // armed level, bull N   (buffer 2)
#property indicator_type4 DRAW_LINE    // armed level, bear N   (buffer 3)
#property indicator_type5 DRAW_ARROW   // confirmed BUY         (buffer 4)
#property indicator_type6 DRAW_ARROW   // confirmed SELL        (buffer 5)
#property indicator_type7 DRAW_ARROW   // TL-break dot, res     (buffer 6)
#property indicator_type8 DRAW_ARROW   // TL-break dot, sup     (buffer 7)

//--- pivots
input int    InpPivotBars         = 3;     // bars each side to confirm a swing
input int    InpLookbackBars      = 200;   // scan window (closed bars)
input int    InpMaxPivotsPerSide  = 10;    // newest swings considered for line pairs

//--- line validation
input int    InpATRPeriod         = 14;    // ATR period (tolerance + wick filter)
input double InpTouchTolATR       = 0.25;  // touch tolerance = this x ATR
input int    InpMinTouches        = 3;     // min touches (anchors count; 3 = one extra proof touch)
input double InpWickFilterATR     = 1.5;   // clamp anchor to candle body if wick exceeds this x ATR (0 = off)

//--- N pattern
input int    InpMaxBarsAfterBreak = 20;    // structure must break within this many bars of the TL break

//--- visuals
input color  InpResColor       = clrRed;         // resistance trendline
input color  InpSupColor       = clrRed;         // support trendline
input int    InpLineWidth      = 1;
input color  InpLevelColor     = clrYellow;      // armed structure level
input color  InpBuyColor       = clrLime;        // confirmed bullish arrow
input color  InpSellColor      = clrRed;         // confirmed bearish arrow
input int    InpArrowSize      = 1;
input bool   InpShowBreakDot   = true;           // small dot where the TL broke
input bool   InpShowArmedLevel = true;           // dashed structure level while the N is armed
input bool   InpShowArrows     = false;          // confirmed BUY/SELL entry arrows
input int    InpMaxSignals     = 10;             // arrows/dots kept per type
// NOTE: these three are PURELY visual. The state machine (TL break ->
// armed -> confirmed) always runs in full, and the alerts have their own
// switches -- hiding a stage's visual never changes what fires or when.

//--- alerts
input bool   InpAlertOnConfirm = false;    // popup alert on confirmed N breakout
input bool   InpAlertOnTLBreak = false;    // popup alert on trendline break (early warning)
input bool   InpPushOnConfirm  = false;    // push notification on confirmed breakout

//--- refresh
input int    InpRefreshSeconds = 30;       // Force refresh interval in seconds (0 = only on new bars)

//--- internal ---------------------------------------------------------
// Kept only as a code marker (so this panel-only build is easy to tell
// apart from the object build, lines-N.mq5) and to clean any stray objects
// a previous version may have left. This build creates no objects.
#define PREFIX "TLNI_"

// validated input copies (inputs are read-only)
int    ExtPivotBars, ExtLookback, ExtMaxPivots, ExtATRPeriod, ExtMinTouches, ExtWindow, ExtMaxSignals;
double ExtTouchTolATR, ExtWickFilterATR;

int      g_atrHandle       = INVALID_HANDLE;
datetime g_lastBarTime     = 0;
datetime g_lastForceRefresh = 0;
bool     g_loggedNoData    = false;

//------------------------------------------------------------------
// PANEL-ONLY rendering (indicator buffers)
//------------------------------------------------------------------

double BufLineR[], BufLineS[];     // trendlines (style flips solid/dot per scan)
double BufLvlR[],  BufLvlS[];      // armed structure levels
double BufBuy[],   BufSell[];      // confirmed entry arrows (write-once)
double BufDotR[],  BufDotS[];      // TL-break dots          (write-once)

bool g_panelBuffersInit = false;   // one-time full EMPTY wipe done
int  g_panelClearedTo   = -1;      // marker buffers initialized up to this bar

//------------------------------------------------------------------
// HANDLE WARM-UP GRACE (suite standard)
//------------------------------------------------------------------
// Right after attach/reinit the ATR handle can transiently fail even
// though the data is fine a moment later. Failures inside this grace
// window are retried silently WITHOUT consuming the log-once flag --
// the old version burned the flag during warm-up, so a REAL persistent
// failure later was never reported at all.
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
  {
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
  }

// Alert state survives a timeframe/symbol switch (the program is not
// unloaded on chart change, so globals persist). First scan after a
// fresh attach records the baseline WITHOUT alerting, so attaching to
// a chart never fires a burst of alerts for old historical signals.
bool     g_scannedOnce         = false;
datetime g_lastConfirmAlert[2] = {0, 0};   // [0]=resistance side (bull), [1]=support side (bear)
datetime g_lastBreakAlert[2]   = {0, 0};

struct Pivot
  {
   int    idx;      // local index inside the scan window
   double raw;      // true wick extreme (used for structure levels)
   double anchor;   // line anchor price (wick, or body edge if wick-filtered)
  };

//+------------------------------------------------------------------+
int OnInit()
  {
   ExtPivotBars     = MathMax(1, InpPivotBars);
   ExtLookback      = MathMax(50, InpLookbackBars);
   ExtMaxPivots     = MathMax(3, InpMaxPivotsPerSide);
   ExtATRPeriod     = MathMax(1, InpATRPeriod);
   ExtTouchTolATR   = MathMax(0.0, InpTouchTolATR);
   ExtMinTouches    = MathMax(2, InpMinTouches);
   ExtWickFilterATR = MathMax(0.0, InpWickFilterATR);
   ExtWindow        = MathMax(1, InpMaxBarsAfterBreak);
   ExtMaxSignals    = MathMax(1, InpMaxSignals);

   ResetLastError();
   g_atrHandle = iATR(_Symbol, _Period, ExtATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("TL-N ERROR: failed to create ATR handle, error code ", GetLastError(), ".");
      return(INIT_FAILED);
     }

   // ---- panel buffer setup ----
   SetIndexBuffer(0, BufLineR, INDICATOR_DATA);
   SetIndexBuffer(1, BufLineS, INDICATOR_DATA);
   SetIndexBuffer(2, BufLvlR,  INDICATOR_DATA);
   SetIndexBuffer(3, BufLvlS,  INDICATOR_DATA);
   SetIndexBuffer(4, BufBuy,   INDICATOR_DATA);
   SetIndexBuffer(5, BufSell,  INDICATOR_DATA);
   SetIndexBuffer(6, BufDotR,  INDICATOR_DATA);
   SetIndexBuffer(7, BufDotS,  INDICATOR_DATA);
   ArraySetAsSeries(BufLineR, false); ArraySetAsSeries(BufLineS, false);
   ArraySetAsSeries(BufLvlR,  false); ArraySetAsSeries(BufLvlS,  false);
   ArraySetAsSeries(BufBuy,   false); ArraySetAsSeries(BufSell,  false);
   ArraySetAsSeries(BufDotR,  false); ArraySetAsSeries(BufDotS,  false);

   PanelSetupPlots();
   g_panelBuffersInit = false; // TF switch rebinds buffers: wipe again
   g_panelClearedTo   = -1;

   g_lastBarTime = 0; // force a scan on the first tick
   g_lastForceRefresh = 0;
   g_initTick = GetTickCount(); // start the warm-up grace clock
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
     }
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw(0);
  }

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
   int need = ExtPivotBars * 2 + ExtATRPeriod + 10;
   if(rates_total < need)
      return(rates_total); // quietly wait for more history (normal warm-up)

   // Full recalculation (attach, TF switch, history reload): the terminal
   // has just REALLOCATED the buffers, and new memory is not guaranteed
   // initialized. Without this, the new-bar gate below would see the same
   // bar time and skip the scan, leaving garbage (values at ~0) on the
   // plots until the next bar or force refresh -- and the write-once
   // marker cells behind g_panelClearedTo would never be re-initialized.
   if(prev_calculated <= 0 || prev_calculated > rates_total)
     {
      g_panelBuffersInit = false; // PanelClearCanvas: full EMPTY wipe
      g_panelClearedTo   = -1;
      g_lastBarTime      = 0;     // defeat the bar gate: scan now
     }

   // New-bar gate: everything here is defined on CLOSED bars only, so
   // there is nothing new to compute until a bar closes. Retry is
   // implicit: if a scan fails (data not ready), g_lastBarTime stays
   // unset and the next tick tries again.
   datetime curBar = time[rates_total - 1];

   // 30s force refresh: everything is keyed/idempotent, so re-running the
   // scan simply restores any objects wiped between bars (delete-all,
   // template reload) and keeps things alive over market close. The
   // time-keyed alert baselines make refresh re-scans alert-silent.
   bool forceRefresh = false;
   if(InpRefreshSeconds > 0)
     {
      datetime curTime = TimeCurrent();
      if(curTime - g_lastForceRefresh >= InpRefreshSeconds)
        {
         forceRefresh = true;
         g_lastForceRefresh = curTime;
        }
     }

   if(curBar == g_lastBarTime && !forceRefresh)
      return(rates_total);

   if(Scan(rates_total, time, open, high, low, close))
     {
      g_lastBarTime = curBar;
      g_scannedOnce = true;
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
// One full stateless scan over the lookback window. Recomputing from
// scratch each closed bar keeps the state machine impossible to
// desync; the window is bounded so the cost is trivial (well under a
// millisecond) once per bar. State visuals are wiped and refilled each
// scan; marker buffers are write-once, so printed arrows never move.
//+------------------------------------------------------------------+
bool Scan(const int rates_total,
          const datetime &time[],
          const double &open[],
          const double &high[],
          const double &low[],
          const double &close[])
  {
   int W    = MathMin(ExtLookback, rates_total);
   int base = rates_total - W;      // local i  <->  global base+i
   int last = W - 2;                // newest CLOSED bar, local index

   // ATR, aligned to the same window (plain array + as-series false:
   // element [count-1] is the current bar, same as the window layout)
   double atr[];
   ArraySetAsSeries(atr, false);
   ResetLastError();
   int copied = CopyBuffer(g_atrHandle, 0, 0, W, atr);
   if(copied < W)
     {
      // Suite-standard grace: silent retry during warm-up, and the
      // log-once flag is consumed ONLY when a line is actually printed
      // (the old code burned it silently during warm-up, hiding any
      // real failure that developed later).
      if(!StillWarmingUp() && !g_loggedNoData)
        {
         Print("TL-N: ATR copy incomplete (", copied, "/", W,
               "), error code ", GetLastError(), ". Will keep retrying.");
         g_loggedNoData = true;
        }
      return(false);
     }
   g_loggedNoData = false; // recovered -- a future new failure gets reported again

   // stateless scan == stateless canvas. The state visuals (trendlines,
   // armed levels) are cleared over the window and refilled by ProcessSide.
   // Marker buffers (arrows, dots) are write-once and NOT cleared, so
   // printed history persists.
   PanelClearCanvas(base, rates_total);

   // ---- Stage 1: confirmed pivots, newest ExtMaxPivots per side ----
   Pivot hi[], lo[];
   CollectPivots(base, last, high, low, open, close, atr, hi, lo);

   // ---- Stages 2-4 per side ----
   ProcessSide(true,  base, last, time, high, low, close, atr, hi, lo); // resistance -> bullish N
   ProcessSide(false, base, last, time, high, low, close, atr, hi, lo); // support    -> bearish N

   ChartRedraw(0);
   return(true);
  }

//+------------------------------------------------------------------+
// Confirmed fractal swings. Anchor price is the wick, unless the wick
// sticks out past the candle body by more than ExtWickFilterATR x ATR
// -- a liquidity spike -- in which case the anchor is clamped to the
// body edge, so one stop-hunt candle can't tilt the whole line. The
// RAW wick is kept separately: structure levels (the N's second
// break) still use the true extreme, because a structure break should
// have to clear the real high/low, spike included.
//+------------------------------------------------------------------+
void CollectPivots(const int base, const int last,
                   const double &high[], const double &low[],
                   const double &open[], const double &close[],
                   const double &atr[],
                   Pivot &hi[], Pivot &lo[])
  {
   ArrayFree(hi);
   ArrayFree(lo);

   for(int i = ExtPivotBars; i <= last - ExtPivotBars; i++)
     {
      int g = base + i;

      bool isHigh = true, isLow = true;
      for(int j = 1; j <= ExtPivotBars && (isHigh || isLow); j++)
        {
         if(isHigh && (high[g] <= high[g + j] || high[g] <= high[g - j])) isHigh = false;
         if(isLow  && (low[g]  >= low[g + j]  || low[g]  >= low[g - j]))  isLow  = false;
        }

      if(isHigh)
        {
         Pivot p;
         p.idx = i;
         p.raw = high[g];
         double body = MathMax(open[g], close[g]);
         p.anchor = (ExtWickFilterATR > 0.0 && (p.raw - body) > ExtWickFilterATR * atr[i]) ? body : p.raw;
         int n = ArraySize(hi); ArrayResize(hi, n + 1); hi[n] = p;
        }
      if(isLow)
        {
         Pivot p;
         p.idx = i;
         p.raw = low[g];
         double body = MathMin(open[g], close[g]);
         p.anchor = (ExtWickFilterATR > 0.0 && (body - p.raw) > ExtWickFilterATR * atr[i]) ? body : p.raw;
         int n = ArraySize(lo); ArrayResize(lo, n + 1); lo[n] = p;
        }
     }

   TrimOldest(hi, ExtMaxPivots);
   TrimOldest(lo, ExtMaxPivots);
  }

//+------------------------------------------------------------------+
void TrimOldest(Pivot &arr[], const int keep)
  {
   int n = ArraySize(arr);
   if(n <= keep)
      return;
   int drop = n - keep;
   for(int i = 0; i < keep; i++)
      arr[i] = arr[i + drop];
   ArrayResize(arr, keep);
  }

//+------------------------------------------------------------------+
// Stages 2-4 for one side. isRes=true handles the descending
// resistance line whose break starts a BULLISH N; isRes=false the
// ascending support line whose break starts a BEARISH N.
//+------------------------------------------------------------------+
void ProcessSide(const bool isRes,
                 const int base, const int last,
                 const datetime &time[],
                 const double &high[], const double &low[], const double &close[],
                 const double &atr[],
                 const Pivot &hi[], const Pivot &lo[])
  {
   int    side     = isRes ? 0 : 1;

   // pivots the line is built FROM / the arrays the N reads levels from
   // (const-reference params can't be aliased, so pick explicitly below)

   // ---- candidate search: best valid line on this side ----
   int    bestA = -1, bestB = -1, bestTouches = -1, bestBreak = -1, bestPri = -1;
   double bestSlope = 0.0, bestPA = 0.0;

   int np = isRes ? ArraySize(hi) : ArraySize(lo);
   for(int a = 0; a < np - 1; a++)
     {
      for(int b = a + 1; b < np; b++)
        {
         double pA = isRes ? hi[a].anchor : lo[a].anchor;
         double pB = isRes ? hi[b].anchor : lo[b].anchor;
         int    iA = isRes ? hi[a].idx    : lo[a].idx;
         int    iB = isRes ? hi[b].idx    : lo[b].idx;
         if(iB <= iA)
            continue;

         // Stage 2: direction filter
         if(isRes  && pB >= pA) continue;   // resistance must descend
         if(!isRes && pB <= pA) continue;   // support must ascend

         double slope = (pB - pA) / (double)(iB - iA);

         // Stage 3a: no close may cross the line between its anchors
         bool dead = false;
         for(int i = iA; i <= iB && !dead; i++)
           {
            double lv = pA + slope * (i - iA);
            if(isRes  && close[base + i] > lv) dead = true;
            if(!isRes && close[base + i] < lv) dead = true;
           }
         if(dead)
            continue;

         // break: first close beyond the line after anchor B
         int brk = -1;
         for(int i = iB + 1; i <= last; i++)
           {
            double lv = pA + slope * (i - iA);
            if((isRes && close[base + i] > lv) || (!isRes && close[base + i] < lv))
              { brk = i; break; }
           }

         // Stage 3b: cluster-counted touches up to the break
         int stop = (brk >= 0) ? brk - 1 : last;
         int touches = 0;
         bool prevTouch = false;
         for(int i = iA; i <= stop; i++)
           {
            double lv  = pA + slope * (i - iA);
            double tol = ExtTouchTolATR * atr[i];
            bool touch = isRes ? (high[base + i] >= lv - tol)
                               : (low[base + i]  <= lv + tol);
            if(touch && !prevTouch)
               touches++;
            prevTouch = touch;
           }
         if(touches < ExtMinTouches)
            continue;

         // Relevance + priority. An armed break (waiting for the N to
         // resolve) outranks everything; a recent confirm outranks a
         // plain active line; invalidated or stale lines are dropped
         // so a NEW line can take over.
         int pri;
         if(brk < 0)
            pri = 1;                                   // active, unbroken
         else
           {
            int outcome = NOutcome(isRes, base, last, brk, close, hi, lo);
            if(outcome == 1)                           // confirmed
              {
               int cIdx = NConfirmIndex(isRes, base, last, brk, close, hi, lo);
               if(cIdx >= 0 && last - cIdx <= ExtWindow) pri = 2;
               else continue;                          // old story, expired
              }
            else if(outcome == -1)
               continue;                               // N invalidated: line is history
            else                                       // still armed
              {
               if(last - brk <= ExtWindow) pri = 3;
               else continue;                          // armed too long: expired
              }
           }

         if(pri > bestPri
            || (pri == bestPri && touches > bestTouches)
            || (pri == bestPri && touches == bestTouches && iB > bestB))
           {
            bestPri = pri; bestTouches = touches;
            bestA = iA; bestB = iB; bestSlope = slope; bestPA = pA; bestBreak = brk;
           }
        }
     }

   if(bestA < 0)
      return; // panel canvas was already cleared this scan

   // ---- draw the line ----
   if(bestBreak < 0)
     {
      // active line: solid, extended to the newest bar (buffers cannot
      // pass the data, so it runs to the last bar)
      PanelDrawTrend(isRes, base, bestA, base + last + 1, bestPA, bestSlope, STYLE_SOLID);
      return;
     }

   // broken: dotted, ends exactly at the break bar. WARNING state.
   double lvBrk = bestPA + bestSlope * (bestBreak - bestA);
   datetime tBrk = time[base + bestBreak];
   PanelDrawTrend(isRes, base, bestA, base + bestBreak, bestPA, bestSlope, STYLE_DOT);
   if(InpShowBreakDot)
     {
      // above the line for an up-break, below for a down-break
      double dotPrice = isRes ? lvBrk + 0.15 * atr[bestBreak]
                              : lvBrk - 0.15 * atr[bestBreak];
      if(isRes) BufDotR[base + bestBreak] = dotPrice;
      else      BufDotS[base + bestBreak] = dotPrice;
     }

   // TL-break alert (optional early warning; explicitly NOT the entry)
   if(InpAlertOnTLBreak && bestBreak == last && g_scannedOnce && tBrk != g_lastBreakAlert[side])
     {
      Alert("TL-N ", _Symbol, " ", EnumToString(_Period), ": trendline broken (",
            isRes ? "bullish" : "bearish", " setup arming). NOT the entry - wait for the structure break.");
      g_lastBreakAlert[side] = tBrk;
     }
   else if(bestBreak == last)
      g_lastBreakAlert[side] = tBrk; // baseline without alerting

   // ---- the N ----
   double structLvl, killLvl;
   if(!NLevels(isRes, bestBreak, hi, lo, structLvl, killLvl))
      return; // no reference swings before the break (extremely early history)

   int outcome    = NOutcome(isRes, base, last, bestBreak, close, hi, lo);
   int confirmIdx = (outcome == 1) ? NConfirmIndex(isRes, base, last, bestBreak, close, hi, lo) : -1;

   if(outcome == 0)
     {
      // armed: show the structure level the market has to beat, drawn from
      // the break bar to the newest closed bar (toggle off -> plot is
      // DRAW_NONE from init, canvas already clean)
      if(InpShowArmedLevel)
         for(int g = base + bestBreak; g <= base + last; g++)
           {
            if(isRes) BufLvlR[g] = structLvl;
            else      BufLvlS[g] = structLvl;
           }
      return;
     }

   if(outcome != 1 || confirmIdx < 0)
      return;

   // ---- confirmed N breakout: the actual entry arrow ----
   datetime tC = time[base + confirmIdx];
   double   off = 0.5 * atr[confirmIdx];
   if(InpShowArrows)
     {
      // write-once markers: same glyphs (233/234), same ATR offset; once
      // printed they persist in the buffer
      if(isRes) BufBuy[base + confirmIdx]  = low[base + confirmIdx]  - off;
      else      BufSell[base + confirmIdx] = high[base + confirmIdx] + off;
     }

   if(InpAlertOnConfirm && confirmIdx == last && g_scannedOnce && tC != g_lastConfirmAlert[side])
     {
      string msg = StringFormat("TL-N %s %s: CONFIRMED %s breakout (trendline + structure).",
                                _Symbol, EnumToString(_Period), isRes ? "BULLISH" : "BEARISH");
      Alert(msg);
      if(InpPushOnConfirm)
         SendNotification(msg);
      g_lastConfirmAlert[side] = tC;
     }
   else if(confirmIdx == last)
      g_lastConfirmAlert[side] = tC; // baseline without alerting
  }

//+------------------------------------------------------------------+
// The two reference levels of the N, taken from the last confirmed
// swings BEFORE the trendline break:
//   bullish N (isRes): structure = last swing HIGH (the lower high to
//     beat), kill = last swing LOW (a close below it = new low = no N)
//   bearish N: mirrored.
// RAW wick prices on purpose -- the structure break must clear the
// true extreme, liquidity spike included.
//+------------------------------------------------------------------+
bool NLevels(const bool isRes, const int brk,
             const Pivot &hi[], const Pivot &lo[],
             double &structLvl, double &killLvl)
  {
   int sIdx = -1, kIdx = -1;
   if(isRes)
     {
      for(int i = ArraySize(hi) - 1; i >= 0; i--) if(hi[i].idx < brk) { sIdx = i; break; }
      for(int i = ArraySize(lo) - 1; i >= 0; i--) if(lo[i].idx < brk) { kIdx = i; break; }
      if(sIdx < 0 || kIdx < 0) return false;
      structLvl = hi[sIdx].raw;
      killLvl   = lo[kIdx].raw;
     }
   else
     {
      for(int i = ArraySize(lo) - 1; i >= 0; i--) if(lo[i].idx < brk) { sIdx = i; break; }
      for(int i = ArraySize(hi) - 1; i >= 0; i--) if(hi[i].idx < brk) { kIdx = i; break; }
      if(sIdx < 0 || kIdx < 0) return false;
      structLvl = lo[sIdx].raw;
      killLvl   = hi[kIdx].raw;
     }
   return true;
  }

//+------------------------------------------------------------------+
// N outcome after a trendline break, scanning closed bars in order:
//   +1 confirmed (close beyond the structure level within the window)
//   -1 invalidated (close beyond the kill level first, or window ran out)
//    0 still armed
//+------------------------------------------------------------------+
int NOutcome(const bool isRes, const int base, const int last, const int brk,
             const double &close[], const Pivot &hi[], const Pivot &lo[])
  {
   double structLvl, killLvl;
   if(!NLevels(isRes, brk, hi, lo, structLvl, killLvl))
      return -1;

   int limit = MathMin(last, brk + ExtWindow);
   for(int i = brk + 1; i <= limit; i++)
     {
      double c = close[base + i];
      if(isRes)
        {
         if(c < killLvl)   return -1;
         if(c > structLvl) return +1;
        }
      else
        {
         if(c > killLvl)   return -1;
         if(c < structLvl) return +1;
        }
     }
   if(last > brk + ExtWindow)
      return -1; // window expired without a structure break
   return 0;
  }

//+------------------------------------------------------------------+
int NConfirmIndex(const bool isRes, const int base, const int last, const int brk,
                  const double &close[], const Pivot &hi[], const Pivot &lo[])
  {
   double structLvl, killLvl;
   if(!NLevels(isRes, brk, hi, lo, structLvl, killLvl))
      return -1;

   int limit = MathMin(last, brk + ExtWindow);
   for(int i = brk + 1; i <= limit; i++)
     {
      double c = close[base + i];
      if(isRes)
        {
         if(c < killLvl)   return -1;
         if(c > structLvl) return i;
        }
      else
        {
         if(c > killLvl)   return -1;
         if(c < structLvl) return i;
        }
     }
   return -1;
  }

//------------------------------------------------------------------
// PANEL RENDERING helpers (indicator buffers)
//------------------------------------------------------------------
// PanelSetupPlots: runs once in OnInit. Styles the 8 plots from the
// same inputs as always; the three visual-only toggles disable their
// plots here (the engine never changes).
//+------------------------------------------------------------------+
void PanelSetupPlots()
  {
   for(int p = 0; p < 8; p++)
     {
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      PlotIndexSetInteger(p, PLOT_SHOW_DATA, false);
     }

   // trendlines (style flips per scan; dotted renders only at width 1)
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, InpResColor);
   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, InpLineWidth);
   PlotIndexSetString(0,  PLOT_LABEL, "TL-N resistance");
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, InpSupColor);
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, InpLineWidth);
   PlotIndexSetString(1,  PLOT_LABEL, "TL-N support");

   // armed structure levels
   if(InpShowArmedLevel)
     {
      PlotIndexSetInteger(2, PLOT_LINE_COLOR, InpLevelColor);
      PlotIndexSetInteger(2, PLOT_LINE_STYLE, STYLE_DOT);
      PlotIndexSetInteger(2, PLOT_LINE_WIDTH, 1);
      PlotIndexSetString(2,  PLOT_LABEL, "TL-N armed level (bull)");
      PlotIndexSetInteger(3, PLOT_LINE_COLOR, InpLevelColor);
      PlotIndexSetInteger(3, PLOT_LINE_STYLE, STYLE_DOT);
      PlotIndexSetInteger(3, PLOT_LINE_WIDTH, 1);
      PlotIndexSetString(3,  PLOT_LABEL, "TL-N armed level (bear)");
     }
   else
     {
      PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(3, PLOT_DRAW_TYPE, DRAW_NONE);
     }

   // confirmed entry arrows
   if(InpShowArrows)
     {
      PlotIndexSetInteger(4, PLOT_ARROW, 233);
      PlotIndexSetInteger(4, PLOT_LINE_COLOR, InpBuyColor);
      PlotIndexSetInteger(4, PLOT_LINE_WIDTH, InpArrowSize);
      PlotIndexSetString(4,  PLOT_LABEL, "TL-N BUY");
      PlotIndexSetInteger(5, PLOT_ARROW, 234);
      PlotIndexSetInteger(5, PLOT_LINE_COLOR, InpSellColor);
      PlotIndexSetInteger(5, PLOT_LINE_WIDTH, InpArrowSize);
      PlotIndexSetString(5,  PLOT_LABEL, "TL-N SELL");
     }
   else
     {
      PlotIndexSetInteger(4, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(5, PLOT_DRAW_TYPE, DRAW_NONE);
     }

   // TL-break dots
   if(InpShowBreakDot)
     {
      PlotIndexSetInteger(6, PLOT_ARROW, 159);
      PlotIndexSetInteger(6, PLOT_LINE_COLOR, InpResColor);
      PlotIndexSetInteger(6, PLOT_LINE_WIDTH, 1);
      PlotIndexSetString(6,  PLOT_LABEL, "TL-N break dot (res)");
      PlotIndexSetInteger(7, PLOT_ARROW, 159);
      PlotIndexSetInteger(7, PLOT_LINE_COLOR, InpSupColor);
      PlotIndexSetInteger(7, PLOT_LINE_WIDTH, 1);
      PlotIndexSetString(7,  PLOT_LABEL, "TL-N break dot (sup)");
     }
   else
     {
      PlotIndexSetInteger(6, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(7, PLOT_DRAW_TYPE, DRAW_NONE);
     }
  }

//+------------------------------------------------------------------+
// PanelClearCanvas: state visuals (lines, levels) are wiped over the
// scan window and refilled every scan. Marker buffers (arrows, dots)
// are write-once and only get their NEWLY APPENDED cells initialized
// (the terminal does not guarantee new buffer cells are empty) -- so
// printed history persists, and a fresh bar can
// never show a garbage arrow at price 0.
//+------------------------------------------------------------------+
void PanelClearCanvas(const int base, const int rates_total)
  {
   if(!g_panelBuffersInit)
     {
      ArrayInitialize(BufLineR, EMPTY_VALUE); ArrayInitialize(BufLineS, EMPTY_VALUE);
      ArrayInitialize(BufLvlR,  EMPTY_VALUE); ArrayInitialize(BufLvlS,  EMPTY_VALUE);
      ArrayInitialize(BufBuy,   EMPTY_VALUE); ArrayInitialize(BufSell,  EMPTY_VALUE);
      ArrayInitialize(BufDotR,  EMPTY_VALUE); ArrayInitialize(BufDotS,  EMPTY_VALUE);
      g_panelBuffersInit = true;
     }
   else
     {
      for(int g = MathMax(0, g_panelClearedTo + 1); g < rates_total; g++)
        {
         BufBuy[g]  = EMPTY_VALUE;
         BufSell[g] = EMPTY_VALUE;
         BufDotR[g] = EMPTY_VALUE;
         BufDotS[g] = EMPTY_VALUE;
        }
     }
   g_panelClearedTo = rates_total - 1;

   for(int g = base; g < rates_total; g++)
     {
      BufLineR[g] = EMPTY_VALUE;
      BufLineS[g] = EMPTY_VALUE;
      BufLvlR[g]  = EMPTY_VALUE;
      BufLvlS[g]  = EMPTY_VALUE;
     }
  }

//+------------------------------------------------------------------+
// PanelDrawTrend: writes a sloped line into the side's buffer from
// the first anchor to toGlobal (inclusive), and flips the plot style
// (solid = active, dotted = broken).
//+------------------------------------------------------------------+
void PanelDrawTrend(const bool isRes, const int base, const int iA,
                    const int toGlobal, const double pA, const double slope,
                    const ENUM_LINE_STYLE style)
  {
   PlotIndexSetInteger(isRes ? 0 : 1, PLOT_LINE_STYLE, style);
   for(int g = base + iA; g <= toGlobal; g++)
     {
      double v = pA + slope * ((g - base) - iA);
      if(isRes) BufLineR[g] = v;
      else      BufLineS[g] = v;
     }
  }
//+------------------------------------------------------------------+