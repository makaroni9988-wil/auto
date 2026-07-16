#property copyright "Custom"
#property link      ""
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0
#property indicator_buffers 0

//===================================================================
// CHoCH / BOS Structure Indicator
// Detects Change of Character (reversal) and Break of Structure
// (continuation) using fractal swing points, per bar-close or
// wick break confirmation. Designed as a visual entry-timing aid,
// not a signal generator - you decide the entry.
//===================================================================

enum ENUM_BREAK_MODE
  {
   BREAK_CLOSE = 0,   // Candle Close breaks level (fewer false signals)
   BREAK_WICK  = 1    // Candle Wick/shadow breaks level (faster, noisier)
  };

enum ENUM_TREND_STATE
  {
   TREND_NEUTRAL = 0,
   TREND_BULL    = 1,
   TREND_BEAR    = -1
  };

input group "=== Structure Detection ==="
input ENUM_TIMEFRAMES  InpTimeframe     = PERIOD_CURRENT;    // Timeframe to detect structure on
input int              InpFractalPeriod = 2;                 // Bars each side to confirm swing point (min 1)
input ENUM_BREAK_MODE  InpBreakMode     = BREAK_CLOSE;       // Break confirmation mode
input int              InpLookbackBars  = 200;               // Bars scanned on indicator load

input group "=== CHoCH (Change of Character) ==="
input bool    InpShowCHoCH       = true;          // Show CHoCH labels
input color   InpCHoCH_BullColor = clrLime;       // CHoCH Bullish color
input color   InpCHoCH_BearColor = clrLime;       // CHoCH Bearish color
input string  InpCHoCH_Text      = "CHoCH";       // CHoCH tooltip text
input int     InpCHoCH_Size      = 1;             // CHoCH triangle size (1-5)

input group "=== BOS (Break of Structure) ==="
input bool    InpShowBOS        = true;           // Show BOS labels
input color   InpBOS_BullColor  = clrWhite;       // BOS Bullish color
input color   InpBOS_BearColor  = clrWhite;       // BOS Bearish color
input string  InpBOS_Text       = "BOS";          // BOS tooltip text
input int     InpBOS_Size       = 1;              // BOS triangle size (1-5)

input group "=== Display ==="
input int     InpMaxLabels        = 20;     // Max labels kept on chart (oldest auto-deleted)
input int     InpLabelOffsetPips  = 3;      // Distance of triangle from candle wick (pips)

input int     InpRefreshSeconds   = 30;     // Force refresh interval in seconds (0 = only on new bars)

// Instance-unique object prefix, built in OnInit: "COC_<TF>_".
// A fixed "COC_" meant two copies (e.g. M2 + M5 structure) shared one
// namespace: removing/reiniting ONE deleted the OTHER's labels via
// ObjectsDeleteAll -- whose restore queue then resurrected them, so the
// two copies fought forever. TF-aware prefix = each cleans only its own.
string g_prefix;

struct SwingPoint
  {
   bool     valid;
   bool     broken;
   double   price;
   datetime time;
  };

SwingPoint       g_lastHigh;
SwingPoint       g_lastLow;
ENUM_TREND_STATE g_trend;
datetime         g_lastScanBarTime;   // forming-bar time at the last successful scan (new-bar gate)
datetime         g_lastProcessedTime; // time of the newest CLOSED bar already run through ProcessClosedBar
datetime         g_lastForceRefresh;  // time of last force refresh

// Everything needed to REBUILD a label if it gets deleted from the
// chart (manually, by another tool, by a template, ...). The old
// version only stored the object NAME, so CheckLabelsMissing() could
// detect a deletion but nothing could actually recreate the object --
// the "missing" state then persisted forever and re-triggered a full
// (useless) rescan on every single tick.
struct LabelInfo
  {
   string   name;
   datetime time;
   double   price;    // anchor price (already offset from the wick)
   bool     isUp;
   bool     isChoch;
  };
LabelInfo        g_labelQueue[];
double           g_pip;
ENUM_TIMEFRAMES  g_tf;

//------------------------------------------------------------------
// HANDLE WARM-UP GRACE
//------------------------------------------------------------------
// Right after attach/reinit (timeframe switch, input change), the
// terminal may not have finished syncing this symbol-timeframe's
// history yet, so CopyRates() can transiently fail (error 4401) even
// though the data is fine a moment later. That's a normal transient,
// not a failure: it retries the next time ScanAndProcess() runs (new
// bar / force-refresh / missing labels) and succeeds. During a short
// grace window after init, this is retried silently; only if it
// persists past the window is it logged.
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
}

