//+------------------------------------------------------------------+
//|                                                2nd-strategy.mq5   |
//|   Stoch + RSI + MACD pullback grid EA. Skeleton (grid layering,   |
//|   basket SL/TP, session filter, market guard, retry machinery)    |
//|   forked from fibo-gun.mq5 (AutoFibTrader). ONLY the entry logic  |
//|   is different: the fib pivot/zigzag engine, golden-zone entry    |
//|   and BOS filter are replaced by an indicator-only pullback rule  |
//|   below. (The MA direction filter was re-added in v1.10.)         |
//|                                                                   |
//|   Entry rule (evaluated once per closed bar on InpTimeframe):     |
//|    - Stochastic (5,3,3 default): the TRIGGER. Two INDEPENDENT     |
//|      on/off switches — cross and classic never mix:               |
//|      UseStochCross (default true): %K must cross %D between the   |
//|      last two closed bars, qualified by StochCrossMode:           |
//|      PULLBACK = the cross must ALSO land on the pullback side of  |
//|      StochPullbackLevel (%K < level for buys, %K > level for      |
//|      sells); ANY = the cross alone fires, level ignored;          |
//|      OSOB = the cross must COME FROM the extreme zone (%K before  |
//|      the cross < StochOversoldLevel for buys, >                   |
//|      StochOverboughtLevel for sells).                             |
//|      UseStochClassic (default false): classic oversold/overbought |
//|      rule, NO cross involved — the last closed bar's %K simply    |
//|      sits inside the zone (< StochOversoldLevel = buy side,       |
//|      > StochOverboughtLevel = sell side).                         |
//|      Both ON = either trigger firing counts. Both OFF = no stoch  |
//|      condition at all, MACD bias decides.                         |
//|    - MACD (standard): bias filter, always on. The MAIN LINE       |
//|      itself (fast EMA - slow EMA) of the last CLOSED bar vs zero  |
//|      - this is what the chart's histogram bars actually plot      |
//|      (MT5 stock MACD draws main-line-as-bars, NOT main-signal).   |
//|      > 0 for buys, < 0 for sells.                                 |
//|    - RSI: OPTIONAL bias filter, toggled by UseRSI. When on, last  |
//|      closed bar value must be > RSIMidLevel for buys,             |
//|      < RSIMidLevel for sells. When off, ignored entirely and      |
//|      entries run on Stoch trigger + MACD bias alone.              |
//|    - MA filter (ported from fibo-bomb v3.50, same inputs): LIVE   |
//|      check at the entry moment — buys only above MA+buffer,       |
//|      sells only below MA-buffer, right NOW. Gates grid layers     |
//|      too, not just the first entry. MACheckMode: RUNNING = live   |
//|      check only; CANDLE_CLOSE = live check + last close confirm.  |
//|    - The signal is recomputed fresh every bar (no memory carried  |
//|      over) so it is only true on the bar the cross actually       |
//|      happens - same "pure function of current state" style as     |
//|      the fib leg scan it replaces.                                |
//|                                                                   |
//|   Stop loss has 2 types (SLType, since v1.30):                    |
//|    - SL_FIXED: broker SL = pip cap from avg entry. Original.      |
//|    - SL_MA_VIRTUAL: broker SL stays the pip cap (offline backup)  |
//|      PLUS a VIRTUAL exit watched by the EA tick-by-tick — basket  |
//|      is market-closed when price breaks the entry-filter MA by    |
//|      SLMABufferPips. Never written to the broker, follows the MA  |
//|      both directions. Same design as the basket pip trail.        |
//|                                                                   |
//|   Everything else - grid layering, basket SL/TP ratchet, basket   |
//|   pip trail, WIB session/weekend filter, broker/market guards,    |
//|   modify-retry burst logic - is unchanged from fibo-gun.mq5.      |
//|                                                                   |
//|   TEST ON DEMO / STRATEGY TESTER FIRST. Mechanical tool, not a    |
//|   profit guarantee. Grids carry tail risk - mind MaxLayers.       |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "1.35"
// v1.35: Cross and classic stoch are now two INDEPENDENT true/false switches —
//        no more mixing (StochClassicMode input removed). UseStochCross
//        (default true) = the %K/%D cross trigger, still qualified by
//        StochCrossMode (PULLBACK / ANY / OSOB, unchanged rules).
//        UseStochClassic (default false) = the classic oversold/overbought
//        rule on the last closed bar's %K (< StochOversoldLevel = buy side,
//        > StochOverboughtLevel = sell side), no cross involved. Both ON =
//        either trigger firing counts; both OFF = stoch condition gone, MACD
//        bias decides (what ANY+classic used to do). Defaults reproduce
//        v1.34 behavior exactly (cross on, OSOB mode, classic off).
// v1.34: StochClassicMode toggle (bool, default false): true turns the %K/%D
//        cross requirement OFF — the selected mode's level rule alone is the
//        trigger, judged on the last closed bar's %K (PULLBACK: %K on the
//        pullback side; OSOB: %K inside the OS/OB zone now). ANY + classic =
//        stoch condition gone entirely (MACD bias becomes the trigger).
//        Same toggle added to fibo-bomb v3.90 so the two stay in sync.
// v1.33: Third stoch cross mode: STOCH_CROSS_OSOB — the cross must COME FROM
//        the extreme zone (%K of the bar BEFORE the cross < StochOversoldLevel
//        for buys / > StochOverboughtLevel for sells; defaults 20/80). Where
//        %K lands after the cross doesn't matter, so a fast escape from the
//        zone still fires on the cross bar. Defaults unchanged (PULLBACK).
//        Same mode added to fibo-bomb v3.80 so the two stay in sync.
// v1.32: Stoch cross got 2 modes (StochCrossMode input): PULLBACK (original
//        rule — the cross must land on the pullback side of
//        StochPullbackLevel) or ANY (the %K/%D cross alone fires, level
//        ignored). Default PULLBACK — behavior unchanged. Same mode added
//        to fibo-bomb v3.70 so the two stay in sync.
// v1.31: Defaults synced to the 21x tester run (XAUUSDc M1, SL_MA_VIRTUAL):
//        LotSize 0.5, MaxStopLossPips 300, MaxLayers 2, LayerStepPips 200,
//        BasketStartPips 200, BasketGivebackPips 50, MABufferPips/
//        SLMABufferPips 100. Only DEFAULTS changed — no logic touched.
// v1.30: MA SL is now VIRTUAL (like the basket pip trail): SL_MA_VIRTUAL
//        watches the entry-filter MA tick-by-tick and market-closes the
//        whole basket when price breaks MA -/+ SLMABufferPips. Nothing is
//        written to the broker for it — the broker SL line is ALWAYS the
//        fixed pip cap (offline backup), in both modes. Because the line is
//        recomputed from the MA each tick, it follows the MA both ways.
// v1.20: SL got 2 types (SLType input); the MA variant was a broker-side
//        trail — replaced by the virtual design in v1.30.
// v1.10: MA direction filter added, ported 1:1 from fibo-bomb v3.50 (same
//        inputs, same defaults). Pure ADDITIVE filter: Stoch/RSI/MACD signal
//        engine untouched — the MA can only block an entry, never create one.

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_LABEL "2nd-strategy"

