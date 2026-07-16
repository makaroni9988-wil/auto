//+------------------------------------------------------------------+
//| AutoFibRetracement.mq5                                           |
//| MQL5 port "Auto Fib Retracement"                                 |
//| v2: corrected pivot engine — windowed pivot detection (Depth/2   |
//| left/right bars) with deviation-gated reversals only,            |
//| No live-tracking/repainting.                                     |
//| v3: (1) full state reset on history reload/timeframe switch,     |
//| (2) ATR period as input, (3) deviation threshold sampled at the  |
//| pivot bar itself, (4) fills extend right with the level lines.   |
//|                                                                  |
//| v4: EA-PARITY ENGINE. The zigzag is rebuilt FROM SCRATCH on      |
//| every new bar over the last LookbackBars bars, INCLUDING the     |
//| still-forming candle -- exactly like AutoFibTrader's             |
//| UpdateLeg(). No pivot is ever latched: if a live spike kills a   |
//| freshly-confirmed pivot, the leg re-anchors at the next bar      |
//| open, same as the EA. Consequence: the drawn fib CAN re-anchor   |
//| between bars -- that is the EA's real behavior made visible.     |
//| Match Depth / DeviationMult / ATRPeriod / LookbackBars to the    |
//| EA and put this chart on the EA's InpTimeframe: the leg you see  |
//| IS the leg the EA trades.                                        |
//+------------------------------------------------------------------+
#property copyright "MQL5 port"
#property version   "4.00"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

input double DeviationMult      = 3.0;    // Deviation multiplier (ATR-based %) 
input int    Depth              = 6;      // Depth (total bars for pivot confirmation; left/right = Depth/2)
input int    ATRPeriod          = 10;     // ATR period for deviation threshold
input bool   Reverse            = false;  // Reverse anchor direction
input bool   ExtendLeft         = false;  // Extend lines left
input bool   ExtendRight        = true;   // Extend lines right
input bool   ShowPrices         = false;  // Show price values on labels
input bool   ShowLevels         = false;  // Show level values on labels
input bool   LevelsAsPercent    = false;  // Show levels as percent instead of ratio
input bool   LabelsOnLeft       = false;  // Labels on left (false = right)
input int    BackgroundTransparencyPct = 85; // Fill transparency (0=solid,100=invisible)
input bool   EnableAlerts       = false;  // Alert on level cross

input int    InpRefreshSeconds  = 30;     // Force refresh interval in seconds (missing-object recovery)
input int    LookbackBars       = 100;    // Bars scanned for the current leg (MATCH THE EA)

input bool   Show_neg_0_65   = false; input double Val_neg_0_65   = -0.65;  input color Col_neg_0_65   = clrTeal;
input bool   Show_neg_0_618  = false; input double Val_neg_0_618  = -0.618; input color Col_neg_0_618  = clrTeal;
input bool   Show_neg_0_382  = false; input double Val_neg_0_382  = -0.382; input color Col_neg_0_382  = clrLightGreen;
input bool   Show_neg_0_236  = false; input double Val_neg_0_236  = -0.236; input color Col_neg_0_236  = clrRed;
input bool   Show_0          = false; input double Val_0          = 0.0;    input color Col_0          = clrGray;
input bool   Show_0_236      = false; input double Val_0_236      = 0.236;  input color Col_0_236      = clrRed;

// Trend Zone (original LightGreen)
input bool   Show_0_382      = true;  input double Val_0_382      = 0.382;  input color Col_0_382      = clrRed;

// Golden Zone (original Green, Teal)
input bool   Show_0_5        = false; input double Val_0_5        = 0.5;    input color Col_0_5        = clrRed;
input bool   Show_0_618      = true;  input double Val_0_618      = 0.618;  input color Col_0_618      = clrRed;

