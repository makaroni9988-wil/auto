//+------------------------------------------------------------------+
//|                                                      lets-go.mq5 |
//|           Modular dual-TF confluence grid EA                     |
//|                                                                  |
//|  Skeleton: grid, basket SL/TP, virtual exits, session/weekend/   |
//|  news/market guards, modify-retry.                               |
//|                                                                  |
//|  Engine : THE SIGNAL BRAIN RUNS ON EVERY TICK. Two timings only, |
//|           everywhere: LIVE = the tick decides (indicator's live  |
//|           value / live price at a level, armed + fired the same  |
//|           tick). CLOSED = the closed candle arms it, ticks       |
//|           execute. No hybrids.                                   |
//|  Entry  : T1 = entry (every ON module must pass — all AND).      |
//|           T2 = zone bias (rsi / stoch / fib / macd / ma).        |
//|           rsi / macd: live/closed per chip (r./m. closed/live).  |
//|           Stoch: cross OR classic, x/c.closed or x/c.live.       |
//|           Fibo: entry always live (price in zone at the tick);   |
//|           the closed/live chip governs the LEG scan only.        |
//|           MA: master + m1/m2, live or closed timing.             |
//|           BOS: swing levels are live levels — live = tick break, |
//|           closed = candle-confirmed; event = at the break (entry |
//|           consumes it), bias = standing trend permission.        |
//|           S/R: full standalone entry — break/reject fires the    |
//|           tick price hits the pivot level, alone or with others. |
//|           One entry per T1 candle; grid layers by step rule.     |
//|           Grid chip OFF → 1 layer; ON → MaxLayers.               |
//|           Stoch inputs GLOBAL (one K/D + OB/OS/MID for T1+T2).   |
//|           MaSL: ON/OFF + Fast/Slow exit line (T1 MA lines).      |
//|  Exits  : broker pip-cap; optional virtual MaSL and/or SwSL.     |
//|  Panel  : chip toggles (top-left), GV memory.                    |
//|  Journal: Tag "lets-go #magic SYMBOL". Push INIT/BASKET only.    |
//|                                                                  |
//|  TEST ON DEMO / STRATEGY TESTER FIRST. Not a profit guarantee.   |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "5.47"

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_LABEL "lets-go"