//====================== INPUTS ======================
input group "===== Timeframe Lock ====="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // Locked TF (engine + trades run on THIS tf)

input group "===== Entry Mode ====="
input bool                UseRSI            = true;        // true = RSI bias filter applies; false = Stoch trigger + MACD bias only (RSI ignored)

input group "===== Indicator Engine (Stoch + RSI + MACD) ====="
input int                 StochKPeriod      = 5;           // Stochastic %K period
input int                 StochDPeriod      = 3;           // Stochastic %D period
input int                 StochSlowing      = 3;           // Stochastic slowing
input ENUM_MA_METHOD      StochMAMethod     = MODE_SMA;    // Stochastic MA method
input ENUM_STO_PRICE      StochPriceField   = STO_LOWHIGH; // Stochastic price field
enum ENUM_STOCH_CROSS_MODE
{
   STOCH_CROSS_PULLBACK, // Pullback side: cross must land below level (buy) / above level (sell)
   STOCH_CROSS_ANY,      // Any cross: %K/%D cross alone fires, level ignored
   STOCH_CROSS_OSOB      // Extremes: cross must COME FROM oversold (buy) / overbought (sell)
};
input bool                UseStochCross       = true;      // CROSS trigger ON/OFF: %K crosses %D (mode below)
input ENUM_STOCH_CROSS_MODE StochCrossMode    = STOCH_CROSS_OSOB; // Cross mode (only used when UseStochCross = true)
input bool                UseStochClassic     = false;     // CLASSIC trigger ON/OFF: %K in OS zone = buy / OB zone = sell, NO cross
input double              StochPullbackLevel  = 50;        // Pullback level (cross PULLBACK mode only)
input double              StochOversoldLevel  = 20;        // Oversold level (cross OSOB mode start zone + classic buy zone)
input double              StochOverboughtLevel= 80;        // Overbought level (cross OSOB mode start zone + classic sell zone)
input int                 RSIPeriod         = 14;          // RSI period
input ENUM_APPLIED_PRICE  RSIAppliedPrice   = PRICE_CLOSE; // RSI applied price
input double              RSIMidLevel       = 50;          // RSI must be above(buy)/below(sell) this level
input int                 MACDFastEMA       = 12;          // MACD fast EMA
input int                 MACDSlowEMA       = 26;          // MACD slow EMA
input int                 MACDSignalPeriod  = 9;           // MACD signal period
input ENUM_APPLIED_PRICE  MACDAppliedPrice  = PRICE_CLOSE; // MACD applied price

