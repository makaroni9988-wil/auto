//+------------------------------------------------------------------+
//|                                                      lets-go.mq5 |
//|           Modular dual-TF confluence grid EA                     |
//|                                                                  |
//|  Skeleton: grid, basket SL/TP, virtual exits, session/weekend/   |
//|  news/market guards, modify-retry.                               |
//|                                                                  |
//|  Entry  : LTF = entry (every ON module must pass — all AND).     |
//|           HTF = zone bias (rsi / stoch / fib / macd / ma).       |
//|           Open when LTF ready, and HTF ready if AND mode.        |
//|           Signal clock = LTF new bar.                            |
//|           LTF Stoch: cross OR classic. S/R: bounce OR retest.    |
//|           Enabled families AND with each other.                  |
//|           BOS: scan own/HTF/both; engine Zig/Frac/Both;          |
//|           signal evt/bias (evt = once per structure-TF bar).     |
//|           S/R levels: own or HTF (PA = LTF).                     |
//|           HTF stoch: independent mid or OS/OB mom/rev zone.      |
//|           HTF MA: independent own setup or shared LTF handles.   |
//|           MA: one module per TF — panel m1 / m2.                 |
//|           MA check per TF: run / close / closed (no live gate).  |
//|           MaSL: ON/OFF + Fast/Slow exit line (LTF MA lines).     |
//|           Grid chip OFF → 1 layer; ON → MaxLayers.               |
//|           BosMode / SwingSLMode independent. FibZone may arm on  |
//|           bar and re-check zone every tick while module is ON.   |
//|  Exits  : broker pip-cap; optional virtual MaSL and/or SwSL.     |
//|  Panel  : chip toggles (top-left), GV memory.                    |
//|  Journal: Tag "lets-go #magic SYMBOL". Push INIT/BASKET only.    |
//|                                                                  |
//|  TEST ON DEMO / STRATEGY TESTER FIRST. Not a profit guarantee.   |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "5.25"

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_LABEL "lets-go"

//====================== ENUMS ======================
enum ENUM_CONF_MODE
{
   CONF_LTF_ONLY,     // LTF entry only
   CONF_LTF_AND_HTF   // LTF entry AND HTF bias must agree
};
enum ENUM_STOCH_CROSS_MODE
{
   STOCH_CROSS_PULLBACK, // Cross must land below/above pullback level
   STOCH_CROSS_ANY,      // Any %K/%D cross
   STOCH_CROSS_OSOB      // Cross must come FROM OS (buy) / OB (sell)
};
enum ENUM_STOCH_CLASSIC_MODE
{
   STOCH_CLASSIC_MOM, // Momentum: buy in OB / sell in OS (ride the extreme)
   STOCH_CLASSIC_REV  // Reversal: buy in OS / sell in OB (fade the extreme)
};
enum ENUM_MA_STYLE
{
   MA_STYLE_SINGLE, // m1 — single MA line
   MA_STYLE_DOUBLE  // m2 — fast vs slow
};
enum ENUM_MA_CHECK
{
   MA_CHECK_RUNNING,      // Live side only (+/- buffer)
   MA_CHECK_CANDLE_CLOSE, // Live side + last close must confirm
   MA_CHECK_CLOSED_ONLY   // Last close only — no live gate (bias style)
};
enum ENUM_MA_TREND_MODE
{
   MA_TREND_FOLLOW,   // Buy when price/fast is on the buy side of MA/slow
   MA_TREND_REVERSAL  // Fade: buy when price/fast is on the sell side of MA/slow
};
enum ENUM_BOS_MODE
{
   BOS_ZIGZAG,    // Zigzag structural BOS
   BOS_FRACTAL,   // Fractal structure BOS
   BOS_BOTH_AND   // Both engines must agree
};
enum ENUM_BOS_SIGNAL_MODE
{
   BOS_SIGNAL_EVENT, // Enter only on the bar that breaks structure
   BOS_SIGNAL_BIAS   // Stay buy/sell every bar while bias holds
};
enum ENUM_BOS_BREAK_MODE
{
   BOS_BREAK_CLOSE, // Fractal: close must break level
   BOS_BREAK_WICK   // Fractal: wick may break level
};
enum ENUM_MASL_LINE
{
   MASL_FAST, // m2: fast. m1: same single line
   MASL_SLOW  // m2: slow. m1: same single line
};
enum ENUM_TF_SOURCE
{
   TF_SOURCE_OWN,
   TF_SOURCE_HTF,
   TF_SOURCE_BOTH
};

//====================== INPUTS ======================
input group "===== Confluence (LTF entry, optional HTF bias) ====="
input ENUM_CONF_MODE  ConfluenceMode = CONF_LTF_ONLY; // LTF only, or LTF+HTF
input ENUM_TIMEFRAMES InpLTF         = PERIOD_M30;    // LTF entry (signal clock + virtual exits)
input ENUM_TIMEFRAMES InpHTF         = PERIOD_H1;     // HTF bias (AND mode only)

input group "===== Direction Master ====="
input bool TradeBuy  = true; // Allow BUY
input bool TradeSell = true; // Allow SELL

input group "===== LTF Entry (every ON module must pass — all AND) ====="
// Stoch: cross OR classic if both on. S/R: bounce OR retest if both on.
// Those families then AND with Fib / MACD / RSI / MA / BOS.
input bool LTF_UseStochCross    = false; // Stoch cross
input bool LTF_UseStochClassic  = false; // Stoch classic OS/OB
input bool LTF_UseSrBounce      = false; // S/R bounce
input bool LTF_UseSrBreakRetest = false; // S/R break-retest
input bool LTF_UseFibZone       = false; // Fib golden zone
input bool LTF_UseMacdBias      = false; // MACD bias
input bool LTF_UseRsiBias       = false; // RSI bias
input bool LTF_UseMA            = false; // MA module (panel: m1 / m2)
input bool LTF_UseBos           = true;  // BOS (see BosMode)

input group "===== HTF Bias — zone modules (every ON must pass — all AND) ====="
// Ignored when ConfluenceMode = LTF_ONLY.
// Zone bias: rsi / stoch / fib / macd / ma. (S/R + BOS stay LTF entry only.)
input bool HTF_UseStoch    = false; // HTF stoch on/off (mid or OS/OB)
input bool HTF_StochObOs   = false; // false=mid (%K vs pullback); true=OS/OB
input bool HTF_UseFibZone  = false; // Fib golden zone
input bool HTF_UseMacdBias = false; // MACD bias
input bool HTF_UseRsiBias  = false; // RSI bias (mid-only)
input bool HTF_UseMA       = false; // MA module (panel: m1 / m2)
input bool HTF_MaFromLTF   = false; // HTF MA eval uses LTF handles (panel own/LTF)

input group "===== LTF Stochastic ====="
input int                     StochKPeriod         = 5;                 // Stochastic %K period
input int                     StochDPeriod         = 3;                 // Stochastic %D period
input int                     StochSlowing         = 3;                 // Stochastic slowing
input ENUM_MA_METHOD          StochMAMethod        = MODE_SMA;          // Stochastic MA method
input ENUM_STO_PRICE          StochPriceField      = STO_LOWHIGH;       // Stochastic price field
input ENUM_STOCH_CROSS_MODE   StochCrossMode       = STOCH_CROSS_OSOB;  // Cross mode (only used when Stoch cross is ON)
// Classic OS/OB zone entry style.
input ENUM_STOCH_CLASSIC_MODE StochClassicMode     = STOCH_CLASSIC_REV; // Classic mode (only used when Stoch classic is ON)
input double                  StochPullbackLevel   = 50;                // Pullback level (cross PULLBACK mode + HTF mid)
input double                  StochOversoldLevel   = 20;                // Oversold level (cross OSOB start zone + classic buy zone)
input double                  StochOverboughtLevel = 80;                // Overbought level (cross OSOB start zone + classic sell zone)

input group "===== HTF Stochastic (independent) ====="
input int                     HTF_StochKPeriod         = 5;                 // HTF Stochastic %K period
input int                     HTF_StochDPeriod         = 3;                 // HTF Stochastic %D period
input int                     HTF_StochSlowing         = 3;                 // HTF Stochastic slowing
input ENUM_MA_METHOD          HTF_StochMAMethod        = MODE_SMA;          // HTF Stochastic smoothing method
input ENUM_STO_PRICE          HTF_StochPriceField      = STO_LOWHIGH;       // HTF Stochastic price field
input ENUM_STOCH_CLASSIC_MODE HTF_StochObOsMode        = STOCH_CLASSIC_REV; // HTF OB/OS style: momentum or reversal
input double                  HTF_StochMidLevel        = 50;                // HTF mid-mode threshold
input double                  HTF_StochOversoldLevel   = 20;                // HTF oversold threshold
input double                  HTF_StochOverboughtLevel = 80;                // HTF overbought threshold

input group "===== RSI / MACD (shared params) ====="
input int                RSIPeriod        = 14;          // RSI period
input ENUM_APPLIED_PRICE RSIAppliedPrice  = PRICE_CLOSE; // RSI applied price
input double             RSIMidLevel      = 50;          // RSI must be above(buy)/below(sell) this level
input int                MACDFastEMA      = 12;          // MACD fast EMA
input int                MACDSlowEMA      = 26;          // MACD slow EMA
input int                MACDSignalPeriod = 9;           // MACD signal period
input ENUM_APPLIED_PRICE MACDAppliedPrice = PRICE_CLOSE; // MACD applied price

input group "===== MA (m1 single line / m2 double line + MaSL lines) ====="
// One MA module per TF. Panel chip cycles OFF → m1 → m2.
//   m1 = single MA line (price vs MA, Follow / Reversal).
//   m2 = double line (fast vs slow, Follow / Reversal).
// LTF MACheckMode:
//   RUNNING      = live side check only.
//   CANDLE_CLOSE = live side + last closed bar must confirm.
//   CLOSED_ONLY  = last closed bar only, no live gate (bias style).
// LTF uses these settings. HTF has an independent own setup below.
// Risk row only toggles MaSL + Fast/Slow.
input ENUM_MA_METHOD     MaMethod       = MODE_EMA;    // SMA / EMA / SMMA / LWMA
input ENUM_APPLIED_PRICE MaAppliedPrice = PRICE_CLOSE; // Applied price
input int                MaShift        = 0;           // MA horizontal shift

input ENUM_MA_STYLE MaStyle        = MA_STYLE_DOUBLE;    // Default when LTF/HTF UseMA is ON
input ENUM_MA_CHECK LTF_MACheckMode = MA_CHECK_RUNNING; // LTF Running / CandleClose / ClosedOnly (m1 / m2)
input double        MABufferPips   = 100;                // LTF m1 buffer (pips)

input int MaPeriod     = 34; // Single line (m1)
input int MaFastPeriod = 13; // m2 fast
input int MaSlowPeriod = 34; // m2 slow

// m1 / m2 entry direction.
input ENUM_MA_TREND_MODE LTF_MaTrendMode = MA_TREND_FOLLOW; // LTF m1 / m2 direction
input double             MaMinDiffPips   = 100;             // LTF m2: 0 = any separation

input group "===== HTF MA (independent when panel source = own) ====="
input ENUM_MA_METHOD     HTF_MaMethod       = MODE_EMA;         // HTF own MA method
input ENUM_APPLIED_PRICE HTF_MaAppliedPrice = PRICE_CLOSE;      // HTF own applied price
input int                HTF_MaShift        = 0;                // HTF own horizontal shift
input ENUM_MA_CHECK      HTF_MACheckMode    = MA_CHECK_RUNNING; // HTF own Running / CandleClose / ClosedOnly
input ENUM_MA_TREND_MODE HTF_MaTrendMode    = MA_TREND_FOLLOW;  // HTF own Follow or Reversal
input double             HTF_MABufferPips   = 100;              // HTF own m1 buffer (pips)
input double             HTF_MaMinDiffPips  = 100;              // HTF own m2 minimum separation
input int                HTF_MaPeriod       = 55;               // HTF own single line (m1)
input int                HTF_MaFastPeriod   = 13;               // HTF own m2 fast line
input int                HTF_MaSlowPeriod   = 55;               // HTF own m2 slow line

input group "===== S/R Pivot Entry (LTF entry; levels own or HTF) ====="
input int    PivotLeftBars       = 5;     // Pivot left bars (levels TF)
input int    PivotRightBars      = 5;     // Pivot right bars (levels TF)
input int    LevelsLookback      = 200;   // Bars to scan for pivots on levels TF
input double TouchPips           = 50;    // How close price must get to the level (pips)
input bool   RequireRejectCandle = true;  // Bounce/retest candle must be bullish(buy)/bearish(sell)
input int    BreakLookbackBars   = 12;    // Break-retest: bars to search for the break (LTF)
input ENUM_TF_SOURCE SrLevelsSource = TF_SOURCE_OWN; // S/R levels: own / HTF / both (same-side AND)

input group "===== Fib / BOS entry (shared params, per-TF scan) ====="
input ENUM_BOS_MODE        BosMode             = BOS_FRACTAL;      // Entry BOS engine
input ENUM_BOS_SIGNAL_MODE BosSignalMode       = BOS_SIGNAL_EVENT; // BOS entry mode (evt/bias)
input ENUM_TF_SOURCE       BosStructureSource = TF_SOURCE_OWN;     // BOS structure: own / HTF / both (same-side AND)

input double FibDeviationMult = 3.0;   // Zigzag: ATR deviation multiplier
input int    FibDepth         = 6;     // Zigzag: depth (confirm = Depth/2)
input int    FibATRPeriod     = 10;    // Zigzag: ATR period
input int    FibLookbackBars  = 100;   // Zigzag: bars scanned
input double FibZoneLevelMin  = 0.382; // FibZone: shallow edge
input double FibZoneLevelMax  = 0.618; // FibZone: deep edge

input int                 BosFractalPeriod   = 3;              // Fractal: bars each side
input ENUM_BOS_BREAK_MODE BosBreakMode       = BOS_BREAK_WICK; // Fractal break type
input int                 BosFractalLookback = 200;            // Fractal: bars scanned

input group "===== Stop / Exit ====="
// Broker SL = hard pip cap. Virtual MA / swing SL are optional; first hit closes.
// MaSL uses LTF MA lines. m1: Fast/Slow both = single. m2: Fast vs Slow.
input bool           UseVirtualMaSL = false;     // Virtual MA stop ON/OFF
input ENUM_MASL_LINE MaSLLine       = MASL_SLOW; // Default Fast/Slow (panel)
input double         SLMABufferPips = 100;       // MA SL buffer (pips)

input bool          UseSwingVirtualSL = true;        // Virtual swing stop (tighten-only)
input ENUM_BOS_MODE SwingSLMode       = BOS_FRACTAL; // Swing SL engine (independent of BosMode)
input double        SwingSLBufferPips = 100;         // Air beyond swing (pips)

input group "===== Orders / Risk (basket lines: shared SL/TP, tighter-only) ====="
input double LotSize         = 0.01;   // Lots per layer
input int    MaxStopLossPips = 500;    // Hard broker SL (pips)
input int    TakeProfitPips  = 3000;   // Broker TP (pips)
input int    MaxSpreadPips   = 0;      // Skip new entries above this spread (0 = ignore)
input int    SlippagePoints  = 20;     // Max deviation for market orders (points)
input long   MagicNumber     = 778899; // EA id

input group "===== Grid Layering ====="
input bool UseGrid       = false; // Panel Grid OFF = 1 layer; ON = MaxLayers
input int  MaxLayers     = 1;     // Max open layers when Grid ON
input int  LayerStepPips = 200;   // Min adverse move before next layer

