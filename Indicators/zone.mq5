//+------------------------------------------------------------------+
//|                                                    MTF_Range.mq5 |
//|                                  Copyright 2026, AI Collaborator |
//|                                             https://www.mql5.com |
//|                                                                  |
//|  Dual multi-timeframe candle-range drawer.                       |
//|                                                                  |
//|  Each higher timeframe candle is drawn as a rectangle spanning   |
//|  its high..low. Two independently locked timeframes, each with   |
//|  its own fill + border color.                                    |
//|                                                                  |
//|  Light by design: the full set of rectangles is only rebuilt     |
//|  when a NEW higher-tf candle closes, when the force-refresh      |
//|  interval elapses, or when objects go missing (template reload,  |
//|  "delete all objects", etc.). On ordinary ticks only the single  |
//|  still-forming candle is updated, and only if its high/low       |
//|  actually moved -- otherwise the tick does nothing.              |
//|                                                                  |
//|  Chart-TF visibility lock: each slot has a VisibleFrom..VisibleTo|
//|  chart-period range, stamped on its rectangles as an             |
//|  OBJPROP_TIMEFRAMES mask (capped strictly below the slot's own   |
//|  tf). The terminal shows/hides them natively on period switches; |
//|  the objects stay alive and keep updating in the background, so  |
//|  changing chart TF costs nothing instead of delete + rebuild.    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "5.10"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- Input Parameters
input group "--- Global Settings ---"
input int      InpMaxCandles             = 100; // Number of MTF candles to display
input int      BackgroundTransparencyPct = 85;  // Fill transparency (0=solid, 100=invisible)
input int      InpRefreshSeconds         = 30;  // Force refresh interval in seconds (0 = only on new bars)

input group "--- Timeframe-1st ---"
input bool     InpTF1_Enable             = true;         // Enable 1st Timeframe
input ENUM_TIMEFRAMES InpTF1             = PERIOD_H1;    // 1st Timeframe
input bool     InpTF1_ShowBackground     = true;         // 1st Show Background Fill?
input color    InpTF1_Color              = clrSilver;    // 1st Fill Color
input bool     InpTF1_ShowBorder         = true;         // 1st Show Border?
input color    InpTF1_BorderColor        = clrSilver;    // 1st Border Color
input ENUM_TIMEFRAMES InpTF1_VisibleFrom = PERIOD_CURRENT;   // 1st Visible from chart TF
input ENUM_TIMEFRAMES InpTF1_VisibleTo   = PERIOD_CURRENT;   // 1st Visible up to chart TF

input group "--- Timeframe-2nd ---"
input bool     InpTF2_Enable             = true;         // Enable 2nd Timeframe
input ENUM_TIMEFRAMES InpTF2             = PERIOD_H4;    // 2nd Timeframe
input bool     InpTF2_ShowBackground     = false;        // 2nd Show Background Fill?
input color    InpTF2_Color              = clrRed;       // 2nd Fill Color
input bool     InpTF2_ShowBorder         = true;         // 2nd Show Border?
input color    InpTF2_BorderColor        = clrRed;       // 2nd Border Color
input ENUM_TIMEFRAMES InpTF2_VisibleFrom = PERIOD_CURRENT;   // 2nd Visible from chart TF
input ENUM_TIMEFRAMES InpTF2_VisibleTo   = PERIOD_CURRENT;   // 2nd Visible up to chart TF

// Instance-unique object prefix, built in OnInit from the timeframe pair.
// A fixed prefix would make two attached copies share one namespace, so
// removing/reiniting one could delete the other's rectangles. A TF-pair
// prefix means each instance owns and cleans only its own objects.
string g_prefix;

//--- per-slot configuration (slot 0 = TF1, slot 1 = TF2)
ENUM_TIMEFRAMES g_tf[2];
bool            g_enabled[2];
bool            g_showBg[2];
bool            g_showBorder[2];
color           g_fillColor[2];
color           g_borderColor[2];
string          g_tfName[2];
long            g_visMask[2];   // OBJPROP_TIMEFRAMES bitmask: chart TFs to render on

//--- per-slot runtime state
datetime g_lastBarTime[2];      // open time of the newest known candle (new-bar detection)
datetime g_lastForceRefresh[2]; // last time a full rebuild ran for this slot
double   g_curHigh[2];          // live high of the forming candle (slot's index 0)
double   g_curLow[2];           // live low  of the forming candle
int      g_drawnCount[2];       // how many candles are currently drawn (for stale cleanup)

// Only print a given failure once while it persists, not every tick.
bool g_loggedNoHistory[2] = {false, false};

