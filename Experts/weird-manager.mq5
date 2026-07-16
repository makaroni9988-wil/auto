#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// INPUT SETTINGS
//==================================================================
input string ManagerMagicList    = "0;777;888";

input bool   IncludeManualTrades = false;
input bool   BypassMagicFilter   = false;

input double PartialPercent      = 30.0;

input int    DeviationPoints     = 50;

input uint   ActionCooldownMs    = 300;

// Main Panel
input bool   ShowMainPanel       = true;

input color  UI_BgColor          = clrBlack;
input color  UI_TextColor        = clrWhiteSmoke;
input color  UI_BorderColor      = clrBlack;
input color  UI_EditBorderColor  = clrRed;

input string UI_Font             = "Consolas Bold";
input int    UI_FontSize         = 9;

input int    MainPanelStartX     = 260;
input int    MainPanelStartY     = 25;

input int    MainButtonWidth     = 90;
input int    MainButtonHeight    = 20;

input int    MainGapX            = 2;
input int    MainGapY            = 3;

input color  BuySLColor          = clrTomato;
input color  SellSLColor         = clrTomato;
input color  BuyTPColor          = clrLime;
input color  SellTPColor         = clrLime;

input color  EntryPriceColor     = clrWhite;
input color  PendingPriceColor   = clrYellow;
input color  PendingSLColor      = clrTomato;
input color  PendingTPColor      = clrLime;

input bool   ShowLines           = false;  // ShowLines (global)
input int    LineWidth           = 1;
input ENUM_LINE_STYLE LineStyle  = STYLE_DOT;

// SL / TP Editor
input bool   ShowSLEditor        = false;
input int    SLEditorStartX      = 450;
input int    SLEditorStartY      = 5;
input int    SLEditorLabelWidth  = 100;
input int    SLEditorEditWidth   = 100;
input int    SLEditorHeight      = 20;
input int    SLEditorGapX        = 2;
input int    SLEditorGapY        = 3;
input color  SLEditorBgColor     = clrBlack;
input color  SLEditorTextColor   = clrWhiteSmoke;

input color EditorActiveTextColor    = clrLime;
input color EditorPendingTextColor   = clrYellow;

input color EditorActiveBgColor      = clrBlack;
input color EditorPendingBgColor     = clrBlack;

input color EditorActiveBorderColor  = clrDarkGreen;
input color EditorPendingBorderColor = clrDarkGoldenrod;

//==================================================================
// GLOBALS
//==================================================================
string PREFIX;
ulong  g_lastActionTick = 0;

bool g_editorPending = false;
long g_editorType    = POSITION_TYPE_BUY;
int  g_editorBuyLayer  = 1;
int  g_editorSellLayer = 1;

ulong g_managerMagic = 0;

ulong g_magicList[];
int   g_magicIndex = 0;

string EDITOR_MAGIC_PREV = "EDITOR_MAGIC_PREV";
string EDITOR_MAGIC_NEXT = "EDITOR_MAGIC_NEXT";

//==================================================================
// HELPERS
//==================================================================
string MagicDisplayName(ulong magic)
{
   if(magic == 0)
      return "[MANUAL 0]";

   if(magic == 777)
      return "[UNCLE 777]"; 
      
   if(magic == 888)
      return "[KOKO 888]";           
      
   return "MAGIC " + (string)magic;
}

void LoadManagerMagicList()
{
   ArrayResize(g_magicList,0);

   string parts[];
   int total = StringSplit(ManagerMagicList,';',parts);

   for(int i = 0; i < total; i++)
   {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);

      if(s == "")
         continue;

      ulong magic = (ulong)StringToInteger(s);

      int size = ArraySize(g_magicList);
      ArrayResize(g_magicList,size + 1);
      g_magicList[size] = magic;
   }

   if(ArraySize(g_magicList) <= 0)
   {
      ArrayResize(g_magicList,1);
      g_magicList[0] = 0;
   }

   g_magicIndex   = 0;
   g_managerMagic = g_magicList[0];
}

void MoveManagerMagic(int step)
{
   int count = ArraySize(g_magicList);

   if(count <= 0)
      return;

   g_magicIndex += step;

   if(g_magicIndex < 0)
      g_magicIndex = count - 1;

   if(g_magicIndex >= count)
      g_magicIndex = 0;

   g_managerMagic = g_magicList[g_magicIndex];

   RefreshEditorButtons();
   RefreshLines();
   ChartRedraw(0);
}