//====================== ENUMS ======================
enum ENUM_CONF_MODE
{
   CONF_T1_ONLY,     // T1 entry only
   CONF_T1_AND_T2   // T1 entry AND T2 bias must agree
};
enum ENUM_STOCH_CROSS_MODE
{
   STOCH_CROSS_PULLBACK, // Cross must land below/above pullback level
   STOCH_CROSS_ANY,      // Any %K/%D cross
   STOCH_CROSS_OBOS      // Cross must come FROM OB (sell) / OS (buy)
};
enum ENUM_STOCH_CLASSIC_MODE
{
   STOCH_CLASSIC_MOM, // Momentum: buy in OB / sell in OS (ride the extreme)
   STOCH_CLASSIC_REV  // Reversal: buy in OS / sell in OB (fade the extreme)
};
enum ENUM_SIG_TIMING
{
   SIG_CLOSED, // Confirmed on closed candle (no repaint, up to 1 bar late)
   SIG_LIVE    // Live %K/%D values — fires intra-bar, instant
};
enum ENUM_MA_STYLE
{
   MA_STYLE_SINGLE, // m1 — single MA line
   MA_STYLE_DOUBLE  // m2 — fast vs slow
};
enum ENUM_MA_CHECK
{
   MA_CHECK_RUNNING,      // Live side only (+/- buffer)
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
enum ENUM_FIB_SCAN_MODE
{
   FIB_SCAN_CLOSED, // Zigzag scan: closed bars only
   FIB_SCAN_LIVE    // Zigzag scan: include forming bar (fibo-gun/bomb parity)
};
enum ENUM_TF_SOURCE
{
   TF_SOURCE_OWN,
   TF_SOURCE_T2
};

//====================== INPUTS ======================
input group "===== Confluence (T1 entry, optional T2 bias) ====="
input ENUM_CONF_MODE  ConfluenceMode = CONF_T1_ONLY; // T1 only, or T1+T2
input ENUM_TIMEFRAMES InpT1         = PERIOD_M30;    // T1 entry (signal clock + virtual exits)
input ENUM_TIMEFRAMES InpT2         = PERIOD_H1;     // T2 bias (AND mode only)

input group "===== Direction Master ====="
input bool TradeBuy  = true; // Allow BUY
input bool TradeSell = true; // Allow SELL

input group "===== T1 Entry (every ON module must pass — all AND) ====="
// Stoch: cross OR classic if both on. S/R: break OR reject if both on (live).
// Those families then AND with Fib / MACD / RSI / MA / BOS.
input bool T1_UseStochCross    = false; // Stoch cross
input bool T1_UseStochClassic  = false; // Stoch classic OB/OS
input bool T1_UseSrBounce      = false; // S/R reject (reversal, live at level)
input bool T1_UseSrBreak       = false; // S/R break (live at level)
input bool T1_UseFibZone       = false; // Fib golden zone
input bool T1_UseMacdBias      = false; // MACD bias
input bool T1_UseRsiBias       = false; // RSI bias
input bool T1_UseMA            = false; // MA module (panel: m1 / m2)
input bool T1_UseBos           = true;  // BOS (see BosMode)

input group "===== T2 Bias — zone modules (every ON must pass — all AND) ====="
// Ignored when ConfluenceMode = T1_ONLY.
// Zone bias: rsi / stoch / fib / macd / ma. (S/R + BOS stay T1 entry only.)
input bool T2_UseStoch    = false; // T2 stoch on/off (mid or OB/OS)
input bool T2_StochObOs   = false; // false=mid (%K vs pullback); true=OB/OS
input bool T2_UseFibZone  = false; // Fib golden zone
input bool T2_UseMacdBias = false; // MACD bias
input bool T2_UseRsiBias  = false; // RSI bias (mid-only)
input bool T2_UseMA       = false; // MA module (panel: m1 / m2)
input bool T2_MaFromT1   = false; // T2 MA eval uses T1 handles (panel own/T1)

input group "===== Stochastic (GLOBAL — one set for T1 and T2) ====="
// One stochastic everywhere: same %K/%D and the three global levels
// (OB / OS / MID). T1 uses cross+classic triggers, T2 uses the mid /
// OB-OS state — all reading these numbers, each on its own timeframe.
input int                     StochKPeriod         = 5;                 // Stochastic %K period
input int                     StochDPeriod         = 3;                 // Stochastic %D period
input int                     StochSlowing         = 3;                 // Stochastic slowing
input ENUM_MA_METHOD          StochMAMethod        = MODE_SMA;          // Stochastic MA method
input ENUM_STO_PRICE          StochPriceField      = STO_LOWHIGH;       // Stochastic price field
input double                  StochOverboughtLevel = 80;                // GLOBAL OB level
input double                  StochOversoldLevel   = 20;                // GLOBAL OS level
input double                  StochMidLevel        = 50;                // GLOBAL MID level (cross pullback + T2 mid)
input ENUM_STOCH_CROSS_MODE   StochCrossMode       = STOCH_CROSS_OBOS;  // T1 cross mode (pullback / any / OB-OS)
input ENUM_SIG_TIMING         StochCrossTiming     = SIG_CLOSED;        // T1 cross: closed / live (panel x.closed / x.live)
input ENUM_STOCH_CLASSIC_MODE StochClassicMode     = STOCH_CLASSIC_REV; // T1 classic: momentum / reversal
input ENUM_SIG_TIMING         StochClassicTiming   = SIG_CLOSED;        // T1 classic: closed / live (panel c.closed / c.live)
input ENUM_STOCH_CLASSIC_MODE T2_StochObOsMode     = STOCH_CLASSIC_REV; // T2 OB/OS style: momentum or reversal
input ENUM_SIG_TIMING         T2_StochTiming       = SIG_CLOSED;        // T2 stoch state: closed / live

input group "===== RSI / MACD (shared params) ====="
input int                RSIPeriod        = 14;          // RSI period
input ENUM_APPLIED_PRICE RSIAppliedPrice  = PRICE_CLOSE; // RSI applied price
input double             RSIMidLevel      = 50;          // RSI must be above(buy)/below(sell) this level
input ENUM_SIG_TIMING    T1_RsiTiming     = SIG_LIVE;    // T1 RSI: live tick / closed candle
input ENUM_SIG_TIMING    T2_RsiTiming     = SIG_LIVE;    // T2 RSI: live tick / closed candle
input int                MACDFastEMA      = 12;          // MACD fast EMA
input int                MACDSlowEMA      = 26;          // MACD slow EMA
input int                MACDSignalPeriod = 9;           // MACD signal period
input ENUM_APPLIED_PRICE MACDAppliedPrice = PRICE_CLOSE; // MACD applied price
input ENUM_SIG_TIMING    T1_MacdTiming    = SIG_LIVE;    // T1 MACD: live tick / closed candle
input ENUM_SIG_TIMING    T2_MacdTiming    = SIG_LIVE;    // T2 MACD: live tick / closed candle

input group "===== MA (m1 single line / m2 double line + MaSL lines) ====="
// One MA module per TF. Panel: master ON/OFF chip + m1/m2 mode chip.
//   m1 = single MA line (price vs MA, Follow / Reversal).
//   m2 = double line (fast vs slow, Follow / Reversal).
// Timing (RUNNING = live tick, CLOSED_ONLY = closed candle arms it).
// CANDLE_CLOSE is legacy — coerced to CLOSED_ONLY on load.
// T1 uses these settings. T2 has an independent own setup below.
// Risk row only toggles MaSL + Fast/Slow.
input ENUM_MA_METHOD     MaMethod       = MODE_EMA;    // SMA / EMA / SMMA / LWMA
input ENUM_APPLIED_PRICE MaAppliedPrice = PRICE_CLOSE; // Applied price
input int                MaShift        = 0;           // MA horizontal shift

input ENUM_MA_STYLE MaStyle        = MA_STYLE_DOUBLE;    // Default when T1/T2 UseMA is ON
input ENUM_MA_CHECK T1_MACheckMode = MA_CHECK_CLOSED_ONLY; // T1 Running / ClosedOnly (m1 / m2)
input double        MABufferPips   = 100;                // T1 m1 buffer (pips)

input int MaPeriod     = 34; // Single line (m1)
input int MaFastPeriod = 13; // m2 fast
input int MaSlowPeriod = 34; // m2 slow

// m1 / m2 entry direction.
input ENUM_MA_TREND_MODE T1_MaTrendMode = MA_TREND_FOLLOW; // T1 m1 / m2 direction
input double             MaMinDiffPips   = 100;             // T1 m2: 0 = any separation

input group "===== T2 MA (independent when panel source = own) ====="
input ENUM_MA_METHOD     T2_MaMethod       = MODE_EMA;         // T2 own MA method
input ENUM_APPLIED_PRICE T2_MaAppliedPrice = PRICE_CLOSE;      // T2 own applied price
input int                T2_MaShift        = 0;                // T2 own horizontal shift
input ENUM_MA_CHECK      T2_MACheckMode    = MA_CHECK_CLOSED_ONLY; // T2 own Running / ClosedOnly
input ENUM_MA_TREND_MODE T2_MaTrendMode    = MA_TREND_FOLLOW;  // T2 own Follow or Reversal
input double             T2_MABufferPips   = 100;              // T2 own m1 buffer (pips)
input double             T2_MaMinDiffPips  = 100;              // T2 own m2 minimum separation
input int                T2_MaPeriod       = 55;               // T2 own single line (m1)
input int                T2_MaFastPeriod   = 13;               // T2 own m2 fast line
input int                T2_MaSlowPeriod   = 55;               // T2 own m2 slow line

input group "===== S/R Pivot Entry (T1 entry; levels own or T2) ====="
input int    PivotLeftBars       = 15;    // Pivot left bars (levels TF; match sr-breaks)
input int    PivotRightBars      = 15;    // Pivot right bars (levels TF; match sr-breaks)
input int    LevelsLookback      = 200;   // Bars to scan for pivots on levels TF
input double SrBufferPips        = 0;     // Break: beyond level by this. Reject: within this of level. 0 = exact line
input ENUM_TF_SOURCE SrLevelsSource = TF_SOURCE_OWN; // S/R levels: own / T2

input group "===== Fib / BOS entry (shared params, per-TF scan) ====="
input ENUM_BOS_MODE        BosMode             = BOS_FRACTAL;      // Entry BOS engine
input ENUM_BOS_SIGNAL_MODE BosSignalMode       = BOS_SIGNAL_EVENT; // BOS entry mode (evt/bias)
input ENUM_TF_SOURCE       BosStructureSource = TF_SOURCE_OWN;     // BOS structure: own / T2

input double FibDeviationMult = 3.0;   // Zigzag: ATR deviation multiplier
input int    FibDepth         = 6;     // Zigzag: depth (confirm = Depth/2)
input int    FibATRPeriod     = 10;    // Zigzag: ATR period
input int    FibLookbackBars  = 100;   // Zigzag: bars scanned
input double FibZoneLevelMin  = 0.382; // FibZone: shallow edge
input double FibZoneLevelMax  = 0.618; // FibZone: deep edge
input ENUM_FIB_SCAN_MODE T1_FibScanMode = FIB_SCAN_CLOSED; // T1 zigzag scan: closed bars / live forming bar
input ENUM_FIB_SCAN_MODE T2_FibScanMode = FIB_SCAN_CLOSED; // T2 zigzag scan: closed bars / live forming bar

input int                 BosFractalPeriod   = 2;              // Fractal: bars each side
input ENUM_BOS_BREAK_MODE BosBreakMode       = BOS_BREAK_CLOSE; // Fractal break type
input int                 BosFractalLookback = 200;            // Fractal: bars scanned

input group "===== Stop / Exit ====="
// Broker SL = hard pip cap. Virtual MA / swing SL are optional; first hit closes.
// MaSL uses T1 MA lines. m1: Fast/Slow both = single. m2: Fast vs Slow.
input bool           UseVirtualMaSL = false;     // Virtual MA stop ON/OFF
input ENUM_MASL_LINE MaSLLine       = MASL_SLOW; // Default Fast/Slow (panel)
input double         SLMABufferPips = 100;       // MA SL buffer (pips)

input bool          UseSwingVirtualSL = false;       // Virtual swing stop (tighten-only)
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
input double BasketStartPips    = 200;  // Arm trail after this open profit
input double BasketGivebackPips = 50;   // Pullback from peak before close

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
input bool InpDetailedBlockedLog = true;  // BLOCKED: list enabled T1 / T2 modules
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
ENUM_FIB_SCAN_MODE g_T1_FibScanMode, g_T2_FibScanMode;
ENUM_STOCH_CROSS_MODE g_StochCrossMode;
ENUM_STOCH_CLASSIC_MODE g_StochClassicMode;
ENUM_SIG_TIMING g_StochCrossTiming, g_StochClassicTiming;
ENUM_SIG_TIMING g_T1_RsiTiming, g_T2_RsiTiming;
ENUM_SIG_TIMING g_T1_MacdTiming, g_T2_MacdTiming;
ENUM_SIG_TIMING g_T2_StochTiming;
ENUM_STOCH_CLASSIC_MODE g_T2_StochObOsMode;
ENUM_MA_CHECK g_T1_MACheckMode, g_T2_MACheckMode;
ENUM_MA_TREND_MODE g_T1_MaTrendMode, g_T2_MaTrendMode;
ENUM_TF_SOURCE g_BosSource, g_SrSource;
bool g_TradeBuy, g_TradeSell;
bool g_UseGrid;
int  g_MaxLayers;
bool g_T1_UseStochCross, g_T1_UseStochClassic, g_T1_UseSrBounce, g_T1_UseSrBreak; // derived: master && selection
// Family master ON/OFF chips + per-mode selections (stoch and S/R rows).
bool g_StOn = false, g_StCrossSel = false, g_StClassicSel = false;
bool g_SrOn = false, g_SrBreakSel = false, g_SrRejectSel = false;
bool g_T1_UseFibZone, g_T1_UseMacdBias, g_T1_UseRsiBias, g_T1_UseBos;
bool g_T2_UseStoch, g_T2_StochObOs;
bool g_T2_UseFibZone, g_T2_UseMacdBias, g_T2_UseRsiBias;
bool g_T2_MaFromT1 = false;   // T2 MA eval on T1 handles
int  g_T1_MA = MA_OFF;        // derived: master && mode (see ApplyFamilyMasters)
int  g_T2_MA = MA_OFF;
// MA family: master ON/OFF chip + m1/m2 mode selection, per TF.
bool g_T1_MaOn = false, g_T2_MaOn = false;
int  g_T1_MaSel = MA_DOUBLE, g_T2_MaSel = MA_DOUBLE;
bool g_UseVirtualMaSL, g_UseSwingVirtualSL, g_UseBasketTP;
bool g_UseSession, g_UseWeekendFilter, g_UseNewsFilter, g_UseBrokerSessionGuard;
ENUM_MASL_LINE g_MaSLLine = MASL_SLOW;

// Keep the derived module bools (used by eval/trigger/tags) in step with the
// family master chips: a family is active only when master ON and mode picked.
void ApplyFamilyMasters()
{
   g_T1_UseStochCross   = (g_StOn && g_StCrossSel);
   g_T1_UseStochClassic = (g_StOn && g_StClassicSel);
   g_T1_UseSrBreak      = (g_SrOn && g_SrBreakSel);
   g_T1_UseSrBounce     = (g_SrOn && g_SrRejectSel);
   g_T1_MA = g_T1_MaOn ? g_T1_MaSel : MA_OFF;
   g_T2_MA = g_T2_MaOn ? g_T2_MaSel : MA_OFF;
}

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

// MaSL line family from T1 MA module; if OFF, use input MaStyle default.
int MaExitState()
{
   if(MaEnabled(g_T1_MA)) return g_T1_MA;
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
ENUM_TIMEFRAMES g_t1;
ENUM_TIMEFRAMES g_t2;

int g_stochT1 = INVALID_HANDLE, g_rsiT1 = INVALID_HANDLE, g_macdT1 = INVALID_HANDLE;
int g_maT1    = INVALID_HANDLE, g_maFT1 = INVALID_HANDLE, g_maST1 = INVALID_HANDLE, g_atrT1 = INVALID_HANDLE;
int g_stochT2 = INVALID_HANDLE, g_rsiT2 = INVALID_HANDLE, g_macdT2 = INVALID_HANDLE;
int g_maT2    = INVALID_HANDLE, g_maFT2 = INVALID_HANDLE, g_maST2 = INVALID_HANDLE, g_atrT2 = INVALID_HANDLE;

double   g_pip = 0;
datetime g_lastBarTime  = 0;
datetime g_lastEntryBar = 0;

bool   g_haveSignal  = false;
bool   g_signalIsBuy = false;
// True when S/R is the only directional module: signal armed side-neutral,
// the live level trigger picks buy/sell at the tick it fires.
bool   g_srSideFromTick  = false;

// BOS EVENT latches. Only an ENTRY consumes a break: when a basket opens on
// a BOS event, the broken level's price is recorded here and that exact
// level can never fire a second basket. Evaluation alone never eats events.
double g_bosEvtLvlBuy = 0, g_bosEvtLvlSell = 0;   // candidate level this tick
double g_bosDoneLvlBuy = 0, g_bosDoneLvlSell = 0; // consumed on entry

// Zigzag structure reference for live BOS (set by every ScanFibLeg pass):
// the previous same-side swing the current leg has to beat.
bool   g_zzHavePrevSwing = false;
double g_zzPrevSwing     = 0;

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
   return "v540|" + IntegerToString((int)ConfluenceMode) + "|"
        + IntegerToString((int)BosMode) + "|"
        + IntegerToString((int)BosSignalMode) + "|"
        + IntegerToString((int)BosBreakMode) + "|"
        + IntegerToString((int)T1_FibScanMode) + IntegerToString((int)T2_FibScanMode) + "|"
        + IntegerToString((int)BosStructureSource) + "|"
        + IntegerToString((int)SwingSLMode) + "|"
        + IntegerToString((int)TradeBuy) + IntegerToString((int)TradeSell) + "|"
        + IntegerToString((int)UseGrid) + "|" + IntegerToString(MaxLayers) + "|"
        + IntegerToString((int)T1_UseStochCross) + IntegerToString((int)T1_UseStochClassic)
        + IntegerToString((int)T1_UseSrBounce) + IntegerToString((int)T1_UseSrBreak)
        + IntegerToString((int)T1_UseFibZone) + IntegerToString((int)T1_UseMacdBias)
        + IntegerToString((int)T1_UseRsiBias) + IntegerToString((int)T1_UseMA)
        + IntegerToString((int)T1_UseBos) + "|"
        + IntegerToString((int)StochCrossMode) + IntegerToString((int)StochClassicMode)
        + IntegerToString((int)StochCrossTiming) + IntegerToString((int)StochClassicTiming)
        + IntegerToString((int)T2_StochTiming) + "|"
        + IntegerToString((int)T1_RsiTiming) + IntegerToString((int)T2_RsiTiming)
        + IntegerToString((int)T1_MacdTiming) + IntegerToString((int)T2_MacdTiming) + "|"
        + IntegerToString((int)T1_MaTrendMode) + "|" + IntegerToString((int)T1_MACheckMode) + "|"
        + IntegerToString((int)T2_UseStoch) + IntegerToString((int)T2_StochObOs)
        + IntegerToString((int)T2_UseFibZone) + IntegerToString((int)T2_UseMacdBias)
        + IntegerToString((int)T2_UseRsiBias) + IntegerToString((int)T2_UseMA)
        + IntegerToString((int)T2_MaFromT1) + "|" + IntegerToString((int)T2_StochObOsMode) + "|"
        + IntegerToString((int)T2_MaTrendMode) + "|" + IntegerToString((int)T2_MACheckMode) + "|"
        + IntegerToString((int)SrLevelsSource) + "|"
        + IntegerToString((int)MaStyle) + IntegerToString((int)MaMethod)
        + IntegerToString(T2_MaPeriod) + IntegerToString(T2_MaFastPeriod)
        + IntegerToString(T2_MaSlowPeriod)
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
   g_T1_FibScanMode = T1_FibScanMode;
   g_T2_FibScanMode = T2_FibScanMode;
   // BOS source is own / T2 only — a legacy BOTH input falls back to OWN.
   g_BosSource = (BosStructureSource == TF_SOURCE_T2) ? TF_SOURCE_T2 : TF_SOURCE_OWN;
   g_SwingSLMode = SwingSLMode;
   g_TradeBuy = TradeBuy;
   g_TradeSell = TradeSell;
   g_UseGrid = UseGrid;
   g_MaxLayers = MathMax(1, MathMin(3, MaxLayers));
   g_StochCrossMode = StochCrossMode;
   g_StochClassicMode = StochClassicMode;
   g_StochCrossTiming = StochCrossTiming;
   g_StochClassicTiming = StochClassicTiming;
   g_T2_StochTiming = T2_StochTiming;
   g_T1_RsiTiming = T1_RsiTiming;
   g_T2_RsiTiming = T2_RsiTiming;
   g_T1_MacdTiming = T1_MacdTiming;
   g_T2_MacdTiming = T2_MacdTiming;
   g_T1_MaTrendMode = T1_MaTrendMode;
   // Hybrid CANDLE_CLOSE is legacy — two timings only (live / closed).
   g_T1_MACheckMode = (T1_MACheckMode == MA_CHECK_RUNNING) ? MA_CHECK_RUNNING : MA_CHECK_CLOSED_ONLY;

   g_StCrossSel   = T1_UseStochCross;
   g_StClassicSel = T1_UseStochClassic;
   g_StOn         = (T1_UseStochCross || T1_UseStochClassic);
   g_SrBreakSel   = T1_UseSrBreak;
   g_SrRejectSel  = T1_UseSrBounce;
   g_SrOn         = (T1_UseSrBreak || T1_UseSrBounce);
   ApplyFamilyMasters();
   g_T1_UseFibZone = T1_UseFibZone;
   g_T1_UseMacdBias = T1_UseMacdBias;
   g_T1_UseRsiBias = T1_UseRsiBias;
   g_T1_MaOn  = T1_UseMA;
   g_T1_MaSel = MaStyleToState(MaStyle);
   g_T1_UseBos = T1_UseBos;

   g_T2_UseStoch = T2_UseStoch;
   g_T2_StochObOs = T2_StochObOs;
   g_T2_StochObOsMode = T2_StochObOsMode;
   g_T2_UseFibZone = T2_UseFibZone;
   g_T2_UseMacdBias = T2_UseMacdBias;
   g_T2_UseRsiBias = T2_UseRsiBias;
   g_T2_MaOn  = T2_UseMA;
   g_T2_MaSel = MaStyleToState(MaStyle);
   ApplyFamilyMasters();
   g_T2_MaFromT1 = T2_MaFromT1;
   g_T2_MaTrendMode = T2_MaTrendMode;
   g_T2_MACheckMode = (T2_MACheckMode == MA_CHECK_RUNNING) ? MA_CHECK_RUNNING : MA_CHECK_CLOSED_ONLY;
   // S/R source is own / T2 only — a legacy BOTH input falls back to OWN.
   g_SrSource = (SrLevelsSource == TF_SOURCE_T2) ? TF_SOURCE_T2 : TF_SOURCE_OWN;

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
   PanelSaveInt("T1_FibScan", (int)g_T1_FibScanMode);
   PanelSaveInt("T2_FibScan", (int)g_T2_FibScanMode);
   PanelSaveInt("BosSrc", (int)g_BosSource);
   PanelSaveInt("SwMode", (int)g_SwingSLMode);
   PanelSaveBool("Buy", g_TradeBuy);
   PanelSaveBool("Sell", g_TradeSell);
   PanelSaveBool("Grid", g_UseGrid);
   PanelSaveInt("GridN", g_MaxLayers);
   PanelSaveInt("StXMode", (int)g_StochCrossMode);
   PanelSaveInt("StCMode", (int)g_StochClassicMode);
   PanelSaveInt("T1_stXt", (int)g_StochCrossTiming);
   PanelSaveInt("T1_stCt", (int)g_StochClassicTiming);
   PanelSaveInt("T2_stT", (int)g_T2_StochTiming);
   PanelSaveInt("T1_rsiT", (int)g_T1_RsiTiming);
   PanelSaveInt("T2_rsiT", (int)g_T2_RsiTiming);
   PanelSaveInt("T1_macdT", (int)g_T1_MacdTiming);
   PanelSaveInt("T2_macdT", (int)g_T2_MacdTiming);
   PanelSaveInt("T1_MaDir", (int)g_T1_MaTrendMode);
   PanelSaveInt("T1_MaChk", (int)g_T1_MACheckMode);

   PanelSaveBool("T1_stOn", g_StOn);
   PanelSaveBool("T1_stX", g_StCrossSel);
   PanelSaveBool("T1_stC", g_StClassicSel);
   PanelSaveBool("T1_srOn", g_SrOn);
   PanelSaveBool("T1_srR", g_SrBreakSel);
   PanelSaveBool("T1_srB", g_SrRejectSel);
   PanelSaveBool("T1_fib", g_T1_UseFibZone);
   PanelSaveBool("T1_macd", g_T1_UseMacdBias);
   PanelSaveBool("T1_rsi", g_T1_UseRsiBias);
   PanelSaveBool("T1_maOn", g_T1_MaOn);
   PanelSaveInt("T1_ma", g_T1_MaSel);
   PanelSaveBool("T1_bos", g_T1_UseBos);
   PanelSaveInt("SrLv", (int)g_SrSource);

   PanelSaveBool("T2_stoch", g_T2_UseStoch);
   PanelSaveBool("T2_stOb", g_T2_StochObOs);
   PanelSaveInt("T2_stDir", (int)g_T2_StochObOsMode);
   PanelSaveBool("T2_fib", g_T2_UseFibZone);
   PanelSaveBool("T2_macd", g_T2_UseMacdBias);
   PanelSaveBool("T2_rsi", g_T2_UseRsiBias);
   PanelSaveBool("T2_maOn", g_T2_MaOn);
   PanelSaveInt("T2_ma", g_T2_MaSel);
   PanelSaveBool("T2_maT1", g_T2_MaFromT1);
   PanelSaveInt("T2_MaDir", (int)g_T2_MaTrendMode);
   PanelSaveInt("T2_MaChk", (int)g_T2_MACheckMode);

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
   g_T1_FibScanMode = (ENUM_FIB_SCAN_MODE)PanelLoadInt("T1_FibScan", (int)g_T1_FibScanMode);
   g_T2_FibScanMode = (ENUM_FIB_SCAN_MODE)PanelLoadInt("T2_FibScan", (int)g_T2_FibScanMode);
   g_BosSource = (ENUM_TF_SOURCE)PanelLoadInt("BosSrc", (int)g_BosSource);
   g_SwingSLMode = (ENUM_BOS_MODE)PanelLoadInt("SwMode", (int)g_SwingSLMode);
   g_TradeBuy = PanelLoadBool("Buy", g_TradeBuy);
   g_TradeSell = PanelLoadBool("Sell", g_TradeSell);
   g_UseGrid = PanelLoadBool("Grid", g_UseGrid);
   g_MaxLayers = PanelLoadInt("GridN", g_MaxLayers);
   g_StochCrossMode = (ENUM_STOCH_CROSS_MODE)PanelLoadInt("StXMode", (int)g_StochCrossMode);
   g_StochClassicMode = (ENUM_STOCH_CLASSIC_MODE)PanelLoadInt("StCMode", (int)g_StochClassicMode);
   g_StochCrossTiming = (ENUM_SIG_TIMING)PanelLoadInt("T1_stXt", (int)g_StochCrossTiming);
   g_StochClassicTiming = (ENUM_SIG_TIMING)PanelLoadInt("T1_stCt", (int)g_StochClassicTiming);
   g_T2_StochTiming = (ENUM_SIG_TIMING)PanelLoadInt("T2_stT", (int)g_T2_StochTiming);
   g_T1_RsiTiming = (ENUM_SIG_TIMING)PanelLoadInt("T1_rsiT", (int)g_T1_RsiTiming);
   g_T2_RsiTiming = (ENUM_SIG_TIMING)PanelLoadInt("T2_rsiT", (int)g_T2_RsiTiming);
   g_T1_MacdTiming = (ENUM_SIG_TIMING)PanelLoadInt("T1_macdT", (int)g_T1_MacdTiming);
   g_T2_MacdTiming = (ENUM_SIG_TIMING)PanelLoadInt("T2_macdT", (int)g_T2_MacdTiming);
   g_T1_MaTrendMode = (ENUM_MA_TREND_MODE)PanelLoadInt("T1_MaDir", (int)g_T1_MaTrendMode);
   g_T1_MACheckMode = (ENUM_MA_CHECK)PanelLoadInt("T1_MaChk", (int)g_T1_MACheckMode);

   // Selections keep their legacy GV keys; the master chips get new keys with
   // "any selection ON" as the upgrade fallback, so old saved states carry over.
   g_StCrossSel   = PanelLoadBool("T1_stX", g_StCrossSel);
   g_StClassicSel = PanelLoadBool("T1_stC", g_StClassicSel);
   g_StOn         = PanelLoadBool("T1_stOn", g_StCrossSel || g_StClassicSel);
   g_SrBreakSel   = PanelLoadBool("T1_srR", g_SrBreakSel);
   g_SrRejectSel  = PanelLoadBool("T1_srB", g_SrRejectSel);
   g_SrOn         = PanelLoadBool("T1_srOn", g_SrBreakSel || g_SrRejectSel);
   ApplyFamilyMasters();
   g_T1_UseFibZone = PanelLoadBool("T1_fib", g_T1_UseFibZone);
   g_T1_UseMacdBias = PanelLoadBool("T1_macd", g_T1_UseMacdBias);
   g_T1_UseRsiBias = PanelLoadBool("T1_rsi", g_T1_UseRsiBias);
   g_T1_MaSel = PanelLoadInt("T1_ma", g_T1_MaSel);
   g_T1_MaOn  = PanelLoadBool("T1_maOn", MaEnabled(g_T1_MaSel));
   g_T1_UseBos = PanelLoadBool("T1_bos", g_T1_UseBos);
   g_SrSource = (ENUM_TF_SOURCE)PanelLoadInt("SrLv", (int)g_SrSource);

   g_T2_UseStoch = PanelLoadBool("T2_stoch", g_T2_UseStoch);
   g_T2_StochObOs = PanelLoadBool("T2_stOb", g_T2_StochObOs);
   g_T2_StochObOsMode = (ENUM_STOCH_CLASSIC_MODE)PanelLoadInt("T2_stDir", (int)g_T2_StochObOsMode);
   g_T2_UseFibZone = PanelLoadBool("T2_fib", g_T2_UseFibZone);
   g_T2_UseMacdBias = PanelLoadBool("T2_macd", g_T2_UseMacdBias);
   g_T2_UseRsiBias = PanelLoadBool("T2_rsi", g_T2_UseRsiBias);
   g_T2_MaSel = PanelLoadInt("T2_ma", g_T2_MaSel);
   g_T2_MaOn  = PanelLoadBool("T2_maOn", MaEnabled(g_T2_MaSel));
   g_T2_MaFromT1 = PanelLoadBool("T2_maT1", g_T2_MaFromT1);
   g_T2_MaTrendMode = (ENUM_MA_TREND_MODE)PanelLoadInt("T2_MaDir", (int)g_T2_MaTrendMode);
   g_T2_MACheckMode = (ENUM_MA_CHECK)PanelLoadInt("T2_MaChk", (int)g_T2_MACheckMode);

   // Mode selection must be m1/m2 (a legacy saved OFF becomes the style default).
   if(!MaEnabled(g_T1_MaSel)) g_T1_MaSel = MaStyleToState(MaStyle);
   if(!MaEnabled(g_T2_MaSel)) g_T2_MaSel = MaStyleToState(MaStyle);

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
   if(g_ConfluenceMode != CONF_T1_ONLY && g_ConfluenceMode != CONF_T1_AND_T2)
      g_ConfluenceMode = CONF_T1_ONLY;
   if(g_BosMode != BOS_ZIGZAG && g_BosMode != BOS_FRACTAL && g_BosMode != BOS_BOTH_AND)
      g_BosMode = BOS_FRACTAL;
   if(g_BosSignalMode != BOS_SIGNAL_EVENT && g_BosSignalMode != BOS_SIGNAL_BIAS)
      g_BosSignalMode = BOS_SIGNAL_EVENT;
   if(g_BosBreakMode != BOS_BREAK_CLOSE && g_BosBreakMode != BOS_BREAK_WICK)
      g_BosBreakMode = BOS_BREAK_CLOSE;
   if(g_T1_FibScanMode != FIB_SCAN_CLOSED && g_T1_FibScanMode != FIB_SCAN_LIVE)
      g_T1_FibScanMode = FIB_SCAN_CLOSED;
   if(g_T2_FibScanMode != FIB_SCAN_CLOSED && g_T2_FibScanMode != FIB_SCAN_LIVE)
      g_T2_FibScanMode = FIB_SCAN_CLOSED;
   if(g_BosSource != TF_SOURCE_OWN && g_BosSource != TF_SOURCE_T2)
      g_BosSource = TF_SOURCE_OWN;
   // S/R source is own / T2 only — anything invalid (e.g. stale GV int) falls back to OWN.
   if(g_SrSource != TF_SOURCE_OWN && g_SrSource != TF_SOURCE_T2)
      g_SrSource = TF_SOURCE_OWN;
   ApplyFamilyMasters();
   g_MaxLayers = MathMax(1, MathMin(3, g_MaxLayers));
   if(g_SwingSLMode != BOS_ZIGZAG && g_SwingSLMode != BOS_FRACTAL && g_SwingSLMode != BOS_BOTH_AND)
      g_SwingSLMode = BOS_FRACTAL;
   if(g_StochCrossMode != STOCH_CROSS_PULLBACK && g_StochCrossMode != STOCH_CROSS_ANY
      && g_StochCrossMode != STOCH_CROSS_OBOS)
      g_StochCrossMode = STOCH_CROSS_OBOS;
   if(g_StochCrossTiming != SIG_CLOSED && g_StochCrossTiming != SIG_LIVE)
      g_StochCrossTiming = SIG_CLOSED;
   if(g_StochClassicTiming != SIG_CLOSED && g_StochClassicTiming != SIG_LIVE)
      g_StochClassicTiming = SIG_CLOSED;
   if(g_T2_StochTiming != SIG_CLOSED && g_T2_StochTiming != SIG_LIVE)
      g_T2_StochTiming = SIG_CLOSED;
   if(g_T1_RsiTiming != SIG_CLOSED && g_T1_RsiTiming != SIG_LIVE)
      g_T1_RsiTiming = SIG_LIVE;
   if(g_T2_RsiTiming != SIG_CLOSED && g_T2_RsiTiming != SIG_LIVE)
      g_T2_RsiTiming = SIG_LIVE;
   if(g_T1_MacdTiming != SIG_CLOSED && g_T1_MacdTiming != SIG_LIVE)
      g_T1_MacdTiming = SIG_LIVE;
   if(g_T2_MacdTiming != SIG_CLOSED && g_T2_MacdTiming != SIG_LIVE)
      g_T2_MacdTiming = SIG_LIVE;
   if(g_StochClassicMode != STOCH_CLASSIC_MOM && g_StochClassicMode != STOCH_CLASSIC_REV)
      g_StochClassicMode = STOCH_CLASSIC_REV;
   if(g_T2_StochObOsMode != STOCH_CLASSIC_MOM && g_T2_StochObOsMode != STOCH_CLASSIC_REV)
      g_T2_StochObOsMode = STOCH_CLASSIC_REV;
   // Two timings only: RUNNING (live) / CLOSED_ONLY (closed). The legacy
   // CANDLE_CLOSE hybrid and anything invalid coerce to CLOSED_ONLY.
   if(g_T1_MACheckMode != MA_CHECK_RUNNING)
      g_T1_MACheckMode = MA_CHECK_CLOSED_ONLY;
   if(g_T2_MACheckMode != MA_CHECK_RUNNING)
      g_T2_MACheckMode = MA_CHECK_CLOSED_ONLY;
   if(g_T1_MaTrendMode != MA_TREND_FOLLOW && g_T1_MaTrendMode != MA_TREND_REVERSAL)
      g_T1_MaTrendMode = MA_TREND_FOLLOW;
   if(g_T2_MaTrendMode != MA_TREND_FOLLOW && g_T2_MaTrendMode != MA_TREND_REVERSAL)
      g_T2_MaTrendMode = MA_TREND_FOLLOW;
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
      "INP_FP","Conf","BosMode","BosSig","BosBrk","T1_FibScan","T2_FibScan","BosSrc","SwMode","Buy","Sell","Grid","GridN","Collapsed","SrLv",
      "StXMode","StCMode","T1_stXt","T1_stCt","T2_stT","T1_rsiT","T2_rsiT","T1_macdT","T2_macdT","T1_MaDir","T1_MaChk",
      "T1_stOn","T1_stX","T1_stC","T1_srOn","T1_srB","T1_srR","T1_fib","T1_macd","T1_rsi","T1_maOn","T1_ma","T1_bos",
      "T2_stoch","T2_stOb","T2_stDir","T2_fib","T2_macd","T2_rsi","T2_maOn","T2_ma","T2_maT1","T2_MaDir","T2_MaChk",
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
      id == "GuardSt")
      return true;
   return false;
}

