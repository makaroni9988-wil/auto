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
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

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
string g_prefix = "";   // instance-unique object prefix, built in OnInit (was fixed "TLN_")

// validated input copies (inputs are read-only)
int    ExtPivotBars, ExtLookback, ExtMaxPivots, ExtATRPeriod, ExtMinTouches, ExtWindow, ExtMaxSignals;
double ExtTouchTolATR, ExtWickFilterATR;

int      g_atrHandle       = INVALID_HANDLE;
datetime g_lastBarTime     = 0;
datetime g_lastForceRefresh = 0;
bool     g_loggedNoData    = false;
bool     g_loggedObjFail   = false;

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

   // Instance-unique object prefix (was a fixed "TLN_" #define, which made
   // every copy share one namespace so removing/reiniting one wiped the
   // other's objects). Base "TLN_" keeps this file distinct from the panel
   // build (lines-N-in uses "TLNI_"), so the two can be tested side by side
   // without colliding. The chart period is appended so a copy on a
   // different timeframe owns its own objects; it is recomputed on reinit,
   // and OnDeinit (which runs first, still holding the old value) cleans the
   // old objects before OnInit assigns the new one -- no orphans.
   string tfn = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(tfn, "PERIOD_", "");
   g_prefix = "TLN_" + tfn + "_";

   g_lastBarTime = 0; // force a scan on the first tick
   g_lastForceRefresh = 0;
   g_initTick = GetTickCount(); // start the warm-up grace clock

   // 1-second self-heal timer (suite standard, matches Sub-/Float-Chart).
   // Ticks alone can't restore wiped lines/arrows or force-refresh on a
   // dead or closed market. OnTimer copies its own rates and runs the same
   // gated scan (see PollFromCopy); it shares g_lastBarTime/g_lastForceRefresh
   // with OnCalculate so the two never double-work. The per-tick path
   // (OnCalculate) is left exactly as-is.
   EventSetTimer(1);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
     }
   ObjectsDeleteAll(0, g_prefix);
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
//| Timer: dead-market self-heal. OnCalculate only runs on ticks, so |
//| on a frozen/closed market wiped objects never come back and the  |
//| force-refresh never fires. The timer copies its own rates and    |
//| runs the SAME gated scan. It shares g_lastBarTime and            |
//| g_lastForceRefresh with OnCalculate, so on a live market the gate |
//| makes this return immediately -- no double scanning.             |
//+------------------------------------------------------------------+
void OnTimer()
  {
   PollFromCopy();
  }

//+------------------------------------------------------------------+
//| Copy the current symbol/period rates (non-series, exactly the    |
//| layout Scan expects: index 0 = oldest, last index = forming bar) |
//| and run the same new-bar / force-refresh gate as OnCalculate.    |
//+------------------------------------------------------------------+
void PollFromCopy()
  {
   int need = ExtPivotBars * 2 + ExtATRPeriod + 10;
   int W    = MathMax(need, ExtLookback);

   datetime t[];
   double   o[], h[], l[], c[];
   ArraySetAsSeries(t, false);
   ArraySetAsSeries(o, false);
   ArraySetAsSeries(h, false);
   ArraySetAsSeries(l, false);
   ArraySetAsSeries(c, false);

   // Copy the newest W bars. Non-series -> element [copied-1] is the
   // still-forming bar, [copied-2] the newest closed one, matching the
   // window layout Scan and OnCalculate both assume.
   int nt = CopyTime (_Symbol, _Period, 0, W, t);
   int no = CopyOpen (_Symbol, _Period, 0, W, o);
   int nh = CopyHigh (_Symbol, _Period, 0, W, h);
   int nl = CopyLow  (_Symbol, _Period, 0, W, l);
   int nc = CopyClose(_Symbol, _Period, 0, W, c);

   int copied = nt;
   if(copied < need || no != copied || nh != copied || nl != copied || nc != copied)
      return; // history not ready yet -- retry next second (warm-up safe)

   datetime curBar = t[copied - 1];

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

   // Also treat "our newest object went missing" as a reason to rescan,
   // so a delete-all / template reload on a dead market recovers within
   // a second instead of waiting for the next force-refresh interval.
   bool objectsMissing = (ObjectFind(0, g_prefix + "LINE_R") < 0 &&
                          ObjectFind(0, g_prefix + "LINE_S") < 0 &&
                          g_scannedOnce);

   if(curBar == g_lastBarTime && !forceRefresh && !objectsMissing)
      return;

   if(Scan(copied, t, o, h, l, c))
     {
      g_lastBarTime = curBar;
      g_scannedOnce = true;
     }
  }

