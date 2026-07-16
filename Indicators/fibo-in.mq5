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
//| v5: PANEL-ONLY BUILD. Renders ONLY with indicator buffers        |
//| (DRAW_LINE levels + leg, DRAW_FILLING zones) so it shows inside  |
//| an OBJ_CHART float/sub panel, where chart objects never display. |
//| The chart-object path has been removed entirely -- use the plain |
//| fibo.mq5 on a normal chart. Panel budget: 8 levels + 4 zones.    |
//| Not available here (buffer limits): text labels, Extend Left/    |
//| Right past the data, tooltips. Cross alerts still work.          |
//|                                                                  |
//| v6: EA-PARITY ENGINE. The zigzag is rebuilt FROM SCRATCH on      |
//| every new bar over the last LookbackBars bars, INCLUDING the     |
//| still-forming candle -- exactly like AutoFibTrader's             |
//| UpdateLeg(). No pivot is ever latched: if a live spike kills a   |
//| freshly-confirmed pivot, the leg re-anchors at the next bar      |
//| open, same as the EA. Consequence: the drawn fib CAN re-anchor   |
//| between bars -- that is the EA's real behavior made visible.     |
//| Match Depth / DeviationMult / ATRPeriod / LookbackBars to the    |
//| EA and put this (sub)chart on the EA's InpTimeframe: the leg     |
//| you see IS the leg the EA trades.                                |
//+------------------------------------------------------------------+
#property copyright "MQL5 port"
#property version   "6.00"
#property indicator_chart_window
#property indicator_buffers 17
#property indicator_plots   13

// PANEL-ONLY BUILD. This file renders ONLY with indicator buffers, so it
// shows correctly INSIDE a float/sub OBJ_CHART panel. It has no chart-object
// path -- use the plain fibo.mq5 on a normal chart. Plot TYPES are never
// changed at runtime: the plot->buffer mapping depends on each type's buffer
// count, so switching a 2-buffer DRAW_FILLING to DRAW_NONE would shift every
// later plot onto the wrong buffers. Layout (fixed at compile time):
//   plots 1-4  : zone fills, DRAW_FILLING (2 buffers each -> 0..7)
//   plot  5    : zigzag leg, DRAW_LINE      (buffer 8)
//   plots 6-13 : fib level lines, DRAW_LINE (buffers 9..16)
#property indicator_type1  DRAW_FILLING
#property indicator_type2  DRAW_FILLING
#property indicator_type3  DRAW_FILLING
#property indicator_type4  DRAW_FILLING
#property indicator_type5  DRAW_LINE
#property indicator_type6  DRAW_LINE
#property indicator_type7  DRAW_LINE
#property indicator_type8  DRAW_LINE
#property indicator_type9  DRAW_LINE
#property indicator_type10 DRAW_LINE
#property indicator_type11 DRAW_LINE
#property indicator_type12 DRAW_LINE
#property indicator_type13 DRAW_LINE

input double DeviationMult      = 3.0;    // Deviation multiplier (ATR-based %) 
input int    Depth              = 6;      // Depth (total bars for pivot confirmation; left/right = Depth/2)
input int    ATRPeriod          = 10;     // ATR period for deviation threshold
input bool   Reverse            = false;  // Reverse anchor direction
input int    BackgroundTransparencyPct = 85; // Fill transparency (0=solid,100=invisible)
input bool   EnableAlerts       = false;  // Alert on level cross
input int    LookbackBars       = 100;    // Bars scanned for the current leg (MATCH THE EA)
// (No ExtendLeft/Right, label, or refresh inputs in this build: buffers
// cannot extend past the data or carry text, and they survive delete-all
// so no missing-object recovery is needed. See the header.)

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

//==================================================================
// PANEL RENDERING (indicator buffers) -- suite standard, matches TL-N
//==================================================================
double BufFillTop1[], BufFillBot1[];   // plot 1 (buffers 0,1)
double BufFillTop2[], BufFillBot2[];   // plot 2 (buffers 2,3)
double BufFillTop3[], BufFillBot3[];   // plot 3 (buffers 4,5)
double BufFillTop4[], BufFillBot4[];   // plot 4 (buffers 6,7)
double BufLeg[];                       // plot 5 (buffer 8)
double BufLevel1[], BufLevel2[], BufLevel3[], BufLevel4[];   // plots 6-9
double BufLevel5[], BufLevel6[], BufLevel7[], BufLevel8[];   // plots 10-13

