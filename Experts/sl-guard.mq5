//+------------------------------------------------------------------+
//|                                                     sl-guard.mq5  |
//|   Manual-trade SL/TP/trail helper. You place ALL orders yourself  |
//|   (buy limit, sell limit, market, however) — this EA never opens  |
//|   a trade. It only watches positions with magic ManageMagicNumber |
//|   (0 = manual) on its chart's symbol, and manages each one        |
//|   INDEPENDENTLY — no grid, no basket averaging, no interaction    |
//|   between positions:                                              |
//|                                                                   |
//|    1. Hard broker SL/TP: fixed pip cap from THAT position's own   |
//|       entry, set once when first seen — fills in whichever of     |
//|       SL/TP is still 0, never overwrites a line already set.      |
//|    2. Virtual MA exit: watched tick-by-tick, never written to     |
//|       the broker. Closes the position when price breaks the MA    |
//|       by MAExitBufferPips — buys below MA-buffer, sells above     |
//|       MA+buffer.                                                  |
//|    3. Virtual profit trail: per position, arms once ITS OWN       |
//|       profit reaches TrailStartPips, then closes it if it gives   |
//|       back TrailGivebackPips from its own peak.                   |
//|                                                                   |
//|   Whichever of the three fires first for a given position closes  |
//|   just THAT position — every other open position is untouched.    |
//|                                                                   |
//|   TEST ON DEMO FIRST.                                             |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//====================== INPUTS ======================
input group "===== Timeframe ====="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M2; // Timeframe the MA is read on

input group "===== Moving Average ====="
input ENUM_MA_METHOD     MA_Method       = MODE_EMA;         // MA type: SMA / EMA / SMMA / LWMA
input int                MA_Period       = 34;               // MA period
input int                MA_Shift        = 0;                // MA horizontal shift
input ENUM_APPLIED_PRICE MA_AppliedPrice = PRICE_CLOSE;      // Applied price

input group "===== Hard SL / TP (broker lines, per position, set once) ====="
input int MaxStopLossPips = 300;   // Hard SL cap in pips from THIS position's own entry (0 = never set one)
input int TakeProfitPips  = 3000;  // Hard TP in pips from THIS position's own entry (0 = never set one)

input group "===== Virtual MA Exit (never sent to broker) ====="
input double MAExitBufferPips = 100; // Room BEYOND the MA before closing (0 = exit at MA touch)

input group "===== Virtual Profit Trail (per position) ====="
input bool   UseTrail          = true; // Arm+trail each position's own profit in pips
input double TrailStartPips    = 200;  // Arm the trail once THIS position's own profit >= this
input double TrailGivebackPips = 50;   // Close THIS position if it gives back this many pips from its own peak

input group "===== Management ====="
input long ManageMagicNumber     = 0;    // Only positions with this magic are managed (0 = manual trades)
input int  SlippagePoints        = 20;   // Max deviation for market closes (points)
input int  MaxStaleTickSeconds   = 120;  // No modify/close attempts if no tick for this long (0 = ignore)
input int  OrderRetryCooldownSec = 60;   // After a failed modify/close, wait before retrying
input bool UseBrokerSessionGuard = true; // Respect broker symbol trade sessions (holidays, early close)

input group "===== Modify Retry ====="
input int ModifyRetryMax                = 3;    // Modify retry max (attempts per burst)
input int ModifyRetryDelayMs            = 500;  // Modify retry delay ms (between attempts)
input int MaxConsecutiveRetryCooldownMs = 2000; // Max consecutive retry cooldown ms (between failed bursts)

//====================== PER-POSITION STATE ======================
struct ManagedPos
{
   ulong  ticket;
   bool   hardLinesSet;       // whichever of SL/TP was missing has been filled at least once
   bool   modifyPending;      // a hard-line modify is queued but not yet confirmed by the broker
   double pendingSL;
   double pendingTP;
   ulong  lastModifyBurstMs;
   bool   trailArmed;
   double trailPeak;
};
ManagedPos g_pos[];

//====================== GLOBALS ======================
ENUM_TIMEFRAMES g_tf;
int      g_ma  = INVALID_HANDLE;
double   g_pip = 0;

datetime g_lastCloseFailTime = 0;
datetime g_lastGuardLogTime  = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;

   g_ma = iMA(_Symbol, g_tf, MathMax(1, MA_Period), MA_Shift, MA_Method, MA_AppliedPrice);
   if(g_ma == INVALID_HANDLE)
   { Print("EA error: failed to create MA handle."); return(INIT_FAILED); }

   g_pip = PipSize();

   trade.SetDeviationInPoints(SlippagePoints);

   if(_Period != g_tf)
      Print("Note: chart TF differs from the MA read TF (", EnumToString(g_tf), ").");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_ma != INVALID_HANDLE) IndicatorRelease(g_ma);
}

//+------------------------------------------------------------------+
void OnTick()
{
   PruneClosedPositions();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != ManageMagicNumber) continue;

      ManagePosition(tk);
   }
}

