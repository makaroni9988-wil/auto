#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

input color  UI_TextColor  = clrWhiteSmoke;
input string UI_Font       = "Consolas";

input color LotPanelColor  = clrWhiteSmoke;

input int LotPanelStartX      = 3;     
input int LotPanelStartY      = 100;   

input int LotPanelColumnWidth = 150;
input int LotPanelRowHeight   = 15;
input int LotPanelGapX        = 2;
input int LotPanelGapY        = 3;

input int LotPanelFontSize = 9;

input bool ShowSpread      = true;
input bool ShowBuySellLots = true;

input int RefreshSeconds   = 1;

// Instance-unique object prefix, built in OnInit from the panel position
// (suite standard: identity by configuration). Two copies at different
// positions own separate objects; a reinit at the same position adopts
// and cleans the same names as before.
string PREFIX;

string LBL_EQUITY;
string LBL_DD;
string LBL_PNL;
string LBL_SPREAD;
string LBL_BUY;
string LBL_SELL;

//==================================================
// WARM-UP GRACE (suite standard)
//==================================================
// Right after attach/reinit the object subsystem can transiently refuse
// creation. Failures inside this grace window are retried silently by
// the 1-second timer; only a persistent one is logged, once, and the
// flag resets on recovery -- no journal spam.
uint g_initTick = 0;
#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
}

// Only print the label-creation failure once while it persists.
bool g_loggedCreateFail = false;

//==================================================
// Floating PnL for THIS CHART'S SYMBOL only (like the
// per-symbol P/L a normal panel should show), not the
// whole account. Includes swap. Commission is booked at
// deal level in MT5, so it can't be read per open
// position -- the terminal's own position list has the
// same limitation.
//==================================================

double TotalProfit()
{
   double total = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      // Skip positions belonging to other symbols.
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      total += PositionGetDouble(POSITION_PROFIT);
      total += PositionGetDouble(POSITION_SWAP);
   }

   return total;
}

//==================================================

double AccountDrawdownPercent()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance <= 0.0)
      return 0.0;

   double dd = ((balance - equity) / balance) * 100.0;

   if(dd < 0.0)
      dd = 0.0;

   return dd;
}

//==================================================
// Buy/Sell lot & count breakdown for THIS CHART'S
// SYMBOL only.
//==================================================

void GetBuySellStats(double &buyLots,
                     double &sellLots,
                     int &buyCount,
                     int &sellCount)
{
   buyLots = 0.0;
   sellLots = 0.0;
   buyCount = 0;
   sellCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      // Skip positions belonging to other symbols.
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double lot = PositionGetDouble(POSITION_VOLUME);

      if(type == POSITION_TYPE_BUY)
      {
         buyLots += lot;
         buyCount++;
      }
      else if(type == POSITION_TYPE_SELL)
      {
         sellLots += lot;
         sellCount++;
      }
   }
}

//==================================================

// Returns true when it had to (re)create or visibly change the label,
// so the caller knows a chart repaint is actually needed this pass.
bool CreateLabel(string name,
                 string text,
                 int x,
                 int y,
                 color labelColor)
{
   bool changed = false;

   if(ObjectFind(0, name) < 0)
   {
      ResetLastError();
      if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      {
         // Transient refusals happen during re-init -- retried every second.
         // Only a persistent failure past the grace window is reported, once.
         if(!StillWarmingUp() && !g_loggedCreateFail)
         {
            Print("PnL-Stat ERROR: failed to create label '", name, "', error code ", GetLastError(), ". Will keep retrying..");
            g_loggedCreateFail = true;
         }
         return false;
      }
      g_loggedCreateFail = false; // recovered -- future failures get reported again

      // Static properties: position, font and behavior derive purely from
      // inputs, so they are set ONCE at creation and never rewritten on
      // the per-second path (honoring the only-touch-what-differs rule).
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, LotPanelFontSize);
      ObjectSetString(0, name, OBJPROP_FONT, UI_Font);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      changed = true;
   }

   // Only touch properties that actually differ -- rewriting identical
   // text/colors every second just burns CPU and forces useless repaints.
   if(ObjectGetString(0, name, OBJPROP_TEXT) != text)
   {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      changed = true;
   }
   if((color)ObjectGetInteger(0, name, OBJPROP_COLOR) != labelColor)
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR, labelColor);
      changed = true;
   }

   return changed;
}

