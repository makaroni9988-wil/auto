//+------------------------------------------------------------------+
//|                                                   Div-ATR.mq5    |
//|      Market fuel gauge: ATR as % of its own average (or raw),    |
//|      with a flat "asleep" threshold line. No divergence engine   |
//|      on purpose -- ATR is a filter, not an oscillator.           |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property indicator_separate_window

#property indicator_buffers 2
#property indicator_plots   1

// --- Plot 1: The ATR Line (normalized % or raw) ---
#property indicator_label1  "ATR"
#property indicator_type1   DRAW_LINE

enum ACTIVE_LEVEL
{
   Level_1 = 0,
   Level_2 = 1,
   Level_3 = 2,
   Level_4 = 3
};

enum ATR_DISPLAY_MODE
{
   ATR_NORMALIZED = 0,  // Normalized: % of own average + threshold
   ATR_RAW        = 1   // Raw: classic ATR in price units
};

// --- Input Parameters ---
input group "--- ACTIVE LEVEL ---"
input ACTIVE_LEVEL ActiveLevel = Level_1;

input group "--- LEVEL 1 ---"
input bool   UseFakeTopLeftLabel_L1 = true;
input string FakeTopLeftLabel_L1    = "ERROR >.<";
input int    ATRPeriod_L1           = 14;

input group "--- LEVEL 2 ---"
input bool   UseFakeTopLeftLabel_L2 = true;
input string FakeTopLeftLabel_L2    = "Loading..";
input int    ATRPeriod_L2           = 14;

input group "--- LEVEL 3 ---"
input bool   UseFakeTopLeftLabel_L3 = true;
input string FakeTopLeftLabel_L3    = "Loading..";
input int    ATRPeriod_L3           = 21;

input group "--- LEVEL 4 ---"
input bool   UseFakeTopLeftLabel_L4 = true;
input string FakeTopLeftLabel_L4    = "Loading..";
input int    ATRPeriod_L4           = 50;

input group "--- DISPLAY MODE ---"
// Normalized (default): line = ATR / its own average * 100.
//   100 = normal volatility, 150 = hot, below the threshold = asleep.
//   Window locked 0-200 so the threshold always sits at the same height.
//   Same math as the Div-MACD ATR guard: this line crossing under its
//   threshold = the MACD histogram turning gray, at the same moment.
// Raw: classic ATR in price units, auto-scaling window (like built-in ATR).
input ATR_DISPLAY_MODE ATRDisplayMode  = ATR_NORMALIZED;
input int    ATRAveragePeriod          = 100;  // Bars for the ATR average (Normalized mode)

input color LineColor      = clrWhite;
input int   LineThickness  = 1;
input ENUM_LINE_STYLE LineStyle = STYLE_SOLID;

input group "--- THRESHOLD LINE ---"
input bool   ShowThresholdLine   = true;
input double ThresholdPercent    = 60;         // Asleep floor, % of average (Normalized mode)
input int    RawThresholdPoints  = 0;          // Flat line at this many points (Raw mode, 0 = none)
input color  ThresholdColor      = clrRed;
input ENUM_LINE_STYLE ThresholdStyle = STYLE_DOT;

input group  "--- CUSTOM LEVEL SETTINGS ---"

input color  LevelColor          = clrSilver;  // Color for all level lines
input ENUM_LINE_STYLE LevelStyle = STYLE_DOT;  // Level line style (proper dropdown)
// One Single Input For All Levels (Up to 6 or more!)
// Empty = clean. In Normalized mode "100" marks the average reference.
input string CustomLevels        = "";         // Separate levels with a semicolon

input group "--- REFRESH SETTINGS ---"
input int    InpRefreshSeconds        = 30;    // Force refresh interval in seconds (0 = only on new bars)

// --- Buffers & Global Variables ---
double ATRLineBuffer[];  // plotted value (normalized % or raw)
double ATRRawBuffer[];   // hidden: raw ATR values from the handle

int    atrHandle;
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

// Raw mode's dynamic window frame (see OnInit note): the last min/max
// applied, so the scale is only rewritten when it materially changes.
double g_rawScaleMax     = 0.0;
double g_rawScaleMin     = 0.0;

// Parsed custom levels (parsed ONCE in OnInit -- see ParseCustomLevels).
double g_levelValue[];
int    g_levelCount = 0;

//==================================================================
// HANDLE WARM-UP GRACE
//==================================================================
// Right after attach/reinit (timeframe switch, input change), the
// terminal may not have finished calculating the ATR handle yet, so
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