//------------------------------------------------------------------
// WARM-UP GRACE
//------------------------------------------------------------------
// Right after attach/reinit (or when a locked timeframe the chart isn't
// showing hasn't synced yet), the first history read can land before the
// data exists. That is a normal transient: it retries and succeeds. During
// a short grace window after init, "not ready" is retried silently; only a
// failure that persists past the window (missing history, broken symbol) is
// reported, and then just once.
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
}

//--- forward declarations
bool CheckObjectsMissing(int slot);
void RedrawTF(int slot);
void UpdateLiveCandle(int slot, double hi, double lo);

//+------------------------------------------------------------------+
int OnInit()
{
   g_tf[0]          = InpTF1;               g_tf[1]          = InpTF2;
   g_enabled[0]     = InpTF1_Enable;        g_enabled[1]     = InpTF2_Enable;
   g_showBg[0]      = InpTF1_ShowBackground;g_showBg[1]      = InpTF2_ShowBackground;
   g_showBorder[0]  = InpTF1_ShowBorder;    g_showBorder[1]  = InpTF2_ShowBorder;
   g_fillColor[0]   = InpTF1_Color;         g_fillColor[1]   = InpTF2_Color;
   g_borderColor[0] = InpTF1_BorderColor;   g_borderColor[1] = InpTF2_BorderColor;

   for(int s = 0; s < 2; s++)
   {
      g_tfName[s]           = TimeframeToString(g_tf[s]);
      g_lastBarTime[s]      = 0;
      g_lastForceRefresh[s] = 0;
      g_curHigh[s]          = 0.0;
      g_curLow[s]           = 0.0;
      g_drawnCount[s]       = 0;
      g_loggedNoHistory[s]  = false;
   }

   g_prefix = "MTF_RNG_" + g_tfName[0] + "_" + (g_enabled[1] ? g_tfName[1] : "X") + "_";

   // Visibility masks: on which CHART periods each slot's rectangles render.
   // Capped strictly below the slot's own tf, so "bigger/equal timeframe =
   // gone" behaves exactly as before -- just hidden by the terminal now
   // instead of deleted and rebuilt on every period switch.
   g_visMask[0] = BuildVisMask(InpTF1_VisibleFrom, InpTF1_VisibleTo, g_tf[0]);
   g_visMask[1] = BuildVisMask(InpTF2_VisibleFrom, InpTF2_VisibleTo, g_tf[1]);
   for(int s = 0; s < 2; s++)
      if(g_enabled[s] && g_visMask[s] == 0)
         Print("Dual MTF Range: ", g_tfName[s], " visible-range inputs leave no",
               " chart period below ", g_tfName[s],
               " -- its rectangles will stay hidden everywhere.");

   // Start the warm-up grace clock (see StillWarmingUp above).
   g_initTick = GetTickCount();

   IndicatorSetString(INDICATOR_SHORTNAME, "Dual MTF Range");

   // 1-second self-heal timer (suite standard, matches Sub-/Float-Chart).
   // Ticks alone can't recover wiped rectangles or force-refresh on a dead
   // or closed market -- the timer runs the same ProcessSlot path once a
   // second so missing-object recovery and new-bar detection keep working
   // with zero ticks. The per-tick path (OnCalculate) is unchanged.
   EventSetTimer(1);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   // Keep the rectangles when only the chart's visible timeframe changes
   // (REASON_CHARTCHANGE) -- they are anchored by time/price and stay valid
   // on any chart period. For every other reason (inputs changed, removed,
   // template loaded, recompiled) clear the objects so stale rectangles
   // from a previous setting don't get left behind.
   if(reason != REASON_CHARTCHANGE)
      ObjectsDeleteAll(0, g_prefix);

   ChartRedraw(0);
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
   ProcessSlot(0);
   ProcessSlot(1);
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Timer: self-heal + new-bar/refresh without needing a tick.       |
//| Same work as OnCalculate -- ProcessSlot is cheap when nothing    |
//| changed (one CopyRates of the forming candle), and it's what     |
//| recovers wiped rectangles on a frozen/closed market.             |
//+------------------------------------------------------------------+
void OnTimer()
{
   ProcessSlot(0);
   ProcessSlot(1);
}

//+------------------------------------------------------------------+
//| Decide what (if anything) a slot needs this tick, cheaply.       |
//+------------------------------------------------------------------+
void ProcessSlot(int slot)
{
   ENUM_TIMEFRAMES tf = g_tf[slot];

   // A slot is active if it's enabled with at least one visible element.
   // The chart period is deliberately NOT checked here: rectangles exist on
   // every chart TF and the OBJPROP_TIMEFRAMES mask decides where they
   // actually render, so a period switch costs nothing instead of a full
   // delete + rebuild. The mask is capped below the slot's tf in OnInit.
   bool active = g_enabled[slot] &&
                 (g_showBg[slot] || g_showBorder[slot]);

   if(!active)
   {
      // Safety net: if this slot somehow drew before going inactive,
      // remove its now-meaningless rectangles once.
      if(g_lastBarTime[slot] != 0)
      {
         ObjectsDeleteAll(0, g_prefix + IntegerToString(slot) + "_");
         g_drawnCount[slot]  = 0;
         g_lastBarTime[slot] = 0;
      }
      return;
   }

   // One lightweight read of the forming candle. CopyRates (unlike iTime/
   // iHigh) actively requests a sync for a locked tf the chart isn't on, so
   // new-bar detection never stalls, and it hands us the live high/low too.
   MqlRates r[];
   ArraySetAsSeries(r, true);
   ResetLastError();
   int got = CopyRates(_Symbol, tf, 0, 1, r);
   if(got <= 0)
   {
      if(!StillWarmingUp() && !g_loggedNoHistory[slot])
      {
         Print("Dual MTF Range: history for ", g_tfName[slot],
               " isn't available yet. Rectangles on hold, will keep retrying..");
         g_loggedNoHistory[slot] = true;
      }
      return; // retried next tick (or new bar / refresh / missing objects)
   }

   //--- decide whether a full rebuild is needed ---
   bool doRedraw = false;

   // new higher-tf bar (or first run for this slot)
   if(r[0].time != g_lastBarTime[slot])
      doRedraw = true;

   // periodic force refresh (rebuilds wiped objects, keeps things honest)
   if(!doRedraw && InpRefreshSeconds > 0 &&
      (TimeCurrent() - g_lastForceRefresh[slot]) >= InpRefreshSeconds)
      doRedraw = true;

   // objects went missing since last time (template reload, delete-all, ..)
   if(!doRedraw && CheckObjectsMissing(slot))
      doRedraw = true;

   if(doRedraw)
   {
      RedrawTF(slot);
      return;
   }

   // Same bar, nothing structural changed: the only thing that can move is
   // the still-forming candle's high/low. Update that ONE rectangle, and
   // only when it actually grew -- otherwise this tick costs nothing.
   if(r[0].high != g_curHigh[slot] || r[0].low != g_curLow[slot])
      UpdateLiveCandle(slot, r[0].high, r[0].low);
}

//+------------------------------------------------------------------+
//| Full rebuild of one slot's rectangles (runs rarely, not per tick).|
//+------------------------------------------------------------------+
void RedrawTF(int slot)
{
   ENUM_TIMEFRAMES tf = g_tf[slot];

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   ResetLastError();
   int copied = CopyRates(_Symbol, tf, 0, InpMaxCandles, rates);
   if(copied <= 0)
   {
      if(!StillWarmingUp() && !g_loggedNoHistory[slot])
      {
         Print("Dual MTF Range: history for ", g_tfName[slot],
               " isn't ready yet (have ", copied, "). Will keep retrying..");
         g_loggedNoHistory[slot] = true;
      }
      return; // leave existing rectangles untouched, retry later
   }
   g_loggedNoHistory[slot] = false;

   // Fill color is blended against the chart background here (not per tick)
   // so a theme change is picked up on the next rebuild.
   color fill = g_showBg[slot]
                ? BlendWithBackground(g_fillColor[slot], BackgroundTransparencyPct)
                : clrNONE;

   for(int i = 0; i < copied; i++)
   {
      datetime start = rates[i].time;
      datetime end   = start + PeriodSeconds(tf) - 1;
      double   hi    = rates[i].high;
      double   lo    = rates[i].low;

      // Background fill and border are separate objects: an MT5 rectangle
      // can't carry an independent fill color and outline color at once, so
      // the fill block and the crisp outline are drawn as their own objects.
      if(g_showBg[slot])
         DrawRect(BgName(slot, i),  start, hi, end, lo, fill,                 true,  0, g_visMask[slot]);
      if(g_showBorder[slot])
         DrawRect(BrdName(slot, i), start, hi, end, lo, g_borderColor[slot],  false, 1, g_visMask[slot]);
   }

   // Remove any candles that scrolled out of the window since last rebuild.
   for(int i = copied; i < g_drawnCount[slot]; i++)
   {
      ObjectDelete(0, BgName(slot, i));
      ObjectDelete(0, BrdName(slot, i));
   }
   g_drawnCount[slot] = copied;

   // Record state only after a confirmed-good copy, so a failed rebuild
   // retries instead of being marked done. Stamp the refresh clock on every
   // successful rebuild (new-bar path included) so a redundant force-refresh
   // can't fire right after.
   g_lastBarTime[slot]      = rates[0].time;
   g_curHigh[slot]          = rates[0].high;
   g_curLow[slot]           = rates[0].low;
   g_lastForceRefresh[slot] = TimeCurrent();

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Cheap per-tick update of the single forming candle (index 0).    |
//+------------------------------------------------------------------+
void UpdateLiveCandle(int slot, double hi, double lo)
{
   datetime start = g_lastBarTime[slot];
   datetime end   = start + PeriodSeconds(g_tf[slot]) - 1;

   if(g_showBg[slot])
   {
      string n = BgName(slot, 0);
      if(ObjectFind(0, n) >= 0)
      {
         ObjectMove(0, n, 0, start, hi);
         ObjectMove(0, n, 1, end,   lo);
      }
   }
   if(g_showBorder[slot])
   {
      string n = BrdName(slot, 0);
      if(ObjectFind(0, n) >= 0)
      {
         ObjectMove(0, n, 0, start, hi);
         ObjectMove(0, n, 1, end,   lo);
      }
   }

   g_curHigh[slot] = hi;
   g_curLow[slot]  = lo;
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| True if the newest rectangle for this slot has gone missing.     |
//+------------------------------------------------------------------+
bool CheckObjectsMissing(int slot)
{
   if(g_lastBarTime[slot] == 0)                     return false; // never drawn yet
   if(!g_showBg[slot] && !g_showBorder[slot])       return false; // nothing to draw

   // If the newest candle's expected object(s) are present, we're fine.
   if(g_showBg[slot]     && ObjectFind(0, BgName(slot, 0))  >= 0) return false;
   if(g_showBorder[slot] && ObjectFind(0, BrdName(slot, 0)) >= 0) return false;

   return true; // something wiped them -> trigger a rebuild
}

//+------------------------------------------------------------------+
//| Create-once / move-thereafter rectangle. No delete+recreate.     |
//+------------------------------------------------------------------+
void DrawRect(string name, datetime t1, double p1, datetime t2, double p2,
              color clr, bool fill, int width, long visMask)
{
   if(ObjectFind(0, name) < 0)
   {
      ResetLastError();
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2))
         return;
   }
   else
   {
      ObjectMove(0, name, 0, t1, p1);
      ObjectMove(0, name, 1, t2, p2);
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      width);
   ObjectSetInteger(0, name, OBJPROP_FILL,       fill);
   ObjectSetInteger(0, name, OBJPROP_BACK,       true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, visMask);
}

//+------------------------------------------------------------------+
//| Object name builders (slot + role + candle index).               |
//+------------------------------------------------------------------+
string BgName(int slot, int idx)
{
   return g_prefix + IntegerToString(slot) + "_BG_" + IntegerToString(idx);
}
string BrdName(int slot, int idx)
{
   return g_prefix + IntegerToString(slot) + "_BRD_" + IntegerToString(idx);
}

//+------------------------------------------------------------------+
//| Chart-period visibility mask (OBJPROP_TIMEFRAMES).               |
//| One bit per standard chart period, ascending: bit 0 = M1 up to   |
//| bit 20 = MN1 -- the exact bit order of the OBJ_PERIOD_* flags.   |
//+------------------------------------------------------------------+
const ENUM_TIMEFRAMES VIS_ORDER[21] =
{
   PERIOD_M1,  PERIOD_M2,  PERIOD_M3,  PERIOD_M4,  PERIOD_M5,
   PERIOD_M6,  PERIOD_M10, PERIOD_M12, PERIOD_M15, PERIOD_M20,
   PERIOD_M30, PERIOD_H1,  PERIOD_H2,  PERIOD_H3,  PERIOD_H4,
   PERIOD_H6,  PERIOD_H8,  PERIOD_H12, PERIOD_D1,  PERIOD_W1,
   PERIOD_MN1
};

int PeriodIndex(ENUM_TIMEFRAMES tf)
{
   for(int i = 0; i < 21; i++)
      if(VIS_ORDER[i] == tf)
         return i;
   return -1;
}

long BuildVisMask(ENUM_TIMEFRAMES from, ENUM_TIMEFRAMES to, ENUM_TIMEFRAMES lockedTF)
{
   // PERIOD_CURRENT on either side means "no limit on that side".
   int a = (from == PERIOD_CURRENT) ? 0  : PeriodIndex(from);
   int b = (to   == PERIOD_CURRENT) ? 20 : PeriodIndex(to);
   if(a < 0) a = 0;
   if(b < 0) b = 20;
   if(a > b) { int t = a; a = b; b = t; }   // swapped inputs: be forgiving

   // Hard cap: never render on the locked tf itself or anything above it,
   // preserving the old "chart at/above locked tf = nothing shown" rule.
   int cap = PeriodIndex(lockedTF);
   if(cap >= 0 && b >= cap)
      b = cap - 1;

   long mask = 0;
   for(int i = a; i <= b; i++)
      mask |= ((long)1 << i);
   return mask; // 0 = OBJ_NO_PERIODS: hidden on every chart period
}

//+------------------------------------------------------------------+
string TimeframeToString(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

//+------------------------------------------------------------------+
//| Blend a color toward the chart background for a transparent fill.|
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