bool ActionAllowed()
{
   ulong now = GetTickCount64();
   if(now - g_lastActionTick < ActionCooldownMs)
      return false;

   g_lastActionTick = now;
   return true;
}

bool IsManagedPosition()
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   if(BypassMagicFilter)
      return true;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

   if(magic == g_managerMagic)
      return true;

   if(IncludeManualTrades && magic == 0)
      return true;

   return false;
}

bool IsManagedOrder()
{
   if(OrderGetString(ORDER_SYMBOL) != _Symbol)
      return false;

   if(BypassMagicFilter)
      return true;

   ulong magic = (ulong)OrderGetInteger(ORDER_MAGIC);

   if(magic == g_managerMagic)
      return true;

   if(IncludeManualTrades && magic == 0)
      return true;

   return false;
}

string OrderTypeText(long type)
{
   if(type == ORDER_TYPE_BUY_LIMIT)       return "BUY LIMIT";
   if(type == ORDER_TYPE_SELL_LIMIT)      return "SELL LIMIT";
   if(type == ORDER_TYPE_BUY_STOP)        return "BUY STOP";
   if(type == ORDER_TYPE_SELL_STOP)       return "SELL STOP";
   if(type == ORDER_TYPE_BUY_STOP_LIMIT)  return "BUY STOP LIMIT";
   if(type == ORDER_TYPE_SELL_STOP_LIMIT) return "SELL STOP LIMIT";
   return "PENDING";
}

string TypeText(long type)
{
   if(type == POSITION_TYPE_BUY)
      return "BUY";
   if(type == POSITION_TYPE_SELL)
      return "SELL";
   return "UNKNOWN";
}

string LevelText(bool isSL)
{
   return isSL ? "SL" : "TP";
}

string ButtonName(string id)
{
   return PREFIX + "BTN_" + id;
}

string EditName(string id)
{
   return PREFIX + "EDIT_" + id;
}

string LineName(string dir,string level,ulong ticket)
{
   return PREFIX + dir + "_" + level + "_" + (string)ticket;
}

bool IsManagerObject(string name)
{
   return (StringFind(name,PREFIX) == 0);
}

void DeleteManagerObjects()
{
   for(int i = ObjectsTotal(0,0,-1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0,i,0,-1);
      if(IsManagerObject(name))
         ObjectDelete(0,name);
   }
}

