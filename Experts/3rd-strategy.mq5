//+------------------------------------------------------------------+
//|                                                3rd-strategy.mq5   |
//|   Dual-TF Support/Resistance grid EA. NEW file — does NOT modify  |
//|   2nd-strategy.mq5. Skeleton (grid layering, basket SL/TP, session |
//|   filter, market guard, retry, MA filter, virtual MA SL) forked   |
//|   from 2nd-strategy; ONLY the entry signal engine is different.   |
//|                                                                   |
//|   Entry (evaluated once per closed bar on InpEntryTF, default M5):|
//|    - Levels TF (default H1): pivot S/R like sr-breaks — latest    |
//|      confirmed pivot high = resistance, pivot low = support.      |
//|    - Entry TF: price action vs those levels.                      |
//|    - Mode BOUNCE (default): wick into S/R + close back through     |
//|      the level (rejection).                                       |
//|    - Mode BREAK_RETEST: recent close broke the level, then a       |
//|      pullback touches it from the break side and rejects.         |
//|    - Optional HTF MA bias: buys only if HTF close above MA, etc.   |
//|    - Optional entry-TF MA filter (same live gate as 2nd-strategy). |
//|    - Signal recomputed fresh every entry-TF bar (no memory).       |
//|                                                                   |
//|   TEST ON DEMO / STRATEGY TESTER FIRST. Not a profit guarantee.   |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "1.00"
// v1.00: First release. H1 S/R + M5 bounce/break-retest entry.

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_LABEL "3rd-strategy"

//====================== INPUTS ======================
input group "===== Timeframes (dual) ====="
input ENUM_TIMEFRAMES InpEntryTF  = PERIOD_M2; // Entry TF (signal + MA filter / trades gate on THIS)
input ENUM_TIMEFRAMES InpLevelsTF = PERIOD_M15;// Levels TF (support / resistance pivots)

input group "===== S/R Entry Mode ====="
enum ENUM_SR_MODE
{
   SR_BOUNCE,       // Bounce: wick into level + close reject back
   SR_BREAK_RETEST  // Break + retest: recent break, then touch + reject
};
input ENUM_SR_MODE SrMode         = SR_BREAK_RETEST; // Entry style
input int          PivotLeftBars  = 5;         // Pivot left bars (levels TF)
input int          PivotRightBars = 5;         // Pivot right bars (levels TF)
input int          LevelsLookback = 200;       // Bars to scan for pivots on levels TF
input double       TouchPips      = 50;        // How close price must get to the level (pips)
input bool         RequireRejectCandle = true; // Bounce/retest candle must be bullish(buy)/bearish(sell)
input int          BreakLookbackBars   = 12;   // BREAK_RETEST: bars to search for the break (entry TF)

input group "===== HTF MA Bias (levels TF) ====="
input bool               UseHtfMaBias     = true;             // Require HTF close on correct side of MA
input ENUM_MA_METHOD     HtfMA_Method     = MODE_EMA;         // HTF MA type
input int                HtfMA_Period     = 55;               // HTF MA period
input ENUM_APPLIED_PRICE HtfMA_Price      = PRICE_CLOSE;      // HTF MA applied price

input group "===== Moving Average Filter (entry TF) ====="
enum ENUM_MA_CHECK
{
   MA_CHECK_RUNNING,      // Running: live price vs MA right now (+/- buffer)
   MA_CHECK_CANDLE_CLOSE  // Candle close: last close must confirm too (tighter)
};
input bool               UseMAFilter     = true;             // Enable MA direction filter
input ENUM_MA_CHECK      MACheckMode     = MA_CHECK_RUNNING; // Running or candle-close (tighter)
input ENUM_MA_METHOD     MA_Method       = MODE_EMA;         // MA type: SMA / EMA / SMMA / LWMA
input int                MA_Period       = 34;               // MA period
input int                MA_Shift        = 0;                // MA horizontal shift
input ENUM_APPLIED_PRICE MA_AppliedPrice = PRICE_CLOSE;      // Applied price
input double             MABufferPips    = 100;              // Price must clear the MA by this many pips (0 = plain cross)
// Rule (BOTH modes): live price NOW must be above MA+buffer for BUYS,
// below MA-buffer for SELLS — an entry can never sit on the wrong side of
// the MA you see on the chart.
// CANDLE_CLOSE adds: the last finished candle must ALSO have closed on the
// correct side (+/- buffer) — tighter, skips the first spike across the MA.

input group "===== Stop Loss Type ====="
enum ENUM_SL_TYPE
{
   SL_FIXED,      // Fixed only: broker pip-cap SL, no MA exit
   SL_MA_VIRTUAL  // Fixed cap on broker + VIRTUAL MA exit watched by the EA
};
input ENUM_SL_TYPE SLType         = SL_MA_VIRTUAL; // SL type: fixed only, or fixed + virtual MA exit
input double       SLMABufferPips = 50;            // Virtual MA exit: room BEYOND the MA before closing (0 = exit at MA touch)
// SL_MA_VIRTUAL uses the SAME MA as the entry filter above (period/method/price).
// The BROKER SL line stays the fixed pip cap in BOTH modes — that is the
// backup if the terminal/EA is offline, same idea as the basket pip trail.
// The MA exit is VIRTUAL: watched tick-by-tick by the EA, never written to
// the broker. BUY basket closes when bid <= MA - buffer; SELL basket closes
// when ask >= MA + buffer. Buffer = breathing room past the MA, so a wick
// through the line doesn't shake the basket out.

