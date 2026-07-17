//+------------------------------------------------------------------+
//|                                                      lets-go.mq5 |
//|           Modular dual-TF confluence grid EA                     |
//|                                                                  |
//|  Skeleton: grid, basket SL/TP, virtual exits, session/weekend/   |
//|  news/market guards, modify-retry.                               |
//|                                                                  |
//|  Entry  : TF1 = entry (every ON module must pass — all AND).     |
//|           TF2 = bias (same AND rule; used only in AND mode).     |
//|           Open when TF1 ready, and TF2 ready if AND mode.        |
//|           Signal clock = TF1 new bar.                            |
//|           Within Stoch: cross OR classic. Within S/R: bounce OR  |
//|           break-retest. Families AND with each other.            |
//|           MA trend: Single (m1) / Double (m2), method choosable  |
//|           — separate from live MA chip / MaSL.                   |
//|           BosMode / SwingSLMode independent. FibZone may arm on  |
//|           bar and re-check zone every tick (gun/bomb style).     |
//|  Exits  : broker pip-cap; optional virtual MaSL and/or SwSL.     |
//|  Panel  : chip toggles (top-left), GV memory.                    |
//|  Journal: Tag "lets-go #magic SYMBOL". Push INIT/BASKET only.    |
//|                                                                  |
//|  TEST ON DEMO / STRATEGY TESTER FIRST. Not a profit guarantee.   |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "4.93"

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_LABEL "lets-go"

//====================== INPUTS ======================
input group "===== Confluence (TF1 entry, optional TF2 bias) ====="
enum ENUM_CONF_MODE
{
   CONF_TF1_ONLY,     // TF1 entry only
   CONF_TF1_AND_TF2   // TF1 entry AND TF2 bias must agree
};
input ENUM_CONF_MODE   ConfluenceMode = CONF_TF1_ONLY; // TF1 only, or TF1+TF2
input ENUM_TIMEFRAMES  InpTF1         = PERIOD_M30;    // TF1 entry (signal clock + virtual exits)
input ENUM_TIMEFRAMES  InpTF2         = PERIOD_H1;     // TF2 bias (AND mode only)

input group "===== Direction Master ====="
input bool TradeBuy  = true;  // Allow BUY
input bool TradeSell = true;  // Allow SELL

input group "===== TF1 Entry (every ON module must pass — all AND) ====="
// Stoch: cross OR classic if both on. S/R: bounce OR retest if both on.
// Those families then AND with Fib / MACD / RSI / MaTrend / BOS.
input bool TF1_UseStochCross     = false; // Stoch cross
input bool TF1_UseStochClassic   = false; // Stoch classic OS/OB
input bool TF1_UseSrBounce       = false; // S/R bounce
input bool TF1_UseSrBreakRetest  = false; // S/R break-retest
input bool TF1_UseFibZone        = false; // Fib golden zone
input bool TF1_UseMacdBias       = false; // MACD bias
input bool TF1_UseRsiBias        = false; // RSI bias
input bool TF1_UseMaTrend        = false; // MA trend (m1/m2)
input bool TF1_UseBos            = true;  // BOS (see BosMode)

input group "===== TF2 Bias (every ON module must pass — all AND) ====="
// Ignored when ConfluenceMode = TF1_ONLY. Same module set as TF1 entry.
input bool TF2_UseStochCross     = false; // Stoch cross
input bool TF2_UseStochClassic   = false; // Stoch classic OS/OB
input bool TF2_UseSrBounce       = false; // S/R bounce
input bool TF2_UseSrBreakRetest  = false; // S/R break-retest
input bool TF2_UseFibZone        = false; // Fib golden zone
input bool TF2_UseMacdBias       = false; // MACD bias
input bool TF2_UseRsiBias        = false; // RSI bias
input bool TF2_UseMaTrend        = false; // MA trend (m1/m2)
input bool TF2_UseBos            = false; // BOS (see BosMode)

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

input group "===== MA Trend Filter (shared params; NOT the live MA chip) ====="
// Panel chip cycles OFF / Single (m1) / Double (m2) per TF.
enum ENUM_MA_TREND_STYLE
{
   MA_TREND_SINGLE, // Price vs one MA
   MA_TREND_DOUBLE  // Fast vs slow MA
};
enum ENUM_TREND_MODE
{
   TREND_FOLLOW,    // Single: price vs MA side. Double: fast vs slow side
   TREND_REVERSAL   // Fade the follow rule
};
input ENUM_MA_TREND_STYLE MaTrendStyle      = MA_TREND_DOUBLE; // Default style when module ON
input ENUM_MA_METHOD      MaTrendMethod     = MODE_EMA;        // SMA / EMA / SMMA / LWMA
input ENUM_APPLIED_PRICE  MaTrendPrice      = PRICE_CLOSE;
input int                 MaTrendPeriod     = 34;              // Single MA period
input int                 MaTrendFastPeriod = 13;              // Double: fast period
input int                 MaTrendSlowPeriod = 34;              // Double: slow period
input ENUM_TREND_MODE     MaTrendMode       = TREND_FOLLOW;    // Follow / Reversal
input double              MaTrendMinDiffPips = 0;              // 0 = any separation counts

input group "===== S/R Pivot Entry (shared params, per-TF levels) ====="
input int    PivotLeftBars       = 5;
input int    PivotRightBars      = 5;
input int    LevelsLookback      = 200;
input double TouchPips           = 50;
input bool   RequireRejectCandle = true;
input int    BreakLookbackBars   = 12;

input group "===== Fib / BOS entry (shared params, per-TF scan) ====="
enum ENUM_BOS_MODE
{
   BOS_ZIGZAG,    // Zigzag structural BOS (fibo-gun)
   BOS_FRACTAL,   // Fractal structure (choch-bos style)
   BOS_BOTH_AND   // Both engines must agree
};
input ENUM_BOS_MODE BosMode = BOS_FRACTAL; // Entry BOS engine
enum ENUM_BOS_SIGNAL_MODE
{
   BOS_SIGNAL_EVENT, // Enter only on the bar that breaks structure
   BOS_SIGNAL_BIAS   // Stay buy/sell every bar while bias holds
};
input ENUM_BOS_SIGNAL_MODE BosSignalMode = BOS_SIGNAL_EVENT; // BOS entry style

input double FibDeviationMult = 3.0;   // Zigzag: ATR deviation multiplier
input int    FibDepth         = 6;     // Zigzag: depth (confirm = Depth/2)
input int    FibATRPeriod     = 10;    // Zigzag: ATR period
input int    FibLookbackBars  = 100;   // Zigzag: bars scanned
input double FibZoneLevelMin  = 0.382; // FibZone: shallow edge
input double FibZoneLevelMax  = 0.618; // FibZone: deep edge

enum ENUM_BOS_BREAK_MODE
{
   BOS_BREAK_CLOSE, // Fractal: close must break level
   BOS_BREAK_WICK   // Fractal: wick may break level
};
input int                 BosFractalPeriod   = 3;              // Fractal: bars each side
input ENUM_BOS_BREAK_MODE BosBreakMode       = BOS_BREAK_WICK; // Fractal break type
input int                 BosFractalLookback = 200;            // Fractal: bars scanned

input group "===== Moving Average (TF1 live gate + optional virtual SL) ====="
enum ENUM_MA_CHECK
{
   MA_CHECK_RUNNING,      // Live price vs MA (+/- buffer)
   MA_CHECK_CANDLE_CLOSE  // Last close must confirm too
};
input bool               UseMAFilter     = false; // Live MA entry filter
input ENUM_MA_CHECK      MACheckMode     = MA_CHECK_RUNNING;
input ENUM_MA_METHOD     MA_Method       = MODE_EMA;
input int                MA_Period       = 34;
input int                MA_Shift        = 0;
input ENUM_APPLIED_PRICE MA_AppliedPrice = PRICE_CLOSE;
input double             MABufferPips    = 100;

input group "===== Stop / Exit ====="
// Broker SL = hard pip cap. Virtual MA / swing SL are optional; first hit closes.
input bool         UseVirtualMaSL    = false;      // Virtual MA stop (live follow)
input double       SLMABufferPips    = 50;         // MA SL buffer (pips)

input bool         UseSwingVirtualSL = true;       // Virtual swing stop (tighten-only)
input ENUM_BOS_MODE SwingSLMode      = BOS_FRACTAL; // Swing SL engine (independent of BosMode)
input double       SwingSLBufferPips = 50;         // Air beyond swing (pips)

input group "===== Orders / Risk (basket lines: shared SL/TP, tighter-only) ====="
input double LotSize         = 0.01;
input int    MaxStopLossPips = 500;   // Hard broker SL (pips)
input int    TakeProfitPips  = 3000;  // Broker TP (pips)
input int    MaxSpreadPips   = 0;     // 0 = no spread filter
input int    SlippagePoints  = 20;
input long   MagicNumber     = 778899;

input group "===== Grid Layering ====="
input int    MaxLayers       = 1;     // Max open layers (same magic)
input int    LayerStepPips   = 200;   // Min adverse move before next layer