input group "===== Basket Take-Profit (pips, trailing) ====="
input bool   UseBasketTP        = true; // Manage profit as a basket in pips (works alongside broker TP)
input double BasketStartPips    = 500;  // Arm trail after this open profit
input double BasketGivebackPips = 200;  // Pullback from peak before close

input group "===== Basket SL/TP Modify Retry ====="
input int ModifyRetryMax                = 3;    // Modify retry max (attempts per burst)
input int ModifyRetryDelayMs            = 500;  // Modify retry delay ms (between attempts)
input int MaxConsecutiveRetryCooldownMs = 2000; // Max consecutive retry cooldown ms (between failed bursts)

input group "===== Session Filter (WIB / Jakarta time) ====="
input int  SessionTZOffset     = 7;    // UTC offset for inputs below (7 = WIB Jakarta)
input bool UseSession          = true; // Enable daily trading-hours window
input int  SessionStartHour    = 6;    // Daily window FROM this hour WIB (0-23)
input int  SessionEndHour      = 3;    // NO new entries from this hour WIB (crosses midnight: 6→3)
input bool CloseAtSessionEnd   = true; // Flatten when outside the daily window (e.g. at 03:00)
input bool UseWeekendFilter    = true; // Block weekend gap (WIB)
input int  WeekendStopDayWIB   = 6;    // Weekend starts this day (0=Sun … 5=Fri 6=Sat)
input int  WeekendStopHourWIB  = 3;    // …from this hour (Sat 03:00 = after last Fri session)
input int  WeekendStartDayWIB  = 1;    // Weekend ends this day (1=Mon)
input int  WeekendStartHourWIB = 6;    // …resume from this hour (Mon 06:00)
input bool CloseAtWeekend      = true; // Flatten when the weekend block starts

input group "===== News Filter (economic calendar) ====="
input bool                           UseNewsFilter     = true;                         // Block/flatten around economic news
input ENUM_CALENDAR_EVENT_IMPORTANCE NewsMinImportance = CALENDAR_IMPORTANCE_MODERATE; // Minimum importance to react to
input string                         NewsCurrency      = "USD";                        // Currency to watch (USD for XAUUSD)
input int                            NewsMinutesBefore = 15;                           // Stop entries this long before the event
input int                            NewsMinutesAfter  = 15;                           // Resume this long after the event
input bool                           CloseAtNews       = true;                         // Flatten when the news blackout starts

input group "===== Market Guard (holidays / early close) ====="
input bool UseBrokerSessionGuard = true; // Respect broker symbol trade sessions (Jul 4, etc.)
input int  MaxStaleTickSeconds   = 120;  // No new trades if no tick for this long (0 = ignore)
input int  OrderRetryCooldownSec = 60;   // After a failed order/close, wait before retrying

input group "===== Chip Panel (click toggles) ====="
input bool ShowPanel           = true;  // Show chip panel (top-left)
input int  PanelInsetX         = 3;     // Inset from left
input int  PanelInsetY         = 25;    // Inset from top
input bool PanelRemember       = true;  // Remember toggles (GV)
input bool PanelStartCollapsed = false; // Start minimized
input uint PanelClickGuardMs   = 200;   // Double-click guard (ms)

input group "===== Logging ====="
input bool InpDetailedBlockedLog = true;  // BLOCKED: list enabled LTF / HTF modules
input bool InpDebugLog           = false; // Panel clicks + memory notes

//====================== RUNTIME TOGGLES (panel + GV; inputs = defaults) ======================
// MA module per TF: 0=OFF, 1=m1 (single line), 2=m2 (double line)
#define MA_OFF    0
#define MA_SINGLE 1
#define MA_DOUBLE 2

ENUM_CONF_MODE g_ConfluenceMode;
ENUM_BOS_MODE  g_BosMode;
ENUM_BOS_MODE  g_SwingSLMode;
ENUM_BOS_SIGNAL_MODE g_BosSignalMode;
ENUM_BOS_BREAK_MODE g_BosBreakMode;
ENUM_STOCH_CROSS_MODE g_StochCrossMode;
ENUM_STOCH_CLASSIC_MODE g_StochClassicMode;
ENUM_STOCH_CLASSIC_MODE g_HTF_StochObOsMode;
ENUM_MA_CHECK g_LTF_MACheckMode, g_HTF_MACheckMode;
ENUM_MA_TREND_MODE g_LTF_MaTrendMode, g_HTF_MaTrendMode;
ENUM_TF_SOURCE g_BosSource, g_SrSource;
bool g_TradeBuy, g_TradeSell;
bool g_UseGrid;
int  g_MaxLayers;
bool g_LTF_UseStochCross, g_LTF_UseStochClassic, g_LTF_UseSrBounce, g_LTF_UseSrBreakRetest;
bool g_LTF_UseFibZone, g_LTF_UseMacdBias, g_LTF_UseRsiBias, g_LTF_UseBos;
bool g_HTF_UseStoch, g_HTF_StochObOs;
bool g_HTF_UseFibZone, g_HTF_UseMacdBias, g_HTF_UseRsiBias;
bool g_HTF_MaFromLTF = false;   // HTF MA eval on LTF handles
int  g_LTF_MA = MA_OFF;
int  g_HTF_MA = MA_OFF;
bool g_UseVirtualMaSL, g_UseSwingVirtualSL, g_UseBasketTP;
bool g_RequireRejectCandle;
bool g_UseSession, g_UseWeekendFilter, g_UseNewsFilter, g_UseBrokerSessionGuard;
ENUM_MASL_LINE g_MaSLLine = MASL_SLOW;

int EffectiveMaxLayers()
{
   return g_UseGrid ? MathMax(1, g_MaxLayers) : 1;
}

bool MaEnabled(const int state)
{
   return (state == MA_SINGLE || state == MA_DOUBLE);
}

bool MaUsesSingleLine(const int state)
{
   return (state == MA_SINGLE);
}

int MaStyleToState(const ENUM_MA_STYLE style)
{
   if(style == MA_STYLE_SINGLE) return MA_SINGLE;
   return MA_DOUBLE;
}

int MaStateFromInputs(const bool useIt)
{
   if(!useIt) return MA_OFF;
   return MaStyleToState(MaStyle);
}

// MaSL line family from LTF MA module; if OFF, use input MaStyle default.
int MaExitState()
{
   if(MaEnabled(g_LTF_MA)) return g_LTF_MA;
   return MaStyleToState(MaStyle);
}

bool MaExitUsesSingleLine()
{
   return MaUsesSingleLine(MaExitState());
}

string g_gvPrefix = "";
string g_panelPrefix = "";
bool   g_panelCollapsed = false;
bool   g_quietInit = false;          // TF-change reinit: keep logs quiet
ulong  g_panelLastClickMs = 0;

// Per-category throttle for LogGuardOnce (guard spam never suppresses a
// different category, e.g. a routine session-closed note can no longer
// eat a genuine FAIL / EXIT line for up to 5 minutes).
string   g_guardLogKeys[];
datetime g_guardLogTimes[];
//====================== GLOBALS ======================
ENUM_TIMEFRAMES g_ltf;
ENUM_TIMEFRAMES g_htf;

int g_stochL = INVALID_HANDLE, g_rsiL = INVALID_HANDLE, g_macdL = INVALID_HANDLE;
int g_maL    = INVALID_HANDLE, g_maFL = INVALID_HANDLE, g_maSL = INVALID_HANDLE, g_atrL = INVALID_HANDLE;
int g_stochH = INVALID_HANDLE, g_rsiH = INVALID_HANDLE, g_macdH = INVALID_HANDLE;
int g_maH    = INVALID_HANDLE, g_maFH = INVALID_HANDLE, g_maSH = INVALID_HANDLE, g_atrH = INVALID_HANDLE;

double   g_pip = 0;
datetime g_lastBarTime  = 0;
datetime g_lastEntryBar = 0;

bool   g_haveSignal  = false;
bool   g_signalIsBuy = false;
// True when signal is armed by FibZone leg but price not yet in zone at bar eval.
// TryEnter re-checks live zone every tick while FibZone is ON.
bool   g_fibZoneTickGate = false;

// BOS EVENT: one latch per structure TF (BOTH must never share one timestamp).
datetime g_bosEventSeenLtfBar = 0;
datetime g_bosEventSeenHtfBar = 0;

bool   g_basketArmed = false;
double g_basketPeak  = 0;

double g_basketSL = 0;
double g_basketTP = 0;

// Swing virtual SL ratchet (tighten-only while basket is open)
bool   g_haveSwingSL = false;
double g_swingSL     = 0;

datetime g_lastEntryFailTime = 0;
datetime g_lastCloseFailTime = 0;
datetime g_lastDiagBar       = 0;

bool  g_newsBlackoutCached = false;
ulong g_newsLastCheckMs    = 0;

bool   g_modifyPending     = false;
double g_pendingSL         = 0;
double g_pendingTP         = 0;
ulong  g_lastModifyBurstMs = 0;

//====================== LOGGING / PUSH ======================
// Journal:  lets-go #magic SYMBOL | OPEN/CLOSE/LINES/FAIL/INIT/...
// Push: INIT FAILED + BASKET CLOSED only. InpDebugLog = panel notes.
string Tag() { return EA_LABEL + " #" + IntegerToString(MagicNumber) + " " + _Symbol; }
void LogInfo(const string msg)  { Print(Tag(), " | ", msg); }
void LogDebug(const string msg) { if(InpDebugLog) Print(Tag(), " | ", msg); }

void NotifyPush(const string msg)
{
   if(!SendNotification(Tag() + ": " + msg))
      LogInfo("PUSH FAILED - " + msg);
}