input group "===== Moving Average Filter ====="
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
input long   MagicNumber     = 222;   // EA id

input group "===== Grid Layering ====="
input int    MaxLayers       = 2;     // Max simultaneous positions this EA owns
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
ENUM_TIMEFRAMES g_tf;
int      g_stoch = INVALID_HANDLE;
int      g_rsi   = INVALID_HANDLE;
int      g_macd  = INVALID_HANDLE;
int      g_ma    = INVALID_HANDLE;
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
   g_tf = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;

   if(MaxLayers < 1)
   {
      LogInfo("INIT FAILED - MaxLayers must be >= 1");
      NotifyPush(Tag() + ": INIT FAILED - MaxLayers must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_stoch = iStochastic(_Symbol, g_tf, StochKPeriod, StochDPeriod, StochSlowing, StochMAMethod, StochPriceField);
   if(g_stoch == INVALID_HANDLE)
   {
      LogInfo("INIT FAILED - Stochastic handle");
      NotifyPush(Tag() + ": INIT FAILED - Stochastic handle");
      return(INIT_FAILED);
   }

   g_rsi = iRSI(_Symbol, g_tf, RSIPeriod, RSIAppliedPrice);
   if(g_rsi == INVALID_HANDLE)
   {
      LogInfo("INIT FAILED - RSI handle");
      NotifyPush(Tag() + ": INIT FAILED - RSI handle");
      return(INIT_FAILED);
   }

   g_macd = iMACD(_Symbol, g_tf, MACDFastEMA, MACDSlowEMA, MACDSignalPeriod, MACDAppliedPrice);
   if(g_macd == INVALID_HANDLE)
   {
      LogInfo("INIT FAILED - MACD handle");
      NotifyPush(Tag() + ": INIT FAILED - MACD handle");
      return(INIT_FAILED);
   }

   // MA handle needed by the entry filter AND/OR the virtual MA SL
   if(UseMAFilter || SLType == SL_MA_VIRTUAL)
   {
      g_ma = iMA(_Symbol, g_tf, MathMax(1, MA_Period), MA_Shift, MA_Method, MA_AppliedPrice);
      if(g_ma == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - MA handle");
         NotifyPush(Tag() + ": INIT FAILED - MA handle");
         return(INIT_FAILED);
      }
   }

   g_pip = PipSize();

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(_Period != g_tf)
      Print(Tag(), " | NOTE chart TF differs from locked TF (", EnumToString(g_tf),
            "). EA runs on the locked TF regardless of the chart.");

   LogInfo("Stoch trigger: CROSS=" + (UseStochCross ? "ON (" + EnumToString(StochCrossMode) + ")" : "OFF")
           + " | CLASSIC=" + (UseStochClassic ? "ON" : "OFF")
           + (!UseStochCross && !UseStochClassic ? " | BOTH OFF -> no stoch condition, MACD bias decides!" : ""));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_stoch != INVALID_HANDLE) IndicatorRelease(g_stoch);
   if(g_rsi   != INVALID_HANDLE) IndicatorRelease(g_rsi);
   if(g_macd  != INVALID_HANDLE) IndicatorRelease(g_macd);
   if(g_ma    != INVALID_HANDLE) IndicatorRelease(g_ma);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // --- refresh the signal once per locked-TF bar (no intrabar repaint) ---
   datetime bt[];
   if(CopyTime(_Symbol, g_tf, 0, 1, bt) == 1 && bt[0] != g_lastBarTime)
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

//====================== SIGNAL ENGINE (Stoch trigger, MACD bias, optional RSI filter) ======================
// Recomputed fresh every closed bar — pure function of the last two closed
// bars, nothing carried over, mirroring the "no memory, recompute every
// scan" design of the fib leg engine this file replaces. With the CROSS
// trigger, g_haveSignal is only true on the bar the cross actually happens;
// with the CLASSIC trigger it stays true every bar %K sits in the zone
// (layer step / one-entry-per-bar rules in TryEnter pace the entries).
void UpdateSignal()
{
   g_haveSignal  = false;
   g_signalIsBuy = false;

   double k[], d[], rsi[], macdMain[];
   ArraySetAsSeries(k,        true);
   ArraySetAsSeries(d,        true);
   ArraySetAsSeries(rsi,      true);
   ArraySetAsSeries(macdMain, true);

   // index 0 = current forming bar (ignored — no intrabar repaint),
   // index 1 = last CLOSED bar, index 2 = the closed bar before that.
   if(CopyBuffer(g_stoch, 0, 0, 3, k)          != 3) return; // %K
   if(CopyBuffer(g_stoch, 1, 0, 3, d)          != 3) return; // %D
   if(CopyBuffer(g_rsi,   0, 0, 3, rsi)        != 3) return;
   if(CopyBuffer(g_macd,  0, 0, 3, macdMain)   != 3) return; // MACD main line (the histogram bars in the chart)

   double k1 = k[1], k2 = k[2];
   double d1 = d[1], d2 = d[2];
   double macdMain1 = macdMain[1];
   double rsi1      = rsi[1];

   // Stoch trigger: two INDEPENDENT switches, never mixed.
   // CROSS (UseStochCross): %K crosses %D between the two closed bars,
   // qualified by StochCrossMode — PULLBACK: the cross must land on the
   // pullback side of StochPullbackLevel (%K after the cross); ANY: the
   // cross alone; OSOB: the cross must COME FROM the extreme zone (%K
   // BEFORE the cross below StochOversoldLevel for buys / above
   // StochOverboughtLevel for sells — where %K lands doesn't matter, so a
   // fast escape from the zone still fires on the cross bar).
   // CLASSIC (UseStochClassic): no cross anywhere — the last closed bar's
   // %K simply sits inside the zone (< StochOversoldLevel = buy side,
   // > StochOverboughtLevel = sell side). Can stay true bar after bar
   // while %K stays in the zone; buy/sell sides are exclusive by level.
   // Both ON = either trigger firing counts. Both OFF = no stoch condition
   // at all and the MACD bias below becomes the de-facto trigger.
   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);
   bool crossLevelBuyOK  = (StochCrossMode == STOCH_CROSS_ANY)  ? true
                         : (StochCrossMode == STOCH_CROSS_OSOB) ? (k2 < StochOversoldLevel)
                         :                                        (k1 < StochPullbackLevel);
   bool crossLevelSellOK = (StochCrossMode == STOCH_CROSS_ANY)  ? true
                         : (StochCrossMode == STOCH_CROSS_OSOB) ? (k2 > StochOverboughtLevel)
                         :                                        (k1 > StochPullbackLevel);
   bool crossBuy    = UseStochCross && crossedUp   && crossLevelBuyOK;
   bool crossSell   = UseStochCross && crossedDown && crossLevelSellOK;

   bool classicBuy  = UseStochClassic && (k1 < StochOversoldLevel);
   bool classicSell = UseStochClassic && (k1 > StochOverboughtLevel);

   bool stochOff    = (!UseStochCross && !UseStochClassic);
   bool stochBuyOK  = crossBuy  || classicBuy  || stochOff;
   bool stochSellOK = crossSell || classicSell || stochOff;

   // MACD bias: the main line itself vs zero — this is what the chart's
   // histogram bars actually plot (MT5's stock MACD draws main-line-as-bars,
   // signal-as-line; it is NOT main-minus-signal).
   bool macdBuyOK  = macdMain1 > 0;
   bool macdSellOK = macdMain1 < 0;

   // RSI bias: optional. When UseRSI is off, this filter is bypassed
   // (always true) and entries run on Stoch trigger + MACD bias alone.
   bool rsiBuyOK   = !UseRSI || (rsi1 > RSIMidLevel);
   bool rsiSellOK  = !UseRSI || (rsi1 < RSIMidLevel);

   if(stochBuyOK && macdBuyOK && rsiBuyOK)
   { g_haveSignal = true; g_signalIsBuy = true; }
   else if(stochSellOK && macdSellOK && rsiSellOK)
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
      if(trade.Buy(lots, _Symbol, ask, sl, tp, "2nd-strategy grid buy"))
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
      if(trade.Sell(lots, _Symbol, bid, sl, tp, "2nd-strategy grid sell"))
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
   if(!UseBasketTP) return;

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

   if(count == 0) { ResetBasket(); ResetBasketLines(); return; }

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
   if(CopyClose(_Symbol, g_tf, 1, 1, c) != 1) return false;

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