input group "===== Orders / Risk (BASKET lines: shared SL/TP, tighter-only) ====="
input double LotSize         = 0.01;  // Lots per layer
input int    MaxStopLossPips = 300;   // SL cap in pips from AVG entry
input int    TakeProfitPips  = 3000;  // Basket TP: avg entry +/- this many pips (0 = no TP line)
input int    MaxSpreadPips   = 0;     // Skip new entries above this spread (0 = ignore)
input int    SlippagePoints  = 20;    // Max deviation for market orders (points)
input long   MagicNumber     = 333;   // EA id (different from 2nd-strategy)

input group "===== Grid Layering ====="
input int    MaxLayers       = 1;     // Max simultaneous positions this EA owns (1 = safer on M5)
input int    LayerStepPips   = 200;   // Price must push this many pips DEEPER before adding a layer

input group "===== Basket Take-Profit (pips, trailing) ====="
input bool   UseBasketTP         = true; // Manage profit as a basket in pips (works alongside per-layer TP)
input double BasketStartPips     = 200;  // Arm the basket trail once total pips >= this
input double BasketGivebackPips  = 50;   // Close ALL layers if basket falls this many pips from its peak

input group "===== Session Filter (WIB / Jakarta time) ====="
input int  SessionTZOffset       = 7;    // UTC offset for inputs below (7 = WIB Jakarta)
input bool UseSession            = true; // Enable daily trading-hours window
input int  SessionStartHour      = 6;    // Daily window FROM this hour WIB (0-23)
input int  SessionEndHour        = 3;    // NO new entries from this hour WIB (crosses midnight: 6→3)
input bool CloseAtSessionEnd     = true; // Flatten when outside the daily window (e.g. at 03:00)
input bool UseWeekendFilter      = true; // Block weekend gap (WIB)
input int  WeekendStopDayWIB     = 6;    // Weekend starts this day (0=Sun … 5=Fri 6=Sat)
input int  WeekendStopHourWIB    = 3;    // …from this hour (Sat 03:00 = after last Fri session)
input int  WeekendStartDayWIB    = 1;    // Weekend ends this day (1=Mon)
input int  WeekendStartHourWIB   = 6;    // …resume from this hour (Mon 06:00)
input bool CloseAtWeekend        = true; // Flatten when the weekend block starts

input group "===== News Filter (economic calendar) ====="
input bool   UseNewsFilter        = true;                                              // Block/flatten around economic news
input ENUM_CALENDAR_EVENT_IMPORTANCE NewsMinImportance = CALENDAR_IMPORTANCE_MODERATE;  // Minimum importance to react to
input string NewsCurrency         = "USD";                                             // Currency to watch (USD for XAUUSD)
input int    NewsMinutesBefore    = 15;                                                // Stop entries this long before the event
input int    NewsMinutesAfter     = 15;                                                // Resume this long after the event
input bool   CloseAtNews          = true;                                              // Flatten when the news blackout starts

input group "===== Market Guard (holidays / early close) ====="
input bool UseBrokerSessionGuard = true; // Respect broker symbol trade sessions (Jul 4, etc.)
input int  MaxStaleTickSeconds   = 120;  // No new trades if no tick for this long (0 = ignore)
input int  OrderRetryCooldownSec = 60;   // After a failed order/close, wait before retrying

input group "===== Basket SL/TP Modify Retry ====="
input int ModifyRetryMax                = 3;    // Modify retry max (attempts per burst)
input int ModifyRetryDelayMs            = 500;  // Modify retry delay ms (between attempts)
input int MaxConsecutiveRetryCooldownMs = 2000; // Max consecutive retry cooldown ms (between failed bursts)

//====================== GLOBALS ======================
ENUM_TIMEFRAMES g_entryTF;
ENUM_TIMEFRAMES g_levelsTF;
int      g_ma    = INVALID_HANDLE; // entry-TF MA (filter + virtual SL)
int      g_htfMa = INVALID_HANDLE; // levels-TF MA bias
double   g_pip = 0;
datetime g_lastBarTime  = 0;
datetime g_lastEntryBar = 0;

// current entry signal (recomputed fresh every closed bar, no memory carryover)
bool   g_haveSignal  = false;
bool   g_signalIsBuy = false;

// basket trail state (VIRTUAL — never written to broker)
bool   g_basketArmed = false;
double g_basketPeak  = 0;

// basket SL/TP lines (BROKER — shared by all layers, ratchet tighter-only)
double g_basketSL = 0;   // 0 = not set yet
double g_basketTP = 0;   // 0 = not set / TakeProfitPips disabled

// trade guard state (anti-spam on market closed / holidays)
datetime g_lastEntryFailTime = 0;
datetime g_lastCloseFailTime  = 0;
datetime g_lastGuardLogTime   = 0;