//==================================================================
// PANEL
//==================================================================
void CreateButton(string id,string text,int x,int y,int width,int height)
{
   string name = ButtonName(id);

   if(ObjectFind(0,name) < 0)
      ObjectCreate(0,name,OBJ_BUTTON,0,0,0);

   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,UI_FontSize);
   ObjectSetString (0,name,OBJPROP_FONT,UI_Font);
   ObjectSetInteger(0,name,OBJPROP_ALIGN,ALIGN_LEFT);
   ObjectSetInteger(0,name,OBJPROP_COLOR,UI_TextColor);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,UI_BgColor);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,UI_BorderColor);
   if(StringLen(text) <= 1)
      ObjectSetString(0,name,OBJPROP_TEXT,text);
   else
      ObjectSetString(0,name,
                      OBJPROP_TEXT,
                      StringFormat("%-10s",text));
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void CreateEdit(string id,string text,int x,int y,int width,int height)
{
   string name = EditName(id);

   if(ObjectFind(0,name) < 0)
      ObjectCreate(0,name,OBJ_EDIT,0,0,0);

   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,UI_FontSize);
   ObjectSetString (0,name,OBJPROP_FONT,UI_Font);
   ObjectSetInteger(0,name,OBJPROP_COLOR,SLEditorTextColor);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,SLEditorBgColor);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,UI_EditBorderColor);
   ObjectSetInteger(0,name,OBJPROP_ALIGN,ALIGN_CENTER);

   if(ObjectGetString(0,name,OBJPROP_TEXT) == "")
      ObjectSetString(0,name,OBJPROP_TEXT,text);

   ObjectSetInteger(0,name,OBJPROP_READONLY,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void CreateSLEditorPanel()
{
   if(!ShowSLEditor)
      return;

   int x  = SLEditorStartX;
   int x2 = SLEditorStartX + SLEditorLabelWidth + SLEditorGapX;
   int y  = SLEditorStartY;
   int h  = SLEditorHeight;

   int fullW  = SLEditorLabelWidth + SLEditorGapX + SLEditorEditWidth;
   int arrowW = 15;
   int countW = SLEditorEditWidth - (arrowW * 2);

   if(countW < 30)
      countW = 30;

   int leftX  = x2;
   int boxX   = leftX + arrowW;
   int rightX = boxX + countW;

// Full middle row, same width as CLOSE ALL if fullW
CreateButton("EDITOR_MAGIC_PREV", "<", x, y, arrowW, h);
CreateButton("EDITOR_TARGET", "ACTIVE", x + arrowW + SLEditorGapX, y,
             fullW - (arrowW * 2) - (SLEditorGapX * 2), h);
CreateButton("EDITOR_MAGIC_NEXT", ">", x + fullW - arrowW, y, arrowW, h);
   
                ObjectSetInteger(
                0,
                ButtonName("EDITOR_TARGET"),
                OBJPROP_BORDER_COLOR,
                clrWhite
                );
   
   y += h + SLEditorGapY;

   // Left side = BUY/SELL column. Right side = selector, same width as typing box.
   CreateButton("EDITOR_BUY_SIDE",  "BUY",   x,     y, SLEditorLabelWidth, h);
   CreateButton("EDITOR_BUY_PREV",  "<",     leftX, y, arrowW,             h);
   CreateButton("EDITOR_BUY_COUNT", "0 / 0", boxX,  y, countW,             h);
   CreateButton("EDITOR_BUY_NEXT",  ">",     rightX,y, arrowW,             h);
   y += h + SLEditorGapY;

   CreateButton("EDITOR_SELL_SIDE",  "SELL",  x,     y, SLEditorLabelWidth, h);
   CreateButton("EDITOR_SELL_PREV",  "<",     leftX, y, arrowW,             h);
   CreateButton("EDITOR_SELL_COUNT", "0 / 0", boxX,  y, countW,             h);
   CreateButton("EDITOR_SELL_NEXT",  ">",     rightX,y, arrowW,             h);
   y += h + SLEditorGapY;

   // Left labels align with BUY/SELL. Typing boxes have their own red border.
   CreateButton("APPLY_SL", " APPLY SL", x,  y, SLEditorLabelWidth, h);
   CreateEdit  ("EDITOR_SL", "",       x2, y, SLEditorEditWidth,  h);
   y += h + SLEditorGapY;

   CreateButton("APPLY_TP", " APPLY TP", x,  y, SLEditorLabelWidth, h);
   CreateEdit  ("EDITOR_TP", "",       x2, y, SLEditorEditWidth,  h);
}

void CreatePanel()
{
   if(!ShowMainPanel)
      return;

   int x1 = MainPanelStartX;
   int x2 = MainPanelStartX + MainButtonWidth + MainGapX;
   int y  = MainPanelStartY;

   int fullW = (MainButtonWidth * 2) + MainGapX;

   CreateButton("BUY_PARTI",
                "BUY PARTI",
                x1,y,
                MainButtonWidth,
                MainButtonHeight);
   
   CreateButton("SELL_PARTI",
                "SELL PARTI",
                x2,y,
                MainButtonWidth,
                MainButtonHeight);
                
   y += MainButtonHeight + MainGapY;             

   CreateButton("BUY_CLOSE", "BUY CLOSE", x1,y,MainButtonWidth,MainButtonHeight);
   CreateButton("SELL_CLOSE","SELL CLOSE",x2,y,MainButtonWidth,MainButtonHeight);

   y += MainButtonHeight + MainGapY;

   // Full-width and centered if fullW
   CreateButton("CLOSE_ALL", "- CLOSE ALL -", x1,y,fullW,MainButtonHeight);
}

//==================================================================
// LINE DRAWING
//==================================================================
void DrawLine(string name,double price,color clr)
{
   if(price <= 0)
      return;

   price = NormalizeDouble(price,_Digits);

   if(ObjectFind(0,name) < 0)
      ObjectCreate(0,name,OBJ_HLINE,0,0,price);

   ObjectSetDouble (0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,LineWidth);
   ObjectSetInteger(0,name,OBJPROP_STYLE,LineStyle);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,1000);
   ObjectSetString (0,name,OBJPROP_TEXT,"");
}

void DeleteManagerLinesOnly()
{
   for(int i = ObjectsTotal(0,0,-1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0,i,0,-1);

      if(StringFind(name,PREFIX) != 0)
         continue;

      if(StringFind(name,PREFIX + "BTN_") == 0)
         continue;

      if(StringFind(name,PREFIX + "EDIT_") == 0)
         continue;

      ObjectDelete(0,name);
   }
}

