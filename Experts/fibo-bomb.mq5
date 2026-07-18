//+------------------------------------------------------------------+
//|                                              AutoFibTrader.mq5    |
//|   Fibonacci golden-zone grid EA. Pairs with AutoFibRetracement    |
//|   (fibo.mq5 v4+ chart build / fibo-in.mq5 v6+ panel build): those |
//|   builds rescan per bar exactly like the engine below, so the leg |
//|   the EA trades matches the leg you see — provided Depth,         |
//|   DeviationMult, ATRPeriod, LookbackBars are identical and the    |
//|   indicator chart runs on InpTimeframe.                           |
//|                                                                   |
//|   Design (v3.50):                                                 |
//|    - SL/TP are BASKET LINES shared by every layer: recomputed     |
//|      from avg entry + fibo anchor when a layer opens, pushed to   |
//|      all tickets, and RATCHETED tighter-only — never widened.     |
//|    - Basket profit trail in PIPS: total pips of all open layers   |
//|      arms the trail at BasketStartPips; give back                 |
//|      BasketGivebackPips from the peak and the whole basket        |
//|      closes. Runs alongside the basket TP line if both are on.    |
//|    - Grid: adds a layer only when price pushes LayerStepPips      |
//|      deeper into the zone against the position, up to MaxLayers.  |
//|    - Timeframe LOCK: engine + trades run on InpTimeframe.         |
//|    - Session filter: daily window + weekend block entered in WIB. |
//|      SessionTZOffset must equal WIB(+7) minus the broker's UTC    |
//|      offset — 7 on a UTC+0 broker (verified for this account).    |
//|    - Optional BOS gate: the leg endpoint must break the PREVIOUS  |
//|      same-side swing, then pullback to fib zone + MA must align.  |
//|    - MA filter: LIVE check at the entry moment — buys only above  |
//|      MA+buffer, sells only below MA-buffer, right NOW. The pivot  |
//|      engine likewise scans INCLUDING the forming candle: leg, BOS |
//|      and MA are all judged on the same live market state.         |
//|    - Stochastic filter: two INDEPENDENT on/off switches — cross   |
//|      and classic never mix (same design as 2nd-strategy v1.35):   |
//|      UseStochCross (default true): %K must cross %D between the   |
//|      last two CLOSED bars, qualified by StochCrossMode:           |
//|      PULLBACK = cross must ALSO land on the pullback side of      |
//|      StochPullbackLevel; ANY = the cross alone; OSOB = cross      |
//|      must COME FROM oversold (buy) / overbought (sell) — %K       |
//|      before the cross past the level. Signal lives one bar.       |
//|      UseStochClassic (default false): classic oversold/overbought |
//|      rule, NO cross — last closed bar's %K inside the zone        |
//|      (< StochOversoldLevel = buy side, > StochOverboughtLevel =   |
//|      sell side).                                                  |
//|      Both ON = either one passing counts. Both OFF = the stoch    |
//|      filter is disabled entirely (old UseStochFilter=false).      |
//|                                                                   |
//|   TEST ON DEMO / STRATEGY TESTER FIRST. Mechanical tool, not a    |
//|   profit guarantee. Grids carry tail risk — mind MaxLayers.       |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "4.01"
// v4.00: Cross and classic stoch are now two INDEPENDENT true/false switches —
//        no more mixing (StochClassicMode AND UseStochFilter inputs removed).
//        UseStochCross (default true) = the %K/%D cross filter, still
//        qualified by StochCrossMode (PULLBACK / ANY / OSOB, unchanged rules).
//        UseStochClassic (default false) = the classic oversold/overbought
//        rule on the last closed bar's %K (< StochOversoldLevel = buy side,
//        > StochOverboughtLevel = sell side), no cross involved. Both ON =
//        either one passing counts; both OFF = stoch filter disabled entirely
//        (this replaces UseStochFilter=false). Defaults reproduce v3.90
//        behavior exactly (filter on, cross, PULLBACK mode, classic off).
//        Same split as 2nd-strategy v1.35 so the two stay in sync.
// v3.90: StochClassicMode toggle (bool, default false): true turns the %K/%D
//        cross requirement OFF — the selected mode's level rule alone is the
//        condition, judged on the last closed bar's %K (PULLBACK: %K on the
//        pullback side; OSOB: %K inside the OS/OB zone now). ANY + classic =
//        stoch filter passes everything. Same toggle added to 2nd-strategy
//        v1.34 so the two stay in sync.
// v3.80: Third stoch cross mode: STOCH_CROSS_OSOB — the cross must COME FROM
//        the extreme zone (%K of the bar BEFORE the cross < StochOversoldLevel
//        for buys / > StochOverboughtLevel for sells; defaults 20/80). Where
//        %K lands after the cross doesn't matter, so a fast escape from the
//        zone still fires on the cross bar. Defaults unchanged (PULLBACK).
//        Same mode added to 2nd-strategy v1.33 so the two stay in sync.
// v3.70: Stoch cross got 2 modes (StochCrossMode input): PULLBACK (original
//        rule — the cross must land on the pullback side of
//        StochPullbackLevel) or ANY (the %K/%D cross alone fires, level
//        ignored). Default PULLBACK — behavior unchanged. Same mode added
//        to 2nd-strategy v1.32 so the two stay in sync.
// v3.60: Stochastic cross filter added, ported 1:1 from 2nd-strategy (same
//        level rule, pullback side): %K must cross %D between the last two
//        CLOSED bars on the locked TF, with the cross on the pullback side
//        of StochPullbackLevel — below it for buys, above it for sells.
//        Signal is valid only during the bar right after the cross —
//        recomputed fresh every bar, no memory. Pure veto gate like BOS/MA:
//        it can only block an entry, never create one. Gates layers too.
// v3.50: MA filter rebuilt around the CURRENT moment, not bar-1 history.
//        Both modes require live price on the correct side of the MA NOW
//        (+/- MABufferPips) -> entries can never print on the wrong side of
//        the MA line. MACheckMode: RUNNING = live check only;
//        CANDLE_CLOSE = live check + last close must confirm (tighter).

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_LABEL "fibo-bomb"

