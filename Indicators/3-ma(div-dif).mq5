//+------------------------------------------------------------------+
//|                                                    Div-MA.mq5    |
//|                                  Copyright 2026, AI Assistant    |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property indicator_chart_window

#property indicator_buffers 4
#property indicator_plots   4

// --- Plot 1..4: The MA Lines (Level 1..4) ---
#property indicator_label1  "MA L1"
#property indicator_type1   DRAW_LINE

#property indicator_label2  "MA L2"
#property indicator_type2   DRAW_LINE

#property indicator_label3  "MA L3"
#property indicator_type3   DRAW_LINE

#property indicator_label4  "MA L4"
#property indicator_type4   DRAW_LINE

// --- Input Parameters ---
input group "--- LEVEL 1 ---"
input bool   ShowMA_L1       = true;
input int    MAPeriod_L1     = 5;  //(8,21,55)
input color  MAColor_L1      = clrLime;
input int    MAThickness_L1  = 1;
input ENUM_LINE_STYLE MAStyle_L1 = STYLE_SOLID;
input int    MATransp_L1     = 25;  // Transparency % (0=solid, 100=invisible)

input group "--- LEVEL 2 ---"
input bool   ShowMA_L2       = true;
input int    MAPeriod_L2     = 13;
input color  MAColor_L2      = clrYellow;
input int    MAThickness_L2  = 1;
input ENUM_LINE_STYLE MAStyle_L2 = STYLE_SOLID;
input int    MATransp_L2     = 25;  // Transparency % (0=solid, 100=invisible)

input group "--- LEVEL 3 ---"
input bool   ShowMA_L3       = true;
input int    MAPeriod_L3     = 34;
input color  MAColor_L3      = clrRed;
input int    MAThickness_L3  = 1;
input ENUM_LINE_STYLE MAStyle_L3 = STYLE_SOLID;
input int    MATransp_L3     = 0;  // Transparency % (0=solid, 100=invisible)

input group "--- LEVEL 4 ---"
input bool   ShowMA_L4       = true;
input int    MAPeriod_L4     = 200;
input color  MAColor_L4      = clrWhite;
input int    MAThickness_L4  = 1;
input ENUM_LINE_STYLE MAStyle_L4 = STYLE_DOT;
input int    MATransp_L4     = 0;  // Transparency % (0=solid, 100=invisible)

input group "--- GLOBAL MA ---"
input ENUM_MA_METHOD     MAMethod = MODE_EMA;      // MA method
input ENUM_APPLIED_PRICE MAPrice  = PRICE_CLOSE;   // Applied price
input int                MAShift  = 0;             // MA shift (bars)

input group "--- VISIBILITY ---"
// PERIOD_CURRENT = MAs show on every chart timeframe.
// Any specific timeframe (e.g. M15) = MAs are drawn ONLY when the chart
// is on that timeframe; on every other timeframe the indicator goes
// fully dormant (no handles, no calculation, no lines) -- feather-light.
input ENUM_TIMEFRAMES    VisibleTimeframe = PERIOD_CURRENT;

input group "--- FAKE NAME ---"
input bool   UseFakeName = true;
input string FakeName    = "Loading..";

// --- Buffers & Global Variables ---
double MABuffer1[];
double MABuffer2[];
double MABuffer3[];
double MABuffer4[];

#define MA_LEVELS 4

int    maHandle[MA_LEVELS];   // INVALID_HANDLE for disabled levels
bool   maEnabled[MA_LEVELS];
int    maPeriod[MA_LEVELS];
string indicatorName;

// Whether the indicator is allowed to show on the CURRENT chart timeframe
// (see VisibleTimeframe above). Decided once in OnInit -- switching the
// chart timeframe always triggers a full re-init, so this never goes stale.
bool   g_visibleHere = false;

// --- Debug/error logging state -------------------------------------------
// Each flag makes sure a given failure is only printed to the Experts log
// ONCE while it persists, instead of spamming it every tick/bar. The flag
// resets back to false as soon as the underlying condition clears, so a
// genuinely new failure later on still gets reported. One flag per level,
// since each level has its own independent handle.
bool g_loggedNoBars[MA_LEVELS];
bool g_loggedCopyFail[MA_LEVELS];