input group "===== Basket Take-Profit (pips, trailing) ====="
input bool   UseBasketTP         = true;
input double BasketStartPips     = 500; // Arm trail after this open profit
input double BasketGivebackPips  = 200; // Pullback from peak before close

input group "===== Basket SL/TP Modify Retry ====="
input int ModifyRetryMax                = 3;
input int ModifyRetryDelayMs            = 500;
input int MaxConsecutiveRetryCooldownMs = 2000;

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

input group "===== Chip Panel (click toggles) ====="
input bool ShowPanel             = true;  // Show chip panel (top-left)
input int  PanelInsetX           = 3;     // Inset from left
input int  PanelInsetY           = 25;    // Inset from top
input bool PanelRemember         = true;  // Remember toggles (GV)
input bool PanelStartCollapsed   = false; // Start minimized
input uint PanelClickGuardMs     = 200;   // Double-click guard (ms)

input group "===== Logging ====="
input bool InpDebugLog = false; // Extra panel chatter (trade lines always on)


//====================== RUNTIME TOGGLES (panel + GV; inputs = defaults) ======================
// MA trend panel state per TF: 0=OFF, 1=Single (m1), 2=Double (m2)
#define MA_TREND_OFF     0
#define MA_TREND_ST_SINGLE 1
#define MA_TREND_ST_DOUBLE 2

ENUM_CONF_MODE g_ConfluenceMode;
ENUM_BOS_MODE  g_BosMode;
ENUM_BOS_MODE  g_SwingSLMode;
bool g_TradeBuy, g_TradeSell;
bool g_TF1_UseStochCross, g_TF1_UseStochClassic, g_TF1_UseSrBounce, g_TF1_UseSrBreakRetest;
bool g_TF1_UseFibZone, g_TF1_UseMacdBias, g_TF1_UseRsiBias, g_TF1_UseBos;
bool g_TF2_UseStochCross, g_TF2_UseStochClassic, g_TF2_UseSrBounce, g_TF2_UseSrBreakRetest;
bool g_TF2_UseFibZone, g_TF2_UseMacdBias, g_TF2_UseRsiBias, g_TF2_UseBos;
int  g_TF1_MaTrend = MA_TREND_OFF;
int  g_TF2_MaTrend = MA_TREND_OFF;
bool g_UseMAFilter, g_UseVirtualMaSL, g_UseSwingVirtualSL, g_UseBasketTP;

bool MaTrendEnabled(const int state) { return (state == MA_TREND_ST_SINGLE || state == MA_TREND_ST_DOUBLE); }

int MaTrendStateFromInputs(const bool useIt)
{
   if(!useIt) return MA_TREND_OFF;
   return (MaTrendStyle == MA_TREND_SINGLE) ? MA_TREND_ST_SINGLE : MA_TREND_ST_DOUBLE;
}

string g_gvPrefix = "";
string g_panelPrefix = "";
bool   g_panelCollapsed = false;
bool   g_quietInit = false;          // TF-change reinit: keep logs quiet
ulong  g_panelLastClickMs = 0;
//====================== GLOBALS ======================
ENUM_TIMEFRAMES g_tf1;
ENUM_TIMEFRAMES g_tf2;

int g_stoch1 = INVALID_HANDLE, g_rsi1 = INVALID_HANDLE, g_macd1 = INVALID_HANDLE;
int g_maTr1  = INVALID_HANDLE, g_maF1 = INVALID_HANDLE, g_maS1 = INVALID_HANDLE, g_atr1 = INVALID_HANDLE;
int g_stoch2 = INVALID_HANDLE, g_rsi2 = INVALID_HANDLE, g_macd2 = INVALID_HANDLE;
int g_maTr2  = INVALID_HANDLE, g_maF2 = INVALID_HANDLE, g_maS2 = INVALID_HANDLE, g_atr2 = INVALID_HANDLE;
int g_ma     = INVALID_HANDLE; // TF1 live MA filter + virtual SL (separate from MA trend module)

double   g_pip = 0;
datetime g_lastBarTime  = 0;
datetime g_lastEntryBar = 0;

bool   g_haveSignal  = false;
bool   g_signalIsBuy = false;
// True when signal is armed by FibZone leg but price not yet in zone at bar eval.
// TryEnter re-checks live zone every tick (gun/bomb style).
bool   g_fibZoneTickGate = false;

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

//====================== LOGGING / PUSH (same style as 2nd / 3rd / fibo-gun) ======================
// Journal example:  lets-go #777 EURUSD | OPEN BUY 0.01 @ ...
string Tag() { return EA_LABEL + " #" + IntegerToString(MagicNumber) + " " + _Symbol; }
void LogInfo(const string msg)  { Print(Tag(), " | ", msg); }
void LogDebug(const string msg) { if(InpDebugLog) Print(Tag(), " | ", msg); }

void NotifyPush(const string msg)
{
   // Important only: callers already limit to INIT FAILED + BASKET CLOSED.
   if(!SendNotification(msg))
      LogInfo("PUSH FAILED - " + msg);
}

bool CreateTfHandles(const ENUM_TIMEFRAMES tf,
                     const bool useCross, const bool useClassic,
                     const bool useMacd, const bool useRsi, const bool useMaTrend,
                     const bool useFib, const bool useBos,
                     int &hStoch, int &hRsi, int &hMacd,
                     int &hMaSingle, int &hMaFast, int &hMaSlow, int &hAtr,
                     const string label)
{
   if(useCross || useClassic)
   {
      hStoch = iStochastic(_Symbol, tf, StochKPeriod, StochDPeriod, StochSlowing, StochMAMethod, StochPriceField);
      if(hStoch == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " Stochastic");
         NotifyPush(Tag() + ": INIT FAILED - " + label + " Stochastic");
         return false;
      }
   }
   if(useRsi)
   {
      hRsi = iRSI(_Symbol, tf, RSIPeriod, RSIAppliedPrice);
      if(hRsi == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " RSI");
         NotifyPush(Tag() + ": INIT FAILED - " + label + " RSI");
         return false;
      }
   }
   if(useMacd)
   {
      hMacd = iMACD(_Symbol, tf, MACDFastEMA, MACDSlowEMA, MACDSignalPeriod, MACDAppliedPrice);
      if(hMacd == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " MACD");
         NotifyPush(Tag() + ": INIT FAILED - " + label + " MACD");
         return false;
      }
   }
   // Create single + double handles so panel can cycle m1/m2 without reattach.
   if(useMaTrend)
   {
      hMaSingle = iMA(_Symbol, tf, MathMax(1, MaTrendPeriod), 0, MaTrendMethod, MaTrendPrice);
      hMaFast   = iMA(_Symbol, tf, MathMax(1, MaTrendFastPeriod), 0, MaTrendMethod, MaTrendPrice);
      hMaSlow   = iMA(_Symbol, tf, MathMax(1, MaTrendSlowPeriod), 0, MaTrendMethod, MaTrendPrice);
      if(hMaSingle == INVALID_HANDLE || hMaFast == INVALID_HANDLE || hMaSlow == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " MA trend");
         NotifyPush(Tag() + ": INIT FAILED - " + label + " MA trend");
         return false;
      }
   }
   // ATR needed for FibZone and/or zigzag BOS (not for fractal-only BOS)
   if(useFib || (useBos && g_BosMode != BOS_FRACTAL))
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


//====================== PANEL STATE (GlobalVariables) ======================
// Memory: fingerprint Inputs; if unchanged restore last clicks, else reset.
// Scope: account + symbol + magic.

void PanelInitPrefix()
{
   string sym = _Symbol;
   StringReplace(sym, ".", "_");
   g_gvPrefix = "LG_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "_"
              + sym + "_" + IntegerToString(MagicNumber) + "_";
   g_panelPrefix = "LGUI_" + IntegerToString(ChartID()) + "_";
}

string PanelGvKey(const string id) { return g_gvPrefix + id; }

void PanelSaveBool(const string id, const bool v)
{
   if(!PanelRemember) return;
   GlobalVariableSet(PanelGvKey(id), v ? 1.0 : 0.0);
}

void PanelSaveInt(const string id, const int v)
{
   if(!PanelRemember) return;
   GlobalVariableSet(PanelGvKey(id), (double)v);
}

bool PanelLoadBool(const string id, const bool fallback)
{
   if(!PanelRemember) return fallback;
   string k = PanelGvKey(id);
   if(!GlobalVariableCheck(k)) return fallback;
   return (GlobalVariableGet(k) > 0.5);
}

int PanelLoadInt(const string id, const int fallback)
{
   if(!PanelRemember) return fallback;
   string k = PanelGvKey(id);
   if(!GlobalVariableCheck(k)) return fallback;
   return (int)GlobalVariableGet(k);
}

