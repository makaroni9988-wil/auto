//+------------------------------------------------------------------+
//|                                 ATR_Grid_Martingale_Hedge.mq5    |
//|  Grid martingale EA for MT5 HEDGING accounts.                    |
//|                                                                  |
//|  NEW in v3:                                                      |
//|  - Auto trend filter (EMA fast/slow, higher TF). In an uptrend   |
//|    only BUY grid opens new entries; downtrend -> only SELL.      |
//|    Existing baskets still get managed/closed either way.         |
//|  - TP_PERCENT_GLOBAL mode: TP as % of balance, SAME unit as the  |
//|    SL cut-off (InpMaxLossPct), so you can directly compare them. |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_TREND_MODE
  {
   TREND_FOLLOW   = 0,  // Trade WITH trend: buy in uptrend, sell in downtrend
   TREND_REVERSAL = 1   // Trade AGAINST trend: buy in downtrend, sell in uptrend
  };

enum ENUM_TP_MODE
  {
   TP_ATR_BASKET     = 0,  // ATR basket   (breakeven +/- ATR x value, per side)
   TP_PIPS_BASKET    = 1,  // Pips basket  (breakeven +/- value pips, per side)
   TP_MONEY_BASKET   = 2,  // Money basket (side profit >= value $, per side)
   TP_MONEY_GLOBAL   = 3,  // Money global (total profit >= value $, close ALL)
   TP_PERCENT_GLOBAL = 4   // Percent global (total profit >= value % of balance, close ALL)
  };

//--- Inputs
input group             "=== Grid / Martingale ==="
input double            InpInitialLot     = 0.01;       // Initial lot size
input double            InpLotMultiplier  = 2.0;        // Martingale lot multiplier
input int               InpATRPeriod      = 14;         // ATR period
input ENUM_TIMEFRAMES   InpATRTimeframe   = PERIOD_H1;  // ATR timeframe
input double            InpGridATRMult    = 1.0;        // Grid distance = ATR x this
input bool              InpTradeBuy       = true;       // Enable BUY grid (master switch)
input bool              InpTradeSell      = true;       // Enable SELL grid (master switch)

input group             "=== Auto Trend Filter (0/false = off, trades both ways) ==="
input bool              InpUseTrendFilter = false;      // Auto-detect trend, filter entries
input ENUM_TREND_MODE   InpTrendMode      = TREND_FOLLOW; // Follow trend or fade it (reversal)
input ENUM_TIMEFRAMES   InpTrendTimeframe = PERIOD_H4;  // Timeframe for trend detection
input int               InpTrendFastEMA   = 50;         // Fast EMA period
input int               InpTrendSlowEMA   = 200;        // Slow EMA period
input double            InpTrendMinDiffPips = 20;       // Min EMA separation (pips) to call it a trend

input group             "=== Take Profit (pick ONE mode) ==="
input ENUM_TP_MODE      InpTPMode         = TP_ATR_BASKET; // TP mode
input double            InpTPValue        = 1.0;        // TP value (ATR mult / pips / money / percent)

input group             "=== Safety (0 = disabled) ==="
input int               InpMaxGridLevels  = 10;         // Max positions per side (0 = unlimited)
input double            InpMaxLossMoney   = 0;          // Cut-off: close all at floating loss >= this $ (0 = off)
input double            InpMaxLossPct     = 0;          // Cut-off: close all at floating loss >= this % of balance (0 = off)

input group             "=== Misc ==="
input ulong             InpMagic          = 20260716;   // Magic number
input int               InpSlippagePoints = 30;         // Max slippage (points)

//--- Globals
CTrade   trade;
int      g_atrHandle    = INVALID_HANDLE;
int      g_maFastHandle = INVALID_HANDLE;
int      g_maSlowHandle = INVALID_HANDLE;
bool     g_halted       = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_atrHandle = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle");
      return(INIT_FAILED);
     }

   if(InpUseTrendFilter)
     {
      g_maFastHandle = iMA(_Symbol, InpTrendTimeframe, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_maSlowHandle = iMA(_Symbol, InpTrendTimeframe, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_maFastHandle == INVALID_HANDLE || g_maSlowHandle == INVALID_HANDLE)
        {
         Print("Failed to create trend EMA handles");
         return(INIT_FAILED);
        }
     }

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: account is NOT in hedging mode. Buy and sell grids will offset each other.");

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle    != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_maFastHandle != INVALID_HANDLE) IndicatorRelease(g_maFastHandle);
   if(g_maSlowHandle != INVALID_HANDLE) IndicatorRelease(g_maSlowHandle);
  }
