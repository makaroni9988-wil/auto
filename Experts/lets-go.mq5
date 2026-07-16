//+------------------------------------------------------------------+
//|                                                      lets-go.mq5 |
//|  Modular dual-TF confluence grid EA. Skeleton (grid layering,    |
//|  basket SL/TP, virtual MA SL, session/weekend/news/market guards,|
//|  modify-retry) forked from 3rd-strategy / 2nd-strategy.          |
//|                                                                  |
//|  Entry:                                                          |
//|   - ConfluenceMode: TF1 only, or TF1 AND TF2 (both must agree).  |
//|   - Signal clock = TF1 new bar (no intrabar repaint).            |
//|   - Each TF has its OWN on/off modules. Disabled = ignored.      |
//|   - TRIGGERS (OR if any enabled): StochCross, StochClassic,      |
//|     SrBounce, SrBreakRetest, FibZone. If none enabled, filters   |
//|     alone can form the signal (same idea as 2nd with stoch off). |
//|   - FILTERS (AND if enabled): MacdBias, RsiBias, EmaTrend, Bos.  |
//|   - Fib/BOS are independent toggles (not forced as a pair).      |
//|   - BosMode: ZIGZAG (fibo-gun), FRACTAL (choch-bos style), or     |
//|     BOTH_AND (both engines must agree). No OR mode.              |
//|   - Live MA gate + virtual exits stay on TF1 (InpTF1).           |
//|   - Exits: broker pip-cap always; optional virtual MA SL (live)  |
//|     and/or swing SL (BosMode + tighten-only) — first hit closes. |
//|                                                                  |
//|  TEST ON DEMO / STRATEGY TESTER FIRST. Not a profit guarantee.   |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "4.40"
// v4.40: Swing virtual SL follows BosMode (zigzag / fractal / both-AND),
//        ratchet tighten-only. Virtual MA stays live follow both ways.
// v4.30: Exit toggles — broker pip-cap always; optional virtual MA SL and
//        optional virtual swing/last-low SL. All can be ON; first hit closes.
// v4.20: BosMode chooser: ZIGZAG / FRACTAL / BOTH_AND (no OR — clear which
//        engines must pass). Fractal = choch-bos style structure bias.
// v4.10: Per-TF FibZone (trigger) + Bos (filter) toggles, independent —
//        use fib alone, BOS alone, both, or neither.
// v4.00: Full rewrite onto 2nd/3rd skeleton. Modular 1/2-TF confluence
//        entry with per-TF toggles (Stoch / MACD / RSI / S/R / EMA).
//        Replaces the old ATR martingale always-on grid (v3).

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_LABEL "lets-go"

//====================== INPUTS ======================
input group "===== Confluence (1 or 2 TF) ====="
enum ENUM_CONF_MODE
{
   CONF_TF1_ONLY,     // TF1 only
   CONF_TF1_AND_TF2   // TF1 AND TF2 (both must agree on direction)
};
input ENUM_CONF_MODE   ConfluenceMode = CONF_TF1_AND_TF2; // How many TFs must agree
input ENUM_TIMEFRAMES  InpTF1         = PERIOD_M5;        // TF1 (signal clock + live MA / virtual SL)
input ENUM_TIMEFRAMES  InpTF2         = PERIOD_H1;        // TF2 (used only when AND mode)

input group "===== Direction Master ====="
input bool TradeBuy  = true;  // Allow BUY signals
input bool TradeSell = true;  // Allow SELL signals

input group "===== TF1 Modules (ON = use, OFF = ignore) ====="
input bool TF1_UseStochCross     = true;   // TRIGGER: %K crosses %D
input bool TF1_UseStochClassic   = false;  // TRIGGER: %K in OS/OB zone (no cross)
input bool TF1_UseSrBounce       = false;  // TRIGGER: wick into S/R + reject
input bool TF1_UseSrBreakRetest  = false;  // TRIGGER: break + retest reject
input bool TF1_UseFibZone        = false;  // TRIGGER: price in fib golden zone of zigzag leg
input bool TF1_UseMacdBias       = true;   // FILTER: MACD main >0 buy / <0 sell
input bool TF1_UseRsiBias        = true;   // FILTER: RSI above/below mid
input bool TF1_UseEmaTrend       = false;  // FILTER: fast vs slow EMA side
input bool TF1_UseBos            = false;  // FILTER: BOS (engine chosen by BosMode below)

input group "===== TF2 Modules (ON = use, OFF = ignore) ====="
input bool TF2_UseStochCross     = false;
input bool TF2_UseStochClassic   = false;
input bool TF2_UseSrBounce       = false;
input bool TF2_UseSrBreakRetest  = false;
input bool TF2_UseFibZone        = false;
input bool TF2_UseMacdBias       = true;
input bool TF2_UseRsiBias        = false;
input bool TF2_UseEmaTrend       = true;
input bool TF2_UseBos            = false;

input group "===== Stochastic (shared params, per-TF handles) ====="
input int                 StochKPeriod       = 5;
input int                 StochDPeriod       = 3;
input int                 StochSlowing       = 3;
input ENUM_MA_METHOD      StochMAMethod      = MODE_SMA;
input ENUM_STO_PRICE      StochPriceField    = STO_LOWHIGH;
enum ENUM_STOCH_CROSS_MODE
{
   STOCH_CROSS_PULLBACK, // Cross must land below/above pullback level
   STOCH_CROSS_ANY,      // Any %K/%D cross
   STOCH_CROSS_OSOB      // Cross must come FROM OS (buy) / OB (sell)
};
input ENUM_STOCH_CROSS_MODE StochCrossMode     = STOCH_CROSS_OSOB;
input double              StochPullbackLevel   = 50;
input double              StochOversoldLevel   = 20;
input double              StochOverboughtLevel = 80;

input group "===== RSI / MACD (shared params) ====="
input int                 RSIPeriod        = 14;
input ENUM_APPLIED_PRICE  RSIAppliedPrice  = PRICE_CLOSE;
input double              RSIMidLevel      = 50;
input int                 MACDFastEMA      = 12;
input int                 MACDSlowEMA      = 26;
input int                 MACDSignalPeriod = 9;
input ENUM_APPLIED_PRICE  MACDAppliedPrice = PRICE_CLOSE;