//+------------------------------------------------------------------+
// One full stateless scan over the lookback window. Recomputing from
// scratch each closed bar keeps the state machine impossible to
// desync; the window is bounded so the cost is trivial (well under a
// millisecond) once per bar. Objects are idempotent (keyed by bar
// time), so redrawing never duplicates and printed arrows never move.
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

   // ---- Stage 1: confirmed pivots, newest ExtMaxPivots per side ----
   Pivot hi[], lo[];
   CollectPivots(base, last, high, low, open, close, atr, hi, lo);

   // ---- Stages 2-4 per side ----
   ProcessSide(true,  base, last, time, high, low, close, atr, hi, lo); // resistance -> bullish N
   ProcessSide(false, base, last, time, high, low, close, atr, hi, lo); // support    -> bearish N

   PruneByPrefix(g_prefix + "BUY_",  ExtMaxSignals);
   PruneByPrefix(g_prefix + "SELL_", ExtMaxSignals);
   PruneByPrefix(g_prefix + "TB_",   ExtMaxSignals);

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
   string lineName = g_prefix + (isRes ? "LINE_R" : "LINE_S");
   string lvlName  = g_prefix + (isRes ? "LVL_R"  : "LVL_S");
   color  lineClr  = isRes ? InpResColor : InpSupColor;
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
     {
      ObjectDelete(0, lineName);
      ObjectDelete(0, lvlName);
      return;
     }

   // ---- draw the line ----
   datetime tA = time[base + bestA];
   if(bestBreak < 0)
     {
      double pBv = bestPA + bestSlope * (bestB - bestA);
      UpsertTrend(lineName, tA, bestPA, time[base + bestB], pBv,
                  lineClr, STYLE_SOLID, InpLineWidth, true);
      ObjectDelete(0, lvlName); // nothing armed
      return;
     }

   // broken: dotted, ends exactly at the break bar. WARNING state.
   double lvBrk = bestPA + bestSlope * (bestBreak - bestA);
   UpsertTrend(lineName, tA, bestPA, time[base + bestBreak], lvBrk,
               lineClr, STYLE_DOT, InpLineWidth, false);

   datetime tBrk = time[base + bestBreak];
   if(InpShowBreakDot)
      UpsertDot(g_prefix + "TB_" + (isRes ? "R_" : "S_") + TimeToString(tBrk, TIME_DATE|TIME_MINUTES),
                tBrk, lvBrk, 0.15 * atr[bestBreak], lineClr, isRes);

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
      // armed: show the structure level the market has to beat,
      // drawn from the break bar to the newest closed bar
      if(InpShowArmedLevel)
         UpsertTrend(lvlName, tBrk, structLvl,
                     time[base + last], structLvl, InpLevelColor, STYLE_DOT, 1, false);
      else
         ObjectDelete(0, lvlName); // toggled off mid-arm -> remove any leftover
      return;
     }

   ObjectDelete(0, lvlName);
   if(outcome != 1 || confirmIdx < 0)
      return;

   // ---- confirmed N breakout: the actual entry arrow ----
   datetime tC = time[base + confirmIdx];
   double   off = 0.5 * atr[confirmIdx];
   if(!InpShowArrows)
     {
      // visual off; the alert block below still runs untouched
     }
   else if(isRes)
      UpsertArrow(g_prefix + "BUY_" + TimeToString(tC, TIME_DATE|TIME_MINUTES),
                  tC, low[base + confirmIdx] - off, 233, InpBuyColor, ANCHOR_TOP,
                  "TL-N confirmed BULLISH breakout (TL break + structure break)");
   else
      UpsertArrow(g_prefix + "SELL_" + TimeToString(tC, TIME_DATE|TIME_MINUTES),
                  tC, high[base + confirmIdx] + off, 234, InpSellColor, ANCHOR_BOTTOM,
                  "TL-N confirmed BEARISH breakout (TL break + structure break)");

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