//+------------------------------------------------------------------+
double GetATR()
  {
   double buf[1];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1) return(0.0);
   return(buf[0]);
  }
//+------------------------------------------------------------------+
double GetMAValue(int handle)
  {
   double buf[1];
   if(CopyBuffer(handle, 0, 1, 1, buf) != 1) return(0.0);
   return(buf[0]);
  }
//+------------------------------------------------------------------+
double PipSize()
  {
   return((_Digits == 3 || _Digits == 5) ? 10 * _Point : _Point);
  }
//+------------------------------------------------------------------+
//| Returns +1 uptrend, -1 downtrend, 0 ranging / filter off          |
//+------------------------------------------------------------------+
int GetTrendDirection()
  {
   if(!InpUseTrendFilter) return(0);
   double fast = GetMAValue(g_maFastHandle);
   double slow = GetMAValue(g_maSlowHandle);
   if(fast == 0.0 || slow == 0.0) return(0);
   double diff      = fast - slow;
   double threshold = InpTrendMinDiffPips * PipSize();
   if(diff >  threshold) return(1);
   if(diff < -threshold) return(-1);
   return(0);
  }
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / lotStep + 0.5) * lotStep;
   return(MathMax(minLot, MathMin(maxLot, lot)));
  }
//+------------------------------------------------------------------+
void GetBasketInfo(const ENUM_POSITION_TYPE side,
                   int &count, double &totalLots, double &breakeven,
                   double &extremePrice, double &sideProfit)
  {
   count = 0; totalLots = 0.0; breakeven = 0.0; sideProfit = 0.0;
   double sumLotPrice = 0.0;
   extremePrice = (side == POSITION_TYPE_BUY) ? DBL_MAX : -DBL_MAX;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;

      double lot   = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);

      count++;
      totalLots   += lot;
      sumLotPrice += lot * price;
      sideProfit  += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(side == POSITION_TYPE_BUY)  extremePrice = MathMin(extremePrice, price);
      else                           extremePrice = MathMax(extremePrice, price);
     }

   if(totalLots > 0.0) breakeven = sumLotPrice / totalLots;
  }
//+------------------------------------------------------------------+
double GetEAFloatingPL(int &positions)
  {
   double pl = 0.0;
   positions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      positions++;
     }
   return(pl);
  }
//+------------------------------------------------------------------+
void CloseSide(const ENUM_POSITION_TYPE side)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
      trade.PositionClose(ticket);
     }
  }
//+------------------------------------------------------------------+
void CloseAll()
  {
   CloseSide(POSITION_TYPE_BUY);
   CloseSide(POSITION_TYPE_SELL);
  }