//==================================================

void UpdatePanel()
{
   // No separate "missing label" canary needed: CreateLabel below already
   // recreates any label that was deleted, on every 1-second update.

   int x = LotPanelStartX;
   int y = LotPanelStartY;

   int x2    = x + LotPanelColumnWidth + LotPanelGapX;
   int stepY = LotPanelRowHeight + LotPanelGapY;

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // SymbolInfoTick gives one CONSISTENT snapshot; two separate
   // SymbolInfoDouble calls can straddle a quote update and produce a
   // momentarily wrong (even negative) spread.
   MqlTick tick;
   double spread = 0.0;
   if(SymbolInfoTick(_Symbol, tick))
      spread = (tick.ask - tick.bid) / _Point;

   double pnl = TotalProfit();
   double dd  = AccountDrawdownPercent();

   double buyLots, sellLots;
   int buyCount, sellCount;

   GetBuySellStats(buyLots, sellLots, buyCount, sellCount);

   color pnlColor = LotPanelColor;

   if(pnl > 0.0)
      pnlColor = clrLime;
   else if(pnl < 0.0)
      pnlColor = clrRed;

   bool anyChanged = false;

   anyChanged |= CreateLabel(LBL_EQUITY,
               "Equity : " + DoubleToString(equity, 2),
               x,
               y,
               LotPanelColor);

   anyChanged |= CreateLabel(LBL_DD,
               "DD     : " + DoubleToString(dd, 2) + " %",
               x,
               y + stepY,
               LotPanelColor);

   anyChanged |= CreateLabel(LBL_PNL,
               "PnL  : " + DoubleToString(pnl, 2),
               x2,
               y,
               pnlColor);

   if(ShowSpread)
   {
      anyChanged |= CreateLabel(LBL_SPREAD,
                  "Spread : " + DoubleToString(spread, 0),
                  x,
                  y + stepY * 2,
                  UI_TextColor);
   }

   if(ShowBuySellLots)
   {
      anyChanged |= CreateLabel(LBL_BUY,
                  "Buy  : " + DoubleToString(buyLots, 2) +
                  " / " + IntegerToString(buyCount),
                  x2,
                  y + stepY,
                  UI_TextColor);

      anyChanged |= CreateLabel(LBL_SELL,
                  "Sell : " + DoubleToString(sellLots, 2) +
                  " / " + IntegerToString(sellCount),
                  x2,
                  y + stepY * 2,
                  UI_TextColor);
   }

   // Repaint only when something on the panel actually changed. Without
   // an explicit redraw MT5 may not repaint until some other chart event;
   // but forcing one every second when nothing changed is pure waste.
   if(anyChanged)
      ChartRedraw(0);
}

//==================================================

void DeletePanel()
{
   ObjectsDeleteAll(0, PREFIX);
}

//==================================================

int OnInit()
{
   // Identity by configuration (see PREFIX above).
   PREFIX = StringFormat("LOT_PNL_%d_%d_", LotPanelStartX, LotPanelStartY);

   LBL_EQUITY = PREFIX + "EQUITY";
   LBL_DD     = PREFIX + "DD";
   LBL_PNL    = PREFIX + "PNL";
   LBL_SPREAD = PREFIX + "SPREAD";
   LBL_BUY    = PREFIX + "BUY";
   LBL_SELL   = PREFIX + "SELL";

   // Start the warm-up grace clock (see StillWarmingUp above).
   g_initTick = GetTickCount();
   g_loggedCreateFail = false;

   // EventSetTimer(0) (or a negative value) fails silently -- the panel
   // would draw once and then never refresh again. Clamp to >= 1 second.
   int refresh = RefreshSeconds;
   if(refresh < 1)
      refresh = 1;

   EventSetTimer(refresh);
   UpdatePanel();
   return INIT_SUCCEEDED;
}

//==================================================

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeletePanel();
}

//==================================================

void OnTimer()
{
   UpdatePanel();
}

//==================================================

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
   return rates_total;
}