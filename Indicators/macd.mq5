//+------------------------------------------------------------------+
//|                                              Div-MACD-ATR.mq5    |
//|                                  Copyright 2026, AI Assistant    |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property indicator_separate_window

#property indicator_buffers 4
#property indicator_plots   2

// --- Plot 1: MACD Histogram (ATR-aware colors) ---
#property indicator_label1  "MACD"
#property indicator_type1   DRAW_COLOR_HISTOGRAM

// --- Plot 2: Signal Line ---
#property indicator_label2  "Signal"
#property indicator_type2   DRAW_LINE

enum ACTIVE_LEVEL
{
   Level_1 = 0,
   Level_2 = 1,
   Level_3 = 2,
   Level_4 = 3
};

enum ATR_GUARD_MODE
{
   ATR_AUTO  = 0,  // Auto: vs ATR's own average
   ATR_FIXED = 1   // Fixed: points threshold
};

// --- Input Parameters ---
input group "--- ACTIVE LEVEL ---"
input ACTIVE_LEVEL ActiveLevel = Level_1;

input group "--- LEVEL 1 ---"
input bool   UseFakeTopLeftLabel_L1 = true;
input string FakeTopLeftLabel_L1    = "Loading..";  //ERROR >.<
input int    FastEMA_L1             = 12;
input int    SlowEMA_L1             = 26;
input int    SignalPeriod_L1        = 9;

input group "--- LEVEL 2 ---"
input bool   UseFakeTopLeftLabel_L2 = true;
input string FakeTopLeftLabel_L2    = "Loading..";
input int    FastEMA_L2             = 6;
input int    SlowEMA_L2             = 13;
input int    SignalPeriod_L2        = 5;

input group "--- LEVEL 3 ---"
input bool   UseFakeTopLeftLabel_L3 = true;
input string FakeTopLeftLabel_L3    = "Loading..";
input int    FastEMA_L3             = 24;
input int    SlowEMA_L3             = 52;
input int    SignalPeriod_L3        = 9;

input group "--- LEVEL 4 ---"
input bool   UseFakeTopLeftLabel_L4 = true;
input string FakeTopLeftLabel_L4    = "Loading..";
input int    FastEMA_L4             = 12;
input int    SlowEMA_L4             = 26;
input int    SignalPeriod_L4        = 9;

input group "--- GLOBAL MACD ---"
input ENUM_APPLIED_PRICE MACDPrice  = PRICE_CLOSE;   // Applied price

// Histogram colors: positive side / negative side / market-asleep
input color HistUpColor    = clrLime;   // Histogram above zero (awake)
input color HistDownColor  = clrRed;    // Histogram below zero (awake)
input color HistSleepColor = clrSilver; // Histogram while market is asleep
input int   HistThickness  = 1;

input color SignalColor     = clrRed;
input int   SignalThickness = 1;
input ENUM_LINE_STYLE SignalStyle = STYLE_SOLID;

input group "--- ATR GUARD ---"
// The ATR guard never blocks anything by itself -- it only COLORS the
// histogram gray on bars where the market had no fuel (low volatility),
// so dead hours are visible at a glance, historically and live.
input bool           EnableATRGuard          = true;
input int            ATRPeriod               = 14;
input ATR_GUARD_MODE ATRGuardMode            = ATR_AUTO;
input int            ATRAutoPercent          = 60;   // Asleep when ATR < this % of its own average
input int            ATRAveragePeriod        = 100;  // Bars used for the ATR average (Auto mode)
input int            ATRFixedThresholdPoints = 80;   // Asleep when ATR < this many points (Fixed mode)

input group  "--- CUSTOM LEVEL SETTINGS ---"

input color  LevelColor          = clrSilver;  // Color for all level lines
input ENUM_LINE_STYLE LevelStyle = STYLE_DOT;  // Level line style (proper dropdown)
// One Single Input For All Levels (Up to 6 or more!)
// MACD is unbounded and zero-centered: empty = no lines (clean, like the
// built-in MACD). Type "0" anytime for a zero line, or e.g. "-1;0;1".
input string CustomLevels        = "";         // Separate levels with a semicolon

input group "--- DIVERGENCE SETTINGS ---"

// ON by default. Note: MACD histogram divergence on very low timeframes
// is noisier than RSI/Stoch divergence -- flip off anytime if it's too busy.
input bool   EnableDivergence         = true;