void DrawRealLevelsForDirection(long type,bool isSL)
{
   double firstLevel = -1;
   bool   hasLevel   = false;
   bool   sameLevel  = true;
   int    count      = 0;

   ulong  tickets[];
   double levels[];

   ArrayResize(tickets,0);
   ArrayResize(levels,0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsManagedPosition())
         continue;

      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      double level = isSL ? PositionGetDouble(POSITION_SL)
                          : PositionGetDouble(POSITION_TP);

      if(level <= 0)
         continue;

      level = NormalizeDouble(level,_Digits);

      int size = ArraySize(tickets);
      ArrayResize(tickets,size + 1);
      ArrayResize(levels,size + 1);
      tickets[size] = ticket;
      levels[size]  = level;

      count++;
      hasLevel = true;

      if(firstLevel < 0)
         firstLevel = level;
      else if(MathAbs(firstLevel - level) > (_Point * 2))
         sameLevel = false;
   }

   if(!hasLevel)
      return;

   string dir   = TypeText(type);
   string level = LevelText(isSL);
   color clr    = clrNONE;

   if(type == POSITION_TYPE_BUY && isSL)  clr = BuySLColor;
   if(type == POSITION_TYPE_SELL && isSL) clr = SellSLColor;
   if(type == POSITION_TYPE_BUY && !isSL) clr = BuyTPColor;
   if(type == POSITION_TYPE_SELL && !isSL)clr = SellTPColor;

   if(sameLevel)
   {
      string name = LineName(dir,level,0);
      DrawLine(name,firstLevel,clr);
      return;
   }

   for(int j = 0; j < ArraySize(tickets); j++)
   {
      string name = LineName(dir,level,tickets[j]);
      DrawLine(name,levels[j],clr);
   }
}

void DrawEntryForDirection(long type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsManagedPosition())
         continue;

      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(price <= 0)
         continue;

      string dir = TypeText(type);
      DrawLine(LineName(dir,"ENTRY",ticket),price,EntryPriceColor);
   }
}

void DrawPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      if(!IsManagedOrder())
         continue;

      long type = OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT &&
         type != ORDER_TYPE_SELL_LIMIT &&
         type != ORDER_TYPE_BUY_STOP &&
         type != ORDER_TYPE_SELL_STOP &&
         type != ORDER_TYPE_BUY_STOP_LIMIT &&
         type != ORDER_TYPE_SELL_STOP_LIMIT)
      {
         continue;
      }

      double openPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double sl        = OrderGetDouble(ORDER_SL);
      double tp        = OrderGetDouble(ORDER_TP);

      string base = PREFIX + "PENDING_" + (string)ticket + "_";

      DrawLine(base + "PRICE",openPrice,PendingPriceColor);

      if(sl > 0)
         DrawLine(base + "SL",sl,PendingSLColor);

      if(tp > 0)
         DrawLine(base + "TP",tp,PendingTPColor);
   }
}

void RefreshLines()
{
   DeleteManagerLinesOnly();

   if(!ShowLines)
      return;

   DrawEntryForDirection(POSITION_TYPE_BUY);
   DrawEntryForDirection(POSITION_TYPE_SELL);

   DrawRealLevelsForDirection(POSITION_TYPE_BUY,true);
   DrawRealLevelsForDirection(POSITION_TYPE_BUY,false);
   DrawRealLevelsForDirection(POSITION_TYPE_SELL,true);
   DrawRealLevelsForDirection(POSITION_TYPE_SELL,false);

   DrawPendingOrders();
}

//==================================================================
// TRADE ACTIONS
//==================================================================
bool ModifyTicketLevel(ulong ticket,bool isSL,double price)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   if(!IsManagedPosition())
      return false;

   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);

   price = NormalizeDouble(price,_Digits);

   if(isSL)
      sl = price;
   else
      tp = price;

   if(sl > 0) sl = NormalizeDouble(sl,_Digits);
   if(tp > 0) tp = NormalizeDouble(tp,_Digits);

   if(!trade.PositionModify(ticket,sl,tp))
   {
      return false;
   }

   return true;
}

void ModifyDirectionLevel(long type,bool isSL,double price)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsManagedPosition())
         continue;

      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      ModifyTicketLevel(ticket,isSL,price);
   }
}

bool ReadEditPrice(string id,double &price)
{
   string txt = ObjectGetString(0,EditName(id),OBJPROP_TEXT);
   StringTrimLeft(txt);
   StringTrimRight(txt);

   if(txt == "")
      return false;

   price = StringToDouble(txt);
   if(price <= 0)
      return false;

   price = NormalizeDouble(price,_Digits);
   return true;
}

