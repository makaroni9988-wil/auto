//+------------------------------------------------------------------+
//|                                          CandleTimerPanel.mq5     |
//|   Lightweight multi-timeframe candle countdown panel              |
//|   - Timer-driven (1s), no OnCalculate load                        |
//|   - Only draws the timeframes you enable                          |
//|   - Format HH:MM:SS for every row                                 |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- master switch for the corner countdown panel. false = the rows are
//    never created and their per-second update loop is skipped entirely
//    (zero work, not just hidden). The price tag below is independent.
input bool ShowPanel = false;

//--- which timeframes to show
input bool ShowM1  = false;
input bool ShowM5  = true;
input bool ShowM15 = false;
input bool ShowM30 = true;
input bool ShowH1  = false;
input bool ShowH4  = true;
input bool ShowD1  = false;

//--- panel position
input ENUM_BASE_CORNER PanelCorner   = CORNER_RIGHT_LOWER;
input int              PanelPaddingX = 110;   // distance from corner, X
input int              PanelPaddingY = 20;    // distance from corner, Y
input int              LineSpacing   = 15;    // px between rows (tighter = smaller)

//--- font
input string FontName = "Lucida Console";
input int    FontSize = 8;

//--- colors
input color NormalColor    = clrWhite;
input color WarningColor   = clrRed;
input int   WarningSeconds = 10;   // row turns WarningColor when remaining <= this

//--- format switch: timeframes >= this many seconds use HH:MM:SS, smaller ones use MM:SS
input int   HourFormatFromSeconds = 14400;  // 14400 = H4, so only H4 and D1 get hour format, use 3600 for 1 hour (optional)

//--- price tag: countdown of the CHART's timeframe, glued to the bid price.
//    Text is only the time. Format follows HourFormatFromSeconds above
//    (same rule as the panel rows -- one global setting). Color reflects
//    floating PnL of this symbol (same formula as the PnL-Stat panel:
//    profit + swap, this chart's symbol only).
input bool   ShowPriceTag    = true;
input color  TagProfitColor  = clrLime;   // tag color when floating PnL > 0
input color  TagLossColor    = clrYellow; // tag color when floating PnL < 0
input color  TagFlatColor    = clrWhite;  // tag color when flat / no position on this symbol
input int    TagFontSize     = 8;
input int    TagBarsOffset   = 5;         // bars to the right of the current candle (needs chart shift to be visible)
input int    TagOffsetPixels = 0;         // extra gap ABOVE the bid line, in pixels (zoom-independent; negative = below)

//--- internal
// Instance-unique object prefix, built in OnInit from the panel position
// (suite standard: identity by configuration) -- two copies anchored to
// different corners/offsets own separate objects.
string g_prefix;
string g_tagName;   // covered by the prefix cleanup in OnDeinit

struct TFRow
  {
   ENUM_TIMEFRAMES tf;
   string          label;
  };

TFRow rows[];

