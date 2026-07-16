//+------------------------------------------------------------------+
//| TrendlinesWithBreaks.mq5                                         |
//| MQL5 port of "Trendlines with Breaks"                            |
//|                                                                  |
//| v2.01:                                                           |
//|  - GAP-PROOF EXTENDED LINES: anchor 2 now uses a real bar's       |
//|    timestamp spanning Length bars (same slope-per-bar), instead   |
//|    of t1 + PeriodSeconds(). The old fake timestamp could land     |
//|    inside a weekend/session gap, collapsing both anchors onto the |
//|    same x pixel and rendering the ray as a near-vertical line.    |
//|                                                                   |
//| v2 rewrite:                                                      |
//|  - strict watermark processing: every completed bar advances the |
//|    trendline state exactly once (fixes lines drifting on ticks)  |
//|  - buffers stay EMPTY until the first pivot on each side exists  |
//|    (fixes the vertical line from price 0 at chart start)         |
//|  - breakout state follows the same single-pass rule (stable      |
//|    arrows, no live-edge flicker)                                 |
//|  - extended doted lines updated once per new pivot only          |
//+------------------------------------------------------------------+
#property version   "2.01"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   4

#property indicator_label1  "Upper"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrTeal
#property indicator_width1  1

#property indicator_label2  "Lower"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_width2  1

#property indicator_label3  "UpBreak"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrTeal
#property indicator_width3  2

#property indicator_label4  "DownBreak"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrRed
#property indicator_width4  2

enum ENUM_SLOPE_METHOD
{
   SLOPE_ATR = 0,    // Atr
   SLOPE_STDEV = 1,  // Stdev
   SLOPE_LINREG = 2  // Linreg
};

input int               Length            = 14;           // Swing Detection Lookback
input double            Mult              = 1.0;          // Slope multiplier
input ENUM_SLOPE_METHOD CalcMethod        = SLOPE_ATR;    // Slope Calculation Method
input bool              Backpaint         = true;         // Backpaint (shift lines to pivot bars)
input bool              ShowBreaks        = false;        // Show breakout arrows
input color             UpColor           = clrGreen;
input color             DnColor           = clrRed;
input bool              ShowExtendedLines = true;

double UpperBuffer[];
double LowerBuffer[];
double UpBreakBuffer[];
double DownBreakBuffer[];

int g_atrHandle = INVALID_HANDLE;
string g_prefix;   // unique object prefix per instance (settings-based)

// --- Debug/error logging state: each failure is printed ONCE while it
// persists, and the flag resets on recovery so a new failure later still
// gets reported. ---
bool g_loggedCopyFail = false;

// --- Extended-line recovery state -----------------------------------------
// The two extended trendlines are only (re)drawn when a NEW PIVOT fires,
// which on a quiet stretch can be many bars apart -- so a wiped object
// (delete-all, template reload) used to stay gone until the next pivot.
// Every UpdateExtendedLine call records its parameters here, and the 1s
// self-heal timer rebuilds any line that exists in state but not on chart.
struct ExtLineState
  {
   bool     active;
   datetime t1;
   double   p1;
   datetime t2;
   double   p2;
   color    col;
  };
ExtLineState g_extLine[2];        // [0] = "up", [1] = "dn"

//==================================================================
// HANDLE WARM-UP GRACE: right after attach/reinit the ATR handle can
// transiently fail BarsCalculated/CopyBuffer even though data is fine
// a moment later. Retried silently during a short grace window; only a
// persistent failure is logged.
//==================================================================
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS; // uint wrap-safe
}

// --- persistent state, advanced exactly once per COMPLETED bar ---
double g_upper   = 0.0;
double g_lower   = 0.0;
double g_slopePh = 0.0;
double g_slopePl = 0.0;
int    g_upos    = 0;
int    g_dnos    = 0;
bool   g_haveUpper = false;   // becomes true after the first pivot high
bool   g_haveLower = false;   // becomes true after the first pivot low

int    g_watermark = -1;      // index of the last completed bar whose state was applied