// Divergence calculated from the MACD histogram only
// Zero-side filter (replaces the OB/OS filter of the bounded oscillators):
// bearish divergence only counts above zero, bullish only below zero.
input bool   RequireZeroSideForDivergence = true;

input int    DivergenceLookbackBars   = 100;
input int    PivotLeftBars            = 2;
input int    PivotRightBars           = 2;

input int    MaxBullDivergenceLines   = 2;
input int    MaxBearDivergenceLines   = 2;

input bool   DrawMACDDivergence       = true;
input bool   DrawPriceDivergence      = false;

input color  BullDivColor             = clrLime;
input int    BullDivThickness         = 2;

input color  BearDivColor             = clrRed;
input int    BearDivThickness         = 2;

input group "--- REFRESH SETTINGS ---"
input int    InpRefreshSeconds        = 30;    // Force refresh interval in seconds (0 = only on new bars)

// --- Buffers & Global Variables ---
double MACDBuffer[];      // histogram data (MT5-style: the MACD main line)
double HistColorBuffer[]; // per-bar color index: 0=up, 1=down, 2=asleep
double SignalBuffer[];    // signal line
double ATRBuffer[];       // hidden calculation buffer (ATR values)

int    macdHandle;
int    atrHandle;
string subwindowName;
string indicatorName;

datetime g_lastDivergenceBar = 0;
datetime g_lastForceRefresh  = 0;  // Track last force refresh time

// --- Debug/error logging state -------------------------------------------
// Each flag makes sure a given failure is only printed to the Experts log
// ONCE while it persists, instead of spamming it every tick/bar. The flag
// resets back to false as soon as the underlying condition clears, so a
// genuinely new failure later on still gets reported. One flag per data
// stream, since MACD-main, MACD-signal and ATR can fail independently.
bool g_loggedNoBars        = false; // MACD BarsCalculated
bool g_loggedCopyFailMain  = false; // MACD main buffer copy
bool g_loggedCopyFailSig   = false; // MACD signal buffer copy
bool g_loggedATRNoBars     = false; // ATR BarsCalculated
bool g_loggedATRCopyFail   = false; // ATR buffer copy

// The incremental CopyBuffer below is only valid AFTER one full-history
// copy has succeeded. This can't be inferred from prev_calculated alone,
// because OnCalculate returns rates_total even on early warm-up ticks
// where the copy failed -- so prev_calculated may already be large when
// the handle finally becomes readable. One flag per stream.
bool g_fullMain = false;
bool g_fullSig  = false;
bool g_fullATR  = false;