input bool   Show_0_65       = false; input double Val_0_65       = 0.65;   input color Col_0_65       = clrTeal;
input bool   Show_0_786      = false; input double Val_0_786      = 0.786;  input color Col_0_786      = clrDodgerBlue;
input bool   Show_1          = false; input double Val_1          = 1.0;    input color Col_1          = clrGray;
input bool   Show_1_272      = false; input double Val_1_272      = 1.272;  input color Col_1_272      = clrLightGreen;
input bool   Show_1_414      = false; input double Val_1_414      = 1.414;  input color Col_1_414      = clrRed;
input bool   Show_1_618      = false; input double Val_1_618      = 1.618;  input color Col_1_618      = clrBlue;
input bool   Show_1_65       = false; input double Val_1_65       = 1.65;   input color Col_1_65       = clrBlue;
input bool   Show_2_618      = false; input double Val_2_618      = 2.618;  input color Col_2_618      = clrRed;
input bool   Show_2_65       = false; input double Val_2_65       = 2.65;   input color Col_2_65       = clrRed;
input bool   Show_3_618      = false; input double Val_3_618      = 3.618;  input color Col_3_618      = clrPurple;
input bool   Show_3_65       = false; input double Val_3_65       = 3.65;   input color Col_3_65       = clrPurple;
input bool   Show_4_236      = false; input double Val_4_236      = 4.236;  input color Col_4_236      = clrMagenta;
input bool   Show_4_618      = false; input double Val_4_618      = 4.618;  input color Col_4_618      = clrLightGreen;

#define NUM_LEVELS 22
bool   g_show[NUM_LEVELS];
double g_value[NUM_LEVELS];
color  g_color[NUM_LEVELS];
int    g_sortedIdx[NUM_LEVELS]; // indices sorted ascending by value, for fill pairing

int g_atrHandle = INVALID_HANDLE;

// --- ZigZag state (windowed pivot detection + deviation-gated reversal) ---
bool   g_haveLastZZ  = false;
double g_lastZZPrice = 0;  int g_lastZZBar = -1;  int g_lastZZType = -1; // 1=HIGH, 0=LOW

bool   g_havePrevZZ  = false;   // true once we have a full leg (prev -> last)
double g_olderPrice  = 0;  int g_olderBar = -1;    // = prevZZ (fixed, older anchor)
double g_newerPrice  = 0;  int g_newerBar = -1;    // = lastZZ (fixed, newer anchor)

datetime g_lastScanBarTime = 0;    // engine rescans from scratch once per new bar (EA parity)
datetime g_lastAlertBarTime = 0;   // 64-bit, 2038-safe (suite standard)

string g_prefix;                    // unique object prefix per instance

// --- draw gating: the fib objects only actually change on a new bar or
// a new zigzag leg, yet v3 rewrote every line/label/fill and ran 44
// ObjectFind calls on EVERY TICK. State below gates the whole draw block.
int      g_drawnOlderBar   = -1;
int      g_drawnNewerBar   = -1;
datetime g_drawnBarTime    = 0;
datetime g_lastForceRefresh = 0;

// --- last-drawn geometry, captured at the end of each successful draw so
// the 1-second timer can restore the whole fib from stored values WITHOUT
// re-running the pivot engine (that engine indexes the live rates array,
// so it is unsafe to re-run from a copied window). This is dead-market
// self-heal: if "delete all objects" / a template reload wipes the fib
// while the market is closed, the timer redraws it from these values.
bool     g_haveRender  = false;
datetime g_rLegT1 = 0, g_rLegT2 = 0;   // leg anchors (two pivot bar times)
double   g_rLegP1 = 0, g_rLegP2 = 0;
datetime g_rT1 = 0, g_rT2 = 0, g_rFillEnd = 0; // level/fill anchors
double   g_rStartPrice = 0, g_rHeight = 0;     // level price = start + height*ratio

