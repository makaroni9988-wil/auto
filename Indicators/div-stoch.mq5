//+------------------------------------------------------------------+
//|                                                 Div-Stoch.mq5    |
//|                                  Copyright 2026, AI Assistant    |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property indicator_separate_window

#property indicator_buffers 2
#property indicator_plots   2

// --- Plot 1: The %K Line ---
#property indicator_label1  "Main %K"
#property indicator_type1   DRAW_LINE

// --- Plot 2: The %D Line ---
#property indicator_label2  "Signal %D"
#property indicator_type2   DRAW_LINE

enum STOCH_SHOW_MODE
{
   D_Only  = 0,   // D Line Only
   K_Only  = 1,   // K Line Only
   K_and_D = 2    // K and D Lines
};

enum ACTIVE_LEVEL
{
   Level_1 = 0,
   Level_2 = 1,
   Level_3 = 2,
   Level_4 = 3
};

// --- Input Parameters ---
input group "--- ACTIVE LEVEL ---"
input ACTIVE_LEVEL ActiveLevel = Level_1;

input group "--- LEVEL 1 ---"
input bool   UseFakeTopLeftLabel_L1 = true;
input string FakeTopLeftLabel_L1    = "ERROR >.<";
input int    KPeriod_L1             = 5;  //9
input int    DPeriod_L1             = 3;  //3
input int    Slowing_L1             = 3;  //1

input group "--- LEVEL 2 ---"
input bool   UseFakeTopLeftLabel_L2 = true;
input string FakeTopLeftLabel_L2    = "Loading..";
input int    KPeriod_L2             = 14;
input int    DPeriod_L2             = 3;
input int    Slowing_L2             = 1;

input group "--- LEVEL 3 ---"
input bool   UseFakeTopLeftLabel_L3 = true;
input string FakeTopLeftLabel_L3    = "Loading..";
input int    KPeriod_L3             = 40;
input int    DPeriod_L3             = 4;
input int    Slowing_L3             = 1;

input group "--- LEVEL 4 ---"
input bool   UseFakeTopLeftLabel_L4 = true;
input string FakeTopLeftLabel_L4    = "Loading..";
input int    KPeriod_L4             = 60;
input int    DPeriod_L4             = 10;
input int    Slowing_L4             = 1;

input group "--- GLOBAL STOCH ---"
input ENUM_MA_METHOD    StochMethod    = MODE_SMA;
input ENUM_STO_PRICE    StochPrice     = STO_LOWHIGH;

input STOCH_SHOW_MODE   ShowStochLine  = K_and_D;

input color DLineColor      = clrSilver;
input int   DLineThickness  = 1;
input ENUM_LINE_STYLE DLineStyle = STYLE_DOT;

input color KLineColor      = clrGold;
input int   KLineThickness  = 1;
input ENUM_LINE_STYLE KLineStyle = STYLE_SOLID;

input group  "--- CUSTOM LEVEL SETTINGS ---"

input color  LevelColor          = clrGray;    // Color for all level lines
input ENUM_LINE_STYLE LevelStyle = STYLE_DOT;  // Level line style (proper dropdown)
// One Single Input For All Levels (Up to 6 or more!)
input string CustomLevels        = "50";       // Separate levels with a semicolon (e.g. 20;50;80)

input group "--- DIVERGENCE SETTINGS ---"

input bool   EnableDivergence         = true;

// Divergence calculated from %D line only
input bool   RequireOBOSForDivergence = true;

input double BullDivMaxLevel          = 30.0;
input double BearDivMinLevel          = 70.0;

input int    DivergenceLookbackBars   = 100;
input int    PivotLeftBars            = 2;
input int    PivotRightBars           = 2;

input int    MaxBullDivergenceLines   = 2;
input int    MaxBearDivergenceLines   = 2;

input bool   DrawStochDivergence      = true;
input bool   DrawPriceDivergence      = false;

input color  BullDivColor             = clrLime;
input int    BullDivThickness         = 2;

input color  BearDivColor             = clrRed;
input int    BearDivThickness         = 2;

input group "--- REFRESH SETTINGS ---"
input int    InpRefreshSeconds        = 30;    // Force refresh interval in seconds (0 = only on new bars)

// --- Buffers & Global Variables ---
double KBuffer[];
double DBuffer[];
int    stochHandle;
string subwindowName;
string indicatorName; 

