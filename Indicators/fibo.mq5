//+------------------------------------------------------------------+
//| fibo.mq5 — Auto Fib Retracement (NORMAL ZigZag engine)           |
//|                                                                  |
//| Draws a fib retracement off the latest ZigZag leg. The ZigZag is |
//| a self-calculated port of the standard MetaQuotes ZigZag         |
//| (Depth / Deviation-in-points / Backstep) -- NO ATR, NO iCustom.  |
//| Drop a ZigZag indicator with the same three params on the chart  |
//| and the leg lines up exactly. This is the plain twin of          |
//| fibo-atr.mq5 (ATR deviation) -- only the pivot engine differs;   |
//| every draw / refresh / self-heal / level is identical.           |
//|                                                                  |
//| Engine cadence (unchanged from the -atr build): the zigzag is    |
//| rebuilt from scratch once per NEW BAR over the last LookbackBars |
//| bars; nothing is latched, so the leg can re-anchor at bar open.  |
//| Leg = the two most recent alternating swings (older -> newer).   |
//|                                                                  |
//| v1.10: FiboStructureShift lets the fib anchor to an OLDER leg    |
//| while the zigzag keeps drawing the newest swing. 1 = newest leg  |
//| (unchanged), 2 = one confirmed swing behind, etc. Only the leg   |
//| the fib picks moves; the pivot engine is untouched.              |
//+------------------------------------------------------------------+
#property copyright "MQL5 port"
#property version   "1.10"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

input int    Depth              = 12;     // ZigZag depth (bars)
input int    Deviation          = 5;      // ZigZag deviation (points)
input int    Backstep           = 3;      // ZigZag backstep (bars)
input int    FiboStructureShift = 1;      // Fib leg age (1=newest, 2=one leg behind, ...)
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
input int    LookbackBars       = 200;    // Bars scanned for the current leg (MATCH THE EA)

input bool   Show_neg_0_65   = false; input double Val_neg_0_65   = -0.65;  input color Col_neg_0_65   = clrTeal;
input bool   Show_neg_0_618  = false; input double Val_neg_0_618  = -0.618; input color Col_neg_0_618  = clrTeal;
input bool   Show_neg_0_382  = false; input double Val_neg_0_382  = -0.382; input color Col_neg_0_382  = clrLightGreen;
input bool   Show_neg_0_236  = false; input double Val_neg_0_236  = -0.236; input color Col_neg_0_236  = clrRed;
input bool   Show_0          = false; input double Val_0          = 0.0;    input color Col_0          = clrGray;
input bool   Show_0_236      = false; input double Val_0_236      = 0.236;  input color Col_0_236      = clrRed;
input bool   Show_0_382      = false; input double Val_0_382      = 0.382;  input color Col_0_382      = clrLightGreen;

// Golden Zone (original Green, Teal)
input bool   Show_0_5        = true;  input double Val_0_5        = 0.5;    input color Col_0_5        = clrRed;
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

// --- ZigZag leg state (standard Depth/Deviation/Backstep engine) ---
// The scan fills the latest leg's two anchors; the draw code below is
// unchanged and only ever reads these four + g_havePrevZZ.
bool   g_havePrevZZ  = false;   // true once we have a full leg (older -> newer)
double g_olderPrice  = 0;  int g_olderBar = -1;    // older anchor
double g_newerPrice  = 0;  int g_newerBar = -1;    // newer anchor

datetime g_lastScanBarTime = 0;    // engine rescans from scratch once per new bar
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

