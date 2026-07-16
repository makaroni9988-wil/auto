//+------------------------------------------------------------------+
//|                                                   StochRSI.mq5   |
//|                                  Copyright 2026, AI Assistant    |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property indicator_separate_window

// 2 visible plots (%K, %D) + 2 hidden calculation buffers
// (raw RSI copied from the iRSI handle, and raw Stoch-of-RSI before
// smoothing). Calculation buffers persist between ticks exactly like
// plot buffers, which is what makes the incremental recalc below valid.
#property indicator_buffers 4
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
input int    smoothK_L1             = 3;   // K            (Pine default)
input int    smoothD_L1             = 3;   // D            (Pine default)
input int    lengthRSI_L1           = 14;  // RSI Length   (Pine default)
input int    lengthStoch_L1         = 14;  // Stochastic Length (Pine default)

input group "--- LEVEL 2 ---"
input bool   UseFakeTopLeftLabel_L2 = true;
input string FakeTopLeftLabel_L2    = "Loading..";
input int    smoothK_L2             = 3;   // K
input int    smoothD_L2             = 3;   // D
input int    lengthRSI_L2           = 9;   // RSI Length
input int    lengthStoch_L2         = 9;   // Stochastic Length

input group "--- LEVEL 3 ---"
input bool   UseFakeTopLeftLabel_L3 = true;
input string FakeTopLeftLabel_L3    = "Loading..";
input int    smoothK_L3             = 3;   // K
input int    smoothD_L3             = 3;   // D
input int    lengthRSI_L3           = 40;  // RSI Length
input int    lengthStoch_L3         = 40;  // Stochastic Length

input group "--- LEVEL 4 ---"
input bool   UseFakeTopLeftLabel_L4 = true;
input string FakeTopLeftLabel_L4    = "Loading..";
input int    smoothK_L4             = 3;   // K
input int    smoothD_L4             = 3;   // D
input int    lengthRSI_L4           = 60;  // RSI Length
input int    lengthStoch_L4         = 60;  // Stochastic Length

input group "--- GLOBAL STOCHRSI ---"
// Pine's "RSI Source" (src input). Smoothing is fixed to SMA to match
// Pine's ta.sma exactly, so there's no MA-method input here on purpose.
input ENUM_APPLIED_PRICE RSIPrice   = PRICE_CLOSE;   // RSI Source

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
input string CustomLevels        = "20;80";    // Separate levels with a semicolon (e.g. 20;50;80)

input group "--- REFRESH SETTINGS ---"
input int    InpRefreshSeconds        = 30;    // Force refresh interval in seconds (0 = only on new bars)

// --- Buffers & Global Variables ---
double KBuffer[];
double DBuffer[];
double RSIRaw[];    // calculation buffer: raw RSI from the iRSI handle
double StochRaw[];  // calculation buffer: Stoch(RSI) BEFORE K smoothing
int    rsiHandle;
string subwindowName;
string indicatorName; 

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
// terminal may not have finished calculating the RSI handle
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

// Parsed custom levels (parsed ONCE in OnInit -- see ParseCustomLevels).
double g_levelValue[];
int    g_levelCount = 0;