//====================== INPUTS ======================
input group "===== Timeframe Lock ====="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // Locked TF (engine + trades run on THIS tf)

input group "===== Pivot Engine (match your indicator) ====="
input double DeviationMult  = 3.0;    // Deviation multiplier (ATR-based %)
input int    Depth          = 6;      // Depth (left/right confirm = Depth/2)
input int    ATRPeriod      = 10;     // ATR period
input int    LookbackBars   = 100;    // Bars scanned for the current leg

input group "===== Golden Zone Entry ====="
input double ZoneLevelMin   = 0.382;  // Shallow edge of zone
input double ZoneLevelMax   = 0.618;  // Deep edge of zone

input group "===== Orders / Risk (BASKET lines: shared SL/TP, tighter-only) ====="
input double LotSize         = 0.01;  // Lots per layer
input int    MaxStopLossPips = 500;   // SL cap in pips from AVG entry (vs fibo anchor, closer wins)
input int    TakeProfitPips  = 3000;  // Basket TP: avg entry +/- this many pips (0 = no TP line)
input int    MaxSpreadPips   = 0;     // Skip new entries above this spread (0 = ignore)
input int    SlippagePoints  = 20;    // Max deviation for market orders (points)
input long   MagicNumber     = 987;   // EA id

input group "===== Grid Layering ====="
input int    MaxLayers       = 1;     // Max simultaneous positions this EA owns
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

input group "===== BOS Confirmation (anti-chop) ====="
input bool UseBOSFilter          = true; // Only trade legs whose endpoint broke the PREVIOUS swing (BOS)