void PanelDeleteAll()
{
   if(StringLen(g_panelPrefix) == 0)
      g_panelPrefix = "LGUI_" + IntegerToString(ChartID()) + "_";
   ObjectsDeleteAll(0, g_panelPrefix);
}

// Panel palette — single source for every chip color.
const color PNL_MODE_BG   = C'36,52,68';    // mode chip (always clickable, blue)
const color PNL_MODE_FG   = C'220,235,250';
const color PNL_MODE_BD   = C'70,110,140';
const color PNL_ON_BG     = C'40,110,92';   // toggle ON (green); also status OPEN
const color PNL_ON_FG     = C'235,255,248';
const color PNL_ON_BD     = C'80,160,130';
const color PNL_OFF_BG    = C'48,48,48';    // toggle OFF (gray)
const color PNL_OFF_FG    = C'160,160,160';
const color PNL_OFF_BD    = C'36,36,36';
const color PNL_DIS_BG    = C'32,32,32';    // locked / disabled
const color PNL_DIS_FG    = C'90,90,90';
const color PNL_DIS_BD    = C'28,28,28';
const color PNL_BLOCK_BG  = C'130,55,55';   // status chip BLOCK (red)
const color PNL_BLOCK_BD  = C'175,75,75';
const color PNL_STATUS_FG = C'245,245,245';

void PanelStyleChip(const string name, const string text, const string tip,
                    const bool on, const bool isModeChip)
{
   color bg, fg, bd;
   if(isModeChip)
   {
      bg = PNL_MODE_BG;
      fg = PNL_MODE_FG;
      bd = PNL_MODE_BD;
   }
   else if(on)
   {
      bg = PNL_ON_BG;
      fg = PNL_ON_FG;
      bd = PNL_ON_BD;
   }
   else
   {
      bg = PNL_OFF_BG;
      fg = PNL_OFF_FG;
      bd = PNL_OFF_BD;
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
   ObjectSetInteger(0, name, OBJPROP_COLOR, PNL_DIS_FG);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, PNL_DIS_BG);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, PNL_DIS_BD);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
}