// news filter state (cached calendar lookup, refreshed every 60s)
bool  g_newsBlackoutCached = false;
ulong g_newsLastCheckMs    = 0;

// pending basket SL/TP modify (broker has NOT accepted these yet — keep
// re-attempting every MaxConsecutiveRetryCooldownMs until every ticket takes them)
bool   g_modifyPending     = false;
double g_pendingSL         = 0;
double g_pendingTP         = 0;
ulong  g_lastModifyBurstMs = 0;   // GetTickCount64() of last failed burst

// entry diagnostics: one reason per bar, only when a fresh signal fires
datetime g_lastDiagBar = 0;

//====================== PUSH NOTIFICATIONS ======================
string Tag() { return EA_LABEL + " #" + IntegerToString(MagicNumber) + " " + _Symbol; }
void LogInfo(const string msg) { Print(Tag(), " | ", msg); }

void NotifyPush(const string msg)
{
   if(!SendNotification(msg))
      LogInfo("PUSH FAILED - " + msg);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_entryTF  = (InpEntryTF  == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpEntryTF;
   g_levelsTF = (InpLevelsTF == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpLevelsTF;

   if(MaxLayers < 1)
   {
      LogInfo("INIT FAILED - MaxLayers must be >= 1");
      NotifyPush(Tag() + ": INIT FAILED - MaxLayers must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(PivotLeftBars < 1 || PivotRightBars < 1)
   {
      LogInfo("INIT FAILED - PivotLeftBars/PivotRightBars must be >= 1");
      NotifyPush(Tag() + ": INIT FAILED - PivotLeftBars/PivotRightBars must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(PeriodSeconds(g_levelsTF) <= PeriodSeconds(g_entryTF))
      Print(Tag(), " | NOTE Levels TF should be higher than Entry TF for dual-TF design (currently ",
            EnumToString(g_levelsTF), " / ", EnumToString(g_entryTF), ").");

   // Entry-TF MA: filter and/or virtual MA SL
   if(UseMAFilter || SLType == SL_MA_VIRTUAL)
   {
      g_ma = iMA(_Symbol, g_entryTF, MathMax(1, MA_Period), MA_Shift, MA_Method, MA_AppliedPrice);
      if(g_ma == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - entry-TF MA handle");
         NotifyPush(Tag() + ": INIT FAILED - entry-TF MA handle");
         return(INIT_FAILED);
      }
   }

   if(UseHtfMaBias)
   {
      g_htfMa = iMA(_Symbol, g_levelsTF, MathMax(1, HtfMA_Period), 0, HtfMA_Method, HtfMA_Price);
      if(g_htfMa == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - HTF MA handle");
         NotifyPush(Tag() + ": INIT FAILED - HTF MA handle");
         return(INIT_FAILED);
      }
   }

   g_pip = PipSize();

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(_Period != g_entryTF)
      Print(Tag(), " | NOTE chart TF differs from entry TF (", EnumToString(g_entryTF),
            "). Signal runs on entry TF. Levels on ", EnumToString(g_levelsTF), ".");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_ma    != INVALID_HANDLE) IndicatorRelease(g_ma);
   if(g_htfMa != INVALID_HANDLE) IndicatorRelease(g_htfMa);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // --- refresh the signal once per entry-TF bar (no intrabar repaint) ---
   datetime bt[];
   if(CopyTime(_Symbol, g_entryTF, 0, 1, bt) == 1 && bt[0] != g_lastBarTime)
   {
      g_lastBarTime = bt[0];
      UpdateSignal();
   }

   // --- outside session/weekend: optionally flatten + stop ---
   if(ShouldCloseForSchedule())
   {
      CloseAllEA("session/weekend schedule");
      return;
   }

   // --- pending basket SL/TP modify: keep pushing until broker accepts ---
   if(g_modifyPending &&
      GetTickCount64() - g_lastModifyBurstMs >= (ulong)MathMax(0, MaxConsecutiveRetryCooldownMs))
      ProcessBasketModify();

   // --- basket profit management runs whenever positions are open ---
   ManageBasket();

   // --- virtual MA SL: close the basket if price breaks the MA (EA-side) ---
   CheckVirtualMASL();

   // --- entries ---
   if(!g_haveSignal) return;
   if(!InSession()) return;
   TryEnter();
}

//====================== SESSION (WIB inputs, broker clock) ======================
void GetWIBTime(MqlDateTime &dt)
{
   TimeToStruct(TimeCurrent() + SessionTZOffset * 3600, dt);
}

bool InWeekendBlock()
{
   if(!UseWeekendFilter) return false;

   MqlDateTime dt;
   GetWIBTime(dt);

   int stopDow  = MathMax(0, MathMin(6, WeekendStopDayWIB));
   int stopHr   = MathMax(0, MathMin(23, WeekendStopHourWIB));
   int startDow = MathMax(0, MathMin(6, WeekendStartDayWIB));
   int startHr  = MathMax(0, MathMin(23, WeekendStartHourWIB));

   int nowMin   = dt.day_of_week * 1440 + dt.hour * 60 + dt.min;
   int stopMin  = stopDow * 1440 + stopHr * 60;
   int startMin = startDow * 1440 + startHr * 60;

   if(stopMin == startMin) return false;
   if(stopMin < startMin)
      return (nowMin >= stopMin && nowMin < startMin);
   return (nowMin >= stopMin || nowMin < startMin);   // e.g. Sat 03:00 → Mon 06:00
}

bool ComputeNewsBlackout()
{
   datetime now  = TimeCurrent();
   datetime from = now - NewsMinutesAfter * 60;
   datetime to   = now + NewsMinutesBefore * 60;

   MqlCalendarValue values[];
   if(CalendarValueHistory(values, from, to, NULL, NewsCurrency) <= 0)
      return false;

   for(int i = 0; i < ArraySize(values); i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance < NewsMinImportance) continue;

      datetime t = values[i].time;
      if(now >= t - NewsMinutesBefore * 60 && now <= t + NewsMinutesAfter * 60)
         return true;
   }
   return false;
}

bool InNewsBlackout()
{
   if(!UseNewsFilter) return false;

   ulong nowMs = GetTickCount64();
   if(nowMs - g_newsLastCheckMs >= 60000)
   {
      g_newsLastCheckMs    = nowMs;
      g_newsBlackoutCached = ComputeNewsBlackout();
   }
   return g_newsBlackoutCached;
}

bool InDailySession()
{
   if(!UseSession) return true;

   int s = MathMax(0, MathMin(23, SessionStartHour));
   int e = MathMax(1, MathMin(24, SessionEndHour));   // end is exclusive
   if(s == e) return false;

   MqlDateTime dt;
   GetWIBTime(dt);
   int h = dt.hour;

   if(s < e) return (h >= s && h < e);   // same-day window
   return (h >= s || h < e);             // window crosses midnight
}

bool InSession()
{
   if(InWeekendBlock()) return false;
   if(InNewsBlackout()) return false;
   return InDailySession();
}

bool ShouldCloseForSchedule()
{
   if(UseWeekendFilter && CloseAtWeekend && InWeekendBlock()) return true;
   if(UseSession && CloseAtSessionEnd && !InDailySession()) return true;
   if(UseNewsFilter && CloseAtNews && InNewsBlackout()) return true;
   return false;
}

//====================== SIGNAL ENGINE (HTF S/R + entry-TF PA) ======================
// Recomputed fresh every closed ENTRY-TF bar. Pivot S/R from levels TF
// (same pivot idea as sr-breaks). No Stoch/RSI/MACD — different from 2nd-strategy.

bool IsPivotHighAt_Rates(const MqlRates &rates[], int idx, int total, int leftBars, int rightBars)
{
   if(idx - leftBars < 0 || idx + rightBars >= total) return false;
   double val = rates[idx].high;
   for(int j = idx - leftBars; j <= idx + rightBars; j++)
   {
      if(j == idx) continue;
      if(rates[j].high >= val) return false;
   }
   return true;
}

bool IsPivotLowAt_Rates(const MqlRates &rates[], int idx, int total, int leftBars, int rightBars)
{
   if(idx - leftBars < 0 || idx + rightBars >= total) return false;
   double val = rates[idx].low;
   for(int j = idx - leftBars; j <= idx + rightBars; j++)
   {
      if(j == idx) continue;
      if(rates[j].low <= val) return false;
   }
   return true;
}

// Latest confirmed pivot high/low on levels TF (index 0 = oldest).
bool GetActiveSR(double &support, double &resistance)
{
   support = 0; resistance = 0;

   int need = MathMax(LevelsLookback, PivotLeftBars + PivotRightBars + 5);
   MqlRates rates[];
   int got = CopyRates(_Symbol, g_levelsTF, 0, need, rates);
   if(got < PivotLeftBars + PivotRightBars + 3) return false;

   int total = got;
   int lastCompleted = total - 2; // exclude forming bar
   int startBar = MathMax(PivotLeftBars, total - LevelsLookback);

   double curHigh = EMPTY_VALUE;
   double curLow  = EMPTY_VALUE;

   for(int i = startBar; i <= lastCompleted; i++)
   {
      int pivotIdx = i - PivotRightBars;
      if(pivotIdx < PivotLeftBars) continue;
      if(pivotIdx + PivotRightBars > lastCompleted) continue; // not fully confirmed

      if(IsPivotHighAt_Rates(rates, pivotIdx, total, PivotLeftBars, PivotRightBars))
         curHigh = rates[pivotIdx].high;
      if(IsPivotLowAt_Rates(rates, pivotIdx, total, PivotLeftBars, PivotRightBars))
         curLow = rates[pivotIdx].low;
   }

   if(curHigh == EMPTY_VALUE || curLow == EMPTY_VALUE) return false;
   resistance = curHigh;
   support    = curLow;
   return true;
}

bool PassesHtfMaBias(const bool wantBuy)
{
   if(!UseHtfMaBias) return true;
   if(g_htfMa == INVALID_HANDLE) return false;

   double m[], c[];
   ArraySetAsSeries(m, true);
   ArraySetAsSeries(c, true);
   if(CopyBuffer(g_htfMa, 0, 1, 1, m) != 1) return false; // last CLOSED HTF MA
   if(CopyClose(_Symbol, g_levelsTF, 1, 1, c) != 1) return false;

   if(wantBuy) return (c[0] > m[0]);
   return (c[0] < m[0]);
}

// Recent break of level on entry TF (closed bars only). Series index 0 = forming.
bool HadRecentBreakUp(const double &close[], int barsAvailable, double level, int lookback)
{
   int lb = MathMax(2, lookback);
   for(int i = 2; i <= lb + 1; i++)
   {
      if(i >= barsAvailable) break;
      // close crossed above level between bar i and bar i-1 (both closed / older)
      if(close[i] <= level && close[i - 1] > level)
         return true;
   }
   return false;
}

bool HadRecentBreakDown(const double &close[], int barsAvailable, double level, int lookback)
{
   int lb = MathMax(2, lookback);
   for(int i = 2; i <= lb + 1; i++)
   {
      if(i >= barsAvailable) break;
      if(close[i] >= level && close[i - 1] < level)
         return true;
   }
   return false;
}

void UpdateSignal()
{
   g_haveSignal  = false;
   g_signalIsBuy = false;

   double support = 0, resistance = 0;
   if(!GetActiveSR(support, resistance)) return;
   if(support <= 0 || resistance <= 0 || support >= resistance) return;

   double touch = MathMax(0.0, TouchPips) * g_pip;

   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);

   int need = MathMax(BreakLookbackBars + 4, 6);
   if(CopyOpen (_Symbol, g_entryTF, 0, need, o) != need) return;
   if(CopyHigh (_Symbol, g_entryTF, 0, need, h) != need) return;
   if(CopyLow  (_Symbol, g_entryTF, 0, need, l) != need) return;
   if(CopyClose(_Symbol, g_entryTF, 0, need, c) != need) return;

   // index 1 = last CLOSED entry-TF bar
   double o1 = o[1], h1 = h[1], l1 = l[1], c1 = c[1];
   bool bullReject = (c1 > o1);
   bool bearReject = (c1 < o1);

   bool bounceBuy = false, bounceSell = false;
   bool retestBuy = false, retestSell = false;

   // --- BOUNCE: wick into level, close back on the trade side ---
   bounceBuy  = (l1 <= support + touch) && (c1 > support) &&
                (!RequireRejectCandle || bullReject);
   bounceSell = (h1 >= resistance - touch) && (c1 < resistance) &&
                (!RequireRejectCandle || bearReject);

   // --- BREAK + RETEST: recent break of that level, then touch + reject ---
   retestBuy  = HadRecentBreakUp(c, need, resistance, BreakLookbackBars) &&
                (l1 <= resistance + touch) && (c1 > resistance) &&
                (!RequireRejectCandle || bullReject);
   retestSell = HadRecentBreakDown(c, need, support, BreakLookbackBars) &&
                (h1 >= support - touch) && (c1 < support) &&
                (!RequireRejectCandle || bearReject);

   bool buyOK  = false;
   bool sellOK = false;
   if(SrMode == SR_BOUNCE)
   {
      buyOK  = bounceBuy;
      sellOK = bounceSell;
   }
   else
   {
      buyOK  = retestBuy;
      sellOK = retestSell;
   }

   if(buyOK && PassesHtfMaBias(true))
   { g_haveSignal = true; g_signalIsBuy = true; }
   else if(sellOK && PassesHtfMaBias(false))
   { g_haveSignal = true; g_signalIsBuy = false; }
}

//====================== ENTRY ======================
void DiagBlock(const string reason)
{
   // one line per bar, printed only when a fresh signal fired but the trade
   // was still blocked — the "everything lined up but no trade" case.
   if(g_lastDiagBar == g_lastBarTime) return;
   g_lastDiagBar = g_lastBarTime;
   Print(Tag(), " | BLOCKED ", reason,
         " | signal=", (g_signalIsBuy ? "BUY" : "SELL"));
}

void TryEnter()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(!CanAttemptEntry())
   { DiagBlock("trade path guard (terminal/broker session/stale tick/retry cooldown)"); return; }

   if(MaxSpreadPips > 0 && (ask - bid) / g_pip > MaxSpreadPips)
   { DiagBlock("spread " + DoubleToString((ask - bid) / g_pip, 1) + " > " + IntegerToString(MaxSpreadPips)); return; }

   if(!PassesMAFilter(g_signalIsBuy))
   { DiagBlock("MA filter"); return; }

   int    layers; double deepest; bool existingIsBuy;
   CountLayers(layers, deepest, existingIsBuy);

   if(layers >= MaxLayers)
   { DiagBlock("MaxLayers reached (" + IntegerToString(layers) + ")"); return; }

   if(layers > 0 && existingIsBuy != g_signalIsBuy)
   { DiagBlock("open layers are opposite direction"); return; }

   double px = g_signalIsBuy ? ask : bid;

   if(layers > 0)
   {
      double needed = LayerStepPips * g_pip;
      double gap    = g_signalIsBuy ? (deepest - px) : (px - deepest);
      if(gap < needed)
      { DiagBlock("layer step " + DoubleToString(gap / g_pip, 1) + " < " + IntegerToString(LayerStepPips) + " pips"); return; }
   }
   else
   {
      if(g_lastEntryBar == g_lastBarTime)
      { DiagBlock("one first-layer entry per bar"); return; }
      ResetBasketLines();   // fresh basket: never inherit lines from a previous one
   }

   OpenLayer(layers == 0);
}

//====================== MARKET GUARD ======================
void LogGuardOnce(const string msg)
{
   if(TimeCurrent() - g_lastGuardLogTime < 300) return;
   g_lastGuardLogTime = TimeCurrent();
   Print(Tag(), " | ", msg);
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

bool IsTradePathOpen(const bool forClose)
{
   if(!IsExpertTradingEnabled()) return false;

   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED) return false;
   if(!forClose && mode != SYMBOL_TRADE_MODE_FULL) return false;

   if(!IsBrokerTradeSessionOpen())
   {
      LogGuardOnce("GUARD broker trade session closed");
      return false;
   }
   if(!IsTickFresh())
   {
      LogGuardOnce("GUARD no fresh ticks for " + IntegerToString(MaxStaleTickSeconds) + "s");
      return false;
   }
   return true;
}

bool CanAttemptEntry()
{
   if(OrderRetryCooldownSec > 0 && (TimeCurrent() - g_lastEntryFailTime) < OrderRetryCooldownSec)
      return false;
   return IsTradePathOpen(false);
}

bool CanAttemptClose()
{
   if(OrderRetryCooldownSec > 0 && (TimeCurrent() - g_lastCloseFailTime) < OrderRetryCooldownSec)
      return false;
   return IsTradePathOpen(true);
}

bool HasEAPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber) return true;
   }
   return false;
}