input group "===== Moving Average Filter ====="
enum ENUM_MA_CHECK
{
   MA_CHECK_RUNNING,      // Running: live price vs MA right now (+/- buffer)
   MA_CHECK_CANDLE_CLOSE  // Candle close: last close must confirm too (tighter)
};
input bool               UseMAFilter     = true;             // Enable MA direction filter
input ENUM_MA_CHECK      MACheckMode     = MA_CHECK_CANDLE_CLOSE; // Running or candle-close (tighter)
input ENUM_MA_METHOD     MA_Method       = MODE_EMA;         // MA type: SMA / EMA / SMMA / LWMA
input int                MA_Period       = 55;               // MA period
input int                MA_Shift        = 0;                // MA horizontal shift
input ENUM_APPLIED_PRICE MA_AppliedPrice = PRICE_CLOSE;      // Applied price
input double             MABufferPips    = 100;              // Price must clear the MA by this many pips (0 = plain cross)
// Rule (BOTH modes): live price NOW must be above MA+buffer for BUYS,
// below MA-buffer for SELLS — an entry can never sit on the wrong side of
// the MA you see on the chart.
// CANDLE_CLOSE adds: the last finished candle must ALSO have closed on the
// correct side (+/- buffer) — tighter, skips the first spike across the MA.

input group "===== Stochastic Filter ====="
input int                StochKPeriod    = 5;           // Stochastic %K period
input int                StochDPeriod    = 3;           // Stochastic %D period
input int                StochSlowing    = 3;           // Stochastic slowing
input ENUM_MA_METHOD     StochMAMethod   = MODE_SMA;    // Stochastic MA method
input ENUM_STO_PRICE     StochPriceField = STO_LOWHIGH; // Stochastic price field
enum ENUM_STOCH_CROSS_MODE
{
   STOCH_CROSS_PULLBACK, // Pullback side: cross must land below level (buy) / above level (sell)
   STOCH_CROSS_ANY,      // Any cross: %K/%D cross alone fires, level ignored
   STOCH_CROSS_OSOB      // Extremes: cross must COME FROM oversold (buy) / overbought (sell)
};
input bool               UseStochCross   = true;        // CROSS filter ON/OFF: %K crosses %D (mode below)
input ENUM_STOCH_CROSS_MODE StochCrossMode = STOCH_CROSS_PULLBACK; // Cross mode (only used when UseStochCross = true)
input bool               UseStochClassic = false;       // CLASSIC filter ON/OFF: %K in OS zone = buy / OB zone = sell, NO cross
input double             StochPullbackLevel = 50;       // Pullback level (cross PULLBACK mode only)
input double             StochOversoldLevel  = 20;      // Oversold level (cross OSOB mode start zone + classic buy zone)
input double             StochOverboughtLevel= 80;      // Overbought level (cross OSOB mode start zone + classic sell zone)
// Two independent switches, never mixed — same design as 2nd-strategy.
// CROSS: %K crosses %D between the last two CLOSED bars on the locked TF
// (signal lives one bar). CLASSIC: last closed bar's %K sits in the OS/OB
// zone, no cross. Both ON = either counts. Both OFF = filter disabled.

//====================== GLOBALS ======================
ENUM_TIMEFRAMES g_tf;
int      g_atr   = INVALID_HANDLE;
int      g_ma    = INVALID_HANDLE;
int      g_stoch = INVALID_HANDLE;
double   g_pip = 0;
datetime g_lastBarTime  = 0;
datetime g_lastEntryBar = 0;

// current leg (anchors)
bool   g_haveLeg    = false;
bool   g_bullishLeg = false;
double g_olderPrice = 0;   // leg start (swing that began the move)
double g_newerPrice = 0;   // leg end   (0.0 anchor of the retracement)

// zigzag scan state (reset every scan)
bool   g_haveLastZZ  = false;
double g_lastZZPrice = 0;
int    g_lastZZType  = -1;
bool   g_havePrevZZ  = false;

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

// BOS (Option B, structural): the swing BEFORE the leg. For a bull leg
// (L1->H2) this is the previous swing high H1; BOS = H2 > H1. Recomputed
// fresh every scan in UpdateLeg() — no event memory, nothing to reset.
bool   g_bosConfirmed  = false;
bool   g_havePrevSwing = false;
double g_prevSwing     = 0;

// entry diagnostics: one reason per bar, only when price is inside the zone
datetime g_lastDiagBar = 0;