//+------------------------------------------------------------------+
// A locked TF the chart itself isn't on (e.g. M30 while charting M1)
// may never have had anything trigger MT5 to sync its history. Plain
// iTime() only reports what's already synced -- it doesn't request
// the sync itself -- so it can silently return 0 forever for such a
// TF. Copy* functions DO trigger that sync request. So: try iTime()
// first (cheap, normal case), and only if it comes back 0 do we kick
// off a CopyRates() request to get things moving.
//+------------------------------------------------------------------+
datetime GetBarOpenTime(string symbol, ENUM_TIMEFRAMES tf)
  {
   datetime t = iTime(symbol, tf, 0);
   if(t == 0)
     {
      MqlRates r[];
      ArraySetAsSeries(r, true);
      CopyRates(symbol, tf, 0, 1, r); // fire-and-forget: kicks off history sync
     }
   return t;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   // Identity by configuration (see g_prefix above).
   g_prefix  = StringFormat("CTP_%d_%d_%d_", (int)PanelCorner, PanelPaddingX, PanelPaddingY);
   g_tagName = g_prefix + "TAG";

   ArrayFree(rows);

   if(ShowPanel)
     {
      if(ShowM1)  AddRow(PERIOD_M1,  "M1");
      if(ShowM5)  AddRow(PERIOD_M5,  "M5");
      if(ShowM15) AddRow(PERIOD_M15, "M15");
      if(ShowM30) AddRow(PERIOD_M30, "M30");
      if(ShowH1)  AddRow(PERIOD_H1,  "H1");
      if(ShowH4)  AddRow(PERIOD_H4,  "H4");
      if(ShowD1)  AddRow(PERIOD_D1,  "D1");

      CreateLabels();
     }

   datetime nowSrv = TimeTradeServer();
   if(ShowPanel)
      UpdateLabels(nowSrv); // paint immediately, don't wait for first timer tick
   UpdateTag(true, nowSrv);
   ChartRedraw(0);

   // 200ms poll, but drawing happens only when the server second
   // actually FLIPS (see OnTimer). A plain 1s timer starts counting
   // from attach time, so it fires at some random offset inside each
   // second (e.g. xx.73) and that offset drifts -- making the
   // countdown look sometimes late, sometimes skipping a beat. Edge-
   // triggering on the second boundary keeps every visible update
   // within 0.2s of the true flip. Cost: 5 clock reads/second, one
   // draw/second -- same load as before.
   EventSetMillisecondTimer(200);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void AddRow(ENUM_TIMEFRAMES tf, string label)
  {
   int n = ArraySize(rows);
   ArrayResize(rows, n + 1);
   rows[n].tf    = tf;
   rows[n].label = label;
  }

//+------------------------------------------------------------------+
void CreateLabels()
  {
   int total = ArraySize(rows);

   // rows[] is ordered smallest TF -> biggest TF (M1...D1).
   // On upper corners, Y grows downward, so that order already reads top=smallest.
   // On lower corners, Y grows upward, so we must reverse the stacking order
   // to still get smallest on top / biggest on bottom.
   bool isUpperCorner = (PanelCorner == CORNER_LEFT_UPPER || PanelCorner == CORNER_RIGHT_UPPER);

   for(int i = 0; i < total; i++)
     {
      int stackPos = isUpperCorner ? i : (total - 1 - i);

      string name = g_prefix + IntegerToString(i);
      if(ObjectFind(0, name) < 0)
        {
         ResetLastError();
         if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
           {
            // Skip the property calls below: each one would otherwise log
            // its own "object not found" error into the Experts journal.
            Print("CandleTimerPanel ERROR: failed to create label '", name,
                  "', error code ", GetLastError(), ".");
            continue;
           }
        }

      ObjectSetInteger(0, name, OBJPROP_CORNER, PanelCorner);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PanelPaddingX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, PanelPaddingY + stackPos * LineSpacing);
      ObjectSetString(0,  name, OBJPROP_FONT, FontName);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, FontSize);
      ObjectSetInteger(0, name, OBJPROP_COLOR, NormalColor);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
  }