#define PANEL_MAX_LEVELS 8
#define PANEL_MAX_FILLS  4
#define PANEL_PLOT_FILL0 0   // first fill plot index (runtime, 0-based)
#define PANEL_PLOT_LEG   4   // leg plot index
#define PANEL_PLOT_LVL0  5   // first level plot index

int  g_slotLevel[PANEL_MAX_LEVELS];     // slot -> level idx (0..21)
int  g_numSlots = 0;
int  g_fillLowLvl[PANEL_MAX_FILLS];     // zone -> lower level idx
int  g_fillHighLvl[PANEL_MAX_FILLS];    // zone -> upper level idx
int  g_numFills = 0;
int  g_panelClearedTo = -1;             // buffers initialized up to this bar

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

// Kept only as a code marker so this panel-only build is easy to tell apart
// from the object build (fibo.mq5) at a glance, and to clean any stray
// objects a previous version may have left. This build creates no objects.
string g_prefix;

// --- draw gating: the fib buffers only actually change on a new bar or a
// new zigzag leg, so the redraw below is gated on those two events instead
// of running every tick.
int      g_drawnOlderBar   = -1;
int      g_drawnNewerBar   = -1;
datetime g_drawnBarTime    = 0;

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
   // panel buffers (binding is compile-fixed)
   SetIndexBuffer(0,  BufFillTop1, INDICATOR_DATA);
   SetIndexBuffer(1,  BufFillBot1, INDICATOR_DATA);
   SetIndexBuffer(2,  BufFillTop2, INDICATOR_DATA);
   SetIndexBuffer(3,  BufFillBot2, INDICATOR_DATA);
   SetIndexBuffer(4,  BufFillTop3, INDICATOR_DATA);
   SetIndexBuffer(5,  BufFillBot3, INDICATOR_DATA);
   SetIndexBuffer(6,  BufFillTop4, INDICATOR_DATA);
   SetIndexBuffer(7,  BufFillBot4, INDICATOR_DATA);
   SetIndexBuffer(8,  BufLeg,      INDICATOR_DATA);
   SetIndexBuffer(9,  BufLevel1,   INDICATOR_DATA);
   SetIndexBuffer(10, BufLevel2,   INDICATOR_DATA);
   SetIndexBuffer(11, BufLevel3,   INDICATOR_DATA);
   SetIndexBuffer(12, BufLevel4,   INDICATOR_DATA);
   SetIndexBuffer(13, BufLevel5,   INDICATOR_DATA);
   SetIndexBuffer(14, BufLevel6,   INDICATOR_DATA);
   SetIndexBuffer(15, BufLevel7,   INDICATOR_DATA);
   SetIndexBuffer(16, BufLevel8,   INDICATOR_DATA);
   ArraySetAsSeries(BufFillTop1, false); ArraySetAsSeries(BufFillBot1, false);
   ArraySetAsSeries(BufFillTop2, false); ArraySetAsSeries(BufFillBot2, false);
   ArraySetAsSeries(BufFillTop3, false); ArraySetAsSeries(BufFillBot3, false);
   ArraySetAsSeries(BufFillTop4, false); ArraySetAsSeries(BufFillBot4, false);
   ArraySetAsSeries(BufLeg, false);
   ArraySetAsSeries(BufLevel1, false); ArraySetAsSeries(BufLevel2, false);
   ArraySetAsSeries(BufLevel3, false); ArraySetAsSeries(BufLevel4, false);
   ArraySetAsSeries(BufLevel5, false); ArraySetAsSeries(BufLevel6, false);
   ArraySetAsSeries(BufLevel7, false); ArraySetAsSeries(BufLevel8, false);

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

   PanelSetup(); // map shown levels/zones to plot slots + style or disable plots

   g_haveLastZZ = false;
   g_havePrevZZ = false;
   g_lastScanBarTime = 0;
   g_drawnOlderBar = -1;
   g_drawnNewerBar = -1;
   g_drawnBarTime  = 0;
   g_panelClearedTo = -1; // TF switch rebinds buffers: init cells again
   g_initTick = GetTickCount();
   g_loggedCopyFail = false;

   IndicatorSetString(INDICATOR_SHORTNAME, "Auto Fib Retracement");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, g_prefix);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
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
         {
            g_newerPrice = g_lastZZPrice; g_newerBar = g_lastZZBar;
            // the leg is drawn as a buffer in PanelDraw()
         }
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
      // the leg is drawn as a buffer in PanelDraw()
   }
   // else: not a big enough move yet — ignore this candidate
}