void CountLayers(int &count, double &deepest, bool &existingIsBuy)
{
   count = 0; deepest = 0; existingIsBuy = g_signalIsBuy;
   bool first = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double e = PositionGetDouble(POSITION_PRICE_OPEN);
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      count++;
      if(first) { deepest = e; existingIsBuy = isBuy; first = false; }
      else
      {
         if(isBuy) deepest = MathMin(deepest, e); // deepest buy  = lowest entry
         else      deepest = MathMax(deepest, e); // deepest sell = highest entry
      }
   }
}

void OpenLayer(const bool isFirstLayer)
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double lots  = NormalizeLots(LotSize);
   if(lots <= 0) return;

   // Order is never sent naked: attach the existing basket lines if we have
   // them, otherwise a first-layer estimate. SyncBasketLines() recomputes the
   // exact levels from real fills right after and pushes them to all tickets.
   double sl = g_basketSL;
   double tp = g_basketTP;

   if(g_signalIsBuy)
   {
      if(sl <= 0)
         sl = ask - MaxStopLossPips * g_pip;             // broker line = fixed pip cap in BOTH SL types
      if(ask - sl < minStop) sl = ask - minStop;
      if(tp <= 0 && TakeProfitPips > 0) tp = ask + TakeProfitPips * g_pip;
      if(tp > 0 && tp - ask < minStop) tp = ask + minStop;

      sl = NormalizePrice(sl);
      tp = (tp > 0) ? NormalizePrice(tp) : 0.0;
      if(trade.Buy(lots, _Symbol, ask, sl, tp, "3rd-strategy grid buy"))
      {
         LogInfo("OPEN BUY " + DoubleToString(lots, 2) + " @ " + DoubleToString(ask, _Digits) + (isFirstLayer ? " | new basket" : " | add layer") + " | SL " + DoubleToString(sl, _Digits) + (tp > 0 ? " TP " + DoubleToString(tp, _Digits) : ""));
         g_lastEntryBar = g_lastBarTime; SyncBasketLines();
      }
      else
      {
         g_lastEntryFailTime = TimeCurrent();
         LogGuardOnce("FAIL buy rc=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      }
   }
   else
   {
      if(sl <= 0)
         sl = bid + MaxStopLossPips * g_pip;             // broker line = fixed pip cap in BOTH SL types
      if(sl - bid < minStop) sl = bid + minStop;
      if(tp <= 0 && TakeProfitPips > 0) tp = bid - TakeProfitPips * g_pip;
      if(tp > 0 && bid - tp < minStop) tp = bid - minStop;

      sl = NormalizePrice(sl);
      tp = (tp > 0) ? NormalizePrice(tp) : 0.0;
      if(trade.Sell(lots, _Symbol, bid, sl, tp, "3rd-strategy grid sell"))
      {
         LogInfo("OPEN SELL " + DoubleToString(lots, 2) + " @ " + DoubleToString(bid, _Digits) + (isFirstLayer ? " | new basket" : " | add layer") + " | SL " + DoubleToString(sl, _Digits) + (tp > 0 ? " TP " + DoubleToString(tp, _Digits) : ""));
         g_lastEntryBar = g_lastBarTime; SyncBasketLines();
      }
      else
      {
         g_lastEntryFailTime = TimeCurrent();
         LogGuardOnce("FAIL sell rc=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      }
   }
}

//====================== BASKET SL/TP LINES (broker, tighter-only) ======================
// Called ONLY when a layer opens. Computes candidates from the average entry
// of all open layers, then ratchets:
//   BUY : SL may only move UP, TP may only move DOWN (both = tighter)
//   SELL: SL may only move DOWN, TP may only move UP
// Wider candidates are ignored. Same line pushed to every ticket.
// Avg entry is a SIMPLE average (not lot-weighted): basket TP hit always
// equals layers x TakeProfitPips in pips, whatever lots each layer has.
void SyncBasketLines()
{
   int    count = 0;
   double sumEntry = 0;
   bool   isBuy = true, first = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      sumEntry += PositionGetDouble(POSITION_PRICE_OPEN);
      if(first) { isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY); first = false; }
      count++;
   }
   if(count == 0) { ResetBasketLines(); return; }

   double avgEntry = sumEntry / count;
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStop  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   // ratchet reference: if a tighter modify is still pending at the broker,
   // ratchet against THAT, so the tighter-only guarantee survives rejections
   double refSL = g_modifyPending ? g_pendingSL : g_basketSL;
   double refTP = g_modifyPending ? g_pendingTP : g_basketTP;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double slCand, tpCand;

   if(isBuy)
   {
      slCand = avgEntry - MaxStopLossPips * g_pip;
      tpCand = (TakeProfitPips > 0) ? avgEntry + TakeProfitPips * g_pip : 0.0;

      // ratchet: tighter update, wider ignore
      double newSL = (refSL <= 0) ? slCand : MathMax(refSL, slCand);
      double newTP = (TakeProfitPips <= 0) ? 0.0
                   : (refTP <= 0) ? tpCand : MathMin(refTP, tpCand);

      // broker min-distance: never widen to satisfy it — keep old line instead
      if(bid - newSL < minStop)  newSL = (refSL > 0) ? refSL : bid - minStop;
      if(newTP > 0 && newTP - ask < minStop) newTP = (refTP > 0) ? refTP : ask + minStop;

      ApplyBasketLines(NormalizePrice(newSL), (newTP > 0) ? NormalizePrice(newTP) : 0.0);
   }
   else
   {
      slCand = avgEntry + MaxStopLossPips * g_pip;
      tpCand = (TakeProfitPips > 0) ? avgEntry - TakeProfitPips * g_pip : 0.0;

      double newSL = (refSL <= 0) ? slCand : MathMin(refSL, slCand);
      double newTP = (TakeProfitPips <= 0) ? 0.0
                   : (refTP <= 0) ? tpCand : MathMax(refTP, tpCand);

      if(newSL - ask < minStop) newSL = (refSL > 0) ? refSL : ask + minStop;
      if(newTP > 0 && bid - newTP < minStop) newTP = (refTP > 0) ? refTP : bid - minStop;

      ApplyBasketLines(NormalizePrice(newSL), (newTP > 0) ? NormalizePrice(newTP) : 0.0);
   }
}

void ApplyBasketLines(double sl, double tp)
{
   double tol = SymbolInfoDouble(_Symbol, SYMBOL_POINT) / 2.0;
   bool slMoved = (MathAbs(sl - g_basketSL) > tol);
   bool tpMoved = (MathAbs(tp - g_basketTP) > tol);

   if(slMoved || tpMoved)
      Print(Tag(), " | LINES SL ", DoubleToString(g_basketSL, _Digits), " -> ", DoubleToString(sl, _Digits),
            " | TP ", DoubleToString(g_basketTP, _Digits), " -> ", DoubleToString(tp, _Digits),
            " (tighter update / wider ignored)");

   // targets are PENDING until every ticket is confirmed by the broker
   g_pendingSL     = sl;
   g_pendingTP     = tp;
   g_modifyPending = true;

   ProcessBasketModify();
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
         LogGuardOnce("FAIL modify (fatal) rc=" + IntegerToString(rc) +
                      " " + trade.ResultRetcodeDescription() + " — will re-attempt after cooldown");
         return false;
      }
      if(attempt < maxTry && ModifyRetryDelayMs > 0)
         Sleep(ModifyRetryDelayMs);
   }
   LogGuardOnce("FAIL modify after " + IntegerToString(maxTry) + " tries rc=" +
                IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
   return false;
}

