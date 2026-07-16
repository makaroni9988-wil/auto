// version: 3.01
//   - Timeframe input switched from a custom enum to the NATIVE
//     ENUM_TIMEFRAMES dropdown -- same picker as the chart panels, and
//     all periods (M2..H12 etc.) now available. PERIOD_CURRENT = follow
//     the chart. NOTE: input type changed, so an already-attached copy
//     resets its Timeframe setting to Current once on refresh.
// version: 3.00
//   - MULTI-TIMEFRAME LOCK: new "Timeframe" input. Leave it on "Current" for
//     the normal behaviour. Pick a timeframe (M1..MN1) and the indicator
//     computes support/resistance + break/wick arrows on THAT timeframe's data
//     and projects them onto whatever chart period you are viewing. The locked
//     levels stay put when you switch the chart's period.
//   - core calculation refactored into ComputeSeries() so the exact same,
//     verified math runs for both the current chart and a locked timeframe.
//   - full clean recompute per NEW bar (no incremental EMA state that can
//     drift), capped by MaxBarsBack; recompute is skipped within a bar for
//     speed via a rates_total / htf-bar-count guard.
//   - v2.00 correctness kept: pivots and arrows confirmed on CLOSED bars only;
//     break arrows vs wick arrows separately toggleable and separately colored.

#property version   "3.01"
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6

#property indicator_label1  "Resistance"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrRed
#property indicator_width1  3
#property indicator_style1  STYLE_SOLID

#property indicator_label2  "Support"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDodgerBlue
#property indicator_width2  3
#property indicator_style2  STYLE_SOLID

#property indicator_label3  "BreakUp"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrLime
#property indicator_width3  2

#property indicator_label4  "BreakDown"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrRed
#property indicator_width4  2

#property indicator_label5  "BullWick"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrAqua
#property indicator_width5  2

#property indicator_label6  "BearWick"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrOrange
#property indicator_width6  2

// Native MT5 timeframe dropdown, same as the chart panels (v3.01).
// Current = follow the chart (normal behavior). Anything else = compute
// on that timeframe and project onto whatever period you're viewing.
input ENUM_TIMEFRAMES Timeframe       = PERIOD_CURRENT; // Timeframe (lock)

input int             LeftBars        = 15;             // Left Bars
input int             RightBars       = 15;             // Right Bars
input double          VolumeThreshold = 20.0;           // Volume Threshold (%)
input int             MaxBarsBack     = 200;            // Max bars to scan (0 = all available history)

input group "--- ARROWS ---"
// Break arrows: close through the level + volume confirmation + body shape.
// Wick arrows: cross of the level but wick-dominant candle = rejection /
// potential fakeout. Opposite meanings -- separately toggleable and colored.
input bool   ShowBreakArrows = false;   // Show break arrows (volume-confirmed)
input bool   ShowWickArrows  = false;   // Show wick/rejection arrows
input color  BreakUpColor    = clrLime;
input color  BreakDownColor  = clrRed;
input color  WickBullColor   = clrWhiteSmoke;
input color  WickBearColor   = clrWhiteSmoke;

double ResistanceBuffer[];
double SupportBuffer[];
double BreakUpBuffer[];
double BreakDownBuffer[];
double BullWickBuffer[];
double BearWickBuffer[];

// --- recompute guards (recompute once per new bar, not every tick) ---
int    g_lastRatesTotal = -1;
int    g_lastHtfBars    = -1;

//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0, ResistanceBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, SupportBuffer,    INDICATOR_DATA);
   SetIndexBuffer(2, BreakUpBuffer,    INDICATOR_DATA);
   SetIndexBuffer(3, BreakDownBuffer,  INDICATOR_DATA);
   SetIndexBuffer(4, BullWickBuffer,   INDICATOR_DATA);
   SetIndexBuffer(5, BearWickBuffer,   INDICATOR_DATA);

   PlotIndexSetInteger(2, PLOT_ARROW, 233); // wingdings up arrow
   PlotIndexSetInteger(3, PLOT_ARROW, 234); // wingdings down arrow
   PlotIndexSetInteger(4, PLOT_ARROW, 233);
   PlotIndexSetInteger(5, PLOT_ARROW, 234);

   for(int i = 0; i < 6; i++)
      PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   PlotIndexSetInteger(2, PLOT_LINE_COLOR, BreakUpColor);
   PlotIndexSetInteger(3, PLOT_LINE_COLOR, BreakDownColor);
   PlotIndexSetInteger(4, PLOT_LINE_COLOR, WickBullColor);
   PlotIndexSetInteger(5, PLOT_LINE_COLOR, WickBearColor);

   string tfName = (Timeframe == PERIOD_CURRENT)
                   ? "Current"
                   : StringSubstr(EnumToString(Timeframe), 7); // "H1", "M15", ...
   IndicatorSetString(INDICATOR_SHORTNAME,
                      "S&R with Breaks [" + tfName + "]");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_lastRatesTotal = -1;
   g_lastHtfBars    = -1;

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
// PERIOD_CURRENT -> follow the chart; anything else = the locked TF.
ENUM_TIMEFRAMES SelectedPeriod()
{
   return (Timeframe == PERIOD_CURRENT)
          ? (ENUM_TIMEFRAMES)_Period
          : Timeframe;
}