// Compact fingerprint of every panel-backed INPUT default.
string PanelInputFingerprint()
{
   return IntegerToString((int)ConfluenceMode) + "|"
        + IntegerToString((int)BosMode) + "|"
        + IntegerToString((int)SwingSLMode) + "|"
        + IntegerToString((int)TradeBuy) + IntegerToString((int)TradeSell) + "|"
        + IntegerToString((int)TF1_UseStochCross) + IntegerToString((int)TF1_UseStochClassic)
        + IntegerToString((int)TF1_UseSrBounce) + IntegerToString((int)TF1_UseSrBreakRetest)
        + IntegerToString((int)TF1_UseFibZone) + IntegerToString((int)TF1_UseMacdBias)
        + IntegerToString((int)TF1_UseRsiBias) + IntegerToString((int)TF1_UseMaTrend)
        + IntegerToString((int)TF1_UseBos) + "|"
        + IntegerToString((int)TF2_UseStochCross) + IntegerToString((int)TF2_UseStochClassic)
        + IntegerToString((int)TF2_UseSrBounce) + IntegerToString((int)TF2_UseSrBreakRetest)
        + IntegerToString((int)TF2_UseFibZone) + IntegerToString((int)TF2_UseMacdBias)
        + IntegerToString((int)TF2_UseRsiBias) + IntegerToString((int)TF2_UseMaTrend)
        + IntegerToString((int)TF2_UseBos) + "|"
        + IntegerToString((int)MaTrendStyle) + IntegerToString((int)MaTrendMethod) + "|"
        + IntegerToString((int)UseMAFilter) + IntegerToString((int)UseVirtualMaSL)
        + IntegerToString((int)UseSwingVirtualSL) + IntegerToString((int)UseBasketTP);
}

void RuntimeApplyInputDefaults()
{
   g_ConfluenceMode = ConfluenceMode;
   g_BosMode = BosMode;
   g_SwingSLMode = SwingSLMode;
   g_TradeBuy = TradeBuy;
   g_TradeSell = TradeSell;

   g_TF1_UseStochCross = TF1_UseStochCross;
   g_TF1_UseStochClassic = TF1_UseStochClassic;
   g_TF1_UseSrBounce = TF1_UseSrBounce;
   g_TF1_UseSrBreakRetest = TF1_UseSrBreakRetest;
   g_TF1_UseFibZone = TF1_UseFibZone;
   g_TF1_UseMacdBias = TF1_UseMacdBias;
   g_TF1_UseRsiBias = TF1_UseRsiBias;
   g_TF1_MaTrend = MaTrendStateFromInputs(TF1_UseMaTrend);
   g_TF1_UseBos = TF1_UseBos;

   g_TF2_UseStochCross = TF2_UseStochCross;
   g_TF2_UseStochClassic = TF2_UseStochClassic;
   g_TF2_UseSrBounce = TF2_UseSrBounce;
   g_TF2_UseSrBreakRetest = TF2_UseSrBreakRetest;
   g_TF2_UseFibZone = TF2_UseFibZone;
   g_TF2_UseMacdBias = TF2_UseMacdBias;
   g_TF2_UseRsiBias = TF2_UseRsiBias;
   g_TF2_MaTrend = MaTrendStateFromInputs(TF2_UseMaTrend);
   g_TF2_UseBos = TF2_UseBos;

   g_UseMAFilter = UseMAFilter;
   g_UseVirtualMaSL = UseVirtualMaSL;
   g_UseSwingVirtualSL = UseSwingVirtualSL;
   g_UseBasketTP = UseBasketTP;
}

void RuntimeSaveAllToGV()
{
   if(!PanelRemember) return;
   PanelSaveInt("Conf", (int)g_ConfluenceMode);
   PanelSaveInt("BosMode", (int)g_BosMode);
   PanelSaveInt("SwMode", (int)g_SwingSLMode);
   PanelSaveBool("Buy", g_TradeBuy);
   PanelSaveBool("Sell", g_TradeSell);

   PanelSaveBool("T1_stX", g_TF1_UseStochCross);
   PanelSaveBool("T1_stC", g_TF1_UseStochClassic);
   PanelSaveBool("T1_srB", g_TF1_UseSrBounce);
   PanelSaveBool("T1_srR", g_TF1_UseSrBreakRetest);
   PanelSaveBool("T1_fib", g_TF1_UseFibZone);
   PanelSaveBool("T1_macd", g_TF1_UseMacdBias);
   PanelSaveBool("T1_rsi", g_TF1_UseRsiBias);
   PanelSaveInt("T1_maT", g_TF1_MaTrend);
   PanelSaveBool("T1_bos", g_TF1_UseBos);

   PanelSaveBool("T2_stX", g_TF2_UseStochCross);
   PanelSaveBool("T2_stC", g_TF2_UseStochClassic);
   PanelSaveBool("T2_srB", g_TF2_UseSrBounce);
   PanelSaveBool("T2_srR", g_TF2_UseSrBreakRetest);
   PanelSaveBool("T2_fib", g_TF2_UseFibZone);
   PanelSaveBool("T2_macd", g_TF2_UseMacdBias);
   PanelSaveBool("T2_rsi", g_TF2_UseRsiBias);
   PanelSaveInt("T2_maT", g_TF2_MaTrend);
   PanelSaveBool("T2_bos", g_TF2_UseBos);

   PanelSaveBool("MA", g_UseMAFilter);
   PanelSaveBool("MaSL", g_UseVirtualMaSL);
   PanelSaveBool("SwSL", g_UseSwingVirtualSL);
   PanelSaveBool("Trail", g_UseBasketTP);
   PanelSaveBool("Collapsed", g_panelCollapsed);
}

void RuntimeLoadFromGV()
{
   g_ConfluenceMode = (ENUM_CONF_MODE)PanelLoadInt("Conf", (int)g_ConfluenceMode);
   g_BosMode = (ENUM_BOS_MODE)PanelLoadInt("BosMode", (int)g_BosMode);
   g_SwingSLMode = (ENUM_BOS_MODE)PanelLoadInt("SwMode", (int)g_SwingSLMode);
   g_TradeBuy = PanelLoadBool("Buy", g_TradeBuy);
   g_TradeSell = PanelLoadBool("Sell", g_TradeSell);

   g_TF1_UseStochCross = PanelLoadBool("T1_stX", g_TF1_UseStochCross);
   g_TF1_UseStochClassic = PanelLoadBool("T1_stC", g_TF1_UseStochClassic);
   g_TF1_UseSrBounce = PanelLoadBool("T1_srB", g_TF1_UseSrBounce);
   g_TF1_UseSrBreakRetest = PanelLoadBool("T1_srR", g_TF1_UseSrBreakRetest);
   g_TF1_UseFibZone = PanelLoadBool("T1_fib", g_TF1_UseFibZone);
   g_TF1_UseMacdBias = PanelLoadBool("T1_macd", g_TF1_UseMacdBias);
   g_TF1_UseRsiBias = PanelLoadBool("T1_rsi", g_TF1_UseRsiBias);
   // Prefer new int state; migrate old bool T1_ema if present.
   if(GlobalVariableCheck(PanelGvKey("T1_maT")))
      g_TF1_MaTrend = PanelLoadInt("T1_maT", g_TF1_MaTrend);
   else if(PanelLoadBool("T1_ema", false))
      g_TF1_MaTrend = MaTrendStateFromInputs(true);
   g_TF1_UseBos = PanelLoadBool("T1_bos", g_TF1_UseBos);

   g_TF2_UseStochCross = PanelLoadBool("T2_stX", g_TF2_UseStochCross);
   g_TF2_UseStochClassic = PanelLoadBool("T2_stC", g_TF2_UseStochClassic);
   g_TF2_UseSrBounce = PanelLoadBool("T2_srB", g_TF2_UseSrBounce);
   g_TF2_UseSrBreakRetest = PanelLoadBool("T2_srR", g_TF2_UseSrBreakRetest);
   g_TF2_UseFibZone = PanelLoadBool("T2_fib", g_TF2_UseFibZone);
   g_TF2_UseMacdBias = PanelLoadBool("T2_macd", g_TF2_UseMacdBias);
   g_TF2_UseRsiBias = PanelLoadBool("T2_rsi", g_TF2_UseRsiBias);
   if(GlobalVariableCheck(PanelGvKey("T2_maT")))
      g_TF2_MaTrend = PanelLoadInt("T2_maT", g_TF2_MaTrend);
   else if(PanelLoadBool("T2_ema", false))
      g_TF2_MaTrend = MaTrendStateFromInputs(true);
   g_TF2_UseBos = PanelLoadBool("T2_bos", g_TF2_UseBos);

   if(g_TF1_MaTrend != MA_TREND_OFF && g_TF1_MaTrend != MA_TREND_ST_SINGLE && g_TF1_MaTrend != MA_TREND_ST_DOUBLE)
      g_TF1_MaTrend = MA_TREND_OFF;
   if(g_TF2_MaTrend != MA_TREND_OFF && g_TF2_MaTrend != MA_TREND_ST_SINGLE && g_TF2_MaTrend != MA_TREND_ST_DOUBLE)
      g_TF2_MaTrend = MA_TREND_OFF;

   g_UseMAFilter = PanelLoadBool("MA", g_UseMAFilter);
   g_UseVirtualMaSL = PanelLoadBool("MaSL", g_UseVirtualMaSL);
   g_UseSwingVirtualSL = PanelLoadBool("SwSL", g_UseSwingVirtualSL);
   g_UseBasketTP = PanelLoadBool("Trail", g_UseBasketTP);
   g_panelCollapsed = PanelLoadBool("Collapsed", g_panelCollapsed);

   if(g_ConfluenceMode != CONF_TF1_ONLY && g_ConfluenceMode != CONF_TF1_AND_TF2)
      g_ConfluenceMode = CONF_TF1_AND_TF2;
   if(g_BosMode != BOS_ZIGZAG && g_BosMode != BOS_FRACTAL && g_BosMode != BOS_BOTH_AND)
      g_BosMode = BOS_ZIGZAG;
   if(g_SwingSLMode != BOS_ZIGZAG && g_SwingSLMode != BOS_FRACTAL && g_SwingSLMode != BOS_BOTH_AND)
      g_SwingSLMode = BOS_FRACTAL;
}