//====================== PER-POSITION STATE HELPERS ======================
int FindPos(const ulong ticket)
{
   for(int i = 0; i < ArraySize(g_pos); i++)
      if(g_pos[i].ticket == ticket) return i;
   return -1;
}

int GetOrAddPos(const ulong ticket)
{
   int idx = FindPos(ticket);
   if(idx >= 0) return idx;

   idx = ArraySize(g_pos);
   ArrayResize(g_pos, idx + 1);
   g_pos[idx].ticket            = ticket;
   g_pos[idx].hardLinesSet      = false;
   g_pos[idx].modifyPending     = false;
   g_pos[idx].pendingSL         = 0;
   g_pos[idx].pendingTP         = 0;
   g_pos[idx].lastModifyBurstMs = 0;
   g_pos[idx].trailArmed        = false;
   g_pos[idx].trailPeak         = 0;
   return idx;
}

// Drop state for tickets that are no longer open — closed by the hard SL,
// hard TP, virtual MA exit, virtual trail, or you closing it by hand.
void PruneClosedPositions()
{
   for(int i = ArraySize(g_pos) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(g_pos[i].ticket))
      {
         int last = ArraySize(g_pos) - 1;
         g_pos[i] = g_pos[last];
         ArrayResize(g_pos, last);
      }
   }
}

//====================== PER-POSITION MANAGEMENT ======================
void ManagePosition(const ulong ticket)
{
   int idx = GetOrAddPos(ticket);

   EnsureHardLines(idx, ticket);
   if(CheckVirtualMAExit(ticket)) return;   // position closed — nothing else to do this tick
   CheckTrail(idx, ticket);
}

//====================== HARD SL/TP (fixed cap, THIS position's own entry) ======================
// Set ONCE per position: fills in whichever of SL/TP is still 0 when first
// seen, then never touched again — unlike a grid basket, a single manual
// position's entry never moves, so there is nothing to ratchet afterward.
void EnsureHardLines(const int idx, const ulong ticket)
{
   if(g_pos[idx].hardLinesSet) return;

   if(g_pos[idx].modifyPending)
   {
      if(GetTickCount64() - g_pos[idx].lastModifyBurstMs < (ulong)MathMax(0, MaxConsecutiveRetryCooldownMs))
         return;
      RetryHardLines(idx, ticket);
      return;
   }

   if(!PositionSelectByTicket(ticket)) return;

   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double sl = curSL, tp = curTP;

   if(isBuy)
   {
      if(sl == 0 && MaxStopLossPips > 0)
      { sl = entry - MaxStopLossPips * g_pip; if(bid - sl < minStop) sl = bid - minStop; }
      if(tp == 0 && TakeProfitPips > 0)
      { tp = entry + TakeProfitPips * g_pip; if(tp - ask < minStop) tp = ask + minStop; }
   }
   else
   {
      if(sl == 0 && MaxStopLossPips > 0)
      { sl = entry + MaxStopLossPips * g_pip; if(sl - ask < minStop) sl = ask + minStop; }
      if(tp == 0 && TakeProfitPips > 0)
      { tp = entry - TakeProfitPips * g_pip; if(bid - tp < minStop) tp = bid - minStop; }
   }

   if(sl == curSL && tp == curTP) { g_pos[idx].hardLinesSet = true; return; } // nothing missing to fill

   g_pos[idx].pendingSL     = NormalizePrice(sl);
   g_pos[idx].pendingTP     = (tp > 0) ? NormalizePrice(tp) : 0.0;
   g_pos[idx].modifyPending = true;
   RetryHardLines(idx, ticket);
}

void RetryHardLines(const int idx, const ulong ticket)
{
   if(!CanAttemptTradeAction()) return;

   if(ModifyTicketWithRetry(ticket, g_pos[idx].pendingSL, g_pos[idx].pendingTP))
   {
      g_pos[idx].modifyPending = false;
      g_pos[idx].hardLinesSet  = true;
   }
   else
      g_pos[idx].lastModifyBurstMs = GetTickCount64();
}

//====================== VIRTUAL MA EXIT (never sent to broker) ======================
bool GetMAExitAnchor(const bool isBuy, double &anchor)
{
   anchor = 0;
   if(g_ma == INVALID_HANDLE) return false;

   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(g_ma, 0, 0, 1, m) != 1) return false;

   double buffer = MathMax(0.0, MAExitBufferPips) * g_pip;
   anchor = isBuy ? (m[0] - buffer) : (m[0] + buffer);
   return true;
}

// Returns true if the position was closed this call.
bool CheckVirtualMAExit(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;

   bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double anchor;
   if(!GetMAExitAnchor(isBuy, anchor)) return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool breached = isBuy ? (bid <= anchor) : (ask >= anchor);
   if(!breached) return false;

   Print("Virtual MA exit hit on #", IntegerToString((long)ticket), ": ",
         (isBuy ? "bid " + DoubleToString(bid, _Digits) + " <= " : "ask " + DoubleToString(ask, _Digits) + " >= "),
         DoubleToString(anchor, _Digits));
   return ClosePosition(ticket);
}