void ClearEditPrice(string id)
{
   ObjectSetString(0,EditName(id),OBJPROP_TEXT,"");
}

bool IsPendingOrderType(long type)
{
   return (type == ORDER_TYPE_BUY_LIMIT ||
           type == ORDER_TYPE_SELL_LIMIT ||
           type == ORDER_TYPE_BUY_STOP ||
           type == ORDER_TYPE_SELL_STOP ||
           type == ORDER_TYPE_BUY_STOP_LIMIT ||
           type == ORDER_TYPE_SELL_STOP_LIMIT);
}

bool IsPendingBuyType(long type)
{
   return (type == ORDER_TYPE_BUY_LIMIT ||
           type == ORDER_TYPE_BUY_STOP ||
           type == ORDER_TYPE_BUY_STOP_LIMIT);
}

bool IsPendingSellType(long type)
{
   return (type == ORDER_TYPE_SELL_LIMIT ||
           type == ORDER_TYPE_SELL_STOP ||
           type == ORDER_TYPE_SELL_STOP_LIMIT);
}


int CountEditorTargets(bool pending,long posType)
{
   int count = 0;

   if(pending)
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0)
            continue;

         if(!OrderSelect(ticket))
            continue;

         if(!IsManagedOrder())
            continue;

         long orderType = OrderGetInteger(ORDER_TYPE);
         if(!IsPendingOrderType(orderType))
            continue;

         if(posType == POSITION_TYPE_BUY && !IsPendingBuyType(orderType))
            continue;

         if(posType == POSITION_TYPE_SELL && !IsPendingSellType(orderType))
            continue;

         count++;
      }

      return count;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsManagedPosition())
         continue;

      if(PositionGetInteger(POSITION_TYPE) != posType)
         continue;

      count++;
   }

   return count;
}

bool GetEditorTargetTicket(bool pending,long posType,int layer,ulong &ticket)
{
   ticket = 0;

   if(layer < 1)
      layer = 1;

   ulong    tickets[];
   datetime times[];

   int count = 0;

   if(pending)
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong tk = OrderGetTicket(i);
         if(tk == 0)
            continue;

         if(!OrderSelect(tk))
            continue;

         if(!IsManagedOrder())
            continue;

         long orderType = OrderGetInteger(ORDER_TYPE);

         if(!IsPendingOrderType(orderType))
            continue;

         if(posType == POSITION_TYPE_BUY && !IsPendingBuyType(orderType))
            continue;

         if(posType == POSITION_TYPE_SELL && !IsPendingSellType(orderType))
            continue;

         ArrayResize(tickets,count + 1);
         ArrayResize(times,count + 1);

         tickets[count] = tk;
         times[count]   = (datetime)OrderGetInteger(ORDER_TIME_SETUP);

         count++;
      }
   }
   else
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0)
            continue;

         if(!PositionSelectByTicket(tk))
            continue;

         if(!IsManagedPosition())
            continue;

         if(PositionGetInteger(POSITION_TYPE) != posType)
            continue;

         ArrayResize(tickets,count + 1);
         ArrayResize(times,count + 1);

         tickets[count] = tk;
         times[count]   = (datetime)PositionGetInteger(POSITION_TIME);

         count++;
      }
   }

   if(count <= 0)
      return false;

   // sort oldest first
   for(int a = 0; a < count - 1; a++)
   {
      for(int b = a + 1; b < count; b++)
      {
         if(times[a] > times[b])
         {
            datetime tempTime = times[a];
            times[a] = times[b];
            times[b] = tempTime;

            ulong tempTicket = tickets[a];
            tickets[a] = tickets[b];
            tickets[b] = tempTicket;
         }
      }
   }

   if(layer > count)
      return false;

   ticket = tickets[layer - 1];
   return true;
}

bool ModifyPendingTicketLevel(ulong ticket,bool isSL,double price)
{
   if(!OrderSelect(ticket))
      return false;

   if(!IsManagedOrder())
      return false;

   long type = OrderGetInteger(ORDER_TYPE);
   if(!IsPendingOrderType(type))
      return false;

   double openPrice = OrderGetDouble(ORDER_PRICE_OPEN);
   double sl        = OrderGetDouble(ORDER_SL);
   double tp        = OrderGetDouble(ORDER_TP);
   double stopLimit = OrderGetDouble(ORDER_PRICE_STOPLIMIT);

   ENUM_ORDER_TYPE_TIME typeTime = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
   datetime expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

   price = NormalizeDouble(price,_Digits);

   if(isSL)
      sl = price;
   else
      tp = price;

   if(sl > 0) sl = NormalizeDouble(sl,_Digits);
   if(tp > 0) tp = NormalizeDouble(tp,_Digits);

   if(!trade.OrderModify(ticket,openPrice,sl,tp,typeTime,expiration,stopLimit))
   {
      return false;
   }

   return true;
}