bool CreateTfHandles(const ENUM_TIMEFRAMES tf,
                     const bool useCross, const bool useClassic,
                     const bool useMacd, const bool useRsi, const bool useMA,
                     const bool useFib, const bool useBos,
                     const int stochK, const int stochD, const int stochSlowing,
                     const ENUM_MA_METHOD stochMethod, const ENUM_STO_PRICE stochPrice,
                     const int maPeriod, const int maFastPeriod, const int maSlowPeriod,
                     const int maShift, const ENUM_MA_METHOD maMethod,
                     const ENUM_APPLIED_PRICE maPrice,
                     int &hStoch, int &hRsi, int &hMacd,
                     int &hMaSingle, int &hMaFast, int &hMaSlow, int &hAtr,
                     const string label)
{
   if(useCross || useClassic)
   {
      hStoch = iStochastic(_Symbol, tf, stochK, stochD, stochSlowing, stochMethod, stochPrice);
      if(hStoch == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " Stochastic");
         NotifyPush("INIT FAILED - " + label + " Stochastic");
         return false;
      }
   }
   if(useRsi)
   {
      hRsi = iRSI(_Symbol, tf, RSIPeriod, RSIAppliedPrice);
      if(hRsi == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " RSI");
         NotifyPush("INIT FAILED - " + label + " RSI");
         return false;
      }
   }
   if(useMacd)
   {
      hMacd = iMACD(_Symbol, tf, MACDFastEMA, MACDSlowEMA, MACDSignalPeriod, MACDAppliedPrice);
      if(hMacd == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " MACD");
         NotifyPush("INIT FAILED - " + label + " MACD");
         return false;
      }
   }
   // Single + fast + slow so panel can cycle m1/m2 (and MaSL Fast/Slow) without reattach.
   if(useMA)
   {
      hMaSingle = iMA(_Symbol, tf, MathMax(1, maPeriod),     maShift, maMethod, maPrice);
      hMaFast   = iMA(_Symbol, tf, MathMax(1, maFastPeriod), maShift, maMethod, maPrice);
      hMaSlow   = iMA(_Symbol, tf, MathMax(1, maSlowPeriod), maShift, maMethod, maPrice);
      if(hMaSingle == INVALID_HANDLE || hMaFast == INVALID_HANDLE || hMaSlow == INVALID_HANDLE)
      {
         LogInfo("INIT FAILED - " + label + " MA");
         NotifyPush("INIT FAILED - " + label + " MA");
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
         NotifyPush("INIT FAILED - " + label + " ATR");
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
   return "v517|" + IntegerToString((int)ConfluenceMode) + "|"
        + IntegerToString((int)BosMode) + "|"
        + IntegerToString((int)BosSignalMode) + "|"
        + IntegerToString((int)BosBreakMode) + "|"
        + IntegerToString((int)BosStructureSource) + "|"
        + IntegerToString((int)SwingSLMode) + "|"
        + IntegerToString((int)TradeBuy) + IntegerToString((int)TradeSell) + "|"
        + IntegerToString((int)UseGrid) + "|" + IntegerToString(MaxLayers) + "|"
        + IntegerToString((int)LTF_UseStochCross) + IntegerToString((int)LTF_UseStochClassic)
        + IntegerToString((int)LTF_UseSrBounce) + IntegerToString((int)LTF_UseSrBreakRetest)
        + IntegerToString((int)LTF_UseFibZone) + IntegerToString((int)LTF_UseMacdBias)
        + IntegerToString((int)LTF_UseRsiBias) + IntegerToString((int)LTF_UseMA)
        + IntegerToString((int)LTF_UseBos) + "|"
        + IntegerToString((int)StochCrossMode) + IntegerToString((int)StochClassicMode) + "|"
        + IntegerToString((int)LTF_MaTrendMode) + "|" + IntegerToString((int)LTF_MACheckMode) + "|"
        + IntegerToString((int)HTF_UseStoch) + IntegerToString((int)HTF_StochObOs)
        + IntegerToString((int)HTF_UseFibZone) + IntegerToString((int)HTF_UseMacdBias)
        + IntegerToString((int)HTF_UseRsiBias) + IntegerToString((int)HTF_UseMA)
        + IntegerToString((int)HTF_MaFromLTF) + "|" + IntegerToString((int)HTF_StochObOsMode) + "|"
        + IntegerToString((int)HTF_MaTrendMode) + "|" + IntegerToString((int)HTF_MACheckMode) + "|"
        + IntegerToString((int)SrLevelsSource) + "|" + IntegerToString((int)RequireRejectCandle) + "|"
        + IntegerToString((int)MaStyle) + IntegerToString((int)MaMethod)
        + IntegerToString(HTF_MaPeriod) + IntegerToString(HTF_MaFastPeriod)
        + IntegerToString(HTF_MaSlowPeriod)
        + IntegerToString((int)MaSLLine) + "|"
        + IntegerToString((int)UseVirtualMaSL)
        + IntegerToString((int)UseSwingVirtualSL) + IntegerToString((int)UseBasketTP) + "|"
        + IntegerToString((int)UseSession) + IntegerToString((int)UseWeekendFilter)
        + IntegerToString((int)UseNewsFilter) + IntegerToString((int)UseBrokerSessionGuard);
}

void RuntimeApplyInputDefaults()
{
   g_ConfluenceMode = ConfluenceMode;
   g_BosMode = BosMode;
   g_BosSignalMode = BosSignalMode;
   g_BosBreakMode = BosBreakMode;
   g_BosSource = BosStructureSource;
   g_SwingSLMode = SwingSLMode;
   g_TradeBuy = TradeBuy;
   g_TradeSell = TradeSell;
   g_UseGrid = UseGrid;
   g_MaxLayers = MathMax(1, MathMin(3, MaxLayers));
   g_StochCrossMode = StochCrossMode;
   g_StochClassicMode = StochClassicMode;
   g_LTF_MaTrendMode = LTF_MaTrendMode;
   g_LTF_MACheckMode = LTF_MACheckMode;

   g_LTF_UseStochCross = LTF_UseStochCross;
   g_LTF_UseStochClassic = LTF_UseStochClassic;
   g_LTF_UseSrBounce = LTF_UseSrBounce;
   g_LTF_UseSrBreakRetest = LTF_UseSrBreakRetest;
   g_LTF_UseFibZone = LTF_UseFibZone;
   g_LTF_UseMacdBias = LTF_UseMacdBias;
   g_LTF_UseRsiBias = LTF_UseRsiBias;
   g_LTF_MA = MaStateFromInputs(LTF_UseMA);
   g_LTF_UseBos = LTF_UseBos;

   g_HTF_UseStoch = HTF_UseStoch;
   g_HTF_StochObOs = HTF_StochObOs;
   g_HTF_StochObOsMode = HTF_StochObOsMode;
   g_HTF_UseFibZone = HTF_UseFibZone;
   g_HTF_UseMacdBias = HTF_UseMacdBias;
   g_HTF_UseRsiBias = HTF_UseRsiBias;
   g_HTF_MA = MaStateFromInputs(HTF_UseMA);
   g_HTF_MaFromLTF = HTF_MaFromLTF;
   g_HTF_MaTrendMode = HTF_MaTrendMode;
   g_HTF_MACheckMode = HTF_MACheckMode;
   g_SrSource = SrLevelsSource;
   g_RequireRejectCandle = RequireRejectCandle;

   g_UseVirtualMaSL = UseVirtualMaSL;
   g_MaSLLine = MaSLLine;
   g_UseSwingVirtualSL = UseSwingVirtualSL;
   g_UseBasketTP = UseBasketTP;
   g_UseSession = UseSession;
   g_UseWeekendFilter = UseWeekendFilter;
   g_UseNewsFilter = UseNewsFilter;
   g_UseBrokerSessionGuard = UseBrokerSessionGuard;
}

void RuntimeSaveAllToGV()
{
   if(!PanelRemember) return;
   PanelSaveInt("Conf", (int)g_ConfluenceMode);
   PanelSaveInt("BosMode", (int)g_BosMode);
   PanelSaveInt("BosSig", (int)g_BosSignalMode);
   PanelSaveInt("BosBrk", (int)g_BosBreakMode);
   PanelSaveInt("BosSrc", (int)g_BosSource);
   PanelSaveInt("SwMode", (int)g_SwingSLMode);
   PanelSaveBool("Buy", g_TradeBuy);
   PanelSaveBool("Sell", g_TradeSell);
   PanelSaveBool("Grid", g_UseGrid);
   PanelSaveInt("GridN", g_MaxLayers);
   PanelSaveInt("StXMode", (int)g_StochCrossMode);
   PanelSaveInt("StCMode", (int)g_StochClassicMode);
   PanelSaveInt("T1_MaDir", (int)g_LTF_MaTrendMode);
   PanelSaveInt("T1_MaChk", (int)g_LTF_MACheckMode);

   PanelSaveBool("T1_stX", g_LTF_UseStochCross);
   PanelSaveBool("T1_stC", g_LTF_UseStochClassic);
   PanelSaveBool("T1_srB", g_LTF_UseSrBounce);
   PanelSaveBool("T1_srR", g_LTF_UseSrBreakRetest);
   PanelSaveBool("T1_fib", g_LTF_UseFibZone);
   PanelSaveBool("T1_macd", g_LTF_UseMacdBias);
   PanelSaveBool("T1_rsi", g_LTF_UseRsiBias);
   PanelSaveInt("T1_ma", g_LTF_MA);
   PanelSaveBool("T1_bos", g_LTF_UseBos);
   PanelSaveInt("SrLv", (int)g_SrSource);
   PanelSaveBool("SrRej", g_RequireRejectCandle);

   PanelSaveBool("T2_stoch", g_HTF_UseStoch);
   PanelSaveBool("T2_stOb", g_HTF_StochObOs);
   PanelSaveInt("T2_stDir", (int)g_HTF_StochObOsMode);
   PanelSaveBool("T2_fib", g_HTF_UseFibZone);
   PanelSaveBool("T2_macd", g_HTF_UseMacdBias);
   PanelSaveBool("T2_rsi", g_HTF_UseRsiBias);
   PanelSaveInt("T2_ma", g_HTF_MA);
   PanelSaveBool("T2_maLTF", g_HTF_MaFromLTF);
   PanelSaveInt("T2_MaDir", (int)g_HTF_MaTrendMode);
   PanelSaveInt("T2_MaChk", (int)g_HTF_MACheckMode);

   PanelSaveBool("MaSL", g_UseVirtualMaSL);
   PanelSaveInt("MaLn", (int)g_MaSLLine);
   PanelSaveBool("SwSL", g_UseSwingVirtualSL);
   PanelSaveBool("Trail", g_UseBasketTP);
   PanelSaveBool("Session", g_UseSession);
   PanelSaveBool("Weekend", g_UseWeekendFilter);
   PanelSaveBool("News", g_UseNewsFilter);
   PanelSaveBool("Broker", g_UseBrokerSessionGuard);
   PanelSaveBool("Collapsed", g_panelCollapsed);
}

void RuntimeLoadFromGV()
{
   g_ConfluenceMode = (ENUM_CONF_MODE)PanelLoadInt("Conf", (int)g_ConfluenceMode);
   g_BosMode = (ENUM_BOS_MODE)PanelLoadInt("BosMode", (int)g_BosMode);
   g_BosSignalMode = (ENUM_BOS_SIGNAL_MODE)PanelLoadInt("BosSig", (int)g_BosSignalMode);
   g_BosBreakMode = (ENUM_BOS_BREAK_MODE)PanelLoadInt("BosBrk", (int)g_BosBreakMode);
   g_BosSource = (ENUM_TF_SOURCE)PanelLoadInt("BosSrc", (int)g_BosSource);
   g_SwingSLMode = (ENUM_BOS_MODE)PanelLoadInt("SwMode", (int)g_SwingSLMode);
   g_TradeBuy = PanelLoadBool("Buy", g_TradeBuy);
   g_TradeSell = PanelLoadBool("Sell", g_TradeSell);
   g_UseGrid = PanelLoadBool("Grid", g_UseGrid);
   g_MaxLayers = PanelLoadInt("GridN", g_MaxLayers);
   g_StochCrossMode = (ENUM_STOCH_CROSS_MODE)PanelLoadInt("StXMode", (int)g_StochCrossMode);
   g_StochClassicMode = (ENUM_STOCH_CLASSIC_MODE)PanelLoadInt("StCMode", (int)g_StochClassicMode);
   g_LTF_MaTrendMode = (ENUM_MA_TREND_MODE)PanelLoadInt("T1_MaDir", (int)g_LTF_MaTrendMode);
   g_LTF_MACheckMode = (ENUM_MA_CHECK)PanelLoadInt("T1_MaChk", (int)g_LTF_MACheckMode);

   g_LTF_UseStochCross = PanelLoadBool("T1_stX", g_LTF_UseStochCross);
   g_LTF_UseStochClassic = PanelLoadBool("T1_stC", g_LTF_UseStochClassic);
   g_LTF_UseSrBounce = PanelLoadBool("T1_srB", g_LTF_UseSrBounce);
   g_LTF_UseSrBreakRetest = PanelLoadBool("T1_srR", g_LTF_UseSrBreakRetest);
   g_LTF_UseFibZone = PanelLoadBool("T1_fib", g_LTF_UseFibZone);
   g_LTF_UseMacdBias = PanelLoadBool("T1_macd", g_LTF_UseMacdBias);
   g_LTF_UseRsiBias = PanelLoadBool("T1_rsi", g_LTF_UseRsiBias);
   g_LTF_MA = PanelLoadInt("T1_ma", g_LTF_MA);
   g_LTF_UseBos = PanelLoadBool("T1_bos", g_LTF_UseBos);
   g_SrSource = (ENUM_TF_SOURCE)PanelLoadInt("SrLv", (int)g_SrSource);
   g_RequireRejectCandle = PanelLoadBool("SrRej", g_RequireRejectCandle);

   g_HTF_UseStoch = PanelLoadBool("T2_stoch", g_HTF_UseStoch);
   g_HTF_StochObOs = PanelLoadBool("T2_stOb", g_HTF_StochObOs);
   g_HTF_StochObOsMode = (ENUM_STOCH_CLASSIC_MODE)PanelLoadInt("T2_stDir", (int)g_HTF_StochObOsMode);
   g_HTF_UseFibZone = PanelLoadBool("T2_fib", g_HTF_UseFibZone);
   g_HTF_UseMacdBias = PanelLoadBool("T2_macd", g_HTF_UseMacdBias);
   g_HTF_UseRsiBias = PanelLoadBool("T2_rsi", g_HTF_UseRsiBias);
   g_HTF_MA = PanelLoadInt("T2_ma", g_HTF_MA);
   g_HTF_MaFromLTF = PanelLoadBool("T2_maLTF", g_HTF_MaFromLTF);
   g_HTF_MaTrendMode = (ENUM_MA_TREND_MODE)PanelLoadInt("T2_MaDir", (int)g_HTF_MaTrendMode);
   g_HTF_MACheckMode = (ENUM_MA_CHECK)PanelLoadInt("T2_MaChk", (int)g_HTF_MACheckMode);

   if(g_LTF_MA != MA_OFF && g_LTF_MA != MA_SINGLE && g_LTF_MA != MA_DOUBLE)
      g_LTF_MA = MA_OFF;
   if(g_HTF_MA != MA_OFF && g_HTF_MA != MA_SINGLE && g_HTF_MA != MA_DOUBLE)
      g_HTF_MA = MA_OFF;

   g_UseVirtualMaSL = PanelLoadBool("MaSL", g_UseVirtualMaSL);
   g_MaSLLine = (ENUM_MASL_LINE)PanelLoadInt("MaLn", (int)g_MaSLLine);
   if(g_MaSLLine != MASL_FAST && g_MaSLLine != MASL_SLOW)
      g_MaSLLine = MASL_SLOW;
   g_UseSwingVirtualSL = PanelLoadBool("SwSL", g_UseSwingVirtualSL);
   g_UseBasketTP = PanelLoadBool("Trail", g_UseBasketTP);
   g_UseSession = PanelLoadBool("Session", g_UseSession);
   g_UseWeekendFilter = PanelLoadBool("Weekend", g_UseWeekendFilter);
   g_UseNewsFilter = PanelLoadBool("News", g_UseNewsFilter);
   g_UseBrokerSessionGuard = PanelLoadBool("Broker", g_UseBrokerSessionGuard);
   g_panelCollapsed = PanelLoadBool("Collapsed", g_panelCollapsed);

   // Corrupt GV memory → fall back to input defaults
   if(g_ConfluenceMode != CONF_LTF_ONLY && g_ConfluenceMode != CONF_LTF_AND_HTF)
      g_ConfluenceMode = CONF_LTF_ONLY;
   if(g_BosMode != BOS_ZIGZAG && g_BosMode != BOS_FRACTAL && g_BosMode != BOS_BOTH_AND)
      g_BosMode = BOS_FRACTAL;
   if(g_BosSignalMode != BOS_SIGNAL_EVENT && g_BosSignalMode != BOS_SIGNAL_BIAS)
      g_BosSignalMode = BOS_SIGNAL_EVENT;
   if(g_BosBreakMode != BOS_BREAK_CLOSE && g_BosBreakMode != BOS_BREAK_WICK)
      g_BosBreakMode = BOS_BREAK_WICK;
   if(g_BosSource < TF_SOURCE_OWN || g_BosSource > TF_SOURCE_BOTH)
      g_BosSource = TF_SOURCE_OWN;
   if(g_SrSource < TF_SOURCE_OWN || g_SrSource > TF_SOURCE_BOTH)
      g_SrSource = TF_SOURCE_OWN;
   g_MaxLayers = MathMax(1, MathMin(3, g_MaxLayers));
   if(g_SwingSLMode != BOS_ZIGZAG && g_SwingSLMode != BOS_FRACTAL && g_SwingSLMode != BOS_BOTH_AND)
      g_SwingSLMode = BOS_FRACTAL;
   if(g_StochCrossMode != STOCH_CROSS_PULLBACK && g_StochCrossMode != STOCH_CROSS_ANY
      && g_StochCrossMode != STOCH_CROSS_OSOB)
      g_StochCrossMode = STOCH_CROSS_OSOB;
   if(g_StochClassicMode != STOCH_CLASSIC_MOM && g_StochClassicMode != STOCH_CLASSIC_REV)
      g_StochClassicMode = STOCH_CLASSIC_REV;
   if(g_HTF_StochObOsMode != STOCH_CLASSIC_MOM && g_HTF_StochObOsMode != STOCH_CLASSIC_REV)
      g_HTF_StochObOsMode = STOCH_CLASSIC_REV;
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
      "INP_FP","Conf","BosMode","BosSig","BosBrk","BosSrc","SwMode","Buy","Sell","Grid","GridN","Collapsed","SrLv","SrRej",
      "StXMode","StCMode","T1_MaDir","T1_MaChk",
      "T1_stX","T1_stC","T1_srB","T1_srR","T1_fib","T1_macd","T1_rsi","T1_ma","T1_bos",
      "T2_stoch","T2_stOb","T2_stDir","T2_fib","T2_macd","T2_rsi","T2_ma","T2_maLTF","T2_MaDir","T2_MaChk",
      "MaSL","MaLn","SwSL","Trail","Session","Weekend","News","Broker"
   };
   for(int i = 0; i < ArraySize(ids); i++)
      GlobalVariableDel(PanelGvKey(ids[i]));
}

//====================== CHIP PANEL UI ======================
// Always top-left. Position = PanelInsetX / PanelInsetY.
string PanelObj(const string id) { return g_panelPrefix + id; }

bool PanelIsNonInteractiveId(const string id)
{
   if(id == "L1" || id == "L2" || id == "LG" || id == "LR" ||
      id == "SRLBL" || id == "GuardSt")
      return true;
   if(StringFind(id, "Sp") == 0) return true;
   if(StringFind(id, "Fam") == 0) return true;
   if(StringFind(id, "Tag") == 0) return true;
   return false;
}

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

void PanelStyleDisabled(const string name, const string text, const string tip)
{
   ObjectSetString (0, name, OBJPROP_TEXT, text);
   ObjectSetString (0, name, OBJPROP_TOOLTIP, tip);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'90,90,90');
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'32,32,32');
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'28,28,28');
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
}

void PanelStyleFamily(const string name, const string text, const string tip, const bool isOr)
{
   ObjectSetString (0, name, OBJPROP_TEXT, text);
   ObjectSetString (0, name, OBJPROP_TOOLTIP, tip);
   if(isOr)
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR, C'240,205,140');
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'54,44,26');
      ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'120,92,44');
   }
   else
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR, C'150,220,220');
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'24,46,46');
      ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'54,96,96');
   }
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
}

void PanelStyleStatus(const string name, const bool blocked)
{
   ObjectSetString (0, name, OBJPROP_TEXT, blocked ? "BLOCK" : "OPEN");
   ObjectSetString (0, name, OBJPROP_TOOLTIP, "Current combined entry-guard status");
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'245,245,245');
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, blocked ? C'130,55,55' : C'40,110,92');
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, blocked ? C'175,75,75' : C'80,160,130');
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

void PanelPlaceEvenRow(const string &ids[], const int n,
                       const int x0, const int y,
                       const int rowW, const int gap, const int chipH)
{
   if(n <= 0) return;
   const int body  = rowW - gap * (n - 1);
   const int chipW = body / n;
   const int step  = chipW + gap;
   for(int i = 0; i < n; i++)
      PanelEnsureButton(ids[i], x0 + step * i, y, chipW, chipH);
}

string ConfChipText()
{
   return (g_ConfluenceMode == CONF_LTF_ONLY) ? "LTF" : "+HTF";
}