//+------------------------------------------------------------------+
void UpdateLabels(const datetime nowSrv)
  {
   // Check every 10 seconds if labels have been accidentally deleted
   // and recreate them if needed. This is a lightweight canary check
   // that only looks for the first label object.
   static int g_checkCounter = 0;
   
   g_checkCounter++;
   if(g_checkCounter >= 10) // Check every 10 timer ticks (10 seconds)
     {
      g_checkCounter = 0;
      
      int total = ArraySize(rows);
      if(total > 0)
        {
         string firstName = g_prefix + "0";
         if(ObjectFind(0, firstName) < 0)
           {
            // Labels are missing - recreate them all
            CreateLabels();
           }
        }
     }

   for(int i = 0; i < ArraySize(rows); i++)
     {
      ENUM_TIMEFRAMES tf = rows[i].tf;
      datetime openTime  = GetBarOpenTime(_Symbol, tf);
      string name = g_prefix + IntegerToString(i);

      if(openTime == 0)
        {
         // Not synced yet (sync request was just fired in
         // GetBarOpenTime). Show a neutral placeholder instead of a
         // misleading 00:00 that looks like "about to close" -- the
         // "--:--" on screen IS the diagnostic; nothing is written to
         // the Experts journal for this (it's a normal, self-healing
         // state, and it would re-log on every chart change otherwise).
         ObjectSetString(0, name, OBJPROP_TEXT, StringFormat("%-4s %8s", rows[i].label, "--:--"));
         ObjectSetInteger(0, name, OBJPROP_COLOR, NormalColor);
         continue;
        }

      int periodSec       = PeriodSeconds(tf);
      long remaining       = (long)(openTime + periodSec - nowSrv);
      if(remaining < 0) remaining = 0;

      string txt;
      if(periodSec >= HourFormatFromSeconds)
        {
         // H4 / D1 style: HH:MM:SS
         int hh = (int)(remaining / 3600);
         int mm = (int)((remaining % 3600) / 60);
         int ss = (int)(remaining % 60);
         txt = StringFormat("%-4s %8s", rows[i].label, StringFormat("%02d:%02d:%02d", hh, mm, ss));
        }
      else
        {
         // M1...H1 style: MM:SS (minutes can exceed 59, that's fine)
         int mm = (int)(remaining / 60);
         int ss = (int)(remaining % 60);
         txt = StringFormat("%-4s %8s", rows[i].label, StringFormat("%02d:%02d", mm, ss));
        }

      ObjectSetString(0, name, OBJPROP_TEXT, txt);

      color c = (remaining <= WarningSeconds) ? WarningColor : NormalColor;
      ObjectSetInteger(0, name, OBJPROP_COLOR, c);
     }
   // NOTE: no ChartRedraw here. The caller repaints once AFTER the tag
   // is updated too. Redrawing between panel and tag painted the screen
   // with a fresh panel but the PREVIOUS second still on the tag -- on
   // a quiet market (no tick to repaint) the tag then sat visibly one
   // second behind until the next pass.
  }

//+------------------------------------------------------------------+
// Floating PnL for THIS CHART'S SYMBOL only -- deliberately the exact
// same formula as the PnL-Stat panel (profit + swap per open position,
// other symbols skipped), so tag color and panel number always agree.
// Returns false when there is no open position on this symbol, so the
// caller can tell "flat" apart from "PnL happens to be 0.00".
//+------------------------------------------------------------------+
bool TagFloatingPnL(double &pnl)
  {
   pnl = 0.0;
   bool hasPos = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      pnl += PositionGetDouble(POSITION_PROFIT);
      pnl += PositionGetDouble(POSITION_SWAP);
      hasPos = true;
     }

   return hasPos;
  }