// The incremental CopyBuffer below is only valid AFTER one full-history
// copy has succeeded. This can't be inferred from prev_calculated alone,
// because OnCalculate returns rates_total even on early warm-up ticks
// where the copy failed -- so prev_calculated may already be large when
// the handle finally becomes readable. One flag per level/handle.
bool g_fullCopyDone[MA_LEVELS];

//==================================================================
// HANDLE WARM-UP GRACE
//==================================================================
// Right after attach/reinit (timeframe switch, input change), the
// terminal may not have finished calculating the MA handles yet, so
// BarsCalculated()/CopyBuffer() can transiently fail even though the
// data is fine a moment later. That's a normal transient, not a
// failure: the next tick retries and succeeds. During a short grace
// window after init, this is retried silently; only if it persists
// past the window is it logged.
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
}

//+------------------------------------------------------------------+
//| Fake transparency: blend a color toward the chart background.    |
//| Buffer plots can't do real alpha (PLOT_LINE_COLOR ignores it),   |
//| so the line color is pre-mixed with the background color -- the  |
//| same trick the AutoFib suite uses for its level fills.           |
//| 0 = original solid color, 100 = identical to background.         |
//| NOTE: computed once in OnInit; if the chart background color is  |
//| changed afterwards, re-attach / switch TF to re-blend.           |
//+------------------------------------------------------------------+
color BlendWithBackground(color c, int transparencyPct)
{
   long bg;
   if(!ChartGetInteger(0, CHART_COLOR_BACKGROUND, 0, bg))
      bg = (long)clrBlack;
   int bgR = (int)(bg & 0xFF);
   int bgG = (int)((bg >> 8) & 0xFF);
   int bgB = (int)((bg >> 16) & 0xFF);

   int cR = (int)(c & 0xFF);
   int cG = (int)((c >> 8) & 0xFF);
   int cB = (int)((c >> 16) & 0xFF);

   double t = MathMax(0, MathMin(100, transparencyPct)) / 100.0;
   int r = (int)MathRound(cR*(1.0-t) + bgR*t);
   int g = (int)MathRound(cG*(1.0-t) + bgG*t);
   int b = (int)MathRound(cB*(1.0-t) + bgB*t);
   return (color)(r | (g<<8) | (b<<16));
}