int ClampLayerByCount(int layer,int total)
{
   if(total <= 0)
      return 0;

   if(layer < 1)
      return 1;

   if(layer > total)
      return total;

   return layer;
}

string CountText(int current,int total)
{
   return (string)current + " / " + (string)total;
}

void RefreshEditorButtons()
{
   if(!ShowSLEditor)
      return;

   int buyTotal  = CountEditorTargets(g_editorPending,POSITION_TYPE_BUY);
   int sellTotal = CountEditorTargets(g_editorPending,POSITION_TYPE_SELL);

   g_editorBuyLayer  = ClampLayerByCount(g_editorBuyLayer,buyTotal);
   g_editorSellLayer = ClampLayerByCount(g_editorSellLayer,sellTotal);

   if(g_editorType == POSITION_TYPE_BUY && buyTotal <= 0 && sellTotal > 0)
      g_editorType = POSITION_TYPE_SELL;

   if(g_editorType == POSITION_TYPE_SELL && sellTotal <= 0 && buyTotal > 0)
      g_editorType = POSITION_TYPE_BUY;

string targetName = ButtonName("EDITOR_TARGET");

string modeText = g_editorPending ? "PENDING" : "ACTIVE";

string magicText = MagicDisplayName(g_managerMagic);

int totalChars = 20; // adjust this wider/smaller

int spaces = totalChars - StringLen(modeText) - StringLen(magicText);

if(spaces < 1)
   spaces = 1;

string gap = "";

for(int i = 0; i < spaces; i++)
   gap += " ";

ObjectSetString(0,targetName,OBJPROP_TEXT,
                modeText + gap + magicText);
   
   ObjectSetInteger(0,targetName,OBJPROP_COLOR,
                    g_editorPending ?
                    EditorPendingTextColor :
                    EditorActiveTextColor);
   
   ObjectSetInteger(0,targetName,OBJPROP_BGCOLOR,
                    g_editorPending ?
                    EditorPendingBgColor :
                    EditorActiveBgColor);
   
   ObjectSetInteger(0,targetName,OBJPROP_BORDER_COLOR,
                    g_editorPending ?
                    EditorPendingBorderColor :
                    EditorActiveBorderColor);

   ObjectSetString(0,ButtonName("EDITOR_BUY_SIDE"),OBJPROP_TEXT,
                   (g_editorType == POSITION_TYPE_BUY ? "[BUY]" : "BUY"));

   ObjectSetString(0,ButtonName("EDITOR_SELL_SIDE"),OBJPROP_TEXT,
                   (g_editorType == POSITION_TYPE_SELL ? "[SELL]" : "SELL"));

   ObjectSetString(0,ButtonName("EDITOR_BUY_COUNT"),OBJPROP_TEXT,
                   CountText(g_editorBuyLayer,buyTotal));

   ObjectSetString(0,ButtonName("EDITOR_SELL_COUNT"),OBJPROP_TEXT,
                   CountText(g_editorSellLayer,sellTotal));
}

void ToggleEditorTarget()
{
   g_editorPending = !g_editorPending;
   RefreshEditorButtons();
   ChartRedraw(0);
}

void SelectEditorSide(long posType)
{
   g_editorType = posType;
   RefreshEditorButtons();
   ChartRedraw(0);
}

void MoveEditorLayer(long posType,int step)
{
   int total = CountEditorTargets(g_editorPending,posType);

   g_editorType = posType;

   if(posType == POSITION_TYPE_BUY)
   {
      if(total <= 0)
      {
         g_editorBuyLayer = 0;
      }
      else
      {
         if(g_editorBuyLayer <= 0)
            g_editorBuyLayer = 1;

         g_editorBuyLayer += step;

         if(g_editorBuyLayer < 1)
            g_editorBuyLayer = total;

         if(g_editorBuyLayer > total)
            g_editorBuyLayer = 1;
      }
   }
   else
   {
      if(total <= 0)
      {
         g_editorSellLayer = 0;
      }
      else
      {
         if(g_editorSellLayer <= 0)
            g_editorSellLayer = 1;

         g_editorSellLayer += step;

         if(g_editorSellLayer < 1)
            g_editorSellLayer = total;

         if(g_editorSellLayer > total)
            g_editorSellLayer = 1;
      }
   }

   RefreshEditorButtons();
   ChartRedraw(0);
}