void RuntimeLoadFromInputsThenGV()
{
   PanelInitPrefix();
   RuntimeApplyInputDefaults();
   g_panelCollapsed = PanelStartCollapsed;

   // No panel or remember off -> Inputs only (never silent GV override).
   if(!ShowPanel || !PanelRemember)
      return;

   string fpNow = PanelInputFingerprint();
   string kFp = PanelGvKey("INP_FP");
   bool haveFp = GlobalVariableCheck(kFp);
   double fpHash = 0;
   for(int i = 0; i < StringLen(fpNow); i++)
      fpHash += (double)StringGetCharacter(fpNow, i) * (i + 1);

   if(haveFp && MathAbs(GlobalVariableGet(kFp) - fpHash) < 0.5)
   {
      RuntimeLoadFromGV();
      if(!g_quietInit)
         LogDebug("PANEL memory restored (inputs unchanged)");
   }
   else
   {
      RuntimeApplyInputDefaults();
      g_panelCollapsed = PanelStartCollapsed;
      GlobalVariableSet(kFp, fpHash);
      RuntimeSaveAllToGV();
      if(!g_quietInit)
         LogDebug("PANEL defaults from Inputs (fresh or inputs changed)");
   }
}

void PanelClearMemory()
{
   // wipe remembered clicks for this account/symbol/magic
   string ids[] = {
      "INP_FP","Conf","BosMode","SwMode","Buy","Sell","Collapsed",
      "T1_stX","T1_stC","T1_srB","T1_srR","T1_fib","T1_macd","T1_rsi","T1_ema","T1_maT","T1_bos",
      "T2_stX","T2_stC","T2_srB","T2_srR","T2_fib","T2_macd","T2_rsi","T2_ema","T2_maT","T2_bos",
      "MA","MaSL","SwSL","SwMd","Trail"
   };
   for(int i = 0; i < ArraySize(ids); i++)
      GlobalVariableDel(PanelGvKey(ids[i]));
}

//====================== CHIP PANEL UI ======================
// Always top-left. Position = PanelInsetX / PanelInsetY.
string PanelObj(const string id) { return g_panelPrefix + id; }

void PanelDeleteAll()
{
   if(StringLen(g_panelPrefix) == 0)
      g_panelPrefix = "LGUI_" + IntegerToString(ChartID()) + "_";
   ObjectsDeleteAll(0, g_panelPrefix);
}

void PanelStyleChip(const string name, const string text, const string tip,
                    const bool on, const bool isModeChip)
{
   color bg, fg, bd;
   if(isModeChip)
   {
      bg = C'36,52,68';
      fg = C'220,235,250';
      bd = C'70,110,140';
   }
   else if(on)
   {
      bg = C'40,110,92';
      fg = C'235,255,248';
      bd = C'80,160,130';
   }
   else
   {
      bg = C'48,48,48';
      fg = C'160,160,160';
      bd = C'36,36,36';
   }

   ObjectSetString (0, name, OBJPROP_TEXT, text);
   ObjectSetString (0, name, OBJPROP_TOOLTIP, tip);
   ObjectSetInteger(0, name, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, bd);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
}

void PanelEnsureButton(const string id, const int x, const int y, const int w, const int h)
{
   string name = PanelObj(id);
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetString (0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1000);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

void PanelEnsureLabel(const string id, const int x, const int y, const int w, const int h)
{
   PanelEnsureButton(id, x, y, w, h);
   ObjectSetInteger(0, PanelObj(id), OBJPROP_ZORDER, 900);
}

string ConfChipText()
{
   return (g_ConfluenceMode == CONF_TF1_ONLY) ? "1TF" : "+TF2";
}

string BosChipText()
{
   if(g_BosMode == BOS_FRACTAL) return "Frac";
   if(g_BosMode == BOS_BOTH_AND) return "Both";
   return "Zig";
}

// Swing SL method chip (independent of entry BOSM)
string SwMdChipText()
{
   if(g_SwingSLMode == BOS_FRACTAL) return "Frac";
   if(g_SwingSLMode == BOS_BOTH_AND) return "Both";
   return "Zig";
}

string ConfTip()
{
   return (g_ConfluenceMode == CONF_TF1_ONLY)
      ? "TF1 entry only (click to also require TF2 bias)"
      : "TF1 entry AND TF2 bias (click for TF1 only)";
}

string BosTip()
{
   if(g_BosMode == BOS_FRACTAL) return "Entry BOS engine: Fractal (click to cycle)";
   if(g_BosMode == BOS_BOTH_AND) return "Entry BOS engine: BOTH must agree (click to cycle)";
   return "Entry BOS engine: Zigzag (click to cycle)";
}

string SwMdTip()
{
   if(g_SwingSLMode == BOS_FRACTAL)
      return "Swing SL method: Fractal (click to cycle; independent of entry BOS)";
   if(g_SwingSLMode == BOS_BOTH_AND)
      return "Swing SL method: BOTH tighter (click to cycle; independent of entry BOS)";
   return "Swing SL method: Zigzag (click to cycle; independent of entry BOS)";
}

string MaTrendChipText(const int state)
{
   if(state == MA_TREND_ST_SINGLE) return "m1";
   if(state == MA_TREND_ST_DOUBLE) return "m2";
   return "maT";
}

string MaTrendTip(const int state, const string tfTag)
{
   if(state == MA_TREND_ST_SINGLE)
      return tfTag + " MA trend: SINGLE (price vs MA). Click: OFF / m1 / m2";
   if(state == MA_TREND_ST_DOUBLE)
      return tfTag + " MA trend: DOUBLE (fast vs slow). Click: OFF / m1 / m2";
   return tfTag + " MA trend: OFF. Click: OFF / m1 / m2";
}

void PanelCycleMaTrend(int &state, const string gvId)
{
   if(state == MA_TREND_OFF) state = MA_TREND_ST_SINGLE;
   else if(state == MA_TREND_ST_SINGLE) state = MA_TREND_ST_DOUBLE;
   else state = MA_TREND_OFF;
   PanelSaveInt(gvId, state);
}

void PanelPaintState()
{
   if(!ShowPanel) return;

   PanelStyleChip(PanelObj("TTL"), g_panelCollapsed ? " lets-go  ▸" : " lets-go  ▾",
                  "Click to collapse / expand panel", true, true);

   if(g_panelCollapsed) return;

   PanelStyleChip(PanelObj("CONF"), ConfChipText(), ConfTip(), true, true);
   PanelStyleChip(PanelObj("BOSM"), BosChipText(), BosTip(), true, true);
   PanelStyleChip(PanelObj("BUY"),  "Buy",  "Allow BUY signals",  g_TradeBuy,  false);
   PanelStyleChip(PanelObj("SELL"), "Sell", "Allow SELL signals", g_TradeSell, false);

   PanelStyleChip(PanelObj("L1"), " TF1 entry · all AND", "TF1 entry modules (every ON must pass)", true, true);
   PanelStyleChip(PanelObj("T1_stX"), "stX", "TF1 entry: Stoch cross", g_TF1_UseStochCross, false);
   PanelStyleChip(PanelObj("T1_stC"), "stC", "TF1 entry: Stoch classic OS/OB", g_TF1_UseStochClassic, false);
   PanelStyleChip(PanelObj("T1_srB"), "srB", "TF1 entry: S/R bounce", g_TF1_UseSrBounce, false);
   PanelStyleChip(PanelObj("T1_srR"), "srR", "TF1 entry: S/R break-retest", g_TF1_UseSrBreakRetest, false);
   PanelStyleChip(PanelObj("T1_fib"), "fib", "TF1 entry: Fib golden zone", g_TF1_UseFibZone, false);
   PanelStyleChip(PanelObj("T1_macd"),"macd","TF1 entry: MACD bias", g_TF1_UseMacdBias, false);
   PanelStyleChip(PanelObj("T1_rsi"), "rsi", "TF1 entry: RSI bias", g_TF1_UseRsiBias, false);
   PanelStyleChip(PanelObj("T1_ema"), MaTrendChipText(g_TF1_MaTrend), MaTrendTip(g_TF1_MaTrend, "TF1 entry"),
                  MaTrendEnabled(g_TF1_MaTrend), false);
   PanelStyleChip(PanelObj("T1_bos"), "bos", "TF1 entry: BOS (BosMode)", g_TF1_UseBos, false);

   PanelStyleChip(PanelObj("L2"), " TF2 bias · all AND", "TF2 bias modules (AND mode only; every ON must pass)", true, true);
   PanelStyleChip(PanelObj("T2_stX"), "stX", "TF2 bias: Stoch cross", g_TF2_UseStochCross, false);
   PanelStyleChip(PanelObj("T2_stC"), "stC", "TF2 bias: Stoch classic OS/OB", g_TF2_UseStochClassic, false);
   PanelStyleChip(PanelObj("T2_srB"), "srB", "TF2 bias: S/R bounce", g_TF2_UseSrBounce, false);
   PanelStyleChip(PanelObj("T2_srR"), "srR", "TF2 bias: S/R break-retest", g_TF2_UseSrBreakRetest, false);
   PanelStyleChip(PanelObj("T2_fib"), "fib", "TF2 bias: Fib golden zone", g_TF2_UseFibZone, false);
   PanelStyleChip(PanelObj("T2_macd"),"macd","TF2 bias: MACD", g_TF2_UseMacdBias, false);
   PanelStyleChip(PanelObj("T2_rsi"), "rsi", "TF2 bias: RSI", g_TF2_UseRsiBias, false);
   PanelStyleChip(PanelObj("T2_ema"), MaTrendChipText(g_TF2_MaTrend), MaTrendTip(g_TF2_MaTrend, "TF2 bias"),
                  MaTrendEnabled(g_TF2_MaTrend), false);
   PanelStyleChip(PanelObj("T2_bos"), "bos", "TF2 bias: BOS (BosMode)", g_TF2_UseBos, false);

   PanelStyleChip(PanelObj("LR"), " risk exits", "Risk / exit toggles", true, true);
   PanelStyleChip(PanelObj("MA"),   "MA",   "Live MA entry filter (TF1) — separate from m1/m2", g_UseMAFilter, false);
   PanelStyleChip(PanelObj("MaSL"), "MaSL", "Virtual MA stop (live follow)", g_UseVirtualMaSL, false);
   PanelStyleChip(PanelObj("SwSL"), "SwSL", "Virtual swing stop ON/OFF (green=on)", g_UseSwingVirtualSL, false);
   PanelStyleChip(PanelObj("SwMd"), SwMdChipText(), SwMdTip(), true, true);
   PanelStyleChip(PanelObj("Trail"),"Trail","Basket pip trail TP", g_UseBasketTP, false);
}

void PanelHideExtras()
{
   string extras[] = {
      "CONF","BOSM","BUY","SELL","L1","L2","LR",
      "T1_stX","T1_stC","T1_srB","T1_srR","T1_fib","T1_macd","T1_rsi","T1_ema","T1_bos",
      "T2_stX","T2_stC","T2_srB","T2_srR","T2_fib","T2_macd","T2_rsi","T2_ema","T2_bos",
      "MA","MaSL","SwSL","SwMd","Trail"
   };
   for(int i = 0; i < ArraySize(extras); i++)
   {
      string name = PanelObj(extras[i]);
      if(ObjectFind(0, name) < 0) continue;
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, -5000);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, -5000);
   }
}