//==================================================================
// PANEL RENDERING helpers (indicator buffers)
//==================================================================
// PanelSetup: runs once in OnInit. Maps the ENABLED levels (ascending)
// to the first 8 level plots and the zones between consecutive shown
// levels to the first 4 fill plots, then styles them from the Col_*
// inputs. Extra enabled levels/zones beyond the budget are reported
// once and simply not drawn.
//+------------------------------------------------------------------+
void PanelSetup()
{
   // ---- map shown levels (ascending by value) to slots ----
   g_numSlots = 0;
   int shownTotal = 0;
   for(int s = 0; s < NUM_LEVELS; s++)
   {
      int idx = g_sortedIdx[s];
      if(!g_show[idx]) continue;
      shownTotal++;
      if(g_numSlots < PANEL_MAX_LEVELS)
         g_slotLevel[g_numSlots++] = idx;
   }

   // ---- zones between consecutive slotted levels ----
   g_numFills = 0;
   int zonesWanted = (g_numSlots > 0) ? g_numSlots - 1 : 0;
   for(int s = 1; s < g_numSlots && g_numFills < PANEL_MAX_FILLS; s++)
   {
      g_fillLowLvl[g_numFills]  = g_slotLevel[s-1];
      g_fillHighLvl[g_numFills] = g_slotLevel[s];
      g_numFills++;
   }

   if(shownTotal > PANEL_MAX_LEVELS)
      Print("AutoFib panel mode: drawing the first ", PANEL_MAX_LEVELS,
            " enabled levels (ascending); ", shownTotal - PANEL_MAX_LEVELS,
            " more are enabled but not drawn in this panel.");
   if(zonesWanted > PANEL_MAX_FILLS)
      Print("AutoFib panel mode: drawing the first ", PANEL_MAX_FILLS,
            " zones; ", zonesWanted - PANEL_MAX_FILLS, " more are not drawn in this panel.");

   // ---- style the used plots, disable the unused ----
   for(int f = 0; f < PANEL_MAX_FILLS; f++)
   {
      int p = PANEL_PLOT_FILL0 + f;
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      PlotIndexSetInteger(p, PLOT_SHOW_DATA, false);
      // NEVER change PLOT_DRAW_TYPE here. The plot->buffer mapping is
      // derived from how many buffers each plot TYPE consumes, in plot
      // order -- and DRAW_FILLING takes 2 while DRAW_NONE takes 1.
      // Runtime-switching an unused fill to DRAW_NONE therefore SHIFTS
      // the mapping of every plot after it: the leg/level plots start
      // reading the wrong (empty) buffers and the panel goes blank
      // (the v4.00 launch bug). Unused plots simply keep their EMPTY
      // buffers, which draw nothing anyway.
      PlotIndexSetInteger(p, PLOT_DRAW_TYPE, DRAW_FILLING); // reassert declared type
      if(f < g_numFills)
      {
         // fake-transparency blend against the chart background
         color blended = BlendWithBackground(g_color[g_fillLowLvl[f]], BackgroundTransparencyPct);
         PlotIndexSetInteger(p, PLOT_LINE_COLOR, 0, blended);
         PlotIndexSetInteger(p, PLOT_LINE_COLOR, 1, blended); // fib zones never invert; same color anyway
         PlotIndexSetString(p, PLOT_LABEL,
            "Zone " + DoubleToString(g_value[g_fillLowLvl[f]], 3) + "-" + DoubleToString(g_value[g_fillHighLvl[f]], 3));
      }
   }

   PlotIndexSetDouble(PANEL_PLOT_LEG, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(PANEL_PLOT_LEG, PLOT_SHOW_DATA, false);
   PlotIndexSetInteger(PANEL_PLOT_LEG, PLOT_DRAW_TYPE, DRAW_LINE); // reassert; see fills note
   PlotIndexSetInteger(PANEL_PLOT_LEG, PLOT_LINE_COLOR, clrSilver);
   PlotIndexSetInteger(PANEL_PLOT_LEG, PLOT_LINE_STYLE, STYLE_DOT); // dotted renders only at width 1
   PlotIndexSetInteger(PANEL_PLOT_LEG, PLOT_LINE_WIDTH, 1);
   PlotIndexSetString(PANEL_PLOT_LEG, PLOT_LABEL, "Fib leg");

   for(int sl = 0; sl < PANEL_MAX_LEVELS; sl++)
   {
      int p = PANEL_PLOT_LVL0 + sl;
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      PlotIndexSetInteger(p, PLOT_SHOW_DATA, false);
      PlotIndexSetInteger(p, PLOT_DRAW_TYPE, DRAW_LINE); // reassert; never DRAW_NONE (see fills note)
      if(sl < g_numSlots)
      {
         PlotIndexSetInteger(p, PLOT_LINE_COLOR, g_color[g_slotLevel[sl]]);
         PlotIndexSetInteger(p, PLOT_LINE_STYLE, STYLE_SOLID);
         PlotIndexSetInteger(p, PLOT_LINE_WIDTH, 1);
         PlotIndexSetString(p, PLOT_LABEL, "Fib " + DoubleToString(g_value[g_slotLevel[sl]], 3));
      }
   }

}

//+------------------------------------------------------------------+
void PanelWipeBuffers()
{
   ArrayInitialize(BufFillTop1, EMPTY_VALUE); ArrayInitialize(BufFillBot1, EMPTY_VALUE);
   ArrayInitialize(BufFillTop2, EMPTY_VALUE); ArrayInitialize(BufFillBot2, EMPTY_VALUE);
   ArrayInitialize(BufFillTop3, EMPTY_VALUE); ArrayInitialize(BufFillBot3, EMPTY_VALUE);
   ArrayInitialize(BufFillTop4, EMPTY_VALUE); ArrayInitialize(BufFillBot4, EMPTY_VALUE);
   ArrayInitialize(BufLeg, EMPTY_VALUE);
   ArrayInitialize(BufLevel1, EMPTY_VALUE); ArrayInitialize(BufLevel2, EMPTY_VALUE);
   ArrayInitialize(BufLevel3, EMPTY_VALUE); ArrayInitialize(BufLevel4, EMPTY_VALUE);
   ArrayInitialize(BufLevel5, EMPTY_VALUE); ArrayInitialize(BufLevel6, EMPTY_VALUE);
   ArrayInitialize(BufLevel7, EMPTY_VALUE); ArrayInitialize(BufLevel8, EMPTY_VALUE);
}

//+------------------------------------------------------------------+
// PanelInitNewCells: the terminal does not guarantee that NEWLY
// APPENDED buffer cells are empty, so every pass initializes cells
// added since the last one (normally just the fresh bar). Without
// this, a new bar could briefly show a garbage value on any plot.
//+------------------------------------------------------------------+
void PanelInitNewCells(const int rates_total)
{
   int from = (g_panelClearedTo < 0) ? 0 : g_panelClearedTo + 1;
   if(from >= rates_total)
   {
      g_panelClearedTo = rates_total - 1;
      return;
   }
   if(from == 0)
      PanelWipeBuffers();
   else
      for(int i = from; i < rates_total; i++)
      {
         BufFillTop1[i] = EMPTY_VALUE; BufFillBot1[i] = EMPTY_VALUE;
         BufFillTop2[i] = EMPTY_VALUE; BufFillBot2[i] = EMPTY_VALUE;
         BufFillTop3[i] = EMPTY_VALUE; BufFillBot3[i] = EMPTY_VALUE;
         BufFillTop4[i] = EMPTY_VALUE; BufFillBot4[i] = EMPTY_VALUE;
         BufLeg[i] = EMPTY_VALUE;
         BufLevel1[i] = EMPTY_VALUE; BufLevel2[i] = EMPTY_VALUE;
         BufLevel3[i] = EMPTY_VALUE; BufLevel4[i] = EMPTY_VALUE;
         BufLevel5[i] = EMPTY_VALUE; BufLevel6[i] = EMPTY_VALUE;
         BufLevel7[i] = EMPTY_VALUE; BufLevel8[i] = EMPTY_VALUE;
      }
   g_panelClearedTo = rates_total - 1;
}

//+------------------------------------------------------------------+
void SetLevelBuf(const int slot, const int i, const double v)
{
   switch(slot)
   {
      case 0: BufLevel1[i] = v; break;
      case 1: BufLevel2[i] = v; break;
      case 2: BufLevel3[i] = v; break;
      case 3: BufLevel4[i] = v; break;
      case 4: BufLevel5[i] = v; break;
      case 5: BufLevel6[i] = v; break;
      case 6: BufLevel7[i] = v; break;
      case 7: BufLevel8[i] = v; break;
   }
}

//+------------------------------------------------------------------+
void SetFillBuf(const int f, const int i, const double top, const double bot)
{
   switch(f)
   {
      case 0: BufFillTop1[i] = top; BufFillBot1[i] = bot; break;
      case 1: BufFillTop2[i] = top; BufFillBot2[i] = bot; break;
      case 2: BufFillTop3[i] = top; BufFillBot3[i] = bot; break;
      case 3: BufFillTop4[i] = top; BufFillBot4[i] = bot; break;
   }
}

//+------------------------------------------------------------------+
// PanelDraw: writes the fib into the buffers. Level lines
// and zones run from the older anchor to the CURRENT bar (buffers
// cannot extend into empty future space); the leg is interpolated
// along its slope between the two anchors, dotted, like the object.
//+------------------------------------------------------------------+
void PanelDraw(const int rates_total, const bool wipeFirst, const double &levelPrice[])
{
   if(wipeFirst)
      PanelWipeBuffers();

   if(g_olderBar < 0 || g_newerBar <= g_olderBar)
      return;

   for(int i = g_olderBar; i < rates_total; i++)
   {
      for(int sl = 0; sl < g_numSlots; sl++)
         SetLevelBuf(sl, i, levelPrice[g_slotLevel[sl]]);

      for(int f = 0; f < g_numFills; f++)
      {
         double a = levelPrice[g_fillLowLvl[f]];
         double b = levelPrice[g_fillHighLvl[f]];
         SetFillBuf(f, i, MathMax(a, b), MathMin(a, b));
      }
   }

   int span = g_newerBar - g_olderBar;
   for(int i = g_olderBar; i <= g_newerBar; i++)
      BufLeg[i] = g_olderPrice + (g_newerPrice - g_olderPrice) * (double)(i - g_olderBar) / (double)span;
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

   PanelInitNewCells(rates_total); // fresh buffer cells never show garbage

   // --- EA-PARITY ENGINE (v6): full rescan once per new bar ---
   // Mirrors AutoFibTrader.UpdateLeg(): every new bar the zigzag state is
   // wiped and rebuilt over the last LookbackBars bars, INCLUDING the
   // still-forming candle. Nothing is latched, so a live spike that kills a
   // freshly-confirmed pivot re-routes the leg at the next bar open --
   // exactly like the EA. Same window, same math, same cadence.
   bool fullPass = (prev_calculated == 0 || prev_calculated > rates_total);
   if(fullPass)
   {
      // first run, timeframe switch, or history reload: wipe everything so
      // stale anchors / ghost lines from old data can't survive
      PanelWipeBuffers();
      g_panelClearedTo = rates_total - 1;
      g_drawnOlderBar = -1;
      g_drawnNewerBar = -1;
      g_drawnBarTime  = 0;
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
         // full state-reset flicker on the very next tick. g_lastScanBarTime
         // is NOT stored, so the scan retries next tick.
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
      if(g_drawnOlderBar >= 0)
      {
         PanelWipeBuffers();
         g_panelClearedTo = rates_total - 1;
         g_drawnOlderBar = -1;
         g_drawnNewerBar = -1;
         g_drawnBarTime  = 0;
      }
      return(rates_total);
   }

   // --- draw/update fib levels using the current leg (older -> newer) ---
   // GATED: the drawn output only actually changes on a new zigzag leg or a
   // new bar (the buffers run to the current bar, so the right edge advances
   // once per bar). Nothing to do on an ordinary same-bar tick.
   bool legChanged = (g_olderBar != g_drawnOlderBar || g_newerBar != g_drawnNewerBar);
   bool newBar     = (time[rates_total-1] != g_drawnBarTime);

   if(g_havePrevZZ && (legChanged || newBar))
   {
      bool wipeFirst = legChanged; // leg moved: the old span may be wider

      g_drawnOlderBar = g_olderBar;
      g_drawnNewerBar = g_newerBar;
      g_drawnBarTime  = time[rates_total-1];
      double lpStart = g_olderPrice;
      double lpEnd   = g_newerPrice;
      double startPrice = Reverse ? lpStart : lpEnd;
      double endPrice   = Reverse ? lpEnd   : lpStart;
      double height = (startPrice > endPrice ? -1.0 : 1.0) * MathAbs(startPrice - endPrice);

      // level prices, computed once and shared by the buffer draw and the
      // alert block below
      double levelPrice[NUM_LEVELS];
      for(int idx = 0; idx < NUM_LEVELS; idx++)
         levelPrice[idx] = g_show[idx] ? startPrice + height * g_value[idx]
                                       : EMPTY_VALUE;

      // ---------- PANEL PATH: buffers ----------
      PanelDraw(rates_total, wipeFirst, levelPrice);

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

      // ONE repaint per draw pass (new bar / leg change), so the
      // buffer updates show instantly even with no follow-up tick.
      ChartRedraw(0);
   }

   return(rates_total);
}
//+------------------------------------------------------------------+