bool   UseFakeTopLeftLabel;
string FakeTopLeftLabel;
int    ATRPeriodValue;

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
         ATRPeriodValue      = ATRPeriod_L1;
         break;
      case Level_2:
         UseFakeTopLeftLabel = UseFakeTopLeftLabel_L2;
         FakeTopLeftLabel    = FakeTopLeftLabel_L2;
         ATRPeriodValue      = ATRPeriod_L2;
         break;
      case Level_3:
         UseFakeTopLeftLabel = UseFakeTopLeftLabel_L3;
         FakeTopLeftLabel    = FakeTopLeftLabel_L3;
         ATRPeriodValue      = ATRPeriod_L3;
         break;
      case Level_4:
         UseFakeTopLeftLabel = UseFakeTopLeftLabel_L4;
         FakeTopLeftLabel    = FakeTopLeftLabel_L4;
         ATRPeriodValue      = ATRPeriod_L4;
         break;
   }

   // Set Identifiers
   indicatorName =
   StringFormat("Div-ATR( %d )",
                ATRPeriodValue);

if(UseFakeTopLeftLabel)
{
   IndicatorSetString(INDICATOR_SHORTNAME, FakeTopLeftLabel);

   PlotIndexSetString(0, PLOT_LABEL, FakeTopLeftLabel);
}
else
{
   IndicatorSetString(INDICATOR_SHORTNAME, indicatorName);

   PlotIndexSetString(0, PLOT_LABEL, "ATR");
}
   subwindowName =
   StringFormat("DivATR_%d_%d",
                ATRPeriodValue,
                (int)ATRDisplayMode);

   // Bind Data Buffers
   SetIndexBuffer(0, ATRLineBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, ATRRawBuffer,  INDICATOR_CALCULATIONS);

// Configure UI Property Rules Dynamically
PlotIndexSetInteger(0, PLOT_LINE_COLOR, LineColor);
PlotIndexSetInteger(0, PLOT_LINE_WIDTH, LineThickness);
PlotIndexSetInteger(0, PLOT_LINE_STYLE, LineStyle);

PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_LINE);

   // Don't draw over the ATR's own warm-up region.
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, ATRPeriodValue);

   // Hide Moving Decimal Numbers in Top-Left Label
   PlotIndexSetInteger(0, PLOT_SHOW_DATA, false);

   if(ATRDisplayMode == ATR_NORMALIZED)
   {
      // Normalized: readable percent, window locked 0-200 so the
      // threshold line always sits at the same visual height (no
      // auto-scale hijacking on volatility spikes).
      IndicatorSetInteger(INDICATOR_DIGITS, 1);
      IndicatorSetDouble(INDICATOR_MINIMUM, 0.0);
      IndicatorSetDouble(INDICATOR_MAXIMUM, 200.0);
   }
   else
   {
      // Raw: price units. NOTE: a fixed 0-200 window lock from a previous
      // Normalized run PERSISTS across input changes (MT5 keeps window
      // min/max on re-init), which squashed the raw line flat on the
      // floor. There is no clean "back to auto" switch, so raw mode
      // maintains its own dynamic scale: min 0, max tracking the recent
      // ATR high (updated on new bars in OnCalculate).
      IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
      IndicatorSetDouble(INDICATOR_MINIMUM, 0.0);
      IndicatorSetDouble(INDICATOR_MAXIMUM, 1.0); // placeholder; real max set on first data pass
   }

   // Initialize Core Mathematical Engine Handle
   atrHandle = iATR(_Symbol, _Period, ATRPeriodValue);

   if(atrHandle == INVALID_HANDLE)
   {
      Print("Div-ATR ERROR: failed to create internal ATR handle, error code ", GetLastError(), ".");
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
   // Ticks alone can't restore a wiped threshold/level line on a dead or
   // closed market -- the timer rebuilds them from the inputs (OnTimer)
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

   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Compute the displayed line for bars [from .. rates_total-1]      |
//| Normalized: ATR / average(ATR, N ending at bar) * 100            |
//| Raw:        the ATR value itself                                 |
//| Older bars never change (their ATR history is fixed), so normal  |
//| ticks recompute only the freshly copied 2-3 bar tail.            |
//+------------------------------------------------------------------+
void ComputeDisplay(const int from, const int rates_total)
{
   int start = from;
   if(start < 0)
      start = 0;

   for(int i = start; i < rates_total; i++)
   {
      double raw = ATRRawBuffer[i];

      // ATR warm-up region can hold EMPTY_VALUE / zero placeholders --
      // don't draw garbage there.
      if(raw == EMPTY_VALUE || raw <= 0.0)
      {
         ATRLineBuffer[i] = EMPTY_VALUE;
         continue;
      }

      if(ATRDisplayMode == ATR_RAW)
      {
         ATRLineBuffer[i] = raw;
         continue;
      }

      // --- Normalized: % of own recent average ---
      int count = ATRAveragePeriod;
      if(count < 1)
         count = 1;
      if(count > i + 1)
         count = i + 1;

      double sum   = 0.0;
      int    valid = 0;

      for(int k = i - count + 1; k <= i; k++)
      {
         double v = ATRRawBuffer[k];
         if(v == EMPTY_VALUE || v <= 0.0)
            continue;
         sum += v;
         valid++;
      }

      if(valid == 0)
      {
         ATRLineBuffer[i] = EMPTY_VALUE;
         continue;
      }

      ATRLineBuffer[i] = raw / (sum / valid) * 100.0;
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

// --- Refresh threshold + custom levels on new candle / force refresh ---
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
   EnsureThreshold(subWindow);
   EnsureLevels(subWindow);
}

   // Copy ATR data
   int barsReady = BarsCalculated(atrHandle);
   if(barsReady < 0 && !StillWarmingUp() && !g_loggedNoBars)
   {
      Print("Div-ATR ERROR: BarsCalculated(atrHandle) failed, error code ", GetLastError(), ".");
      g_loggedNoBars = true;
   }
   else if(barsReady == 0 && !StillWarmingUp() && !g_loggedNoBars)
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window (e.g. handle never finishing for this symbol/TF).
      // Worth one soft report so this doesn't stay invisible forever --
      // without this, a permanently-stuck handle would never be reported.
      Print("Div-ATR: ATR data isn't ready yet after warm-up. Will keep retrying..");
      g_loggedNoBars = true;
   }
   else if(barsReady > 0)
      g_loggedNoBars = false; // only reset once truly recovered, not while still stuck at 0

   if(barsReady <= 0)
      return(rates_total);

   // --- Force buffers into the SAME direction as time[]/high[]/low[] ---
   // SetIndexBuffer() auto-marks the buffers as timeseries (index 0 =
   // newest bar), but time[]/high[]/low[] here are in chronological order
   // (index 0 = oldest bar). Must be set BEFORE CopyBuffer so the copy
   // itself fills in the correct order.
   ArraySetAsSeries(ATRLineBuffer, false);
   ArraySetAsSeries(ATRRawBuffer,  false);

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

   int copiedATR =
      CopyBuffer(atrHandle,
                 0,
                 0,
                 toCopy,
                 ATRRawBuffer);

   bool copyHasError = (copiedATR < 0);
   bool copyNotReady = (!copyHasError && copiedATR == 0);

   if(copyHasError && !StillWarmingUp() && !g_loggedCopyFail)
   {
      Print("Div-ATR ERROR: CopyBuffer() failed for ATR (copiedATR=", copiedATR,
            "), error code ", GetLastError(), ".");
      g_loggedCopyFail = true;
   }
   else if(copyNotReady && !StillWarmingUp() && !g_loggedCopyFail)
   {
      // Not an error code, just stuck at "still calculating" past the
      // grace window -- worth one soft report so this doesn't stay
      // invisible forever.
      Print("Div-ATR: ATR data isn't ready yet after warm-up. Will keep retrying..");
      g_loggedCopyFail = true;
   }
   else if(copiedATR > 0)
      g_loggedCopyFail = false; // only reset once truly recovered

   if(copiedATR <= 0)
      return(rates_total);

   // Full-history copy has succeeded at least once -- from now on the
   // cheap incremental tail copy above is sufficient.
   if(toCopy >= rates_total)
      g_fullCopyDone = true;

   // --- Displayed line: only the freshly (re)copied tail needs work ---
   int computeFrom;
   if(copiedATR >= rates_total)
      computeFrom = 0;                          // full pass
   else
      computeFrom = rates_total - copiedATR;    // tail only

   ComputeDisplay(computeFrom, rates_total);

   // --- Raw mode: mimic the built-in ATR's native auto-scale ---
   // The built-in never sets a window scale: MT5 frames it around the
   // VISIBLE bars only and re-frames on scroll/zoom. A previously set
   // fixed scale (from Normalized mode) can't be un-set back to "auto",
   // so raw mode imitates it: frame the visible bars, re-frame on
   // chart changes (see OnChartEvent).
   if(ATRDisplayMode == ATR_RAW)
   {
      if(UpdateRawScale())
         needRedraw = true;
   }

   // Only force a repaint when we actually drew/moved something this call
   // (new bar closed -> threshold/levels checked). On every other tick
   // this block is skipped entirely, so there's no added cost on the
   // high-frequency path.
   if(needRedraw)
      ChartRedraw(0);

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Raw mode: frame the window around the VISIBLE bars only, like    |
//| MT5's native auto-scale does for the built-in ATR. Returns true  |
//| when the scale was actually rewritten (material change only).    |
//+------------------------------------------------------------------+
bool UpdateRawScale(void)
{
   int total = ArraySize(ATRLineBuffer);
   if(total <= 0)
      return false;

   // Visible range in SERIES indices (leftmost bar + count), converted
   // to the chronological indexing our buffer uses.
   long firstVis = ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   long visBars  = ChartGetInteger(0, CHART_VISIBLE_BARS);
   if(visBars <= 0)
      return false;

   int from = total - 1 - (int)firstVis;      // leftmost visible, chrono
   int to   = from + (int)visBars;            // one past rightmost
   if(from < 0)
      from = 0;
   if(to > total)
      to = total;
   if(from >= to)
      return false;

   double maxVal = 0.0;
   double minVal = DBL_MAX;
   for(int i = from; i < to; i++)
   {
      double v = ATRLineBuffer[i];
      if(v == EMPTY_VALUE)
         continue;
      if(v > maxVal)
         maxVal = v;
      if(v < minVal)
         minVal = v;
   }

   if(maxVal <= 0.0 || minVal >= DBL_MAX)
      return false;

   double top    = maxVal * 1.03; // whisper of headroom, like native framing
   double bottom = minVal * 0.97;
   if(bottom < 0.0)
      bottom = 0.0;

   // Rewrite only on material change so the window isn't nudged
   // pointlessly on every tick.
   double span = top - bottom;
   if(span <= 0.0)
      return false;

   if(g_rawScaleMax > 0.0 &&
      MathAbs(top - g_rawScaleMax)    < span * 0.03 &&
      MathAbs(bottom - g_rawScaleMin) < span * 0.03)
      return false;

   IndicatorSetDouble(INDICATOR_MINIMUM, bottom);
   IndicatorSetDouble(INDICATOR_MAXIMUM, top);
   g_rawScaleMax = top;
   g_rawScaleMin = bottom;
   return true;
}

//+------------------------------------------------------------------+
//| Scroll / zoom re-framing for raw mode. OnCalculate only fires on |
//| ticks, so on a quiet market a scroll would otherwise keep the    |
//| old frame until the next tick -- this closes that gap.           |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE && ATRDisplayMode == ATR_RAW)
   {
      if(UpdateRawScale())
         ChartRedraw(0);
   }
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

      // Skip empty entries (default input is "" = clean window).
      if(StringLen(trimmedVal) == 0)
         continue;

      double levelPrice = StringToDouble(trimmedVal);

      // No range check: the line's units follow the display mode
      // (percent in Normalized mode, price in Raw mode).

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
//| Create the asleep-threshold line if enabled and missing. State-  |
//| less (pure inputs), so callable from the per-bar path or the 1s  |
//| heal timer. Returns true when it actually (re)created the line.  |
//+------------------------------------------------------------------+
bool EnsureThreshold(const int subWindow)
{
   if(!ShowThresholdLine)
      return false;

   double thresholdValue = 0.0;
   bool   drawThreshold  = false;

   if(ATRDisplayMode == ATR_NORMALIZED)
   {
      thresholdValue = ThresholdPercent;
      drawThreshold  = (ThresholdPercent > 0);
   }
   else if(RawThresholdPoints > 0)
   {
      thresholdValue = RawThresholdPoints * _Point;
      drawThreshold  = true;
   }

   if(!drawThreshold)
      return false;

   string thrName = subwindowName + "_THR";
   if(ObjectFind(0, thrName) >= 0)
      return false;

   ResetLastError();
   if(!ObjectCreate(0, thrName, OBJ_HLINE, subWindow, 0, thresholdValue))
   {
      Print("Div-ATR ERROR: failed to create threshold line, error code ", GetLastError(), ".");
      return false;
   }
   ObjectSetInteger(0, thrName, OBJPROP_STYLE, ThresholdStyle);
   ObjectSetInteger(0, thrName, OBJPROP_COLOR, ThresholdColor);
   ObjectSetInteger(0, thrName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, thrName, OBJPROP_BACK, true);
   ObjectSetInteger(0, thrName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, thrName, OBJPROP_HIDDEN, true);
   return true;
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
      Print("Div-ATR ERROR: failed to create level line '", name, "', error code ", GetLastError(), ".");
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
//| Timer: dead-market self-heal ONLY (suite standard, matches Sub-/ |
//| Float-Chart). OnCalculate runs on ticks, so on a frozen/closed   |
//| market wiped objects never come back on their own. Restores the  |
//| stateless threshold and level lines from the inputs; does        |
//| nothing (a few ObjectFind calls) when everything is present.     |
//+------------------------------------------------------------------+
void OnTimer()
{
   int subWindow = ChartWindowFind();
   if(subWindow < 0)
      return;

   bool restored = EnsureThreshold(subWindow);
   if(EnsureLevels(subWindow))
      restored = true;

   if(restored)
      ChartRedraw(0);
}
//+------------------------------------------------------------------+