datetime g_lastDivergenceBar = 0;
datetime g_lastForceRefresh  = 0;  // Track last force refresh time

// --- Debug/error logging state -------------------------------------------
// Each flag makes sure a given failure is only printed to the Experts log
// ONCE while it persists, instead of spamming it every tick/bar. The flag
// resets back to false as soon as the underlying condition clears, so a
// genuinely new failure later on still gets reported.
bool g_loggedNoBars      = false;
bool g_loggedCopyFail    = false;

// The incremental CopyBuffer below is only valid AFTER one full-history
// copy has succeeded. This can't be inferred from prev_calculated alone,
// because OnCalculate returns rates_total even on early warm-up ticks
// where the copy failed -- so prev_calculated may already be large when
// the handle finally becomes readable.
bool g_fullCopyDone      = false;

//==================================================================
// HANDLE WARM-UP GRACE
//==================================================================
// Right after attach/reinit (timeframe switch, input change), the
// terminal may not have finished calculating the Stochastic handle
// yet, so BarsCalculated()/CopyBuffer() can transiently fail even
// though the data is fine a moment later. That's a normal transient,
// not a failure: the next tick retries and succeeds. During a short
// grace window after init, this is retried silently; only if it
// persists past the window is it logged.
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
}

// --- a single divergence "run": one anchor pivot plus the newest pivot
// that extended it while passing the OB/OS filter. Runs are collected
// first, then only the newest N per direction are actually drawn -- this
// is what prevents the old draw-all-then-prune churn (see
// DrawDivergenceRuns below).
struct DivRun
{
   int anchor; // index of the run's anchor pivot
   int last;   // index of the newest pivot that passed the OB/OS filter
};

// Every divergence line currently drawn by this indicator, per category,
// with its FULL geometry (not just the name) so the 1-second self-heal
// timer can REBUILD a wiped line from state (suite standard) -- no rescan
// needed. After every rescan these are synced against the freshly-drawn
// set: anything no longer in the newest-N runs gets deleted from the chart.
struct DivLine
{
   string   name;
   datetime t1;  double p1;
   datetime t2;  double p2;
   color    clr;
   int      width;
   int      window;
};
DivLine g_bearDivLines[];
DivLine g_priceBearDivLines[];
DivLine g_bullDivLines[];
DivLine g_priceBullDivLines[];

// Parsed custom levels (parsed ONCE in OnInit -- see ParseCustomLevels).
double g_levelValue[];
int    g_levelCount = 0;

bool   UseFakeTopLeftLabel;
string FakeTopLeftLabel;
int    KPeriod;
int    DPeriod;
int    Slowing;