// push pending lines to every EA ticket; commit g_basketSL/TP only when the
// broker has accepted them on ALL tickets. Called on layer open and from
// OnTick after MaxConsecutiveRetryCooldownMs while still pending.
void ProcessBasketModify()
{
   if(!g_modifyPending) return;

   double sl  = g_pendingSL;
   double tp  = g_pendingTP;
   double tol = SymbolInfoDouble(_Symbol, SYMBOL_POINT) / 2.0;

   int  count = 0;
   bool allOk = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      count++;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      if(MathAbs(curSL - sl) <= tol && MathAbs(curTP - tp) <= tol) continue;   // already there

      if(!ModifyTicketWithRetry(tk, sl, tp)) allOk = false;
   }

   if(count == 0)              // nothing left to modify
   {
      g_modifyPending = false;
      return;
   }

   if(allOk)
   {
      g_modifyPending = false;
      g_basketSL = sl;         // commit ONLY what the broker actually accepted
      g_basketTP = tp;
   }
   else
      g_lastModifyBurstMs = GetTickCount64();   // stay pending, cool down, retry in OnTick
}

void ResetBasketLines()
{
   g_basketSL      = 0;
   g_basketTP      = 0;
   g_modifyPending = false;
   g_pendingSL     = 0;
   g_pendingTP     = 0;
}