void PanelBuild()
{
   if(!ShowPanel) { PanelDeleteAll(); return; }
   if(StringLen(g_panelPrefix) == 0)
      PanelInitPrefix();

   if(ObjectFind(0, PanelObj("MIN")) >= 0)
      ObjectDelete(0, PanelObj("MIN"));

   const int chipW = 40;
   const int chipH = 18;
   const int gap   = 3;
   const int rowW  = chipW * 5 + gap * 4; // full panel width (5-chip rows)
   const int step  = chipW + gap;
   const int x0    = MathMax(0, PanelInsetX);
   int y = MathMax(0, PanelInsetY);

   // 4 equal chips spanning full rowW (mode row + filter/risk 4-chip rows)
   const int quadW    = (rowW - gap * 3) / 4;
   const int quadStep = quadW + gap;
   const int quadLast = rowW - quadStep * 3;

   PanelEnsureLabel("TTL", x0, y, rowW, chipH);

   if(g_panelCollapsed)
   {
      PanelHideExtras();
      PanelPaintState();
      return;
   }

   y += chipH + gap;
   PanelEnsureButton("CONF", x0,                y, quadW,    chipH);
   PanelEnsureButton("BOSM", x0 + quadStep,     y, quadW,    chipH);
   PanelEnsureButton("BUY",  x0 + quadStep * 2, y, quadW,    chipH);
   PanelEnsureButton("SELL", x0 + quadStep * 3, y, quadLast, chipH);
   y += chipH + gap + 2;

   PanelEnsureLabel("L1", x0, y, rowW, chipH); y += chipH + gap;
   PanelEnsureButton("T1_stX", x0,             y, chipW, chipH);
   PanelEnsureButton("T1_stC", x0 + step,      y, chipW, chipH);
   PanelEnsureButton("T1_srB", x0 + step * 2,  y, chipW, chipH);
   PanelEnsureButton("T1_srR", x0 + step * 3,  y, chipW, chipH);
   PanelEnsureButton("T1_fib", x0 + step * 4,  y, chipW, chipH);
   y += chipH + gap;
   PanelEnsureButton("T1_macd", x0,                y, quadW,    chipH);
   PanelEnsureButton("T1_rsi",  x0 + quadStep,     y, quadW,    chipH);
   PanelEnsureButton("T1_ema",  x0 + quadStep * 2, y, quadW,    chipH);
   PanelEnsureButton("T1_bos",  x0 + quadStep * 3, y, quadLast, chipH);
   y += chipH + gap + 2;

   PanelEnsureLabel("L2", x0, y, rowW, chipH); y += chipH + gap;
   PanelEnsureButton("T2_stX", x0,             y, chipW, chipH);
   PanelEnsureButton("T2_stC", x0 + step,      y, chipW, chipH);
   PanelEnsureButton("T2_srB", x0 + step * 2,  y, chipW, chipH);
   PanelEnsureButton("T2_srR", x0 + step * 3,  y, chipW, chipH);
   PanelEnsureButton("T2_fib", x0 + step * 4,  y, chipW, chipH);
   y += chipH + gap;
   PanelEnsureButton("T2_macd", x0,                y, quadW,    chipH);
   PanelEnsureButton("T2_rsi",  x0 + quadStep,     y, quadW,    chipH);
   PanelEnsureButton("T2_ema",  x0 + quadStep * 2, y, quadW,    chipH);
   PanelEnsureButton("T2_bos",  x0 + quadStep * 3, y, quadLast, chipH);
   y += chipH + gap + 2;

   PanelEnsureLabel("LR", x0, y, rowW, chipH); y += chipH + gap;
   // Full-width 5 chips — same grid as TF1/TF2 module rows
   PanelEnsureButton("MA",    x0,            y, chipW, chipH);
   PanelEnsureButton("MaSL",  x0 + step,     y, chipW, chipH);
   PanelEnsureButton("SwSL",  x0 + step * 2, y, chipW, chipH);
   PanelEnsureButton("SwMd",  x0 + step * 3, y, chipW, chipH);
   PanelEnsureButton("Trail", x0 + step * 4, y, chipW, chipH);

   PanelPaintState();
}

bool PanelClickAllowed()
{
   ulong now = GetTickCount64();
   if(PanelClickGuardMs > 0 && now - g_panelLastClickMs < (ulong)PanelClickGuardMs)
      return false;
   g_panelLastClickMs = now;
   return true;
}

bool PanelToggleBool(bool &flag, const string gvId)
{
   flag = !flag;
   PanelSaveBool(gvId, flag);
   return true;
}