void PanelStyleStatus(const string name, const bool blocked)
{
   ObjectSetString (0, name, OBJPROP_TEXT, blocked ? "BLOCK" : "OPEN");
   ObjectSetString (0, name, OBJPROP_TOOLTIP, "Current combined entry-guard status");
   ObjectSetInteger(0, name, OBJPROP_COLOR, PNL_STATUS_FG);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, blocked ? PNL_BLOCK_BG : PNL_ON_BG);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, blocked ? PNL_BLOCK_BD : PNL_ON_BD);
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
   // Fixed 5-column grid: every row shares the same column edges, so chips
   // align vertically panel-wide. A row with fewer chips lets its LAST chip
   // span the remaining columns (no dead filler chips).
   const int cols  = 5;
   const int slotW = (rowW - gap * (cols - 1)) / cols;
   const int step  = slotW + gap;
   for(int i = 0; i < n; i++)
   {
      const int w = (i == n - 1) ? (rowW - step * i) : slotW;
      PanelEnsureButton(ids[i], x0 + step * i, y, w, chipH);
   }
}

string ConfChipText()
{
   return (g_ConfluenceMode == CONF_T1_ONLY) ? "T1" : "+T2";
}

string BosChipText()
{
   if(g_BosMode == BOS_FRACTAL) return "Fractal";
   if(g_BosMode == BOS_BOTH_AND) return "Both";
   return "ZigZag";
}

// Swing SL method chip (independent of entry BOS engine)
string SwMdChipText()
{
   if(g_SwingSLMode == BOS_FRACTAL) return "Fractal";
   if(g_SwingSLMode == BOS_BOTH_AND) return "Both";
   return "ZigZag";
}

string ConfTip()
{
   return (g_ConfluenceMode == CONF_T1_ONLY)
      ? "T1 entry only (click to also require T2 bias)"
      : "T1 entry AND T2 bias (click for T1 only)";
}

string BosTip()
{
   if(g_BosMode == BOS_FRACTAL) return "BOS engine: Fractal (click to cycle)";
   if(g_BosMode == BOS_BOTH_AND) return "BOS engine: BOTH must agree (click to cycle)";
   return "BOS engine: Zigzag (click to cycle)";
}

string SourceText(const ENUM_TF_SOURCE source)
{
   if(source == TF_SOURCE_T2) return "T2";
   return "own";
}
string BosSrcChipText() { return SourceText(g_BosSource); }
string BosSrcTip()
{
   return "BOS structure source: " + SourceText(g_BosSource) + " (own / T2)";
}

string BosSigChipText()
{
   return (g_BosSignalMode == BOS_SIGNAL_BIAS) ? "bias" : "event";
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
   if(g_StochCrossMode == STOCH_CROSS_OBOS) return "OB/OS";
   return "pullback"; // PULLBACK until user clicks into any/OS-OB cycle
}
string StXModeTip()
{
   if(g_StochCrossMode == STOCH_CROSS_ANY)
      return "Stoch cross: ANY (cross anywhere). Click for OB/OS origin";
   if(g_StochCrossMode == STOCH_CROSS_OBOS)
      return "Stoch cross: must come FROM OB/OS. Click for pullback";
   return "Stoch cross: pullback side of MID (buy below / sell above). Click for ANY";
}

string StCModeChipText()
{
   return (g_StochClassicMode == STOCH_CLASSIC_MOM) ? "momentum" : "reversal";
}
string StCModeTip()
{
   return (g_StochClassicMode == STOCH_CLASSIC_MOM)
      ? "Stoch classic mom: buy OB / sell OS. Click for rev"
      : "Stoch classic rev: buy OS / sell OB. Click for mom";
}

// 3-state stoch chips: off (gray) -> x.closed/c.closed -> x.live/c.live.
// Faces show the SELECTION; the family master chip gates whether it trades.
string StXChipText()
{
   if(!g_StCrossSel) return "cross";
   return (g_StochCrossTiming == SIG_LIVE) ? "x.live" : "x.closed";
}
string StXChipTip()
{
   if(!g_StCrossSel) return "T1 Stoch cross OFF. Click: x.closed > x.live > off";
   return (g_StochCrossTiming == SIG_LIVE)
      ? "Stoch cross LIVE: fires the tick %K crosses %D. Click: off"
      : "Stoch cross CLOSED: confirmed on candle close. Click: x.live";
}
string StCChipText()
{
   if(!g_StClassicSel) return "classic";
   return (g_StochClassicTiming == SIG_LIVE) ? "c.live" : "c.closed";
}
string StCChipTip()
{
   if(!g_StClassicSel) return "T1 Stoch classic OB/OS OFF. Click: c.closed > c.live > off";
   return (g_StochClassicTiming == SIG_LIVE)
      ? "Stoch classic LIVE: fires the tick %K enters the zone. Click: off"
      : "Stoch classic CLOSED: zone on candle close. Click: c.live";
}

string T2StochModeChipText() { return g_T2_StochObOs ? "OB/OS" : "mid"; }
string T2StochModeTip()
{
   return g_T2_StochObOs
      ? "T2 stoch: OB/OS zone. Click for mid (%K vs pullback)"
      : "T2 stoch: mid (%K vs pullback). Click for OB/OS";
}

string T2StochDirText() { return g_T2_StochObOsMode == STOCH_CLASSIC_MOM ? "momentum" : "reversal"; }

string T2MaSrcChipText() { return g_T2_MaFromT1 ? "T1" : "own"; }
string T2MaSrcTip()
{
   return g_T2_MaFromT1
      ? "T2 MA uses T1 handles. Click for own T2"
      : "T2 MA uses own T2 handles. Click for T1";
}

string SwMdTip()
{
   if(g_SwingSLMode == BOS_FRACTAL)
      return "Swing SL method: Fractal (click to cycle; independent of entry BOS)";
   if(g_SwingSLMode == BOS_BOTH_AND)
      return "Swing SL method: BOTH tighter (click to cycle; independent of entry BOS)";
   return "Swing SL method: Zigzag (click to cycle; independent of entry BOS)";
}

// MA family: master ON/OFF chip + m1/m2 mode chip (like stoch/S/R rows).
string MaModeChipText(const int sel) { return (sel == MA_SINGLE) ? "m1" : "m2"; }
string MaModeChipTip(const int sel, const string tfTag)
{
   return (sel == MA_SINGLE)
      ? tfTag + " MA m1 (single line, price vs MA). Click for m2"
      : tfTag + " MA m2 (fast vs slow). Click for m1";
}

// 3-state timing chips for rsi / macd (off -> closed -> live -> off).
string RsiChipText(const bool on, const ENUM_SIG_TIMING t)
{
   if(!on) return "rsi";
   return (t == SIG_LIVE) ? "r.live" : "r.closed";
}
string MacdChipText(const bool on, const ENUM_SIG_TIMING t)
{
   if(!on) return "macd";
   return (t == SIG_LIVE) ? "m.live" : "m.closed";
}
string SigTimingTip(const string what, const bool on, const ENUM_SIG_TIMING t)
{
   if(!on) return what + " OFF. Click: closed > live > off";
   return (t == SIG_LIVE)
      ? what + " LIVE: the tick decides. Click: off"
      : what + " CLOSED: the closed candle arms it. Click: live";
}

// T2 stoch timing chip (own chip since the master is plain on/off).
string T2StochTimingText() { return (g_T2_StochTiming == SIG_LIVE) ? "live" : "closed"; }
string T2StochTimingTip()
{
   return (g_T2_StochTiming == SIG_LIVE)
      ? "T2 stoch LIVE: the tick decides. Click for closed"
      : "T2 stoch CLOSED: the closed candle arms it. Click for live";
}

string MaSLLineChipText()
{
   return (g_MaSLLine == MASL_FAST) ? "Fast" : "Slow";
}

string SrLvChipText()
{
   return SourceText(g_SrSource);
}

string SrLvTip()
{
   return "S/R level source: " + SourceText(g_SrSource) + " (own / T2)";
}

string MaDirText(const ENUM_MA_TREND_MODE mode) { return mode == MA_TREND_FOLLOW ? "follow" : "reversal"; }
// Two timings only: live (tick) / closed (candle arms it).
string MaCheckText(const ENUM_MA_CHECK mode)
{
   return (mode == MA_CHECK_RUNNING) ? "live" : "closed";
}
string BosBreakText() { return g_BosBreakMode == BOS_BREAK_CLOSE ? "closed" : "live"; }
string FibScanText(const ENUM_FIB_SCAN_MODE mode) { return mode == FIB_SCAN_LIVE ? "live" : "closed"; }
string FibScanTip(const ENUM_FIB_SCAN_MODE mode, const string tfTag)
{
   return (mode == FIB_SCAN_LIVE)
      ? tfTag + " zigzag scan: live forming bar (fibo-gun parity). Click for closed"
      : tfTag + " zigzag scan: closed bars only. Click for live forming bar";
}
string GridCountText() { return "max " + IntegerToString(g_MaxLayers); }

string MaSLLineTip()
{
   if(MaExitUsesSingleLine())
      return "MaSL line: single MA (Fast/Slow same line). Click to toggle";
   return (g_MaSLLine == MASL_FAST)
      ? "MaSL line: Fast (m2). Click for Slow"
      : "MaSL line: Slow (m2). Click for Fast";
}

void PanelCycleMaCheck(ENUM_MA_CHECK &mode, const string gvId)
{
   // Two timings only: live <-> closed
   mode = (mode == MA_CHECK_RUNNING) ? MA_CHECK_CLOSED_ONLY : MA_CHECK_RUNNING;
   PanelSaveInt(gvId, (int)mode);
}

void PanelCycleMaSLLine()
{
   g_MaSLLine = (g_MaSLLine == MASL_FAST) ? MASL_SLOW : MASL_FAST;
   PanelSaveInt("MaLn", (int)g_MaSLLine);
}

// Shared 3-way cycle for any ZigZag/Fractal/Both engine-select chip
// (entry BOS engine and swing-SL engine both use this exact triad).
ENUM_BOS_MODE CycleBosTriad(const ENUM_BOS_MODE mode)
{
   if(mode == BOS_ZIGZAG) return BOS_FRACTAL;
   if(mode == BOS_FRACTAL) return BOS_BOTH_AND;
   return BOS_ZIGZAG;
}

void PanelCycleBosMode()
{
   g_BosMode = CycleBosTriad(g_BosMode);
   PanelSaveInt("BosMode", (int)g_BosMode);
}