//==================================================================
// HANDLE WARM-UP GRACE
//==================================================================
// Right after attach/reinit (timeframe switch, input change), the
// terminal may not have finished calculating the MACD/ATR handles
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
// that extended it while passing the zero-side filter. Runs are collected
// first, then only the newest N per direction are actually drawn.
struct DivRun
{
   int anchor; // index of the run's anchor pivot
   int last;   // index of the newest pivot that passed the filter
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
int    FastEMA;
int    SlowEMA;
int    SignalPeriod;

//+------------------------------------------------------------------+
//| Indicator Initialization                                         |
//+------------------------------------------------------------------+
int OnInit()
{
   switch(ActiveLevel)
   {
      case Level_1:
         UseFakeTopLeftLabel = UseFakeTopLeftLabel_L1;
         FakeTopLeftLabel    = FakeTopLeftLabel_L1;
         FastEMA             = FastEMA_L1;
         SlowEMA             = SlowEMA_L1;
         SignalPeriod        = SignalPeriod_L1;
         break;
      case Level_2:
         UseFakeTopLeftLabel = UseFakeTopLeftLabel_L2;
         FakeTopLeftLabel    = FakeTopLeftLabel_L2;
         FastEMA             = FastEMA_L2;
         SlowEMA             = SlowEMA_L2;
         SignalPeriod        = SignalPeriod_L2;
         break;
      case Level_3:
         UseFakeTopLeftLabel = UseFakeTopLeftLabel_L3;
         FakeTopLeftLabel    = FakeTopLeftLabel_L3;
         FastEMA             = FastEMA_L3;
         SlowEMA             = SlowEMA_L3;
         SignalPeriod        = SignalPeriod_L3;
         break;
      case Level_4:
         UseFakeTopLeftLabel = UseFakeTopLeftLabel_L4;
         FakeTopLeftLabel    = FakeTopLeftLabel_L4;
         FastEMA             = FastEMA_L4;
         SlowEMA             = SlowEMA_L4;
         SignalPeriod        = SignalPeriod_L4;
         break;
   }

   // Set Identifiers
   indicatorName =
   StringFormat("Div-MACD( %d, %d, %d )",
                FastEMA,
                SlowEMA,
                SignalPeriod);

if(UseFakeTopLeftLabel)
{
   IndicatorSetString(INDICATOR_SHORTNAME, FakeTopLeftLabel);

   PlotIndexSetString(0, PLOT_LABEL, FakeTopLeftLabel);
   PlotIndexSetString(1, PLOT_LABEL, FakeTopLeftLabel);
}
else
{
   IndicatorSetString(INDICATOR_SHORTNAME, indicatorName);

   PlotIndexSetString(0, PLOT_LABEL, "MACD");
   PlotIndexSetString(1, PLOT_LABEL, "Signal");
}
   // Applied price included so two copies differing only by price never
   // share object names (same rule as Div-RSI / Div-Stoch).
   subwindowName =
   StringFormat("DivMACD_%d_%d_%d_%d",
                FastEMA,
                SlowEMA,
                SignalPeriod,
                (int)MACDPrice);

   // Bind Data Buffers
   SetIndexBuffer(0, MACDBuffer,      INDICATOR_DATA);
   SetIndexBuffer(1, HistColorBuffer, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, SignalBuffer,    INDICATOR_DATA);
   SetIndexBuffer(3, ATRBuffer,       INDICATOR_CALCULATIONS);

// Configure UI Property Rules Dynamically
// Histogram: 3 color slots -- 0 = above zero (awake), 1 = below zero
// (awake), 2 = market asleep (ATR guard). Colored PER BAR, so dead
// sessions show as gray blocks even in history.
PlotIndexSetInteger(0, PLOT_COLOR_INDEXES, 3);
PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, HistUpColor);
PlotIndexSetInteger(0, PLOT_LINE_COLOR, 1, HistDownColor);
PlotIndexSetInteger(0, PLOT_LINE_COLOR, 2, HistSleepColor);
PlotIndexSetInteger(0, PLOT_LINE_WIDTH, HistThickness);

PlotIndexSetInteger(1, PLOT_LINE_COLOR, SignalColor);
PlotIndexSetInteger(1, PLOT_LINE_WIDTH, SignalThickness);
PlotIndexSetInteger(1, PLOT_LINE_STYLE, SignalStyle);