// stoch filter state, recomputed fresh every locked-TF bar in
// UpdateStochSignal (cross: true only the bar right after the cross;
// classic: true every bar %K sits in the OS/OB zone)
bool g_stochBuyOK  = false;
bool g_stochSellOK = false;

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

   if(ZoneLevelMin >= ZoneLevelMax)
   {
      LogInfo("INIT FAILED - ZoneLevelMin must be < ZoneLevelMax");
      NotifyPush(Tag() + ": INIT FAILED - ZoneLevelMin must be < ZoneLevelMax");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxLayers < 1)
   {
      LogInfo("INIT FAILED - MaxLayers must be >= 1");
      NotifyPush(Tag() + ": INIT FAILED - MaxLayers must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_atr = iATR(_Symbol, g_tf, MathMax(1, ATRPeriod));
   if(g_atr == INVALID_HANDLE)
   {
      LogInfo("INIT FAILED - ATR handle");
      NotifyPush(Tag() + ": INIT FAILED - ATR handle");
      return(INIT_FAILED);
   }

   if(UseMAFilter)
   {
      g_ma = iMA(_Symbol, g_tf, MathMax(1, MA_Period), MA_Shift, MA_Method, MA_AppliedPrice);
      if(g_ma == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - MA handle");
         NotifyPush(Tag() + ": INIT FAILED - MA handle");
         return(INIT_FAILED);
      }
   }

   if(UseStochCross || UseStochClassic)
   {
      g_stoch = iStochastic(_Symbol, g_tf, StochKPeriod, StochDPeriod, StochSlowing, StochMAMethod, StochPriceField);
      if(g_stoch == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - Stochastic handle");
         NotifyPush(Tag() + ": INIT FAILED - Stochastic handle");
         return(INIT_FAILED);
      }
   }

   g_pip = PipSize();

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(_Period != g_tf)
      Print(Tag(), " | NOTE chart TF differs from locked TF (", EnumToString(g_tf),
            "). EA runs on the locked TF regardless of the chart.");

   LogInfo("Stoch filter: CROSS=" + (UseStochCross ? "ON (" + EnumToString(StochCrossMode) + ")" : "OFF")
           + " | CLASSIC=" + (UseStochClassic ? "ON" : "OFF")
           + (!UseStochCross && !UseStochClassic ? " | BOTH OFF -> stoch filter disabled, fib entries ungated by stoch" : ""));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atr != INVALID_HANDLE)
      IndicatorRelease(g_atr);
   if(g_ma != INVALID_HANDLE)
      IndicatorRelease(g_ma);
   if(g_stoch != INVALID_HANDLE)
      IndicatorRelease(g_stoch);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // --- refresh the leg once per locked-TF bar (no intrabar repaint) ---
   datetime bt[];
   if(CopyTime(_Symbol, g_tf, 0, 1, bt) == 1 && bt[0] != g_lastBarTime)
   {
      g_lastBarTime = bt[0];
      UpdateLeg();           // leg + structural BOS computed together
      UpdateStochSignal();   // stoch filter (cross/classic) refreshed on the same bar
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

   // --- entries ---
   if(!g_haveLeg) return;
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
   return false;
}

//====================== PIVOT ENGINE (port of fibo.mq5) ======================
void UpdateLeg()
{
   g_haveLeg = false;

   int prd  = MathMax(1, Depth / 2);
   int bars = (int)MathMin((long)LookbackBars, (long)Bars(_Symbol, g_tf));
   if(bars < 2 * prd + 3) return;

   double high[], low[], close[], atr[];
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(atr,   false);   // index 0 = oldest, aligned with price arrays

   if(CopyHigh (_Symbol, g_tf, 0, bars, high)  < bars) return;
   if(CopyLow  (_Symbol, g_tf, 0, bars, low)   < bars) return;
   if(CopyClose(_Symbol, g_tf, 0, bars, close) < bars) return;
   if(CopyBuffer(g_atr, 0, 0, bars, atr)       < bars) return;

   // full state reset each scan (prevents leg drift)
   g_haveLastZZ = false; g_havePrevZZ = false;
   g_lastZZPrice = 0;    g_lastZZType = -1;
   g_olderPrice = 0;     g_newerPrice = 0;
   g_havePrevSwing = false; g_prevSwing = 0;

   for(int i = 2 * prd; i < bars; i++)
   {
      int pivotIdx = i - prd;
      if(pivotIdx < prd) continue;

      double atrVal = atr[pivotIdx];
      double devPct = (close[pivotIdx] != 0.0 && atrVal > 0.0)
                      ? (atrVal / close[pivotIdx]) * 100.0 * DeviationMult : 0.0;

      bool ph = IsPivotHigh(high, pivotIdx, bars, prd);
      bool pl = IsPivotLow (low,  pivotIdx, bars, prd);

      if(ph) ProcessPivot(high[pivotIdx], 1, devPct);
      if(pl) ProcessPivot(low[pivotIdx],  0, devPct);
   }

   if(g_havePrevZZ)
   {
      g_haveLeg    = true;
      g_bullishLeg = (g_newerPrice > g_olderPrice); // up leg -> pullback down -> BUY
   }

   // --- BOS (Option B, structural): leg endpoint must have broken the ---
   // --- PREVIOUS same-side swing. Bull leg L1->H2: BOS = H2 > H1.      ---
   // Pure function of the zigzag points — recomputed every scan, so a fib
   // redraw can never "forget" a break: if the structure was broken, the
   // pivots prove it; if not, no entries on this leg.
   g_bosConfirmed = false;
   if(g_haveLeg && g_havePrevSwing)
   {
      if(g_bullishLeg)  g_bosConfirmed = (g_newerPrice > g_prevSwing); // higher high vs previous swing high
      else              g_bosConfirmed = (g_newerPrice < g_prevSwing); // lower low  vs previous swing low
   }
   // note: with only 2 zigzag points in the lookback there is no previous
   // swing to verify against -> BOS stays false (no unverified entries).
}

bool PassesBOSFilter()
{
   if(!UseBOSFilter) return true;
   return (g_haveLeg && g_bosConfirmed);
}

//====================== STOCH FILTER (%K/%D cross, optional level rule) ======================
// Recomputed fresh every locked-TF bar — pure function of the last two closed
// bars, nothing carried over. Two INDEPENDENT switches, never mixed — same
// design as 2nd-strategy.
// CROSS (UseStochCross): %K crosses %D between the two closed bars, only
// true on the bar right after the cross, qualified by StochCrossMode —
// PULLBACK: the cross must land on the pullback side of StochPullbackLevel
// (below it for buys, above it for sells); ANY: the cross alone; OSOB: the
// cross must COME FROM the extreme zone (%K BEFORE the cross below
// StochOversoldLevel for buys / above StochOverboughtLevel for sells —
// where %K lands doesn't matter, a fast escape still fires on the cross bar).
// CLASSIC (UseStochClassic): no cross anywhere — the last closed bar's %K
// simply sits inside the zone (< StochOversoldLevel = buy side,
// > StochOverboughtLevel = sell side). Can stay true bar after bar.
// Both ON = either one passing counts. Both OFF = filter disabled
// (PassesStochFilter passes everything).
void UpdateStochSignal()
{
   g_stochBuyOK  = false;
   g_stochSellOK = false;

   if(!UseStochCross && !UseStochClassic) return;
   if(g_stoch == INVALID_HANDLE) return;

   double k[], d[];
   ArraySetAsSeries(k, true);
   ArraySetAsSeries(d, true);

   // index 0 = forming bar (ignored), 1 = last closed, 2 = one before that
   if(CopyBuffer(g_stoch, 0, 0, 3, k) != 3) return; // %K
   if(CopyBuffer(g_stoch, 1, 0, 3, d) != 3) return; // %D

   bool crossedUp   = (k[2] <= d[2]) && (k[1] > d[1]);
   bool crossedDown = (k[2] >= d[2]) && (k[1] < d[1]);
   bool crossLevelBuyOK  = (StochCrossMode == STOCH_CROSS_ANY)  ? true
                         : (StochCrossMode == STOCH_CROSS_OSOB) ? (k[2] < StochOversoldLevel)
                         :                                        (k[1] < StochPullbackLevel);
   bool crossLevelSellOK = (StochCrossMode == STOCH_CROSS_ANY)  ? true
                         : (StochCrossMode == STOCH_CROSS_OSOB) ? (k[2] > StochOverboughtLevel)
                         :                                        (k[1] > StochPullbackLevel);
   bool crossBuy    = UseStochCross && crossedUp   && crossLevelBuyOK;
   bool crossSell   = UseStochCross && crossedDown && crossLevelSellOK;

   bool classicBuy  = UseStochClassic && (k[1] < StochOversoldLevel);
   bool classicSell = UseStochClassic && (k[1] > StochOverboughtLevel);

   g_stochBuyOK  = crossBuy  || classicBuy;
   g_stochSellOK = crossSell || classicSell;
}

bool PassesStochFilter(const bool wantBuy)
{
   if(!UseStochCross && !UseStochClassic) return true; // filter disabled
   return wantBuy ? g_stochBuyOK : g_stochSellOK;
}

bool IsPivotHigh(const double &h[], int idx, int total, int prd)
{
   if(idx - prd < 0 || idx + prd >= total) return false;
   double v = h[idx];
   for(int j = idx - prd; j <= idx + prd; j++)
   { if(j == idx) continue; if(h[j] >= v) return false; }
   return true;
}

bool IsPivotLow(const double &l[], int idx, int total, int prd)
{
   if(idx - prd < 0 || idx + prd >= total) return false;
   double v = l[idx];
   for(int j = idx - prd; j <= idx + prd; j++)
   { if(j == idx) continue; if(l[j] <= v) return false; }
   return true;
}

void ProcessPivot(double price, int pivType, double devPct)
{
   if(!g_haveLastZZ)
   { g_lastZZPrice = price; g_lastZZType = pivType; g_haveLastZZ = true; return; }

   if(pivType == g_lastZZType)
   {
      bool better = (pivType == 1) ? (price > g_lastZZPrice) : (price < g_lastZZPrice);
      if(better)
      { g_lastZZPrice = price; if(g_havePrevZZ) g_newerPrice = g_lastZZPrice; }
      return;
   }

   if(devPct <= 0) return;
   double dev = (g_lastZZPrice != 0.0)
                ? MathAbs(price - g_lastZZPrice) / MathAbs(g_lastZZPrice) * 100.0 : 0.0;
   if(dev >= devPct)
   {
      // the point being retired (old olderPrice) is the swing BEFORE the new
      // leg — same side as the new leg's endpoint. That's the BOS reference.
      if(g_havePrevZZ) { g_prevSwing = g_olderPrice; g_havePrevSwing = true; }

      g_olderPrice = g_lastZZPrice;
      g_lastZZPrice = price; g_lastZZType = pivType;
      g_newerPrice = g_lastZZPrice;
      g_havePrevZZ = true;
   }
}

//====================== ENTRY ======================
void DiagBlock(const string reason)
{
   // A: one line per bar, printed only when price IS inside the golden zone —
   // i.e. exactly the "all conditions look met but no trade" case.
   if(g_lastDiagBar == g_lastBarTime) return;
   g_lastDiagBar = g_lastBarTime;
   Print(Tag(), " | BLOCKED ", reason,
         " | leg=", (g_bullishLeg ? "BULL" : "BEAR"),
         " zoneAnchor=", DoubleToString(g_newerPrice, _Digits),
         " bos=", (g_bosConfirmed ? "Y" : "N"));
}

void TryEnter()
{
   double height = MathAbs(g_newerPrice - g_olderPrice);
   if(height <= 0) return;

   double zLow, zHigh;
   if(g_bullishLeg)
   {
      zLow  = g_newerPrice - height * ZoneLevelMax; // deep pullback
      zHigh = g_newerPrice - height * ZoneLevelMin; // shallow
   }
   else
   {
      zLow  = g_newerPrice + height * ZoneLevelMin; // shallow
      zHigh = g_newerPrice + height * ZoneLevelMax; // deep pullback
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double px  = g_bullishLeg ? ask : bid;

   if(px < zLow || px > zHigh) return; // not inside the golden zone

   // --- price is in the zone: from here every block gets a named reason ---

   if(!CanAttemptEntry())
   { DiagBlock("trade path guard (terminal/broker session/stale tick/retry cooldown)"); return; }

   if(MaxSpreadPips > 0 && (ask - bid) / g_pip > MaxSpreadPips)
   { DiagBlock("spread " + DoubleToString((ask - bid) / g_pip, 1) + " > " + IntegerToString(MaxSpreadPips)); return; }

   if(!PassesBOSFilter())
   { DiagBlock("BOS not confirmed"); return; }

   if(!PassesMAFilter(g_bullishLeg))
   { DiagBlock("MA filter"); return; }

   if(!PassesStochFilter(g_bullishLeg))
   { DiagBlock("Stoch filter (no cross/classic signal on the " + (g_bullishLeg ? "buy" : "sell") + " side this bar)"); return; }

   int    layers; double deepest; bool existingIsBuy;
   CountLayers(layers, deepest, existingIsBuy);

   if(layers >= MaxLayers)
   { DiagBlock("MaxLayers reached (" + IntegerToString(layers) + ")"); return; }

   if(layers > 0 && existingIsBuy != g_bullishLeg)
   { DiagBlock("open layers are opposite direction"); return; }

   if(layers > 0)
   {
      double needed = LayerStepPips * g_pip;
      double gap    = g_bullishLeg ? (deepest - px) : (px - deepest);
      if(gap < needed)
      { DiagBlock("layer step " + DoubleToString(gap / g_pip, 1) + " < " + IntegerToString(LayerStepPips) + " pips"); return; }
   }
   else
   {
      if(g_lastEntryBar == g_lastBarTime)
      { DiagBlock("one first-layer entry per bar"); return; }
      ResetBasket();
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
   count = 0; deepest = 0; existingIsBuy = g_bullishLeg;
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
   if(lots <= 0)
   {
      LogGuardOnce("BLOCKED open — NormalizeLots(LotSize=" +
                   DoubleToString(LotSize, 2) + ") = 0 (check LotSize vs broker min/max/step)");
      return;
   }

   // Order is never sent naked: attach the existing basket lines if we have
   // them, otherwise a first-layer estimate. SyncBasketLines() recomputes the
   // exact levels from real fills right after and pushes them to all tickets.
   double sl = g_basketSL;
   double tp = g_basketTP;

   if(g_bullishLeg)
   {
      if(sl <= 0)
      {
         double entry = ask;
         double structuralSL = g_olderPrice;                     // fibo anchor (swing low)
         double capSL        = entry - MaxStopLossPips * g_pip;  // pip cap
         sl = MathMax(structuralSL, capSL);                      // tighter (closer) wins
         if(sl >= entry) sl = capSL;                             // safety
      }
      if(ask - sl < minStop) sl = ask - minStop;
      if(tp <= 0 && TakeProfitPips > 0) tp = ask + TakeProfitPips * g_pip;
      if(tp > 0 && tp - ask < minStop) tp = ask + minStop;

      sl = NormalizePrice(sl);
      tp = (tp > 0) ? NormalizePrice(tp) : 0.0;
      if(trade.Buy(lots, _Symbol, ask, sl, tp, "AutoFib grid buy"))
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
      {
         double entry = bid;
         double structuralSL = g_olderPrice;                     // fibo anchor (swing high)
         double capSL        = entry + MaxStopLossPips * g_pip;
         sl = MathMin(structuralSL, capSL);
         if(sl <= entry) sl = capSL;
      }
      if(sl - bid < minStop) sl = bid + minStop;
      if(tp <= 0 && TakeProfitPips > 0) tp = bid - TakeProfitPips * g_pip;
      if(tp > 0 && bid - tp < minStop) tp = bid - minStop;

      sl = NormalizePrice(sl);
      tp = (tp > 0) ? NormalizePrice(tp) : 0.0;
      if(trade.Sell(lots, _Symbol, bid, sl, tp, "AutoFib grid sell"))
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
// of all open layers + the current fibo anchor, then ratchets:
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

   // structural anchor only valid while the leg matches the basket direction
   bool   haveStruct = (g_haveLeg && g_bullishLeg == isBuy);
   double slCand, tpCand;

   if(isBuy)
   {
      double capSL = avgEntry - MaxStopLossPips * g_pip;
      slCand = haveStruct ? MathMax(g_olderPrice, capSL) : capSL;   // tighter of the two
      if(slCand >= bid) slCand = capSL;                             // safety
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
      double capSL = avgEntry + MaxStopLossPips * g_pip;
      slCand = haveStruct ? MathMin(g_olderPrice, capSL) : capSL;
      if(slCand <= ask) slCand = capSL;
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