//+------------------------------------------------------------------+
int OnInit()
{
   // unique per instance: two copies with different settings no longer
   // fight over the same objects
   g_prefix = StringFormat("AF_%d_%d_%d_", Depth, Deviation, Backstep);

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

   IndicatorSetString(INDICATOR_SHORTNAME, "Auto Fib Retracement (ZigZag)");

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
//| Index of the lowest low / highest high over [from,to] (inclusive)|
//+------------------------------------------------------------------+
int RangeLowest(const double &a[], int from, int to)
{
   if(from < 0) from = 0;
   int idx = to; double v = a[to];
   for(int j = to - 1; j >= from; j--)
      if(a[j] < v) { v = a[j]; idx = j; }
   return idx;
}

int RangeHighest(const double &a[], int from, int to)
{
   if(from < 0) from = 0;
   int idx = to; double v = a[to];
   for(int j = to - 1; j >= from; j--)
      if(a[j] > v) { v = a[j]; idx = j; }
   return idx;
}

//+------------------------------------------------------------------+
//| Standard MetaQuotes ZigZag (Depth / Deviation-points / Backstep),|
//| self-calculated over the last `bars` window. Fills the latest    |
//| leg's two anchors (older -> newer) into the globals; no ATR, no  |
//| iCustom. Same two-pass algorithm as a ZigZag indicator on chart. |
//+------------------------------------------------------------------+
void ScanZigZagLeg(const int rates_total, const int bars,
                   const double &high[], const double &low[])
{
   const int    depth    = MathMax(1, Depth);
   const int    backstep = MathMax(0, Backstep);
   const double devPts   = MathMax(0, Deviation) * _Point;
   if(bars < depth + backstep + 3) return;

   const int base = rates_total - bars; // window index k <-> chronological base+k

   double hi[], lo[], hiMap[], loMap[];
   ArrayResize(hi, bars); ArrayResize(lo, bars);
   ArrayResize(hiMap, bars); ArrayResize(loMap, bars);
   for(int i = 0; i < bars; i++)
   {
      hi[i] = high[base + i]; lo[i] = low[base + i];
      hiMap[i] = 0.0; loMap[i] = 0.0;
   }

   // ---- pass 1: mark local extremes (deviation + backstep cleanup) ----
   double p1low = 0.0, p1high = 0.0;
   for(int i = depth; i < bars; i++)
   {
      double ext = lo[RangeLowest(lo, i - depth + 1, i)];
      if(ext == p1low) ext = 0.0;
      else
      {
         p1low = ext;
         if(lo[i] - ext > devPts) ext = 0.0;
         else
            for(int back = 1; back <= backstep; back++)
            {
               int pos = i - back; if(pos < 0) break;
               if(loMap[pos] != 0.0 && loMap[pos] > ext) loMap[pos] = 0.0;
            }
      }
      loMap[i] = (lo[i] == ext) ? ext : 0.0;

      ext = hi[RangeHighest(hi, i - depth + 1, i)];
      if(ext == p1high) ext = 0.0;
      else
      {
         p1high = ext;
         if(ext - hi[i] > devPts) ext = 0.0;
         else
            for(int back = 1; back <= backstep; back++)
            {
               int pos = i - back; if(pos < 0) break;
               if(hiMap[pos] != 0.0 && hiMap[pos] < ext) hiMap[pos] = 0.0;
            }
      }
      hiMap[i] = (hi[i] == ext) ? ext : 0.0;
   }

   // ---- pass 2: record every confirmed alternating pivot, oldest -> newest.
   // A pivot is only final once the OPPOSITE extreme confirms (until then it
   // can still relocate), so we push it at each state flip; the last running
   // pivot is pushed after the loop. FiboStructureShift then anchors the fib
   // to a chosen pair without disturbing this engine (shift 1 = last two).
   double swPrice[]; int swPos[];
   int    swN = 0;
   int    whatlookfor = 0;      // 0 = first, 1 = expecting a high, -1 = expecting a low
   int    lastHighPos = -1, lastLowPos = -1;
   double curHigh = 0.0, curLow = 0.0;
   for(int i = depth; i < bars; i++)
   {
      switch(whatlookfor)
      {
         case 0:
            if(loMap[i] != 0.0)  { curLow = loMap[i];  lastLowPos = i;  whatlookfor = 1;  }
            if(hiMap[i] != 0.0)  { curHigh = hiMap[i]; lastHighPos = i; whatlookfor = -1; }
            break;
         case 1: // expecting a high; a deeper low relocates the last low
            if(loMap[i] != 0.0 && loMap[i] < curLow && hiMap[i] == 0.0)
            { lastLowPos = i; curLow = loMap[i]; }
            if(hiMap[i] != 0.0 && loMap[i] == 0.0)
            { PushSwing(swPrice, swPos, swN, curLow, lastLowPos);   // low now final
              curHigh = hiMap[i]; lastHighPos = i; whatlookfor = -1; }
            break;
         case -1: // expecting a low; a higher high relocates the last high
            if(hiMap[i] != 0.0 && hiMap[i] > curHigh && loMap[i] == 0.0)
            { lastHighPos = i; curHigh = hiMap[i]; }
            if(loMap[i] != 0.0 && hiMap[i] == 0.0)
            { PushSwing(swPrice, swPos, swN, curHigh, lastHighPos); // high now final
              curLow = loMap[i]; lastLowPos = i; whatlookfor = 1; }
            break;
      }
   }
   // last running pivot (the newest, still-relocatable one)
   if(whatlookfor == 1)       PushSwing(swPrice, swPos, swN, curLow,  lastLowPos);
   else if(whatlookfor == -1) PushSwing(swPrice, swPos, swN, curHigh, lastHighPos);

   // need at least one full leg (two alternating pivots)
   if(swN < 2) return;

   // shift back by whole pivots; clamp to the oldest available leg
   int s = MathMax(1, FiboStructureShift);
   if(s > swN - 1) s = swN - 1;
   int aPos = swPos[swN - 1 - s], bPos = swPos[swN - s];   // one high, one low
   double aPrice = swPrice[swN - 1 - s], bPrice = swPrice[swN - s];

   // newer = larger bar index (chronologically later)
   if(bPos > aPos)
   {
      g_newerBar = base + bPos; g_newerPrice = bPrice;
      g_olderBar = base + aPos; g_olderPrice = aPrice;
   }
   else
   {
      g_newerBar = base + aPos; g_newerPrice = aPrice;
      g_olderBar = base + bPos; g_olderPrice = bPrice;
   }
   g_havePrevZZ = true;
}

// Append one confirmed swing (price + window bar position) to the ordered
// pivot list. Grows the parallel arrays in lockstep; caller tracks the count.
void PushSwing(double &price[], int &pos[], int &n, double p, int barPos)
{
   ArrayResize(price, n + 1);
   ArrayResize(pos,   n + 1);
   price[n] = p;
   pos[n]   = barPos;
   n++;
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
   int minBars = MathMax(1, Depth) + MathMax(0, Backstep) + 3;
   if(rates_total < minBars) return(0);

   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   // --- ZigZag engine: full rescan once per new bar ---
   // Every new bar the zigzag is wiped and rebuilt over the last
   // LookbackBars bars. Nothing is latched, so the leg can re-anchor at
   // the next bar open. Standard Depth/Deviation/Backstep math, no ATR.
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
   if(bars < minBars) return(rates_total);

   if(fullPass || time[rates_total-1] != g_lastScanBarTime)
   {
      g_lastScanBarTime = time[rates_total-1];

      // full state reset each scan (prevents leg drift)
      g_havePrevZZ = false;
      g_olderPrice = 0;     g_olderBar = -1;
      g_newerPrice = 0;     g_newerBar = -1;

      ScanZigZagLeg(rates_total, bars, high, low);
   }

   // no valid leg in the window: show nothing
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