// --- log-once + warm-up grace (suite pattern) ---
bool g_loggedCopyFail = false;
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS; // uint wrap-safe
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_atrHandle = iATR(_Symbol, _Period, MathMax(1, ATRPeriod));
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("AutoFib ERROR: failed to create ATR handle, error code ", GetLastError(), ".");
      return(INIT_FAILED);
   }

   // unique per instance: two copies with different settings no longer
   // fight over the same objects
   g_prefix = StringFormat("AF_%d_%d_", Depth, (int)MathRound(DeviationMult * 100.0));

   int i = 0;
   g_show[i]=Show_neg_0_65;  g_value[i]=Val_neg_0_65;  g_color[i]=Col_neg_0_65;  i++;
   g_show[i]=Show_neg_0_618; g_value[i]=Val_neg_0_618; g_color[i]=Col_neg_0_618; i++;
   g_show[i]=Show_neg_0_382; g_value[i]=Val_neg_0_382; g_color[i]=Col_neg_0_382; i++;
   g_show[i]=Show_neg_0_236; g_value[i]=Val_neg_0_236; g_color[i]=Col_neg_0_236; i++;
   g_show[i]=Show_0;         g_value[i]=Val_0;         g_color[i]=Col_0;         i++;
   g_show[i]=Show_0_236;     g_value[i]=Val_0_236;     g_color[i]=Col_0_236;     i++;
   g_show[i]=Show_0_382;     g_value[i]=Val_0_382;     g_color[i]=Col_0_382;     i++;
   g_show[i]=Show_0_5;       g_value[i]=Val_0_5;       g_color[i]=Col_0_5;       i++;
   g_show[i]=Show_0_618;     g_value[i]=Val_0_618;     g_color[i]=Col_0_618;     i++;
   g_show[i]=Show_0_65;      g_value[i]=Val_0_65;      g_color[i]=Col_0_65;      i++;
   g_show[i]=Show_0_786;     g_value[i]=Val_0_786;     g_color[i]=Col_0_786;     i++;
   g_show[i]=Show_1;         g_value[i]=Val_1;         g_color[i]=Col_1;         i++;
   g_show[i]=Show_1_272;     g_value[i]=Val_1_272;     g_color[i]=Col_1_272;     i++;
   g_show[i]=Show_1_414;     g_value[i]=Val_1_414;     g_color[i]=Col_1_414;     i++;
   g_show[i]=Show_1_618;     g_value[i]=Val_1_618;     g_color[i]=Col_1_618;     i++;
   g_show[i]=Show_1_65;      g_value[i]=Val_1_65;      g_color[i]=Col_1_65;      i++;
   g_show[i]=Show_2_618;     g_value[i]=Val_2_618;     g_color[i]=Col_2_618;     i++;
   g_show[i]=Show_2_65;      g_value[i]=Val_2_65;      g_color[i]=Col_2_65;      i++;
   g_show[i]=Show_3_618;     g_value[i]=Val_3_618;     g_color[i]=Col_3_618;     i++;
   g_show[i]=Show_3_65;      g_value[i]=Val_3_65;      g_color[i]=Col_3_65;      i++;
   g_show[i]=Show_4_236;     g_value[i]=Val_4_236;     g_color[i]=Col_4_236;     i++;
   g_show[i]=Show_4_618;     g_value[i]=Val_4_618;     g_color[i]=Col_4_618;     i++;

   // sort indices ascending by value (simple insertion sort, 22 items)
   for(int k = 0; k < NUM_LEVELS; k++) g_sortedIdx[k] = k;
   for(int a = 1; a < NUM_LEVELS; a++)
   {
      int keyIdx = g_sortedIdx[a];
      double keyVal = g_value[keyIdx];
      int b = a - 1;
      while(b >= 0 && g_value[g_sortedIdx[b]] > keyVal)
      {
         g_sortedIdx[b+1] = g_sortedIdx[b];
         b--;
      }
      g_sortedIdx[b+1] = keyIdx;
   }

   g_haveLastZZ = false;
   g_havePrevZZ = false;
   g_lastScanBarTime = 0;
   g_drawnOlderBar = -1;
   g_drawnNewerBar = -1;
   g_drawnBarTime  = 0;
   g_lastForceRefresh = 0;
   // Globals survive a TF/symbol switch: without this reset the 1s timer
   // could self-heal from geometry captured on the OLD chart before the
   // first full pass here has produced a leg for the new one.
   g_haveRender = false;
   g_initTick = GetTickCount();
   g_loggedCopyFail = false;

   IndicatorSetString(INDICATOR_SHORTNAME, "Auto Fib Retracement");

   // 1-second self-heal timer (suite standard, matches Sub-/Float-Chart).
   // Ticks alone can't restore a wiped fib on a dead/closed market. The
   // timer only redraws from stored geometry when the leg canary is gone
   // (see OnTimer) -- it never re-runs the pivot engine, and does nothing
   // when the objects are present. The per-tick path (OnCalculate) is
   // unchanged.
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
string LevelText(int idx, double price)
{
   string s = "";
   if(ShowLevels)
   {
      if(LevelsAsPercent)
         s += DoubleToString(g_value[idx]*100, 1) + "%";
      else
         s += DoubleToString(g_value[idx], 3);
   }
   if(ShowPrices)
   {
      if(s != "") s += " ";
      s += "(" + DoubleToString(price, _Digits) + ")";
   }
   return s;
}

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
void DrawLeg(datetime t1, double p1, datetime t2, double p2)
{
   string name = g_prefix + "leg";
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrSilver);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
}