string BosChipText()
{
   if(g_BosMode == BOS_FRACTAL) return "Frac";
   if(g_BosMode == BOS_BOTH_AND) return "Both";
   return "Zig";
}

// Swing SL method chip (independent of entry BOS engine)
string SwMdChipText()
{
   if(g_SwingSLMode == BOS_FRACTAL) return "Frac";
   if(g_SwingSLMode == BOS_BOTH_AND) return "Both";
   return "Zig";
}

string ConfTip()
{
   return (g_ConfluenceMode == CONF_LTF_ONLY)
      ? "LTF entry only (click to also require HTF bias)"
      : "LTF entry AND HTF bias (click for LTF only)";
}

string BosTip()
{
   if(g_BosMode == BOS_FRACTAL) return "BOS engine: Fractal (click to cycle)";
   if(g_BosMode == BOS_BOTH_AND) return "BOS engine: BOTH must agree (click to cycle)";
   return "BOS engine: Zigzag (click to cycle)";
}

string SourceText(const ENUM_TF_SOURCE source)
{
   if(source == TF_SOURCE_HTF) return "HTF";
   if(source == TF_SOURCE_BOTH) return "both";
   return "own";
}
string BosSrcChipText() { return SourceText(g_BosSource); }
string BosSrcTip()
{
   return "BOS structure source: " + SourceText(g_BosSource) + " (own / HTF / both-AND)";
}

string BosSigChipText()
{
   return (g_BosSignalMode == BOS_SIGNAL_BIAS) ? "bias" : "evt";
}
string BosSigTip()
{
   return (g_BosSignalMode == BOS_SIGNAL_BIAS)
      ? "BOS mode: sticky bias. Click for event (break bar only)"
      : "BOS mode: event (break bar). Click for sticky bias";
}

string StXModeChipText()
{
   if(g_StochCrossMode == STOCH_CROSS_ANY) return "any";
   if(g_StochCrossMode == STOCH_CROSS_OSOB) return "obos";
   return "pb"; // PULLBACK until user clicks into any/obos cycle
}
string StXModeTip()
{
   if(g_StochCrossMode == STOCH_CROSS_ANY)
      return "Stoch cross: ANY. Click for OS/OB origin";
   if(g_StochCrossMode == STOCH_CROSS_OSOB)
      return "Stoch cross: from OS/OB. Click for ANY";
   return "Stoch cross: pullback level (input). Click to cycle any/obos";
}

string StCModeChipText()
{
   return (g_StochClassicMode == STOCH_CLASSIC_MOM) ? "mom" : "rev";
}
string StCModeTip()
{
   return (g_StochClassicMode == STOCH_CLASSIC_MOM)
      ? "Stoch classic mom: buy OB / sell OS. Click for rev"
      : "Stoch classic rev: buy OS / sell OB. Click for mom";
}

string T2StochModeChipText() { return g_HTF_StochObOs ? "obos" : "mid"; }
string T2StochModeTip()
{
   return g_HTF_StochObOs
      ? "HTF stoch: OS/OB zone. Click for mid (%K vs pullback)"
      : "HTF stoch: mid (%K vs pullback). Click for OS/OB";
}

string T2StochDirText() { return g_HTF_StochObOsMode == STOCH_CLASSIC_MOM ? "mom" : "rev"; }

string T2MaSrcChipText() { return g_HTF_MaFromLTF ? "LTF" : "own"; }
string T2MaSrcTip()
{
   return g_HTF_MaFromLTF
      ? "HTF MA uses LTF handles. Click for own HTF"
      : "HTF MA uses own HTF handles. Click for LTF";
}

string SwMdTip()
{
   if(g_SwingSLMode == BOS_FRACTAL)
      return "Swing SL method: Fractal (click to cycle; independent of entry BOS)";
   if(g_SwingSLMode == BOS_BOTH_AND)
      return "Swing SL method: BOTH tighter (click to cycle; independent of entry BOS)";
   return "Swing SL method: Zigzag (click to cycle; independent of entry BOS)";
}

// Panel MA chip: off = "ma" (gray); "m1" / "m2" = lit (green).
string MaChipText(const int state)
{
   if(state == MA_SINGLE) return "m1";
   if(state == MA_DOUBLE) return "m2";
   return "ma"; // off
}

bool MaChipLit(const int state)
{
   return MaEnabled(state); // m1 / m2 light up
}

string MaChipTip(const int state, const string tfTag)
{
   if(state == MA_SINGLE)
      return tfTag + " MA m1 (single line). Click: off → m1 → m2";
   if(state == MA_DOUBLE)
      return tfTag + " MA m2 (fast vs slow). Click: off → m1 → m2";
   return tfTag + " MA off. Click: off → m1 → m2";
}

string MaSLLineChipText()
{
   return (g_MaSLLine == MASL_FAST) ? "Fst" : "Slw";
}

string SrLvChipText()
{
   return SourceText(g_SrSource);
}

string SrLvTip()
{
   return "S/R level source: " + SourceText(g_SrSource) + " (own / HTF / both-AND; PA=LTF)";
}

string MaDirText(const ENUM_MA_TREND_MODE mode) { return mode == MA_TREND_FOLLOW ? "fol" : "rev"; }
string MaCheckText(const ENUM_MA_CHECK mode)
{
   if(mode == MA_CHECK_RUNNING)      return "run";
   if(mode == MA_CHECK_CANDLE_CLOSE) return "close";
   return "closed"; // MA_CHECK_CLOSED_ONLY
}
string BosBreakText() { return g_BosBreakMode == BOS_BREAK_CLOSE ? "close" : "wick"; }
string RejectText() { return g_RequireRejectCandle ? "reject" : "free"; }
string GridCountText() { return "G" + IntegerToString(g_MaxLayers); }

string MaSLLineTip()
{
   if(MaExitUsesSingleLine())
      return "MaSL line: single MA (Fast/Slow same line). Click to toggle";
   return (g_MaSLLine == MASL_FAST)
      ? "MaSL line: Fast (m2). Click for Slow"
      : "MaSL line: Slow (m2). Click for Fast";
}

void PanelCycleMA(int &state, const string gvId)
{
   // Panel: off → m1 → m2 → off
   if(state == MA_SINGLE)      state = MA_DOUBLE;
   else if(state == MA_DOUBLE) state = MA_OFF;
   else                        state = MA_SINGLE;
   PanelSaveInt(gvId, state);
}

void PanelCycleMaCheck(ENUM_MA_CHECK &mode, const string gvId)
{
   // Panel: run → close → closed → run
   if(mode == MA_CHECK_RUNNING)           mode = MA_CHECK_CANDLE_CLOSE;
   else if(mode == MA_CHECK_CANDLE_CLOSE) mode = MA_CHECK_CLOSED_ONLY;
   else                                   mode = MA_CHECK_RUNNING;
   PanelSaveInt(gvId, (int)mode);
}

void PanelCycleMaSLLine()
{
   g_MaSLLine = (g_MaSLLine == MASL_FAST) ? MASL_SLOW : MASL_FAST;
   PanelSaveInt("MaLn", (int)g_MaSLLine);
}

void PanelCycleBosMode()
{
   if(g_BosMode == BOS_ZIGZAG) g_BosMode = BOS_FRACTAL;
   else if(g_BosMode == BOS_FRACTAL) g_BosMode = BOS_BOTH_AND;
   else g_BosMode = BOS_ZIGZAG;
   PanelSaveInt("BosMode", (int)g_BosMode);
}

void PanelCycleStochCrossMode()
{
   // Panel cycles ANY ↔ OSOB only; PULLBACK (input) until first click → ANY
   if(g_StochCrossMode == STOCH_CROSS_ANY)
      g_StochCrossMode = STOCH_CROSS_OSOB;
   else
      g_StochCrossMode = STOCH_CROSS_ANY;
   PanelSaveInt("StXMode", (int)g_StochCrossMode);
}

void PanelCycleStochClassicMode()
{
   g_StochClassicMode = (g_StochClassicMode == STOCH_CLASSIC_MOM) ? STOCH_CLASSIC_REV : STOCH_CLASSIC_MOM;
   PanelSaveInt("StCMode", (int)g_StochClassicMode);
}

void PanelCycleBosSignalMode()
{
   g_BosSignalMode = (g_BosSignalMode == BOS_SIGNAL_EVENT) ? BOS_SIGNAL_BIAS : BOS_SIGNAL_EVENT;
   PanelSaveInt("BosSig", (int)g_BosSignalMode);
}

void PanelCycleSource(ENUM_TF_SOURCE &source, const string gvId)
{
   if(source == TF_SOURCE_OWN) source = TF_SOURCE_HTF;
   else if(source == TF_SOURCE_HTF) source = TF_SOURCE_BOTH;
   else source = TF_SOURCE_OWN;
   PanelSaveInt(gvId, (int)source);
}

void PanelCycleGridCount()
{
   g_MaxLayers = (g_MaxLayers >= 3) ? 1 : g_MaxLayers + 1;
   PanelSaveInt("GridN", g_MaxLayers);
}

void PanelPaintState()
{
   if(!ShowPanel) return;

   PanelStyleChip(PanelObj("TTL"), g_panelCollapsed ? " lets-go  ▸" : " lets-go  ▾",
                  "Click to collapse / expand panel", true, true);

   if(g_panelCollapsed) return;

   PanelStyleChip(PanelObj("CONF"), ConfChipText(), ConfTip(), true, true);
   PanelStyleChip(PanelObj("GRID"), "Grid", "Grid ON = MaxLayers; OFF = 1 layer", g_UseGrid, false);
   PanelStyleChip(PanelObj("GRIDN"), GridCountText(), "Grid maximum layers (1 / 2 / 3)", true, true);
   PanelStyleChip(PanelObj("BUY"),  "Buy",  "Allow BUY signals",  g_TradeBuy,  false);
   PanelStyleChip(PanelObj("SELL"), "Sell", "Allow SELL signals", g_TradeSell, false);

   PanelStyleChip(PanelObj("L1"), " LTF entry . AND", "LTF entry: every ON family must pass (AND)", true, true);

   PanelStyleFamily(PanelObj("FamOsc"), "osc", "LTF oscillator bias: each ON module ANDs with the rest", false);
   PanelStyleChip(PanelObj("T1_rsi"), "rsi", "LTF entry: RSI bias (mid)", g_LTF_UseRsiBias, false);
   PanelStyleChip(PanelObj("T1_macd"),"macd","LTF entry: MACD bias", g_LTF_UseMacdBias, false);
   PanelStyleChip(PanelObj("T1_fib"), "fib", "LTF entry: Fib golden zone", g_LTF_UseFibZone, false);

   PanelStyleFamily(PanelObj("FamSt"), "st or", "LTF Stoch family: stX OR stC (either arms it), then ANDs with others", true);
   PanelStyleChip(PanelObj("T1_stX"), "stX", "LTF entry: Stoch cross", g_LTF_UseStochCross, false);
   PanelStyleChip(PanelObj("T1_stXm"), StXModeChipText(), StXModeTip(), true, true);
   PanelStyleChip(PanelObj("T1_stC"), "stC", "LTF entry: Stoch classic OS/OB", g_LTF_UseStochClassic, false);
   PanelStyleChip(PanelObj("T1_stCm"), StCModeChipText(), StCModeTip(), true, true);

   PanelStyleFamily(PanelObj("FamMa"), "ma", "LTF MA family (ANDs when ON)", false);
   PanelStyleChip(PanelObj("T1_ma"), MaChipText(g_LTF_MA), MaChipTip(g_LTF_MA, "LTF entry"),
                  MaChipLit(g_LTF_MA), false);
   PanelStyleChip(PanelObj("T1_maDir"), MaDirText(g_LTF_MaTrendMode), "LTF MA follow / reversal", true, true);
   PanelStyleChip(PanelObj("T1_maChk"), MaCheckText(g_LTF_MACheckMode), "LTF MA running / candle close / closed only", true, true);

   PanelStyleChip(PanelObj("T1_bos"), "bos", "LTF entry: BOS on/off (ANDs when ON)", g_LTF_UseBos, false);
   PanelStyleChip(PanelObj("BosSrc"), BosSrcChipText(), BosSrcTip(), true, true);
   PanelStyleChip(PanelObj("BosEng"), BosChipText(), BosTip(), true, true);
   PanelStyleChip(PanelObj("BosSig"), BosSigChipText(), BosSigTip(), true, true);
   PanelStyleChip(PanelObj("BosBrk"), BosBreakText(), "Fractal BOS break by wick / close", true, true);

   PanelStyleFamily(PanelObj("SRLBL"), "S/R or", "S/R family: bounce OR break-retest (either arms it), then ANDs; PA=LTF", true);
   PanelStyleChip(PanelObj("SrLv"), SrLvChipText(), SrLvTip(), true, true);
   PanelStyleChip(PanelObj("T1_srR"), "srBrk", "LTF entry: S/R break-retest", g_LTF_UseSrBreakRetest, false);
   PanelStyleChip(PanelObj("T1_srB"), "srRev", "LTF entry: S/R bounce", g_LTF_UseSrBounce, false);
   PanelStyleChip(PanelObj("SrRej"), RejectText(), "Require rejection candle / free", true, true);

   PanelStyleChip(PanelObj("L2"), " HTF bias . AND", "HTF bias (+HTF): every ON module must pass (AND)", true, true);
   const bool htfActive = (g_ConfluenceMode == CONF_LTF_AND_HTF);
   if(htfActive)
   {
      PanelStyleFamily(PanelObj("FamOsc2"), "osc", "HTF oscillator bias: each ON module ANDs", false);
      PanelStyleFamily(PanelObj("FamSt2"), "st", "HTF Stoch family: toggle + mid/obos + mom/rev", false);
      PanelStyleFamily(PanelObj("FamMa2"), "ma", "HTF MA family (ANDs when ON)", false);

      PanelStyleChip(PanelObj("T2_rsi"), "rsi", "HTF bias: RSI mid", g_HTF_UseRsiBias, false);
      PanelStyleChip(PanelObj("T2_macd"),"macd","HTF bias: MACD", g_HTF_UseMacdBias, false);
      PanelStyleChip(PanelObj("T2_fib"), "fib", "HTF bias: Fib golden zone", g_HTF_UseFibZone, false);
      PanelStyleChip(PanelObj("T2_stoch"), "stoch", "HTF bias: Stoch on/off", g_HTF_UseStoch, false);
      PanelStyleChip(PanelObj("T2_stMd"), T2StochModeChipText(), T2StochModeTip(), true, true);
      PanelStyleChip(PanelObj("T2_stDir"), T2StochDirText(), "HTF OB/OS mom/rev (used when mode=obos)", true, true);
      PanelStyleChip(PanelObj("T2_maSrc"), T2MaSrcChipText(), T2MaSrcTip(), true, true);
      PanelStyleChip(PanelObj("T2_ma"), MaChipText(g_HTF_MA), MaChipTip(g_HTF_MA, "HTF bias"), MaChipLit(g_HTF_MA), false);
      if(g_HTF_MaFromLTF)
      {
         PanelStyleDisabled(PanelObj("T2_maDir"), MaDirText(g_LTF_MaTrendMode), "Shared from LTF MA");
         PanelStyleDisabled(PanelObj("T2_maChk"), MaCheckText(g_LTF_MACheckMode), "Shared from LTF MA");
      }
      else
      {
         PanelStyleChip(PanelObj("T2_maDir"), MaDirText(g_HTF_MaTrendMode), "HTF-own MA follow / reversal", true, true);
         PanelStyleChip(PanelObj("T2_maChk"), MaCheckText(g_HTF_MACheckMode), "HTF-own MA running / candle close / closed only", true, true);
      }
   }
   else
   {
      PanelStyleDisabled(PanelObj("FamOsc2"), "osc", "HTF bias locked while mode=LTF");
      PanelStyleDisabled(PanelObj("FamSt2"), "st", "HTF bias locked while mode=LTF");
      PanelStyleDisabled(PanelObj("FamMa2"), "ma", "HTF bias locked while mode=LTF");
      string hIds[] = {"T2_rsi","T2_macd","T2_fib","T2_stoch","T2_stMd","T2_stDir","T2_maSrc","T2_ma","T2_maDir","T2_maChk"};
      string hTxt[10];
      hTxt[0]="rsi"; hTxt[1]="macd"; hTxt[2]="fib"; hTxt[3]="stoch";
      hTxt[4]=T2StochModeChipText(); hTxt[5]=T2StochDirText();
      hTxt[6]=T2MaSrcChipText(); hTxt[7]=MaChipText(g_HTF_MA);
      hTxt[8]=MaDirText(g_HTF_MaFromLTF ? g_LTF_MaTrendMode : g_HTF_MaTrendMode);
      hTxt[9]=MaCheckText(g_HTF_MaFromLTF ? g_LTF_MACheckMode : g_HTF_MACheckMode);
      for(int i=0; i<ArraySize(hIds); i++) PanelStyleDisabled(PanelObj(hIds[i]), hTxt[i], "HTF bias locked while mode=LTF");
   }

   PanelStyleChip(PanelObj("LG"), " guards", "Entry/schedule guards", true, true);
   PanelStyleChip(PanelObj("Session"), "Session", "Session guard ON/OFF", g_UseSession, false);
   PanelStyleChip(PanelObj("Weekend"), "Weekend", "Weekend guard ON/OFF", g_UseWeekendFilter, false);
   PanelStyleChip(PanelObj("News"), "News", "News guard ON/OFF", g_UseNewsFilter, false);
   PanelStyleChip(PanelObj("Broker"), "Broker", "Broker session guard ON/OFF", g_UseBrokerSessionGuard, false);
   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool cooldown = OrderRetryCooldownSec > 0 && (TimeCurrent() - g_lastEntryFailTime) < OrderRetryCooldownSec;
   bool spreadBlocked = MaxSpreadPips > 0 && g_pip > 0 && (ask - bid) / g_pip > MaxSpreadPips;
   bool blocked = InWeekendBlock() || !InDailySession() || InNewsBlackout() ||
                  !IsBrokerTradeSessionOpen() || !IsExpertTradingEnabled() ||
                  tradeMode != SYMBOL_TRADE_MODE_FULL || !IsTickFresh() ||
                  cooldown || spreadBlocked;
   PanelStyleStatus(PanelObj("GuardSt"), blocked);

   PanelStyleChip(PanelObj("LR"), " risk exits", "Risk / exit toggles", true, true);
   PanelStyleChip(PanelObj("MaSL"), "MaSL", "Virtual MA stop ON/OFF", g_UseVirtualMaSL, false);
   PanelStyleChip(PanelObj("MaLn"), MaSLLineChipText(), MaSLLineTip(), true, true);
   PanelStyleChip(PanelObj("SwSL"), "SwSL", "Virtual swing stop ON/OFF", g_UseSwingVirtualSL, false);
   PanelStyleChip(PanelObj("SwMd"), SwMdChipText(), SwMdTip(), true, true);
   PanelStyleChip(PanelObj("Trail"),"Trail","Basket pip trail TP", g_UseBasketTP, false);

}