//====================== VIRTUAL MA SL (EA-side, never sent to broker) ======================
// Exit line from the CURRENT MA value: BUY = MA - buffer, SELL = MA + buffer.
// Returns false if the MA can't be read (handle missing / no data yet) —
// then no virtual exit fires this tick; the broker pip-cap SL is the backup.
bool GetMASLAnchor(const bool isBuy, double &anchor)
{
   anchor = 0;
   if(g_ma == INVALID_HANDLE) return false;

   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(g_ma, 0, 0, 1, m) != 1) return false;

   double buffer = MathMax(0.0, SLMABufferPips) * g_pip;
   anchor = isBuy ? (m[0] - buffer) : (m[0] + buffer);
   return true;
}

// Watched every tick, exactly like the basket pip trail: when price breaks
// the MA by the buffer, the WHOLE basket is closed at market by the EA.
// Nothing is ever written to the broker — the broker SL stays the fixed
// pip cap as offline backup. The line moves with the MA on its own, both
// directions, because it's recomputed fresh from the MA each tick.
void CheckVirtualMASL()
{
   if(SLType != SL_MA_VIRTUAL) return;

   int layers; double deepest; bool isBuy;
   CountLayers(layers, deepest, isBuy);
   if(layers == 0) return;

   double maSL;
   if(!GetMASLAnchor(isBuy, maSL)) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool breached = isBuy ? (bid <= maSL) : (ask >= maSL);
   if(!breached) return;

   LogGuardOnce("EXIT virtual MA SL hit " + (isBuy ? "bid " + DoubleToString(bid, _Digits) + " <= " : "ask " + DoubleToString(ask, _Digits) + " >= ") +
                DoubleToString(maSL, _Digits) + " (MA " + (isBuy ? "-" : "+") + " " + DoubleToString(SLMABufferPips, 1) + " pips) — closing basket");
   CloseAllEA("virtual MA SL");
}