bool PanelHandleClick(const string sparam)
{
   if(!ShowPanel) return false;
   if(StringLen(g_panelPrefix) == 0) PanelInitPrefix();
   if(StringFind(sparam, g_panelPrefix) != 0) return false;

   string id = StringSubstr(sparam, StringLen(g_panelPrefix));
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

   if(id == "L1" || id == "L2" || id == "LR")
      return true;

   if(!PanelClickAllowed())
      return true;

   bool changed = true;
   bool needFullBuild = false;

   if(id == "TTL")
   {
      g_panelCollapsed = !g_panelCollapsed;
      PanelSaveBool("Collapsed", g_panelCollapsed);
      needFullBuild = true;
   }
   else if(id == "CONF")
   {
      g_ConfluenceMode = (g_ConfluenceMode == CONF_TF1_ONLY) ? CONF_TF1_AND_TF2 : CONF_TF1_ONLY;
      PanelSaveInt("Conf", (int)g_ConfluenceMode);
   }
   else if(id == "BOSM")
   {
      if(g_BosMode == BOS_ZIGZAG) g_BosMode = BOS_FRACTAL;
      else if(g_BosMode == BOS_FRACTAL) g_BosMode = BOS_BOTH_AND;
      else g_BosMode = BOS_ZIGZAG;
      PanelSaveInt("BosMode", (int)g_BosMode);
   }
   else if(id == "SwMd")
   {
      if(g_SwingSLMode == BOS_ZIGZAG) g_SwingSLMode = BOS_FRACTAL;
      else if(g_SwingSLMode == BOS_FRACTAL) g_SwingSLMode = BOS_BOTH_AND;
      else g_SwingSLMode = BOS_ZIGZAG;
      PanelSaveInt("SwMode", (int)g_SwingSLMode);
      g_haveSwingSL = false;
      g_swingSL = 0;
   }
   else if(id == "BUY")  PanelToggleBool(g_TradeBuy, "Buy");
   else if(id == "SELL") PanelToggleBool(g_TradeSell, "Sell");
   else if(id == "T1_stX") PanelToggleBool(g_TF1_UseStochCross, "T1_stX");
   else if(id == "T1_stC") PanelToggleBool(g_TF1_UseStochClassic, "T1_stC");
   else if(id == "T1_srB") PanelToggleBool(g_TF1_UseSrBounce, "T1_srB");
   else if(id == "T1_srR") PanelToggleBool(g_TF1_UseSrBreakRetest, "T1_srR");
   else if(id == "T1_fib") PanelToggleBool(g_TF1_UseFibZone, "T1_fib");
   else if(id == "T1_macd") PanelToggleBool(g_TF1_UseMacdBias, "T1_macd");
   else if(id == "T1_rsi") PanelToggleBool(g_TF1_UseRsiBias, "T1_rsi");
   else if(id == "T1_ema") PanelCycleMaTrend(g_TF1_MaTrend, "T1_maT");
   else if(id == "T1_bos") PanelToggleBool(g_TF1_UseBos, "T1_bos");
   else if(id == "T2_stX") PanelToggleBool(g_TF2_UseStochCross, "T2_stX");
   else if(id == "T2_stC") PanelToggleBool(g_TF2_UseStochClassic, "T2_stC");
   else if(id == "T2_srB") PanelToggleBool(g_TF2_UseSrBounce, "T2_srB");
   else if(id == "T2_srR") PanelToggleBool(g_TF2_UseSrBreakRetest, "T2_srR");
   else if(id == "T2_fib") PanelToggleBool(g_TF2_UseFibZone, "T2_fib");
   else if(id == "T2_macd") PanelToggleBool(g_TF2_UseMacdBias, "T2_macd");
   else if(id == "T2_rsi") PanelToggleBool(g_TF2_UseRsiBias, "T2_rsi");
   else if(id == "T2_ema") PanelCycleMaTrend(g_TF2_MaTrend, "T2_maT");
   else if(id == "T2_bos") PanelToggleBool(g_TF2_UseBos, "T2_bos");
   else if(id == "MA") PanelToggleBool(g_UseMAFilter, "MA");
   else if(id == "MaSL") PanelToggleBool(g_UseVirtualMaSL, "MaSL");
   else if(id == "SwSL") PanelToggleBool(g_UseSwingVirtualSL, "SwSL");
   else if(id == "Trail") PanelToggleBool(g_UseBasketTP, "Trail");
   else changed = false;

   if(changed)
   {
      if(needFullBuild) PanelBuild();
      else PanelPaintState();
      ChartRedraw(0);
      if(!g_quietInit)
         LogDebug("PANEL " + id);
   }
   return true;
}

