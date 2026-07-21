#property copyright "Copyright 2026"
#property version   "1.00"
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

   // Keep lines alive across a timeframe switch so the next OnInit
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

void DrawLine(string name,double price,color clr,ENUM_LINE_STYLE style)
{
   if(price <= 0)
      return;

   price = NormalizeDouble(price,_Digits);

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

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);

      string base = g_prefix + "POS_" + (string)ticket;

      DrawLine(base + "_OPEN",openPrice,entryColor,STYLE_DOT);
      DrawLine(base + "_SL",  sl,        InpSLColor, STYLE_DASHDOT);
      DrawLine(base + "_TP",  tp,        InpTPColor, STYLE_DASHDOT);
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

      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      double sl    = OrderGetDouble(ORDER_SL);
      double tp    = OrderGetDouble(ORDER_TP);

      string base = g_prefix + "ORD_" + (string)ticket;

      DrawLine(base + "_PRICE",price,InpPendingColor,STYLE_DASHDOT);
      DrawLine(base + "_SL",   sl,   InpSLColor,      STYLE_DASHDOT);
      DrawLine(base + "_TP",   tp,   InpTPColor,      STYLE_DASHDOT);
   }

   RemoveStaleLines();
}