bool   UseFakeTopLeftLabel;
string FakeTopLeftLabel;
int    smoothK;
int    smoothD;
int    lengthRSI;
int    lengthStoch;

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
         smoothK               = smoothK_L1;
         smoothD               = smoothD_L1;
         lengthRSI             = lengthRSI_L1;
         lengthStoch           = lengthStoch_L1;
         break;
      case Level_2:
         UseFakeTopLeftLabel   = UseFakeTopLeftLabel_L2;
         FakeTopLeftLabel      = FakeTopLeftLabel_L2;
         smoothK               = smoothK_L2;
         smoothD               = smoothD_L2;
         lengthRSI             = lengthRSI_L2;
         lengthStoch           = lengthStoch_L2;
         break;
      case Level_3:
         UseFakeTopLeftLabel   = UseFakeTopLeftLabel_L3;
         FakeTopLeftLabel      = FakeTopLeftLabel_L3;
         smoothK               = smoothK_L3;
         smoothD               = smoothD_L3;
         lengthRSI             = lengthRSI_L3;
         lengthStoch           = lengthStoch_L3;
         break;
      case Level_4:
         UseFakeTopLeftLabel   = UseFakeTopLeftLabel_L4;
         FakeTopLeftLabel      = FakeTopLeftLabel_L4;
         smoothK               = smoothK_L4;
         smoothD               = smoothD_L4;
         lengthRSI             = lengthRSI_L4;
         lengthStoch           = lengthStoch_L4;
         break;
   }

   // Hard floor of 1 on every period, same as Pine's minval=1.
   if(smoothK     < 1) smoothK     = 1;
   if(smoothD     < 1) smoothD     = 1;
   if(lengthRSI   < 1) lengthRSI   = 1;
   if(lengthStoch < 1) lengthStoch = 1;

   // Set Identifiers
   indicatorName =
   StringFormat("StochRSI( %d, %d, %d, %d )",
                smoothK,
                smoothD,
                lengthRSI,
                lengthStoch);
                
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
   StringFormat("StochRSI_%d_%d_%d_%d_%d",
                smoothK,
                smoothD,
                lengthRSI,
                lengthStoch,
                (int)RSIPrice);

   // Bind Data Buffers 
   SetIndexBuffer(0, KBuffer, INDICATOR_DATA); 
   SetIndexBuffer(1, DBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, RSIRaw,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, StochRaw, INDICATOR_CALCULATIONS);

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

   // Skip the warm-up region where the smoothing chain isn't filled yet:
   // %K first becomes valid after lengthRSI + lengthStoch + smoothK bars,
   // %D needs smoothD more on top of that.
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, lengthRSI + lengthStoch + smoothK);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, lengthRSI + lengthStoch + smoothK + smoothD);

   // Gaps in the warm-up region are stored as EMPTY_VALUE -- tell the
   // plots explicitly so they draw nothing there instead of a spike.
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   
   // Hide Moving Decimal Numbers in Top-Left Label
   PlotIndexSetInteger(0, PLOT_SHOW_DATA, false);
   PlotIndexSetInteger(1, PLOT_SHOW_DATA, false);  

   // --- Lock Decimal Precision To 2 Places (.00) ---
   // This forces MT5 to format all underlying window readouts to exactly 2 digits
   IndicatorSetInteger(INDICATOR_DIGITS, 2);

   // Force the window frame constraints to lock at 0 and 100 immediately on attachment.
   // This stops the indicator lines and custom levels from vanishing or showing blank data rows.
   IndicatorSetDouble(INDICATOR_MINIMUM, -10.0);
   IndicatorSetDouble(INDICATOR_MAXIMUM, 110.0);

   // Initialize Core Mathematical Engine Handle
   // Pine equivalent: rsi1 = ta.rsi(src, lengthRSI)
   // The Stoch-of-RSI + SMA smoothing chain (ta.stoch + ta.sma) is
   // computed manually in OnCalculate -- iStochastic can't be used here
   // because it only runs on PRICE, never on another indicator's output.
   rsiHandle = iRSI(_Symbol, _Period, lengthRSI, RSIPrice);
   
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("StochRSI ERROR: failed to create internal RSI handle, error code ", GetLastError(), ".");
      return(INIT_FAILED);
   }

   // Wipes out old parameter lines when inputs are modified by the user
   ObjectsDeleteAll(0, subwindowName);

   // Parse the CustomLevels input ONCE (see ParseCustomLevels).
   ParseCustomLevels();

   // Start the warm-up grace clock (see StillWarmingUp above).
   g_initTick = GetTickCount();
   g_fullCopyDone = false;

   // 1-second self-heal timer (suite standard, matches Sub-/Float-Chart).
   // Ticks alone can't restore wiped level lines on a dead or closed
   // market -- the timer rebuilds them from stored state (OnTimer) and
   // does nothing when everything is present.
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

   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);

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

   // Copy RSI data
   int barsReady = BarsCalculated(rsiHandle);
   if(barsReady < 0 && !StillWarmingUp() && !g_loggedNoBars)
   {
      Print("StochRSI ERROR: BarsCalculated(rsiHandle) failed, error code ", GetLastError(), ".");
      g_loggedNoBars = true;
   }
   else if(barsReady == 0 && !StillWarmingUp() && !g_loggedNoBars)
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window (e.g. handle never finishing for this symbol/TF).
      // Worth one soft report so this doesn't stay invisible forever --
      // without this, a permanently-stuck handle would never be reported.
      Print("StochRSI: RSI data isn't ready yet after warm-up. Will keep retrying..");
      g_loggedNoBars = true;
   }
   else if(barsReady > 0)
      g_loggedNoBars = false; // only reset once truly recovered, not while still stuck at 0

   if(barsReady <= 0)
      return(rates_total);

   // --- Force buffers into the SAME direction as time[] ---
   // SetIndexBuffer() auto-marks the buffers as a timeseries
   // (index 0 = newest bar), but time[] here is in chronological order
   // (index 0 = oldest bar) since ArraySetAsSeries was never called on
   // it. Must be set BEFORE CopyBuffer so the copy itself fills in the
   // correct order.
   ArraySetAsSeries(KBuffer, false);
   ArraySetAsSeries(DBuffer, false);
   ArraySetAsSeries(RSIRaw, false);
   ArraySetAsSeries(StochRaw, false);

   // --- Incremental copy (modern MQL5 pattern) ---
   // Indicator buffers persist between calls and are auto-shifted by the
   // terminal on new bars, so after the FIRST full copy only the bars
   // that actually changed since prev_calculated need re-copying: the
   // still-forming bar plus one closed bar of safety margin.
   int toCopy;
   if(!g_fullCopyDone || prev_calculated <= 0 || prev_calculated > rates_total)
      toCopy = rates_total;                       // first successful call / history reload
   else
      toCopy = rates_total - prev_calculated + 2; // new bars + forming bar + margin
   if(toCopy > rates_total)
      toCopy = rates_total;

   ResetLastError();

   int copiedRSI =
      CopyBuffer(rsiHandle,
                 0,
                 0,
                 toCopy,
                 RSIRaw);

   bool copyHasError = (copiedRSI < 0);
   bool copyNotReady = (!copyHasError && copiedRSI == 0);

   if(copyHasError && !StillWarmingUp() && !g_loggedCopyFail)
   {
      Print("StochRSI ERROR: CopyBuffer() failed for RSI (copiedRSI=", copiedRSI,
            "), error code ", GetLastError(), ".");
      g_loggedCopyFail = true;
   }
   else if(copyNotReady && !StillWarmingUp() && !g_loggedCopyFail)
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window -- worth one soft report so this doesn't stay
      // invisible forever.
      Print("StochRSI: RSI data isn't ready yet after warm-up. Will keep retrying..");
      g_loggedCopyFail = true;
   }
   else if(copiedRSI > 0)
      g_loggedCopyFail = false; // only reset once truly recovered

   if(copiedRSI <= 0)
      return(rates_total);

   // Full-history copy has succeeded at least once -- from now on the
   // cheap incremental tail copy above is sufficient.
   if(toCopy >= rates_total)
      g_fullCopyDone = true;

   //==================================================================
   // STOCH RSI CHAIN (exact Pine formula):
   //   rsi1 = ta.rsi(src, lengthRSI)                     -> RSIRaw
   //   stoch = ta.stoch(rsi1, rsi1, rsi1, lengthStoch)   -> StochRaw
   //   k = ta.sma(stoch, smoothK)                        -> KBuffer
   //   d = ta.sma(k, smoothD)                            -> DBuffer
   //==================================================================
   // Only the tail that could have changed since prev_calculated is
   // recomputed; every bar i depends solely on values up to bar i, and
   // all four buffers persist between calls, so older bars stay valid.
   int begin;
   if(toCopy >= rates_total || prev_calculated <= 0 || prev_calculated > rates_total)
      begin = 0;
   else
      begin = MathMax(0, prev_calculated - 2);

   for(int i = begin; i < rates_total; i++)
   {
      // --- ta.stoch(rsi1, rsi1, rsi1, lengthStoch) -----------------
      // = 100 * (rsi - lowest(rsi, len)) / (highest(rsi, len) - lowest)
      int winStart = i - lengthStoch + 1;
      if(winStart < 0 || RSIRaw[i] == EMPTY_VALUE)
      {
         StochRaw[i] = EMPTY_VALUE;
         KBuffer[i]  = EMPTY_VALUE;
         DBuffer[i]  = EMPTY_VALUE;
         continue;
      }

      double hh = -DBL_MAX;
      double ll =  DBL_MAX;
      bool   windowOK = true;
      for(int j = winStart; j <= i; j++)
      {
         double v = RSIRaw[j];
         if(v == EMPTY_VALUE) { windowOK = false; break; } // RSI warm-up region
         if(v > hh) hh = v;
         if(v < ll) ll = v;
      }
      if(!windowOK)
      {
         StochRaw[i] = EMPTY_VALUE;
         KBuffer[i]  = EMPTY_VALUE;
         DBuffer[i]  = EMPTY_VALUE;
         continue;
      }

      double range = hh - ll;
      // Perfectly flat RSI window -> Pine yields na; a bounded fallback
      // of 0 is used here so the buffer never holds garbage.
      StochRaw[i] = (range > 0.0) ? 100.0 * (RSIRaw[i] - ll) / range : 0.0;

      // --- k = ta.sma(stoch, smoothK) -------------------------------
      KBuffer[i] = SmaOf(StochRaw, i, smoothK);

      // --- d = ta.sma(k, smoothD) -----------------------------------
      DBuffer[i] = SmaOf(KBuffer, i, smoothD);
   }

   // Only force a repaint when we actually drew something this call
   // (new bar closed -> levels checked). On every other tick this block
   // is skipped entirely, so there's no added cost on the high-frequency
   // path.
   if(needRedraw)
      ChartRedraw(0);

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Simple SMA over a chronological buffer, ending at index i.       |
//| Returns EMPTY_VALUE while the window isn't fully filled with     |
//| valid values yet (buffer warm-up region), mirroring how Pine's   |
//| ta.sma returns na until it has 'period' real values.             |
//+------------------------------------------------------------------+
double SmaOf(const double &buf[], const int i, const int period)
{
   int winStart = i - period + 1;
   if(winStart < 0)
      return EMPTY_VALUE;

   double sum = 0.0;
   for(int j = winStart; j <= i; j++)
   {
      if(buf[j] == EMPTY_VALUE)
         return EMPTY_VALUE;
      sum += buf[j];
   }
   return sum / period;
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
      Print("StochRSI ERROR: failed to create level line '", name, "', error code ", GetLastError(), ".");
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
//| Timer: dead-market self-heal ONLY (suite standard, matches Sub-/ |
//| Float-Chart). OnCalculate runs on ticks, so on a frozen/closed   |
//| market wiped objects never come back on their own. Restores the  |
//| stateless level lines from the parsed values; does nothing (a    |
//| few ObjectFind calls) when everything is present.                |
//+------------------------------------------------------------------+
void OnTimer()
{
   int subWindow = ChartWindowFind();
   if(subWindow < 0)
      return;

   bool restored = EnsureLevels(subWindow);

   if(restored)
      ChartRedraw(0);
}
//+------------------------------------------------------------------+