//====================== VIRTUAL PROFIT TRAIL (per position) ======================
void CheckTrail(const int idx, const ulong ticket)
{
   if(!UseTrail) return;
   if(!PositionSelectByTicket(ticket)) return;

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double pips = isBuy ? (bid - entry) / g_pip : (entry - ask) / g_pip;

   if(!g_pos[idx].trailArmed)
   {
      if(pips >= TrailStartPips) { g_pos[idx].trailArmed = true; g_pos[idx].trailPeak = pips; }
      return;
   }

   if(pips > g_pos[idx].trailPeak) g_pos[idx].trailPeak = pips;
   if(g_pos[idx].trailPeak - pips >= TrailGivebackPips)
   {
      Print("Virtual trail hit on #", IntegerToString((long)ticket), ": peak ",
            DoubleToString(g_pos[idx].trailPeak, 1), " pips, now ", DoubleToString(pips, 1),
            " pips — gave back ", DoubleToString(g_pos[idx].trailPeak - pips, 1));
      ClosePosition(ticket);
   }
}

//====================== MARKET GUARD ======================
void LogGuardOnce(const string msg)
{
   if(TimeCurrent() - g_lastGuardLogTime < 300) return;
   g_lastGuardLogTime = TimeCurrent();
   Print(msg);
}

bool IsExpertTradingEnabled()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return false;
   return true;
}

bool IsTickFresh()
{
   if(MaxStaleTickSeconds <= 0) return true;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   if(tick.bid <= 0.0 || tick.ask <= 0.0) return false;
   return ((TimeCurrent() - tick.time) <= MaxStaleTickSeconds);
}

bool IsBrokerTradeSessionOpen()
{
   if(!UseBrokerSessionGuard) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowSec = dt.hour * 3600 + dt.min * 60 + dt.sec;

   datetime from = 0, to = 0;
   bool found = false;
   for(uint ses = 0; ses < 16; ses++)
   {
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, ses, from, to))
         break;
      found = true;
      if(nowSec >= (int)from && nowSec < (int)to)
         return true;
   }
   return !found;   // no published sessions -> don't block (use stale-tick guard)
}

bool CanAttemptTradeAction()
{
   if(OrderRetryCooldownSec > 0 && (TimeCurrent() - g_lastCloseFailTime) < OrderRetryCooldownSec)
      return false;

   if(!IsExpertTradingEnabled()) return false;

   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED) return false;

   if(!IsBrokerTradeSessionOpen())
   {
      LogGuardOnce("Market guard: broker trade session closed for " + _Symbol);
      return false;
   }
   if(!IsTickFresh())
   {
      LogGuardOnce("Market guard: no fresh ticks for " + IntegerToString(MaxStaleTickSeconds) + "s on " + _Symbol);
      return false;
   }
   return true;
}

//====================== HELPERS ======================
bool ClosePosition(const ulong ticket)
{
   if(!CanAttemptTradeAction()) return false;

   if(!trade.PositionClose(ticket))
   {
      g_lastCloseFailTime = TimeCurrent();
      LogGuardOnce("Close failed on #" + IntegerToString((long)ticket) + " rc=" +
                   IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

// transient = worth an immediate retry burst; fatal = burst is pointless,
// but the pending flag stays so we re-attempt after the cooldown
bool IsTransientRetcode(const uint rc)
{
   return (rc == TRADE_RETCODE_REQUOTE           ||   // 10004
           rc == TRADE_RETCODE_TIMEOUT           ||   // 10012
           rc == TRADE_RETCODE_PRICE_CHANGED     ||   // 10020
           rc == TRADE_RETCODE_PRICE_OFF         ||   // 10021
           rc == TRADE_RETCODE_TOO_MANY_REQUESTS ||   // 10024
           rc == TRADE_RETCODE_CONNECTION);           // 10031
}

// one ticket, one burst: up to ModifyRetryMax attempts, ModifyRetryDelayMs apart
bool ModifyTicketWithRetry(const ulong ticket, const double sl, const double tp)
{
   int maxTry = MathMax(1, ModifyRetryMax);
   for(int attempt = 1; attempt <= maxTry; attempt++)
   {
      if(trade.PositionModify(ticket, sl, tp)) return true;

      uint rc = trade.ResultRetcode();
      if(!IsTransientRetcode(rc))
      {
         LogGuardOnce("SL/TP modify failed (fatal) on #" + IntegerToString((long)ticket) + " rc=" +
                      IntegerToString(rc) + " " + trade.ResultRetcodeDescription() + " — will re-attempt after cooldown");
         return false;
      }
      if(attempt < maxTry && ModifyRetryDelayMs > 0)
         Sleep(ModifyRetryDelayMs);
   }
   LogGuardOnce("SL/TP modify failed after " + IntegerToString(maxTry) + " tries on #" + IntegerToString((long)ticket) +
                " rc=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
   return false;
}

double PipSize()
{
   int    d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (d == 3 || d == 5) ? p * 10.0 : p;
}

double NormalizePrice(double p)
{
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}
//+------------------------------------------------------------------+