//+------------------------------------------------------------------+
// Price tag update. Two speeds, to stay cheap:
//   fullUpdate = true  (1x per second, from OnTimer): text, color, position
//   fullUpdate = false (every tick, from OnCalculate): position only,
//                       so the tag glides with the bid instead of
//                       stepping once a second on fast markets.
// Create-if-missing runs on the full update, which doubles as the
// canary recovery if the object gets deleted from the chart.
//+------------------------------------------------------------------+
void UpdateTag(bool fullUpdate, datetime nowSrv = 0)
  {
   if(!ShowPriceTag)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;                       // no quote yet; try again next pass

   bool created = false;
   if(ObjectFind(0, g_tagName) < 0)
     {
      if(!fullUpdate)
         return;                    // creation only on the 1s pass

      ResetLastError();
      if(!ObjectCreate(0, g_tagName, OBJ_TEXT, 0, tick.time, tick.bid))
        {
         Print("CandleTimerPanel ERROR: failed to create price tag, error code ", GetLastError(), ".");
         return;
        }
      ObjectSetString(0,  g_tagName, OBJPROP_FONT, FontName);
      ObjectSetInteger(0, g_tagName, OBJPROP_FONTSIZE, TagFontSize);
      // LEFT_LOWER: the anchor is the text's bottom-left corner, so the
      // whole tag renders ABOVE the anchored price instead of being
      // vertically centered on it (which put the bid line through it).
      ObjectSetInteger(0, g_tagName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, g_tagName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_tagName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, g_tagName, OBJPROP_BACK, false);
      created = true;
     }

   // --- position: glued to current bid, TagBarsOffset bars right of bar 0
   int      periodSec = PeriodSeconds(PERIOD_CURRENT);
   datetime bar0      = iTime(_Symbol, PERIOD_CURRENT, 0);   // chart TF is always synced
   datetime anchorT   = (bar0 > 0) ? bar0 + (datetime)((TagBarsOffset > 0 ? TagBarsOffset : 0) * periodSec)
                                   : tick.time;

   // Extra air gap above the line, requested in PIXELS and converted to
   // price with the live chart scale -- so the gap looks the same at any
   // zoom level and on any symbol (a fixed point-offset would be huge on
   // one symbol and invisible on another).
   double tagPrice = tick.bid;
   if(TagOffsetPixels != 0)
     {
      double pmax = ChartGetDouble(0, CHART_PRICE_MAX, 0);
      double pmin = ChartGetDouble(0, CHART_PRICE_MIN, 0);
      long   hpx  = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
      if(hpx > 0 && pmax > pmin)
         tagPrice += TagOffsetPixels * (pmax - pmin) / (double)hpx;
     }

   ObjectSetInteger(0, g_tagName, OBJPROP_TIME, 0, anchorT);
   ObjectSetDouble(0,  g_tagName, OBJPROP_PRICE, 0, tagPrice);

   if(!fullUpdate && !created)
      return;                       // tick pass: position refresh only

   // --- text: countdown of the CHART's timeframe. Format follows the
   //     same HourFormatFromSeconds input as the panel rows, so ONE
   //     setting controls the format globally (tag + all rows agree).
   string txt = "--:--";
   if(bar0 > 0)
     {
      if(nowSrv == 0)
         nowSrv = TimeTradeServer(); // safety net; full passes always pass it in
      long remaining = (long)(bar0 + periodSec - nowSrv);
      if(remaining < 0) remaining = 0;

      if(periodSec >= HourFormatFromSeconds)
         txt = StringFormat("%02d:%02d:%02d",
                            (int)(remaining / 3600),
                            (int)((remaining % 3600) / 60),
                            (int)(remaining % 60));
      else
         txt = StringFormat("%02d:%02d",
                            (int)(remaining / 60),
                            (int)(remaining % 60));
     }
   ObjectSetString(0, g_tagName, OBJPROP_TEXT, txt);

   // --- color: floating PnL state of this symbol
   double pnl = 0.0;
   color  c   = TagFlatColor;
   if(TagFloatingPnL(pnl))
     {
      if(pnl > 0.0)      c = TagProfitColor;
      else if(pnl < 0.0) c = TagLossColor;
      // pnl exactly 0.00 with an open position keeps TagFlatColor
     }
   ObjectSetInteger(0, g_tagName, OBJPROP_COLOR, c);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   // One clock read per pass, shared by the panel and the tag. Two
   // separate TimeTradeServer() calls can straddle a second flip and
   // render DIFFERENT seconds on panel vs tag (e.g. M5 03:38 next to
   // an M15 tag of 13:39 -- off by one). One read = always consistent.
   static datetime lastShownSec = 0;
   datetime nowSrv = TimeTradeServer();
   if(nowSrv == lastShownSec)
      return;                    // same second: nothing visible changes
   lastShownSec = nowSrv;

   if(ShowPanel)
      UpdateLabels(nowSrv);
   UpdateTag(true, nowSrv);      // full pass: text + color + position
   ChartRedraw(0);               // ONE repaint, after both are current
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
   UpdateTag(false);   // ticks: glide the tag with the bid (position only)
   return(rates_total);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(reason != REASON_CHARTCHANGE)
      ObjectsDeleteAll(0, g_prefix);
   else
      ObjectDelete(0, g_tagName);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+