//+------------------------------------------------------------------+
//| Indicator Initialization                                         |
//+------------------------------------------------------------------+
int OnInit()
{
   maEnabled[0] = ShowMA_L1;  maPeriod[0] = MAPeriod_L1;
   maEnabled[1] = ShowMA_L2;  maPeriod[1] = MAPeriod_L2;
   maEnabled[2] = ShowMA_L3;  maPeriod[2] = MAPeriod_L3;
   maEnabled[3] = ShowMA_L4;  maPeriod[3] = MAPeriod_L4;

   for(int L = 0; L < MA_LEVELS; L++)
   {
      maHandle[L]         = INVALID_HANDLE;
      g_loggedNoBars[L]   = false;
      g_loggedCopyFail[L] = false;
      g_fullCopyDone[L]   = false;
   }

   // --- Visibility filter: show only on the chosen chart timeframe ---
   g_visibleHere = (VisibleTimeframe == PERIOD_CURRENT || VisibleTimeframe == _Period);

   // Set Identifiers
   indicatorName =
   StringFormat("Div-MA( %d, %d, %d, %d )",
                maPeriod[0],
                maPeriod[1],
                maPeriod[2],
                maPeriod[3]);

if(UseFakeName)
{
   IndicatorSetString(INDICATOR_SHORTNAME, FakeName);

   PlotIndexSetString(0, PLOT_LABEL, FakeName);
   PlotIndexSetString(1, PLOT_LABEL, FakeName);
   PlotIndexSetString(2, PLOT_LABEL, FakeName);
   PlotIndexSetString(3, PLOT_LABEL, FakeName);
}
else
{
   IndicatorSetString(INDICATOR_SHORTNAME, indicatorName);

   PlotIndexSetString(0, PLOT_LABEL, "MA " + IntegerToString(maPeriod[0]));
   PlotIndexSetString(1, PLOT_LABEL, "MA " + IntegerToString(maPeriod[1]));
   PlotIndexSetString(2, PLOT_LABEL, "MA " + IntegerToString(maPeriod[2]));
   PlotIndexSetString(3, PLOT_LABEL, "MA " + IntegerToString(maPeriod[3]));
}

   // Bind Data Buffers
   SetIndexBuffer(0, MABuffer1, INDICATOR_DATA);
   SetIndexBuffer(1, MABuffer2, INDICATOR_DATA);
   SetIndexBuffer(2, MABuffer3, INDICATOR_DATA);
   SetIndexBuffer(3, MABuffer4, INDICATOR_DATA);

// Configure UI Property Rules Dynamically
PlotIndexSetInteger(0, PLOT_LINE_COLOR, BlendWithBackground(MAColor_L1, MATransp_L1));
PlotIndexSetInteger(0, PLOT_LINE_WIDTH, MAThickness_L1);
PlotIndexSetInteger(0, PLOT_LINE_STYLE, MAStyle_L1);

PlotIndexSetInteger(1, PLOT_LINE_COLOR, BlendWithBackground(MAColor_L2, MATransp_L2));
PlotIndexSetInteger(1, PLOT_LINE_WIDTH, MAThickness_L2);
PlotIndexSetInteger(1, PLOT_LINE_STYLE, MAStyle_L2);

PlotIndexSetInteger(2, PLOT_LINE_COLOR, BlendWithBackground(MAColor_L3, MATransp_L3));
PlotIndexSetInteger(2, PLOT_LINE_WIDTH, MAThickness_L3);
PlotIndexSetInteger(2, PLOT_LINE_STYLE, MAStyle_L3);

PlotIndexSetInteger(3, PLOT_LINE_COLOR, BlendWithBackground(MAColor_L4, MATransp_L4));
PlotIndexSetInteger(3, PLOT_LINE_WIDTH, MAThickness_L4);
PlotIndexSetInteger(3, PLOT_LINE_STYLE, MAStyle_L4);

   // One toggle per level: false = completely off (no handle, no
   // calculation, no line, zero cost). The visibility filter overrides
   // everything: on a non-matching chart timeframe ALL levels go dark.
   for(int L = 0; L < MA_LEVELS; L++)
   {
      bool drawIt = g_visibleHere && maEnabled[L];

      PlotIndexSetInteger(L, PLOT_DRAW_TYPE, drawIt ? DRAW_LINE : DRAW_NONE);

      // Don't draw over the MA's own warm-up region.
      PlotIndexSetInteger(L, PLOT_DRAW_BEGIN, maPeriod[L] + MAShift);

      // Hide Moving Decimal Numbers in Top-Left / Data Window
      PlotIndexSetInteger(L, PLOT_SHOW_DATA, false);

      // Gaps in disabled levels shouldn't connect across.
      PlotIndexSetDouble(L, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   }

   // --- Lock Decimal Precision to the symbol's digits ---
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   // Initialize Core Mathematical Engine Handles (only for enabled levels,
   // and only if this chart timeframe passes the visibility filter --
   // otherwise the indicator stays fully dormant and costs nothing).
   if(g_visibleHere)
   {
      for(int L = 0; L < MA_LEVELS; L++)
      {
         if(!maEnabled[L])
            continue;

         maHandle[L] = iMA(_Symbol, _Period, maPeriod[L], MAShift, MAMethod, MAPrice);

         if(maHandle[L] == INVALID_HANDLE)
         {
            Print("Div-MA ERROR: failed to create internal MA handle for Level ",
                  L + 1, " (period ", maPeriod[L], "), error code ", GetLastError(), ".");
            return(INIT_FAILED);
         }
      }
   }

   // Start the warm-up grace clock (see StillWarmingUp above).
   g_initTick = GetTickCount();

   // --- Force Instant Graphical Refresh ---
   // This forces MT5 to clear its memory cache and redraw the indicator completely fresh
   ChartRedraw(0);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Indicator Deinitialization                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int L = 0; L < MA_LEVELS; L++)
   {
      if(maHandle[L] != INVALID_HANDLE)
         IndicatorRelease(maHandle[L]);
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Copy one level's MA data with the same incremental + log-once    |
//| pattern used by Div-Stoch / Div-RSI                              |
//+------------------------------------------------------------------+
bool UpdateLevel(const int L,
                 double &buffer[],
                 const int rates_total,
                 const int prev_calculated)
{
   // Copy MA data
   int barsReady = BarsCalculated(maHandle[L]);
   if(barsReady < 0 && !StillWarmingUp() && !g_loggedNoBars[L])
   {
      Print("Div-MA ERROR: BarsCalculated() failed for Level ", L + 1,
            ", error code ", GetLastError(), ".");
      g_loggedNoBars[L] = true;
   }
   else if(barsReady == 0 && !StillWarmingUp() && !g_loggedNoBars[L])
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window (e.g. handle never finishing for this symbol/TF).
      // Worth one soft report so this doesn't stay invisible forever --
      // without this, a permanently-stuck handle would never be reported.
      Print("Div-MA: Level ", L + 1, " MA data isn't ready yet after warm-up. Will keep retrying..");
      g_loggedNoBars[L] = true;
   }
   else if(barsReady > 0)
      g_loggedNoBars[L] = false; // only reset once truly recovered, not while still stuck at 0

   if(barsReady <= 0)
      return false;

   // --- Force buffer into chronological (non-series) order ---
   // Keeps every level's buffer aligned the same way as the other
   // indicators in this suite; must be set BEFORE CopyBuffer so the
   // copy itself fills in the correct order.
   ArraySetAsSeries(buffer, false);

   // --- Incremental copy (modern MQL5 pattern) ---
   // Indicator buffers persist between calls and are auto-shifted by the
   // terminal on new bars, so after the FIRST full copy only the bars
   // that actually changed since prev_calculated need re-copying: the
   // still-forming bar plus one closed bar of safety margin.
   int toCopy;
   if(!g_fullCopyDone[L] || prev_calculated <= 0 || prev_calculated > rates_total)
      toCopy = rates_total;                       // first successful call / history reload
   else
      toCopy = rates_total - prev_calculated + 2; // new bars + forming bar + margin
   if(toCopy > rates_total)
      toCopy = rates_total;

   ResetLastError();

   int copied =
      CopyBuffer(maHandle[L],
                 0,
                 0,
                 toCopy,
                 buffer);

   bool copyHasError = (copied < 0);
   bool copyNotReady = (!copyHasError && copied == 0);

   if(copyHasError && !StillWarmingUp() && !g_loggedCopyFail[L])
   {
      Print("Div-MA ERROR: CopyBuffer() failed for Level ", L + 1,
            " (copied=", copied, "), error code ", GetLastError(), ".");
      g_loggedCopyFail[L] = true;
   }
   else if(copyNotReady && !StillWarmingUp() && !g_loggedCopyFail[L])
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window -- worth one soft report so this doesn't stay
      // invisible forever.
      Print("Div-MA: Level ", L + 1, " MA data isn't ready yet after warm-up. Will keep retrying..");
      g_loggedCopyFail[L] = true;
   }
   else if(copied > 0)
      g_loggedCopyFail[L] = false; // only reset once truly recovered

   if(copied <= 0)
      return false;

   // Full-history copy has succeeded at least once -- from now on the
   // cheap incremental tail copy above is sufficient.
   if(toCopy >= rates_total)
      g_fullCopyDone[L] = true;

   return true;
}

//+------------------------------------------------------------------+
//| Indicator Calculation                                            |
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
   // Visibility filter says this chart timeframe is off-limits:
   // stay fully dormant. (Chart TF switches always re-init, so this
   // decision never goes stale.)
   if(!g_visibleHere)
      return(rates_total);

   // NOTE: no force-refresh machinery here, by design. This indicator is
   // pure buffer plots: buffers persist and the terminal repaints them
   // natively, so there is nothing a periodic refresh could restore.
   if(maEnabled[0]) UpdateLevel(0, MABuffer1, rates_total, prev_calculated);
   if(maEnabled[1]) UpdateLevel(1, MABuffer2, rates_total, prev_calculated);
   if(maEnabled[2]) UpdateLevel(2, MABuffer3, rates_total, prev_calculated);
   if(maEnabled[3]) UpdateLevel(3, MABuffer4, rates_total, prev_calculated);

   return(rates_total);
}
//+------------------------------------------------------------------+