input group "===== EMA Trend Filter (shared params) ====="
enum ENUM_TREND_MODE
{
   TREND_FOLLOW,    // Buy when fast>slow, sell when fast<slow
   TREND_REVERSAL   // Fade: buy when fast<slow, sell when fast>slow
};
input ENUM_TREND_MODE     EmaTrendMode     = TREND_FOLLOW;
input int                 EmaFastPeriod    = 50;
input int                 EmaSlowPeriod    = 200;
input double              EmaMinDiffPips   = 0;   // 0 = any separation counts

input group "===== S/R Pivot Entry (shared params, per-TF levels) ====="
input int    PivotLeftBars     = 5;
input int    PivotRightBars    = 5;
input int    LevelsLookback    = 200;
input double TouchPips         = 50;
input bool   RequireRejectCandle = true;
input int    BreakLookbackBars = 12;

input group "===== Fib / BOS (shared params, per-TF scan) ====="
enum ENUM_BOS_MODE
{
   BOS_ZIGZAG,    // fibo-gun zigzag structural BOS only
   BOS_FRACTAL,   // choch-bos style fractal structure bias only
   BOS_BOTH_AND   // both must agree (strict)
};
input ENUM_BOS_MODE BosMode = BOS_ZIGZAG; // Which BOS engine(s) when UseBos is ON

// --- Zigzag engine (fibo-gun / fibo.mq5) ---
input double FibDeviationMult = 3.0;   // Zigzag: deviation multiplier (ATR-based %)
input int    FibDepth         = 6;     // Zigzag: depth (left/right confirm = Depth/2)
input int    FibATRPeriod     = 10;    // Zigzag: ATR period
input int    FibLookbackBars  = 100;   // Zigzag: bars scanned for current leg
input double FibZoneLevelMin  = 0.382; // FibZone trigger: shallow edge
input double FibZoneLevelMax  = 0.618; // FibZone trigger: deep edge

// --- Fractal engine (choch-bos style) ---
enum ENUM_BOS_BREAK_MODE
{
   BOS_BREAK_CLOSE, // Fractal BOS: candle CLOSE must break level
   BOS_BREAK_WICK   // Fractal BOS: wick/shadow may break level
};
input int                BosFractalPeriod = 2;              // Fractal: bars each side to confirm swing
input ENUM_BOS_BREAK_MODE BosBreakMode    = BOS_BREAK_CLOSE; // Fractal: break confirmation
input int                BosFractalLookback = 200;          // Fractal: bars scanned

input group "===== Moving Average Filter (TF1 live gate + virtual SL) ====="
enum ENUM_MA_CHECK
{
   MA_CHECK_RUNNING,      // Running: live price vs MA right now (+/- buffer)
   MA_CHECK_CANDLE_CLOSE  // Candle close: last close must confirm too (tighter)
};
input bool               UseMAFilter     = true;
input ENUM_MA_CHECK      MACheckMode     = MA_CHECK_RUNNING;
input ENUM_MA_METHOD     MA_Method       = MODE_EMA;
input int                MA_Period       = 34;
input int                MA_Shift        = 0;
input ENUM_APPLIED_PRICE MA_AppliedPrice = PRICE_CLOSE;
input double             MABufferPips    = 100;

input group "===== Stop / Exit (broker pip-cap always; virtuals optional) ====="
// Broker SL line = MaxStopLossPips from avg entry (offline backup) — always.
// Virtual exits are EA-side only; turn on any combo — first hit closes basket.
input bool   UseVirtualMaSL     = true;  // Virtual MA exit on TF1 (InpTF1)
input double SLMABufferPips     = 50;    // MA exit: room beyond MA (0 = at MA touch)
input bool   UseSwingVirtualSL  = false; // Virtual swing/last-low exit (follows BosMode, tighten-only)
input double SwingSLBufferPips  = 0;     // Swing exit: room beyond swing (0 = at swing)

input group "===== Orders / Risk (BASKET lines: shared SL/TP, tighter-only) ====="
input double LotSize         = 0.01;
input int    MaxStopLossPips = 300;
input int    TakeProfitPips  = 3000;
input int    MaxSpreadPips   = 0;
input int    SlippagePoints  = 20;
input long   MagicNumber     = 777;

input group "===== Grid Layering ====="
input int    MaxLayers       = 2;
input int    LayerStepPips   = 200;

input group "===== Basket Take-Profit (pips, trailing) ====="
input bool   UseBasketTP         = true;
input double BasketStartPips     = 200;
input double BasketGivebackPips  = 50;

input group "===== Session Filter (WIB / Jakarta time) ====="
input int  SessionTZOffset       = 7;
input bool UseSession            = true;
input int  SessionStartHour      = 6;
input int  SessionEndHour        = 3;
input bool CloseAtSessionEnd     = true;
input bool UseWeekendFilter      = true;
input int  WeekendStopDayWIB     = 6;
input int  WeekendStopHourWIB    = 3;
input int  WeekendStartDayWIB    = 1;
input int  WeekendStartHourWIB   = 6;
input bool CloseAtWeekend        = true;

input group "===== News Filter (economic calendar) ====="
input bool   UseNewsFilter        = true;
input ENUM_CALENDAR_EVENT_IMPORTANCE NewsMinImportance = CALENDAR_IMPORTANCE_MODERATE;
input string NewsCurrency         = "USD";
input int    NewsMinutesBefore    = 15;
input int    NewsMinutesAfter     = 15;
input bool   CloseAtNews          = true;

input group "===== Market Guard (holidays / early close) ====="
input bool UseBrokerSessionGuard = true;
input int  MaxStaleTickSeconds   = 120;
input int  OrderRetryCooldownSec = 60;

input group "===== Basket SL/TP Modify Retry ====="
input int ModifyRetryMax                = 3;
input int ModifyRetryDelayMs            = 500;
input int MaxConsecutiveRetryCooldownMs = 2000;

//====================== GLOBALS ======================
ENUM_TIMEFRAMES g_tf1;
ENUM_TIMEFRAMES g_tf2;

int g_stoch1 = INVALID_HANDLE, g_rsi1 = INVALID_HANDLE, g_macd1 = INVALID_HANDLE;
int g_emaF1  = INVALID_HANDLE, g_emaS1 = INVALID_HANDLE, g_atr1 = INVALID_HANDLE;
int g_stoch2 = INVALID_HANDLE, g_rsi2 = INVALID_HANDLE, g_macd2 = INVALID_HANDLE;
int g_emaF2  = INVALID_HANDLE, g_emaS2 = INVALID_HANDLE, g_atr2 = INVALID_HANDLE;
int g_ma     = INVALID_HANDLE; // TF1 live MA filter + virtual SL