// Only print the CopyRates failure once while it persists, not every
// scan (new bar / force refresh / missing-label check all call
// ScanAndProcess, so without this a single outage could log repeatedly).
bool g_loggedCopyRatesFail = false;

// Forward declarations
void ScanAndProcess(void);
void ProcessClosedBar(const double &h[], const double &l[], const double &c[], const datetime &t[], int i, int total);
bool IsFractalHigh(const double &h[], int i, int total, int period);
bool IsFractalLow(const double &l[], int i, int total, int period);
void PlotLabel(datetime t, double price, bool isUp, bool isChoch);
void CreateLabelObject(const LabelInfo &info);
void RestoreMissingLabels(void);
void PruneLabels();
bool CheckLabelsMissing(void);
void DebugErr(string msg);
void DebugSoft(string msg);

int OnInit()
  {
   g_tf = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpTimeframe;

   string tfName = EnumToString(g_tf);
   StringReplace(tfName, "PERIOD_", "");
   g_prefix = "COC_" + tfName + "_";

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * ((digits == 3 || digits == 5) ? 10.0 : 1.0);

   g_lastHigh.valid  = false;
   g_lastHigh.broken = false;
   g_lastLow.valid   = false;
   g_lastLow.broken  = false;
   g_trend = TREND_NEUTRAL;
   g_lastScanBarTime   = 0;
   g_lastProcessedTime = 0;
   g_lastForceRefresh  = 0;

   ArrayResize(g_labelQueue, 0);

   // Start the warm-up grace clock (see StillWarmingUp above).
   g_initTick = GetTickCount();

   ScanAndProcess();

   // 1-second self-heal timer (suite standard, matches Sub-/Float-Chart).
   // Ticks alone can't restore deleted labels or force-refresh on a dead
   // or closed market -- the timer runs the same logic once a second so
   // label recovery and new-bar scanning keep working with zero ticks.
   // The per-tick path (OnCalculate) is unchanged.
   EventSetTimer(1);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   // ObjectsDeleteAll() alone is unreliable when called from OnDeinit --
   // a known MT5 quirk where the object list is updated but the chart
   // isn't repainted before the next indicator instance starts drawing
   // (e.g. right after a timeframe switch). Without an explicit
   // ChartRedraw() here, the previous timeframe's arrows can intermittently
   // survive on screen alongside the new timeframe's until something else
   // happens to force a redraw.
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw(0);
  }

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
   ProcessTick();
   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Timer: self-heal + new-bar/refresh without needing a tick.       |
//| Runs the exact same logic as OnCalculate, so deleted labels are  |
//| restored and new closed bars are picked up on a frozen/closed    |
//| market. Cheap when nothing changed (one CopyTime).               |
//+------------------------------------------------------------------+
void OnTimer()
  {
   ProcessTick();
  }

//+------------------------------------------------------------------+
//| Shared per-update logic (called from both OnCalculate and        |
//| OnTimer) -- identical to the original OnCalculate body.          |
//+------------------------------------------------------------------+
void ProcessTick()
  {
   // iTime() only reports what's already synced -- unlike Copy* functions,
   // it doesn't itself trigger a sync request for a locked TF (g_tf) the
   // chart isn't on, so it could sit at 0 for a while after attach/reinit.
   // CopyTime() actively requests that sync. Guard against
   // curTfBarTime==0 so an unsynced read doesn't get misread as "new
   // bar" against a real previous g_lastScanBarTime.
   datetime curTfBarTime = 0;
   datetime tfTime[];
   ArraySetAsSeries(tfTime, true);
   if(CopyTime(_Symbol, g_tf, 0, 1, tfTime) > 0)
      curTfBarTime = tfTime[0];

   bool newBar = (curTfBarTime > 0 && curTfBarTime != g_lastScanBarTime);
   
   // Check if force refresh is needed (for market close or missing labels)
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
   
   // Rebuild any accidentally-deleted labels directly from their stored
   // data. (Rescanning bars can't recreate them: already-processed bars
   // are never re-processed, so the old "just rescan" approach left the
   // labels missing forever while re-running a full scan every tick.)
   if(CheckLabelsMissing())
      RestoreMissingLabels();

   // Trigger scan on new bar or force refresh
   if(newBar || forceRefresh)
      ScanAndProcess();
  }