//====================== BASKET PROFIT (pips, trailing) ======================
void ManageBasket()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   int    count = 0;
   double totalPips = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double e = PositionGetDouble(POSITION_PRICE_OPEN);
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         totalPips += (bid - e) / g_pip;
      else
         totalPips += (e - ask) / g_pip;
      count++;
   }

   // Always clear trail/line state when flat (even if basket TP is off).
   if(count == 0) { ResetBasket(); ResetBasketLines(); return; }
   if(!UseBasketTP) return;

   if(!g_basketArmed)
   {
      if(totalPips >= BasketStartPips)   // arm once the whole basket reaches the start line
      { g_basketArmed = true; g_basketPeak = totalPips; }
   }
   else
   {
      if(totalPips > g_basketPeak) g_basketPeak = totalPips;         // ratchet the peak up
      if(g_basketPeak - totalPips >= BasketGivebackPips)             // gave back too much -> harvest
      { CloseAllEA("basket giveback"); }
   }
}

void ResetBasket()
{
   g_basketArmed = false;
   g_basketPeak  = 0;
}

//====================== HELPERS ======================
void CloseAllEA(const string reason = "")
{
   if(!HasEAPositions()) return;
   if(!CanAttemptClose()) return;

   double totalPL     = 0;
   int    closedCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      totalPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      closedCount++;
   }

   bool anyFail = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(!trade.PositionClose(tk))
      {
         anyFail = true;
         LogGuardOnce("FAIL close rc=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      }
   }
   if(anyFail) g_lastCloseFailTime = TimeCurrent();
   else if(closedCount > 0)
   {
      LogInfo("CLOSE" + (reason != "" ? " (" + reason + ")" : "") + " | net P/L " + DoubleToString(totalPL, 2));
      NotifyPush(Tag() + ": BASKET CLOSED" + (reason != "" ? " (" + reason + ")" : "") + " | Net P/L: " + DoubleToString(totalPL, 2));
   }
}

bool PassesMAFilter(bool wantBuy)
{
   if(!UseMAFilter) return true;
   if(g_ma == INVALID_HANDLE) return false;

   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(g_ma, 0, 0, 2, m) != 2) return false;   // [0]=MA now, [1]=MA of last closed bar

   double buffer = MathMax(0.0, MABufferPips) * g_pip;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // BOTH modes: live price at this exact moment must be on the correct side
   // of the current MA (+/- buffer). No entry can print on the wrong side of
   // the MA line on the chart.
   bool liveOK = wantBuy ? (ask > m[0] + buffer) : (bid < m[0] - buffer);
   if(!liveOK) return false;

   if(MACheckMode == MA_CHECK_RUNNING) return true;

   // CANDLE_CLOSE (tighter): the last finished candle must ALSO have closed
   // on the correct side of its MA (+/- buffer). Skips the first spike
   // across the MA — needs a close to confirm before entries are allowed.
   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(_Symbol, g_entryTF, 1, 1, c) != 1) return false;

   if(wantBuy) return (c[0] > m[1] + buffer);
   return (c[0] < m[1] - buffer);
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

double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lots = MathRound(lots / step) * step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}
//+------------------------------------------------------------------+