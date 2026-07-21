#property copyright "Copyright 2026"
#property version   "1.10"
#property indicator_chart_window
#property indicator_plots 0

input ulong InpMagicNumber  = 12345;      // Magic number to display
input color InpBuyColor     = clrGreen;   // BUY entry line color
input color InpSellColor    = clrGreen;   // SELL entry line color
input color InpSLColor      = clrRed;     // Stop Loss line color
input color InpTPColor      = clrRed;     // Take Profit line color
input color InpPendingColor = clrGreen;   // Pending order price color
input int   InpLineWidth    = 1;          // Line width
input int   InpRefreshMs    = 1000;       // Timer refresh interval (ms)

input bool   InpShowLabels     = true;              // Show left-edge price labels
input color  InpLabelColor     = clrWhite;          // Label text color (all labels)
input string InpLabelFont      = "Lucida Console";  // Label font
input int    InpLabelFontSize  = 7;                 // Label font size
input int    InpLabelBarBuffer = 1;                 // Label buffer from left edge, in bars

string g_prefix;
string g_activeNames[];
int    g_activeCount;

int OnInit()
{
   g_prefix = "MNTL_" + (string)ChartID() + "_";
   EventSetMillisecondTimer(InpRefreshMs);
   RefreshLines();
   ChartRedraw(0);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   // Keep objects alive across a timeframe switch so the next OnInit
   // just redraws over them instead of a delete+recreate flicker.
   if(reason != REASON_CHARTCHANGE)
      DeleteAllLines();
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
   RefreshLines();
   return(rates_total);
}

void OnTimer()
{
   RefreshLines();
   ChartRedraw(0);
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   // Native trade-level labels stay pinned to the left edge of whatever's
   // in view; without this the label would only catch up to a scroll/zoom
   // on the next timer tick instead of immediately.
   if(id == CHARTEVENT_CHART_CHANGE)
      RefreshLines();
}

void DeleteAllLines()
{
   for(int i = ObjectsTotal(0,0,-1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0,i,0,-1);
      if(StringFind(name,g_prefix) == 0)
         ObjectDelete(0,name);
   }
}

bool IsNameActive(string name)
{
   for(int i = 0; i < g_activeCount; i++)
      if(g_activeNames[i] == name)
         return true;
   return false;
}

void MarkActive(string name)
{
   ArrayResize(g_activeNames,g_activeCount + 1);
   g_activeNames[g_activeCount] = name;
   g_activeCount++;
}

datetime GetLeftVisibleTime()
{
   long firstBar = ChartGetInteger(0,CHART_FIRST_VISIBLE_BAR,0);

   // Leftmost visible bar has the HIGHEST index (furthest back in time,
   // since index 0 = the most recent/rightmost bar) - so subtracting the
   // buffer moves the anchor toward more recent bars, i.e. to the RIGHT
   // of the raw left edge.
   int idx = (int)firstBar - InpLabelBarBuffer;
   if(idx < 0)
      idx = 0;

   datetime t = iTime(_Symbol,PERIOD_CURRENT,idx);
   return (t > 0) ? t : TimeCurrent();
}

string OrderTypeText(long type)
{
   switch((int)type)
   {
      case ORDER_TYPE_BUY_LIMIT:       return "BUY LIMIT";
      case ORDER_TYPE_SELL_LIMIT:      return "SELL LIMIT";
      case ORDER_TYPE_BUY_STOP:        return "BUY STOP";
      case ORDER_TYPE_SELL_STOP:       return "SELL STOP";
      case ORDER_TYPE_BUY_STOP_LIMIT:  return "BUY STOP LIMIT";
      case ORDER_TYPE_SELL_STOP_LIMIT: return "SELL STOP LIMIT";
   }
   return "PENDING";
}

void DrawLevel(string name,double price,color clr,ENUM_LINE_STYLE style,string labelText)
{
   if(price <= 0)
      return;

   price = NormalizeDouble(price,_Digits);

   // --- the horizontal line ---
   if(ObjectFind(0,name) < 0)
      ObjectCreate(0,name,OBJ_HLINE,0,0,price);

   // Only touch what actually changed - recreating unchanged objects
   // every refresh is what caused the visible line "blink".
   if(ObjectGetDouble(0,name,OBJPROP_PRICE) != price)
      ObjectSetDouble(0,name,OBJPROP_PRICE,price);

   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,InpLineWidth);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);

   MarkActive(name);

   // --- paired left-edge label, mimicking the native trade-level text ---
   if(!InpShowLabels)
      return;

   string labelName = name + "_LBL";
   datetime leftTime = GetLeftVisibleTime();

   if(ObjectFind(0,labelName) < 0)
      ObjectCreate(0,labelName,OBJ_TEXT,0,leftTime,price);

   ObjectSetInteger(0,labelName,OBJPROP_TIME,0,leftTime);
   ObjectSetDouble (0,labelName,OBJPROP_PRICE,0,price);
   ObjectSetString (0,labelName,OBJPROP_TEXT,labelText);
   ObjectSetString (0,labelName,OBJPROP_FONT,InpLabelFont);
   ObjectSetInteger(0,labelName,OBJPROP_FONTSIZE,InpLabelFontSize);
   ObjectSetInteger(0,labelName,OBJPROP_COLOR,InpLabelColor);
   // LEFT_LOWER: anchor is the text's bottom-left corner, so the label
   // renders ABOVE the line instead of vertically centered through it.
   ObjectSetInteger(0,labelName,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0,labelName,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,labelName,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,labelName,OBJPROP_BACK,false);

   MarkActive(labelName);
}

void RemoveStaleLines()
{
   for(int i = ObjectsTotal(0,0,-1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0,i,0,-1);

      if(StringFind(name,g_prefix) != 0)
         continue;

      if(!IsNameActive(name))
         ObjectDelete(0,name);
   }
}

void RefreshLines()
{
   ArrayResize(g_activeNames,0);
   g_activeCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long  type       = PositionGetInteger(POSITION_TYPE);
      color entryColor = (type == POSITION_TYPE_BUY) ? InpBuyColor : InpSellColor;
      string dirText   = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double volume    = PositionGetDouble(POSITION_VOLUME);

      string base = g_prefix + "POS_" + (string)ticket;

      string entryLabel = StringFormat("%s %s at %s",dirText,
                                        DoubleToString(volume,2),
                                        DoubleToString(openPrice,_Digits));

      DrawLevel(base + "_OPEN",openPrice,entryColor,STYLE_DOT,   entryLabel);
      DrawLevel(base + "_SL",  sl,       InpSLColor, STYLE_DASHDOT,"SL");
      DrawLevel(base + "_TP",  tp,       InpTPColor, STYLE_DASHDOT,"TP");
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      long   type   = OrderGetInteger(ORDER_TYPE);
      double price  = OrderGetDouble(ORDER_PRICE_OPEN);
      double sl     = OrderGetDouble(ORDER_SL);
      double tp     = OrderGetDouble(ORDER_TP);
      double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);

      string base = g_prefix + "ORD_" + (string)ticket;

      string priceLabel = StringFormat("%s %s at %s",OrderTypeText(type),
                                        DoubleToString(volume,2),
                                        DoubleToString(price,_Digits));

      DrawLevel(base + "_PRICE",price,InpPendingColor,STYLE_DASHDOT,priceLabel);
      DrawLevel(base + "_SL",   sl,   InpSLColor,      STYLE_DASHDOT,"SL");
      DrawLevel(base + "_TP",   tp,   InpTPColor,      STYLE_DASHDOT,"TP");
   }

   RemoveStaleLines();
}