//+------------------------------------------------------------------+
//| Indicator Initialization                                         |
//+------------------------------------------------------------------+
int OnInit()
{
   switch(ActiveLevel)
   {
      case Level_1:
         UseFakeTopLeftLabel   = UseFakeTopLeftLabel_L1;
         FakeTopLeftLabel      = FakeTopLeftLabel_L1;
         KPeriod               = KPeriod_L1;
         DPeriod               = DPeriod_L1;
         Slowing               = Slowing_L1;
         break;
      case Level_2:
         UseFakeTopLeftLabel   = UseFakeTopLeftLabel_L2;
         FakeTopLeftLabel      = FakeTopLeftLabel_L2;
         KPeriod               = KPeriod_L2;
         DPeriod               = DPeriod_L2;
         Slowing               = Slowing_L2;
         break;
      case Level_3:
         UseFakeTopLeftLabel   = UseFakeTopLeftLabel_L3;
         FakeTopLeftLabel      = FakeTopLeftLabel_L3;
         KPeriod               = KPeriod_L3;
         DPeriod               = DPeriod_L3;
         Slowing               = Slowing_L3;
         break;
      case Level_4:
         UseFakeTopLeftLabel   = UseFakeTopLeftLabel_L4;
         FakeTopLeftLabel      = FakeTopLeftLabel_L4;
         KPeriod               = KPeriod_L4;
         DPeriod               = DPeriod_L4;
         Slowing               = Slowing_L4;
         break;
   }

   // Set Identifiers
   indicatorName =
   StringFormat("Div-Stoch( %d, %d, %d )",
                KPeriod,
                DPeriod,
                Slowing);
                
if(UseFakeTopLeftLabel)
{
   IndicatorSetString(INDICATOR_SHORTNAME, FakeTopLeftLabel);

   PlotIndexSetString(0, PLOT_LABEL, FakeTopLeftLabel);
   PlotIndexSetString(1, PLOT_LABEL, FakeTopLeftLabel);
}
else
{
   IndicatorSetString(INDICATOR_SHORTNAME, indicatorName);

   PlotIndexSetString(0, PLOT_LABEL, "Main %K");
   PlotIndexSetString(1, PLOT_LABEL, "Signal %D");
}
   subwindowName =
   StringFormat("DivStoch_%d_%d_%d_%d_%d",
                KPeriod,
                DPeriod,
                Slowing,
                (int)StochMethod,
                (int)StochPrice);

   // Bind Data Buffers 
   SetIndexBuffer(0, KBuffer, INDICATOR_DATA); 
   SetIndexBuffer(1, DBuffer, INDICATOR_DATA);

// Configure UI Property Rules Dynamically
PlotIndexSetInteger(0, PLOT_LINE_COLOR, KLineColor);
PlotIndexSetInteger(0, PLOT_LINE_WIDTH, KLineThickness);
PlotIndexSetInteger(0, PLOT_LINE_STYLE, KLineStyle);

PlotIndexSetInteger(1, PLOT_LINE_COLOR, DLineColor);
PlotIndexSetInteger(1, PLOT_LINE_WIDTH, DLineThickness);
PlotIndexSetInteger(1, PLOT_LINE_STYLE, DLineStyle);

if(ShowStochLine == D_Only)
{
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
   PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_LINE);
}
else if(ShowStochLine == K_Only)
{
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_NONE);
}
else if(ShowStochLine == K_and_D)
{
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_LINE);
}
   
   // Hide Moving Decimal Numbers in Top-Left Label
   PlotIndexSetInteger(0, PLOT_SHOW_DATA, false);
   PlotIndexSetInteger(1, PLOT_SHOW_DATA, false);  

   // --- Lock Decimal Precision To 2 Places (.00) ---
   // This forces MT5 to format all underlying window readouts to exactly 2 digits
   IndicatorSetInteger(INDICATOR_DIGITS, 2);

   // Force the window frame constraints to lock at 0 and 100 immediately on attachment.
   // This stops the indicator lines and custom levels from vanishing or showing blank data rows.
   IndicatorSetDouble(INDICATOR_MINIMUM, 0.0);
   IndicatorSetDouble(INDICATOR_MAXIMUM, 100.0);

   // Initialize Core Mathematical Engine Handle
   stochHandle = iStochastic(_Symbol, _Period, KPeriod, DPeriod, Slowing, StochMethod, StochPrice);
   
   if(stochHandle == INVALID_HANDLE)
   {
      Print("Div-Stoch ERROR: failed to create internal Stochastic handle, error code ", GetLastError(), ".");
      return(INIT_FAILED);
   }

   // Wipes out old parameter lines when inputs are modified by the user
   ObjectsDeleteAll(0, subwindowName);

   // Keep the tracked-line arrays in sync with the objects we just wiped.
   ArrayFree(g_bearDivLines);
   ArrayFree(g_priceBearDivLines);
   ArrayFree(g_bullDivLines);
   ArrayFree(g_priceBullDivLines);

   // Parse the CustomLevels input ONCE (see ParseCustomLevels).
   ParseCustomLevels();

   // Start the warm-up grace clock (see StillWarmingUp above).
   g_initTick = GetTickCount();
   g_fullCopyDone = false;

   // 1-second self-heal timer (suite standard, matches Sub-/Float-Chart).
   // Ticks alone can't restore wiped level/divergence lines on a dead or
   // closed market -- the timer rebuilds them from stored state (OnTimer)
   // and does nothing when everything is present.
   EventSetTimer(1);

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
   EventKillTimer();

   ObjectsDeleteAll(0, subwindowName);

   if(stochHandle != INVALID_HANDLE)
      IndicatorRelease(stochHandle);

   ChartRedraw(0);
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
   // Find the subwindow dynamically
   int subWindow = ChartWindowFind();

   if(subWindow < 0)
      return(rates_total);