//+------------------------------------------------------------------+
bool IsPivotHigh(const double &high[], int idx, int total, int leftBars, int rightBars)
{
   if(idx - leftBars < 0 || idx + rightBars >= total) return false;
   double val = high[idx];
   for(int j = idx - leftBars; j <= idx + rightBars; j++)
   {
      if(j == idx) continue;
      if(high[j] >= val) return false;
   }
   return true;
}

bool IsPivotLow(const double &low[], int idx, int total, int leftBars, int rightBars)
{
   if(idx - leftBars < 0 || idx + rightBars >= total) return false;
   double val = low[idx];
   for(int j = idx - leftBars; j <= idx + rightBars; j++)
   {
      if(j == idx) continue;
      if(low[j] <= val) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
// Break a DRAW_LINE into isolated horizontal segments: drop one point at
// each level change so consecutive levels don't get joined by a connector.
//+------------------------------------------------------------------+
void ApplySegmentGaps(double &buf[], int total)
{
   double prev = EMPTY_VALUE;
   for(int j = 0; j < total; j++)
   {
      double cur = buf[j];
      if(cur != EMPTY_VALUE && prev != EMPTY_VALUE && cur != prev)
         buf[j] = EMPTY_VALUE;   // gap at the first bar of the new level
      prev = cur;                // compare against the real level, not the gap
   }
}

//+------------------------------------------------------------------+
// Full, clean computation over one price series (index 0 = oldest).
// Fills gapless active-level lines (outRes/outSup) and per-bar arrow
// markers. Output arrays MUST already be sized to 'total'.
//+------------------------------------------------------------------+
void ComputeSeries(const int total,
                   const double &o[], const double &h[], const double &l[],
                   const double &c[], const long &vol[],
                   int leftBars, int rightBars, double volThresh, int maxBarsBack,
                   bool showBreak, bool showWick,
                   double &outRes[], double &outSup[],
                   double &outBU[], double &outBD[], double &outBW[], double &outBrW[])
{
   for(int j = 0; j < total; j++)
   {
      outRes[j] = EMPTY_VALUE;
      outSup[j] = EMPTY_VALUE;
      outBU[j]  = EMPTY_VALUE;
      outBD[j]  = EMPTY_VALUE;
      outBW[j]  = EMPTY_VALUE;
      outBrW[j] = EMPTY_VALUE;
   }

   if(total < leftBars + rightBars + 2)
      return;

   double kShort = 2.0 / (5.0 + 1.0);
   double kLong  = 2.0 / (10.0 + 1.0);

   int minStart = leftBars;
   int startBar = (maxBarsBack > 0) ? MathMax(minStart, total - maxBarsBack)
                                     : minStart;

   // event lists (pivot index + level value), max one per bar
   int    resIdx[]; double resVal[]; int resCount = 0;
   int    supIdx[]; double supVal[]; int supCount = 0;
   ArrayResize(resIdx, total); ArrayResize(resVal, total);
   ArrayResize(supIdx, total); ArrayResize(supVal, total);

   double emaShortPrev = (double)vol[startBar];
   double emaLongPrev  = (double)vol[startBar];

   double curHigh = EMPTY_VALUE;
   double curLow  = EMPTY_VALUE;

   int lastCompleted = total - 2; // last fully closed bar (total-1 is live)

   for(int i = startBar + 1; i <= lastCompleted; i++)
   {
      double v = (double)vol[i];
      double emaShort = v * kShort + emaShortPrev * (1.0 - kShort);
      double emaLong  = v * kLong  + emaLongPrev  * (1.0 - kLong);
      emaShortPrev = emaShort;
      emaLongPrev  = emaLong;

      // pivot at (i - rightBars) is fully confirmed at bar i; i is capped at
      // the last COMPLETED bar so the still-forming bar never enters a window
      int pivotIdx = i - rightBars;
      if(pivotIdx >= leftBars)
      {
         if(IsPivotHigh(h, pivotIdx, total, leftBars, rightBars))
         {
            double val = h[pivotIdx];
            if(resCount == 0 || resIdx[resCount-1] != pivotIdx)
            {
               resIdx[resCount] = pivotIdx;
               resVal[resCount] = val;
               resCount++;
            }
            curHigh = val;
         }
         if(IsPivotLow(l, pivotIdx, total, leftBars, rightBars))
         {
            double val = l[pivotIdx];
            if(supCount == 0 || supIdx[supCount-1] != pivotIdx)
            {
               supIdx[supCount] = pivotIdx;
               supVal[supCount] = val;
               supCount++;
            }
            curLow = val;
         }
      }

      if(curHigh == EMPTY_VALUE || curLow == EMPTY_VALUE)
         continue;
      if(!showBreak && !showWick)
         continue;

      double osc = (emaLong != 0.0) ? 100.0 * (emaShort - emaLong) / emaLong : 0.0;

      bool crossOverHigh = (c[i-1] <= curHigh) && (c[i] > curHigh);
      bool crossUnderLow = (c[i-1] >= curLow)  && (c[i] < curLow);

      if(showBreak)
      {
         if(crossUnderLow && !((o[i]-c[i]) < (h[i]-o[i])) && osc > volThresh)
            outBD[i] = h[i];
         if(crossOverHigh && !((o[i]-l[i]) > (c[i]-o[i])) && osc > volThresh)
            outBU[i] = l[i];
      }

      if(showWick)
      {
         if(crossOverHigh && ((o[i]-l[i]) > (c[i]-o[i])))
            outBW[i] = l[i];
         if(crossUnderLow && ((o[i]-c[i]) < (h[i]-o[i])))
            outBrW[i] = h[i];
      }
   }

   // gapless active-level fill (level = latest pivot with idx <= j), extends
   // to the live bar; the visual segment gaps are applied by the caller
   int rk = 0;
   for(int j = 0; j < total; j++)
   {
      while(rk + 1 < resCount && resIdx[rk+1] <= j) rk++;
      outRes[j] = (resCount > 0 && resIdx[rk] <= j) ? resVal[rk] : EMPTY_VALUE;
   }
   int sk = 0;
   for(int j = 0; j < total; j++)
   {
      while(sk + 1 < supCount && supIdx[sk+1] <= j) sk++;
      outSup[j] = (supCount > 0 && supIdx[sk] <= j) ? supVal[sk] : EMPTY_VALUE;
   }
}

//+------------------------------------------------------------------+
void BlankAllBuffers(int total)
{
   for(int j = 0; j < total; j++)
   {
      ResistanceBuffer[j] = EMPTY_VALUE;
      SupportBuffer[j]    = EMPTY_VALUE;
      BreakUpBuffer[j]    = EMPTY_VALUE;
      BreakDownBuffer[j]  = EMPTY_VALUE;
      BullWickBuffer[j]   = EMPTY_VALUE;
      BearWickBuffer[j]   = EMPTY_VALUE;
   }
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
   if(rates_total < LeftBars + RightBars + 2)
      return(0);

   ENUM_TIMEFRAMES selPeriod = SelectedPeriod();
   bool useMTF = (selPeriod != (ENUM_TIMEFRAMES)_Period);

   //================================================================
   // CURRENT CHART (no lock, or lock == current period)
   //================================================================
   if(!useMTF)
   {
      // recompute only on a new bar (or first run) -- cheap and drift-free
      if(prev_calculated > 0 && rates_total == g_lastRatesTotal)
         return(rates_total);

      ArraySetAsSeries(open,  false);
      ArraySetAsSeries(high,  false);
      ArraySetAsSeries(low,   false);
      ArraySetAsSeries(close, false);
      ArraySetAsSeries(tick_volume, false);

      ComputeSeries(rates_total, open, high, low, close, tick_volume,
                    LeftBars, RightBars, VolumeThreshold, MaxBarsBack,
                    ShowBreakArrows, ShowWickArrows,
                    ResistanceBuffer, SupportBuffer,
                    BreakUpBuffer, BreakDownBuffer, BullWickBuffer, BearWickBuffer);

      ApplySegmentGaps(ResistanceBuffer, rates_total);
      ApplySegmentGaps(SupportBuffer,    rates_total);

      g_lastRatesTotal = rates_total;
      g_lastHtfBars    = -1;
      return(rates_total);
   }

   //================================================================
   // LOCKED HIGHER/OTHER TIMEFRAME (project onto current chart)
   //================================================================
   int htfBars = Bars(_Symbol, selPeriod);

   // recompute on new current bar OR when a new locked-tf bar appears
   if(prev_calculated > 0 &&
      rates_total == g_lastRatesTotal &&
      htfBars     == g_lastHtfBars)
      return(rates_total);

   if(htfBars < LeftBars + RightBars + 2)
   {
      // locked timeframe history not ready yet -- keep chart clean, retry later
      BlankAllBuffers(rates_total);
      return(0);
   }

   int copyCount = (MaxBarsBack > 0)
                   ? MathMin(htfBars, MaxBarsBack + LeftBars + RightBars + 5)
                   : htfBars;

   double   ho[], hh[], hl[], hc[];
   long     hv[];
   datetime ht[];
   ArraySetAsSeries(ho, false); ArraySetAsSeries(hh, false);
   ArraySetAsSeries(hl, false); ArraySetAsSeries(hc, false);
   ArraySetAsSeries(hv, false); ArraySetAsSeries(ht, false);

   int gotO = CopyOpen (_Symbol, selPeriod, 0, copyCount, ho);
   int gotH = CopyHigh (_Symbol, selPeriod, 0, copyCount, hh);
   int gotL = CopyLow  (_Symbol, selPeriod, 0, copyCount, hl);
   int gotC = CopyClose(_Symbol, selPeriod, 0, copyCount, hc);
   int gotV = CopyTickVolume(_Symbol, selPeriod, 0, copyCount, hv);
   int gotT = CopyTime (_Symbol, selPeriod, 0, copyCount, ht);

   int htfTotal = gotO;
   if(gotO <= 0 || gotH != gotO || gotL != gotO || gotC != gotO ||
      gotV != gotO || gotT != gotO || htfTotal < LeftBars + RightBars + 2)
   {
      // partial/failed copy -- retry on next tick without leaving stale data
      BlankAllBuffers(rates_total);
      return(0);
   }

   // compute S/R + arrows on the locked timeframe series
   double htfRes[], htfSup[], htfBU[], htfBD[], htfBW[], htfBrW[];
   ArrayResize(htfRes, htfTotal); ArrayResize(htfSup, htfTotal);
   ArrayResize(htfBU,  htfTotal); ArrayResize(htfBD,  htfTotal);
   ArrayResize(htfBW,  htfTotal); ArrayResize(htfBrW, htfTotal);

   ComputeSeries(htfTotal, ho, hh, hl, hc, hv,
                 LeftBars, RightBars, VolumeThreshold, MaxBarsBack,
                 ShowBreakArrows, ShowWickArrows,
                 htfRes, htfSup, htfBU, htfBD, htfBW, htfBrW);

   // ---- project locked-tf results onto the current chart by bar time ----
   ArraySetAsSeries(time, false);
   BlankAllBuffers(rates_total);

   int m = 0;       // current locked-tf bar index
   int lastM = -1;  // to detect the first current bar of each locked-tf bar
   for(int i = 0; i < rates_total; i++)
   {
      // advance m so ht[m] is the locked-tf bar containing time[i]
      while(m + 1 < htfTotal && ht[m+1] <= time[i]) m++;

      if(ht[m] > time[i])
         continue; // current bar older than earliest locked-tf bar copied

      // lines: the level active on the locked-tf bar that contains this bar
      ResistanceBuffer[i] = htfRes[m];
      SupportBuffer[i]    = htfSup[m];

      // arrows: place once, on the first current bar of each locked-tf bar
      if(m != lastM)
      {
         if(htfBU[m]  != EMPTY_VALUE) BreakUpBuffer[i]   = htfBU[m];
         if(htfBD[m]  != EMPTY_VALUE) BreakDownBuffer[i] = htfBD[m];
         if(htfBW[m]  != EMPTY_VALUE) BullWickBuffer[i]  = htfBW[m];
         if(htfBrW[m] != EMPTY_VALUE) BearWickBuffer[i]  = htfBrW[m];
         lastM = m;
      }
   }

   ApplySegmentGaps(ResistanceBuffer, rates_total);
   ApplySegmentGaps(SupportBuffer,    rates_total);

   g_lastRatesTotal = rates_total;
   g_lastHtfBars    = htfBars;
   return(rates_total);
}
//+------------------------------------------------------------------+