//+------------------------------------------------------------------+
void DrawLevelLine(int idx, datetime t1, datetime t2, double price)
{
   string name = g_prefix + "line_" + IntegerToString(idx);
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false); // click-proof on a scalping chart
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);      // out of the objects list
   }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, g_color[idx]);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, ExtendLeft);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, ExtendRight);

   string lblName = g_prefix + "lbl_" + IntegerToString(idx);
   datetime lblTime = LabelsOnLeft ? t1 : t2;
   if(ObjectFind(0, lblName) < 0)
   {
      ObjectCreate(0, lblName, OBJ_TEXT, 0, lblTime, price);
      ObjectSetInteger(0, lblName, OBJPROP_ANCHOR, LabelsOnLeft ? ANCHOR_RIGHT : ANCHOR_LEFT);
      ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lblName, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, lblName, OBJPROP_TIME, 0, lblTime);
   ObjectSetDouble(0, lblName, OBJPROP_PRICE, 0, price);
   ObjectSetString(0, lblName, OBJPROP_TEXT, " " + LevelText(idx, price) + " ");
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, g_color[idx]);
}

void HideLevel(int idx)
{
   string name = g_prefix + "line_" + IntegerToString(idx);
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   string lblName = g_prefix + "lbl_" + IntegerToString(idx);
   if(ObjectFind(0, lblName) >= 0) ObjectDelete(0, lblName);
}

//+------------------------------------------------------------------+
void DrawFill(int fillIdx, int idxLow, int idxHigh, double priceLow, double priceHigh,
              datetime t1, datetime t2)
{
   string name = g_prefix + "fill_" + IntegerToString(fillIdx);
   color baseCol = g_color[idxLow];
   color blended = BlendWithBackground(baseCol, BackgroundTransparencyPct);
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, priceHigh, t2, priceLow);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, priceHigh);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, priceLow);
   ObjectSetInteger(0, name, OBJPROP_COLOR, blended);
}

void HideFill(int fillIdx)
{
   string name = g_prefix + "fill_" + IntegerToString(fillIdx);
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
}

//+------------------------------------------------------------------+
bool IsPivotHighAt(const double &high[], int idx, int total, int prd)
{
   if(idx - prd < 0 || idx + prd >= total) return false;
   double val = high[idx];
   for(int j = idx - prd; j <= idx + prd; j++)
   {
      if(j == idx) continue;
      if(high[j] >= val) return false;
   }
   return true;
}