// --- Refresh custom levels when missing or on new candle or force refresh ---
// NOTE: time[] is in chronological (non-series) order here, so the
// CURRENT/most recent bar is at index [rates_total-1], NOT index [0].
// index [0] is the OLDEST bar in history and almost never changes,
// which is why this used to only "refresh" after a timeframe change
// (which forces a full re-init).
static datetime lastLevelCheckBar = 0;

datetime currentBarTime = time[rates_total - 1];

// Check if force refresh is needed (for market close or missing objects)
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

bool checkLevels = (currentBarTime != lastLevelCheckBar) || forceRefresh;

bool needRedraw = false;

if(checkLevels)
{
   needRedraw = true;
   lastLevelCheckBar = currentBarTime;
   EnsureLevels(subWindow);
}

   // Copy stochastic data
   int barsReady = BarsCalculated(stochHandle);
   if(barsReady < 0 && !StillWarmingUp() && !g_loggedNoBars)
   {
      Print("Div-Stoch ERROR: BarsCalculated(stochHandle) failed, error code ", GetLastError(), ".");
      g_loggedNoBars = true;
   }
   else if(barsReady == 0 && !StillWarmingUp() && !g_loggedNoBars)
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window (e.g. handle never finishing for this symbol/TF).
      // Worth one soft report so this doesn't stay invisible forever --
      // without this, a permanently-stuck handle would never be reported.
      Print("Div-Stoch: stochastic data isn't ready yet after warm-up. Will keep retrying..");
      g_loggedNoBars = true;
   }
   else if(barsReady > 0)
      g_loggedNoBars = false; // only reset once truly recovered, not while still stuck at 0

   if(barsReady <= 0)
      return(rates_total);

   // --- Force buffers into the SAME direction as time[]/high[]/low[] ---
   // SetIndexBuffer() auto-marks KBuffer/DBuffer as a timeseries
   // (index 0 = newest bar), but time[]/high[]/low[] here are in
   // chronological order (index 0 = oldest bar) since ArraySetAsSeries
   // was never called on them. Without this, DBuffer[i] and time[i]
   // end up referring to two DIFFERENT bars, silently corrupting every
   // pivot/divergence comparison below. Must be set BEFORE CopyBuffer
   // so the copy itself fills in the correct order.
   ArraySetAsSeries(KBuffer, false);
   ArraySetAsSeries(DBuffer, false);

   // --- Incremental copy (modern MQL5 pattern) ---
   // Indicator buffers persist between calls and are auto-shifted by the
   // terminal on new bars, so after the FIRST full copy only the bars
   // that actually changed since prev_calculated need re-copying: the
   // still-forming bar plus one closed bar of safety margin. The old
   // code copied the entire history (rates_total bars, potentially
   // 100k+) from the Stochastic handle on EVERY SINGLE TICK.
   int toCopy;
   if(!g_fullCopyDone || prev_calculated <= 0 || prev_calculated > rates_total)
      toCopy = rates_total;                       // first successful call / history reload
   else
      toCopy = rates_total - prev_calculated + 2; // new bars + forming bar + margin
   if(toCopy > rates_total)
      toCopy = rates_total;

   ResetLastError();

   int copiedK =
      CopyBuffer(stochHandle,
                 0,
                 0,
                 toCopy,
                 KBuffer);

   int copiedD =
      CopyBuffer(stochHandle,
                 1,
                 0,
                 toCopy,
                 DBuffer);

   bool copyHasError = (copiedK < 0 || copiedD < 0);
   bool copyNotReady = (!copyHasError && (copiedK <= 0 || copiedD <= 0));

   if(copyHasError && !StillWarmingUp() && !g_loggedCopyFail)
   {
      Print("Div-Stoch ERROR: CopyBuffer() failed for K/D (copiedK=", copiedK,
            ", copiedD=", copiedD, "), error code ", GetLastError(), ".");
      g_loggedCopyFail = true;
   }
   else if(copyNotReady && !StillWarmingUp() && !g_loggedCopyFail)
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window -- worth one soft report so this doesn't stay
      // invisible forever.
      Print("Div-Stoch: K/D data isn't ready yet after warm-up. Will keep retrying..");
      g_loggedCopyFail = true;
   }
   else if(copiedK > 0 && copiedD > 0)
      g_loggedCopyFail = false; // only reset once truly recovered

   if(copiedK <= 0 || copiedD <= 0)
      return(rates_total);

   // Full-history copy has succeeded at least once -- from now on the
   // cheap incremental tail copy above is sufficient.
   if(toCopy >= rates_total)
      g_fullCopyDone = true;

   if(EnableDivergence)
   {
      // Rescan on new bar / force refresh. Wiped-line recovery is NOT done
      // here anymore: the 1s heal timer restores from stored geometry, so
      // the tick path no longer pays ObjectFind checks on every tick.
      if(currentBarTime != g_lastDivergenceBar || forceRefresh)
      {
         g_lastDivergenceBar = currentBarTime;
         CheckDivergence(rates_total, time, high, low, subWindow);
         needRedraw = true;
      }
   }

   // Only force a repaint when we actually drew/moved/deleted something this
   // call (new bar closed -> levels checked and/or divergence rescanned).
   // On every other tick this block is skipped entirely, so there's no
   // added cost on the high-frequency path.
   if(needRedraw)
      ChartRedraw(0);

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Parse the CustomLevels input into g_levelValue[]. Runs ONCE in   |
//| OnInit: the input string can't change without a full reinit, so  |
//| re-splitting it every new bar was wasted work -- and the 1s heal |
//| timer needs the parsed values anyway.                            |
//+------------------------------------------------------------------+
void ParseCustomLevels(void)
{
   g_levelCount = 0;
   ArrayResize(g_levelValue, 0);

   string levelsArray[];
   int totalFound = StringSplit(CustomLevels, ';', levelsArray);

   // Safety cap
   int maxLevels = (totalFound > 6) ? 6 : totalFound;

   for(int i = 0; i < maxLevels; i++)
   {
      string trimmedVal = levelsArray[i];
      StringTrimLeft(trimmedVal);
      StringTrimRight(trimmedVal);

      // Skip empty entries (e.g. an empty input string, or ";;").
      if(StringLen(trimmedVal) == 0)
         continue;

      double levelPrice = StringToDouble(trimmedVal);

      // Bounded 0-100 oscillator: out-of-range levels are ignored.
      if(levelPrice < 0 || levelPrice > 100)
         continue;

      ArrayResize(g_levelValue, g_levelCount + 1);
      g_levelValue[g_levelCount] = levelPrice;
      g_levelCount++;
   }
}