double   g_pip = 0;
datetime g_lastBarTime  = 0;
datetime g_lastEntryBar = 0;

bool   g_haveSignal  = false;
bool   g_signalIsBuy = false;

bool   g_basketArmed = false;
double g_basketPeak  = 0;

double g_basketSL = 0;
double g_basketTP = 0;

// Swing virtual SL ratchet (tighten-only while basket is open)
bool   g_haveSwingSL = false;
double g_swingSL     = 0;

datetime g_lastEntryFailTime = 0;
datetime g_lastCloseFailTime = 0;
datetime g_lastGuardLogTime  = 0;
datetime g_lastDiagBar       = 0;

bool  g_newsBlackoutCached = false;
ulong g_newsLastCheckMs    = 0;

bool   g_modifyPending     = false;
double g_pendingSL         = 0;
double g_pendingTP         = 0;
ulong  g_lastModifyBurstMs = 0;

//====================== PUSH NOTIFICATIONS ======================
string Tag() { return EA_LABEL + " #" + IntegerToString(MagicNumber) + " " + _Symbol; }
void LogInfo(const string msg) { Print(Tag(), " | ", msg); }

void NotifyPush(const string msg)
{
   if(!SendNotification(msg))
      LogInfo("PUSH FAILED - " + msg);
}

bool TfNeedsStoch(const bool cross, const bool classic) { return (cross || classic); }
bool TfNeedsMacd(const bool on)  { return on; }
bool TfNeedsRsi(const bool on)   { return on; }
bool TfNeedsEma(const bool on)   { return on; }
bool TfNeedsSr(const bool bounce, const bool retest) { return (bounce || retest); }

bool CreateTfHandles(const ENUM_TIMEFRAMES tf,
                     const bool useCross, const bool useClassic,
                     const bool useMacd, const bool useRsi, const bool useEma,
                     const bool useFib, const bool useBos,
                     int &hStoch, int &hRsi, int &hMacd, int &hEmaF, int &hEmaS, int &hAtr,
                     const string label)
{
   if(TfNeedsStoch(useCross, useClassic))
   {
      hStoch = iStochastic(_Symbol, tf, StochKPeriod, StochDPeriod, StochSlowing, StochMAMethod, StochPriceField);
      if(hStoch == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " Stochastic");
         NotifyPush(Tag() + ": INIT FAILED - " + label + " Stochastic");
         return false;
      }
   }
   if(TfNeedsRsi(useRsi))
   {
      hRsi = iRSI(_Symbol, tf, RSIPeriod, RSIAppliedPrice);
      if(hRsi == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " RSI");
         NotifyPush(Tag() + ": INIT FAILED - " + label + " RSI");
         return false;
      }
   }
   if(TfNeedsMacd(useMacd))
   {
      hMacd = iMACD(_Symbol, tf, MACDFastEMA, MACDSlowEMA, MACDSignalPeriod, MACDAppliedPrice);
      if(hMacd == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " MACD");
         NotifyPush(Tag() + ": INIT FAILED - " + label + " MACD");
         return false;
      }
   }
   if(TfNeedsEma(useEma))
   {
      hEmaF = iMA(_Symbol, tf, MathMax(1, EmaFastPeriod), 0, MODE_EMA, PRICE_CLOSE);
      hEmaS = iMA(_Symbol, tf, MathMax(1, EmaSlowPeriod), 0, MODE_EMA, PRICE_CLOSE);
      if(hEmaF == INVALID_HANDLE || hEmaS == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " EMA trend");
         NotifyPush(Tag() + ": INIT FAILED - " + label + " EMA trend");
         return false;
      }
   }
   // ATR needed for FibZone and/or zigzag BOS (not for fractal-only BOS)
   if(useFib || (useBos && BosMode != BOS_FRACTAL))
   {
      hAtr = iATR(_Symbol, tf, MathMax(1, FibATRPeriod));
      if(hAtr == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " ATR (fib/zigzag BOS)");
         NotifyPush(Tag() + ": INIT FAILED - " + label + " ATR");
         return false;
      }
   }
   return true;
}