void PanelCycleStochCrossMode()
{
   // All three modes: pullback -> any -> OB/OS -> pullback
   if(g_StochCrossMode == STOCH_CROSS_PULLBACK)  g_StochCrossMode = STOCH_CROSS_ANY;
   else if(g_StochCrossMode == STOCH_CROSS_ANY)  g_StochCrossMode = STOCH_CROSS_OBOS;
   else                                          g_StochCrossMode = STOCH_CROSS_PULLBACK;
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

// Sources are own / T2 only — BOTH removed (S/R both needs price at two
// levels on one tick; BOS both was a rarely-useful double AND).
void PanelCycleSource(ENUM_TF_SOURCE &source, const string gvId)
{
   source = (source == TF_SOURCE_OWN) ? TF_SOURCE_T2 : TF_SOURCE_OWN;
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

   PanelStyleChip(PanelObj("L1"), " T1 entry", "T1 entry: every ON family must pass (AND)", true, true);

   PanelStyleChip(PanelObj("T1_rsi"), RsiChipText(g_T1_UseRsiBias, g_T1_RsiTiming),
                  SigTimingTip("T1 RSI", g_T1_UseRsiBias, g_T1_RsiTiming), g_T1_UseRsiBias, false);
   PanelStyleChip(PanelObj("T1_macd"), MacdChipText(g_T1_UseMacdBias, g_T1_MacdTiming),
                  SigTimingTip("T1 MACD", g_T1_UseMacdBias, g_T1_MacdTiming), g_T1_UseMacdBias, false);
   PanelStyleChip(PanelObj("T1_fib"), "fibo", "T1 entry: Fib golden zone (entry always live; chip = leg scan)", g_T1_UseFibZone, false);
   if(g_T1_UseFibZone)
      PanelStyleChip(PanelObj("T1_fibSc"), FibScanText(g_T1_FibScanMode), FibScanTip(g_T1_FibScanMode, "T1"), true, true);
   else
      PanelStyleDisabled(PanelObj("T1_fibSc"), FibScanText(g_T1_FibScanMode), "T1 fibo OFF");

   PanelStyleChip(PanelObj("T1_st"), "stoch", "T1 Stoch family ON/OFF (cross OR classic arms it, then ANDs with others)", g_StOn, false);
   if(g_StOn)
   {
      PanelStyleChip(PanelObj("T1_stX"), StXChipText(), StXChipTip(), g_StCrossSel, false);
      PanelStyleChip(PanelObj("T1_stXm"), StXModeChipText(), StXModeTip(), true, true);
      PanelStyleChip(PanelObj("T1_stC"), StCChipText(), StCChipTip(), g_StClassicSel, false);
      PanelStyleChip(PanelObj("T1_stCm"), StCModeChipText(), StCModeTip(), true, true);
   }
   else
   {
      PanelStyleDisabled(PanelObj("T1_stX"), StXChipText(), "Stoch family OFF");
      PanelStyleDisabled(PanelObj("T1_stXm"), StXModeChipText(), "Stoch family OFF");
      PanelStyleDisabled(PanelObj("T1_stC"), StCChipText(), "Stoch family OFF");
      PanelStyleDisabled(PanelObj("T1_stCm"), StCModeChipText(), "Stoch family OFF");
   }

   PanelStyleChip(PanelObj("T1_maOn"), "MA", "T1 MA family ON/OFF", g_T1_MaOn, false);
   if(g_T1_MaOn)
   {
      PanelStyleChip(PanelObj("T1_ma"), MaModeChipText(g_T1_MaSel), MaModeChipTip(g_T1_MaSel, "T1"), true, true);
      PanelStyleChip(PanelObj("T1_maDir"), MaDirText(g_T1_MaTrendMode), "T1 MA follow / reversal", true, true);
      PanelStyleChip(PanelObj("T1_maChk"), MaCheckText(g_T1_MACheckMode), "T1 MA timing: live tick / closed candle", true, true);
   }
   else
   {
      PanelStyleDisabled(PanelObj("T1_ma"), MaModeChipText(g_T1_MaSel), "MA family OFF");
      PanelStyleDisabled(PanelObj("T1_maDir"), MaDirText(g_T1_MaTrendMode), "MA family OFF");
      PanelStyleDisabled(PanelObj("T1_maChk"), MaCheckText(g_T1_MACheckMode), "MA family OFF");
   }

   PanelStyleChip(PanelObj("T1_bos"), "BOS", "T1 entry: BOS on/off — swing levels are live levels like S/R", g_T1_UseBos, false);
   if(g_T1_UseBos)
   {
      PanelStyleChip(PanelObj("T1_bosSrc"), BosSrcChipText(), BosSrcTip(), true, true);
      PanelStyleChip(PanelObj("T1_bosEng"), BosChipText(), BosTip(), true, true);
      PanelStyleChip(PanelObj("T1_bosSig"), BosSigChipText(), BosSigTip(), true, true);
      PanelStyleChip(PanelObj("T1_bosBrk"), BosBreakText(), "BOS break: live = tick at the level, closed = candle-confirmed", true, true);
   }
   else
   {
      PanelStyleDisabled(PanelObj("T1_bosSrc"), BosSrcChipText(), "BOS OFF");
      PanelStyleDisabled(PanelObj("T1_bosEng"), BosChipText(), "BOS OFF");
      PanelStyleDisabled(PanelObj("T1_bosSig"), BosSigChipText(), "BOS OFF");
      PanelStyleDisabled(PanelObj("T1_bosBrk"), BosBreakText(), "BOS OFF");
   }

   PanelStyleChip(PanelObj("T1_sr"), "S/R", "T1 S/R family ON/OFF: live pending-order trigger at the pivot level (break OR reject)", g_SrOn, false);
   if(g_SrOn)
   {
      PanelStyleChip(PanelObj("T1_srR"), "break", "S/R break: open in break direction the tick price crosses the level", g_SrBreakSel, false);
      PanelStyleChip(PanelObj("T1_srB"), "reject", "S/R reject: open reversal the tick price touches the level", g_SrRejectSel, false);
      PanelStyleChip(PanelObj("T1_srLv"), SrLvChipText(), SrLvTip(), true, true);
   }
   else
   {
      PanelStyleDisabled(PanelObj("T1_srR"), "break", "S/R family OFF");
      PanelStyleDisabled(PanelObj("T1_srB"), "reject", "S/R family OFF");
      PanelStyleDisabled(PanelObj("T1_srLv"), SrLvChipText(), "S/R family OFF");
   }

   PanelStyleChip(PanelObj("L2"), " T2 bias", "T2 bias (+T2): every ON module must pass (AND)", true, true);
   const bool t2Active = (g_ConfluenceMode == CONF_T1_AND_T2);
   if(t2Active)
   {
      PanelStyleChip(PanelObj("T2_rsi"), RsiChipText(g_T2_UseRsiBias, g_T2_RsiTiming),
                     SigTimingTip("T2 RSI", g_T2_UseRsiBias, g_T2_RsiTiming), g_T2_UseRsiBias, false);
      PanelStyleChip(PanelObj("T2_macd"), MacdChipText(g_T2_UseMacdBias, g_T2_MacdTiming),
                     SigTimingTip("T2 MACD", g_T2_UseMacdBias, g_T2_MacdTiming), g_T2_UseMacdBias, false);
      PanelStyleChip(PanelObj("T2_fib"), "fibo", "T2 bias: Fib golden zone (entry always live; chip = leg scan)", g_T2_UseFibZone, false);
      if(g_T2_UseFibZone)
         PanelStyleChip(PanelObj("T2_fibSc"), FibScanText(g_T2_FibScanMode), FibScanTip(g_T2_FibScanMode, "T2"), true, true);
      else
         PanelStyleDisabled(PanelObj("T2_fibSc"), FibScanText(g_T2_FibScanMode), "T2 fibo OFF");

      PanelStyleChip(PanelObj("T2_stoch"), "stoch", "T2 stoch bias ON/OFF", g_T2_UseStoch, false);
      if(g_T2_UseStoch)
      {
         PanelStyleChip(PanelObj("T2_stTm"), T2StochTimingText(), T2StochTimingTip(), true, true);
         PanelStyleChip(PanelObj("T2_stMd"), T2StochModeChipText(), T2StochModeTip(), true, true);
         PanelStyleChip(PanelObj("T2_stDir"), T2StochDirText(), "T2 OB/OS momentum / reversal (used when mode=OB/OS)", true, true);
      }
      else
      {
         PanelStyleDisabled(PanelObj("T2_stTm"), T2StochTimingText(), "T2 stoch OFF");
         PanelStyleDisabled(PanelObj("T2_stMd"), T2StochModeChipText(), "T2 stoch OFF");
         PanelStyleDisabled(PanelObj("T2_stDir"), T2StochDirText(), "T2 stoch OFF");
      }

      PanelStyleChip(PanelObj("T2_maOn"), "MA", "T2 MA family ON/OFF", g_T2_MaOn, false);
      if(g_T2_MaOn)
      {
         PanelStyleChip(PanelObj("T2_ma"), MaModeChipText(g_T2_MaSel), MaModeChipTip(g_T2_MaSel, "T2"), true, true);
         PanelStyleChip(PanelObj("T2_maSrc"), T2MaSrcChipText(), T2MaSrcTip(), true, true);
         if(g_T2_MaFromT1)
         {
            PanelStyleDisabled(PanelObj("T2_maDir"), MaDirText(g_T1_MaTrendMode), "Shared from T1 MA");
            PanelStyleDisabled(PanelObj("T2_maChk"), MaCheckText(g_T1_MACheckMode), "Shared from T1 MA");
         }
         else
         {
            PanelStyleChip(PanelObj("T2_maDir"), MaDirText(g_T2_MaTrendMode), "T2-own MA follow / reversal", true, true);
            PanelStyleChip(PanelObj("T2_maChk"), MaCheckText(g_T2_MACheckMode), "T2-own MA timing: live tick / closed candle", true, true);
         }
      }
      else
      {
         PanelStyleDisabled(PanelObj("T2_ma"), MaModeChipText(g_T2_MaSel), "MA family OFF");
         PanelStyleDisabled(PanelObj("T2_maSrc"), T2MaSrcChipText(), "MA family OFF");
         PanelStyleDisabled(PanelObj("T2_maDir"), MaDirText(g_T2_MaFromT1 ? g_T1_MaTrendMode : g_T2_MaTrendMode), "MA family OFF");
         PanelStyleDisabled(PanelObj("T2_maChk"), MaCheckText(g_T2_MaFromT1 ? g_T1_MACheckMode : g_T2_MACheckMode), "MA family OFF");
      }
   }
   else
   {
      string hIds[] = {"T2_rsi","T2_macd","T2_fib","T2_fibSc","T2_stoch","T2_stTm","T2_stMd","T2_stDir","T2_maOn","T2_ma","T2_maSrc","T2_maDir","T2_maChk"};
      string hTxt[13];
      hTxt[0]=RsiChipText(g_T2_UseRsiBias, g_T2_RsiTiming);
      hTxt[1]=MacdChipText(g_T2_UseMacdBias, g_T2_MacdTiming);
      hTxt[2]="fibo"; hTxt[3]=FibScanText(g_T2_FibScanMode);
      hTxt[4]="stoch"; hTxt[5]=T2StochTimingText(); hTxt[6]=T2StochModeChipText(); hTxt[7]=T2StochDirText();
      hTxt[8]="MA"; hTxt[9]=MaModeChipText(g_T2_MaSel); hTxt[10]=T2MaSrcChipText();
      hTxt[11]=MaDirText(g_T2_MaFromT1 ? g_T1_MaTrendMode : g_T2_MaTrendMode);
      hTxt[12]=MaCheckText(g_T2_MaFromT1 ? g_T1_MACheckMode : g_T2_MACheckMode);
      for(int i=0; i<ArraySize(hIds); i++) PanelStyleDisabled(PanelObj(hIds[i]), hTxt[i], "T2 bias locked while mode=T1");
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
   if(g_UseVirtualMaSL)
      PanelStyleChip(PanelObj("MaLn"), MaSLLineChipText(), MaSLLineTip(), true, true);
   else
      PanelStyleDisabled(PanelObj("MaLn"), MaSLLineChipText(), "MaSL OFF");
   PanelStyleChip(PanelObj("SwSL"), "SwSL", "Virtual swing stop ON/OFF", g_UseSwingVirtualSL, false);
   if(g_UseSwingVirtualSL)
      PanelStyleChip(PanelObj("SwMd"), SwMdChipText(), SwMdTip(), true, true);
   else
      PanelStyleDisabled(PanelObj("SwMd"), SwMdChipText(), "SwSL OFF");
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

   const int chipW      = 60; // fits 8 chars of Consolas 8 — full words, no clipping
   const int chipH      = 19;
   const int gap        = 3;
   const int sectionGap = 2;  // extra air between panel sections
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
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("L1", x0, y, rowW, chipH); y += chipH + gap;
   string t1osc[] = { "T1_rsi", "T1_macd", "T1_fib", "T1_fibSc" };
   PanelPlaceEvenRow(t1osc, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1st[] = { "T1_st", "T1_stX", "T1_stXm", "T1_stC", "T1_stCm" };
   PanelPlaceEvenRow(t1st, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1ma[] = { "T1_maOn", "T1_ma", "T1_maDir", "T1_maChk" };
   PanelPlaceEvenRow(t1ma, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1bos[] = { "T1_bos", "T1_bosSrc", "T1_bosEng", "T1_bosSig", "T1_bosBrk" };
   PanelPlaceEvenRow(t1bos, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1sr[] = { "T1_sr", "T1_srR", "T1_srB", "T1_srLv" };
   PanelPlaceEvenRow(t1sr, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("L2", x0, y, rowW, chipH); y += chipH + gap;
   string t2osc[] = { "T2_rsi", "T2_macd", "T2_fib", "T2_fibSc" };
   PanelPlaceEvenRow(t2osc, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t2st[] = { "T2_stoch", "T2_stTm", "T2_stMd", "T2_stDir" };
   PanelPlaceEvenRow(t2st, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t2ma[] = { "T2_maOn", "T2_ma", "T2_maSrc", "T2_maDir", "T2_maChk" };
   PanelPlaceEvenRow(t2ma, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("LG", x0, y, rowW, chipH); y += chipH + gap;
   string guards[] = { "Session", "Weekend", "News", "Broker", "GuardSt" };
   PanelPlaceEvenRow(guards, 5, x0, y, rowW, gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("LR", x0, y, rowW, chipH); y += chipH + gap;
   string risk[] = { "MaSL", "MaLn", "SwSL", "SwMd", "Trail" };
   PanelPlaceEvenRow(risk, 5, x0, y, rowW, gap, chipH);

   string liveIds[] = {
      "TTL","CONF","GRID","GRIDN","BUY","SELL","L1",
      "T1_rsi","T1_macd","T1_fib","T1_fibSc",
      "T1_st","T1_stX","T1_stXm","T1_stC","T1_stCm",
      "T1_maOn","T1_ma","T1_maDir","T1_maChk",
      "T1_bos","T1_bosSrc","T1_bosEng","T1_bosSig","T1_bosBrk",
      "T1_sr","T1_srR","T1_srB","T1_srLv","L2",
      "T2_rsi","T2_macd","T2_fib","T2_fibSc",
      "T2_stoch","T2_stTm","T2_stMd","T2_stDir",
      "T2_maOn","T2_ma","T2_maSrc","T2_maDir","T2_maChk","LG",
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

   // T2 controls are deliberately locked while confluence is T1-only.
   if(g_ConfluenceMode == CONF_T1_ONLY && StringFind(id, "T2_") == 0)
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
      g_ConfluenceMode = (g_ConfluenceMode == CONF_T1_ONLY) ? CONF_T1_AND_T2 : CONF_T1_ONLY;
      PanelSaveInt("Conf", (int)g_ConfluenceMode);
   }
   else if(id == "GRID") PanelToggleBool(g_UseGrid, "Grid");
   else if(id == "GRIDN") PanelCycleGridCount();
   else if(id == "T1_fibSc")
   {
      if(!g_T1_UseFibZone) return true; // scan chip locked while fibo OFF
      g_T1_FibScanMode = (g_T1_FibScanMode == FIB_SCAN_CLOSED) ? FIB_SCAN_LIVE : FIB_SCAN_CLOSED;
      PanelSaveInt("T1_FibScan", (int)g_T1_FibScanMode);
   }
   else if(id == "T2_fibSc")
   {
      if(!g_T2_UseFibZone) return true; // scan chip locked while fibo OFF
      g_T2_FibScanMode = (g_T2_FibScanMode == FIB_SCAN_CLOSED) ? FIB_SCAN_LIVE : FIB_SCAN_CLOSED;
      PanelSaveInt("T2_FibScan", (int)g_T2_FibScanMode);
   }
   else if(id == "SwMd")
   {
      if(!g_UseSwingVirtualSL) return true; // method locked while SwSL OFF
      g_SwingSLMode = CycleBosTriad(g_SwingSLMode);
      PanelSaveInt("SwMode", (int)g_SwingSLMode);
      g_haveSwingSL = false;
      g_swingSL = 0;
   }
   else if(id == "BUY")  PanelToggleBool(g_TradeBuy, "Buy");
   else if(id == "SELL") PanelToggleBool(g_TradeSell, "Sell");
   else if(id == "T1_st")
   {
      g_StOn = !g_StOn;
      PanelSaveBool("T1_stOn", g_StOn);
      ApplyFamilyMasters();
   }
   else if(id == "T1_stX")
   {
      if(!g_StOn) return true; // family locked while master OFF
      // off -> x.closed -> x.live -> off
      if(!g_StCrossSel)
      { g_StCrossSel = true; g_StochCrossTiming = SIG_CLOSED; }
      else if(g_StochCrossTiming == SIG_CLOSED)
         g_StochCrossTiming = SIG_LIVE;
      else
      { g_StCrossSel = false; g_StochCrossTiming = SIG_CLOSED; }
      PanelSaveBool("T1_stX", g_StCrossSel);
      PanelSaveInt("T1_stXt", (int)g_StochCrossTiming);
      ApplyFamilyMasters();
   }
   else if(id == "T1_stXm")
   {
      if(!g_StOn) return true;
      PanelCycleStochCrossMode();
   }
   else if(id == "T1_stC")
   {
      if(!g_StOn) return true;
      // off -> c.closed -> c.live -> off
      if(!g_StClassicSel)
      { g_StClassicSel = true; g_StochClassicTiming = SIG_CLOSED; }
      else if(g_StochClassicTiming == SIG_CLOSED)
         g_StochClassicTiming = SIG_LIVE;
      else
      { g_StClassicSel = false; g_StochClassicTiming = SIG_CLOSED; }
      PanelSaveBool("T1_stC", g_StClassicSel);
      PanelSaveInt("T1_stCt", (int)g_StochClassicTiming);
      ApplyFamilyMasters();
   }
   else if(id == "T1_stCm")
   {
      if(!g_StOn) return true;
      PanelCycleStochClassicMode();
   }
   else if(id == "T1_sr")
   {
      g_SrOn = !g_SrOn;
      PanelSaveBool("T1_srOn", g_SrOn);
      ApplyFamilyMasters();
   }
   else if(id == "T1_srR")
   {
      if(!g_SrOn) return true;
      g_SrBreakSel = !g_SrBreakSel;
      PanelSaveBool("T1_srR", g_SrBreakSel);
      ApplyFamilyMasters();
   }
   else if(id == "T1_srB")
   {
      if(!g_SrOn) return true;
      g_SrRejectSel = !g_SrRejectSel;
      PanelSaveBool("T1_srB", g_SrRejectSel);
      ApplyFamilyMasters();
   }
   else if(id == "T1_fib") PanelToggleBool(g_T1_UseFibZone, "T1_fib");
   else if(id == "T1_macd")
   {
      // off -> m.closed -> m.live -> off
      if(!g_T1_UseMacdBias)
      { g_T1_UseMacdBias = true; g_T1_MacdTiming = SIG_CLOSED; }
      else if(g_T1_MacdTiming == SIG_CLOSED)
         g_T1_MacdTiming = SIG_LIVE;
      else
      { g_T1_UseMacdBias = false; g_T1_MacdTiming = SIG_LIVE; }
      PanelSaveBool("T1_macd", g_T1_UseMacdBias);
      PanelSaveInt("T1_macdT", (int)g_T1_MacdTiming);
   }
   else if(id == "T1_rsi")
   {
      // off -> r.closed -> r.live -> off
      if(!g_T1_UseRsiBias)
      { g_T1_UseRsiBias = true; g_T1_RsiTiming = SIG_CLOSED; }
      else if(g_T1_RsiTiming == SIG_CLOSED)
         g_T1_RsiTiming = SIG_LIVE;
      else
      { g_T1_UseRsiBias = false; g_T1_RsiTiming = SIG_LIVE; }
      PanelSaveBool("T1_rsi", g_T1_UseRsiBias);
      PanelSaveInt("T1_rsiT", (int)g_T1_RsiTiming);
   }
   else if(id == "T1_maOn")
   {
      g_T1_MaOn = !g_T1_MaOn;
      PanelSaveBool("T1_maOn", g_T1_MaOn);
      ApplyFamilyMasters();
   }
   else if(id == "T1_ma")
   {
      if(!g_T1_MaOn) return true; // family locked while master OFF
      g_T1_MaSel = (g_T1_MaSel == MA_SINGLE) ? MA_DOUBLE : MA_SINGLE;
      PanelSaveInt("T1_ma", g_T1_MaSel);
      ApplyFamilyMasters();
   }
   else if(id == "T1_maDir")
   {
      if(!g_T1_MaOn) return true;
      g_T1_MaTrendMode = (g_T1_MaTrendMode == MA_TREND_FOLLOW) ? MA_TREND_REVERSAL : MA_TREND_FOLLOW;
      PanelSaveInt("T1_MaDir", (int)g_T1_MaTrendMode);
   }
   else if(id == "T1_maChk")
   {
      if(!g_T1_MaOn) return true;
      PanelCycleMaCheck(g_T1_MACheckMode, "T1_MaChk");
   }
   else if(id == "T1_bos") PanelToggleBool(g_T1_UseBos, "T1_bos");
   else if(id == "T1_bosSrc" || id == "T1_bosEng" || id == "T1_bosSig" || id == "T1_bosBrk")
   {
      if(!g_T1_UseBos) return true; // row locked while BOS OFF
      if(id == "T1_bosSrc") PanelCycleSource(g_BosSource, "BosSrc");
      else if(id == "T1_bosEng") PanelCycleBosMode();
      else if(id == "T1_bosSig") PanelCycleBosSignalMode();
      else
      {
         g_BosBreakMode = (g_BosBreakMode == BOS_BREAK_WICK) ? BOS_BREAK_CLOSE : BOS_BREAK_WICK;
         PanelSaveInt("BosBrk", (int)g_BosBreakMode);
      }
   }
   else if(id == "T1_srLv")
   {
      if(!g_SrOn) return true;
      PanelCycleSource(g_SrSource, "SrLv");
   }
   else if(id == "T2_stoch") PanelToggleBool(g_T2_UseStoch, "T2_stoch");
   else if(id == "T2_stTm")
   {
      if(!g_T2_UseStoch) return true;
      g_T2_StochTiming = (g_T2_StochTiming == SIG_CLOSED) ? SIG_LIVE : SIG_CLOSED;
      PanelSaveInt("T2_stT", (int)g_T2_StochTiming);
   }
   else if(id == "T2_stMd")
   {
      if(!g_T2_UseStoch) return true;
      PanelToggleBool(g_T2_StochObOs, "T2_stOb");
   }
   else if(id == "T2_stDir")
   {
      if(!g_T2_UseStoch) return true;
      g_T2_StochObOsMode = (g_T2_StochObOsMode == STOCH_CLASSIC_MOM) ? STOCH_CLASSIC_REV : STOCH_CLASSIC_MOM;
      PanelSaveInt("T2_stDir", (int)g_T2_StochObOsMode);
   }
   else if(id == "T2_fib") PanelToggleBool(g_T2_UseFibZone, "T2_fib");
   else if(id == "T2_macd")
   {
      if(!g_T2_UseMacdBias)
      { g_T2_UseMacdBias = true; g_T2_MacdTiming = SIG_CLOSED; }
      else if(g_T2_MacdTiming == SIG_CLOSED)
         g_T2_MacdTiming = SIG_LIVE;
      else
      { g_T2_UseMacdBias = false; g_T2_MacdTiming = SIG_LIVE; }
      PanelSaveBool("T2_macd", g_T2_UseMacdBias);
      PanelSaveInt("T2_macdT", (int)g_T2_MacdTiming);
   }
   else if(id == "T2_rsi")
   {
      if(!g_T2_UseRsiBias)
      { g_T2_UseRsiBias = true; g_T2_RsiTiming = SIG_CLOSED; }
      else if(g_T2_RsiTiming == SIG_CLOSED)
         g_T2_RsiTiming = SIG_LIVE;
      else
      { g_T2_UseRsiBias = false; g_T2_RsiTiming = SIG_LIVE; }
      PanelSaveBool("T2_rsi", g_T2_UseRsiBias);
      PanelSaveInt("T2_rsiT", (int)g_T2_RsiTiming);
   }
   else if(id == "T2_maOn")
   {
      g_T2_MaOn = !g_T2_MaOn;
      PanelSaveBool("T2_maOn", g_T2_MaOn);
      ApplyFamilyMasters();
   }
   else if(id == "T2_ma")
   {
      if(!g_T2_MaOn) return true;
      g_T2_MaSel = (g_T2_MaSel == MA_SINGLE) ? MA_DOUBLE : MA_SINGLE;
      PanelSaveInt("T2_ma", g_T2_MaSel);
      ApplyFamilyMasters();
   }
   else if(id == "T2_maSrc")
   {
      if(!g_T2_MaOn) return true;
      PanelToggleBool(g_T2_MaFromT1, "T2_maT1");
   }
   else if(id == "T2_maDir")
   {
      if(!g_T2_MaOn || g_T2_MaFromT1) return true;
      g_T2_MaTrendMode = (g_T2_MaTrendMode == MA_TREND_FOLLOW) ? MA_TREND_REVERSAL : MA_TREND_FOLLOW;
      PanelSaveInt("T2_MaDir", (int)g_T2_MaTrendMode);
   }
   else if(id == "T2_maChk")
   {
      if(!g_T2_MaOn || g_T2_MaFromT1) return true;
      PanelCycleMaCheck(g_T2_MACheckMode, "T2_MaChk");
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
   else if(id == "MaLn")
   {
      if(!g_UseVirtualMaSL) return true; // line locked while MaSL OFF
      PanelCycleMaSLLine();
   }
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

   g_t1 = (InpT1 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpT1;
   g_t2 = (InpT2 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpT2;

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
   const bool needT1Ma = prepAll || MaEnabled(g_T1_MA) || g_UseVirtualMaSL
                       || (MaEnabled(g_T2_MA) && g_T2_MaFromT1);
   if(!CreateTfHandles(g_t1,
                       prepAll || g_T1_UseStochCross, prepAll || g_T1_UseStochClassic,
                       prepAll || g_T1_UseMacdBias, prepAll || g_T1_UseRsiBias,
                       needT1Ma,
                       prepAll || g_T1_UseFibZone || (g_UseSwingVirtualSL && g_SwingSLMode != BOS_FRACTAL),
                       prepAll || (g_T1_UseBos && g_BosSource != TF_SOURCE_T2) || g_UseSwingVirtualSL,
                       StochKPeriod, StochDPeriod, StochSlowing, StochMAMethod, StochPriceField,
                       MaPeriod, MaFastPeriod, MaSlowPeriod,
                       MaShift, MaMethod, MaAppliedPrice,
                       g_stochT1, g_rsiT1, g_macdT1, g_maT1, g_maFT1, g_maST1, g_atrT1, "T1"))
      return(INIT_FAILED);

   // T2 handles: T2 bias, and/or BOS-from-T2 ATR (fib OR zigzag/both).
   const bool needT2 = prepAll || g_ConfluenceMode == CONF_T1_AND_T2 || g_BosSource != TF_SOURCE_OWN;
   if(needT2)
   {
      if(!CreateTfHandles(g_t2,
                          prepAll || g_T2_UseStoch, false,
                          prepAll || g_T2_UseMacdBias, prepAll || g_T2_UseRsiBias,
                          prepAll || MaEnabled(g_T2_MA),
                          prepAll || g_T2_UseFibZone,
                          prepAll || (g_T1_UseBos && g_BosSource != TF_SOURCE_OWN),
                          StochKPeriod, StochDPeriod, StochSlowing,
                          StochMAMethod, StochPriceField,
                          T2_MaPeriod, T2_MaFastPeriod, T2_MaSlowPeriod,
                          T2_MaShift, T2_MaMethod, T2_MaAppliedPrice,
                          g_stochT2, g_rsiT2, g_macdT2, g_maT2, g_maFT2, g_maST2, g_atrT2, "T2"))
         return(INIT_FAILED);
      if(PeriodSeconds(g_t2) == PeriodSeconds(g_t1) && !g_quietInit)
         LogInfo("NOTE T1 and T2 are the same period — T2 bias / SrLv T2 add no extra TF.");
   }

   if(!g_quietInit && g_SrSource != TF_SOURCE_OWN && PeriodSeconds(g_t2) <= PeriodSeconds(g_t1))
      LogInfo("NOTE SrLv=T2 but T2 is not higher than T1 — levels TF is not T2.");
   if(!g_quietInit && g_BosSource != TF_SOURCE_OWN && PeriodSeconds(g_t2) <= PeriodSeconds(g_t1))
      LogInfo("NOTE BosSrc=T2 but T2 is not higher than T1 — BOS TF is not T2.");

   g_pip = PipSize();
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(!g_quietInit)
   {
      string mode = (g_ConfluenceMode == CONF_T1_ONLY) ? "ENTRY_ONLY" : "ENTRY+BIAS";
      LogInfo("INIT " + mode
              + " T1=" + EnumToString(g_t1)
              + " T2=" + EnumToString(g_t2)
              + " BosMode=" + EnumToString(g_BosMode)
              + " BosSig=" + EnumToString(g_BosSignalMode)
              + " BosSrc=" + SourceText(g_BosSource)
              + " SwMode=" + EnumToString(g_SwingSLMode)
              + " FibScan=" + FibScanText(g_T1_FibScanMode) + "/" + FibScanText(g_T2_FibScanMode)
              + " | Buy=" + (g_TradeBuy ? "ON" : "OFF")
              + " Sell=" + (g_TradeSell ? "ON" : "OFF")
              + " Grid=" + (g_UseGrid ? ("ON/" + IntegerToString(EffectiveMaxLayers())) : "OFF/1")
              + " | MaSL=" + (g_UseVirtualMaSL ? "ON" : "OFF")
              + (g_UseVirtualMaSL ? ("/" + ((g_MaSLLine == MASL_FAST) ? "Fast" : "Slow")) : "")
              + " SwSL=" + (g_UseSwingVirtualSL ? "ON" : "OFF")
              + " Trail=" + (g_UseBasketTP ? "ON" : "OFF")
              + " | T2MA=" + IntegerToString(T2_MaPeriod)
              + "/" + IntegerToString(T2_MaFastPeriod)
              + "/" + IntegerToString(T2_MaSlowPeriod)
              + (g_T2_MaFromT1 ? " src=T1(shared)" : " src=own")
              + " | panel=" + (ShowPanel ? ("ON inset " + IntegerToString(PanelInsetX) + "," + IntegerToString(PanelInsetY)) : "off"));
      if(_Period != g_t1)
         LogInfo("NOTE chart TF differs from T1 (" + EnumToString(g_t1)
                 + "). Signal clock runs on T1.");
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

   ReleaseHandle(g_stochT1); ReleaseHandle(g_rsiT1); ReleaseHandle(g_macdT1);
   ReleaseHandle(g_maT1);    ReleaseHandle(g_maFT1); ReleaseHandle(g_maST1); ReleaseHandle(g_atrT1);
   ReleaseHandle(g_stochT2); ReleaseHandle(g_rsiT2); ReleaseHandle(g_macdT2);
   ReleaseHandle(g_maT2);    ReleaseHandle(g_maFT2); ReleaseHandle(g_maST2); ReleaseHandle(g_atrT2);
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

   // g_lastBarTime = the per-candle latch clock (one first-layer entry per
   // T1 candle, DiagBlock once per candle). The signal engine itself runs
   // on EVERY tick below — no waiting for candle boundaries to decide.
   datetime bt[];
   if(CopyTime(_Symbol, g_t1, 0, 1, bt) == 1 && bt[0] != g_lastBarTime)
      g_lastBarTime = bt[0];

   UpdateSignal();

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

// S/R = live pending-order trigger at the pivot level, checked every tick.
// break : open in the break direction the tick price crosses the level by
//         SrBufferPips (buy stop above resistance / sell stop below support).
// reject: open the reversal the tick price comes within SrBufferPips of the
//         level (sell limit at resistance / buy limit at support).
// OR family: either ON mode fires it. No candle-close wait, no retest.
bool LiveSrTrigger(const bool wantBuy)
{
   if(!g_T1_UseSrBounce && !g_T1_UseSrBreak) return true; // module off = pass

   const ENUM_TIMEFRAMES levelsTf = (g_SrSource == TF_SOURCE_T2) ? g_t2 : g_t1;
   double support = 0, resistance = 0;
   if(!GetActiveSR(levelsTf, support, resistance)) return false;
   if(support <= 0 || resistance <= 0 || support >= resistance) return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buf = MathMax(0.0, SrBufferPips) * g_pip;

   bool brk = g_T1_UseSrBreak &&
              (wantBuy ? (ask >= resistance + buf) : (bid <= support - buf));
   bool rej = g_T1_UseSrBounce &&
              (wantBuy ? (bid <= support + buf) : (ask >= resistance - buf));
   return brk || rej;
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

   // [0]=live forming candle, [1]=last closed, [2]=one before.
   // The signal engine runs per tick, so each timing reads its own bars:
   //   x.live   — %K crossed %D within the CURRENT candle ([1]->[0]).
   //   x.closed — cross between the last two CLOSED candles ([2]->[1]);
   //              a frozen fact, stays true the whole next candle.
   //   c.live   — live %K inside the zone right now.
   //   c.closed — last closed candle's %K inside the zone.
   bool crossBuy = false, crossSell = false;
   if(useCross)
   {
      const int a = (g_StochCrossTiming == SIG_LIVE) ? 1 : 2; // bar before the cross
      const int b = (g_StochCrossTiming == SIG_LIVE) ? 0 : 1; // bar of the cross
      bool crossedUp   = (k[a] <= d[a]) && (k[b] > d[b]);
      bool crossedDown = (k[a] >= d[a]) && (k[b] < d[b]);
      bool lvlBuy  = (g_StochCrossMode == STOCH_CROSS_ANY)  ? true
                   : (g_StochCrossMode == STOCH_CROSS_OBOS) ? (k[a] < StochOversoldLevel)
                   :                                          (k[b] < StochMidLevel);
      bool lvlSell = (g_StochCrossMode == STOCH_CROSS_ANY)  ? true
                   : (g_StochCrossMode == STOCH_CROSS_OBOS) ? (k[a] > StochOverboughtLevel)
                   :                                          (k[b] > StochMidLevel);
      crossBuy  = crossedUp   && lvlBuy;
      crossSell = crossedDown && lvlSell;
   }

   bool classicBuy = false, classicSell = false;
   if(useClassic)
   {
      const int s = (g_StochClassicTiming == SIG_LIVE) ? 0 : 1;
      bool inOS = (k[s] < StochOversoldLevel);
      bool inOB = (k[s] > StochOverboughtLevel);
      if(g_StochClassicMode == STOCH_CLASSIC_MOM)
      { classicBuy = inOB;  classicSell = inOS; } // mom: ride the extreme
      else
      { classicBuy = inOS;  classicSell = inOB; } // rev: fade the extreme
   }

   buyOK  = crossBuy  || classicBuy;
   sellOK = crossSell || classicSell;
   return true;
}

// T2 stoch zone: mid (%K vs StochMidLevel) or OB/OS (buy OS / sell OB).
// shift 0 = live %K (SIG_LIVE), shift 1 = last closed candle (SIG_CLOSED).
bool EvalStochZone(const int hStoch, const bool useIt, const bool obOs,
                   const ENUM_STOCH_CLASSIC_MODE obOsMode,
                   const double midLevel, const double oversoldLevel,
                   const double overboughtLevel,
                   const int shift, bool &buyOK, bool &sellOK)
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
         buyOK  = (k[shift] > overboughtLevel);
         sellOK = (k[shift] < oversoldLevel);
      }
      else
      {
         buyOK  = (k[shift] < oversoldLevel);
         sellOK = (k[shift] > overboughtLevel);
      }
   }
   else
   {
      buyOK  = (k[shift] > midLevel);
      sellOK = (k[shift] < midLevel);
   }
   return true;
}

// shift 1 = closed bar (arming); shift 0 = live value (post-arm tick gate).
bool EvalMacd(const int hMacd, const bool useIt, const int shift, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!useIt) return true;
   if(hMacd == INVALID_HANDLE)
   { LogDebugGuard("dbg_macd", "EvalMacd: invalid handle"); return false; }

   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(hMacd, 0, 0, 2, m) != 2)
   { LogDebugGuard("dbg_macd", "EvalMacd: buffer not ready"); return false; }
   buyOK  = (m[shift] > 0);
   sellOK = (m[shift] < 0);
   return true;
}

// shift 1 = closed bar (arming); shift 0 = live value (post-arm tick gate).
bool EvalRsi(const int hRsi, const bool useIt, const int shift, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!useIt) return true;
   if(hRsi == INVALID_HANDLE)
   { LogDebugGuard("dbg_rsi", "EvalRsi: invalid handle"); return false; }

   double r[];
   ArraySetAsSeries(r, true);
   if(CopyBuffer(hRsi, 0, 0, 2, r) != 2)
   { LogDebugGuard("dbg_rsi", "EvalRsi: buffer not ready"); return false; }
   buyOK  = (r[shift] > RSIMidLevel);
   sellOK = (r[shift] < RSIMidLevel);
   return true;
}

// Per-TF timing -> series index for rsi/macd: live = 0, closed = 1.
int RsiShiftFor(const ENUM_TIMEFRAMES tf)
{ return (((tf == g_t1) ? g_T1_RsiTiming : g_T2_RsiTiming) == SIG_LIVE) ? 0 : 1; }
int MacdShiftFor(const ENUM_TIMEFRAMES tf)
{ return (((tf == g_t1) ? g_T1_MacdTiming : g_T2_MacdTiming) == SIG_LIVE) ? 0 : 1; }

// m1 side check. RUNNING (live) = live price vs live MA, right now.
// CLOSED_ONLY = last closed candle vs its MA — the closed candle arms it.
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

   if(checkMode == MA_CHECK_RUNNING)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return wantBuy ? (ask > m[0] + buffer) : (bid < m[0] - buffer);
   }

   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(_Symbol, tf, 1, 1, c) != 1)
   { LogDebugGuard("dbg_malive", "PassesMALive: last closed candle not ready"); return false; }
   if(wantBuy) return (c[0] > m[1] + buffer);
   return (c[0] < m[1] - buffer);
}

// One MA module: m1 (single line) / m2 (fast vs slow).
// Timing per TF: RUNNING = live values, CLOSED_ONLY = closed candle arms it.
bool EvalMA(const ENUM_TIMEFRAMES tf,
            const int hSingle, const int hFast, const int hSlow,
            const int state, const ENUM_MA_TREND_MODE trendMode,
            const ENUM_MA_CHECK checkMode, const double bufferPips,
            const double minDiffPips, bool &buyOK, bool &sellOK)
{
   buyOK = true; sellOK = true;
   if(!MaEnabled(state)) return true;

   // m1: single-line filter (live / closed via PassesMALive)
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

   // m2: fast vs slow — live values (RUNNING) or last closed candle (CLOSED).
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
   const int mi = (checkMode == MA_CHECK_RUNNING) ? 0 : 1;
   double diff = f[mi] - s[mi];
   int dir = 0;
   if(diff >  thr) dir = 1;
   if(diff < -thr) dir = -1;
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

// Per-TF scan mode: T1 and T2 each have their own FibScanMode (input + chip).
// CLOSED = closed bars only (fractal / S/R discipline); LIVE = forming bar
// included (fibo-gun/bomb parity). When InpT1 == InpT2, T1's mode wins.
ENUM_FIB_SCAN_MODE FibScanModeFor(const ENUM_TIMEFRAMES tf)
{
   return (tf == g_t1) ? g_T1_FibScanMode : g_T2_FibScanMode;
}

// Scan zigzag leg on tf. Returns false only on data failure.
// Scan window follows FibScanModeFor(tf) — see above.
// bosEventOnLastClosed = current BOS leg's newer pivot confirmed on last closed bar.
bool ScanFibLeg(const ENUM_TIMEFRAMES tf, const int hAtr,
                bool &haveLeg, bool &bullishLeg,
                double &olderPrice, double &newerPrice,
                bool &bosConfirmed, bool &bosEventOnLastClosed)
{
   haveLeg = false; bullishLeg = false;
   olderPrice = 0; newerPrice = 0; bosConfirmed = false;
   bosEventOnLastClosed = false;
   g_zzHavePrevSwing = false; g_zzPrevSwing = 0;
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

   // Non-series: [0]=oldest, [bars-1]=forming.
   // FIB_SCAN_CLOSED: pivots confirmed on closed bars only.
   // FIB_SCAN_LIVE: forming bar joins the scan — leg matches fibo-gun/bomb
   // and the fibo/fibo-in indicators exactly (can re-anchor intra-bar).
   // BOS EVENT stays anchored to the last CLOSED bar in both modes.
   const int lastClosed = bars - 2;
   const int scanEnd = (FibScanModeFor(tf) == FIB_SCAN_LIVE) ? bars - 1 : lastClosed;
   int newerConfirmBar = -1;
   double trackedNewer = 0;
   bool   haveTrackedNewer = false;

   for(int i = 2 * prd; i <= scanEnd; i++)
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

   // expose the structure reference for live zigzag BOS (see globals)
   g_zzHavePrevSwing = havePrevSwing;
   g_zzPrevSwing     = prevSwing;

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

// Fib golden zone from current zigzag leg. Evaluated per tick: the leg
// direction picks the side and LIVE price must be inside the zone right
// now — entry is always instant, the closed/live chip only governs how
// the LEG is built (ScanFibLeg scan mode).
bool EvalFibZone(const ENUM_TIMEFRAMES tf, const int hAtr, const bool useIt,
                 bool &buyOK, bool &sellOK)
{
   buyOK = false; sellOK = false;
   if(!useIt) { buyOK = true; sellOK = true; return true; }

   bool haveLeg = false, bullish = false, bos = false, bosEvt = false;
   double olderP = 0, newerP = 0;
   if(!ScanFibLeg(tf, hAtr, haveLeg, bullish, olderP, newerP, bos, bosEvt)) return false;
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

// Fractal structure: swing levels found on closed bars; break detection is
// live (wick mode) or closed-candle (close mode) against those levels.
// buyOK/sellOK = entry signal (EVENT = at the break; BIAS = while trend holds).
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
   double brokenHighLvl = 0, brokenLowLvl = 0; // level price each break went through

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
         brokenHighLvl = highPrice;
      }
      else if(lowValid && !lowBroken && breakLowPrice < lowPrice)
      {
         lowBroken = true;
         trend = -1;
         highValid = false;
         lastBreakBar = i;
         lastBreakDir = -1;
         brokenLowLvl = lowPrice;
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

   // The swing levels are LEVELS, like S/R. wick mode = the tick price
   // crosses the level IS the break (live, right now). close mode = the
   // candle must finish beyond the level (the closed candle arms it).
   int    liveBreakDir = 0;
   double liveBreakLvl = 0;
   if(g_BosBreakMode == BOS_BREAK_WICK)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(highValid && !highBroken && ask > highPrice)
      { liveBreakDir = 1;  liveBreakLvl = highPrice; }
      else if(lowValid && !lowBroken && bid < lowPrice)
      { liveBreakDir = -1; liveBreakLvl = lowPrice; }
   }

   // Track which level the last replay break went through (event latch id).
   double lastBreakLevel = 0;
   if(lastBreakDir > 0) lastBreakLevel = brokenHighLvl;
   if(lastBreakDir < 0) lastBreakLevel = brokenLowLvl;

   if(g_BosSignalMode == BOS_SIGNAL_EVENT)
   {
      // EVENT = permission at the break itself. Valid while the break candle
      // is the latest closed one (close mode) or while live price holds
      // beyond the level (wick mode). Only an actual ENTRY consumes a break
      // (level latch g_bosDoneLvl*) — evaluation alone never eats it.
      if(lastBreakBar == lastClosed && lastBreakDir != 0)
      {
         if(lastBreakDir > 0 && lastBreakLevel != g_bosDoneLvlBuy)
         { buyOK = true;  g_bosEvtLvlBuy = lastBreakLevel; }
         if(lastBreakDir < 0 && lastBreakLevel != g_bosDoneLvlSell)
         { sellOK = true; g_bosEvtLvlSell = lastBreakLevel; }
      }
      if(liveBreakDir > 0 && liveBreakLvl != g_bosDoneLvlBuy)
      { buyOK = true;  g_bosEvtLvlBuy = liveBreakLvl; }
      if(liveBreakDir < 0 && liveBreakLvl != g_bosDoneLvlSell)
      { sellOK = true; g_bosEvtLvlSell = liveBreakLvl; }
   }
   else
   {
      // Sticky bias — while structure remains bullish/bearish. A live wick
      // break flips the bias the tick it happens.
      int biasTrend = (liveBreakDir != 0) ? liveBreakDir : trend;
      if(biasTrend > 0) buyOK = true;
      if(biasTrend < 0) sellOK = true;
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
   if(!haveLeg) return true;

   // The previous same-side swing is a LEVEL. wick mode: live price crossing
   // it IS the break, that tick — no waiting for the pivot to confirm.
   // close mode: only the pivot-confirmed break counts (closed structure).
   bool   liveBos = false;
   double refLvl  = g_zzPrevSwing;
   if(g_BosBreakMode == BOS_BREAK_WICK && g_zzHavePrevSwing && !bos)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      liveBos = bullish ? (ask > refLvl) : (bid < refLvl);
   }
   if(!bos && !liveBos) return true;

   if(g_BosSignalMode == BOS_SIGNAL_EVENT)
   {
      // Entry-consumed level latch (same rule as fractal): the exact broken
      // level fires one basket, ever. Evaluation never eats the event.
      bool fresh = bos ? bosEvt : liveBos;
      if(!fresh) return true;
      if(bullish  && refLvl != g_bosDoneLvlBuy)
      { buyOK = true;  g_bosEvtLvlBuy = refLvl; }
      if(!bullish && refLvl != g_bosDoneLvlSell)
      { sellOK = true; g_bosEvtLvlSell = refLvl; }
      return true;
   }

   // BIAS — sticky while zigzag BOS leg holds (live break flips it now).
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

bool EvalBosBySource(bool &buyOK, bool &sellOK)
{
   if(g_BosSource == TF_SOURCE_T2)
      return EvalBos(g_t2, g_atrT2, true, buyOK, sellOK);
   return EvalBos(g_t1, g_atrT1, true, buyOK, sellOK);
}

// Evaluate one TF: every enabled module family must pass (all AND).
// T1 Stoch: cross OR classic. T2 Stoch: zone (mid/obos) via useStochZone.
// S/R is NOT here — live pending-order trigger in TryEnter (LiveSrTrigger).
// If nothing enabled: outBuy/outSell stay false (caller may treat empty T2 as pass).
// FibZone: leg direction + live price in zone, per tick (see EvalFibZone).
// maTf + MA handles: T2 bias may evaluate MA on T1 when g_T2_MaFromT1.
bool EvalTf(const ENUM_TIMEFRAMES tf,
            const bool useCross, const bool useClassic,
            const bool useStochZone, const bool stochObOs,
            const ENUM_STOCH_CLASSIC_MODE stochZoneMode,
            const double stochMid, const double stochOS, const double stochOB,
            const bool useFib,
            const bool useMacd, const bool useRsi, const int maState, const bool useBos,
            const int hStoch, const int hRsi, const int hMacd,
            const ENUM_TIMEFRAMES maTf,
            const int hMaSingle, const int hMaFast, const int hMaSlow,
            const ENUM_MA_TREND_MODE maTrendMode, const ENUM_MA_CHECK maCheckMode,
            const double maBufferPips, const double maMinDiffPips,
            const int hAtr,
            bool &outBuy, bool &outSell)
{
   outBuy = false; outSell = false;

   // S/R is not evaluated here: it's a live pending-order trigger in TryEnter.
   const bool useStoch = useStochZone ? true : (useCross || useClassic);
   const bool useMA    = MaEnabled(maState);
   if(!useStoch && !useFib && !useMacd && !useRsi && !useMA && !useBos)
      return true;

   bool buy = true, sell = true;

   if(useStoch)
   {
      bool stB = false, stS = false;
      if(useStochZone)
      {
         if(!EvalStochZone(hStoch, true, stochObOs, stochZoneMode,
                           stochMid, stochOS, stochOB,
                           (g_T2_StochTiming == SIG_LIVE) ? 0 : 1, stB, stS)) return false;
      }
      else
      {
         if(!EvalStoch(hStoch, useCross, useClassic, stB, stS)) return false;
      }
      buy &= stB; sell &= stS;
   }
   if(useFib)
   {
      bool fibB = false, fibS = false;
      if(!EvalFibZone(tf, hAtr, true, fibB, fibS)) return false;
      buy &= fibB; sell &= fibS;
   }
   if(useMacd)
   {
      bool macdBuy = false, macdSell = false;
      if(!EvalMacd(hMacd, true, MacdShiftFor(tf), macdBuy, macdSell)) return false;
      buy &= macdBuy; sell &= macdSell;
   }
   if(useRsi)
   {
      bool rsiBuy = false, rsiSell = false;
      if(!EvalRsi(hRsi, true, RsiShiftFor(tf), rsiBuy, rsiSell)) return false;
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

bool T2BiasModulesOn()
{
   return (g_T2_UseStoch ||
           g_T2_UseFibZone || g_T2_UseMacdBias || g_T2_UseRsiBias || MaEnabled(g_T2_MA));
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
   string t1 = "";
   if(g_T1_UseRsiBias)       AddModuleTag(t1, "rsi");
   if(g_T1_UseFibZone)       AddModuleTag(t1, "fibo");
   if(g_T1_UseMacdBias)      AddModuleTag(t1, "macd");
   if(MaEnabled(g_T1_MA))    AddModuleTag(t1, MaStateTag(g_T1_MA));
   if(g_T1_UseStochCross)    AddModuleTag(t1, "stX");
   if(g_T1_UseStochClassic)  AddModuleTag(t1, "stC");
   if(g_T1_UseBos)           AddModuleTag(t1, "bos:" + SourceText(g_BosSource));
   if(g_T1_UseSrBreak) AddModuleTag(t1, "srBrk");
   if(g_T1_UseSrBounce)      AddModuleTag(t1, "srRev");

   string out = " | T1=" + (StringLen(t1) > 0 ? t1 : "none");
   if(g_ConfluenceMode == CONF_T1_AND_T2)
   {
      string t2 = "";
      if(g_T2_UseRsiBias)   AddModuleTag(t2, "rsi");
      if(g_T2_UseStoch)     AddModuleTag(t2, g_T2_StochObOs ? "stoch:obos" : "stoch:mid");
      if(g_T2_UseFibZone)   AddModuleTag(t2, "fibo");
      if(g_T2_UseMacdBias)  AddModuleTag(t2, "macd");
      if(MaEnabled(g_T2_MA)) AddModuleTag(t2, MaStateTag(g_T2_MA) + (g_T2_MaFromT1 ? ":T1" : ":own"));
      out += " | T2=" + (StringLen(t2) > 0 ? t2 : "none");
   }
   if(g_UseGrid)
      out += " | Grid=" + IntegerToString(EffectiveMaxLayers());
   return out;
}

// THE SIGNAL ENGINE RUNS ON EVERY TICK. Each module reads live or closed
// values per its own timing chip — closed values are frozen facts, so
// re-reading them per tick costs nothing and drifts nothing. The moment a
// live condition turns true, this arms and TryEnter fires on the same tick.
// S/R stays a live level trigger in TryEnter (side-neutral arm when it is
// the only side-picker). BOS events are consumed by ENTRIES only.
void UpdateSignal()
{
   g_haveSignal      = false;
   g_signalIsBuy     = false;
   g_srSideFromTick  = false;

   bool b1 = false, s1 = false;
   if(!EvalTf(g_t1,
              g_T1_UseStochCross, g_T1_UseStochClassic, false, false,
              g_StochClassicMode, StochMidLevel, StochOversoldLevel, StochOverboughtLevel,
              g_T1_UseFibZone,
              g_T1_UseMacdBias, g_T1_UseRsiBias, g_T1_MA, g_T1_UseBos,
              g_stochT1, g_rsiT1, g_macdT1,
              g_t1, g_maT1, g_maFT1, g_maST1,
              g_T1_MaTrendMode, g_T1_MACheckMode, MABufferPips, MaMinDiffPips,
              g_atrT1, b1, s1))
      return; // data not ready

   // S/R alone is a FULL entry module. With no other T1 module on, the eval
   // above is empty (both false) — S/R must still trade: treat the empty
   // eval as both-sides-pass and let the level tick pick the direction.
   const bool srOn = (g_T1_UseSrBounce || g_T1_UseSrBreak);
   const bool t1Empty = !g_T1_UseStochCross && !g_T1_UseStochClassic &&
                        !g_T1_UseFibZone && !g_T1_UseMacdBias &&
                        !g_T1_UseRsiBias && !MaEnabled(g_T1_MA) && !g_T1_UseBos;
   if(srOn && t1Empty) { b1 = true; s1 = true; }

   bool b2 = true, s2 = true; // T1-only mode, or empty T2 bias = pass-through
   if(g_ConfluenceMode == CONF_T1_AND_T2 && T2BiasModulesOn())
   {
      // T2 = zone bias (rsi / stoch zone / fib / macd / ma). No S/R, no BOS.
      const ENUM_TIMEFRAMES maTf = g_T2_MaFromT1 ? g_t1 : g_t2;
      const int hMaS = g_T2_MaFromT1 ? g_maT1  : g_maT2;
      const int hMaF = g_T2_MaFromT1 ? g_maFT1 : g_maFT2;
      const int hMaL = g_T2_MaFromT1 ? g_maST1 : g_maST2;
      const ENUM_MA_TREND_MODE maDir = g_T2_MaFromT1 ? g_T1_MaTrendMode : g_T2_MaTrendMode;
      const ENUM_MA_CHECK maChk = g_T2_MaFromT1 ? g_T1_MACheckMode : g_T2_MACheckMode;
      const double maBuf = g_T2_MaFromT1 ? MABufferPips : T2_MABufferPips;
      const double maDiff = g_T2_MaFromT1 ? MaMinDiffPips : T2_MaMinDiffPips;
      b2 = false; s2 = false;
      if(!EvalTf(g_t2,
                 false, false, g_T2_UseStoch, g_T2_StochObOs,
                 g_T2_StochObOsMode, StochMidLevel, StochOversoldLevel, StochOverboughtLevel,
                 g_T2_UseFibZone,
                 g_T2_UseMacdBias, g_T2_UseRsiBias, g_T2_MA, false,
                 g_stochT2, g_rsiT2, g_macdT2,
                 maTf, hMaS, hMaF, hMaL,
                 maDir, maChk, maBuf, maDiff,
                 g_atrT2, b2, s2))
         return; // data not ready
   }

   bool isBuy = false;
   if(ResolveSignalSide(b1 && b2, s1 && s2, isBuy))
   {
      g_haveSignal  = true;
      g_signalIsBuy = isBuy;
      return;
   }

   // Both sides passed and S/R is on — side-neutral arm, the level decides.
   if(srOn && (b1 && b2) && (s1 && s2))
   {
      g_haveSignal     = true;
      g_srSideFromTick = true;
   }
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

   // Every other module was already checked THIS TICK by UpdateSignal (the
   // engine runs per tick now) — no re-checks needed here. Only S/R remains:
   // it is the live level trigger. Side-neutral arm (S/R the only
   // side-picker) resolves buy/sell here; otherwise the armed side just
   // waits for its level. Silent wait — level not hit yet.
   if(g_T1_UseSrBounce || g_T1_UseSrBreak)
   {
      if(g_srSideFromTick)
      {
         bool buyHit  = g_TradeBuy  && LiveSrTrigger(true);
         bool sellHit = g_TradeSell && LiveSrTrigger(false);
         if(buyHit == sellHit) return; // neither hit (or ambiguous tick)
         g_signalIsBuy = buyHit;
      }
      else if(!LiveSrTrigger(g_signalIsBuy))
         return;
   }
   else if(g_srSideFromTick)
      return; // S/R clicked off before the side resolved — wait for re-arm

   if(!CanAttemptEntry())
   { DiagBlock("trade path guard (terminal/broker session/stale tick/retry cooldown)"); return; }

   if(MaxSpreadPips > 0 && (ask - bid) / g_pip > MaxSpreadPips)
   { DiagBlock("spread " + DoubleToString((ask - bid) / g_pip, 1) + " > " + IntegerToString(MaxSpreadPips)); return; }

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
         g_lastEntryBar = g_lastBarTime;
         g_bosDoneLvlBuy = g_bosEvtLvlBuy; // ENTRY consumes the BOS break level
         SyncBasketLines();
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
         g_lastEntryBar = g_lastBarTime;
         g_bosDoneLvlSell = g_bosEvtLvlSell; // ENTRY consumes the BOS break level
         SyncBasketLines();
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
      h = g_maT1;
   else
      h = (g_MaSLLine == MASL_FAST) ? g_maFT1 : g_maST1;
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
                DoubleToString(maSL, _Digits) + " (T1 " + lineTag + " " + (isBuy ? "-" : "+") + " " +
                DoubleToString(SLMABufferPips, 1) + " pips) — closing basket");
   CloseAllEA("virtual MA SL");
}

// Resolve T1 swing anchor for the open basket direction via g_SwingSLMode
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
      if(!ScanFibLeg(g_t1, g_atrT1, haveLeg, bullish, olderP, newerP, bos, bosEvt))
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
      if(!ScanFractalStructure(g_t1, bOK, sOK, sh, sl))
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
                " (T1 " + engineTag + " SwMode=" + EnumToString(g_SwingSLMode) +
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