//+------------------------------------------------------------------+
//| Create any missing custom level line from the parsed values.     |
//| Levels are stateless (pure inputs), so this can recreate them at |
//| any time -- from the per-bar path or the 1s heal timer. Returns  |
//| true when something was actually (re)created.                    |
//+------------------------------------------------------------------+
bool EnsureLevels(const int subWindow)
{
   bool created = false;
   for(int i = 0; i < g_levelCount; i++)
   {
      string levelName = subwindowName + "_L" + IntegerToString(i);
      if(ObjectFind(0, levelName) < 0)
      {
         DrawCustomLevel(levelName, g_levelValue[i], subWindow);
         created = true;
      }
   }
   return created;
}

//+------------------------------------------------------------------+
//| Helper Function to Draw Custom Lines Without Text Scale Labels  |
//+------------------------------------------------------------------+
void DrawCustomLevel(string name, double priceValue, int windowIndex)
{
   // Create-only: every caller (EnsureLevels) has already checked the
   // object is missing, and level values are pure inputs -- there is
   // nothing an "update in place" could ever change without a full
   // reinit (which wipes and recreates these objects anyway).
   ResetLastError();
   if(!ObjectCreate(0, name, OBJ_HLINE, windowIndex, 0, priceValue))
   {
      Print("Div-Stoch ERROR: failed to create level line '", name, "', error code ", GetLastError(), ".");
      return;
   }
   ObjectSetInteger(0, name, OBJPROP_STYLE, LevelStyle);
   ObjectSetInteger(0, name, OBJPROP_COLOR, LevelColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CHECK DIVERGENCE                                                 |
//+------------------------------------------------------------------+
// Notes:
// - Divergence is calculated from the %D line only.
// - Uses confirmed stochastic pivots.
// - Scans historical bars inside DivergenceLookbackBars.
// - Bearish divergence:
//   Price makes Higher High, %D makes Lower High.
// - Bullish divergence:
//   Price makes Lower Low, %D makes Higher Low.
// - Optional OB/OS filter:
//   Bearish divergence can be limited above BearDivMinLevel.
//   Bullish divergence can be limited below BullDivMaxLevel.
// - DrawStochDivergence draws inside this stochastic subwindow.
// - DrawPriceDivergence draws matching line on main chart.
// - Cleanup keeps newest MaxBearDivergenceLines and
//   MaxBullDivergenceLines only.
//+------------------------------------------------------------------+

void CheckDivergence(const int rates_total,
                     const datetime &time[],
                     const double &high[],
                     const double &low[],
                     int subWindow)
{
   if(rates_total <= DivergenceLookbackBars +
                     PivotLeftBars +
                     PivotRightBars)
      return;

   int start =
      MathMax(PivotLeftBars,
              rates_total - DivergenceLookbackBars);

   int end =
      rates_total - PivotRightBars - 1;

   // --- keep pivot scanning out of the stochastic warm-up region ---
   // The first valid %D value needs roughly KPeriod + Slowing + DPeriod
   // bars of history; before that the K/D buffers can still hold
   // EMPTY_VALUE placeholders, which are huge numbers that would register
   // as fake "pivots" and produce garbage divergence lines. Only matters
   // on symbols/timeframes with very little history, but this makes it
   // bulletproof.
   int warmup = KPeriod + Slowing + DPeriod + PivotLeftBars;
   if(start < warmup)
      start = warmup;

   if(start > end)
      return;

   //==================================================================
   // BEARISH DIVERGENCE HISTORY SCAN
   //==================================================================
   // Price makes Higher High (HH)
   // %D makes Lower High (LH)
   // Indicates weakening bullish momentum
   //==================================================================

   int lastHighPivot = -1;
   int bearRunAnchor  = -1;
   DivRun bearRuns[];

   for(int i = start; i <= end; i++)
   {
      if(!IsStochHighPivot(i))
         continue;

      if(lastHighPivot >= 0)
      {
         bool bearDiv =
            high[i] > high[lastHighPivot] &&
            DBuffer[i] < DBuffer[lastHighPivot];

         if(bearDiv)
         {
            // First pivot of a fresh run keeps the line's start point fixed
            // at the ORIGINAL anchor, even as later pivots keep extending
            // the far end -- this is what turns a staircase of individually
            // -diverging pivots into a single clean diagonal instead of a
            // chain of connected segments.
            if(bearRunAnchor < 0)
               bearRunAnchor = lastHighPivot;

            bool passesOBOS =
               !RequireOBOSForDivergence ||
               (DBuffer[bearRunAnchor] >= BearDivMinLevel ||
                DBuffer[i]             >= BearDivMinLevel);

            if(passesOBOS)
            {
               // Record (or extend) this run. Drawing happens AFTER the
               // scan, and only for the newest N runs -- see
               // DrawDivergenceRuns for why.
               int rn = ArraySize(bearRuns);
               if(rn > 0 && bearRuns[rn - 1].anchor == bearRunAnchor)
                  bearRuns[rn - 1].last = i;
               else
               {
                  ArrayResize(bearRuns, rn + 1);
                  bearRuns[rn].anchor = bearRunAnchor;
                  bearRuns[rn].last   = i;
               }
            }
         }
         else
         {
            // Pattern broke -- the next divergence (if any) starts a fresh
            // run anchored at this pivot instead of continuing the old one.
            bearRunAnchor = -1;
         }
      }

      lastHighPivot = i;
   }

   //==================================================================
   // BULLISH DIVERGENCE HISTORY SCAN
   //==================================================================
   // Price makes Lower Low (LL)
   // %D makes Higher Low (HL)
   // Indicates weakening bearish momentum
   //==================================================================

   int lastLowPivot = -1;
   int bullRunAnchor = -1;
   DivRun bullRuns[];

   for(int i = start; i <= end; i++)
   {
      if(!IsStochLowPivot(i))
         continue;

      if(lastLowPivot >= 0)
      {
         bool bullDiv =
            low[i] < low[lastLowPivot] &&
            DBuffer[i] > DBuffer[lastLowPivot];

         if(bullDiv)
         {
            if(bullRunAnchor < 0)
               bullRunAnchor = lastLowPivot;

            bool passesOBOS =
               !RequireOBOSForDivergence ||
               (DBuffer[bullRunAnchor] <= BullDivMaxLevel ||
                DBuffer[i]             <= BullDivMaxLevel);

            if(passesOBOS)
            {
               int rn = ArraySize(bullRuns);
               if(rn > 0 && bullRuns[rn - 1].anchor == bullRunAnchor)
                  bullRuns[rn - 1].last = i;
               else
               {
                  ArrayResize(bullRuns, rn + 1);
                  bullRuns[rn].anchor = bullRunAnchor;
                  bullRuns[rn].last   = i;
               }
            }
         }
         else
         {
            bullRunAnchor = -1;
         }
      }

      lastLowPivot = i;
   }

   //==================== DRAW NEWEST RUNS / CLEAN THE REST ====================//
   // Runs were collected in ascending anchor-time order, so the newest N
   // are simply the tail of each array. Anything previously drawn that is
   // no longer part of that tail gets deleted -- once, and never
   // recreated. (The old draw-all-then-prune approach deleted the oldest
   // line, only for the next rescan to recreate it and delete a DIFFERENT
   // one -- so when more divergences than MaxLines sat inside the lookback
   // window, the drawn set visibly rotated on every new bar.)
   DrawDivergenceRuns(bearRuns, true,  time, high, low, subWindow);
   DrawDivergenceRuns(bullRuns, false, time, high, low, subWindow);
}

//+------------------------------------------------------------------+
//| Check If Stochastic High Pivot                                   |
//+------------------------------------------------------------------+
bool IsStochHighPivot(int index)
{
   for(int i = 1; i <= PivotLeftBars; i++)
   {
      if(DBuffer[index] <= DBuffer[index - i])
         return false;
   }

   for(int i = 1; i <= PivotRightBars; i++)
   {
      if(DBuffer[index] <= DBuffer[index + i])
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check If Stochastic Low Pivot                                    |
//+------------------------------------------------------------------+
bool IsStochLowPivot(int index)
{
   for(int i = 1; i <= PivotLeftBars; i++)
   {
      if(DBuffer[index] >= DBuffer[index - i])
         return false;
   }

   for(int i = 1; i <= PivotRightBars; i++)
   {
      if(DBuffer[index] >= DBuffer[index + i])
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Draw Newest Divergence Runs & Delete The Rest                    |
//+------------------------------------------------------------------+
void DrawDivergenceRuns(DivRun &runs[],
                        const bool bearish,
                        const datetime &time[],
                        const double &high[],
                        const double &low[],
                        int subWindow)
{
   int total    = ArraySize(runs);
   int maxLines = bearish ? MaxBearDivergenceLines : MaxBullDivergenceLines;
   if(maxLines < 0)
      maxLines = 0;

   // Runs arrive in ascending anchor-time order, so the newest N are the
   // tail of the array.
   int first = MathMax(0, total - maxLines);

   color lineColor = bearish ? BearDivColor     : BullDivColor;
   int   thickness = bearish ? BearDivThickness : BullDivThickness;

   DivLine indLines[];   // lines drawn in this stochastic subwindow this pass
   DivLine priceLines[]; // lines drawn on the main chart this pass

   for(int r = first; r < total; r++)
   {
      int a = runs[r].anchor;
      int e = runs[r].last;
      string key = IntegerToString((long)time[a]);

      if(DrawStochDivergence)
      {
         string name = subwindowName + (bearish ? "_BEAR_DIV_" : "_BULL_DIV_") + key;
         UpsertDivergenceLine(name,
                              time[a], DBuffer[a],
                              time[e], DBuffer[e],
                              lineColor, thickness, subWindow);
         AppendLine(indLines, name, time[a], DBuffer[a],
                    time[e], DBuffer[e], lineColor, thickness, subWindow);
      }

      if(DrawPriceDivergence)
      {
         string name = subwindowName + (bearish ? "_PRICE_BEAR_DIV_" : "_PRICE_BULL_DIV_") + key;
         double p1 = bearish ? high[a] : low[a];
         double p2 = bearish ? high[e] : low[e];
         UpsertDivergenceLine(name,
                              time[a], p1,
                              time[e], p2,
                              lineColor, thickness, 0);
         AppendLine(priceLines, name, time[a], p1,
                    time[e], p2, lineColor, thickness, 0);
      }
   }

   if(bearish)
   {
      SyncTrackedLines(g_bearDivLines, indLines);
      SyncTrackedLines(g_priceBearDivLines, priceLines);
   }
   else
   {
      SyncTrackedLines(g_bullDivLines, indLines);
      SyncTrackedLines(g_priceBullDivLines, priceLines);
   }
}

//+------------------------------------------------------------------+
//| Append A Line (name + full geometry) To A DivLine Array          |
//+------------------------------------------------------------------+
void AppendLine(DivLine &arr[], const string name,
                const datetime t1, const double p1,
                const datetime t2, const double p2,
                const color clr, const int width, const int window)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n].name   = name;
   arr[n].t1     = t1;   arr[n].p1 = p1;
   arr[n].t2     = t2;   arr[n].p2 = p2;
   arr[n].clr    = clr;
   arr[n].width  = width;
   arr[n].window = window;
}


//+------------------------------------------------------------------+
//| Sync Tracked Lines Against The Freshly-Drawn Set                 |
//+------------------------------------------------------------------+
void SyncTrackedLines(DivLine &tracked[], DivLine &current[])
{
   // Delete every previously-drawn line that is no longer part of the
   // newest-N set (a newer run bumped it out, or its anchor slid out of
   // the lookback window). Both arrays hold at most MaxLines entries, so
   // the nested scan is trivially cheap.
   for(int i = 0; i < ArraySize(tracked); i++)
   {
      bool keep = false;
      for(int j = 0; j < ArraySize(current); j++)
      {
         if(tracked[i].name == current[j].name)
         {
            keep = true;
            break;
         }
      }
      if(!keep)
         ObjectDelete(0, tracked[i].name);
   }

   int n = ArraySize(current);
   ArrayResize(tracked, n);
   for(int i = 0; i < n; i++)
      tracked[i] = current[i];
}

//+------------------------------------------------------------------+
//| Draw / Extend One Divergence Line                                |
//+------------------------------------------------------------------+
void UpsertDivergenceLine(string name,
                          datetime time1,
                          double price1,
                          datetime time2,
                          double price2,
                          color lineColor,
                          int thickness,
                          int windowIndex)
{
   // The name is keyed by the run's anchor bar time, so it stays the same
   // across recalculations for as long as this divergence run keeps
   // extending. If it already exists, this is a continuing run -- just move
   // its far endpoint out to the newest pivot instead of drawing a new,
   // separately-connected line segment (that's what used to cause the
   // "zigzag" look for multi-pivot divergence staircases).
   if(ObjectFind(0, name) >= 0)
   {
      ObjectMove(0, name, 1, time2, price2);
      return;
   }

   ResetLastError();
   if(!ObjectCreate(0, name, OBJ_TREND, windowIndex, time1, price1, time2, price2))
   {
      Print("Div-Stoch ERROR: failed to create divergence line '", name, "', error code ", GetLastError(), ".");
      return;
   }

   ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, thickness);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Rebuild every tracked line in one category whose chart object no |
//| longer exists, from its stored geometry.                         |
//+------------------------------------------------------------------+
void HealDivLines(DivLine &arr[], bool &restored)
{
   for(int i = 0; i < ArraySize(arr); i++)
   {
      if(ObjectFind(0, arr[i].name) >= 0)
         continue;
      UpsertDivergenceLine(arr[i].name,
                           arr[i].t1, arr[i].p1,
                           arr[i].t2, arr[i].p2,
                           arr[i].clr, arr[i].width, arr[i].window);
      restored = true;
   }
}

//+------------------------------------------------------------------+
//| Timer: dead-market self-heal ONLY (suite standard, matches Sub-/ |
//| Float-Chart). OnCalculate runs on ticks, so on a frozen/closed   |
//| market wiped objects never come back on their own. Restores the  |
//| stateless level lines and the tracked divergence lines from      |
//| stored data; does nothing (a few ObjectFind calls) when          |
//| everything is present.                                           |
//+------------------------------------------------------------------+
void OnTimer()
{
   int subWindow = ChartWindowFind();
   if(subWindow < 0)
      return;

   bool restored = EnsureLevels(subWindow);
   HealDivLines(g_bearDivLines, restored);
   HealDivLines(g_priceBearDivLines, restored);
   HealDivLines(g_bullDivLines, restored);
   HealDivLines(g_priceBullDivLines, restored);

   if(restored)
      ChartRedraw(0);
}
//+------------------------------------------------------------------+