int CurrentEditorLayer()
{
   if(g_editorType == POSITION_TYPE_BUY)
      return g_editorBuyLayer;

   return g_editorSellLayer;
}

void ApplyEditorLevel(bool isSL)
{
   if(!ActionAllowed())
      return;

   double price = 0;
   string editId = isSL ? "EDITOR_SL" : "EDITOR_TP";

   if(!ReadEditPrice(editId,price))
      return;

   ulong ticket = 0;

   if(!GetEditorTargetTicket(g_editorPending,g_editorType,CurrentEditorLayer(),ticket))
   {
      return;
   }

   bool ok = false;

   if(g_editorPending)
      ok = ModifyPendingTicketLevel(ticket,isSL,price);
   else
      ok = ModifyTicketLevel(ticket,isSL,price);

   if(!ok)
      return;

   ClearEditPrice(editId);
   RefreshEditorButtons();
   RefreshLines();
   ChartRedraw(0);
}

void CloseDirection(long type)
{
   if(!ActionAllowed())
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsManagedPosition())
         continue;

      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      if(!trade.PositionClose(ticket))
      {
      }
   }
}

void PartialDirection(long type)
{
   if(!ActionAllowed())
      return;

   double minLot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   double stepLot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsManagedPosition())
         continue;

      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      double volume =
         PositionGetDouble(POSITION_VOLUME);

      //==================================================
      // Skip smallest lot
      // Example: 0.01 cannot be partial closed safely
      //==================================================
      if(volume <= minLot)
         continue;

      double closeLots =
         volume * PartialPercent / 100.0;

      closeLots =
         MathFloor(closeLots / stepLot) * stepLot;

      closeLots =
         NormalizeDouble(closeLots,(int)MathRound(-MathLog10(stepLot)));

      //==================================================
      // Never full close from partial button
      // Leave at least minimum lot running
      //==================================================
      double maxCloseLots =
         volume - minLot;

      maxCloseLots =
         MathFloor(maxCloseLots / stepLot) * stepLot;

      maxCloseLots =
         NormalizeDouble(maxCloseLots,(int)MathRound(-MathLog10(stepLot)));

      if(closeLots > maxCloseLots)
         closeLots = maxCloseLots;

      //==================================================
      // If too small, skip quietly
      // No broker request, no spam
      //==================================================
      if(closeLots < minLot)
         continue;

      if(!trade.PositionClosePartial(ticket,closeLots))
      {
      }
   }
}

void CloseAllManaged()
{
   if(!ActionAllowed())
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      // Only current chart symbol
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      trade.PositionClose(ticket);
   }

   //==================================================
   // Delete all pending orders on this symbol
   // Master close: no magic filter, fire and forget
   //==================================================
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      // Only current chart symbol
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      trade.OrderDelete(ticket);
   }
}

//==================================================================
// LINE EVENT PARSER
//==================================================================
bool ParseLineName(string name,string &dir,string &level,ulong &ticket)
{
   if(StringFind(name,PREFIX) != 0)
      return false;

   string rest = StringSubstr(name,StringLen(PREFIX));
   string parts[];
   int n = StringSplit(rest,'_',parts);

   if(n != 3)
      return false;

   dir    = parts[0];
   level  = parts[1];
   ticket = (ulong)StringToInteger(parts[2]);

   if(dir != "BUY" && dir != "SELL")
      return false;

   if(level != "SL" && level != "TP")
      return false;

   return true;
}

void HandleLineDrag(string name)
{
   if(!ActionAllowed())
      return;

   string dir,level;
   ulong ticket;

   if(!ParseLineName(name,dir,level,ticket))
      return;

   double price = ObjectGetDouble(0,name,OBJPROP_PRICE);
   if(price <= 0)
      return;

   bool isSL = (level == "SL");
   long type = (dir == "BUY") ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   if(ticket == 0)
      ModifyDirectionLevel(type,isSL,price);
   else
      ModifyTicketLevel(ticket,isSL,price);

   RefreshLines();
}