// Strategy Tester does NOT call OnChartEvent (even in Visual mode).
// Uncle-style: poll OBJ_BUTTON pressed state each tick/timer, then toggle + repaint.
void PanelPollClicks()
{
   if(!ShowPanel) return;
   if(!MQLInfoInteger(MQL_TESTER)) return;
   if(StringLen(g_panelPrefix) == 0) PanelInitPrefix();

   string headers[] = { "L1", "L2", "LR" };
   for(int h = 0; h < ArraySize(headers); h++)
   {
      string hn = PanelObj(headers[h]);
      if(ObjectFind(0, hn) < 0) continue;
      if(ObjectGetInteger(0, hn, OBJPROP_STATE))
         ObjectSetInteger(0, hn, OBJPROP_STATE, false);
   }

   string ids[] = {
      "TTL","CONF","BOSM","BUY","SELL",
      "T1_stX","T1_stC","T1_srB","T1_srR","T1_fib","T1_macd","T1_rsi","T1_ema","T1_bos",
      "T2_stX","T2_stC","T2_srB","T2_srR","T2_fib","T2_macd","T2_rsi","T2_ema","T2_bos",
      "MA","MaSL","SwSL","SwMd","Trail"
   };
   for(int i = 0; i < ArraySize(ids); i++)
   {
      string name = PanelObj(ids[i]);
      if(ObjectFind(0, name) < 0) continue;
      if(!ObjectGetInteger(0, name, OBJPROP_STATE)) continue;
      PanelHandleClick(name);
      break; // one chip per poll (avoids multi-toggle in one tick)
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_quietInit = (UninitializeReason() == REASON_CHARTCHANGE);
   RuntimeLoadFromInputsThenGV();

   g_tf1 = (InpTF1 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTF1;
   g_tf2 = (InpTF2 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTF2;

   if(MaxLayers < 1)
   {
      LogInfo("INIT FAILED - MaxLayers must be >= 1");
      NotifyPush(Tag() + ": INIT FAILED - MaxLayers must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxStopLossPips < 1)
   {
      LogInfo("INIT FAILED - MaxStopLossPips must be >= 1");
      NotifyPush(Tag() + ": INIT FAILED - MaxStopLossPips must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(PivotLeftBars < 1 || PivotRightBars < 1)
   {
      LogInfo("INIT FAILED - PivotLeftBars/PivotRightBars must be >= 1");
      NotifyPush(Tag() + ": INIT FAILED - PivotLeftBars/PivotRightBars must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(FibZoneLevelMin >= FibZoneLevelMax)
   {
      LogInfo("INIT FAILED - FibZoneLevelMin must be < FibZoneLevelMax");
      NotifyPush(Tag() + ": INIT FAILED - FibZoneLevelMin must be < FibZoneLevelMax");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(!g_TradeBuy && !g_TradeSell && !g_quietInit)
      LogInfo("NOTE Buy and Sell both off — enable from panel/inputs to trade.");

   // With the chip panel, pre-create ALL handles so live toggles work without reattach.
   const bool prepAll = ShowPanel;
   if(!CreateTfHandles(g_tf1,
                       prepAll || g_TF1_UseStochCross, prepAll || g_TF1_UseStochClassic,
                       prepAll || g_TF1_UseMacdBias, prepAll || g_TF1_UseRsiBias,
                       prepAll || MaTrendEnabled(g_TF1_MaTrend),
                       prepAll || g_TF1_UseFibZone || (g_UseSwingVirtualSL && g_SwingSLMode != BOS_FRACTAL),
                       prepAll || g_TF1_UseBos || g_UseSwingVirtualSL,
                       g_stoch1, g_rsi1, g_macd1, g_maTr1, g_maF1, g_maS1, g_atr1, "TF1"))
      return(INIT_FAILED);

   if(prepAll || g_ConfluenceMode == CONF_TF1_AND_TF2)
   {
      if(!CreateTfHandles(g_tf2,
                          prepAll || g_TF2_UseStochCross, prepAll || g_TF2_UseStochClassic,
                          prepAll || g_TF2_UseMacdBias, prepAll || g_TF2_UseRsiBias,
                          prepAll || MaTrendEnabled(g_TF2_MaTrend),
                          prepAll || g_TF2_UseFibZone, prepAll || g_TF2_UseBos,
                          g_stoch2, g_rsi2, g_macd2, g_maTr2, g_maF2, g_maS2, g_atr2, "TF2"))
         return(INIT_FAILED);
      if(PeriodSeconds(g_tf2) == PeriodSeconds(g_tf1) && !g_quietInit)
         LogInfo("NOTE TF1 entry and TF2 bias are the same period — bias adds no extra info.");
   }

   if(prepAll || g_UseMAFilter || g_UseVirtualMaSL)
   {
      if(g_ma == INVALID_HANDLE)
         g_ma = iMA(_Symbol, g_tf1, MathMax(1, MA_Period), MA_Shift, MA_Method, MA_AppliedPrice);
      if(g_ma == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - TF1 MA handle (live filter / virtual MA SL)");
         NotifyPush(Tag() + ": INIT FAILED - TF1 MA handle");
         return(INIT_FAILED);
      }
   }

   if((prepAll || g_TF1_UseFibZone ||
       (g_UseSwingVirtualSL && g_SwingSLMode != BOS_FRACTAL)) && g_atr1 == INVALID_HANDLE)
   {
      g_atr1 = iATR(_Symbol, g_tf1, MathMax(1, FibATRPeriod));
      if(g_atr1 == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - TF1 ATR");
         NotifyPush(Tag() + ": INIT FAILED - TF1 ATR");
         return(INIT_FAILED);
      }
   }

   g_pip = PipSize();
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(!g_quietInit)
   {
      string mode = (g_ConfluenceMode == CONF_TF1_ONLY) ? "ENTRY_ONLY" : "ENTRY+BIAS";
      LogInfo("INIT " + mode
              + " TF1=" + EnumToString(g_tf1)
              + " TF2=" + EnumToString(g_tf2)
              + " BosMode=" + EnumToString(g_BosMode)
              + " SwMode=" + EnumToString(g_SwingSLMode)
              + " | Buy=" + (g_TradeBuy ? "ON" : "OFF")
              + " Sell=" + (g_TradeSell ? "ON" : "OFF")
              + " | MaSL=" + (g_UseVirtualMaSL ? "ON" : "OFF")
              + " SwSL=" + (g_UseSwingVirtualSL ? "ON" : "OFF")
              + " Trail=" + (g_UseBasketTP ? "ON" : "OFF")
              + " | panel=" + (ShowPanel ? ("ON inset " + IntegerToString(PanelInsetX) + "," + IntegerToString(PanelInsetY)) : "off"));
      if(_Period != g_tf1)
         LogInfo("NOTE chart TF differs from TF1 (" + EnumToString(g_tf1)
                 + "). Signal clock runs on TF1.");
   }

   // Adopt existing panel on TF change (no delete/rebuild blink)
   PanelBuild();
   EventSetTimer(1);
   if(!g_quietInit)
      ChartRedraw(0);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   // Keep objects on TF change — next OnInit adopts them (no blink).
   if(reason != REASON_CHARTCHANGE)
      PanelDeleteAll();

   // Deliberate remove from chart = forget panel memory (fresh next attach).
   // Restart / DC / recompile / TF change keep memory.
   if(reason == REASON_REMOVE && PanelRemember)
      PanelClearMemory();

   ReleaseHandle(g_stoch1); ReleaseHandle(g_rsi1); ReleaseHandle(g_macd1);
   ReleaseHandle(g_maTr1);  ReleaseHandle(g_maF1); ReleaseHandle(g_maS1); ReleaseHandle(g_atr1);
   ReleaseHandle(g_stoch2); ReleaseHandle(g_rsi2); ReleaseHandle(g_macd2);
   ReleaseHandle(g_maTr2);  ReleaseHandle(g_maF2); ReleaseHandle(g_maS2); ReleaseHandle(g_atr2);
   ReleaseHandle(g_ma);
}

void OnTimer()
{
   if(!ShowPanel) return;
   if(StringLen(g_panelPrefix) == 0) PanelInitPrefix();
   PanelPollClicks(); // tester clicks while paused / between ticks
   if(ObjectFind(0, PanelObj("TTL")) < 0)
   {
      PanelBuild();
      ChartRedraw(0);
   }
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Live / demo charts only — Strategy Tester never calls this.
   if(id == CHARTEVENT_OBJECT_CLICK)
      PanelHandleClick(sparam);
}

void OnTick()
{
   PanelPollClicks();

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

// MA trend filter: Single = close vs one MA; Double = fast vs slow.
// Follow / Reversal applies to both. Live MA chip (g_ma) is separate.
bool EvalMaTrend(const ENUM_TIMEFRAMES tf,
                 const int hSingle, const int hFast, const int hSlow,
                 const int state, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!MaTrendEnabled(state)) return true;

   double thr = MathMax(0.0, MaTrendMinDiffPips) * g_pip;
   int dir = 0; // +1 buy-side follow, -1 sell-side follow, 0 range

   if(state == MA_TREND_ST_SINGLE)
   {
      if(hSingle == INVALID_HANDLE) return false;
      double m[];
      ArraySetAsSeries(m, true);
      if(CopyBuffer(hSingle, 0, 1, 1, m) != 1) return false;
      double close[];
      ArraySetAsSeries(close, true);
      if(CopyClose(_Symbol, tf, 1, 1, close) != 1) return false;
      double diff = close[0] - m[0];
      if(diff >  thr) dir = 1;
      if(diff < -thr) dir = -1;
   }
   else // DOUBLE
   {
      if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE) return false;
      double f[], s[];
      ArraySetAsSeries(f, true);
      ArraySetAsSeries(s, true);
      if(CopyBuffer(hFast, 0, 1, 1, f) != 1) return false;
      if(CopyBuffer(hSlow, 0, 1, 1, s) != 1) return false;
      double diff = f[0] - s[0];
      if(diff >  thr) dir = 1;
      if(diff < -thr) dir = -1;
   }

   if(dir == 0) { buyOK = false; sellOK = false; return true; }

   if(MaTrendMode == TREND_FOLLOW)
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
// g_BosMode selects ZIGZAG / FRACTAL / BOTH_AND (no OR).

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

// Fib golden zone from current zigzag leg.
// legOnly=true  → arm buy/sell from leg direction (no live price check) for bar signal.
// legOnly=false → require ask/bid inside zone (bar eval or per-tick re-gate).
bool EvalFibZone(const ENUM_TIMEFRAMES tf, const int hAtr, const bool useIt,
                 const bool legOnly, bool &buyOK, bool &sellOK)
{
   buyOK = false; sellOK = false;
   if(!useIt) { buyOK = true; sellOK = true; return true; }

   bool haveLeg = false, bullish = false, bos = false;
   double olderP = 0, newerP = 0;
   if(!ScanFibLeg(tf, hAtr, haveLeg, bullish, olderP, newerP, bos)) return false;
   if(!haveLeg) return true;

   double height = MathAbs(newerP - olderP);
   if(height <= 0) return true;

   if(legOnly)
   {
      if(bullish) buyOK = true;
      else        sellOK = true;
      return true;
   }

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

// Live price-in-zone check for per-tick FibZone gate (gun/bomb style).
bool LiveInFibZone(const ENUM_TIMEFRAMES tf, const int hAtr, const bool wantBuy)
{
   bool buyOK = false, sellOK = false;
   if(!EvalFibZone(tf, hAtr, true, false, buyOK, sellOK)) return false;
   return wantBuy ? buyOK : sellOK;
}

// Replay choch-bos style fractal structure on closed bars.
// buyOK/sellOK = entry signal (EVENT = only on break bar; BIAS = while trend holds).
// swingHigh/swingLow = latest active fractal levels (0 if none) — always sticky for SwSL.
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
   int lastBreakBar = -1;
   int lastBreakDir = 0; // +1 buy BOS, -1 sell BOS

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
         lastBreakBar = i;
         lastBreakDir = 1;
      }
      else if(lowValid && !lowBroken && breakLowPrice < lowPrice)
      {
         lowBroken = true;
         trend = -1;
         highValid = false;
         lastBreakBar = i;
         lastBreakDir = -1;
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

   if(BosSignalMode == BOS_SIGNAL_EVENT)
   {
      // Only the bar that actually breaks structure may enter.
      if(lastBreakBar == lastClosed && lastBreakDir > 0) buyOK = true;
      if(lastBreakBar == lastClosed && lastBreakDir < 0) sellOK = true;
   }
   else
   {
      // Sticky bias — every bar while structure remains bullish/bearish.
      if(trend > 0) buyOK = true;
      if(trend < 0) sellOK = true;
   }
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

   if(g_BosMode == BOS_ZIGZAG)
      return EvalZigzagBos(tf, hAtr, buyOK, sellOK);

   if(g_BosMode == BOS_FRACTAL)
      return ScanFractalBos(tf, buyOK, sellOK);

   // BOS_BOTH_AND — both engines must agree on the same side
   bool zBuy = false, zSell = false, fBuy = false, fSell = false;
   if(!EvalZigzagBos(tf, hAtr, zBuy, zSell)) return false;
   if(!ScanFractalBos(tf, fBuy, fSell)) return false;
   buyOK  = (zBuy  && fBuy);
   sellOK = (zSell && fSell);
   return true;
}

// Evaluate one TF: every enabled module family must pass (all AND).
// Within Stoch: cross OR classic. Within S/R: bounce OR retest.
// emptyPass: if no modules ON, pass both sides (used for empty TF2 bias).
// fibLegOnly: FibZone arms from leg direction only (price checked later per tick).
bool EvalTf(const ENUM_TIMEFRAMES tf,
            const bool useCross, const bool useClassic,
            const bool useBounce, const bool useRetest, const bool useFib,
            const bool useMacd, const bool useRsi, const int maTrendState, const bool useBos,
            const int hStoch, const int hRsi, const int hMacd,
            const int hMaSingle, const int hMaFast, const int hMaSlow, const int hAtr,
            const bool fibLegOnly, const bool emptyPass,
            bool &outBuy, bool &outSell)
{
   outBuy = false; outSell = false;

   const bool useStoch   = (useCross || useClassic);
   const bool useSr      = (useBounce || useRetest);
   const bool useMaTrend = MaTrendEnabled(maTrendState);
   if(!useStoch && !useSr && !useFib && !useMacd && !useRsi && !useMaTrend && !useBos)
   {
      if(emptyPass) { outBuy = true; outSell = true; } // empty bias TF = no extra gate
      return true;
   }

   bool buy = true, sell = true;

   if(useStoch)
   {
      bool stB = false, stS = false;
      if(!EvalStoch(hStoch, useCross, useClassic, stB, stS)) return false;
      buy &= stB; sell &= stS;
   }
   if(useSr)
   {
      bool srB = false, srS = false;
      if(!EvalSr(tf, useBounce, useRetest, srB, srS)) return false;
      buy &= srB; sell &= srS;
   }
   if(useFib)
   {
      bool fibB = false, fibS = false;
      if(!EvalFibZone(tf, hAtr, true, fibLegOnly, fibB, fibS)) return false;
      buy &= fibB; sell &= fibS;
   }
   if(useMacd)
   {
      bool macdBuy = false, macdSell = false;
      if(!EvalMacd(hMacd, true, macdBuy, macdSell)) return false;
      buy &= macdBuy; sell &= macdSell;
   }
   if(useRsi)
   {
      bool rsiBuy = false, rsiSell = false;
      if(!EvalRsi(hRsi, true, rsiBuy, rsiSell)) return false;
      buy &= rsiBuy; sell &= rsiSell;
   }
   if(useMaTrend)
   {
      bool maBuy = false, maSell = false;
      if(!EvalMaTrend(tf, hMaSingle, hMaFast, hMaSlow, maTrendState, maBuy, maSell)) return false;
      buy &= maBuy; sell &= maSell;
   }
   if(useBos)
   {
      bool bosBuy = false, bosSell = false;
      if(!EvalBos(tf, hAtr, true, bosBuy, bosSell)) return false;
      buy &= bosBuy; sell &= bosSell;
   }

   outBuy = buy;
   outSell = sell;
   return true;
}

bool ResolveSignalSide(const bool buyOK, const bool sellOK, bool &isBuy)
{
   if(g_TradeBuy && buyOK && !(g_TradeSell && sellOK))
   { isBuy = true; return true; }
   if(g_TradeSell && sellOK && !(g_TradeBuy && buyOK))
   { isBuy = false; return true; }
   return false;
}

void UpdateSignal()
{
   g_haveSignal      = false;
   g_signalIsBuy     = false;
   g_fibZoneTickGate = false;

   // Pass 1: normal eval (FibZone requires price in zone now)
   bool b1 = false, s1 = false;
   if(!EvalTf(g_tf1,
              g_TF1_UseStochCross, g_TF1_UseStochClassic,
              g_TF1_UseSrBounce, g_TF1_UseSrBreakRetest, g_TF1_UseFibZone,
              g_TF1_UseMacdBias, g_TF1_UseRsiBias, g_TF1_MaTrend, g_TF1_UseBos,
              g_stoch1, g_rsi1, g_macd1, g_maTr1, g_maF1, g_maS1, g_atr1,
              false, b1, s1))
      return;

   bool b2 = true, s2 = true; // ignored in ENTRY_ONLY
   if(g_ConfluenceMode == CONF_TF1_AND_TF2)
   {
      b2 = false; s2 = false;
      if(!EvalTf(g_tf2,
                 g_TF2_UseStochCross, g_TF2_UseStochClassic,
                 g_TF2_UseSrBounce, g_TF2_UseSrBreakRetest, g_TF2_UseFibZone,
                 g_TF2_UseMacdBias, g_TF2_UseRsiBias, g_TF2_MaTrend, g_TF2_UseBos,
                 g_stoch2, g_rsi2, g_macd2, g_maTr2, g_maF2, g_maS2, g_atr2,
                 false, b2, s2))
         return;
   }

   bool isBuy = false;
   if(ResolveSignalSide(b1 && b2, s1 && s2, isBuy))
   {
      g_haveSignal  = true;
      g_signalIsBuy = isBuy;
      return;
   }

   // Pass 2: FibZone leg-armed only (price may enter zone later this bar).
   // Used when FibZone is on and pass 1 had no trade (e.g. waiting for zone).
   const bool wantFibGate = (g_TF1_UseFibZone ||
                             (g_ConfluenceMode == CONF_TF1_AND_TF2 && g_TF2_UseFibZone));
   if(!wantFibGate) return;

   b1 = false; s1 = false;
   if(!EvalTf(g_tf1,
              g_TF1_UseStochCross, g_TF1_UseStochClassic,
              g_TF1_UseSrBounce, g_TF1_UseSrBreakRetest, g_TF1_UseFibZone,
              g_TF1_UseMacdBias, g_TF1_UseRsiBias, g_TF1_MaTrend, g_TF1_UseBos,
              g_stoch1, g_rsi1, g_macd1, g_maTr1, g_maF1, g_maS1, g_atr1,
              true, b1, s1))
      return;

   b2 = true; s2 = true;
   if(g_ConfluenceMode == CONF_TF1_AND_TF2)
   {
      b2 = false; s2 = false;
      if(!EvalTf(g_tf2,
                 g_TF2_UseStochCross, g_TF2_UseStochClassic,
                 g_TF2_UseSrBounce, g_TF2_UseSrBreakRetest, g_TF2_UseFibZone,
                 g_TF2_UseMacdBias, g_TF2_UseRsiBias, g_TF2_MaTrend, g_TF2_UseBos,
                 g_stoch2, g_rsi2, g_macd2, g_maTr2, g_maF2, g_maS2, g_atr2,
                 true, b2, s2))
         return;
   }

   if(ResolveSignalSide(b1 && b2, s1 && s2, isBuy))
   {
      g_haveSignal      = true;
      g_signalIsBuy     = isBuy;
      g_fibZoneTickGate = true; // TryEnter waits for live zone
   }
}


//====================== ENTRY ======================
void DiagBlock(const string reason)
{
   if(g_lastDiagBar == g_lastBarTime) return;
   g_lastDiagBar = g_lastBarTime;
   LogInfo("BLOCKED " + reason + " | signal=" + (g_signalIsBuy ? "BUY" : "SELL"));
}

void TryEnter()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // FibZone per-tick re-gate (fibo-gun / fibo-bomb): leg armed on bar, enter when price is in zone.
   if(g_fibZoneTickGate)
   {
      if(g_TF1_UseFibZone && !LiveInFibZone(g_tf1, g_atr1, g_signalIsBuy))
         return; // silent wait — same as gun when price is outside zone
      if(g_ConfluenceMode == CONF_TF1_AND_TF2 && g_TF2_UseFibZone &&
         !LiveInFibZone(g_tf2, g_atr2, g_signalIsBuy))
         return;
   }

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
      ResetBasket();
      ResetBasketLines();
   }

   OpenLayer(layers == 0);
}

//====================== MARKET GUARD ======================
void LogGuardOnce(const string msg)
{
   if(TimeCurrent() - g_lastGuardLogTime < 300) return;
   g_lastGuardLogTime = TimeCurrent();
   LogInfo(msg);
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
      LogInfo("LINES SL " + DoubleToString(g_basketSL, _Digits) + " -> " + DoubleToString(sl, _Digits)
              + " | TP " + DoubleToString(g_basketTP, _Digits) + " -> " + DoubleToString(tp, _Digits)
              + " (tighter update / wider ignored)");

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
   if(!g_UseVirtualMaSL) return;

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

// Resolve TF1 swing anchor for the open basket direction via g_SwingSLMode
// (independent of entry g_BosMode).
// Zigzag: fibo-gun leg start (olderPrice) when leg matches basket side.
// Fractal: active fractal low (buy) / high (sell).
// BOTH_AND: both required; use the tighter of the two.
bool GetSwingAnchor(const bool isBuy, double &swing, string &engineTag)
{
   swing = 0;
   engineTag = "";

   bool needZ = (g_SwingSLMode == BOS_ZIGZAG || g_SwingSLMode == BOS_BOTH_AND);
   bool needF = (g_SwingSLMode == BOS_FRACTAL || g_SwingSLMode == BOS_BOTH_AND);

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

   if(g_SwingSLMode == BOS_ZIGZAG)
   {
      if(!haveZ) return false;
      swing = zSwing; engineTag = "zigzag";
      return true;
   }
   if(g_SwingSLMode == BOS_FRACTAL)
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

// Swing / last-low(high): virtual, follows g_SwingSLMode, ratchet tighten-only.
// BUY exits if bid <= swingSL; SELL if ask >= swingSL (buffer baked into line).
void CheckSwingVirtualSL()
{
   if(!g_UseSwingVirtualSL) return;

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
   if(!GetSwingAnchor(isBuy, rawSwing, engineTag)) return;
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
                " (TF1 " + engineTag + " SwMode=" + EnumToString(g_SwingSLMode) +
                ", raw swing " + DoubleToString(rawSwing, _Digits) + ", tighten-only) — closing basket");
   CloseAllEA("virtual swing SL");
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

   // Always clear trail/line state when flat (even if Trail chip is off).
   if(count == 0) { ResetBasket(); ResetBasketLines(); return; }
   if(!g_UseBasketTP) return;

   if(!g_basketArmed)
   {
      if(totalPips >= BasketStartPips)
      { g_basketArmed = true; g_basketPeak = totalPips; }
   }
   else
   {
      if(totalPips > g_basketPeak) g_basketPeak = totalPips;
      if(g_basketPeak - totalPips >= BasketGivebackPips)
         CloseAllEA("basket giveback");
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
      // Fresh state so the next basket cannot inherit armed peak / swing / pending lines.
      ResetBasket();
      ResetBasketLines();
   }
}

bool PassesMAFilter(bool wantBuy)
{
   if(!g_UseMAFilter) return true;
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