//+------------------------------------------------------------------+
void UpsertTrend(const string name,
                 const datetime t1, const double p1,
                 const datetime t2, const double p2,
                 const color clr, const ENUM_LINE_STYLE style,
                 const int width, const bool rayRight)
  {
   if(ObjectFind(0, name) < 0)
     {
      ResetLastError();
      if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2))
        {
         if(!g_loggedObjFail)
           {
            Print("TL-N ERROR: failed to create object '", name, "', error code ", GetLastError(), ".");
            g_loggedObjFail = true;
           }
         return;
        }
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, rayRight);
  }

//+------------------------------------------------------------------+
void UpsertDot(const string name, const datetime t, const double p,
               const double airGap, const color clr, const bool brokeUp)
  {
   if(ObjectFind(0, name) >= 0)
      return;
   // Above the line for an up-break (resistance), below it for a
   // down-break (support): the dot sits where price WENT. OBJ_ARROW
   // ignores ANCHOR_CENTER, so use the two anchors it actually honors:
   // ANCHOR_BOTTOM draws the glyph above the anchor price, ANCHOR_TOP
   // draws it below.
   double dotPrice = brokeUp ? (p + airGap) : (p - airGap);
   ResetLastError();
   if(!ObjectCreate(0, name, OBJ_ARROW, 0, t, dotPrice))
      return; // dot is cosmetic; fail silently rather than spam
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 159); // small dot
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, brokeUp ? ANCHOR_BOTTOM : ANCHOR_TOP);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0,  name, OBJPROP_TOOLTIP, "Trendline break (warning, not entry)");
  }

//+------------------------------------------------------------------+
void UpsertArrow(const string name, const datetime t, const double p,
                 const int code, const color clr, const ENUM_ARROW_ANCHOR anchor,
                 const string tip)
  {
   if(ObjectFind(0, name) >= 0)
      return; // printed arrows never move: no repaint by construction
   ResetLastError();
   if(!ObjectCreate(0, name, OBJ_ARROW, 0, t, p))
     {
      Print("TL-N ERROR: failed to create signal arrow '", name, "', error code ", GetLastError(), ".");
      return;
     }
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpArrowSize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0,  name, OBJPROP_TOOLTIP, tip);
  }

//+------------------------------------------------------------------+
// Keep at most 'keep' newest objects whose names start with 'pfx',
// judged by their anchor time. Bounded object count forever.
//+------------------------------------------------------------------+
void PruneByPrefix(const string pfx, const int keep)
  {
   string names[];
   datetime times[];
   int n = 0;

   int total = ObjectsTotal(0, 0, OBJ_ARROW);
   for(int i = 0; i < total; i++)
     {
      string nm = ObjectName(0, i, 0, OBJ_ARROW);
      if(StringFind(nm, pfx) != 0)
         continue;
      ArrayResize(names, n + 1);
      ArrayResize(times, n + 1);
      names[n] = nm;
      times[n] = (datetime)ObjectGetInteger(0, nm, OBJPROP_TIME);
      n++;
     }

   while(n > keep)
     {
      int oldest = 0;
      for(int i = 1; i < n; i++)
         if(times[i] < times[oldest])
            oldest = i;
      ObjectDelete(0, names[oldest]);
      names[oldest] = names[n - 1];
      times[oldest] = times[n - 1];
      n--;
     }
  }
//+------------------------------------------------------------------+