   // Don't draw over the MACD's own warm-up region.
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, SlowEMA + SignalPeriod);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, SlowEMA + SignalPeriod);

   // Hide Moving Decimal Numbers in Top-Left Label / Data Window
   PlotIndexSetInteger(0, PLOT_SHOW_DATA, false);
   PlotIndexSetInteger(1, PLOT_SHOW_DATA, false);

   // --- Decimal precision like the built-in MACD (price digits + 1) ---
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits + 1);

   // NOTE: unlike Div-Stoch / Div-RSI there is NO 0-100 window lock here.
   // MACD is unbounded and zero-centered, so the subwindow auto-scales
   // exactly like the built-in MACD does.

   // Initialize Core Mathematical Engine Handles
   macdHandle = iMACD(_Symbol, _Period, FastEMA, SlowEMA, SignalPeriod, MACDPrice);

   if(macdHandle == INVALID_HANDLE)
   {
      Print("Div-MACD ERROR: failed to create internal MACD handle, error code ", GetLastError(), ".");
      return(INIT_FAILED);
   }

   atrHandle = INVALID_HANDLE;
   if(EnableATRGuard)
   {
      atrHandle = iATR(_Symbol, _Period, ATRPeriod);

      if(atrHandle == INVALID_HANDLE)
      {
         Print("Div-MACD ERROR: failed to create internal ATR handle, error code ", GetLastError(), ".");
         return(INIT_FAILED);
      }
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
   g_fullMain = false;
   g_fullSig  = false;
   g_fullATR  = false;

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

   if(macdHandle != INVALID_HANDLE)
      IndicatorRelease(macdHandle);

   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Copy one stream with the suite's incremental + log-once pattern  |
//| Returns bars copied (<=0 on failure). fullFlag tracks whether a  |
//| full-history copy has succeeded for THIS stream.                 |
//+------------------------------------------------------------------+
int CopyStream(const int handle,
               const int bufferIndex,
               double &buffer[],
               const int rates_total,
               const int prev_calculated,
               bool &fullFlag,
               bool &loggedCopyFail,
               const string streamName)
{
   // Buffers must be in chronological (non-series) order, aligned with
   // time[]/high[]/low[] in OnCalculate. Must be set BEFORE CopyBuffer
   // so the copy itself fills in the correct order.
   ArraySetAsSeries(buffer, false);

   // --- Incremental copy (modern MQL5 pattern) ---
   // Indicator buffers persist between calls and are auto-shifted by the
   // terminal on new bars, so after the FIRST full copy only the bars
   // that actually changed since prev_calculated need re-copying: the
   // still-forming bar plus one closed bar of safety margin.
   int toCopy;
   if(!fullFlag || prev_calculated <= 0 || prev_calculated > rates_total)
      toCopy = rates_total;                       // first successful call / history reload
   else
      toCopy = rates_total - prev_calculated + 2; // new bars + forming bar + margin
   if(toCopy > rates_total)
      toCopy = rates_total;

   ResetLastError();

   int copied = CopyBuffer(handle, bufferIndex, 0, toCopy, buffer);

   bool copyHasError = (copied < 0);
   bool copyNotReady = (!copyHasError && copied == 0);

   if(copyHasError && !StillWarmingUp() && !loggedCopyFail)
   {
      Print("Div-MACD ERROR: CopyBuffer() failed for ", streamName,
            " (copied=", copied, "), error code ", GetLastError(), ".");
      loggedCopyFail = true;
   }
   else if(copyNotReady && !StillWarmingUp() && !loggedCopyFail)
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window -- worth one soft report so this doesn't stay
      // invisible forever.
      Print("Div-MACD: ", streamName, " data isn't ready yet after warm-up. Will keep retrying..");
      loggedCopyFail = true;
   }
   else if(copied > 0)
      loggedCopyFail = false; // only reset once truly recovered

   if(copied <= 0)
      return copied;

   // Full-history copy has succeeded at least once -- from now on the
   // cheap incremental tail copy above is sufficient for this stream.
   if(toCopy >= rates_total)
      fullFlag = true;

   return copied;
}

//+------------------------------------------------------------------+
//| Is the market asleep at bar i? (ATR guard)                       |
//+------------------------------------------------------------------+
bool IsAsleepAt(const int i, const bool atrOK)
{
   // Guard disabled, or ATR data unavailable this tick -> never gray out.
   // (Coloring must stay honest: no guessing when the data isn't there.)
   if(!EnableATRGuard || !atrOK)
      return false;

   double atrNow = ATRBuffer[i];

   // ATR warm-up region can hold EMPTY_VALUE / zero placeholders --
   // treat those bars as awake instead of falsely graying them.
   if(atrNow == EMPTY_VALUE || atrNow <= 0.0)
      return false;

   if(ATRGuardMode == ATR_FIXED)
      return (atrNow < ATRFixedThresholdPoints * _Point);

   // --- Auto mode: compare vs ATR's own recent average ---
   int count = ATRAveragePeriod;
   if(count < 1)
      count = 1;
   if(count > i + 1)
      count = i + 1;

   double sum   = 0.0;
   int    valid = 0;

   for(int k = i - count + 1; k <= i; k++)
   {
      double v = ATRBuffer[k];
      if(v == EMPTY_VALUE || v <= 0.0)
         continue;
      sum += v;
      valid++;
   }

   if(valid == 0)
      return false;

   double avg = sum / valid;

   return (atrNow < avg * ATRAutoPercent / 100.0);
}