//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0, UpperBuffer,     INDICATOR_DATA);
   SetIndexBuffer(1, LowerBuffer,     INDICATOR_DATA);
   SetIndexBuffer(2, UpBreakBuffer,   INDICATOR_DATA);
   SetIndexBuffer(3, DownBreakBuffer, INDICATOR_DATA);

   PlotIndexSetInteger(2, PLOT_ARROW, 233); // up arrow
   PlotIndexSetInteger(3, PLOT_ARROW, 234); // down arrow

   for(int i = 0; i < 4; i++)
      PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   PlotIndexSetInteger(0, PLOT_LINE_COLOR, UpColor);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, DnColor);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, UpColor);
   PlotIndexSetInteger(3, PLOT_LINE_COLOR, DnColor);

   g_atrHandle = iATR(_Symbol, _Period, MathMax(1, Length));
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("TrendlinesWithBreaks ERROR: failed to create ATR handle, error code ", GetLastError(), ".");
      return(INIT_FAILED);
   }

   // unique per instance: two copies with different settings no longer
   // fight over the same extended-line objects
   g_prefix = StringFormat("TLB_%d_%d_", Length, (int)CalcMethod);

   g_initTick = GetTickCount();
   g_loggedCopyFail = false;

   g_upper = 0.0; g_lower = 0.0;
   g_slopePh = 0.0; g_slopePl = 0.0;
   g_upos = 0; g_dnos = 0;
   g_haveUpper = false; g_haveLower = false;
   g_watermark = -1;

   IndicatorSetString(INDICATOR_SHORTNAME, "Trendlines with Breaks");

   // 1-second self-heal timer (suite standard, matches Sub-/Float-Chart).
   // The extended lines are only redrawn at the NEXT pivot event, which
   // can be many bars away -- and ticks alone can't restore a wiped line
   // on a dead/closed market. The timer restores from the stored state
   // (RestoreExtendedLines) and does nothing when the objects are there.
   EventSetTimer(1);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
bool IsPivotHighAt(const double &high[], int idx, int total, int len)
{
   if(idx - len < 0 || idx + len >= total) return false;
   double val = high[idx];
   for(int j = idx - len; j <= idx + len; j++)
   {
      if(j == idx) continue;
      if(high[j] >= val) return false;
   }
   return true;
}

bool IsPivotLowAt(const double &low[], int idx, int total, int len)
{
   if(idx - len < 0 || idx + len >= total) return false;
   double val = low[idx];
   for(int j = idx - len; j <= idx + len; j++)
   {
      if(j == idx) continue;
      if(low[j] <= val) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
double ComputeSlope(int i, const double &close[], const double &atr[], const int atrBase)
{
   if(i < Length - 1) return 0.0;

   if(CalcMethod == SLOPE_ATR)
   {
      // atr[] holds only the TAIL of history (see OnCalculate): the value
      // for chronological bar i sits at local index i - atrBase
      int k = i - atrBase;
      if(k < 0 || k >= ArraySize(atr)) return 0.0;
      return (Length != 0) ? atr[k] / Length * Mult : 0.0;
   }
   else if(CalcMethod == SLOPE_STDEV)
   {
      double mean = 0.0;
      for(int k = i - Length + 1; k <= i; k++) mean += close[k];
      mean /= Length;
      double var = 0.0;
      for(int k = i - Length + 1; k <= i; k++) var += (close[k]-mean)*(close[k]-mean);
      var /= Length;
      return MathSqrt(var) / Length * Mult;
   }
   else // SLOPE_LINREG
   {
      double sumX=0, sumY=0, sumXY=0, sumX2=0;
      for(int k = i - Length + 1; k <= i; k++)
      {
         double x = (double)k;
         double y = close[k];
         sumX += x; sumY += y; sumXY += x*y; sumX2 += x*x;
      }
      double meanX = sumX/Length;
      double meanY = sumY/Length;
      double covXY = sumXY/Length - meanX*meanY;
      double varX  = sumX2/Length - meanX*meanX;
      if(varX == 0.0) return 0.0;
      return MathAbs(covXY) / varX / 2.0 * Mult;
   }
}

//+------------------------------------------------------------------+
void UpdateExtendedLine(string name, datetime t1, double p1, datetime t2, double p2, color col)
{
   // Record the latest parameters so the force refresh can rebuild this
   // line from state if something wipes the object between pivots.
   int slot = (name == g_prefix + "up") ? 0 : 1;
   g_extLine[slot].active = true;
   g_extLine[slot].t1  = t1;
   g_extLine[slot].p1  = p1;
   g_extLine[slot].t2  = t2;
   g_extLine[slot].p2  = p2;
   g_extLine[slot].col = col;

   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false); // click-proof on a scalping chart
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);      // out of the objects list
   }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
}