// Pulls the chosen timeframe's series and processes any newly closed bars.
void ScanAndProcess(void)
  {
   int bars = MathMax(InpLookbackBars, InpFractalPeriod * 4 + 10);

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   ResetLastError();
   int copied = CopyRates(_Symbol, g_tf, 0, bars, rates);
   if(copied <= (InpFractalPeriod * 2 + 2))
     {
      if(!StillWarmingUp() && !g_loggedCopyRatesFail)
        {
         DebugSoft(StringFormat("data isn't fully available yet (copied=%d, error code %d). Will keep retrying..", copied, GetLastError()));
         g_loggedCopyRatesFail = true;
        }
      return;
     }
   g_loggedCopyRatesFail = false;

   double h[], l[], c[];
   datetime t[];
   ArrayResize(h, copied);
   ArrayResize(l, copied);
   ArrayResize(c, copied);
   ArrayResize(t, copied);
   for(int k = 0; k < copied; k++)
     {
      h[k] = rates[k].high;
      l[k] = rates[k].low;
      c[k] = rates[k].close;
      t[k] = rates[k].time;
     }

   // Resume right AFTER the newest bar that was already processed.
   //
   // BUGFIX: the old version anchored this resume point to the still-
   // FORMING bar's time (t[copied-1]). On every later scan, startIdx then
   // landed on the new forming bar -- which is beyond the processable
   // range -- so the processing loop below ran ZERO times. Net effect:
   // after the initial load, live bars were never processed at all and
   // new CHoCH/BOS labels only appeared again after a reinit (timeframe
   // switch / input change). Tracking the last PROCESSED closed bar
   // instead means every newly closed bar gets picked up exactly once.
   int startIdx = InpFractalPeriod;
   if(g_lastProcessedTime > 0)
     {
      startIdx = copied; // nothing new in this window unless proven otherwise
      for(int k = 0; k < copied; k++)
        {
         if(t[k] > g_lastProcessedTime)
           {
            startIdx = MathMax(InpFractalPeriod, k);
            break;
           }
        }
     }

   // Process every CLOSED bar. Index copied-1 is the still-forming bar and
   // is never touched, so nothing here can repaint.
   //
   // Note this now runs all the way up to the LAST closed bar: a structure
   // break is confirmed by that bar's own close/wick alone, and the fractal
   // checked alongside it sits InpFractalPeriod bars further back, so its
   // right side is fully closed too. (The old bound of
   // copied-InpFractalPeriod-1 delayed every BOS/CHoCH label by
   // InpFractalPeriod extra bars for no reason.)
   int lastClosed = copied - 2;
   for(int i = startIdx; i <= lastClosed; i++)
      ProcessClosedBar(h, l, c, t, i, copied);

   if(lastClosed >= 0 && t[lastClosed] > g_lastProcessedTime)
      g_lastProcessedTime = t[lastClosed];

   g_lastScanBarTime = t[copied - 1];
  }

// Processes a single confirmed bar: checks structure break, then fractal formation.
void ProcessClosedBar(const double &h[], const double &l[], const double &c[], const datetime &t[], int i, int total)
  {
   double breakHighPrice = (InpBreakMode == BREAK_CLOSE) ? c[i] : h[i];
   double breakLowPrice  = (InpBreakMode == BREAK_CLOSE) ? c[i] : l[i];

   if(g_lastHigh.valid && !g_lastHigh.broken && breakHighPrice > g_lastHigh.price)
     {
      bool isChoch = (g_trend != TREND_BULL);
      g_lastHigh.broken = true;
      g_trend = TREND_BULL;
      PlotLabel(t[i], h[i], true, isChoch);
      g_lastLow.valid = false; // re-anchor low reference from a fresh fractal after this break
     }
   else if(g_lastLow.valid && !g_lastLow.broken && breakLowPrice < g_lastLow.price)
     {
      bool isChoch = (g_trend != TREND_BEAR);
      g_lastLow.broken = true;
      g_trend = TREND_BEAR;
      PlotLabel(t[i], l[i], false, isChoch);
      g_lastHigh.valid = false;
     }

   int pivot = i - InpFractalPeriod;
   if(pivot < InpFractalPeriod)
      return;

   if(IsFractalHigh(h, pivot, total, InpFractalPeriod))
     {
      if(!g_lastHigh.valid || h[pivot] > g_lastHigh.price || g_lastHigh.broken)
        {
         g_lastHigh.valid  = true;
         g_lastHigh.broken = false;
         g_lastHigh.price  = h[pivot];
         g_lastHigh.time   = t[pivot];
        }
     }
   if(IsFractalLow(l, pivot, total, InpFractalPeriod))
     {
      if(!g_lastLow.valid || l[pivot] < g_lastLow.price || g_lastLow.broken)
        {
         g_lastLow.valid  = true;
         g_lastLow.broken = false;
         g_lastLow.price  = l[pivot];
         g_lastLow.time   = t[pivot];
        }
     }
  }