bool IsPivotLowAt(const double &low[], int idx, int total, int prd)
{
   if(idx - prd < 0 || idx + prd >= total) return false;
   double val = low[idx];
   for(int j = idx - prd; j <= idx + prd; j++)
   {
      if(j == idx) continue;
      if(low[j] <= val) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
// Handles one confirmed pivot candidate: extend same-direction pivots,
// or lock in a reversal if the deviation threshold is met.
//+------------------------------------------------------------------+
void ProcessPivot(int idx, double price, int pivType, double devPct)
{
   if(!g_haveLastZZ)
   {
      g_lastZZPrice = price; g_lastZZBar = idx; g_lastZZType = pivType;
      g_haveLastZZ = true;
      return;
   }

   if(pivType == g_lastZZType)
   {
      // same direction: extend if this pivot is more extreme
      bool better = (pivType == 1) ? (price > g_lastZZPrice) : (price < g_lastZZPrice);
      if(better)
      {
         g_lastZZPrice = price; g_lastZZBar = idx;
         if(g_havePrevZZ)
         { g_newerPrice = g_lastZZPrice; g_newerBar = g_lastZZBar; }
      }
      return;
   }

   // opposite direction: only accept as a reversal if deviation threshold is met
   if(devPct <= 0) return;
   double dev = (g_lastZZPrice != 0.0) ? MathAbs(price - g_lastZZPrice) / MathAbs(g_lastZZPrice) * 100.0 : 0.0;
   if(dev >= devPct)
   {
      g_olderPrice = g_lastZZPrice; g_olderBar = g_lastZZBar;
      g_lastZZPrice = price; g_lastZZBar = idx; g_lastZZType = pivType;
      g_newerPrice = g_lastZZPrice; g_newerBar = g_lastZZBar;
      g_havePrevZZ = true;
   }
   // else: not a big enough move yet — ignore this candidate
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
   int prd = MathMax(1, Depth / 2);
   if(rates_total < 2*prd + 2) return(0);

   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   // --- EA-PARITY ENGINE (v4): full rescan once per new bar ---
   // Mirrors AutoFibTrader.UpdateLeg(): every new bar the zigzag state is
   // wiped and rebuilt over the last LookbackBars bars, INCLUDING the
   // still-forming candle. Nothing is latched, so a live spike that kills a
   // freshly-confirmed pivot re-routes the leg at the next bar open --
   // exactly like the EA. Same window, same math, same cadence.
   bool fullPass = (prev_calculated == 0 || prev_calculated > rates_total);
   if(fullPass)
   {
      // first run, timeframe switch, or history reload: wipe everything so
      // stale anchors / stored heal geometry from old data can't survive
      ObjectsDeleteAll(0, g_prefix);
      g_drawnOlderBar = -1;
      g_drawnNewerBar = -1;
      g_drawnBarTime  = 0;
      g_haveRender    = false;
      g_lastScanBarTime = 0;
   }

   int bars = (int)MathMin((long)LookbackBars, (long)rates_total);
   if(bars < 2*prd + 3) return(rates_total);

   if(fullPass || time[rates_total-1] != g_lastScanBarTime)
   {
      // ATR tail for the scan window only (window index k <-> atr[k])
      double atr[];
      ArraySetAsSeries(atr, false);
      ResetLastError();
      int copied = CopyBuffer(g_atrHandle, 0, 0, bars, atr);
      if(copied < bars)
      {
         // Transient (attach warm-up) failures retry silently; a persistent
         // one is logged ONCE. Returning prev_calculated (not 0) avoids the
         // full state-reset + ObjectsDeleteAll flicker on the very next tick.
         // g_lastScanBarTime is NOT stored, so the scan retries next tick.
         if(!StillWarmingUp() && !g_loggedCopyFail)
         {
            Print("AutoFib ERROR: CopyBuffer() failed for ATR (copied=", copied,
                  "), error code ", GetLastError(), ". Will keep retrying..");
            g_loggedCopyFail = true;
         }
         return(prev_calculated);
      }
      g_loggedCopyFail = false; // recovered
      g_lastScanBarTime = time[rates_total-1];

      // full state reset each scan (EA parity: prevents leg drift)
      g_haveLastZZ = false; g_havePrevZZ = false;
      g_lastZZPrice = 0;    g_lastZZBar = -1;  g_lastZZType = -1;
      g_olderPrice = 0;     g_olderBar = -1;
      g_newerPrice = 0;     g_newerBar = -1;

      int base = rates_total - bars; // window index k <-> chronological index base+k
      for(int i = 2*prd; i < bars; i++)
      {
         int pivotIdx = i - prd;      // window index of the pivot candidate
         if(pivotIdx < prd) continue;
         int gIdx = base + pivotIdx;  // chronological index into time/high/low/close

         // deviation threshold sampled at the pivot bar itself (v3 fix):
         // the swing is judged by the volatility at the time it happened,
         // not by conditions prd bars later when it confirms
         double atrVal = atr[pivotIdx];
         double devPct = (close[gIdx] != 0.0 && atrVal > 0.0)
            ? (atrVal / close[gIdx]) * 100.0 * DeviationMult : 0.0;

         bool ph = IsPivotHighAt(high, gIdx, rates_total, prd);
         bool pl = IsPivotLowAt(low, gIdx, rates_total, prd);

         if(ph) ProcessPivot(gIdx, high[gIdx], 1, devPct);
         if(pl) ProcessPivot(gIdx, low[gIdx],  0, devPct);
      }
   }

   // no valid leg in the window (the EA would not trade): show nothing
   if(!g_havePrevZZ)
   {
      if(g_drawnOlderBar >= 0 || g_haveRender)
      {
         ObjectsDeleteAll(0, g_prefix);
         g_drawnOlderBar = -1;
         g_drawnNewerBar = -1;
         g_drawnBarTime  = 0;
         g_haveRender    = false;
      }
      return(rates_total);
   }

   // --- draw/update fib levels using the current leg (older -> newer) ---
   // GATED: the drawn output only actually changes on a new zigzag leg or
   // a new bar (the right edge t2 moves per bar). v3 rewrote every
   // line/label/fill and ran 44 ObjectFind calls on EVERY TICK for
   // nothing. Missing-object recovery rides the 30s force refresh.
   bool legChanged = (g_olderBar != g_drawnOlderBar || g_newerBar != g_drawnNewerBar);
   bool newBar     = (time[rates_total-1] != g_drawnBarTime);

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

   // canary: if the leg exists but its object was wiped (delete-all,
   // template reload), redraw everything on the next pass
   bool canaryMissing = (g_havePrevZZ && ObjectFind(0, g_prefix + "leg") < 0);

   if(g_havePrevZZ && (legChanged || newBar || forceRefresh || canaryMissing))
   {
      DrawLeg(time[g_olderBar], g_olderPrice, time[g_newerBar], g_newerPrice);

      g_drawnOlderBar = g_olderBar;
      g_drawnNewerBar = g_newerBar;
      g_drawnBarTime  = time[rates_total-1];
      double lpStart = g_olderPrice;
      double lpEnd   = g_newerPrice;
      double startPrice = Reverse ? lpStart : lpEnd;
      double endPrice   = Reverse ? lpEnd   : lpStart;
      double height = (startPrice > endPrice ? -1.0 : 1.0) * MathAbs(startPrice - endPrice);

      datetime t1 = time[g_olderBar];
      datetime t2 = time[rates_total-1];

      // fills can't use ray-extension like trendlines, so when ExtendRight is on,
      // anchor their right edge far into the future (~5000 bars) — visually
      // indistinguishable from an infinite extension on screen (v3 fix)
      datetime tFillEnd = ExtendRight ? t2 + (datetime)PeriodSeconds() * 5000 : t2;

      double levelPrice[NUM_LEVELS];
      for(int idx = 0; idx < NUM_LEVELS; idx++)
      {
         if(g_show[idx])
         {
            double price = startPrice + height * g_value[idx];
            levelPrice[idx] = price;
            DrawLevelLine(idx, t1, t2, price);
         }
         else
         {
            HideLevel(idx);
            levelPrice[idx] = EMPTY_VALUE;
         }
      }

      // fills between consecutive shown levels (ascending order)
      int fillCounter = 0;
      int prevShown = -1;
      for(int s = 0; s < NUM_LEVELS; s++)
      {
         int idx = g_sortedIdx[s];
         if(!g_show[idx]) continue;
         if(prevShown >= 0)
         {
            double pLow  = MathMin(levelPrice[prevShown], levelPrice[idx]);
            double pHigh = MathMax(levelPrice[prevShown], levelPrice[idx]);
            DrawFill(fillCounter, prevShown, idx, pLow, pHigh, t1, tFillEnd);
            fillCounter++;
         }
         prevShown = idx;
      }
      for(int f = fillCounter; f < NUM_LEVELS; f++) HideFill(f);

      // Capture this render's geometry so the timer can restore it on a
      // dead market without re-running the pivot engine (see the globals
      // block and RenderFromStored). Everything here is already in scope.
      g_rLegT1 = time[g_olderBar]; g_rLegP1 = g_olderPrice;
      g_rLegT2 = time[g_newerBar]; g_rLegP2 = g_newerPrice;
      g_rT1 = t1; g_rT2 = t2; g_rFillEnd = tFillEnd;
      g_rStartPrice = startPrice;  g_rHeight = height;
      g_haveRender = true;

      // crossing alerts: evaluated once per NEW bar, on the just-CLOSED
      // candle. (v3 read the LIVE close: a mid-candle wiggle across a
      // level popped an early -- possibly false -- alert, and the
      // once-per-bar guard then blocked the real cross if it happened
      // later in the same candle.)
      if(EnableAlerts && rates_total >= 3)
      {
         datetime closedBarTime = time[rates_total-2];
         if(closedBarTime != g_lastAlertBarTime)
         {
            double cNow  = close[rates_total-2]; // last CLOSED candle
            double cPrev = close[rates_total-3];
            for(int idx = 0; idx < NUM_LEVELS; idx++)
            {
               if(!g_show[idx]) continue;
               double r = levelPrice[idx];
               bool crossed = (cNow > r && cPrev < r) || (cNow < r && cPrev > r);
               if(crossed)
               {
                  Alert("AutoFib: ", _Symbol, " ", EnumToString(_Period), " closed across level ", DoubleToString(g_value[idx], 3));
                  g_lastAlertBarTime = closedBarTime;
               }
            }
         }
      }

      // ONE repaint per draw pass (new bar / leg change / heal), so
      // object updates show instantly even with no follow-up tick.
      ChartRedraw(0);
   }

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Timer: dead-market self-heal ONLY. OnCalculate runs on ticks, so |
//| on a frozen/closed market a wiped fib (delete-all, template      |
//| reload) never comes back. The timer detects the wiped leg        |
//| (canary) and restores the whole fib from the last render's       |
//| STORED geometry -- it never re-runs the pivot engine, so there   |
//| is no risk of index misalignment against the live rates array.   |
//| When nothing is missing (or nothing has drawn yet) it does       |
//| nothing, so a live market is unaffected.                         |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_haveRender && ObjectFind(0, g_prefix + "leg") < 0)
      RenderFromStored();
}

//+------------------------------------------------------------------+
//| Redraw leg + level lines + fills from the stored geometry only.  |
//| Mirrors the draw block in OnCalculate but uses the captured      |
//| anchors/prices instead of the live arrays, so it is safe to call |
//| from the timer with no rates_total context.                      |
//+------------------------------------------------------------------+
void RenderFromStored()
{
   if(!g_haveRender)
      return;

   DrawLeg(g_rLegT1, g_rLegP1, g_rLegT2, g_rLegP2);

   double levelPrice[NUM_LEVELS];
   for(int idx = 0; idx < NUM_LEVELS; idx++)
   {
      if(g_show[idx])
      {
         double price = g_rStartPrice + g_rHeight * g_value[idx];
         levelPrice[idx] = price;
         DrawLevelLine(idx, g_rT1, g_rT2, price);
      }
      else
      {
         HideLevel(idx);
         levelPrice[idx] = EMPTY_VALUE;
      }
   }

   int fillCounter = 0;
   int prevShown   = -1;
   for(int s = 0; s < NUM_LEVELS; s++)
   {
      int idx = g_sortedIdx[s];
      if(!g_show[idx]) continue;
      if(prevShown >= 0)
      {
         double pLow  = MathMin(levelPrice[prevShown], levelPrice[idx]);
         double pHigh = MathMax(levelPrice[prevShown], levelPrice[idx]);
         DrawFill(fillCounter, prevShown, idx, pLow, pHigh, g_rT1, g_rFillEnd);
         fillCounter++;
      }
      prevShown = idx;
   }
   for(int f = fillCounter; f < NUM_LEVELS; f++) HideFill(f);

   ChartRedraw(0);
}
//+------------------------------------------------------------------+