void ReleaseHandle(int &h)
{
   if(h != INVALID_HANDLE) { IndicatorRelease(h); h = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_tf1 = (InpTF1 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTF1;
   g_tf2 = (InpTF2 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTF2;

   if(MaxLayers < 1)
   {
      LogInfo("INIT FAILED - MaxLayers must be >= 1");
      NotifyPush(Tag() + ": INIT FAILED - MaxLayers must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(PivotLeftBars < 1 || PivotRightBars < 1)
   {
      LogInfo("INIT FAILED - PivotLeftBars/PivotRightBars must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(!TradeBuy && !TradeSell)
   {
      LogInfo("INIT FAILED - TradeBuy and TradeSell both false");
      return(INIT_PARAMETERS_INCORRECT);
   }

   const bool tf1Any = (TF1_UseStochCross || TF1_UseStochClassic || TF1_UseSrBounce ||
                        TF1_UseSrBreakRetest || TF1_UseFibZone || TF1_UseMacdBias ||
                        TF1_UseRsiBias || TF1_UseEmaTrend || TF1_UseBos);
   if(!tf1Any)
   {
      LogInfo("INIT FAILED - TF1 has no modules enabled");
      NotifyPush(Tag() + ": INIT FAILED - TF1 has no modules enabled");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(ConfluenceMode == CONF_TF1_AND_TF2)
   {
      const bool tf2Any = (TF2_UseStochCross || TF2_UseStochClassic || TF2_UseSrBounce ||
                           TF2_UseSrBreakRetest || TF2_UseFibZone || TF2_UseMacdBias ||
                           TF2_UseRsiBias || TF2_UseEmaTrend || TF2_UseBos);
      if(!tf2Any)
      {
         LogInfo("INIT FAILED - TF2 has no modules enabled (required for AND confluence)");
         NotifyPush(Tag() + ": INIT FAILED - TF2 has no modules enabled");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   if(!CreateTfHandles(g_tf1,
                       TF1_UseStochCross, TF1_UseStochClassic,
                       TF1_UseMacdBias, TF1_UseRsiBias, TF1_UseEmaTrend,
                       TF1_UseFibZone, TF1_UseBos,
                       g_stoch1, g_rsi1, g_macd1, g_emaF1, g_emaS1, g_atr1, "TF1"))
      return(INIT_FAILED);

   if(ConfluenceMode == CONF_TF1_AND_TF2)
   {
      if(!CreateTfHandles(g_tf2,
                          TF2_UseStochCross, TF2_UseStochClassic,
                          TF2_UseMacdBias, TF2_UseRsiBias, TF2_UseEmaTrend,
                          TF2_UseFibZone, TF2_UseBos,
                          g_stoch2, g_rsi2, g_macd2, g_emaF2, g_emaS2, g_atr2, "TF2"))
         return(INIT_FAILED);
      if(PeriodSeconds(g_tf2) == PeriodSeconds(g_tf1))
         Print(Tag(), " | NOTE TF1 and TF2 are the same period — confluence adds no extra info.");
   }

   if(UseMAFilter || UseVirtualMaSL)
   {
      g_ma = iMA(_Symbol, g_tf1, MathMax(1, MA_Period), MA_Shift, MA_Method, MA_AppliedPrice);
      if(g_ma == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - TF1 MA handle (live filter / virtual MA SL)");
         NotifyPush(Tag() + ": INIT FAILED - TF1 MA handle");
         return(INIT_FAILED);
      }
   }

   // Swing virtual SL needs TF1 ATR when BosMode uses zigzag (not fractal-only)
   if(UseSwingVirtualSL && BosMode != BOS_FRACTAL && g_atr1 == INVALID_HANDLE)
   {
      g_atr1 = iATR(_Symbol, g_tf1, MathMax(1, FibATRPeriod));
      if(g_atr1 == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - TF1 ATR (swing virtual SL / zigzag)");
         NotifyPush(Tag() + ": INIT FAILED - TF1 ATR for swing SL");
         return(INIT_FAILED);
      }
   }

   g_pip = PipSize();
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   string mode = (ConfluenceMode == CONF_TF1_ONLY) ? "TF1_ONLY" : "TF1_AND_TF2";
   Print(Tag(), " | INIT ", mode, " TF1=", EnumToString(g_tf1),
         " TF2=", EnumToString(g_tf2), " BosMode=", EnumToString(BosMode),
         " | modules TF1[stX=", (int)TF1_UseStochCross, " stC=", (int)TF1_UseStochClassic,
         " srB=", (int)TF1_UseSrBounce, " srR=", (int)TF1_UseSrBreakRetest,
         " fib=", (int)TF1_UseFibZone, " macd=", (int)TF1_UseMacdBias,
         " rsi=", (int)TF1_UseRsiBias, " ema=", (int)TF1_UseEmaTrend,
         " bos=", (int)TF1_UseBos, "] TF2[stX=", (int)TF2_UseStochCross,
         " stC=", (int)TF2_UseStochClassic, " srB=", (int)TF2_UseSrBounce,
         " srR=", (int)TF2_UseSrBreakRetest, " fib=", (int)TF2_UseFibZone,
         " macd=", (int)TF2_UseMacdBias, " rsi=", (int)TF2_UseRsiBias,
         " ema=", (int)TF2_UseEmaTrend, " bos=", (int)TF2_UseBos, "]");

   if(_Period != g_tf1)
      Print(Tag(), " | NOTE chart TF differs from TF1 (", EnumToString(g_tf1),
            "). Signal clock runs on TF1.");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ReleaseHandle(g_stoch1); ReleaseHandle(g_rsi1); ReleaseHandle(g_macd1);
   ReleaseHandle(g_emaF1);  ReleaseHandle(g_emaS1); ReleaseHandle(g_atr1);
   ReleaseHandle(g_stoch2); ReleaseHandle(g_rsi2); ReleaseHandle(g_macd2);
   ReleaseHandle(g_emaF2);  ReleaseHandle(g_emaS2); ReleaseHandle(g_atr2);
   ReleaseHandle(g_ma);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime bt[];
   if(CopyTime(_Symbol, g_tf1, 0, 1, bt) == 1 && bt[0] != g_lastBarTime)
   {
      g_lastBarTime = bt[0];
      UpdateSignal();
   }

   if(ShouldCloseForSchedule())
   {
      CloseAllEA("session/weekend schedule");
      return;
   }

   if(g_modifyPending &&
      GetTickCount64() - g_lastModifyBurstMs >= (ulong)MathMax(0, MaxConsecutiveRetryCooldownMs))
      ProcessBasketModify();

   ManageBasket();
   CheckVirtualMASL();
   CheckSwingVirtualSL();

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
   return (nowMin >= stopMin || nowMin < startMin);
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
   int e = MathMax(1, MathMin(24, SessionEndHour));
   if(s == e) return false;

   MqlDateTime dt;
   GetWIBTime(dt);
   int h = dt.hour;

   if(s < e) return (h >= s && h < e);
   return (h >= s || h < e);
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

//====================== SIGNAL ENGINE (modular per-TF) ======================
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

bool GetActiveSR(const ENUM_TIMEFRAMES tf, double &support, double &resistance)
{
   support = 0; resistance = 0;

   int need = MathMax(LevelsLookback, PivotLeftBars + PivotRightBars + 5);
   MqlRates rates[];
   int got = CopyRates(_Symbol, tf, 0, need, rates);
   if(got < PivotLeftBars + PivotRightBars + 3) return false;

   int total = got;
   int lastCompleted = total - 2;
   int startBar = MathMax(PivotLeftBars, total - LevelsLookback);

   double curHigh = EMPTY_VALUE;
   double curLow  = EMPTY_VALUE;

   for(int i = startBar; i <= lastCompleted; i++)
   {
      int pivotIdx = i - PivotRightBars;
      if(pivotIdx < PivotLeftBars) continue;
      if(pivotIdx + PivotRightBars > lastCompleted) continue;

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

bool HadRecentBreakUp(const double &close[], int barsAvailable, double level, int lookback)
{
   int lb = MathMax(2, lookback);
   for(int i = 2; i <= lb + 1; i++)
   {
      if(i >= barsAvailable) break;
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

bool EvalStoch(const int hStoch, const bool useCross, const bool useClassic,
               bool &buyOK, bool &sellOK)
{
   buyOK = false; sellOK = false;
   if(!useCross && !useClassic) { buyOK = true; sellOK = true; return true; } // not used
   if(hStoch == INVALID_HANDLE) return false;

   double k[], d[];
   ArraySetAsSeries(k, true);
   ArraySetAsSeries(d, true);
   if(CopyBuffer(hStoch, 0, 0, 3, k) != 3) return false;
   if(CopyBuffer(hStoch, 1, 0, 3, d) != 3) return false;

   double k1 = k[1], k2 = k[2];
   double d1 = d[1], d2 = d[2];

   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);
   bool crossLevelBuyOK  = (StochCrossMode == STOCH_CROSS_ANY)  ? true
                         : (StochCrossMode == STOCH_CROSS_OSOB) ? (k2 < StochOversoldLevel)
                         :                                        (k1 < StochPullbackLevel);
   bool crossLevelSellOK = (StochCrossMode == STOCH_CROSS_ANY)  ? true
                         : (StochCrossMode == STOCH_CROSS_OSOB) ? (k2 > StochOverboughtLevel)
                         :                                        (k1 > StochPullbackLevel);

   bool crossBuy    = useCross && crossedUp   && crossLevelBuyOK;
   bool crossSell   = useCross && crossedDown && crossLevelSellOK;
   bool classicBuy  = useClassic && (k1 < StochOversoldLevel);
   bool classicSell = useClassic && (k1 > StochOverboughtLevel);

   buyOK  = crossBuy  || classicBuy;
   sellOK = crossSell || classicSell;
   return true;
}

bool EvalMacd(const int hMacd, const bool useIt, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!useIt) return true;
   if(hMacd == INVALID_HANDLE) return false;

   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(hMacd, 0, 0, 2, m) != 2) return false;
   buyOK  = (m[1] > 0);
   sellOK = (m[1] < 0);
   return true;
}

bool EvalRsi(const int hRsi, const bool useIt, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!useIt) return true;
   if(hRsi == INVALID_HANDLE) return false;

   double r[];
   ArraySetAsSeries(r, true);
   if(CopyBuffer(hRsi, 0, 0, 2, r) != 2) return false;
   buyOK  = (r[1] > RSIMidLevel);
   sellOK = (r[1] < RSIMidLevel);
   return true;
}

bool EvalEmaTrend(const int hFast, const int hSlow, const bool useIt, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!useIt) return true;
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE) return false;

   double f[], s[];
   ArraySetAsSeries(f, true);
   ArraySetAsSeries(s, true);
   if(CopyBuffer(hFast, 0, 1, 1, f) != 1) return false;
   if(CopyBuffer(hSlow, 0, 1, 1, s) != 1) return false;

   double diff = f[0] - s[0];
   double thr  = MathMax(0.0, EmaMinDiffPips) * g_pip;
   int dir = 0; // +1 up, -1 down, 0 range
   if(diff >  thr) dir = 1;
   if(diff < -thr) dir = -1;

   if(dir == 0) { buyOK = false; sellOK = false; return true; } // ranging = no pass when filter on

   if(EmaTrendMode == TREND_FOLLOW)
   {
      buyOK  = (dir > 0);
      sellOK = (dir < 0);
   }
   else
   {
      buyOK  = (dir < 0);
      sellOK = (dir > 0);
   }
   return true;
}

bool EvalSr(const ENUM_TIMEFRAMES tf, const bool useBounce, const bool useRetest,
            bool &buyOK, bool &sellOK)
{
   buyOK = false; sellOK = false;
   if(!useBounce && !useRetest) { buyOK = true; sellOK = true; return true; }

   double support = 0, resistance = 0;
   if(!GetActiveSR(tf, support, resistance)) return false;
   if(support <= 0 || resistance <= 0 || support >= resistance) return false;

   double touch = MathMax(0.0, TouchPips) * g_pip;

   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);

   int need = MathMax(BreakLookbackBars + 4, 6);
   if(CopyOpen (_Symbol, tf, 0, need, o) != need) return false;
   if(CopyHigh (_Symbol, tf, 0, need, h) != need) return false;
   if(CopyLow  (_Symbol, tf, 0, need, l) != need) return false;
   if(CopyClose(_Symbol, tf, 0, need, c) != need) return false;

   double o1 = o[1], h1 = h[1], l1 = l[1], c1 = c[1];
   bool bullReject = (c1 > o1);
   bool bearReject = (c1 < o1);

   bool bounceBuy  = (l1 <= support + touch) && (c1 > support) &&
                     (!RequireRejectCandle || bullReject);
   bool bounceSell = (h1 >= resistance - touch) && (c1 < resistance) &&
                     (!RequireRejectCandle || bearReject);

   bool retestBuy  = HadRecentBreakUp(c, need, resistance, BreakLookbackBars) &&
                     (l1 <= resistance + touch) && (c1 > resistance) &&
                     (!RequireRejectCandle || bullReject);
   bool retestSell = HadRecentBreakDown(c, need, support, BreakLookbackBars) &&
                     (h1 >= support - touch) && (c1 < support) &&
                     (!RequireRejectCandle || bearReject);

   if(useBounce)
   {
      buyOK  = buyOK  || bounceBuy;
      sellOK = sellOK || bounceSell;
   }
   if(useRetest)
   {
      buyOK  = buyOK  || retestBuy;
      sellOK = sellOK || retestSell;
   }
   return true;
}


//====================== FIB / BOS ENGINES (per-TF) ======================
// Zigzag: ATR-deviation pivots (fibo-gun / fibo.mq5). Structural BOS =
// leg endpoint broke previous same-side swing.
// Fractal: choch-bos style fractal swings + close/wick break → trend bias.
// BosMode selects ZIGZAG / FRACTAL / BOTH_AND (no OR).

bool IsFibPivotHigh(const double &h[], int idx, int total, int prd)
{
   if(idx - prd < 0 || idx + prd >= total) return false;
   double v = h[idx];
   for(int j = idx - prd; j <= idx + prd; j++)
   { if(j == idx) continue; if(h[j] >= v) return false; }
   return true;
}

bool IsFibPivotLow(const double &l[], int idx, int total, int prd)
{
   if(idx - prd < 0 || idx + prd >= total) return false;
   double v = l[idx];
   for(int j = idx - prd; j <= idx + prd; j++)
   { if(j == idx) continue; if(l[j] <= v) return false; }
   return true;
}

void FibProcessPivot(double price, int pivType, double devPct,
                     bool &haveLastZZ, double &lastZZPrice, int &lastZZType,
                     bool &havePrevZZ, double &olderPrice, double &newerPrice,
                     bool &havePrevSwing, double &prevSwing)
{
   if(!haveLastZZ)
   { lastZZPrice = price; lastZZType = pivType; haveLastZZ = true; return; }

   if(pivType == lastZZType)
   {
      bool better = (pivType == 1) ? (price > lastZZPrice) : (price < lastZZPrice);
      if(better)
      { lastZZPrice = price; if(havePrevZZ) newerPrice = lastZZPrice; }
      return;
   }

   if(devPct <= 0) return;
   double dev = (lastZZPrice != 0.0)
                ? MathAbs(price - lastZZPrice) / MathAbs(lastZZPrice) * 100.0 : 0.0;
   if(dev >= devPct)
   {
      if(havePrevZZ) { prevSwing = olderPrice; havePrevSwing = true; }
      olderPrice  = lastZZPrice;
      lastZZPrice = price; lastZZType = pivType;
      newerPrice  = lastZZPrice;
      havePrevZZ  = true;
   }
}

// Scan zigzag leg on tf. Returns false only on data failure.
bool ScanFibLeg(const ENUM_TIMEFRAMES tf, const int hAtr,
                bool &haveLeg, bool &bullishLeg,
                double &olderPrice, double &newerPrice,
                bool &bosConfirmed)
{
   haveLeg = false; bullishLeg = false;
   olderPrice = 0; newerPrice = 0; bosConfirmed = false;
   if(hAtr == INVALID_HANDLE) return false;

   int prd  = MathMax(1, FibDepth / 2);
   int bars = (int)MathMin((long)FibLookbackBars, (long)Bars(_Symbol, tf));
   if(bars < 2 * prd + 3) return false;

   double high[], low[], close[], atr[];
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(atr,   false);

   if(CopyHigh (_Symbol, tf, 0, bars, high)  < bars) return false;
   if(CopyLow  (_Symbol, tf, 0, bars, low)   < bars) return false;
   if(CopyClose(_Symbol, tf, 0, bars, close) < bars) return false;
   if(CopyBuffer(hAtr, 0, 0, bars, atr)      < bars) return false;

   bool haveLastZZ = false, havePrevZZ = false, havePrevSwing = false;
   double lastZZPrice = 0, prevSwing = 0;
   int lastZZType = -1;
   olderPrice = 0; newerPrice = 0;

   for(int i = 2 * prd; i < bars; i++)
   {
      int pivotIdx = i - prd;
      if(pivotIdx < prd) continue;

      double atrVal = atr[pivotIdx];
      double devPct = (close[pivotIdx] != 0.0 && atrVal > 0.0)
                      ? (atrVal / close[pivotIdx]) * 100.0 * FibDeviationMult : 0.0;

      bool ph = IsFibPivotHigh(high, pivotIdx, bars, prd);
      bool pl = IsFibPivotLow (low,  pivotIdx, bars, prd);

      if(ph) FibProcessPivot(high[pivotIdx], 1, devPct,
                             haveLastZZ, lastZZPrice, lastZZType,
                             havePrevZZ, olderPrice, newerPrice,
                             havePrevSwing, prevSwing);
      if(pl) FibProcessPivot(low[pivotIdx],  0, devPct,
                             haveLastZZ, lastZZPrice, lastZZType,
                             havePrevZZ, olderPrice, newerPrice,
                             havePrevSwing, prevSwing);
   }

   if(!havePrevZZ) return true;
   haveLeg    = true;
   bullishLeg = (newerPrice > olderPrice);

   if(havePrevSwing)
   {
      if(bullishLeg) bosConfirmed = (newerPrice > prevSwing);
      else           bosConfirmed = (newerPrice < prevSwing);
   }
   return true;
}

bool EvalFibZone(const ENUM_TIMEFRAMES tf, const int hAtr, const bool useIt,
                 bool &buyOK, bool &sellOK)
{
   buyOK = false; sellOK = false;
   if(!useIt) { buyOK = true; sellOK = true; return true; }

   bool haveLeg = false, bullish = false, bos = false;
   double olderP = 0, newerP = 0;
   if(!ScanFibLeg(tf, hAtr, haveLeg, bullish, olderP, newerP, bos)) return false;
   if(!haveLeg) return true;

   double height = MathAbs(newerP - olderP);
   if(height <= 0) return true;

   double zLow, zHigh;
   if(bullish)
   {
      zLow  = newerP - height * FibZoneLevelMax;
      zHigh = newerP - height * FibZoneLevelMin;
   }
   else
   {
      zLow  = newerP + height * FibZoneLevelMin;
      zHigh = newerP + height * FibZoneLevelMax;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double px  = bullish ? ask : bid;
   if(px < zLow || px > zHigh) return true; // not in zone

   if(bullish) buyOK = true;
   else        sellOK = true;
   return true;
}

// Replay choch-bos style fractal structure on closed bars.
// buyOK/sellOK = current structure bias after last break.
// swingHigh/swingLow = latest active fractal levels (0 if none).
bool ScanFractalStructure(const ENUM_TIMEFRAMES tf,
                          bool &buyOK, bool &sellOK,
                          double &swingHigh, double &swingLow)
{
   buyOK = false; sellOK = false;
   swingHigh = 0; swingLow = 0;

   int period = MathMax(1, BosFractalPeriod);
   int bars   = MathMax(BosFractalLookback, period * 4 + 10);
   bars = (int)MathMin((long)bars, (long)Bars(_Symbol, tf));
   if(bars < period * 2 + 3) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, tf, 0, bars, rates);
   if(copied <= period * 2 + 2) return false;

   bool highValid = false, highBroken = false;
   bool lowValid  = false, lowBroken  = false;
   double highPrice = 0, lowPrice = 0;
   int trend = 0; // +1 bull, -1 bear, 0 neutral

   int lastClosed = copied - 2;
   for(int i = period; i <= lastClosed; i++)
   {
      double breakHighPrice = (BosBreakMode == BOS_BREAK_CLOSE) ? rates[i].close : rates[i].high;
      double breakLowPrice  = (BosBreakMode == BOS_BREAK_CLOSE) ? rates[i].close : rates[i].low;

      if(highValid && !highBroken && breakHighPrice > highPrice)
      {
         highBroken = true;
         trend = 1;
         lowValid = false;
      }
      else if(lowValid && !lowBroken && breakLowPrice < lowPrice)
      {
         lowBroken = true;
         trend = -1;
         highValid = false;
      }

      int pivot = i - period;
      if(pivot < period) continue;

      bool isFH = true;
      for(int k = pivot - period; k <= pivot + period; k++)
      {
         if(k == pivot) continue;
         if(k < 0 || k >= copied || rates[k].high >= rates[pivot].high) { isFH = false; break; }
      }
      if(isFH)
      {
         if(!highValid || rates[pivot].high > highPrice || highBroken)
         {
            highValid = true; highBroken = false;
            highPrice = rates[pivot].high;
         }
      }

      bool isFL = true;
      for(int k = pivot - period; k <= pivot + period; k++)
      {
         if(k == pivot) continue;
         if(k < 0 || k >= copied || rates[k].low <= rates[pivot].low) { isFL = false; break; }
      }
      if(isFL)
      {
         if(!lowValid || rates[pivot].low < lowPrice || lowBroken)
         {
            lowValid = true; lowBroken = false;
            lowPrice = rates[pivot].low;
         }
      }
   }

   if(trend > 0) buyOK = true;
   if(trend < 0) sellOK = true;
   if(highValid) swingHigh = highPrice;
   if(lowValid)  swingLow  = lowPrice;
   return true;
}

bool ScanFractalBos(const ENUM_TIMEFRAMES tf, bool &buyOK, bool &sellOK)
{
   double sh = 0, sl = 0;
   return ScanFractalStructure(tf, buyOK, sellOK, sh, sl);
}

bool EvalZigzagBos(const ENUM_TIMEFRAMES tf, const int hAtr,
                   bool &buyOK, bool &sellOK)
{
   buyOK = false; sellOK = false;
   bool haveLeg = false, bullish = false, bos = false;
   double olderP = 0, newerP = 0;
   if(!ScanFibLeg(tf, hAtr, haveLeg, bullish, olderP, newerP, bos)) return false;
   if(!haveLeg || !bos) return true;
   buyOK  = bullish;
   sellOK = !bullish;
   return true;
}

bool EvalBos(const ENUM_TIMEFRAMES tf, const int hAtr, const bool useIt,
             bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!useIt) return true;

   if(BosMode == BOS_ZIGZAG)
      return EvalZigzagBos(tf, hAtr, buyOK, sellOK);

   if(BosMode == BOS_FRACTAL)
      return ScanFractalBos(tf, buyOK, sellOK);

   // BOS_BOTH_AND — both engines must agree on the same side
   bool zBuy = false, zSell = false, fBuy = false, fSell = false;
   if(!EvalZigzagBos(tf, hAtr, zBuy, zSell)) return false;
   if(!ScanFractalBos(tf, fBuy, fSell)) return false;
   buyOK  = (zBuy  && fBuy);
   sellOK = (zSell && fSell);
   return true;
}

// Evaluate one TF. Triggers OR among enabled; filters AND among enabled.
// If no triggers enabled, enabled filters alone may form the signal.
bool EvalTf(const ENUM_TIMEFRAMES tf,
            const bool useCross, const bool useClassic,
            const bool useBounce, const bool useRetest, const bool useFib,
            const bool useMacd, const bool useRsi, const bool useEma, const bool useBos,
            const int hStoch, const int hRsi, const int hMacd,
            const int hEmaF, const int hEmaS, const int hAtr,
            bool &outBuy, bool &outSell)
{
   outBuy = false; outSell = false;

   bool anyTrigger = (useCross || useClassic || useBounce || useRetest || useFib);
   bool anyFilter  = (useMacd || useRsi || useEma || useBos);
   if(!anyTrigger && !anyFilter) return true; // nothing enabled -> neutral (caller skips)

   bool trigBuy = true, trigSell = true;
   if(anyTrigger)
   {
      trigBuy = false; trigSell = false;

      bool stB = false, stS = false, srB = false, srS = false, fibB = false, fibS = false;
      bool gotStoch = false, gotSr = false, gotFib = false;

      if(useCross || useClassic)
      {
         if(!EvalStoch(hStoch, useCross, useClassic, stB, stS)) return false;
         gotStoch = true;
      }
      if(useBounce || useRetest)
      {
         if(!EvalSr(tf, useBounce, useRetest, srB, srS)) return false;
         gotSr = true;
      }
      if(useFib)
      {
         if(!EvalFibZone(tf, hAtr, true, fibB, fibS)) return false;
         gotFib = true;
      }

      // OR across enabled trigger families
      if(gotStoch) { trigBuy |= stB; trigSell |= stS; }
      if(gotSr)    { trigBuy |= srB; trigSell |= srS; }
      if(gotFib)   { trigBuy |= fibB; trigSell |= fibS; }
   }

   bool macdBuy = true, macdSell = true;
   bool rsiBuy  = true, rsiSell  = true;
   bool emaBuy  = true, emaSell  = true;
   bool bosBuy  = true, bosSell  = true;
   if(!EvalMacd(hMacd, useMacd, macdBuy, macdSell)) return false;
   if(!EvalRsi(hRsi, useRsi, rsiBuy, rsiSell)) return false;
   if(!EvalEmaTrend(hEmaF, hEmaS, useEma, emaBuy, emaSell)) return false;
   if(!EvalBos(tf, hAtr, useBos, bosBuy, bosSell)) return false;

   outBuy  = trigBuy  && macdBuy  && rsiBuy  && emaBuy  && bosBuy;
   outSell = trigSell && macdSell && rsiSell && emaSell && bosSell;
   return true;
}

void UpdateSignal()
{
   g_haveSignal  = false;
   g_signalIsBuy = false;

   bool b1 = false, s1 = false;
   if(!EvalTf(g_tf1,
              TF1_UseStochCross, TF1_UseStochClassic,
              TF1_UseSrBounce, TF1_UseSrBreakRetest, TF1_UseFibZone,
              TF1_UseMacdBias, TF1_UseRsiBias, TF1_UseEmaTrend, TF1_UseBos,
              g_stoch1, g_rsi1, g_macd1, g_emaF1, g_emaS1, g_atr1,
              b1, s1))
      return;

   bool b2 = true, s2 = true; // ignored in TF1_ONLY
   if(ConfluenceMode == CONF_TF1_AND_TF2)
   {
      b2 = false; s2 = false;
      if(!EvalTf(g_tf2,
                 TF2_UseStochCross, TF2_UseStochClassic,
                 TF2_UseSrBounce, TF2_UseSrBreakRetest, TF2_UseFibZone,
                 TF2_UseMacdBias, TF2_UseRsiBias, TF2_UseEmaTrend, TF2_UseBos,
                 g_stoch2, g_rsi2, g_macd2, g_emaF2, g_emaS2, g_atr2,
                 b2, s2))
         return;
   }

   bool buyOK  = b1 && b2;
   bool sellOK = s1 && s2;

   // Conflict (both sides) or neither -> no trade
   if(TradeBuy && buyOK && !(TradeSell && sellOK))
   { g_haveSignal = true; g_signalIsBuy = true; return; }
   if(TradeSell && sellOK && !(TradeBuy && buyOK))
   { g_haveSignal = true; g_signalIsBuy = false; return; }
}


//====================== ENTRY ======================
void DiagBlock(const string reason)
{
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
      ResetBasketLines();
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
         sl = ask - MaxStopLossPips * g_pip;             // broker line = fixed pip cap (offline backup)
      if(ask - sl < minStop) sl = ask - minStop;
      if(tp <= 0 && TakeProfitPips > 0) tp = ask + TakeProfitPips * g_pip;
      if(tp > 0 && tp - ask < minStop) tp = ask + minStop;

      sl = NormalizePrice(sl);
      tp = (tp > 0) ? NormalizePrice(tp) : 0.0;
      if(trade.Buy(lots, _Symbol, ask, sl, tp, "lets-go grid buy"))
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
         sl = bid + MaxStopLossPips * g_pip;             // broker line = fixed pip cap (offline backup)
      if(sl - bid < minStop) sl = bid + minStop;
      if(tp <= 0 && TakeProfitPips > 0) tp = bid - TakeProfitPips * g_pip;
      if(tp > 0 && bid - tp < minStop) tp = bid - minStop;

      sl = NormalizePrice(sl);
      tp = (tp > 0) ? NormalizePrice(tp) : 0.0;
      if(trade.Sell(lots, _Symbol, bid, sl, tp, "lets-go grid sell"))
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
   g_haveSwingSL   = false;
   g_swingSL       = 0;
}

//====================== VIRTUAL EXITS (EA-side, never sent to broker) ======================
// Broker pip-cap SL always stays as offline backup.
// Optional virtual MA and/or swing exits — first one that hits closes the basket.
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

void CheckVirtualMASL()
{
   if(!UseVirtualMaSL) return;

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
                DoubleToString(maSL, _Digits) + " (TF1 MA " + (isBuy ? "-" : "+") + " " + DoubleToString(SLMABufferPips, 1) + " pips) — closing basket");
   CloseAllEA("virtual MA SL");
}

// Resolve TF1 swing anchor for the open basket direction, following BosMode.
// Zigzag: fibo-gun leg start (olderPrice) when leg matches basket side.
// Fractal: active fractal low (buy) / high (sell) from choch-bos style scan.
// BOTH_AND: both must be available; use the TIGHTER of the two.
bool GetSwingAnchorByBosMode(const bool isBuy, double &swing, string &engineTag)
{
   swing = 0;
   engineTag = "";

   bool needZ = (BosMode == BOS_ZIGZAG || BosMode == BOS_BOTH_AND);
   bool needF = (BosMode == BOS_FRACTAL || BosMode == BOS_BOTH_AND);

   double zSwing = 0;
   bool   haveZ  = false;
   if(needZ)
   {
      bool haveLeg = false, bullish = false, bos = false;
      double olderP = 0, newerP = 0;
      if(!ScanFibLeg(g_tf1, g_atr1, haveLeg, bullish, olderP, newerP, bos))
         return false;
      if(haveLeg && olderP > 0)
      {
         if(isBuy && bullish)  { zSwing = olderP; haveZ = true; }
         if(!isBuy && !bullish){ zSwing = olderP; haveZ = true; }
      }
   }

   double fSwing = 0;
   bool   haveF  = false;
   if(needF)
   {
      bool bOK = false, sOK = false;
      double sh = 0, sl = 0;
      if(!ScanFractalStructure(g_tf1, bOK, sOK, sh, sl))
         return false;
      if(isBuy && sl > 0)  { fSwing = sl; haveF = true; }
      if(!isBuy && sh > 0) { fSwing = sh; haveF = true; }
   }

   if(BosMode == BOS_ZIGZAG)
   {
      if(!haveZ) return false;
      swing = zSwing; engineTag = "zigzag";
      return true;
   }
   if(BosMode == BOS_FRACTAL)
   {
      if(!haveF) return false;
      swing = fSwing; engineTag = "fractal";
      return true;
   }

   // BOTH_AND — both required, then tighter wins
   if(!haveZ || !haveF) return false;
   if(isBuy) swing = MathMax(zSwing, fSwing); // higher stop = tighter for buys
   else      swing = MathMin(zSwing, fSwing); // lower stop = tighter for sells
   engineTag = "both-AND";
   return true;
}

// Swing / last-low(high): virtual, follows BosMode, ratchet tighten-only.
// BUY exits if bid <= swingSL; SELL if ask >= swingSL (buffer baked into line).
void CheckSwingVirtualSL()
{
   if(!UseSwingVirtualSL) return;

   int layers; double deepest; bool isBuy;
   CountLayers(layers, deepest, isBuy);
   if(layers == 0)
   {
      g_haveSwingSL = false;
      g_swingSL = 0;
      return;
   }

   double rawSwing = 0;
   string engineTag = "";
   if(!GetSwingAnchorByBosMode(isBuy, rawSwing, engineTag)) return;
   if(rawSwing <= 0) return;

   double buffer = MathMax(0.0, SwingSLBufferPips) * g_pip;
   double cand   = isBuy ? (rawSwing - buffer) : (rawSwing + buffer);

   // Tighten-only ratchet while basket is open
   if(!g_haveSwingSL)
   {
      g_swingSL = cand;
      g_haveSwingSL = true;
   }
   else
   {
      if(isBuy) g_swingSL = MathMax(g_swingSL, cand); // only up
      else      g_swingSL = MathMin(g_swingSL, cand); // only down
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool breached = isBuy ? (bid <= g_swingSL) : (ask >= g_swingSL);
   if(!breached) return;

   LogGuardOnce("EXIT virtual swing SL hit " + (isBuy ? "bid " + DoubleToString(bid, _Digits) + " <= " : "ask " + DoubleToString(ask, _Digits) + " >= ") +
                DoubleToString(g_swingSL, _Digits) +
                " (TF1 " + engineTag + " BosMode=" + EnumToString(BosMode) +
                ", raw swing " + DoubleToString(rawSwing, _Digits) + ", tighten-only) — closing basket");
   CloseAllEA("virtual swing SL");
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
   g_haveSwingSL = false;
   g_swingSL     = 0;
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
   if(CopyClose(_Symbol, g_tf1, 1, 1, c) != 1) return false;

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