bool IsFractalHigh(const double &h[], int i, int total, int period)
  {
   if(i - period < 0 || i + period >= total)
      return false;
   for(int k = i - period; k <= i + period; k++)
     {
      if(k == i) continue;
      if(h[k] >= h[i]) return false;
     }
   return true;
  }

bool IsFractalLow(const double &l[], int i, int total, int period)
  {
   if(i - period < 0 || i + period >= total)
      return false;
   for(int k = i - period; k <= i + period; k++)
     {
      if(k == i) continue;
      if(l[k] <= l[i]) return false;
     }
   return true;
  }

// Draws a small filled Wingdings triangle (not an arrow) at the break bar.
void PlotLabel(datetime t, double price, bool isUp, bool isChoch)
  {
   if(isChoch && !InpShowCHoCH) return;
   if(!isChoch && !InpShowBOS)  return;

   string name = g_prefix + (isChoch ? "CHOCH_" : "BOS_") + (isUp ? "UP_" : "DN_") + TimeToString(t, TIME_DATE|TIME_SECONDS);
   if(ObjectFind(0, name) >= 0)
      return;

   double offset = InpLabelOffsetPips * g_pip;

   LabelInfo info;
   info.name    = name;
   info.time    = t;
   info.price   = isUp ? (price - offset) : (price + offset);
   info.isUp    = isUp;
   info.isChoch = isChoch;

   CreateLabelObject(info);

   int n = ArraySize(g_labelQueue);
   ArrayResize(g_labelQueue, n + 1);
   g_labelQueue[n] = info;
   PruneLabels();
  }

// Creates (or recreates) the chart object for one stored label.
void CreateLabelObject(const LabelInfo &info)
  {
   if(ObjectFind(0, info.name) >= 0)
      return;

   int arrowCode = info.isUp ? 225 : 226; // Wingdings filled triangle up / down

   ResetLastError();
   if(!ObjectCreate(0, info.name, OBJ_ARROW, 0, info.time, info.price))
     {
      DebugErr(StringFormat("ObjectCreate failed for %s, err=%d", info.name, GetLastError()));
      return;
     }

   color clr;
   int   size;
   string tip;
   if(info.isChoch)
     {
      clr  = info.isUp ? InpCHoCH_BullColor : InpCHoCH_BearColor;
      size = InpCHoCH_Size;
      tip  = InpCHoCH_Text + (info.isUp ? " Bullish" : " Bearish");
     }
   else
     {
      clr  = info.isUp ? InpBOS_BullColor : InpBOS_BearColor;
      size = InpBOS_Size;
      tip  = InpBOS_Text + (info.isUp ? " Bullish" : " Bearish");
     }

   ObjectSetInteger(0, info.name, OBJPROP_ARROWCODE, arrowCode);
   ObjectSetInteger(0, info.name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, info.name, OBJPROP_WIDTH, size);
   ObjectSetInteger(0, info.name, OBJPROP_ANCHOR, info.isUp ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(0, info.name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, info.name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, info.name, OBJPROP_TOOLTIP, tip);
  }

// Rebuilds every stored label whose chart object no longer exists.
void RestoreMissingLabels(void)
  {
   bool restored = false;
   for(int i = 0; i < ArraySize(g_labelQueue); i++)
     {
      if(ObjectFind(0, g_labelQueue[i].name) < 0)
        {
         CreateLabelObject(g_labelQueue[i]);
         restored = true;
        }
     }
   if(restored)
      ChartRedraw(0);
  }

// Keeps only the most recent InpMaxLabels labels on the chart.
void PruneLabels()
  {
   int n = ArraySize(g_labelQueue);
   if(n <= InpMaxLabels)
      return;
   int toRemove = n - InpMaxLabels;
   for(int i = 0; i < toRemove; i++)
      ObjectDelete(0, g_labelQueue[i].name);

   int remaining = n - toRemove;
   for(int i = 0; i < remaining; i++)
      g_labelQueue[i] = g_labelQueue[i + toRemove];
   ArrayResize(g_labelQueue, remaining);
  }

//+------------------------------------------------------------------+
//| Check if any CHoCH/BOS labels are missing from the chart         |
//+------------------------------------------------------------------+
bool CheckLabelsMissing(void)
  {
   int n = ArraySize(g_labelQueue);
   if(n == 0)
      return false;
   
   // Check a few of the most recent labels
   int checkCount = MathMin(5, n);
   for(int i = n - checkCount; i < n; i++)
     {
      if(ObjectFind(0, g_labelQueue[i].name) < 0)
         return true;
     }
   
   return false;
  }

void DebugErr(string msg)
  {
   Print("[CHoCH/BOS][ERROR] ", msg);
  }

void DebugSoft(string msg)
  {
   Print("[CHoCH/BOS] ", msg);
  }