//+------------------------------------------------------------------+
//| Rebuild any extended line that exists in state but not on chart  |
//+------------------------------------------------------------------+
void RestoreExtendedLines(void)
  {
   bool restored = false;
   for(int s = 0; s < 2; s++)
     {
      if(!g_extLine[s].active)
         continue;
      string name = g_prefix + (s == 0 ? "up" : "dn");
      if(ObjectFind(0, name) >= 0)
         continue;
      UpdateExtendedLine(name, g_extLine[s].t1, g_extLine[s].p1,
                         g_extLine[s].t2, g_extLine[s].p2, g_extLine[s].col);
      restored = true;
     }
   if(restored)
      ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Timer: dead-market self-heal ONLY. Cost when nothing is missing:  |
//| two ObjectFind calls per second.                                  |
//+------------------------------------------------------------------+
void OnTimer()
  {
   RestoreExtendedLines();
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
   if(rates_total < 2*Length + 2) return(0);

   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   // --- ATR: copy ONLY the tail actually needed this call ---
   // v2 copied the ENTIRE history (rates_total bars) into a local array
   // on EVERY TICK -- the single heaviest thing this indicator did. Only
   // bars past the watermark are processed, so only that tail (plus
   // margin) is copied; atrBase maps chronological index -> local index.
   double atr[];
   ArraySetAsSeries(atr, false);
   int atrBase = 0;
   if(CalcMethod == SLOPE_ATR)
   {
      int needFrom = (prev_calculated == 0 || g_watermark < 0) ? 0 : g_watermark; // 1-bar margin
      int toCopy   = rates_total - needFrom;
      if(toCopy < 2)          toCopy = 2;
      if(toCopy > rates_total) toCopy = rates_total;

      ResetLastError();
      int copied = CopyBuffer(g_atrHandle, 0, 0, toCopy, atr);
      if(copied <= 0)
      {
         // Transient (attach warm-up) failures retry silently; a
         // persistent one is logged ONCE. Returning prev_calculated
         // (not 0) avoids the full state-reset + object-wipe churn the
         // old code triggered on the very next tick.
         if(!StillWarmingUp() && !g_loggedCopyFail)
         {
            Print("TrendlinesWithBreaks ERROR: CopyBuffer() failed for ATR (copied=", copied,
                  "), error code ", GetLastError(), ". Will keep retrying..");
            g_loggedCopyFail = true;
         }
         return(prev_calculated);
      }
      g_loggedCopyFail = false; // recovered
      atrBase = rates_total - copied;
   }

   int offset = Backpaint ? Length : 0;

   // --- full recalculation: reset everything ---
   if(prev_calculated == 0 || prev_calculated > rates_total || g_watermark < 0)
   {
      g_upper = 0.0; g_lower = 0.0;
      g_slopePh = 0.0; g_slopePl = 0.0;
      g_upos = 0; g_dnos = 0;
      g_haveUpper = false; g_haveLower = false;
      g_watermark = MathMax(Length - 1, 2*Length - 1); // state starts once pivots become detectable

      for(int j = 0; j < rates_total; j++)
      {
         UpperBuffer[j] = EMPTY_VALUE;
         LowerBuffer[j] = EMPTY_VALUE;
         UpBreakBuffer[j] = EMPTY_VALUE;
         DownBreakBuffer[j] = EMPTY_VALUE;
      }
      ObjectsDeleteAll(0, g_prefix);
      g_extLine[0].active = false; // objects wiped on purpose -> state must not resurrect them
      g_extLine[1].active = false;
   }

   int lastCompleted = rates_total - 2; // last fully closed bar
   int liveBar = rates_total - 1;

   // blank any not-yet-written buffer elements (new bars appended since last call)
   for(int j = g_watermark + 1; j < rates_total; j++)
   {
      UpperBuffer[j]     = EMPTY_VALUE;
      LowerBuffer[j]     = EMPTY_VALUE;
      UpBreakBuffer[j]   = EMPTY_VALUE;
      DownBreakBuffer[j] = EMPTY_VALUE;
   }

   // --- advance state over completed bars, EXACTLY ONCE each ---
   for(int i = g_watermark + 1; i <= lastCompleted; i++)
   {
      double slope = ComputeSlope(i, close, atr, atrBase);

      // pivot at (i - Length) is confirmed at bar i
      int pivotIdx = i - Length;
      bool ph = false, pl = false;
      double phVal = 0.0, plVal = 0.0;
      if(pivotIdx >= Length)
      {
         ph = IsPivotHighAt(high, pivotIdx, rates_total, Length);
         if(ph) phVal = high[pivotIdx];
         pl = IsPivotLowAt(low, pivotIdx, rates_total, Length);
         if(pl) plVal = low[pivotIdx];
      }

      if(ph) { g_slopePh = slope; g_haveUpper = true; }
      if(pl) { g_slopePl = slope; g_haveLower = true; }

      if(g_haveUpper) g_upper = ph ? phVal : g_upper - g_slopePh;
      if(g_haveLower) g_lower = pl ? plVal : g_lower + g_slopePl;

      double upperRT = g_upper - g_slopePh * Length; // real-time projected values
      double lowerRT = g_lower + g_slopePl * Length;

      // breakout state (mirrors Pine's upos/dnos)
      int uposBefore = g_upos;
      int dnosBefore = g_dnos;
      if(g_haveUpper) g_upos = ph ? 0 : ((close[i] > upperRT) ? 1 : g_upos);
      if(g_haveLower) g_dnos = pl ? 0 : ((close[i] < lowerRT) ? 1 : g_dnos);

      if(ShowBreaks && g_upos > uposBefore) UpBreakBuffer[i]   = low[i];
      if(ShowBreaks && g_dnos > dnosBefore) DownBreakBuffer[i] = high[i];

      // --- write trendline buffers (only once a side has its first pivot) ---
      if(Backpaint)
      {
         int idx = i - offset;
         if(idx >= 0)
         {
            if(g_haveUpper) UpperBuffer[idx] = ph ? EMPTY_VALUE : g_upper; // gap at pivot (mirrors color=na)
            if(g_haveLower) LowerBuffer[idx] = pl ? EMPTY_VALUE : g_lower;
         }
      }
      else
      {
         if(g_haveUpper) UpperBuffer[i] = ph ? EMPTY_VALUE : upperRT; // gap at pivot (mirrors color=na)
         if(g_haveLower) LowerBuffer[i] = pl ? EMPTY_VALUE : lowerRT;
      }

      // --- extended dashed lines: refresh only when a NEW pivot locks in ---
      if(ShowExtendedLines)
      {
         if(ph)
         {
            // Anchor 2 must be a REAL bar's timestamp. The old code used
            // t1 + PeriodSeconds(); when the pivot bar sits right before a
            // time gap (weekend/session close) that fake timestamp falls
            // inside the gap, MT5 collapses it onto (almost) the same x
            // pixel as t1, and the ray through the two anchors renders as
            // a near-vertical line. Spanning Length real bars keeps the
            // same slope-per-bar while making the geometry gap-proof.
            int anchorIdx = Backpaint ? pivotIdx : i;
            double p1 = Backpaint ? phVal : upperRT;
            int span = MathMin(Length, (rates_total - 1) - anchorIdx);
            if(span < 1) span = 1;
            UpdateExtendedLine(g_prefix + "up", time[anchorIdx], p1,
                               time[anchorIdx + span], p1 - slope * span, UpColor);
         }
         if(pl)
         {
            // Same gap-proof anchoring as the up line (see comment above).
            int anchorIdx = Backpaint ? pivotIdx : i;
            double p1 = Backpaint ? plVal : lowerRT;
            int span = MathMin(Length, (rates_total - 1) - anchorIdx);
            if(span < 1) span = 1;
            UpdateExtendedLine(g_prefix + "dn", time[anchorIdx], p1,
                               time[anchorIdx + span], p1 + slope * span, DnColor);
         }
      }
   }

   if(lastCompleted > g_watermark)
      g_watermark = lastCompleted;

   // --- live (forming) bar: display from a SNAPSHOT, never mutate state ---
   // In backpaint mode the last `Length` buffer indices are intentionally
   // empty (same as Pine's offset plotting), so nothing to draw here.
   if(!Backpaint && liveBar >= 0)
   {
      double upperLive = g_upper - g_slopePh;            // one decay step ahead
      double lowerLive = g_lower + g_slopePl;
      if(g_haveUpper) UpperBuffer[liveBar] = upperLive - g_slopePh * Length;
      if(g_haveLower) LowerBuffer[liveBar] = lowerLive + g_slopePl * Length;
   }

   return(rates_total);
}
//+------------------------------------------------------------------+