//+------------------------------------------------------------------+
//| Manage one side. allowEntries gates NEW trades only (initial +   |
//| grid adds) so trend flips don't orphan an existing basket -- it  |
//| still gets tracked and closed at TP normally.                    |
//+------------------------------------------------------------------+
void ManageSide(const ENUM_POSITION_TYPE side, const double atr, const bool allowEntries)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   int count; double totalLots, breakeven, extremePrice, sideProfit;
   GetBasketInfo(side, count, totalLots, breakeven, extremePrice, sideProfit);

   //--- 1) no positions -> open initial trade (only if entries allowed)
   if(count == 0)
     {
      if(!g_halted && allowEntries)
        {
         double lot = NormalizeLot(InpInitialLot);
         if(side == POSITION_TYPE_BUY) trade.Buy(lot, _Symbol, 0, 0, 0, "grid init");
         else                          trade.Sell(lot, _Symbol, 0, 0, 0, "grid init");
        }
      return;
     }

   //--- 2) centralized TP (per-side modes only; global modes handled in OnTick)
   bool closeIt = false;
   switch(InpTPMode)
     {
      case TP_ATR_BASKET:
        {
         double dist = atr * InpTPValue;
         closeIt = (side == POSITION_TYPE_BUY) ? (bid >= breakeven + dist)
                                               : (ask <= breakeven - dist);
         break;
        }
      case TP_PIPS_BASKET:
        {
         double dist = InpTPValue * PipSize();
         closeIt = (side == POSITION_TYPE_BUY) ? (bid >= breakeven + dist)
                                               : (ask <= breakeven - dist);
         break;
        }
      case TP_MONEY_BASKET:
         closeIt = (sideProfit >= InpTPValue);
         break;
      default:
         break; // TP_MONEY_GLOBAL / TP_PERCENT_GLOBAL handled globally
     }

   if(closeIt)
     {
      Print(side == POSITION_TYPE_BUY ? "BUY" : "SELL",
            " basket TP hit. Profit=", DoubleToString(sideProfit, 2),
            " BE=", DoubleToString(breakeven, _Digits), ". Closing side.");
      CloseSide(side);
      return;
     }

   //--- 3) add martingale grid level (only if entries allowed)
   if(g_halted || !allowEntries) return;
   if(InpMaxGridLevels > 0 && count >= InpMaxGridLevels) return;

   double gridDist = atr * InpGridATRMult;

   if(side == POSITION_TYPE_BUY)
     {
      if(ask <= extremePrice - gridDist)
        {
         double lot = NormalizeLot(InpInitialLot * MathPow(InpLotMultiplier, count));
         trade.Buy(lot, _Symbol, 0, 0, 0, "grid lvl " + IntegerToString(count + 1));
        }
     }
   else
     {
      if(bid >= extremePrice + gridDist)
        {
         double lot = NormalizeLot(InpInitialLot * MathPow(InpLotMultiplier, count));
         trade.Sell(lot, _Symbol, 0, 0, 0, "grid lvl " + IntegerToString(count + 1));
        }
     }
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   int eaPositions = 0;
   double floatPL = GetEAFloatingPL(eaPositions);

   //--- SL cut-off (% or $), same style as the new TP% mode below
   if(InpMaxLossMoney > 0 || InpMaxLossPct > 0)
     {
      double floatLoss = -floatPL;
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      bool hitMoney = (InpMaxLossMoney > 0 && floatLoss >= InpMaxLossMoney);
      bool hitPct   = (InpMaxLossPct > 0 && balance > 0 &&
                       floatLoss >= balance * InpMaxLossPct / 100.0);
      if(hitMoney || hitPct)
        {
         if(!g_halted)
           {
            Print("SL CUT-OFF HIT. Floating loss=", DoubleToString(floatLoss, 2),
                  " ", AccountInfoString(ACCOUNT_CURRENCY), ". Closing all.");
            g_halted = true;
           }
         CloseAll();
         return;
        }
      if(g_halted && eaPositions == 0)
        {
         Print("Flat after cut-off. Resuming.");
         g_halted = false;
        }
     }

   //--- Global TP (money or percent of balance -- same unit family as SL%)
   if(eaPositions > 0)
     {
      if(InpTPMode == TP_MONEY_GLOBAL && floatPL >= InpTPValue)
        {
         Print("GLOBAL TP HIT ($). Profit=", DoubleToString(floatPL, 2), ". Closing all.");
         CloseAll();
         return;
        }
      if(InpTPMode == TP_PERCENT_GLOBAL)
        {
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         if(balance > 0 && floatPL >= balance * InpTPValue / 100.0)
           {
            Print("GLOBAL TP HIT (%). Profit=", DoubleToString(floatPL, 2),
                  " (", DoubleToString(InpTPValue, 2), "% of balance). Closing all.");
            CloseAll();
            return;
           }
        }
     }

   double atr = GetATR();
   if(atr <= 0.0) return;

   //--- Trend filter: gate which side may open NEW trades
   int  trendDir = GetTrendDirection();   // 1 up, -1 down, 0 range/off
   bool allowBuyEntry, allowSellEntry;
   if(InpTrendMode == TREND_FOLLOW)
     {
      // buy with uptrend/range, sell with downtrend/range
      allowBuyEntry  = InpTradeBuy  && (trendDir >= 0);
      allowSellEntry = InpTradeSell && (trendDir <= 0);
     }
   else // TREND_REVERSAL: fade the trend
     {
      // buy in a downtrend (expecting bounce), sell in an uptrend (expecting pullback)
      allowBuyEntry  = InpTradeBuy  && (trendDir <= 0);
      allowSellEntry = InpTradeSell && (trendDir >= 0);
     }

   ManageSide(POSITION_TYPE_BUY,  atr, allowBuyEntry);
   ManageSide(POSITION_TYPE_SELL, atr, allowSellEntry);
  }
//+------------------------------------------------------------------+