//+------------------------------------------------------------------+
//| Color the histogram bars in [from .. rates_total-1]              |
//| 0 = above zero (awake), 1 = below zero (awake), 2 = asleep       |
//+------------------------------------------------------------------+
void ComputeHistColors(const int from, const int rates_total, const bool atrOK)
{
   int start = from;
   if(start < 0)
      start = 0;

   for(int i = start; i < rates_total; i++)
   {
      if(IsAsleepAt(i, atrOK))
         HistColorBuffer[i] = 2;
      else
         HistColorBuffer[i] = (MACDBuffer[i] >= 0.0) ? 0 : 1;
   }
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

   // --- MACD readiness ---
   int barsReady = BarsCalculated(macdHandle);
   if(barsReady < 0 && !StillWarmingUp() && !g_loggedNoBars)
   {
      Print("Div-MACD ERROR: BarsCalculated(macdHandle) failed, error code ", GetLastError(), ".");
      g_loggedNoBars = true;
   }
   else if(barsReady == 0 && !StillWarmingUp() && !g_loggedNoBars)
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window (e.g. handle never finishing for this symbol/TF).
      // Worth one soft report so this doesn't stay invisible forever.
      Print("Div-MACD: MACD data isn't ready yet after warm-up. Will keep retrying..");
      g_loggedNoBars = true;
   }
   else if(barsReady > 0)
      g_loggedNoBars = false; // only reset once truly recovered, not while still stuck at 0

   if(barsReady <= 0)
      return(rates_total);

   // --- Copy MACD main (histogram) + signal, suite pattern each ---
   int copiedMain = CopyStream(macdHandle, 0, MACDBuffer, rates_total, prev_calculated,
                               g_fullMain, g_loggedCopyFailMain, "MACD main");
   if(copiedMain <= 0)
      return(rates_total);

   int copiedSig = CopyStream(macdHandle, 1, SignalBuffer, rates_total, prev_calculated,
                              g_fullSig, g_loggedCopyFailSig, "MACD signal");
   if(copiedSig <= 0)
      return(rates_total);

   // --- ATR guard data (optional stream: failure never blocks MACD) ---
   bool atrOK = false;
   if(EnableATRGuard)
   {
      int atrReady = BarsCalculated(atrHandle);
      if(atrReady < 0 && !StillWarmingUp() && !g_loggedATRNoBars)
      {
         Print("Div-MACD ERROR: BarsCalculated(atrHandle) failed, error code ", GetLastError(), ".");
         g_loggedATRNoBars = true;
      }
      else if(atrReady == 0 && !StillWarmingUp() && !g_loggedATRNoBars)
      {
         Print("Div-MACD: ATR data isn't ready yet after warm-up. Will keep retrying..");
         g_loggedATRNoBars = true;
      }
      else if(atrReady > 0)
         g_loggedATRNoBars = false; // only reset once truly recovered

      if(atrReady > 0)
      {
         int copiedATR = CopyStream(atrHandle, 0, ATRBuffer, rates_total, prev_calculated,
                                    g_fullATR, g_loggedATRCopyFail, "ATR");
         atrOK = (copiedATR > 0 && g_fullATR);
      }
   }

   // --- Per-bar coloring: only the freshly (re)copied tail needs work ---
   // Older bars' colors can't change (their ATR history is fixed), so on
   // normal ticks this loop touches 2-3 bars. Full history is colored
   // only on the first successful full copy / history reload.
   int colorFrom;
   if(copiedMain >= rates_total)
      colorFrom = 0;                          // full pass
   else
      colorFrom = rates_total - copiedMain;   // tail only

   ComputeHistColors(colorFrom, rates_total, atrOK);

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

      // MACD is unbounded and zero-centered, so no range check here --
      // negative levels are perfectly valid.

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
      Print("Div-MACD ERROR: failed to create level line '", name, "', error code ", GetLastError(), ".");
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
// - Divergence is calculated from the MACD histogram only.
// - Uses confirmed histogram pivots.
// - Scans historical bars inside DivergenceLookbackBars.
// - Bearish divergence:
//   Price makes Higher High, histogram makes Lower High.
// - Bullish divergence:
//   Price makes Lower Low, histogram makes Higher Low.
// - Optional zero-side filter:
//   Bearish divergence only counts above zero.
//   Bullish divergence only counts below zero.
// - DrawMACDDivergence draws inside this MACD subwindow.
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

   // --- keep pivot scanning out of the MACD warm-up region ---
   // The first valid MACD value needs roughly SlowEMA + SignalPeriod bars
   // of history; before that the buffer can still hold EMPTY_VALUE
   // placeholders, which are huge numbers that would register as fake
   // "pivots" and produce garbage divergence lines.
   int warmup = SlowEMA + SignalPeriod + PivotLeftBars;
   if(start < warmup)
      start = warmup;

   if(start > end)
      return;

   //==================================================================
   // BEARISH DIVERGENCE HISTORY SCAN
   //==================================================================
   // Price makes Higher High (HH)
   // Histogram makes Lower High (LH)
   // Indicates weakening bullish momentum
   //==================================================================

   int lastHighPivot = -1;
   int bearRunAnchor  = -1;
   DivRun bearRuns[];

   for(int i = start; i <= end; i++)
   {
      if(!IsMACDHighPivot(i))
         continue;

      if(lastHighPivot >= 0)
      {
         bool bearDiv =
            high[i] > high[lastHighPivot] &&
            MACDBuffer[i] < MACDBuffer[lastHighPivot];

         if(bearDiv)
         {
            // First pivot of a fresh run keeps the line's start point fixed
            // at the ORIGINAL anchor, even as later pivots keep extending
            // the far end.
            if(bearRunAnchor < 0)
               bearRunAnchor = lastHighPivot;

            bool passesFilter =
               !RequireZeroSideForDivergence ||
               (MACDBuffer[bearRunAnchor] > 0.0 ||
                MACDBuffer[i]             > 0.0);

            if(passesFilter)
            {
               // Record (or extend) this run. Drawing happens AFTER the
               // scan, and only for the newest N runs.
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
   // Histogram makes Higher Low (HL)
   // Indicates weakening bearish momentum
   //==================================================================

   int lastLowPivot = -1;
   int bullRunAnchor = -1;
   DivRun bullRuns[];

   for(int i = start; i <= end; i++)
   {
      if(!IsMACDLowPivot(i))
         continue;

      if(lastLowPivot >= 0)
      {
         bool bullDiv =
            low[i] < low[lastLowPivot] &&
            MACDBuffer[i] > MACDBuffer[lastLowPivot];

         if(bullDiv)
         {
            if(bullRunAnchor < 0)
               bullRunAnchor = lastLowPivot;

            bool passesFilter =
               !RequireZeroSideForDivergence ||
               (MACDBuffer[bullRunAnchor] < 0.0 ||
                MACDBuffer[i]             < 0.0);

            if(passesFilter)
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
   // recreated.
   DrawDivergenceRuns(bearRuns, true,  time, high, low, subWindow);
   DrawDivergenceRuns(bullRuns, false, time, high, low, subWindow);
}

//+------------------------------------------------------------------+
//| Check If MACD Histogram High Pivot                               |
//+------------------------------------------------------------------+
bool IsMACDHighPivot(int index)
{
   for(int i = 1; i <= PivotLeftBars; i++)
   {
      if(MACDBuffer[index] <= MACDBuffer[index - i])
         return false;
   }

   for(int i = 1; i <= PivotRightBars; i++)
   {
      if(MACDBuffer[index] <= MACDBuffer[index + i])
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check If MACD Histogram Low Pivot                                |
//+------------------------------------------------------------------+
bool IsMACDLowPivot(int index)
{
   for(int i = 1; i <= PivotLeftBars; i++)
   {
      if(MACDBuffer[index] >= MACDBuffer[index - i])
         return false;
   }

   for(int i = 1; i <= PivotRightBars; i++)
   {
      if(MACDBuffer[index] >= MACDBuffer[index + i])
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

   DivLine indLines[];   // lines drawn in this MACD subwindow this pass
   DivLine priceLines[]; // lines drawn on the main chart this pass

   for(int r = first; r < total; r++)
   {
      int a = runs[r].anchor;
      int e = runs[r].last;
      string key = IntegerToString((long)time[a]);

      if(DrawMACDDivergence)
      {
         string name = subwindowName + (bearish ? "_BEAR_DIV_" : "_BULL_DIV_") + key;
         UpsertDivergenceLine(name,
                              time[a], MACDBuffer[a],
                              time[e], MACDBuffer[e],
                              lineColor, thickness, subWindow);
         AppendLine(indLines, name, time[a], MACDBuffer[a],
                    time[e], MACDBuffer[e], lineColor, thickness, subWindow);
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
   // separately-connected line segment.
   if(ObjectFind(0, name) >= 0)
   {
      ObjectMove(0, name, 1, time2, price2);
      return;
   }

   ResetLastError();
   if(!ObjectCreate(0, name, OBJ_TREND, windowIndex, time1, price1, time2, price2))
   {
      Print("Div-MACD ERROR: failed to create divergence line '", name, "', error code ", GetLastError(), ".");
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