// Delete any panel button/label whose id is not in this build's live set —
// catches orphans left behind by an older panel layout (e.g. a recompiled
// version that renamed/dropped ids) without touching objects that are still
// current, so a TF-change reinit reuses existing objects (no blink).
void PanelPruneOrphans(const string &liveIds[])
{
   int total = ObjectsTotal(0, -1, OBJ_BUTTON);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, OBJ_BUTTON);
      if(StringFind(name, g_panelPrefix) != 0) continue;
      string id = StringSubstr(name, StringLen(g_panelPrefix));
      bool keep = false;
      for(int j = 0; j < ArraySize(liveIds); j++)
         if(liveIds[j] == id) { keep = true; break; }
      if(!keep) ObjectDelete(0, name);
   }
}

void PanelBuild()
{
   if(!ShowPanel) { PanelDeleteAll(); return; }
   if(StringLen(g_panelPrefix) == 0)
      PanelInitPrefix();

   const int chipW = 56;
   const int chipH = 19;
   const int gap   = 3;
   const int rowW  = chipW * 5 + gap * 4;
   const int x0    = MathMax(0, PanelInsetX);
   int y = MathMax(0, PanelInsetY);

   PanelEnsureLabel("TTL", x0, y, rowW, chipH);

   if(g_panelCollapsed)
   {
      string liveCollapsed[] = { "TTL" };
      PanelPruneOrphans(liveCollapsed);
      PanelPaintState();
      return;
   }

   y += chipH + gap;
   string modeIds[] = { "CONF", "GRID", "GRIDN", "BUY", "SELL" };
   PanelPlaceEvenRow(modeIds, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap + 2;

   PanelEnsureLabel("L1", x0, y, rowW, chipH); y += chipH + gap;
   string t1osc[] = { "FamOsc", "T1_rsi", "T1_macd", "T1_fib" };
   PanelPlaceEvenRow(t1osc, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1st[] = { "FamSt", "T1_stX", "T1_stXm", "T1_stC", "T1_stCm" };
   PanelPlaceEvenRow(t1st, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1ma[] = { "FamMa", "T1_ma", "T1_maDir", "T1_maChk" };
   PanelPlaceEvenRow(t1ma, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1bos[] = { "T1_bos", "BosSrc", "BosEng", "BosSig", "BosBrk" };
   PanelPlaceEvenRow(t1bos, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1sr[] = { "SRLBL", "SrLv", "T1_srR", "T1_srB", "SrRej" };
   PanelPlaceEvenRow(t1sr, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap + 2;

   PanelEnsureLabel("L2", x0, y, rowW, chipH); y += chipH + gap;
   string t2osc[] = { "FamOsc2", "T2_rsi", "T2_macd", "T2_fib" };
   PanelPlaceEvenRow(t2osc, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t2st[] = { "FamSt2", "T2_stoch", "T2_stMd", "T2_stDir" };
   PanelPlaceEvenRow(t2st, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t2ma[] = { "FamMa2", "T2_maSrc", "T2_ma", "T2_maDir", "T2_maChk" };
   PanelPlaceEvenRow(t2ma, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap + 2;

   PanelEnsureLabel("LG", x0, y, rowW, chipH); y += chipH + gap;
   string guards[] = { "Session", "Weekend", "News", "Broker", "GuardSt" };
   PanelPlaceEvenRow(guards, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap + 2;

   PanelEnsureLabel("LR", x0, y, rowW, chipH); y += chipH + gap;
   string risk[] = { "MaSL", "MaLn", "SwSL", "SwMd", "Trail" };
   PanelPlaceEvenRow(risk, 5, x0, y, rowW, gap, chipH);

   string liveIds[] = {
      "TTL","CONF","GRID","GRIDN","BUY","SELL","L1",
      "FamOsc","T1_rsi","T1_macd","T1_fib",
      "FamSt","T1_stX","T1_stXm","T1_stC","T1_stCm",
      "FamMa","T1_ma","T1_maDir","T1_maChk",
      "T1_bos","BosSrc","BosEng","BosSig","BosBrk",
      "SRLBL","SrLv","T1_srR","T1_srB","SrRej","L2",
      "FamOsc2","T2_rsi","T2_macd","T2_fib",
      "FamSt2","T2_stoch","T2_stMd","T2_stDir",
      "FamMa2","T2_maSrc","T2_ma","T2_maDir","T2_maChk","LG",
      "Session","Weekend","News","Broker","GuardSt","LR",
      "MaSL","MaLn","SwSL","SwMd","Trail"
   };
   PanelPruneOrphans(liveIds);

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

   if(PanelIsNonInteractiveId(id))
      return true;

   // HTF controls are deliberately locked while confluence is LTF-only.
   if(g_ConfluenceMode == CONF_LTF_ONLY && StringFind(id, "T2_") == 0)
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
      g_ConfluenceMode = (g_ConfluenceMode == CONF_LTF_ONLY) ? CONF_LTF_AND_HTF : CONF_LTF_ONLY;
      PanelSaveInt("Conf", (int)g_ConfluenceMode);
   }
   else if(id == "GRID") PanelToggleBool(g_UseGrid, "Grid");
   else if(id == "GRIDN") PanelCycleGridCount();
   else if(id == "BosEng") PanelCycleBosMode();
   else if(id == "BosSrc") PanelCycleSource(g_BosSource, "BosSrc");
   else if(id == "BosSig") PanelCycleBosSignalMode();
   else if(id == "BosBrk")
   {
      g_BosBreakMode = (g_BosBreakMode == BOS_BREAK_WICK) ? BOS_BREAK_CLOSE : BOS_BREAK_WICK;
      PanelSaveInt("BosBrk", (int)g_BosBreakMode);
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
   else if(id == "T1_stX") PanelToggleBool(g_LTF_UseStochCross, "T1_stX");
   else if(id == "T1_stXm") PanelCycleStochCrossMode();
   else if(id == "T1_stC") PanelToggleBool(g_LTF_UseStochClassic, "T1_stC");
   else if(id == "T1_stCm") PanelCycleStochClassicMode();
   else if(id == "T1_srB") PanelToggleBool(g_LTF_UseSrBounce, "T1_srB");
   else if(id == "T1_srR") PanelToggleBool(g_LTF_UseSrBreakRetest, "T1_srR");
   else if(id == "T1_fib") PanelToggleBool(g_LTF_UseFibZone, "T1_fib");
   else if(id == "T1_macd") PanelToggleBool(g_LTF_UseMacdBias, "T1_macd");
   else if(id == "T1_rsi") PanelToggleBool(g_LTF_UseRsiBias, "T1_rsi");
   else if(id == "T1_ma") PanelCycleMA(g_LTF_MA, "T1_ma");
   else if(id == "T1_maDir")
   {
      g_LTF_MaTrendMode = (g_LTF_MaTrendMode == MA_TREND_FOLLOW) ? MA_TREND_REVERSAL : MA_TREND_FOLLOW;
      PanelSaveInt("T1_MaDir", (int)g_LTF_MaTrendMode);
   }
   else if(id == "T1_maChk") PanelCycleMaCheck(g_LTF_MACheckMode, "T1_MaChk");
   else if(id == "T1_bos") PanelToggleBool(g_LTF_UseBos, "T1_bos");
   else if(id == "SrLv") PanelCycleSource(g_SrSource, "SrLv");
   else if(id == "SrRej") PanelToggleBool(g_RequireRejectCandle, "SrRej");
   else if(id == "T2_stoch") PanelToggleBool(g_HTF_UseStoch, "T2_stoch");
   else if(id == "T2_stMd") PanelToggleBool(g_HTF_StochObOs, "T2_stOb");
   else if(id == "T2_stDir")
   {
      g_HTF_StochObOsMode = (g_HTF_StochObOsMode == STOCH_CLASSIC_MOM) ? STOCH_CLASSIC_REV : STOCH_CLASSIC_MOM;
      PanelSaveInt("T2_stDir", (int)g_HTF_StochObOsMode);
   }
   else if(id == "T2_fib") PanelToggleBool(g_HTF_UseFibZone, "T2_fib");
   else if(id == "T2_macd") PanelToggleBool(g_HTF_UseMacdBias, "T2_macd");
   else if(id == "T2_rsi") PanelToggleBool(g_HTF_UseRsiBias, "T2_rsi");
   else if(id == "T2_ma") PanelCycleMA(g_HTF_MA, "T2_ma");
   else if(id == "T2_maSrc") PanelToggleBool(g_HTF_MaFromLTF, "T2_maLTF");
   else if(id == "T2_maDir")
   {
      if(g_HTF_MaFromLTF) return true;
      g_HTF_MaTrendMode = (g_HTF_MaTrendMode == MA_TREND_FOLLOW) ? MA_TREND_REVERSAL : MA_TREND_FOLLOW;
      PanelSaveInt("T2_MaDir", (int)g_HTF_MaTrendMode);
   }
   else if(id == "T2_maChk")
   {
      if(g_HTF_MaFromLTF) return true;
      PanelCycleMaCheck(g_HTF_MACheckMode, "T2_MaChk");
   }
   else if(id == "Session") PanelToggleBool(g_UseSession, "Session");
   else if(id == "Weekend") PanelToggleBool(g_UseWeekendFilter, "Weekend");
   else if(id == "News")
   {
      PanelToggleBool(g_UseNewsFilter, "News");
      g_newsLastCheckMs = 0;
      g_newsBlackoutCached = false;
   }
   else if(id == "Broker") PanelToggleBool(g_UseBrokerSessionGuard, "Broker");
   else if(id == "MaSL") PanelToggleBool(g_UseVirtualMaSL, "MaSL");
   else if(id == "MaLn") PanelCycleMaSLLine();
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
// Strategy Tester: poll OBJ_BUTTON pressed state each tick/timer, then toggle + repaint.
void PanelPollClicks()
{
   if(!ShowPanel) return;
   if(!MQLInfoInteger(MQL_TESTER)) return;
   if(StringLen(g_panelPrefix) == 0) PanelInitPrefix();

   string hit = "";
   int total = ObjectsTotal(0, -1, OBJ_BUTTON);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, OBJ_BUTTON);
      if(StringFind(name, g_panelPrefix) != 0) continue;
      if(!ObjectGetInteger(0, name, OBJPROP_STATE)) continue;
      ObjectSetInteger(0, name, OBJPROP_STATE, false);
      string id = StringSubstr(name, StringLen(g_panelPrefix));
      if(PanelIsNonInteractiveId(id)) continue;
      if(StringLen(hit) == 0) hit = name;
   }
   if(StringLen(hit) > 0)
      PanelHandleClick(hit);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_quietInit = (UninitializeReason() == REASON_CHARTCHANGE);
   RuntimeLoadFromInputsThenGV();

   g_ltf = (InpLTF == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpLTF;
   g_htf = (InpHTF == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpHTF;

   if(MaxLayers < 1)
   {
      LogInfo("INIT FAILED - MaxLayers must be >= 1");
      NotifyPush("INIT FAILED - MaxLayers must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxStopLossPips < 1)
   {
      LogInfo("INIT FAILED - MaxStopLossPips must be >= 1");
      NotifyPush("INIT FAILED - MaxStopLossPips must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(PivotLeftBars < 1 || PivotRightBars < 1)
   {
      LogInfo("INIT FAILED - PivotLeftBars/PivotRightBars must be >= 1");
      NotifyPush("INIT FAILED - PivotLeftBars/PivotRightBars must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(FibZoneLevelMin >= FibZoneLevelMax)
   {
      LogInfo("INIT FAILED - FibZoneLevelMin must be < FibZoneLevelMax");
      NotifyPush("INIT FAILED - FibZoneLevelMin must be < FibZoneLevelMax");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(!g_TradeBuy && !g_TradeSell && !g_quietInit)
      LogInfo("NOTE Buy and Sell both off — enable from panel/inputs to trade.");

   // With the chip panel, pre-create ALL handles so live toggles work without reattach.
   const bool prepAll = ShowPanel;
   const bool needLtfMa = prepAll || MaEnabled(g_LTF_MA) || g_UseVirtualMaSL
                       || (MaEnabled(g_HTF_MA) && g_HTF_MaFromLTF);
   if(!CreateTfHandles(g_ltf,
                       prepAll || g_LTF_UseStochCross, prepAll || g_LTF_UseStochClassic,
                       prepAll || g_LTF_UseMacdBias, prepAll || g_LTF_UseRsiBias,
                       needLtfMa,
                       prepAll || g_LTF_UseFibZone || (g_UseSwingVirtualSL && g_SwingSLMode != BOS_FRACTAL),
                       prepAll || (g_LTF_UseBos && g_BosSource != TF_SOURCE_HTF) || g_UseSwingVirtualSL,
                       StochKPeriod, StochDPeriod, StochSlowing, StochMAMethod, StochPriceField,
                       MaPeriod, MaFastPeriod, MaSlowPeriod,
                       MaShift, MaMethod, MaAppliedPrice,
                       g_stochL, g_rsiL, g_macdL, g_maL, g_maFL, g_maSL, g_atrL, "LTF"))
      return(INIT_FAILED);

   // HTF handles: HTF bias, and/or BOS-from-HTF ATR (fib OR zigzag/both).
   const bool needHtf = prepAll || g_ConfluenceMode == CONF_LTF_AND_HTF || g_BosSource != TF_SOURCE_OWN;
   if(needHtf)
   {
      if(!CreateTfHandles(g_htf,
                          prepAll || g_HTF_UseStoch, false,
                          prepAll || g_HTF_UseMacdBias, prepAll || g_HTF_UseRsiBias,
                          prepAll || MaEnabled(g_HTF_MA),
                          prepAll || g_HTF_UseFibZone,
                          prepAll || (g_LTF_UseBos && g_BosSource != TF_SOURCE_OWN),
                          HTF_StochKPeriod, HTF_StochDPeriod, HTF_StochSlowing,
                          HTF_StochMAMethod, HTF_StochPriceField,
                          HTF_MaPeriod, HTF_MaFastPeriod, HTF_MaSlowPeriod,
                          HTF_MaShift, HTF_MaMethod, HTF_MaAppliedPrice,
                          g_stochH, g_rsiH, g_macdH, g_maH, g_maFH, g_maSH, g_atrH, "HTF"))
         return(INIT_FAILED);
      if(PeriodSeconds(g_htf) == PeriodSeconds(g_ltf) && !g_quietInit)
         LogInfo("NOTE LTF and HTF are the same period — HTF bias / SrLv HTF add no extra TF.");
   }

   if(!g_quietInit && g_SrSource != TF_SOURCE_OWN && PeriodSeconds(g_htf) <= PeriodSeconds(g_ltf))
      LogInfo("NOTE SrLv=HTF but HTF is not higher than LTF — levels TF is not HTF.");
   if(!g_quietInit && g_BosSource != TF_SOURCE_OWN && PeriodSeconds(g_htf) <= PeriodSeconds(g_ltf))
      LogInfo("NOTE BosSrc=HTF but HTF is not higher than LTF — BOS TF is not HTF.");

   g_pip = PipSize();
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(!g_quietInit)
   {
      string mode = (g_ConfluenceMode == CONF_LTF_ONLY) ? "ENTRY_ONLY" : "ENTRY+BIAS";
      LogInfo("INIT " + mode
              + " LTF=" + EnumToString(g_ltf)
              + " HTF=" + EnumToString(g_htf)
              + " BosMode=" + EnumToString(g_BosMode)
              + " BosSig=" + EnumToString(g_BosSignalMode)
              + " BosSrc=" + (g_BosSource == TF_SOURCE_OWN ? "own" : (g_BosSource == TF_SOURCE_HTF ? "HTF" : "both"))
              + " SwMode=" + EnumToString(g_SwingSLMode)
              + " | Buy=" + (g_TradeBuy ? "ON" : "OFF")
              + " Sell=" + (g_TradeSell ? "ON" : "OFF")
              + " Grid=" + (g_UseGrid ? ("ON/" + IntegerToString(EffectiveMaxLayers())) : "OFF/1")
              + " | MaSL=" + (g_UseVirtualMaSL ? "ON" : "OFF")
              + (g_UseVirtualMaSL ? ("/" + ((g_MaSLLine == MASL_FAST) ? "Fast" : "Slow")) : "")
              + " SwSL=" + (g_UseSwingVirtualSL ? "ON" : "OFF")
              + " Trail=" + (g_UseBasketTP ? "ON" : "OFF")
              + " | HTFMA=" + IntegerToString(HTF_MaPeriod)
              + "/" + IntegerToString(HTF_MaFastPeriod)
              + "/" + IntegerToString(HTF_MaSlowPeriod)
              + (g_HTF_MaFromLTF ? " src=LTF(shared)" : " src=own")
              + " | panel=" + (ShowPanel ? ("ON inset " + IntegerToString(PanelInsetX) + "," + IntegerToString(PanelInsetY)) : "off"));
      if(_Period != g_ltf)
         LogInfo("NOTE chart TF differs from LTF (" + EnumToString(g_ltf)
                 + "). Signal clock runs on LTF.");
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

   ReleaseHandle(g_stochL); ReleaseHandle(g_rsiL); ReleaseHandle(g_macdL);
   ReleaseHandle(g_maL);    ReleaseHandle(g_maFL); ReleaseHandle(g_maSL); ReleaseHandle(g_atrL);
   ReleaseHandle(g_stochH); ReleaseHandle(g_rsiH); ReleaseHandle(g_macdH);
   ReleaseHandle(g_maH);    ReleaseHandle(g_maFH); ReleaseHandle(g_maSH); ReleaseHandle(g_atrH);
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
   else if(!g_panelCollapsed)
   {
      PanelPaintState(); // refresh OPEN/BLOCK without requiring a click
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
   if(CopyTime(_Symbol, g_ltf, 0, 1, bt) == 1 && bt[0] != g_lastBarTime)
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
   if(!g_UseWeekendFilter) return false;

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
   if(!g_UseNewsFilter) return false;

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
   if(!g_UseSession) return true;

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
   if(g_UseWeekendFilter && CloseAtWeekend && InWeekendBlock()) return true;
   if(g_UseSession && CloseAtSessionEnd && !InDailySession()) return true;
   if(g_UseNewsFilter && CloseAtNews && InNewsBlackout()) return true;
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
   if(got < PivotLeftBars + PivotRightBars + 3)
   { LogDebugGuard("dbg_sr", "GetActiveSR " + EnumToString(tf) + ": not enough bars yet"); return false; }

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

   if(curHigh == EMPTY_VALUE || curLow == EMPTY_VALUE)
   { LogDebugGuard("dbg_sr", "GetActiveSR " + EnumToString(tf) + ": no pivot high/low found yet"); return false; }
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
   if(hStoch == INVALID_HANDLE)
   { LogDebugGuard("dbg_stoch", "EvalStoch: invalid handle"); return false; }

   double k[], d[];
   ArraySetAsSeries(k, true);
   ArraySetAsSeries(d, true);
   if(CopyBuffer(hStoch, 0, 0, 3, k) != 3)
   { LogDebugGuard("dbg_stoch", "EvalStoch: %K buffer not ready"); return false; }
   if(CopyBuffer(hStoch, 1, 0, 3, d) != 3)
   { LogDebugGuard("dbg_stoch", "EvalStoch: %D buffer not ready"); return false; }

   double k1 = k[1], k2 = k[2];
   double d1 = d[1], d2 = d[2];

   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);
   // Runtime mode (panel); PULLBACK still honored until user cycles any/obos
   bool crossLevelBuyOK  = (g_StochCrossMode == STOCH_CROSS_ANY)  ? true
                         : (g_StochCrossMode == STOCH_CROSS_OSOB) ? (k2 < StochOversoldLevel)
                         :                                          (k1 < StochPullbackLevel);
   bool crossLevelSellOK = (g_StochCrossMode == STOCH_CROSS_ANY)  ? true
                         : (g_StochCrossMode == STOCH_CROSS_OSOB) ? (k2 > StochOverboughtLevel)
                         :                                          (k1 > StochPullbackLevel);

   bool crossBuy    = useCross && crossedUp   && crossLevelBuyOK;
   bool crossSell   = useCross && crossedDown && crossLevelSellOK;

   // Classic is always OS/OB zone; mom=follow extreme, rev=fade
   bool inOS = (k1 < StochOversoldLevel);
   bool inOB = (k1 > StochOverboughtLevel);
   bool classicBuy  = false, classicSell = false;
   if(useClassic)
   {
      if(g_StochClassicMode == STOCH_CLASSIC_MOM)
      {
         classicBuy  = inOB; // mom: buy in OB
         classicSell = inOS; // mom: sell in OS
      }
      else
      {
         classicBuy  = inOS; // rev: buy in OS
         classicSell = inOB; // rev: sell in OB
      }
   }

   buyOK  = crossBuy  || classicBuy;
   sellOK = crossSell || classicSell;
   return true;
}

// HTF stoch zone: mid (%K vs StochPullbackLevel) or OS/OB (buy OS / sell OB).
bool EvalStochZone(const int hStoch, const bool useIt, const bool obOs,
                   const ENUM_STOCH_CLASSIC_MODE obOsMode,
                   const double midLevel, const double oversoldLevel,
                   const double overboughtLevel,
                   bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!useIt) return true;
   if(hStoch == INVALID_HANDLE)
   { LogDebugGuard("dbg_stochzone", "EvalStochZone: invalid handle"); return false; }

   double k[];
   ArraySetAsSeries(k, true);
   if(CopyBuffer(hStoch, 0, 0, 2, k) != 2)
   { LogDebugGuard("dbg_stochzone", "EvalStochZone: %K buffer not ready"); return false; }

   if(obOs)
   {
      if(obOsMode == STOCH_CLASSIC_MOM)
      {
         buyOK  = (k[1] > overboughtLevel);
         sellOK = (k[1] < oversoldLevel);
      }
      else
      {
         buyOK  = (k[1] < oversoldLevel);
         sellOK = (k[1] > overboughtLevel);
      }
   }
   else
   {
      buyOK  = (k[1] > midLevel);
      sellOK = (k[1] < midLevel);
   }
   return true;
}

bool EvalMacd(const int hMacd, const bool useIt, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!useIt) return true;
   if(hMacd == INVALID_HANDLE)
   { LogDebugGuard("dbg_macd", "EvalMacd: invalid handle"); return false; }

   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(hMacd, 0, 0, 2, m) != 2)
   { LogDebugGuard("dbg_macd", "EvalMacd: buffer not ready"); return false; }
   buyOK  = (m[1] > 0);
   sellOK = (m[1] < 0);
   return true;
}

bool EvalRsi(const int hRsi, const bool useIt, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!useIt) return true;
   if(hRsi == INVALID_HANDLE)
   { LogDebugGuard("dbg_rsi", "EvalRsi: invalid handle"); return false; }

   double r[];
   ArraySetAsSeries(r, true);
   if(CopyBuffer(hRsi, 0, 0, 2, r) != 2)
   { LogDebugGuard("dbg_rsi", "EvalRsi: buffer not ready"); return false; }
   buyOK  = (r[1] > RSIMidLevel);
   sellOK = (r[1] < RSIMidLevel);
   return true;
}

// Live single-MA side check (m1). Used by EvalMA and TryEnter re-gate.
bool PassesMALive(const ENUM_TIMEFRAMES tf, const int hSingle, const bool wantBuy,
                  const ENUM_MA_CHECK checkMode, const double bufferPips)
{
   if(hSingle == INVALID_HANDLE)
   { LogDebugGuard("dbg_malive", "PassesMALive: invalid handle"); return false; }

   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(hSingle, 0, 0, 2, m) != 2)
   { LogDebugGuard("dbg_malive", "PassesMALive: buffer not ready"); return false; } // [0]=now, [1]=last closed bar MA

   double buffer = MathMax(0.0, bufferPips) * g_pip;

   // CLOSED_ONLY: last closed bar vs its MA only — no live gate (bias style).
   if(checkMode != MA_CHECK_CLOSED_ONLY)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      bool liveOK = wantBuy ? (ask > m[0] + buffer) : (bid < m[0] - buffer);
      if(!liveOK) return false;

      if(checkMode == MA_CHECK_RUNNING) return true;
   }

   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(_Symbol, tf, 1, 1, c) != 1)
   { LogDebugGuard("dbg_malive", "PassesMALive: last closed candle not ready"); return false; }
   if(wantBuy) return (c[0] > m[1] + buffer);
   return (c[0] < m[1] - buffer);
}

// One MA module: m1 (single line) / m2 (fast vs slow).
// Per-TF MA check mode (Running / CandleClose / ClosedOnly) applies to m1 and m2.
bool EvalMA(const ENUM_TIMEFRAMES tf,
            const int hSingle, const int hFast, const int hSlow,
            const int state, const ENUM_MA_TREND_MODE trendMode,
            const ENUM_MA_CHECK checkMode, const double bufferPips,
            const double minDiffPips, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!MaEnabled(state)) return true;

   // m1: single-line filter (Running / CandleClose / ClosedOnly via PassesMALive)
   if(state == MA_SINGLE)
   {
      if(hSingle == INVALID_HANDLE)
      { LogDebugGuard("dbg_ma", "EvalMA m1: invalid handle"); return false; }
      bool followBuy  = PassesMALive(tf, hSingle, true, checkMode, bufferPips);
      bool followSell = PassesMALive(tf, hSingle, false, checkMode, bufferPips);
      if(trendMode == MA_TREND_FOLLOW)
      {
         buyOK  = followBuy;
         sellOK = followSell;
      }
      else // MA_TREND_REVERSAL
      {
         buyOK  = followSell;
         sellOK = followBuy;
      }
      return true;
   }

   // m2: fast vs slow — always require live (bar 0); CandleClose also needs bar 1
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE)
   { LogDebugGuard("dbg_ma", "EvalMA m2: invalid fast/slow handle"); return false; }
   double f[], s[];
   ArraySetAsSeries(f, true);
   ArraySetAsSeries(s, true);
   if(CopyBuffer(hFast, 0, 0, 2, f) != 2)
   { LogDebugGuard("dbg_ma", "EvalMA m2: fast buffer not ready"); return false; } // [0]=now, [1]=last closed
   if(CopyBuffer(hSlow, 0, 0, 2, s) != 2)
   { LogDebugGuard("dbg_ma", "EvalMA m2: slow buffer not ready"); return false; }

   double thr = MathMax(0.0, minDiffPips) * g_pip;
   int dirLive = 0, dirClosed = 0;
   double diffLive = f[0] - s[0];
   double diffClosed = f[1] - s[1];
   if(diffLive >  thr) dirLive = 1;
   if(diffLive < -thr) dirLive = -1;
   if(diffClosed >  thr) dirClosed = 1;
   if(diffClosed < -thr) dirClosed = -1;

   int dir = dirLive;
   if(checkMode == MA_CHECK_CANDLE_CLOSE)
   {
      if(dirLive == 0 || dirClosed == 0 || dirLive != dirClosed)
         dir = 0;
   }
   else if(checkMode == MA_CHECK_CLOSED_ONLY)
      dir = dirClosed; // last closed bar only — no live gate (bias style)
   if(dir == 0) { buyOK = false; sellOK = false; return true; }

   if(trendMode == MA_TREND_FOLLOW)
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

// paTf = bounce/break candles. levelsTf = pivot S/R source (own LTF or HTF).
bool EvalSr(const ENUM_TIMEFRAMES paTf, const bool useBounce, const bool useRetest,
            bool &buyOK, bool &sellOK, const ENUM_TIMEFRAMES levelsTf)
{
   buyOK = false; sellOK = false;
   if(!useBounce && !useRetest) { buyOK = true; sellOK = true; return true; }

   double support = 0, resistance = 0;
   if(!GetActiveSR(levelsTf, support, resistance)) return false;
   if(support <= 0 || resistance <= 0 || support >= resistance) return false;

   double touch = MathMax(0.0, TouchPips) * g_pip;

   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);

   int need = MathMax(BreakLookbackBars + 4, 6);
   if(CopyOpen (_Symbol, paTf, 0, need, o) != need) return false;
   if(CopyHigh (_Symbol, paTf, 0, need, h) != need) return false;
   if(CopyLow  (_Symbol, paTf, 0, need, l) != need) return false;
   if(CopyClose(_Symbol, paTf, 0, need, c) != need) return false;

   double o1 = o[1], h1 = h[1], l1 = l[1], c1 = c[1];
   bool bullReject = (c1 > o1);
   bool bearReject = (c1 < o1);

   bool bounceBuy  = (l1 <= support + touch) && (c1 > support) &&
                     (!g_RequireRejectCandle || bullReject);
   bool bounceSell = (h1 >= resistance - touch) && (c1 < resistance) &&
                     (!g_RequireRejectCandle || bearReject);

   bool retestBuy  = HadRecentBreakUp(c, need, resistance, BreakLookbackBars) &&
                     (l1 <= resistance + touch) && (c1 > resistance) &&
                     (!g_RequireRejectCandle || bullReject);
   bool retestSell = HadRecentBreakDown(c, need, support, BreakLookbackBars) &&
                     (h1 >= support - touch) && (c1 < support) &&
                     (!g_RequireRejectCandle || bearReject);

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
// Zigzag: ATR-deviation pivots. Structural BOS = leg endpoint broke
// previous same-side swing.
// Fractal: fractal swings + close/wick break → trend bias.
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
// Closed-bar only (same discipline as fractal / S/R): forming bar excluded.
// bosEventOnLastClosed = current BOS leg's newer pivot confirmed on last closed bar.
bool ScanFibLeg(const ENUM_TIMEFRAMES tf, const int hAtr,
                bool &haveLeg, bool &bullishLeg,
                double &olderPrice, double &newerPrice,
                bool &bosConfirmed, bool &bosEventOnLastClosed)
{
   haveLeg = false; bullishLeg = false;
   olderPrice = 0; newerPrice = 0; bosConfirmed = false;
   bosEventOnLastClosed = false;
   if(hAtr == INVALID_HANDLE)
   { LogDebugGuard("dbg_fibleg", "ScanFibLeg " + EnumToString(tf) + ": invalid ATR handle"); return false; }

   int prd  = MathMax(1, FibDepth / 2);
   int bars = (int)MathMin((long)FibLookbackBars, (long)Bars(_Symbol, tf));
   if(bars < 2 * prd + 3)
   { LogDebugGuard("dbg_fibleg", "ScanFibLeg " + EnumToString(tf) + ": not enough bars yet"); return false; }

   double high[], low[], close[], atr[];
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(atr,   false);

   if(CopyHigh (_Symbol, tf, 0, bars, high)  < bars)
   { LogDebugGuard("dbg_fibleg", "ScanFibLeg " + EnumToString(tf) + ": high[] short read"); return false; }
   if(CopyLow  (_Symbol, tf, 0, bars, low)   < bars)
   { LogDebugGuard("dbg_fibleg", "ScanFibLeg " + EnumToString(tf) + ": low[] short read"); return false; }
   if(CopyClose(_Symbol, tf, 0, bars, close) < bars)
   { LogDebugGuard("dbg_fibleg", "ScanFibLeg " + EnumToString(tf) + ": close[] short read"); return false; }
   if(CopyBuffer(hAtr, 0, 0, bars, atr)      < bars)
   { LogDebugGuard("dbg_fibleg", "ScanFibLeg " + EnumToString(tf) + ": ATR buffer short read"); return false; }

   bool haveLastZZ = false, havePrevZZ = false, havePrevSwing = false;
   double lastZZPrice = 0, prevSwing = 0;
   int lastZZType = -1;
   olderPrice = 0; newerPrice = 0;

   // Non-series: [0]=oldest, [bars-1]=forming. Confirm pivots only with closed bars.
   const int lastClosed = bars - 2;
   int newerConfirmBar = -1;
   double trackedNewer = 0;
   bool   haveTrackedNewer = false;

   for(int i = 2 * prd; i <= lastClosed; i++)
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

      if(havePrevZZ && (!haveTrackedNewer || newerPrice != trackedNewer))
      {
         trackedNewer = newerPrice;
         haveTrackedNewer = true;
         newerConfirmBar = i;
      }
   }

   if(!havePrevZZ) return true;
   haveLeg    = true;
   bullishLeg = (newerPrice > olderPrice);

   if(havePrevSwing)
   {
      if(bullishLeg) bosConfirmed = (newerPrice > prevSwing);
      else           bosConfirmed = (newerPrice < prevSwing);
   }
   if(bosConfirmed && newerConfirmBar == lastClosed)
      bosEventOnLastClosed = true;
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

   bool haveLeg = false, bullish = false, bos = false, bosEvt = false;
   double olderP = 0, newerP = 0;
   if(!ScanFibLeg(tf, hAtr, haveLeg, bullish, olderP, newerP, bos, bosEvt)) return false;
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

// Live price-in-zone check for per-tick FibZone gate.
bool LiveInFibZone(const ENUM_TIMEFRAMES tf, const int hAtr, const bool wantBuy)
{
   bool buyOK = false, sellOK = false;
   if(!EvalFibZone(tf, hAtr, true, false, buyOK, sellOK)) return false;
   return wantBuy ? buyOK : sellOK;
}

// Replay fractal structure on closed bars.
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
   if(bars < period * 2 + 3)
   { LogDebugGuard("dbg_fractal", "ScanFractalStructure " + EnumToString(tf) + ": not enough bars yet"); return false; }

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, tf, 0, bars, rates);
   if(copied <= period * 2 + 2)
   { LogDebugGuard("dbg_fractal", "ScanFractalStructure " + EnumToString(tf) + ": short rates read"); return false; }

   bool highValid = false, highBroken = false;
   bool lowValid  = false, lowBroken  = false;
   double highPrice = 0, lowPrice = 0;
   int trend = 0; // +1 bull, -1 bear, 0 neutral
   int lastBreakBar = -1;
   int lastBreakDir = 0; // +1 buy BOS, -1 sell BOS

   int lastClosed = copied - 2;
   for(int i = period; i <= lastClosed; i++)
   {
      double breakHighPrice = (g_BosBreakMode == BOS_BREAK_CLOSE) ? rates[i].close : rates[i].high;
      double breakLowPrice  = (g_BosBreakMode == BOS_BREAK_CLOSE) ? rates[i].close : rates[i].low;

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

   if(g_BosSignalMode == BOS_SIGNAL_EVENT)
   {
      // Break must be on the latest closed structure bar, and that bar must not
      // already have been consumed by a prior UpdateSignal (HTF scan + LTF clock).
      if(lastBreakBar == lastClosed && lastBreakDir != 0)
      {
         datetime breakBarTime = rates[lastClosed].time;
         datetime seen = (tf == g_htf) ? g_bosEventSeenHtfBar : g_bosEventSeenLtfBar;
         if(breakBarTime != 0 && breakBarTime != seen)
         {
            if(lastBreakDir > 0) buyOK = true;
            if(lastBreakDir < 0) sellOK = true;
         }
      }
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
   bool haveLeg = false, bullish = false, bos = false, bosEvt = false;
   double olderP = 0, newerP = 0;
   if(!ScanFibLeg(tf, hAtr, haveLeg, bullish, olderP, newerP, bos, bosEvt)) return false;
   if(!haveLeg || !bos) return true;

   if(g_BosSignalMode == BOS_SIGNAL_EVENT)
   {
      // Same once-per-structure-bar gate as fractal EVENT.
      if(!bosEvt) return true;
      datetime breakBarTime = iTime(_Symbol, tf, 1);
      datetime seen = (tf == g_htf) ? g_bosEventSeenHtfBar : g_bosEventSeenLtfBar;
      if(breakBarTime == 0 || breakBarTime == seen) return true;
      buyOK  = bullish;
      sellOK = !bullish;
      return true;
   }

   // BIAS — sticky while zigzag BOS leg holds.
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

bool EvalSrBySource(const bool useBounce, const bool useRetest,
                    bool &buyOK, bool &sellOK)
{
   bool lb = false, ls = false, hb = false, hs = false;
   if(g_SrSource == TF_SOURCE_OWN)
      return EvalSr(g_ltf, useBounce, useRetest, buyOK, sellOK, g_ltf);
   if(g_SrSource == TF_SOURCE_HTF)
      return EvalSr(g_ltf, useBounce, useRetest, buyOK, sellOK, g_htf);
   if(!EvalSr(g_ltf, useBounce, useRetest, lb, ls, g_ltf)) return false;
   if(!EvalSr(g_ltf, useBounce, useRetest, hb, hs, g_htf)) return false;
   buyOK = lb && hb;
   sellOK = ls && hs;
   return true;
}

bool EvalBosBySource(bool &buyOK, bool &sellOK)
{
   bool lb = false, ls = false, hb = false, hs = false;
   if(g_BosSource == TF_SOURCE_OWN)
      return EvalBos(g_ltf, g_atrL, true, buyOK, sellOK);
   if(g_BosSource == TF_SOURCE_HTF)
      return EvalBos(g_htf, g_atrH, true, buyOK, sellOK);
   if(!EvalBos(g_ltf, g_atrL, true, lb, ls)) return false;
   if(!EvalBos(g_htf, g_atrH, true, hb, hs)) return false;
   buyOK = lb && hb;
   sellOK = ls && hs;
   return true;
}

// Evaluate one TF: every enabled module family must pass (all AND).
// LTF Stoch: cross OR classic. HTF Stoch: zone (mid/obos) via useStochZone.
// Within S/R: bounce OR retest. S/R and BOS sources may be own/HTF/both-AND.
// If nothing enabled: outBuy/outSell stay false (caller may treat empty HTF as pass).
// fibLegOnly: FibZone arms from leg direction only (price checked later per tick).
// maTf + MA handles: HTF bias may evaluate MA on LTF when g_HTF_MaFromLTF.
bool EvalTf(const ENUM_TIMEFRAMES tf,
            const bool useCross, const bool useClassic,
            const bool useStochZone, const bool stochObOs,
            const ENUM_STOCH_CLASSIC_MODE stochZoneMode,
            const double stochMid, const double stochOS, const double stochOB,
            const bool useBounce, const bool useRetest, const bool useFib,
            const bool useMacd, const bool useRsi, const int maState, const bool useBos,
            const int hStoch, const int hRsi, const int hMacd,
            const ENUM_TIMEFRAMES maTf,
            const int hMaSingle, const int hMaFast, const int hMaSlow,
            const ENUM_MA_TREND_MODE maTrendMode, const ENUM_MA_CHECK maCheckMode,
            const double maBufferPips, const double maMinDiffPips,
            const int hAtr,
            const bool fibLegOnly,
            bool &outBuy, bool &outSell)
{
   outBuy = false; outSell = false;

   const bool useStoch = useStochZone ? true : (useCross || useClassic);
   const bool useSr    = (useBounce || useRetest);
   const bool useMA    = MaEnabled(maState);
   if(!useStoch && !useSr && !useFib && !useMacd && !useRsi && !useMA && !useBos)
      return true;

   bool buy = true, sell = true;

   if(useStoch)
   {
      bool stB = false, stS = false;
      if(useStochZone)
      {
         if(!EvalStochZone(hStoch, true, stochObOs, stochZoneMode,
                           stochMid, stochOS, stochOB, stB, stS)) return false;
      }
      else
      {
         if(!EvalStoch(hStoch, useCross, useClassic, stB, stS)) return false;
      }
      buy &= stB; sell &= stS;
   }
   if(useSr)
   {
      bool srB = false, srS = false;
      if(!EvalSrBySource(useBounce, useRetest, srB, srS)) return false;
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
   if(useMA)
   {
      bool maBuy = false, maSell = false;
      if(!EvalMA(maTf, hMaSingle, hMaFast, hMaSlow, maState,
                 maTrendMode, maCheckMode, maBufferPips, maMinDiffPips,
                 maBuy, maSell)) return false;
      buy &= maBuy; sell &= maSell;
   }
   if(useBos)
   {
      bool bosBuy = false, bosSell = false;
      if(!EvalBosBySource(bosBuy, bosSell)) return false;
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

bool HtfBiasModulesOn()
{
   return (g_HTF_UseStoch ||
           g_HTF_UseFibZone || g_HTF_UseMacdBias || g_HTF_UseRsiBias || MaEnabled(g_HTF_MA));
}

string MaStateTag(const int state)
{
   if(state == MA_SINGLE) return "m1";
   if(state == MA_DOUBLE) return "m2";
   return "";
}

void AddModuleTag(string &list, const string tag)
{
   if(StringLen(tag) == 0) return;
   if(StringLen(list) > 0) list += ",";
   list += tag;
}

string EnabledModulesContext()
{
   string ltf = "";
   if(g_LTF_UseRsiBias)       AddModuleTag(ltf, "rsi");
   if(g_LTF_UseFibZone)       AddModuleTag(ltf, "fib");
   if(g_LTF_UseMacdBias)      AddModuleTag(ltf, "macd");
   if(MaEnabled(g_LTF_MA))    AddModuleTag(ltf, MaStateTag(g_LTF_MA));
   if(g_LTF_UseStochCross)    AddModuleTag(ltf, "stX");
   if(g_LTF_UseStochClassic)  AddModuleTag(ltf, "stC");
   if(g_LTF_UseBos)           AddModuleTag(ltf, "bos:" + (g_BosSource == TF_SOURCE_OWN ? "own" : (g_BosSource == TF_SOURCE_HTF ? "htf" : "both")));
   if(g_LTF_UseSrBreakRetest) AddModuleTag(ltf, "srBrk");
   if(g_LTF_UseSrBounce)      AddModuleTag(ltf, "srRev");

   string out = " | LTF=" + (StringLen(ltf) > 0 ? ltf : "none");
   if(g_ConfluenceMode == CONF_LTF_AND_HTF)
   {
      string htf = "";
      if(g_HTF_UseRsiBias)   AddModuleTag(htf, "rsi");
      if(g_HTF_UseStoch)     AddModuleTag(htf, g_HTF_StochObOs ? "stoch:obos" : "stoch:mid");
      if(g_HTF_UseFibZone)   AddModuleTag(htf, "fib");
      if(g_HTF_UseMacdBias)  AddModuleTag(htf, "macd");
      if(MaEnabled(g_HTF_MA)) AddModuleTag(htf, MaStateTag(g_HTF_MA) + (g_HTF_MaFromLTF ? ":LTF" : ":own"));
      out += " | HTF=" + (StringLen(htf) > 0 ? htf : "none");
   }
   if(g_UseGrid)
      out += " | Grid=" + IntegerToString(EffectiveMaxLayers());
   return out;
}

// Consume current structure-TF closed bar for BOS EVENT (call once per UpdateSignal
// after both Fib passes, so Pass1/Pass2 can still see the same event).
void MarkBosEventStructBarSeen()
{
   if(g_BosSource == TF_SOURCE_OWN || g_BosSource == TF_SOURCE_BOTH)
   {
      datetime t = iTime(_Symbol, g_ltf, 1);
      if(t > 0) g_bosEventSeenLtfBar = t;
   }
   if(g_BosSource == TF_SOURCE_HTF || g_BosSource == TF_SOURCE_BOTH)
   {
      datetime t = iTime(_Symbol, g_htf, 1);
      if(t > 0) g_bosEventSeenHtfBar = t;
   }
}

void UpdateSignal()
{
   g_haveSignal      = false;
   g_signalIsBuy     = false;
   g_fibZoneTickGate = false;

   // Pass 1: normal eval (FibZone requires price in zone now)
   bool b1 = false, s1 = false;
   if(!EvalTf(g_ltf,
              g_LTF_UseStochCross, g_LTF_UseStochClassic, false, false,
              g_StochClassicMode, StochPullbackLevel, StochOversoldLevel, StochOverboughtLevel,
              g_LTF_UseSrBounce, g_LTF_UseSrBreakRetest, g_LTF_UseFibZone,
              g_LTF_UseMacdBias, g_LTF_UseRsiBias, g_LTF_MA, g_LTF_UseBos,
              g_stochL, g_rsiL, g_macdL,
              g_ltf, g_maL, g_maFL, g_maSL,
              g_LTF_MaTrendMode, g_LTF_MACheckMode, MABufferPips, MaMinDiffPips,
              g_atrL, false, b1, s1))
      return; // data not ready — do not consume BOS EVENT bar

   bool b2 = true, s2 = true; // ENTRY_ONLY, or empty HTF bias = pass-through
   if(g_ConfluenceMode == CONF_LTF_AND_HTF && HtfBiasModulesOn())
   {
      // HTF = zone bias (rsi / stoch zone / fib / macd / ma). No S/R, no BOS.
      const ENUM_TIMEFRAMES maTf = g_HTF_MaFromLTF ? g_ltf : g_htf;
      const int hMaS = g_HTF_MaFromLTF ? g_maL  : g_maH;
      const int hMaF = g_HTF_MaFromLTF ? g_maFL : g_maFH;
      const int hMaL = g_HTF_MaFromLTF ? g_maSL : g_maSH;
      const ENUM_MA_TREND_MODE maDir = g_HTF_MaFromLTF ? g_LTF_MaTrendMode : g_HTF_MaTrendMode;
      const ENUM_MA_CHECK maChk = g_HTF_MaFromLTF ? g_LTF_MACheckMode : g_HTF_MACheckMode;
      const double maBuf = g_HTF_MaFromLTF ? MABufferPips : HTF_MABufferPips;
      const double maDiff = g_HTF_MaFromLTF ? MaMinDiffPips : HTF_MaMinDiffPips;
      b2 = false; s2 = false;
      if(!EvalTf(g_htf,
                 false, false, g_HTF_UseStoch, g_HTF_StochObOs,
                 g_HTF_StochObOsMode, HTF_StochMidLevel, HTF_StochOversoldLevel, HTF_StochOverboughtLevel,
                 false, false, g_HTF_UseFibZone,
                 g_HTF_UseMacdBias, g_HTF_UseRsiBias, g_HTF_MA, false,
                 g_stochH, g_rsiH, g_macdH,
                 maTf, hMaS, hMaF, hMaL,
                 maDir, maChk, maBuf, maDiff,
                 g_atrH, false, b2, s2))
         return; // data not ready — do not consume BOS EVENT bar
   }

   bool isBuy = false;
   if(ResolveSignalSide(b1 && b2, s1 && s2, isBuy))
   {
      g_haveSignal  = true;
      g_signalIsBuy = isBuy;
      MarkBosEventStructBarSeen();
      return;
   }

   // Pass 2: FibZone leg-armed only (price may enter zone later this bar).
   const bool wantFibGate = (g_LTF_UseFibZone ||
                             (g_ConfluenceMode == CONF_LTF_AND_HTF && g_HTF_UseFibZone));
   if(!wantFibGate)
   {
      MarkBosEventStructBarSeen();
      return;
   }

   b1 = false; s1 = false;
   if(!EvalTf(g_ltf,
              g_LTF_UseStochCross, g_LTF_UseStochClassic, false, false,
              g_StochClassicMode, StochPullbackLevel, StochOversoldLevel, StochOverboughtLevel,
              g_LTF_UseSrBounce, g_LTF_UseSrBreakRetest, g_LTF_UseFibZone,
              g_LTF_UseMacdBias, g_LTF_UseRsiBias, g_LTF_MA, g_LTF_UseBos,
              g_stochL, g_rsiL, g_macdL,
              g_ltf, g_maL, g_maFL, g_maSL,
              g_LTF_MaTrendMode, g_LTF_MACheckMode, MABufferPips, MaMinDiffPips,
              g_atrL, true, b1, s1))
      return; // data not ready — do not consume BOS EVENT bar

   b2 = true; s2 = true;
   if(g_ConfluenceMode == CONF_LTF_AND_HTF && HtfBiasModulesOn())
   {
      const ENUM_TIMEFRAMES maTf = g_HTF_MaFromLTF ? g_ltf : g_htf;
      const int hMaS = g_HTF_MaFromLTF ? g_maL  : g_maH;
      const int hMaF = g_HTF_MaFromLTF ? g_maFL : g_maFH;
      const int hMaL = g_HTF_MaFromLTF ? g_maSL : g_maSH;
      const ENUM_MA_TREND_MODE maDir = g_HTF_MaFromLTF ? g_LTF_MaTrendMode : g_HTF_MaTrendMode;
      const ENUM_MA_CHECK maChk = g_HTF_MaFromLTF ? g_LTF_MACheckMode : g_HTF_MACheckMode;
      const double maBuf = g_HTF_MaFromLTF ? MABufferPips : HTF_MABufferPips;
      const double maDiff = g_HTF_MaFromLTF ? MaMinDiffPips : HTF_MaMinDiffPips;
      b2 = false; s2 = false;
      if(!EvalTf(g_htf,
                 false, false, g_HTF_UseStoch, g_HTF_StochObOs,
                 g_HTF_StochObOsMode, HTF_StochMidLevel, HTF_StochOversoldLevel, HTF_StochOverboughtLevel,
                 false, false, g_HTF_UseFibZone,
                 g_HTF_UseMacdBias, g_HTF_UseRsiBias, g_HTF_MA, false,
                 g_stochH, g_rsiH, g_macdH,
                 maTf, hMaS, hMaF, hMaL,
                 maDir, maChk, maBuf, maDiff,
                 g_atrH, true, b2, s2))
         return; // data not ready — do not consume BOS EVENT bar
   }

   if(ResolveSignalSide(b1 && b2, s1 && s2, isBuy))
   {
      g_haveSignal      = true;
      g_signalIsBuy     = isBuy;
      g_fibZoneTickGate = true; // TryEnter waits for live zone
   }
   MarkBosEventStructBarSeen();
}

//====================== ENTRY ======================
void DiagBlock(const string reason)
{
   // One line per bar when a signal fired but entry was still blocked.
   if(g_lastDiagBar == g_lastBarTime) return;
   g_lastDiagBar = g_lastBarTime;
   string msg = "BLOCKED " + reason
              + " | signal=" + (g_signalIsBuy ? "BUY" : "SELL");
   if(InpDetailedBlockedLog)
      msg += EnabledModulesContext();
   LogInfo(msg);
}

void TryEnter()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // FibZone: re-check live zone on every entry attempt (incl. layers).
   // Tick-gate arm = silent wait outside zone; otherwise DiagBlock.
   if(g_LTF_UseFibZone && !LiveInFibZone(g_ltf, g_atrL, g_signalIsBuy))
   {
      if(g_fibZoneTickGate) return;
      DiagBlock("FibZone"); return;
   }
   if(g_ConfluenceMode == CONF_LTF_AND_HTF && g_HTF_UseFibZone &&
      !LiveInFibZone(g_htf, g_atrH, g_signalIsBuy))
   {
      if(g_fibZoneTickGate) return;
      DiagBlock("HTF FibZone"); return;
   }

   if(!CanAttemptEntry())
   { DiagBlock("trade path guard (terminal/broker session/stale tick/retry cooldown)"); return; }

   if(MaxSpreadPips > 0 && (ask - bid) / g_pip > MaxSpreadPips)
   { DiagBlock("spread " + DoubleToString((ask - bid) / g_pip, 1) + " > " + IntegerToString(MaxSpreadPips)); return; }

   // MA module: re-check at entry tick (incl. layers) — m1 / m2 both live.
   if(MaEnabled(g_LTF_MA))
   {
      bool maB = false, maS = false;
      if(!EvalMA(g_ltf, g_maL, g_maFL, g_maSL, g_LTF_MA,
                 g_LTF_MaTrendMode, g_LTF_MACheckMode, MABufferPips, MaMinDiffPips,
                 maB, maS) ||
         (g_signalIsBuy ? !maB : !maS))
      { DiagBlock("MA filter"); return; }
   }
   if(g_ConfluenceMode == CONF_LTF_AND_HTF && MaEnabled(g_HTF_MA))
   {
      bool maB = false, maS = false;
      const ENUM_TIMEFRAMES maTf = g_HTF_MaFromLTF ? g_ltf : g_htf;
      const int hMaS = g_HTF_MaFromLTF ? g_maL  : g_maH;
      const int hMaF = g_HTF_MaFromLTF ? g_maFL : g_maFH;
      const int hMaL = g_HTF_MaFromLTF ? g_maSL : g_maSH;
      const ENUM_MA_TREND_MODE maDir = g_HTF_MaFromLTF ? g_LTF_MaTrendMode : g_HTF_MaTrendMode;
      const ENUM_MA_CHECK maChk = g_HTF_MaFromLTF ? g_LTF_MACheckMode : g_HTF_MACheckMode;
      const double maBuf = g_HTF_MaFromLTF ? MABufferPips : HTF_MABufferPips;
      const double maDiff = g_HTF_MaFromLTF ? MaMinDiffPips : HTF_MaMinDiffPips;
      if(!EvalMA(maTf, hMaS, hMaF, hMaL, g_HTF_MA,
                 maDir, maChk, maBuf, maDiff, maB, maS) ||
         (g_signalIsBuy ? !maB : !maS))
      { DiagBlock("HTF MA filter"); return; }
   }

   int    layers; double deepest; bool existingIsBuy;
   CountLayers(layers, deepest, existingIsBuy);

   const int maxLayers = EffectiveMaxLayers();
   if(layers >= maxLayers)
   { DiagBlock("MaxLayers reached (" + IntegerToString(layers) + "/" + IntegerToString(maxLayers)
               + (g_UseGrid ? " GridON" : " GridOFF") + ")"); return; }

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
// key = message category (own 300s cooldown); msg = full line to print.
void LogGuardOnce(const string key, const string msg)
{
   for(int i = 0; i < ArraySize(g_guardLogKeys); i++)
   {
      if(g_guardLogKeys[i] != key) continue;
      if(TimeCurrent() - g_guardLogTimes[i] < 300) return;
      g_guardLogTimes[i] = TimeCurrent();
      LogInfo(msg);
      return;
   }
   int n = ArraySize(g_guardLogKeys);
   ArrayResize(g_guardLogKeys, n + 1);
   ArrayResize(g_guardLogTimes, n + 1);
   g_guardLogKeys[n]  = key;
   g_guardLogTimes[n] = TimeCurrent();
   LogInfo(msg);
}

// Opt-in trace for indicator-data-not-ready paths (CopyBuffer/CopyRates
// short reads, invalid handles). Silent unless InpDebugLog is ON, and still
// throttled per key so a stuck condition doesn't spam every tick.
void LogDebugGuard(const string key, const string msg)
{
   if(!InpDebugLog) return;
   LogGuardOnce(key, "DBG " + msg);
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
   if(!g_UseBrokerSessionGuard) return true;

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
      LogGuardOnce("guard_session", "GUARD broker trade session closed");
      return false;
   }
   if(!IsTickFresh())
   {
      LogGuardOnce("guard_staletick", "GUARD no fresh ticks for " + IntegerToString(MaxStaleTickSeconds) + "s");
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
   if(lots <= 0)
   {
      LogGuardOnce("lots_invalid", "BLOCKED open — NormalizeLots(LotSize=" +
                   DoubleToString(LotSize, 2) + ") = 0 (check LotSize vs broker min/max/step)");
      return;
   }

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
         LogGuardOnce("fail_buy", "FAIL buy rc=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
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
         LogGuardOnce("fail_sell", "FAIL sell rc=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
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
         LogGuardOnce("fail_modify_fatal", "FAIL modify (fatal) rc=" + IntegerToString(rc) +
                      " " + trade.ResultRetcodeDescription() + " — will re-attempt after cooldown");
         return false;
      }
      if(attempt < maxTry && ModifyRetryDelayMs > 0)
         Sleep(ModifyRetryDelayMs);
   }
   LogGuardOnce("fail_modify_retries", "FAIL modify after " + IntegerToString(maxTry) + " tries rc=" +
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

   // m1: Fast/Slow both = single MaPeriod line. m2: Fast vs Slow.
   int h = INVALID_HANDLE;
   if(MaExitUsesSingleLine())
      h = g_maL;
   else
      h = (g_MaSLLine == MASL_FAST) ? g_maFL : g_maSL;
   if(h == INVALID_HANDLE) return false;

   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(h, 0, 0, 1, m) != 1) return false;

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

   string lineTag;
   if(MaExitUsesSingleLine()) lineTag = "m1";
   else                       lineTag = (g_MaSLLine == MASL_FAST) ? "m2-Fast" : "m2-Slow";
   LogGuardOnce("exit_ma_sl", "EXIT virtual MA SL hit " + (isBuy ? "bid " + DoubleToString(bid, _Digits) + " <= " : "ask " + DoubleToString(ask, _Digits) + " >= ") +
                DoubleToString(maSL, _Digits) + " (LTF " + lineTag + " " + (isBuy ? "-" : "+") + " " +
                DoubleToString(SLMABufferPips, 1) + " pips) — closing basket");
   CloseAllEA("virtual MA SL");
}

// Resolve LTF swing anchor for the open basket direction via g_SwingSLMode
// (independent of entry g_BosMode).
// Zigzag: leg start (olderPrice) when leg matches basket side.
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
      bool haveLeg = false, bullish = false, bos = false, bosEvt = false;
      double olderP = 0, newerP = 0;
      if(!ScanFibLeg(g_ltf, g_atrL, haveLeg, bullish, olderP, newerP, bos, bosEvt))
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
      if(!ScanFractalStructure(g_ltf, bOK, sOK, sh, sl))
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

   LogGuardOnce("exit_swing_sl", "EXIT virtual swing SL hit " + (isBuy ? "bid " + DoubleToString(bid, _Digits) + " <= " : "ask " + DoubleToString(ask, _Digits) + " >= ") +
                DoubleToString(g_swingSL, _Digits) +
                " (LTF " + engineTag + " SwMode=" + EnumToString(g_SwingSLMode) +
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
   if(!CanAttemptClose())
   {
      LogGuardOnce("close_blocked", "BLOCKED close" + (reason != "" ? " (" + reason + ")" : "")
                   + " — trade path guard (broker session/stale tick/retry cooldown); will retry");
      return;
   }

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
         LogGuardOnce("fail_close", "FAIL close rc=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      }
   }
   if(anyFail) g_lastCloseFailTime = TimeCurrent();
   else if(closedCount > 0)
   {
      LogInfo("CLOSE" + (reason != "" ? " (" + reason + ")" : "") + " | net P/L " + DoubleToString(totalPL, 2));
      NotifyPush("BASKET CLOSED" + (reason != "" ? " (" + reason + ")" : "") + " | Net P/L: " + DoubleToString(totalPL, 2));
      // Fresh state so the next basket cannot inherit armed peak / swing / pending lines.
      ResetBasket();
      ResetBasketLines();
   }
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