//==================================================================
// EVENTS
//==================================================================
int OnInit()
{
   PREFIX = "MTM_" + (string)ChartID() + "_";
   LoadManagerMagicList();

   trade.SetDeviationInPoints(DeviationPoints);

   CreatePanel();
   CreateSLEditorPanel();
   RefreshEditorButtons();
   RefreshLines();
   ChartRedraw(0);

   EventSetTimer(1);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   // Chart objects PERSIST across timeframe switches. Deleting them here
   // on a TF flip (the old way) wiped every button/label/line mid-reinit,
   // then OnInit rebuilt them = the visible blink. On REASON_CHARTCHANGE
   // the objects are left alive for the next init to ADOPT (CreateButton
   // is already find-first). Real removal, recompile, input change and
   // chart close still clean up exactly as before.
   if(reason != REASON_CHARTCHANGE)
      DeleteManagerObjects();
}

void OnTick()
{
// keep it light
}

void OnTimer()
{
   RefreshEditorButtons();
   RefreshLines();
   ChartRedraw(0);
}

//==================================================================
// TRADE EVENTS
//==================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest      &request,
                        const MqlTradeResult       &result)
{
   // Catches: SL/TP hit, stop-out, manual close from terminal,
   // partial close, position open/modify, pending order fill —
   // anything that changes the real trade state, panel-button or not.
   switch(trans.type)
   {
      case TRADE_TRANSACTION_DEAL_ADD:
      case TRADE_TRANSACTION_HISTORY_ADD:
      case TRADE_TRANSACTION_POSITION:
      case TRADE_TRANSACTION_ORDER_ADD:
      case TRADE_TRANSACTION_ORDER_DELETE:
      case TRADE_TRANSACTION_ORDER_UPDATE:
         RefreshLines();
         RefreshEditorButtons();
         ChartRedraw(0);
         break;

      default:
         break;
   }
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == ButtonName("EDITOR_MAGIC_PREV"))
      {
         MoveManagerMagic(-1);
         return;
      }
      
      if(sparam == ButtonName("EDITOR_MAGIC_NEXT"))
      {
         MoveManagerMagic(1);
         return;
      }
      
      if(sparam == ButtonName("EDITOR_TARGET"))
      {
         ToggleEditorTarget();
         return;
      }

      if(sparam == ButtonName("EDITOR_BUY_SIDE") ||
         sparam == ButtonName("EDITOR_BUY_COUNT"))
      {
         SelectEditorSide(POSITION_TYPE_BUY);
         return;
      }

      if(sparam == ButtonName("EDITOR_SELL_SIDE") ||
         sparam == ButtonName("EDITOR_SELL_COUNT"))
      {
         SelectEditorSide(POSITION_TYPE_SELL);
         return;
      }

      if(sparam == ButtonName("EDITOR_BUY_PREV"))
      {
         MoveEditorLayer(POSITION_TYPE_BUY,-1);
         return;
      }

      if(sparam == ButtonName("EDITOR_BUY_NEXT"))
      {
         MoveEditorLayer(POSITION_TYPE_BUY,1);
         return;
      }

      if(sparam == ButtonName("EDITOR_SELL_PREV"))
      {
         MoveEditorLayer(POSITION_TYPE_SELL,-1);
         return;
      }

      if(sparam == ButtonName("EDITOR_SELL_NEXT"))
      {
         MoveEditorLayer(POSITION_TYPE_SELL,1);
         return;
      }

      if(sparam == ButtonName("APPLY_SL"))
      {
         ApplyEditorLevel(true);
         return;
      }

      if(sparam == ButtonName("APPLY_TP"))
      {
         ApplyEditorLevel(false);
         return;
      }

      if(sparam == ButtonName("BUY_PARTI"))
      {
         PartialDirection(POSITION_TYPE_BUY);
         RefreshLines();
         return;
      }
      
      if(sparam == ButtonName("SELL_PARTI"))
      {
         PartialDirection(POSITION_TYPE_SELL);
         RefreshLines();
         return;
      }

      if(sparam == ButtonName("BUY_CLOSE"))
      {
         CloseDirection(POSITION_TYPE_BUY);
         RefreshLines();
         return;
      }

      if(sparam == ButtonName("SELL_CLOSE"))
      {
         CloseDirection(POSITION_TYPE_SELL);
         RefreshLines();
         return;
      }

      if(sparam == ButtonName("CLOSE_ALL"))
      {
         CloseAllManaged();
         RefreshLines();
         return;
      }
   }

   if(id == CHARTEVENT_OBJECT_DRAG)
   {
      HandleLineDrag(sparam);
      return;
   }
}