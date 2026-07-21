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
//|           T2 = zone bias (rsi / stoch / macd / ma).              |
//|           rsi / macd: on/off + live/closed timing per chip.      |
//|           Stoch: cross OR classic, x/c.closed or x/c.live.       |
//|           MA: master + m1/m2, live or closed timing.             |
//|           S/R: full standalone entry — break/reject fires the    |
//|           tick price hits the pivot level, alone or with others. |
//|           PENDING ENGINE: S/R ON rests REAL broker stop/limit    |
//|           orders AT the levels — the broker fills at the level,  |
//|           no tick lag. Other ON modules gate placement (orders   |
//|           pulled when they disagree).                            |
//|           One entry per T1 candle; grid layers by step rule.     |
//|           Grid chip OFF → 1 layer; ON → MaxLayers.               |
//|           Stoch inputs GLOBAL (one K/D + OB/OS/MID for T1+T2).   |
//|           MaSL: ON/OFF + Fast/Slow exit line (T1 MA lines).      |
//|  Exits  : broker pip-cap; optional virtual MaSL and/or SwSL      |
//|           (plain ZigZag swing, tighten-only).                    |
//|  Panel  : chip toggles (top-left), GV memory.                    |
//|  Journal: Tag "lets-go #magic SYMBOL". Push INIT/BASKET only.    |
//|                                                                  |
//|  TEST ON DEMO / STRATEGY TESTER FIRST. Not a profit guarantee.   |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "5.62"

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_LABEL "lets-go"

//====================== ENUMS ======================
enum ENUM_CONF_MODE
{
   CONF_T1_ONLY,    // T1 entry only
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
   MA_CHECK_LIVE,    // Live side only (+/- buffer)
   MA_CHECK_CLOSED   // Last closed only
};
enum ENUM_MA_TREND_MODE
{
   MA_TREND_FOLLOW,   // Buy when price/fast is on the buy side of MA/slow
   MA_TREND_REVERSAL  // Fade: buy when price/fast is on the sell side of MA/slow
};
enum ENUM_MASL_LINE
{
   MASL_FAST, // m2: fast. m1: same single line
   MASL_SLOW  // m2: slow. m1: same single line
};
enum ENUM_TF_SOURCE
{
   TF_SOURCE_OWN,
   TF_SOURCE_T2
};

//====================== INPUTS ======================
input group "===== Confluence (T1 entry, optional T2 bias) ====="
input ENUM_CONF_MODE  ConfluenceMode = CONF_T1_ONLY; // T1 only, or T1+T2
input ENUM_TIMEFRAMES InpT1          = PERIOD_M30;   // T1 entry (signal clock + virtual exits)
input ENUM_TIMEFRAMES InpT2          = PERIOD_H1;    // T2 bias (AND mode only)

input group "===== Direction Master ====="
input bool   TradeBuy  = true; // Allow BUY
input bool   TradeSell = true; // Allow SELL

input group "===== Orders / Risk (basket lines: shared SL/TP, tighter-only) ====="
input double LotSize         = 0.01;   // Lots per layer
input int    MaxStopLossPips = 500;    // Hard broker SL (pips)
input int    TakeProfitPips  = 3000;   // Broker TP (pips)
input int    MaxSpreadPips   = 0;      // Skip new entries above this spread (0 = ignore)
input int    SlippagePoints  = 20;     // Max deviation for market orders (points)
input long   MagicNumber     = 778899; // EA id

input group "===== Grid Layering ====="
input bool   UseGrid         = false; // Panel Grid OFF = 1 layer; ON = MaxLayers
input int    MaxLayers       = 3;     // Max open layers when Grid ON
input int    LayerStepPips   = 200;   // Min adverse move before next layer

input group "===== Basket Take-Profit (pips, trailing) ====="
input bool   UseBasketTP        = true; // Manage profit as a basket in pips (works alongside broker TP)
input double BasketStartPips    = 200;  // Arm trail after this open profit
input double BasketGivebackPips = 50;   // Pullback from peak before close

input group "===== T1 Entry (every ON module must pass — all AND) ====="
// Stoch: cross OR classic if both on. S/R: break OR reject if both on (live).
// Those families then AND with MACD / RSI / MA.
input bool T1_UseStochCross    = false; // Stoch cross
input bool T1_UseStochClassic  = false; // Stoch classic OB/OS
input bool T1_UseSrBounce      = false; // S/R reject (reversal, live at level)
input bool T1_UseSrBreak       = false; // S/R break (live at level)
input bool T1_UseMacdBias      = false; // MACD bias
input bool T1_UseRsiBias       = false; // RSI bias
input bool T1_UseMA            = false; // MA module (panel: m1 / m2)

input group "===== T2 Bias — zone modules (every ON must pass — all AND) ====="
// Ignored when ConfluenceMode = T1_ONLY.
// Zone bias: rsi / stoch / macd / ma. (S/R stays T1 entry only.)
input bool T2_UseStoch    = false; // T2 stoch on/off (mid or OB/OS)
input bool T2_StochObOs   = false; // false=mid (%K vs pullback); true=OB/OS
input bool T2_UseMacdBias = false; // MACD bias
input bool T2_UseRsiBias  = false; // RSI bias (mid-only)
input bool T2_UseMA       = false; // MA module (panel: m1 / m2)
input bool T2_MaFromT1    = false; // T2 MA eval uses T1 handles (panel own/T1)

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
input ENUM_SIG_TIMING    T1_RsiTiming     = SIG_CLOSED;  // T1 RSI: live tick / closed candle
input ENUM_SIG_TIMING    T2_RsiTiming     = SIG_CLOSED;  // T2 RSI: live tick / closed candle
input int                MACDFastEMA      = 12;          // MACD fast EMA
input int                MACDSlowEMA      = 26;          // MACD slow EMA
input int                MACDSignalPeriod = 9;           // MACD signal period
input ENUM_APPLIED_PRICE MACDAppliedPrice = PRICE_CLOSE; // MACD applied price
input ENUM_SIG_TIMING    T1_MacdTiming    = SIG_CLOSED;  // T1 MACD: live tick / closed candle
input ENUM_SIG_TIMING    T2_MacdTiming    = SIG_CLOSED;  // T2 MACD: live tick / closed candle

input group "===== MA (m1 single line / m2 double line + MaSL lines) ====="
// One MA module per TF. Panel: master ON/OFF chip + m1/m2 mode chip.
//   m1 = single MA line (price vs MA, Follow / Reversal).
//   m2 = double line (fast vs slow, Follow / Reversal).
// Timing (LIVE = live tick, CLOSED_ONLY = closed candle arms it).
// T1 uses these settings. T2 has an independent own setup below.
// Risk row only toggles MaSL + Fast/Slow.
input ENUM_MA_METHOD     MaMethod       = MODE_EMA;    // SMA / EMA / SMMA / LWMA
input ENUM_APPLIED_PRICE MaAppliedPrice = PRICE_CLOSE; // Applied price
input int                MaShift        = 0;           // MA horizontal shift

input ENUM_MA_STYLE MaStyle        = MA_STYLE_DOUBLE;  // Default when T1/T2 UseMA is ON
input ENUM_MA_CHECK T1_MACheckMode = MA_CHECK_CLOSED;  // T1 Live / Closed (m1 / m2)
input double        MABufferPips   = 100;              // T1 m1 buffer (pips)

input int MaPeriod     = 34; // Single line (m1)
input int MaFastPeriod = 13; // m2 fast
input int MaSlowPeriod = 34; // m2 slow

// m1 / m2 entry direction.
input ENUM_MA_TREND_MODE T1_MaTrendMode  = MA_TREND_FOLLOW;    // T1 m1 / m2 direction
input double             MaMinDiffPips   = 100;                // T1 m2: 0 = any separation

input group "===== T2 MA (single line; independent when panel source = own) ====="
input ENUM_MA_METHOD     T2_MaMethod       = MODE_EMA;         // T2 own MA method
input ENUM_APPLIED_PRICE T2_MaAppliedPrice = PRICE_CLOSE;      // T2 own applied price
input int                T2_MaShift        = 0;                // T2 own horizontal shift
input ENUM_MA_CHECK      T2_MACheckMode    = MA_CHECK_CLOSED;  // T2 own Live / Closed
input ENUM_MA_TREND_MODE T2_MaTrendMode    = MA_TREND_FOLLOW;  // T2 own Follow or Reversal
input double             T2_MABufferPips   = 100;              // T2 own buffer (pips)
input int                T2_MaPeriod       = 200;              // T2 own single line

input group "===== S/R Pivot Entry (T1 entry; levels own or T2) ====="
input int    PivotLeftBars          = 10;    // Pivot left bars (levels TF; match sr-breaks)
input int    PivotRightBars         = 10;    // Pivot right bars (levels TF; match sr-breaks)
input int    LevelsLookback         = 100;   // Bars to scan for pivots on levels TF
input double SrBufferPips           = 100;   // Break: beyond level by this. Reject: within this of level. 0 = exact line
input ENUM_TF_SOURCE SrLevelsSource = TF_SOURCE_OWN; // S/R levels: own / T2

input group "===== Stop / Exit ====="
// Broker SL = hard pip cap. Virtual MA / swing SL are optional; first hit closes.
// MaSL uses T1 MA lines. m1: Fast/Slow both = single. m2: Fast vs Slow.
input bool           UseVirtualMaSL = false;     // Virtual MA stop ON/OFF
input ENUM_MASL_LINE MaSLLine       = MASL_SLOW; // Default Fast/Slow (panel)
input double         SLMABufferPips = 100;       // MA SL buffer (pips)

// Swing SL = plain ZigZag (standard Depth/Deviation/Backstep, no ATR), latest
// swing low (buy) / high (sell), tighten-only. Match a ZigZag indicator with
// the same three params to see the exact levels the stop rides.
input bool   UseSwingVirtualSL = false; // Virtual swing stop (tighten-only)
input int    SwingZZDepth      = 12;    // ZigZag depth (bars)
input int    SwingZZDeviation  = 5;     // ZigZag deviation (points)
input int    SwingZZBackstep   = 3;     // ZigZag backstep (bars)
input int    SwingZZLookback   = 200;   // Bars scanned on T1
input double SwingSLBufferPips = 100;   // Air beyond swing (pips)

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
input bool InpNotifyOnOpen       = true;  // Push notification on OPEN (new basket + add layer)

//====================== RUNTIME TOGGLES (panel + GV; inputs = defaults) ======================
// MA module per TF: 0=OFF, 1=m1 (single line), 2=m2 (double line)
#define MA_OFF    0
#define MA_SINGLE 1
#define MA_DOUBLE 2

ENUM_CONF_MODE g_ConfluenceMode;
ENUM_STOCH_CROSS_MODE g_StochCrossMode;
ENUM_STOCH_CLASSIC_MODE g_StochClassicMode;
ENUM_SIG_TIMING g_StochCrossTiming, g_StochClassicTiming;
ENUM_SIG_TIMING g_T1_RsiTiming, g_T2_RsiTiming;
ENUM_SIG_TIMING g_T1_MacdTiming, g_T2_MacdTiming;
ENUM_SIG_TIMING g_T2_StochTiming;
ENUM_STOCH_CLASSIC_MODE g_T2_StochObOsMode;
ENUM_MA_CHECK g_T1_MACheckMode, g_T2_MACheckMode;
ENUM_MA_TREND_MODE g_T1_MaTrendMode, g_T2_MaTrendMode;
ENUM_TF_SOURCE g_SrSource;
bool g_TradeBuy, g_TradeSell;
bool g_UseGrid;
int  g_MaxLayers;
bool g_T1_UseStochCross, g_T1_UseStochClassic, g_T1_UseSrBounce, g_T1_UseSrBreak; // derived (see ApplyFamilyMasters)
// Stoch cross / classic each carry their own OFF (3-state chip) — no family
// master. S/R has a master (g_SrOn) plus one break-or-reject selection.
bool g_StCrossSel = false, g_StClassicSel = false;
bool g_SrOn = false, g_SrBreakSel = true; // g_SrBreakSel: true=break, false=reject
bool g_T1_UseMacdBias, g_T1_UseRsiBias;
bool g_T2_UseStoch, g_T2_StochObOs;
bool g_T2_UseMacdBias, g_T2_UseRsiBias;
bool g_T2_MaFromT1 = false;   // T2 MA eval on T1 handles
int  g_T1_MA = MA_OFF;        // derived: master && mode (see ApplyFamilyMasters)
int  g_T2_MA = MA_OFF;        // derived: T2 is single-line only (m1 / off)
// MA family: master ON/OFF chip. T1 also has an m1/m2 mode; T2 is single-line.
bool g_T1_MaOn = false, g_T2_MaOn = false;
int  g_T1_MaSel = MA_DOUBLE;
bool g_UseVirtualMaSL, g_UseSwingVirtualSL, g_UseBasketTP;
bool g_UseSession, g_UseWeekendFilter, g_UseNewsFilter, g_UseBrokerSessionGuard;
ENUM_MASL_LINE g_MaSLLine = MASL_SLOW;

// Keep the derived module bools (used by eval/trigger/tags) in step with the
// panel chips. Stoch: active when its 3-state chip is not off. S/R: active
// when master ON and that side selected. T2 MA is single-line only.
void ApplyFamilyMasters()
{
   g_T1_UseStochCross   = g_StCrossSel;
   g_T1_UseStochClassic = g_StClassicSel;
   g_T1_UseSrBreak      = (g_SrOn && g_SrBreakSel);
   g_T1_UseSrBounce     = (g_SrOn && !g_SrBreakSel);
   g_T1_MA = g_T1_MaOn ? g_T1_MaSel : MA_OFF;
   g_T2_MA = g_T2_MaOn ? MA_SINGLE : MA_OFF;
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
int g_maT1    = INVALID_HANDLE, g_maFT1 = INVALID_HANDLE, g_maST1 = INVALID_HANDLE;
int g_stochT2 = INVALID_HANDLE, g_rsiT2 = INVALID_HANDLE, g_macdT2 = INVALID_HANDLE;
int g_maT2    = INVALID_HANDLE, g_maFT2 = INVALID_HANDLE, g_maST2 = INVALID_HANDLE;

double   g_pip = 0;
datetime g_lastBarTime  = 0;
datetime g_lastEntryBar = 0;

bool   g_haveSignal  = false;
bool   g_signalIsBuy = false;
// True when S/R is the only directional module: signal armed side-neutral,
// the live level trigger picks buy/sell at the tick it fires.
bool   g_srSideFromTick  = false;

// S/R EVENT latches. An ENTRY consumes the level; the same touch won't re-fire
// until price LEAVES the level (the raw touch condition goes false) and comes
// back. Position-based re-arm, no memory.
double g_srEvtLvlBuy = 0, g_srEvtLvlSell = 0;   // candidate level this tick
double g_srDoneLvlBuy = 0, g_srDoneLvlSell = 0; // consumed on entry

// PENDING ENGINE tracking: S/R (when ON) rests real broker stop/limit orders
// at its levels. Only orders we placed (or adopted by comment tag on
// re-attach) are tracked — reconcile never touches others.
#define PEND_MAX 2  // straddle ceiling: one buy-side + one sell-side pending, never same-side double
ulong  g_pendTicket[PEND_MAX];
double g_pendLevel[PEND_MAX];
bool   g_pendIsBuy[PEND_MAX];
int    g_pendCount = 0;
datetime g_srRecalcBar = 0; // levels-TF bar of the last relocate while orders rest

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
// Push: INIT FAILED + BASKET CLOSED always; OPEN gated by InpNotifyOnOpen (default on).
// InpDebugLog = panel notes + DBG traces.
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
                     const int stochK, const int stochD, const int stochSlowing,
                     const ENUM_MA_METHOD stochMethod, const ENUM_STO_PRICE stochPrice,
                     const int maPeriod, const int maFastPeriod, const int maSlowPeriod,
                     const int maShift, const ENUM_MA_METHOD maMethod,
                     const ENUM_APPLIED_PRICE maPrice,
                     int &hStoch, int &hRsi, int &hMacd,
                     int &hMaSingle, int &hMaFast, int &hMaSlow,
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
   return "v559|" + IntegerToString((int)ConfluenceMode) + "|"
        + IntegerToString((int)TradeBuy) + IntegerToString((int)TradeSell) + "|"
        + IntegerToString((int)UseGrid) + "|" + IntegerToString(MaxLayers) + "|"
        + IntegerToString((int)T1_UseStochCross) + IntegerToString((int)T1_UseStochClassic)
        + IntegerToString((int)T1_UseSrBounce) + IntegerToString((int)T1_UseSrBreak)
        + IntegerToString((int)T1_UseMacdBias)
        + IntegerToString((int)T1_UseRsiBias) + IntegerToString((int)T1_UseMA) + "|"
        + IntegerToString((int)StochCrossMode) + IntegerToString((int)StochClassicMode)
        + IntegerToString((int)StochCrossTiming) + IntegerToString((int)StochClassicTiming)
        + IntegerToString((int)T2_StochTiming) + "|"
        + IntegerToString((int)T1_RsiTiming) + IntegerToString((int)T2_RsiTiming)
        + IntegerToString((int)T1_MacdTiming) + IntegerToString((int)T2_MacdTiming) + "|"
        + IntegerToString((int)T1_MaTrendMode) + "|" + IntegerToString((int)T1_MACheckMode) + "|"
        + IntegerToString((int)T2_UseStoch) + IntegerToString((int)T2_StochObOs)
        + IntegerToString((int)T2_UseMacdBias)
        + IntegerToString((int)T2_UseRsiBias) + IntegerToString((int)T2_UseMA)
        + IntegerToString((int)T2_MaFromT1) + "|" + IntegerToString((int)T2_StochObOsMode) + "|"
        + IntegerToString((int)T2_MaTrendMode) + "|" + IntegerToString((int)T2_MACheckMode) + "|"
        + IntegerToString((int)SrLevelsSource) + "|"
        + IntegerToString((int)MaStyle) + IntegerToString((int)MaMethod)
        + IntegerToString(T2_MaPeriod)
        + IntegerToString((int)MaSLLine) + "|"
        + IntegerToString((int)UseVirtualMaSL)
        + IntegerToString((int)UseSwingVirtualSL) + IntegerToString((int)UseBasketTP) + "|"
        + IntegerToString((int)UseSession) + IntegerToString((int)UseWeekendFilter)
        + IntegerToString((int)UseNewsFilter) + IntegerToString((int)UseBrokerSessionGuard);
}

void RuntimeApplyInputDefaults()
{
   g_ConfluenceMode = ConfluenceMode;
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
   g_T1_MACheckMode = T1_MACheckMode;

   g_StCrossSel   = T1_UseStochCross;
   g_StClassicSel = T1_UseStochClassic;
   // One break-or-reject selection; master ON when either input is set.
   g_SrOn         = (T1_UseSrBreak || T1_UseSrBounce);
   g_SrBreakSel   = (T1_UseSrBreak || !T1_UseSrBounce); // break wins ties; default break
   ApplyFamilyMasters();
   g_T1_UseMacdBias = T1_UseMacdBias;
   g_T1_UseRsiBias = T1_UseRsiBias;
   g_T1_MaOn  = T1_UseMA;
   g_T1_MaSel = MaStyleToState(MaStyle);

   g_T2_UseStoch = T2_UseStoch;
   g_T2_StochObOs = T2_StochObOs;
   g_T2_StochObOsMode = T2_StochObOsMode;
   g_T2_UseMacdBias = T2_UseMacdBias;
   g_T2_UseRsiBias = T2_UseRsiBias;
   g_T2_MaOn  = T2_UseMA;
   ApplyFamilyMasters();
   g_T2_MaFromT1 = T2_MaFromT1;
   g_T2_MaTrendMode = T2_MaTrendMode;
   g_T2_MACheckMode = T2_MACheckMode;
   g_SrSource = SrLevelsSource;

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
   PanelSaveBool("Buy", g_TradeBuy);
   PanelSaveBool("Sell", g_TradeSell);
   PanelSaveBool("Grid", g_UseGrid);
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

   PanelSaveBool("T1_stX", g_StCrossSel);
   PanelSaveBool("T1_stC", g_StClassicSel);
   PanelSaveBool("T1_srOn", g_SrOn);
   PanelSaveBool("T1_srR", g_SrBreakSel);
   PanelSaveBool("T1_macd", g_T1_UseMacdBias);
   PanelSaveBool("T1_rsi", g_T1_UseRsiBias);
   PanelSaveBool("T1_maOn", g_T1_MaOn);
   PanelSaveInt("T1_ma", g_T1_MaSel);
   PanelSaveInt("SrLv", (int)g_SrSource);

   PanelSaveBool("T2_stoch", g_T2_UseStoch);
   PanelSaveBool("T2_stOb", g_T2_StochObOs);
   PanelSaveInt("T2_stDir", (int)g_T2_StochObOsMode);
   PanelSaveBool("T2_macd", g_T2_UseMacdBias);
   PanelSaveBool("T2_rsi", g_T2_UseRsiBias);
   PanelSaveBool("T2_maOn", g_T2_MaOn);
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
   g_TradeBuy = PanelLoadBool("Buy", g_TradeBuy);
   g_TradeSell = PanelLoadBool("Sell", g_TradeSell);
   g_UseGrid = PanelLoadBool("Grid", g_UseGrid);
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

   g_StCrossSel   = PanelLoadBool("T1_stX", g_StCrossSel);
   g_StClassicSel = PanelLoadBool("T1_stC", g_StClassicSel);
   g_SrOn         = PanelLoadBool("T1_srOn", g_SrOn);
   g_SrBreakSel   = PanelLoadBool("T1_srR", g_SrBreakSel);
   ApplyFamilyMasters();
   g_T1_UseMacdBias = PanelLoadBool("T1_macd", g_T1_UseMacdBias);
   g_T1_UseRsiBias = PanelLoadBool("T1_rsi", g_T1_UseRsiBias);
   g_T1_MaSel = PanelLoadInt("T1_ma", g_T1_MaSel);
   g_T1_MaOn  = PanelLoadBool("T1_maOn", MaEnabled(g_T1_MaSel));
   g_SrSource = (ENUM_TF_SOURCE)PanelLoadInt("SrLv", (int)g_SrSource);

   g_T2_UseStoch = PanelLoadBool("T2_stoch", g_T2_UseStoch);
   g_T2_StochObOs = PanelLoadBool("T2_stOb", g_T2_StochObOs);
   g_T2_StochObOsMode = (ENUM_STOCH_CLASSIC_MODE)PanelLoadInt("T2_stDir", (int)g_T2_StochObOsMode);
   g_T2_UseMacdBias = PanelLoadBool("T2_macd", g_T2_UseMacdBias);
   g_T2_UseRsiBias = PanelLoadBool("T2_rsi", g_T2_UseRsiBias);
   g_T2_MaOn  = PanelLoadBool("T2_maOn", g_T2_MaOn);
   g_T2_MaFromT1 = PanelLoadBool("T2_maT1", g_T2_MaFromT1);
   g_T2_MaTrendMode = (ENUM_MA_TREND_MODE)PanelLoadInt("T2_MaDir", (int)g_T2_MaTrendMode);
   g_T2_MACheckMode = (ENUM_MA_CHECK)PanelLoadInt("T2_MaChk", (int)g_T2_MACheckMode);

   // Mode chip is m1/m2 only — anything else falls back to MaStyle.
   if(!MaEnabled(g_T1_MaSel)) g_T1_MaSel = MaStyleToState(MaStyle);

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
   if(g_SrSource != TF_SOURCE_OWN && g_SrSource != TF_SOURCE_T2)
      g_SrSource = TF_SOURCE_OWN;
   ApplyFamilyMasters();
   g_MaxLayers = MathMax(1, MathMin(3, g_MaxLayers));
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
   // MA timing is live / closed only — anything else → closed.
   if(g_T1_MACheckMode != MA_CHECK_LIVE)
      g_T1_MACheckMode = MA_CHECK_CLOSED;
   if(g_T2_MACheckMode != MA_CHECK_LIVE)
      g_T2_MACheckMode = MA_CHECK_CLOSED;
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
   // wipe remembered clicks for this account/symbol/magic (current keys only)
   string ids[] = {
      "INP_FP","Conf","Buy","Sell","Grid","Collapsed","SrLv",
      "StXMode","StCMode","T1_stXt","T1_stCt","T2_stT","T1_rsiT","T2_rsiT","T1_macdT","T2_macdT","T1_MaDir","T1_MaChk",
      "T1_stX","T1_stC","T1_srOn","T1_srR","T1_macd","T1_rsi","T1_maOn","T1_ma",
      "T2_stoch","T2_stOb","T2_stDir","T2_macd","T2_rsi","T2_maOn","T2_maT1","T2_MaDir","T2_MaChk",
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
   if(id == "L1" || id == "L2" || id == "LG" || id == "LR")
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

// Dynamic section header that doubles as a live status band (guards row):
// green when open, red when blocked. Non-interactive.
void PanelStyleStatus(const string name, const string text, const bool blocked, const string tip)
{
   ObjectSetString (0, name, OBJPROP_TEXT, text);
   ObjectSetString (0, name, OBJPROP_TOOLTIP, tip);
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
   // Fixed 4-column grid: every row shares the same column edges, so chips
   // align vertically panel-wide. A row with fewer chips lets its LAST chip
   // span the remaining columns (no dead filler chips).
   const int cols  = 4;
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

string ConfChipTip()
{
   return (g_ConfluenceMode == CONF_T1_ONLY)
      ? "T1 entry only (click to also require T2 bias)"
      : "T1 entry AND T2 bias (click for T1 only)";
}

string SourceText(const ENUM_TF_SOURCE source)
{
   if(source == TF_SOURCE_T2) return "T2";
   return "own";
}

string StXModeChipText()
{
   if(g_StochCrossMode == STOCH_CROSS_ANY) return "any";
   if(g_StochCrossMode == STOCH_CROSS_OBOS) return "OB/OS";
   return "pullback"; // PULLBACK until user clicks into any/OS-OB cycle
}
string StXModeChipTip()
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
string StCModeChipTip()
{
   return (g_StochClassicMode == STOCH_CLASSIC_MOM)
      ? "Stoch classic mom: buy OB / sell OS. Click for rev"
      : "Stoch classic rev: buy OS / sell OB. Click for mom";
}

// 3-state stoch chips (no family master): off (gray "stX"/"stC") ->
// x.closed/c.closed -> x.live/c.live. Off on both = stoch contributes nothing.
string StXChipText()
{
   if(!g_StCrossSel) return "stX";
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
   if(!g_StClassicSel) return "stC";
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
string T2StochModeChipTip()
{
   return g_T2_StochObOs
      ? "T2 stoch: OB/OS zone. Click for mid (%K vs pullback)"
      : "T2 stoch: mid (%K vs pullback). Click for OB/OS";
}

string T2StochDirChipText() { return g_T2_StochObOsMode == STOCH_CLASSIC_MOM ? "momentum" : "reversal"; }

string T2MaSrcChipText() { return g_T2_MaFromT1 ? "T1" : "own"; }
string T2MaSrcChipTip()
{
   return g_T2_MaFromT1
      ? "T2 MA uses T1 handles. Click for own T2"
      : "T2 MA uses own T2 handles. Click for T1";
}

// MA family: master ON/OFF chip + m1/m2 mode chip (like stoch/S/R rows).
string MaModeChipText(const int sel) { return (sel == MA_SINGLE) ? "m1" : "m2"; }
string MaModeChipTip(const int sel, const string tfTag)
{
   return (sel == MA_SINGLE)
      ? tfTag + " MA m1 (single line, price vs MA). Click for m2"
      : tfTag + " MA m2 (fast vs slow). Click for m1";
}

// rsi / macd: a plain on/off master chip (green/gray, like the stoch / MA /
// S/R masters) sits next to its own closed/live timing chip. The timing chip
// blacks out while the master is off.
string SigTimingText(const ENUM_SIG_TIMING t) { return (t == SIG_LIVE) ? "live" : "closed"; }
string OscMasterChipTip(const string what, const bool on)
{
   return on ? (what + " ON. Click to turn OFF")
             : (what + " OFF. Click to turn ON");
}
string OscTimingChipTip(const string what, const ENUM_SIG_TIMING t)
{
   return (t == SIG_LIVE)
      ? what + " timing LIVE: the tick decides. Click for closed"
      : what + " timing CLOSED: the closed candle arms it. Click for live";
}

// T2 stoch timing chip (own chip since the master is plain on/off).
string T2StochTimingChipText() { return (g_T2_StochTiming == SIG_LIVE) ? "live" : "closed"; }
string T2StochTimingChipTip()
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

string SrLvChipTip()
{
   return "S/R level source: " + SourceText(g_SrSource) + " (own / T2)";
}

string MaDirText(const ENUM_MA_TREND_MODE mode) { return mode == MA_TREND_FOLLOW ? "follow" : "reversal"; }
// Two timings only: live (tick) / closed (candle arms it).
string MaCheckText(const ENUM_MA_CHECK mode)
{
   return (mode == MA_CHECK_LIVE) ? "live" : "closed";
}

// S/R single trigger chip: break or reject (mutually exclusive; master gates on/off).
string SrBrChipText() { return g_SrBreakSel ? "break" : "reject"; }
string SrBrChipTip()
{
   return g_SrBreakSel
      ? "S/R break: open in the break direction the tick price crosses the level. Click for reject"
      : "S/R reject: open reversal the tick price touches the level. Click for break";
}

// Short timeframe tag for dynamic section headers ("PERIOD_M30" -> "M30").
string TfText(const ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   int u = StringFind(s, "_");
   return (u >= 0) ? StringSubstr(s, u + 1) : s;
}

string MaSLLineChipTip()
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
   mode = (mode == MA_CHECK_LIVE) ? MA_CHECK_CLOSED : MA_CHECK_LIVE;
   PanelSaveInt(gvId, (int)mode);
}

void PanelCycleMaSLLine()
{
   g_MaSLLine = (g_MaSLLine == MASL_FAST) ? MASL_SLOW : MASL_FAST;
   PanelSaveInt("MaLn", (int)g_MaSLLine);
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

void PanelCycleSource(ENUM_TF_SOURCE &source, const string gvId)
{
   source = (source == TF_SOURCE_OWN) ? TF_SOURCE_T2 : TF_SOURCE_OWN;
   PanelSaveInt(gvId, (int)source);
}

void PanelPaintState()
{
   if(!ShowPanel) return;

   // Title header shows the base lot; arrow shows collapse state.
   string ttl = " lets-go  " + DoubleToString(LotSize, 2) + (g_panelCollapsed ? "  ▸" : "  ▾");
   PanelStyleChip(PanelObj("TTL"), ttl, "Base lot per layer. Click to collapse / expand panel", true, true);

   if(g_panelCollapsed) return;

   PanelStyleChip(PanelObj("CONF"), ConfChipText(), ConfChipTip(), true, true);
   PanelStyleChip(PanelObj("GRID"), "grid", "Grid ON = MaxLayers input; OFF = 1 layer", g_UseGrid, false);
   PanelStyleChip(PanelObj("BUY"),  "buy",  "Allow BUY signals",  g_TradeBuy,  false);
   PanelStyleChip(PanelObj("SELL"), "sell", "Allow SELL signals", g_TradeSell, false);

   // Section header doubles as the T1 timeframe readout.
   PanelStyleChip(PanelObj("L1"), " T1 entry " + TfText(g_t1),
                  "T1 entry (" + TfText(g_t1) + "): every ON module must pass (AND)", true, true);

   PanelStyleChip(PanelObj("T1_rsi"), "rsi", OscMasterChipTip("T1 RSI", g_T1_UseRsiBias), g_T1_UseRsiBias, false);
   if(g_T1_UseRsiBias)
      PanelStyleChip(PanelObj("T1_rsiTm"), SigTimingText(g_T1_RsiTiming), OscTimingChipTip("T1 RSI", g_T1_RsiTiming), true, true);
   else
      PanelStyleDisabled(PanelObj("T1_rsiTm"), SigTimingText(g_T1_RsiTiming), "T1 RSI OFF");
   PanelStyleChip(PanelObj("T1_macd"), "macd", OscMasterChipTip("T1 MACD", g_T1_UseMacdBias), g_T1_UseMacdBias, false);
   if(g_T1_UseMacdBias)
      PanelStyleChip(PanelObj("T1_macdTm"), SigTimingText(g_T1_MacdTiming), OscTimingChipTip("T1 MACD", g_T1_MacdTiming), true, true);
   else
      PanelStyleDisabled(PanelObj("T1_macdTm"), SigTimingText(g_T1_MacdTiming), "T1 MACD OFF");

   // Stoch row: no master. stX / stC each carry their own off (3-state); each
   // mode chip lives beside its side and blacks out when that side is off.
   PanelStyleChip(PanelObj("T1_stX"), StXChipText(), StXChipTip(), g_StCrossSel, false);
   if(g_StCrossSel)
      PanelStyleChip(PanelObj("T1_stXm"), StXModeChipText(), StXModeChipTip(), true, true);
   else
      PanelStyleDisabled(PanelObj("T1_stXm"), StXModeChipText(), "Stoch cross OFF");
   PanelStyleChip(PanelObj("T1_stC"), StCChipText(), StCChipTip(), g_StClassicSel, false);
   if(g_StClassicSel)
      PanelStyleChip(PanelObj("T1_stCm"), StCModeChipText(), StCModeChipTip(), true, true);
   else
      PanelStyleDisabled(PanelObj("T1_stCm"), StCModeChipText(), "Stoch classic OFF");

   PanelStyleChip(PanelObj("T1_maOn"), "ma", "T1 MA family ON/OFF", g_T1_MaOn, false);
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

   PanelStyleChip(PanelObj("T1_sr"), "S/R", "T1 S/R family ON/OFF: one-shot trigger at the pivot level (break or reject), re-arms when price leaves", g_SrOn, false);
   if(g_SrOn)
   {
      PanelStyleChip(PanelObj("T1_srLv"), SrLvChipText(), SrLvChipTip(), true, true);
      PanelStyleChip(PanelObj("T1_srBR"), SrBrChipText(), SrBrChipTip(), true, true);
   }
   else
   {
      PanelStyleDisabled(PanelObj("T1_srLv"), SrLvChipText(), "S/R family OFF");
      PanelStyleDisabled(PanelObj("T1_srBR"), SrBrChipText(), "S/R family OFF");
   }

   // Section header doubles as the T2 timeframe readout.
   PanelStyleChip(PanelObj("L2"), " T2 bias " + TfText(g_t2),
                  "T2 bias (" + TfText(g_t2) + ", +T2 mode): every ON module must pass (AND)", true, true);
   const bool t2Active = (g_ConfluenceMode == CONF_T1_AND_T2);
   if(t2Active)
   {
      PanelStyleChip(PanelObj("T2_rsi"), "rsi", OscMasterChipTip("T2 RSI", g_T2_UseRsiBias), g_T2_UseRsiBias, false);
      if(g_T2_UseRsiBias)
         PanelStyleChip(PanelObj("T2_rsiTm"), SigTimingText(g_T2_RsiTiming), OscTimingChipTip("T2 RSI", g_T2_RsiTiming), true, true);
      else
         PanelStyleDisabled(PanelObj("T2_rsiTm"), SigTimingText(g_T2_RsiTiming), "T2 RSI OFF");
      PanelStyleChip(PanelObj("T2_macd"), "macd", OscMasterChipTip("T2 MACD", g_T2_UseMacdBias), g_T2_UseMacdBias, false);
      if(g_T2_UseMacdBias)
         PanelStyleChip(PanelObj("T2_macdTm"), SigTimingText(g_T2_MacdTiming), OscTimingChipTip("T2 MACD", g_T2_MacdTiming), true, true);
      else
         PanelStyleDisabled(PanelObj("T2_macdTm"), SigTimingText(g_T2_MacdTiming), "T2 MACD OFF");

      PanelStyleChip(PanelObj("T2_stoch"), "stoch", "T2 stoch bias ON/OFF", g_T2_UseStoch, false);
      if(g_T2_UseStoch)
      {
         PanelStyleChip(PanelObj("T2_stTm"), T2StochTimingChipText(), T2StochTimingChipTip(), true, true);
         PanelStyleChip(PanelObj("T2_stMd"), T2StochModeChipText(), T2StochModeChipTip(), true, true);
         PanelStyleChip(PanelObj("T2_stDir"), T2StochDirChipText(), "T2 OB/OS momentum / reversal (used when mode=OB/OS)", true, true);
      }
      else
      {
         PanelStyleDisabled(PanelObj("T2_stTm"), T2StochTimingChipText(), "T2 stoch OFF");
         PanelStyleDisabled(PanelObj("T2_stMd"), T2StochModeChipText(), "T2 stoch OFF");
         PanelStyleDisabled(PanelObj("T2_stDir"), T2StochDirChipText(), "T2 stoch OFF");
      }

      // T2 MA is single-line: master | own/T1 source | follow-reversal | timing.
      PanelStyleChip(PanelObj("T2_maOn"), "ma", "T2 MA family ON/OFF (single line)", g_T2_MaOn, false);
      if(g_T2_MaOn)
      {
         PanelStyleChip(PanelObj("T2_maSrc"), T2MaSrcChipText(), T2MaSrcChipTip(), true, true);
         if(g_T2_MaFromT1)
         {
            // Following T1 — show a static marker, never echo T1's live values
            // (else clicking a T1 MA chip would ripple into these locked chips).
            PanelStyleDisabled(PanelObj("T2_maDir"), "T1", "T2 MA follows T1 — set direction on the T1 MA row");
            PanelStyleDisabled(PanelObj("T2_maChk"), "T1", "T2 MA follows T1 — set timing on the T1 MA row");
         }
         else
         {
            PanelStyleChip(PanelObj("T2_maDir"), MaDirText(g_T2_MaTrendMode), "T2-own MA follow / reversal", true, true);
            PanelStyleChip(PanelObj("T2_maChk"), MaCheckText(g_T2_MACheckMode), "T2-own MA timing: live tick / closed candle", true, true);
         }
      }
      else
      {
         PanelStyleDisabled(PanelObj("T2_maSrc"), T2MaSrcChipText(), "MA family OFF");
         PanelStyleDisabled(PanelObj("T2_maDir"), g_T2_MaFromT1 ? "T1" : MaDirText(g_T2_MaTrendMode), "MA family OFF");
         PanelStyleDisabled(PanelObj("T2_maChk"), g_T2_MaFromT1 ? "T1" : MaCheckText(g_T2_MACheckMode), "MA family OFF");
      }
   }
   else
   {
      string hIds[] = {"T2_rsi","T2_rsiTm","T2_macd","T2_macdTm","T2_stoch","T2_stTm","T2_stMd","T2_stDir","T2_maOn","T2_maSrc","T2_maDir","T2_maChk"};
      string hTxt[12];
      hTxt[0]="rsi"; hTxt[1]=SigTimingText(g_T2_RsiTiming);
      hTxt[2]="macd"; hTxt[3]=SigTimingText(g_T2_MacdTiming);
      hTxt[4]="stoch"; hTxt[5]=T2StochTimingChipText(); hTxt[6]=T2StochModeChipText(); hTxt[7]=T2StochDirChipText();
      hTxt[8]="ma"; hTxt[9]=T2MaSrcChipText();
      hTxt[10]=g_T2_MaFromT1 ? "T1" : MaDirText(g_T2_MaTrendMode);
      hTxt[11]=g_T2_MaFromT1 ? "T1" : MaCheckText(g_T2_MACheckMode);
      for(int i=0; i<ArraySize(hIds); i++) PanelStyleDisabled(PanelObj(hIds[i]), hTxt[i], "T2 bias locked while mode=T1");
   }

   // Guards header doubles as the live open/blocked status band.
   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool cooldown = OrderRetryCooldownSec > 0 && (TimeCurrent() - g_lastEntryFailTime) < OrderRetryCooldownSec;
   bool spreadBlocked = MaxSpreadPips > 0 && g_pip > 0 && (ask - bid) / g_pip > MaxSpreadPips;
   bool blocked = InWeekendBlock() || !InDailySession() || InNewsBlackout() ||
                  !IsBrokerTradeSessionOpen() || !IsExpertTradingEnabled() ||
                  tradeMode != SYMBOL_TRADE_MODE_FULL || !IsTickFresh() ||
                  cooldown || spreadBlocked;
   PanelStyleStatus(PanelObj("LG"), " guards " + (blocked ? "BLOCK" : "OPEN"), blocked,
                    "Combined entry-guard status: OPEN = clear to trade, BLOCK = an active guard is holding entries");
   PanelStyleChip(PanelObj("Session"), "Session", "Session guard ON/OFF", g_UseSession, false);
   PanelStyleChip(PanelObj("Weekend"), "Weekend", "Weekend guard ON/OFF", g_UseWeekendFilter, false);
   PanelStyleChip(PanelObj("News"), "News", "News guard ON/OFF", g_UseNewsFilter, false);
   PanelStyleChip(PanelObj("Broker"), "Broker", "Broker session guard ON/OFF", g_UseBrokerSessionGuard, false);

   PanelStyleChip(PanelObj("LR"), " risk exits", "Risk / exit toggles", true, true);
   PanelStyleChip(PanelObj("MaSL"), "MaSL", "Virtual MA stop ON/OFF", g_UseVirtualMaSL, false);
   if(g_UseVirtualMaSL)
      PanelStyleChip(PanelObj("MaLn"), MaSLLineChipText(), MaSLLineChipTip(), true, true);
   else
      PanelStyleDisabled(PanelObj("MaLn"), MaSLLineChipText(), "MaSL OFF");
   PanelStyleChip(PanelObj("SwSL"), "SwSL", "Virtual swing stop ON/OFF (plain ZigZag, tighten-only)", g_UseSwingVirtualSL, false);
   PanelStyleChip(PanelObj("Trail"), "Trail", "Basket pip trail TP ON/OFF", g_UseBasketTP, false);
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

   const int chipW      = 66; // fits 8 chars of Consolas 8 with breathing room (pullback/reversal/momentum)
   const int chipH      = 19;
   const int gap        = 3;
   const int sectionGap = 2;  // extra air between panel sections
   const int rowW  = chipW * 4 + gap * 3;
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
   string modeIds[] = { "CONF", "GRID", "BUY", "SELL" };
   PanelPlaceEvenRow(modeIds, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("L1", x0, y, rowW, chipH); y += chipH + gap;
   string t1osc[] = { "T1_rsi", "T1_rsiTm", "T1_macd", "T1_macdTm" };
   PanelPlaceEvenRow(t1osc, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1st[] = { "T1_stX", "T1_stXm", "T1_stC", "T1_stCm" };
   PanelPlaceEvenRow(t1st, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1ma[] = { "T1_maOn", "T1_ma", "T1_maDir", "T1_maChk" };
   PanelPlaceEvenRow(t1ma, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t1sr[] = { "T1_sr", "T1_srLv", "T1_srBR" };
   PanelPlaceEvenRow(t1sr, 3, x0, y, rowW, gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("L2", x0, y, rowW, chipH); y += chipH + gap;
   string t2osc[] = { "T2_rsi", "T2_rsiTm", "T2_macd", "T2_macdTm" };
   PanelPlaceEvenRow(t2osc, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t2st[] = { "T2_stoch", "T2_stTm", "T2_stMd", "T2_stDir" };
   PanelPlaceEvenRow(t2st, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;
   string t2ma[] = { "T2_maOn", "T2_maSrc", "T2_maDir", "T2_maChk" };
   PanelPlaceEvenRow(t2ma, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("LG", x0, y, rowW, chipH); y += chipH + gap;
   string guards[] = { "Session", "Weekend", "News", "Broker" };
   PanelPlaceEvenRow(guards, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("LR", x0, y, rowW, chipH); y += chipH + gap;
   string risk[] = { "MaSL", "MaLn", "SwSL", "Trail" };
   PanelPlaceEvenRow(risk, 4, x0, y, rowW, gap, chipH);

   string liveIds[] = {
      "TTL","CONF","GRID","BUY","SELL","L1",
      "T1_rsi","T1_rsiTm","T1_macd","T1_macdTm",
      "T1_stX","T1_stXm","T1_stC","T1_stCm",
      "T1_maOn","T1_ma","T1_maDir","T1_maChk",
      "T1_sr","T1_srLv","T1_srBR","L2",
      "T2_rsi","T2_rsiTm","T2_macd","T2_macdTm",
      "T2_stoch","T2_stTm","T2_stMd","T2_stDir",
      "T2_maOn","T2_maSrc","T2_maDir","T2_maChk","LG",
      "Session","Weekend","News","Broker","LR",
      "MaSL","MaLn","SwSL","Trail"
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
   else if(id == "BUY")  PanelToggleBool(g_TradeBuy, "Buy");
   else if(id == "SELL") PanelToggleBool(g_TradeSell, "Sell");
   else if(id == "T1_stX")
   {
      // 3-state, self-gating (no master): off -> x.closed -> x.live -> off
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
      if(!g_StCrossSel) return true; // cross mode locked while stX off
      PanelCycleStochCrossMode();
   }
   else if(id == "T1_stC")
   {
      // 3-state, self-gating (no master): off -> c.closed -> c.live -> off
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
      if(!g_StClassicSel) return true; // classic mode locked while stC off
      PanelCycleStochClassicMode();
   }
   else if(id == "T1_sr")
   {
      g_SrOn = !g_SrOn;
      PanelSaveBool("T1_srOn", g_SrOn);
      ApplyFamilyMasters();
   }
   else if(id == "T1_srBR")
   {
      if(!g_SrOn) return true; // locked while S/R master OFF
      g_SrBreakSel = !g_SrBreakSel; // one trigger: break <-> reject
      PanelSaveBool("T1_srR", g_SrBreakSel);
      ApplyFamilyMasters();
   }
   else if(id == "T1_rsi") PanelToggleBool(g_T1_UseRsiBias, "T1_rsi");
   else if(id == "T1_rsiTm")
   {
      if(!g_T1_UseRsiBias) return true; // timing locked while RSI off
      g_T1_RsiTiming = (g_T1_RsiTiming == SIG_CLOSED) ? SIG_LIVE : SIG_CLOSED;
      PanelSaveInt("T1_rsiT", (int)g_T1_RsiTiming);
   }
   else if(id == "T1_macd") PanelToggleBool(g_T1_UseMacdBias, "T1_macd");
   else if(id == "T1_macdTm")
   {
      if(!g_T1_UseMacdBias) return true; // timing locked while MACD off
      g_T1_MacdTiming = (g_T1_MacdTiming == SIG_CLOSED) ? SIG_LIVE : SIG_CLOSED;
      PanelSaveInt("T1_macdT", (int)g_T1_MacdTiming);
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
   else if(id == "T2_rsi") PanelToggleBool(g_T2_UseRsiBias, "T2_rsi");
   else if(id == "T2_rsiTm")
   {
      if(!g_T2_UseRsiBias) return true; // timing locked while RSI off
      g_T2_RsiTiming = (g_T2_RsiTiming == SIG_CLOSED) ? SIG_LIVE : SIG_CLOSED;
      PanelSaveInt("T2_rsiT", (int)g_T2_RsiTiming);
   }
   else if(id == "T2_macd") PanelToggleBool(g_T2_UseMacdBias, "T2_macd");
   else if(id == "T2_macdTm")
   {
      if(!g_T2_UseMacdBias) return true; // timing locked while MACD off
      g_T2_MacdTiming = (g_T2_MacdTiming == SIG_CLOSED) ? SIG_LIVE : SIG_CLOSED;
      PanelSaveInt("T2_macdT", (int)g_T2_MacdTiming);
   }
   else if(id == "T2_maOn")
   {
      g_T2_MaOn = !g_T2_MaOn;
      PanelSaveBool("T2_maOn", g_T2_MaOn);
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
                       StochKPeriod, StochDPeriod, StochSlowing, StochMAMethod, StochPriceField,
                       MaPeriod, MaFastPeriod, MaSlowPeriod,
                       MaShift, MaMethod, MaAppliedPrice,
                       g_stochT1, g_rsiT1, g_macdT1, g_maT1, g_maFT1, g_maST1, "T1"))
      return(INIT_FAILED);

   // T2 handles: needed for T2 bias only. (SrLv=T2 reads rates via CopyRates,
   // no indicator handle.)
   const bool needT2 = prepAll || g_ConfluenceMode == CONF_T1_AND_T2;
   if(needT2)
   {
      if(!CreateTfHandles(g_t2,
                          prepAll || g_T2_UseStoch, false,
                          prepAll || g_T2_UseMacdBias, prepAll || g_T2_UseRsiBias,
                          prepAll || MaEnabled(g_T2_MA),
                          StochKPeriod, StochDPeriod, StochSlowing,
                          StochMAMethod, StochPriceField,
                          T2_MaPeriod, T2_MaPeriod, T2_MaPeriod, // T2 single-line: fast/slow handles unused
                          T2_MaShift, T2_MaMethod, T2_MaAppliedPrice,
                          g_stochT2, g_rsiT2, g_macdT2, g_maT2, g_maFT2, g_maST2, "T2"))
         return(INIT_FAILED);
      if(PeriodSeconds(g_t2) == PeriodSeconds(g_t1) && !g_quietInit)
         LogInfo("NOTE T1 and T2 are the same period — T2 bias / SrLv T2 add no extra TF.");
   }

   if(!g_quietInit && g_SrSource != TF_SOURCE_OWN && PeriodSeconds(g_t2) <= PeriodSeconds(g_t1))
      LogInfo("NOTE SrLv=T2 but T2 is not higher than T1 — levels TF is not T2.");

   g_pip = PipSize();
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   AdoptOurPendings(); // re-track orders a previous attach left resting

   if(!g_quietInit)
   {
      string mode = (g_ConfluenceMode == CONF_T1_ONLY) ? "ENTRY_ONLY" : "ENTRY+BIAS";
      LogInfo("INIT " + mode
              + " T1=" + EnumToString(g_t1)
              + " T2=" + EnumToString(g_t2)
              + " SrLv=" + SourceText(g_SrSource)
              + " | Buy=" + (g_TradeBuy ? "ON" : "OFF")
              + " Sell=" + (g_TradeSell ? "ON" : "OFF")
              + " Grid=" + (g_UseGrid ? ("ON/" + IntegerToString(EffectiveMaxLayers())) : "OFF/1")
              + " | MaSL=" + (g_UseVirtualMaSL ? "ON" : "OFF")
              + (g_UseVirtualMaSL ? ("/" + ((g_MaSLLine == MASL_FAST) ? "Fast" : "Slow")) : "")
              + " SwSL=" + (g_UseSwingVirtualSL ? "ON" : "OFF")
              + " Trail=" + (g_UseBasketTP ? "ON" : "OFF")
              + " | T2MA=" + IntegerToString(T2_MaPeriod)
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

   // Deliberate remove = pull our resting orders too (nothing left unmanaged).
   // Other reasons keep them resting; next OnInit adopts them by comment tag.
   if(reason == REASON_REMOVE && g_pendCount > 0)
      DeleteOurPendings("EA removed");

   ReleaseHandle(g_stochT1); ReleaseHandle(g_rsiT1); ReleaseHandle(g_macdT1);
   ReleaseHandle(g_maT1);    ReleaseHandle(g_maFT1); ReleaseHandle(g_maST1);
   ReleaseHandle(g_stochT2); ReleaseHandle(g_rsiT2); ReleaseHandle(g_macdT2);
   ReleaseHandle(g_maT2);    ReleaseHandle(g_maFT2); ReleaseHandle(g_maST2);
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
      if(g_pendCount > 0) DeleteOurPendings("schedule close");
      return;
   }

   if(g_modifyPending &&
      GetTickCount64() - g_lastModifyBurstMs >= (ulong)MathMax(0, MaxConsecutiveRetryCooldownMs))
      ProcessBasketModify();

   ManageBasket();
   CheckVirtualMASL();
   CheckSwingVirtualSL();

   ManagePendingEntries(); // rest/refresh/pull broker orders at the levels

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

// LEVEL POOL: scan EVERY confirmed pivot (high AND low) within LevelsLookback on
// the levels TF and return the NEAREST level above the reference price and the
// nearest below it. Positional and color-agnostic — a level is judged purely by
// which side of price it sits on, not by whether it was born a pivot high or a
// pivot low. So any line above price is a buy-stop level, any below a sell-stop
// level, and the CLOSEST one on each side always wins (a far level is used only
// when nothing closer exists). This replaces the old single latest-high +
// latest-low read, which left one side empty whenever price ran past its one
// tracked level. Uses the same three inputs as before: LevelsLookback (scan
// depth), PivotLeftBars / PivotRightBars (what counts as a pivot).
// Nearest-per-side means at most one buy-side + one sell-side order — never a
// same-side double. Returns false only when NO pivot exists on either side yet.
bool GetNearestSrLevels(const ENUM_TIMEFRAMES tf, const double px,
                        double &aboveLvl, bool &haveAbove,
                        double &belowLvl, bool &haveBelow)
{
   aboveLvl = 0; belowLvl = 0; haveAbove = false; haveBelow = false;

   // Fetch MORE than LevelsLookback on purpose — by PivotLeftBars+PivotRightBars
   // extra. Why: a pivot at the OLDEST edge of the scan still needs
   // PivotLeftBars bars further back than it, and PivotRightBars bars in front
   // of it, just to be CONFIRMED as a pivot at all (see IsPivotHighAt_Rates /
   // IsPivotLowAt_Rates below). If we only fetched exactly LevelsLookback bars,
   // `total` below would equal LevelsLookback, so `total - LevelsLookback`
   // (the startBar floor two lines down) collapses to 0 every time, and the
   // MathMax falls back to PivotLeftBars instead — silently chopping the
   // oldest ~(PivotLeftBars+PivotRightBars) bars off the requested depth
   // before a single pivot test ever runs on them. Net effect: typing
   // LevelsLookback=100 only ever actually scanned ~80 bars (with 10/10
   // pivot bars), NOT 100 — while the sr-breaks indicator's MaxBarsBack=100
   // scans close to the full 100, because it always has the FULL chart
   // history loaded and only trims the far edge, so its pivot margin costs
   // it nothing. That mismatch is exactly why the EA could pick a level
   // farther away than one still visibly inside the indicator's same
   // "100 bars" picture — the EA's true reach was quietly smaller.
   // Fetching the margin up front keeps `total` bigger than LevelsLookback,
   // so the subtraction below never degenerates, and LevelsLookback always
   // means what it says — 100 typed in = 100 real bars of pivot-scanning
   // depth, matching the indicator, no matter what PivotLeftBars/
   // PivotRightBars are set to (10, 15, 5, whatever).
   int need = LevelsLookback + PivotLeftBars + PivotRightBars;
   MqlRates rates[];
   int got = CopyRates(_Symbol, tf, 0, need, rates);
   if(got < PivotLeftBars + PivotRightBars + 3)
   { LogDebugGuard("dbg_sr", "GetNearestSrLevels " + EnumToString(tf) + ": not enough bars yet"); return false; }

   int total = got;
   int lastCompleted = total - 2;
   int startBar = MathMax(PivotLeftBars, total - LevelsLookback);

   for(int i = startBar; i <= lastCompleted; i++)
   {
      int pivotIdx = i - PivotRightBars;
      if(pivotIdx < PivotLeftBars) continue;
      if(pivotIdx + PivotRightBars > lastCompleted) continue;

      // Every confirmed pivot is a candidate; keep only the closest on each side.
      if(IsPivotHighAt_Rates(rates, pivotIdx, total, PivotLeftBars, PivotRightBars))
      {
         double v = rates[pivotIdx].high;
         if(v > px)      { if(!haveAbove || v < aboveLvl) { aboveLvl = v; haveAbove = true; } }
         else if(v < px) { if(!haveBelow || v > belowLvl) { belowLvl = v; haveBelow = true; } }
      }
      if(IsPivotLowAt_Rates(rates, pivotIdx, total, PivotLeftBars, PivotRightBars))
      {
         double v = rates[pivotIdx].low;
         if(v > px)      { if(!haveAbove || v < aboveLvl) { aboveLvl = v; haveAbove = true; } }
         else if(v < px) { if(!haveBelow || v > belowLvl) { belowLvl = v; haveBelow = true; } }
      }
   }

   if(!haveAbove && !haveBelow)
   { LogDebugGuard("dbg_sr", "GetNearestSrLevels " + EnumToString(tf) + ": no pivots found yet"); return false; }
   return true;
}

// S/R = one-shot pending-order trigger at the pivot level, checked every tick.
// POSITIONAL + NEAREST (pool): a level has no born role — it is typed purely by
//   which side of CURRENT price it sits on, re-read every tick. Of ALL pivots in
//   the lookback window, only the NEAREST one on each side is ever used (so a
//   breach never parks an order at a far level, and there is never a same-side
//   double). Roles flip automatically with no memory (this replaced the old
//   born-role + flip scheme, and the old single latest-high + latest-low read).
// break : nearest level above price -> buy  when the tick breaks UP through it (+buf);
//         nearest level below price -> sell when the tick breaks DOWN through it (-buf).
// reject: nearest level below price -> buy  when the tick reaches DOWN to it (within buf);
//         nearest level above price -> sell when the tick reaches UP to it (within buf).
// ONE-SHOT: an ENTRY consumes the level (g_srDoneLvl*); the same touch cannot
//   re-fire. It re-arms only when price LEAVES the level (raw touch goes false)
//   and returns — this is the anti-machine-gun fix (price parked beyond the
//   level stays consumed, no re-open after SL). Purely price-position, no memory.
bool LiveSrTrigger(const bool wantBuy)
{
   if(!g_T1_UseSrBounce && !g_T1_UseSrBreak) return true; // module off = pass

   const ENUM_TIMEFRAMES levelsTf = (g_SrSource == TF_SOURCE_T2) ? g_t2 : g_t1;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buf = MathMax(0.0, SrBufferPips) * g_pip;
   double px  = 0.5 * (ask + bid); // side reference: which side of price a level is on

   // nearest level each side of price, picked from all pivots in the lookback
   double aboveLvl = 0, belowLvl = 0; bool haveAbove = false, haveBelow = false;
   if(!GetNearestSrLevels(levelsTf, px, aboveLvl, haveAbove, belowLvl, haveBelow))
      return false;

   bool   rawHit = false;
   double cand   = 0;
   if(wantBuy)
   {
      // break: nearest level ABOVE price, tick breaks up through it -> buy
      if(g_T1_UseSrBreak && haveAbove && ask >= aboveLvl + buf)
         { rawHit = true; cand = aboveLvl; }
      // reject: nearest level BELOW price, tick reaches down to it -> buy
      else if(g_T1_UseSrBounce && haveBelow && bid <= belowLvl + buf)
         { rawHit = true; cand = belowLvl; }
      if(!rawHit)            { g_srDoneLvlBuy = 0; return false; } // price left level -> re-arm
      if(cand == g_srDoneLvlBuy) return false;                    // same touch already consumed
      g_srEvtLvlBuy = cand;
      return true;
   }
   else
   {
      // break: nearest level BELOW price, tick breaks down through it -> sell
      if(g_T1_UseSrBreak && haveBelow && bid <= belowLvl - buf)
         { rawHit = true; cand = belowLvl; }
      // reject: nearest level ABOVE price, tick reaches up to it -> sell
      else if(g_T1_UseSrBounce && haveAbove && ask >= aboveLvl - buf)
         { rawHit = true; cand = aboveLvl; }
      if(!rawHit)             { g_srDoneLvlSell = 0; return false; }
      if(cand == g_srDoneLvlSell) return false;
      g_srEvtLvlSell = cand;
      return true;
   }
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

// m1 side check. LIVE (live) = live price vs live MA, right now.
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

   if(checkMode == MA_CHECK_LIVE)
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
// Timing per TF: LIVE = live values, CLOSED_ONLY = closed candle arms it.
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

   // m2: fast vs slow — live values (LIVE) or last closed candle (CLOSED).
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
   const int mi = (checkMode == MA_CHECK_LIVE) ? 0 : 1;
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

// Evaluate one TF: every enabled module family must pass (all AND).
// T1 Stoch: cross OR classic. T2 Stoch: zone (mid/obos) via useStochZone.
// S/R is NOT here — live pending-order trigger in TryEnter (LiveSrTrigger).
// If nothing enabled: outBuy/outSell stay false (caller may treat empty T2 as pass).
// maTf + MA handles: T2 bias may evaluate MA on T1 when g_T2_MaFromT1.
bool EvalTf(const ENUM_TIMEFRAMES tf,
            const bool useCross, const bool useClassic,
            const bool useStochZone, const bool stochObOs,
            const ENUM_STOCH_CLASSIC_MODE stochZoneMode,
            const double stochMid, const double stochOS, const double stochOB,
            const bool useMacd, const bool useRsi, const int maState,
            const int hStoch, const int hRsi, const int hMacd,
            const ENUM_TIMEFRAMES maTf,
            const int hMaSingle, const int hMaFast, const int hMaSlow,
            const ENUM_MA_TREND_MODE maTrendMode, const ENUM_MA_CHECK maCheckMode,
            const double maBufferPips, const double maMinDiffPips,
            bool &outBuy, bool &outSell)
{
   outBuy = false; outSell = false;

   // S/R is not evaluated here: it's a live pending-order trigger in TryEnter.
   const bool useStoch = useStochZone ? true : (useCross || useClassic);
   const bool useMA    = MaEnabled(maState);
   if(!useStoch && !useMacd && !useRsi && !useMA)
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
           g_T2_UseMacdBias || g_T2_UseRsiBias || MaEnabled(g_T2_MA));
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
   if(g_T1_UseMacdBias)      AddModuleTag(t1, "macd");
   if(MaEnabled(g_T1_MA))    AddModuleTag(t1, MaStateTag(g_T1_MA));
   if(g_T1_UseStochCross)    AddModuleTag(t1, "stX");
   if(g_T1_UseStochClassic)  AddModuleTag(t1, "stC");
   if(g_T1_UseSrBreak)       AddModuleTag(t1, "srBrk");
   if(g_T1_UseSrBounce)      AddModuleTag(t1, "srRev");

   string out = " | T1=" + (StringLen(t1) > 0 ? t1 : "none");
   if(g_ConfluenceMode == CONF_T1_AND_T2)
   {
      string t2 = "";
      if(g_T2_UseRsiBias)   AddModuleTag(t2, "rsi");
      if(g_T2_UseStoch)     AddModuleTag(t2, g_T2_StochObOs ? "stoch:obos" : "stoch:mid");
      if(g_T2_UseMacdBias)  AddModuleTag(t2, "macd");
      if(MaEnabled(g_T2_MA)) AddModuleTag(t2, MaStateTag(g_T2_MA) + (g_T2_MaFromT1 ? ":T1" : ":own"));
      out += " | T2=" + (StringLen(t2) > 0 ? t2 : "none");
   }
   if(g_UseGrid)
      out += " | Grid=" + IntegerToString(EffectiveMaxLayers());
   return out;
}

// T2 bias gate (rsi / stoch zone / macd / ma — no S/R).
// Shared by UpdateSignal and the pending engine. false = data not ready.
bool EvalT2Bias(bool &b2, bool &s2)
{
   b2 = true; s2 = true;
   if(g_ConfluenceMode != CONF_T1_AND_T2 || !T2BiasModulesOn()) return true;
   const ENUM_TIMEFRAMES maTf = g_T2_MaFromT1 ? g_t1 : g_t2;
   const int hMaS = g_T2_MaFromT1 ? g_maT1  : g_maT2;
   const int hMaF = g_T2_MaFromT1 ? g_maFT1 : g_maFT2;
   const int hMaL = g_T2_MaFromT1 ? g_maST1 : g_maST2;
   const ENUM_MA_TREND_MODE maDir = g_T2_MaFromT1 ? g_T1_MaTrendMode : g_T2_MaTrendMode;
   const ENUM_MA_CHECK maChk = g_T2_MaFromT1 ? g_T1_MACheckMode : g_T2_MACheckMode;
   const double maBuf = g_T2_MaFromT1 ? MABufferPips : T2_MABufferPips;
   const double maDiff = MaMinDiffPips; // unused for T2 single-line; kept for shared EvalTf signature
   b2 = false; s2 = false;
   return EvalTf(g_t2,
                 false, false, g_T2_UseStoch, g_T2_StochObOs,
                 g_T2_StochObOsMode, StochMidLevel, StochOversoldLevel, StochOverboughtLevel,
                 g_T2_UseMacdBias, g_T2_UseRsiBias, g_T2_MA,
                 g_stochT2, g_rsiT2, g_macdT2,
                 maTf, hMaS, hMaF, hMaL,
                 maDir, maChk, maBuf, maDiff,
                 b2, s2);
}

// THE SIGNAL ENGINE RUNS ON EVERY TICK. Each module reads live or closed
// values per its own timing chip — closed values are frozen facts, so
// re-reading them per tick costs nothing and drifts nothing. The moment a
// live condition turns true, this arms and TryEnter fires on the same tick.
// S/R stays a live level trigger in TryEnter (side-neutral arm when it is
// the only side-picker).
void UpdateSignal()
{
   g_haveSignal      = false;
   g_signalIsBuy     = false;
   g_srSideFromTick  = false;

   bool b1 = false, s1 = false;
   if(!EvalTf(g_t1,
              g_T1_UseStochCross, g_T1_UseStochClassic, false, false,
              g_StochClassicMode, StochMidLevel, StochOversoldLevel, StochOverboughtLevel,
              g_T1_UseMacdBias, g_T1_UseRsiBias, g_T1_MA,
              g_stochT1, g_rsiT1, g_macdT1,
              g_t1, g_maT1, g_maFT1, g_maST1,
              g_T1_MaTrendMode, g_T1_MACheckMode, MABufferPips, MaMinDiffPips,
              b1, s1))
      return; // data not ready

   // S/R alone is a FULL entry module. With no other T1 module on, the eval
   // above is empty (both false) — S/R must still trade: treat the empty
   // eval as both-sides-pass and let the level tick pick the direction.
   const bool srOn = (g_T1_UseSrBounce || g_T1_UseSrBreak);
   const bool t1Empty = !g_T1_UseStochCross && !g_T1_UseStochClassic &&
                        !g_T1_UseMacdBias &&
                        !g_T1_UseRsiBias && !MaEnabled(g_T1_MA);
   if(srOn && t1Empty) { b1 = true; s1 = true; }

   bool b2 = true, s2 = true; // T1-only mode, or empty T2 bias = pass-through
   if(!EvalT2Bias(b2, s2))
      return; // data not ready

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

//====================== PENDING ENGINE ======================
// S/R (when ON) rests REAL broker stop/limit orders at its levels: the broker
// fills AT the level instead of the EA reacting a tick later. Other ON modules
// gate placement — when they stop agreeing the orders are pulled. First layer
// only; grid adds stay on the market path.

int PendFindByOrder(const ulong orderTicket)
{
   for(int i = 0; i < g_pendCount; i++)
      if(g_pendTicket[i] == orderTicket) return i;
   return -1;
}

void PendUntrackIndex(const int idx)
{
   if(idx < 0 || idx >= g_pendCount) return;
   for(int i = idx; i < g_pendCount - 1; i++)
   {
      g_pendTicket[i]  = g_pendTicket[i + 1];
      g_pendLevel[i]   = g_pendLevel[i + 1];
      g_pendIsBuy[i]   = g_pendIsBuy[i + 1];
   }
   g_pendCount--;
}

void DeleteOurPendings(const string reason)
{
   for(int i = g_pendCount - 1; i >= 0; i--)
   {
      if(OrderSelect(g_pendTicket[i]))
      {
         if(!trade.OrderDelete(g_pendTicket[i]))
         {
            LogGuardOnce("fail_pend_del", "FAIL pending delete rc=" + IntegerToString(trade.ResultRetcode())
                         + " " + trade.ResultRetcodeDescription());
            continue; // keep tracked, retry next tick
         }
         LogInfo("PEND DEL " + (g_pendIsBuy[i] ? "BUY" : "SELL") + " @ "
                 + DoubleToString(g_pendLevel[i], _Digits) + " (" + reason + ")");
      }
      PendUntrackIndex(i); // gone from broker either way
   }
}

// Re-attach safety: pick up orders a previous attach left resting (crash /
// TF change) so reconcile manages them instead of orphaning live orders.
void AdoptOurPendings()
{
   g_pendCount = 0;
   for(int i = OrdersTotal() - 1; i >= 0 && g_pendCount < PEND_MAX; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_STOP && ot != ORDER_TYPE_SELL_STOP &&
         ot != ORDER_TYPE_BUY_LIMIT && ot != ORDER_TYPE_SELL_LIMIT) continue;
      string cm = OrderGetString(ORDER_COMMENT);
      if(StringFind(cm, "lets-go pend") < 0) continue;
      g_pendTicket[g_pendCount]  = tk;
      g_pendLevel[g_pendCount]   = OrderGetDouble(ORDER_PRICE_OPEN);
      g_pendIsBuy[g_pendCount]   = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT);
      g_pendCount++;
   }
   if(g_pendCount > 0)
      LogInfo("PEND adopted " + IntegerToString(g_pendCount) + " resting order(s) from previous attach");
}

void PlacePendingOrder(const bool isBuy, const bool isStop, const double lvl)
{
   double lots = NormalizeLots(LotSize);
   if(lots <= 0)
   {
      LogGuardOnce("lots_invalid", "BLOCKED pend — NormalizeLots(LotSize=" +
                   DoubleToString(LotSize, 2) + ") = 0 (check LotSize vs broker min/max/step)");
      return;
   }
   // Same first-layer estimate as OpenLayer — never resting naked. Lines are
   // recomputed from the real fill by SyncBasketLines (fill handler below).
   double sl, tp = 0;
   if(isBuy)
   {
      sl = NormalizePrice(lvl - MaxStopLossPips * g_pip);
      if(TakeProfitPips > 0) tp = NormalizePrice(lvl + TakeProfitPips * g_pip);
   }
   else
   {
      sl = NormalizePrice(lvl + MaxStopLossPips * g_pip);
      if(TakeProfitPips > 0) tp = NormalizePrice(lvl - TakeProfitPips * g_pip);
   }
   const string cm = "lets-go pend sr";
   bool ok;
   if(isBuy)  ok = isStop ? trade.BuyStop(lots, lvl, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cm)
                          : trade.BuyLimit(lots, lvl, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cm);
   else       ok = isStop ? trade.SellStop(lots, lvl, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cm)
                          : trade.SellLimit(lots, lvl, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cm);
   if(ok && trade.ResultOrder() > 0)
   {
      g_pendTicket[g_pendCount]  = trade.ResultOrder();
      g_pendLevel[g_pendCount]   = lvl;
      g_pendIsBuy[g_pendCount]   = isBuy;
      g_pendCount++;
      LogInfo("PEND SET " + (isBuy ? "BUY " : "SELL ") + (isStop ? "STOP" : "LIMIT")
              + " @ " + DoubleToString(lvl, _Digits) + " | S/R"
              + " | SL " + DoubleToString(sl, _Digits)
              + (tp > 0 ? " TP " + DoubleToString(tp, _Digits) : ""));
   }
   else
   {
      g_lastEntryFailTime = TimeCurrent();
      LogGuardOnce("fail_pend", "FAIL pending rc=" + IntegerToString(trade.ResultRetcode())
                   + " " + trade.ResultRetcodeDescription());
   }
}

// Per tick: compute the orders that SHOULD rest right now, then reconcile
// (delete stale, keep matching, place missing). Runs before TryEnter.
// TWO STATES, no gray zone:
//   - Nothing resting (flat) -> place instantly, every tick. The first order
//     after going flat is never delayed.
//   - An order already resting and untouched -> its level is only re-picked on
//     a NEW closed candle of the levels TF. So an intra-candle spike crossing
//     levels back and forth can't churn the broker with cancel/replace; the
//     resting order stays put until the candle closes, then re-checks once.
// Fills are always instant (broker-side, untouched by this). The safety pulls
// below (S/R off, basket open, entry blocked) also stay tick-live.
void ManagePendingEntries()
{
   // Pending broker orders rest ONLY while the S/R module is ON — nothing
   // else places pendings. When S/R is off, pull anything still resting.
   const bool srPend = (g_T1_UseSrBounce || g_T1_UseSrBreak);

   // sync tracked list with the broker (fills untrack in the fill handler;
   // this also catches orders deleted by hand in the terminal)
   for(int i = g_pendCount - 1; i >= 0; i--)
      if(!OrderSelect(g_pendTicket[i])) PendUntrackIndex(i);

   if(!srPend)
   { if(g_pendCount > 0) DeleteOurPendings("S/R off"); return; }

   int layers; double deepest; bool exBuy;
   CountLayers(layers, deepest, exBuy);
   if(layers > 0)
   { if(g_pendCount > 0) DeleteOurPendings("basket open"); return; }

   if(!InSession() || !CanAttemptEntry())
   { if(g_pendCount > 0) DeleteOurPendings("entry blocked"); return; }

   const ENUM_TIMEFRAMES levelsTf = (g_SrSource == TF_SOURCE_T2) ? g_t2 : g_t1;

   // Relocation gate: freeze an already-resting, untouched order until the
   // levels-TF candle closes. Nothing resting -> fall through and place now.
   const datetime curBar = iTime(_Symbol, levelsTf, 0);
   if(g_pendCount > 0 && curBar == g_srRecalcBar) return;
   g_srRecalcBar = curBar;

   // ---- desired orders ----
   double dLvl[PEND_MAX]; bool dBuy[PEND_MAX], dStop[PEND_MAX];
   int dn = 0;

   // Gate = everything else, exactly as UpdateSignal resolved it this tick.
   bool aBuy = false, aSell = false;
   if(g_haveSignal)
   {
      if(g_srSideFromTick) { aBuy = g_TradeBuy; aSell = g_TradeSell; }
      else                 { aBuy = g_signalIsBuy; aSell = !g_signalIsBuy; }
   }
   if(aBuy || aSell)
   {
      const double buf = MathMax(0.0, SrBufferPips) * g_pip;
      const double px  = 0.5 * (SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              + SymbolInfoDouble(_Symbol, SYMBOL_BID));
      double aboveLvl = 0, belowLvl = 0; bool haveAbove = false, haveBelow = false;
      if(GetNearestSrLevels(levelsTf, px, aboveLvl, haveAbove, belowLvl, haveBelow))
      {
         // No done-latch here on purpose: a stop/limit is only placeable when
         // price sits on the pre-touch side, which IS the re-arm rule.
         // POSITIONAL + NEAREST (pool): the closest level on each side of price,
         // picked from all pivots in the lookback, matching LiveSrTrigger exactly
         // so a resting order and the live trigger can never disagree. At most one
         // order per side (never a same-side double); break -> stop, reject -> limit.
         //   nearest above price: break=buy stop  / reject=sell limit
         //   nearest below price: break=sell stop / reject=buy limit
         // nearest level ABOVE price -> one order (break=buy stop / reject=sell limit)
         if(haveAbove && dn < PEND_MAX)
         {
            if(g_T1_UseSrBreak && aBuy)        { dLvl[dn] = aboveLvl + buf; dBuy[dn] = true;  dStop[dn] = true;  dn++; }
            else if(g_T1_UseSrBounce && aSell) { dLvl[dn] = aboveLvl - buf; dBuy[dn] = false; dStop[dn] = false; dn++; }
         }
         // nearest level BELOW price -> one order (break=sell stop / reject=buy limit)
         if(haveBelow && dn < PEND_MAX)
         {
            if(g_T1_UseSrBreak && aSell)       { dLvl[dn] = belowLvl - buf; dBuy[dn] = false; dStop[dn] = true;  dn++; }
            else if(g_T1_UseSrBounce && aBuy)  { dLvl[dn] = belowLvl + buf; dBuy[dn] = true;  dStop[dn] = false; dn++; }
         }
      }
   }

   // Opposite orders at ONE level would both fire on the same touch — drop the
   // pair (same skip the market path does for an ambiguous tick).
   for(int i = 0; i < dn; i++)
      for(int j = i + 1; j < dn; j++)
         if(dLvl[i] > 0 && dLvl[j] > 0 && dBuy[i] != dBuy[j]
            && MathAbs(dLvl[i] - dLvl[j]) < g_pip * 0.1)
         {
            dLvl[i] = 0; dLvl[j] = 0;
            LogGuardOnce("pend_conflict", "NOTE S/R wants opposite orders at one level — both skipped");
         }

   // Broker validity = the arming rule: a stop rests only with price on the
   // pre-break side, a limit only on the approach side. Wrong side = not
   // armed (or the touch already happened — market path takes over, nothing
   // rests so TryEnter is free).
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   for(int i = 0; i < dn; i++)
   {
      if(dLvl[i] <= 0) continue;
      double lvl = NormalizePrice(dLvl[i]);
      bool ok;
      if(dBuy[i]) ok = dStop[i] ? (lvl - ask > minStop) : (ask - lvl > minStop);
      else        ok = dStop[i] ? (bid - lvl > minStop) : (lvl - bid > minStop);
      dLvl[i] = ok ? lvl : 0;
   }

   // Reconcile. Matched desired slots are flagged negative so the placement
   // pass below skips them; anything tracked but no longer desired is pulled.
   for(int i = g_pendCount - 1; i >= 0; i--)
   {
      bool keep = false;
      for(int j = 0; j < dn; j++)
         if(dLvl[j] > 0 && g_pendIsBuy[i] == dBuy[j]
            && MathAbs(g_pendLevel[i] - dLvl[j]) < point * 0.5)
         { keep = true; dLvl[j] = -dLvl[j]; break; }
      if(keep) continue;
      if(!trade.OrderDelete(g_pendTicket[i]))
      {
         LogGuardOnce("fail_pend_del", "FAIL pending delete rc=" + IntegerToString(trade.ResultRetcode())
                      + " " + trade.ResultRetcodeDescription());
         continue;
      }
      LogInfo("PEND DEL " + (g_pendIsBuy[i] ? "BUY" : "SELL") + " @ "
              + DoubleToString(g_pendLevel[i], _Digits) + " (stale)");
      PendUntrackIndex(i);
   }
   for(int j = 0; j < dn && g_pendCount < PEND_MAX; j++)
      if(dLvl[j] > 0)
         PlacePendingOrder(dBuy[j], dStop[j], dLvl[j]);
}

// A pending of ours filled: do the bookkeeping OpenLayer does for market
// entries — consume the level, stamp the bar latch, pull siblings, resync.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber) return;

   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY)
   { NotifyBrokerClose(trans.deal); return; }

   if(dealEntry != DEAL_ENTRY_IN) return;
   int idx = PendFindByOrder((ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER));
   if(idx < 0) return; // market entry — OpenLayer already did this
   const bool   isBuy  = g_pendIsBuy[idx];
   const double lvl    = g_pendLevel[idx];
   if(isBuy) g_srDoneLvlBuy = lvl; else g_srDoneLvlSell = lvl; // consume the S/R level
   g_lastEntryBar = g_lastBarTime;
   PendUntrackIndex(idx);
   string pendFillMsg = "OPEN " + (isBuy ? "BUY" : "SELL") + " "
           + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_VOLUME), 2)
           + " @ " + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PRICE), _Digits)
           + " | pending fill at S/R level "
           + DoubleToString(lvl, _Digits);
   LogInfo(pendFillMsg);
   if(InpNotifyOnOpen) NotifyPush(pendFillMsg);
   DeleteOurPendings("sibling after fill");
   SyncBasketLines();
}

// Broker-side SL/TP/stop-out fill: CloseAllEA() never runs for these (that
// path only closes via trade.PositionClose, tagged DEAL_REASON_EXPERT, and
// pushes there already), so without this they close silently — no Journal
// CLOSE line, no push, even though History shows them same as any other.
void NotifyBrokerClose(const ulong dealTicket)
{
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
   string tag;
   switch(reason)
   {
      case DEAL_REASON_SL: tag = "broker SL"; break;
      case DEAL_REASON_TP: tag = "broker TP"; break;
      case DEAL_REASON_SO: tag = "stop out";  break;
      default: return; // EXPERT/CLIENT/other — already handled elsewhere or not ours
   }

   double dealPL = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   string msg = "POSITION CLOSED (" + tag + ") | Net P/L: " + DoubleToString(dealPL, 2);
   LogInfo(msg);
   NotifyPush(msg);
}

void TryEnter()
{
   // Resting broker pendings own the first layer — they fill AT the level,
   // so the market path must not double-fire the same touch. (Pendings only
   // exist while flat; once a basket opens they are pulled and grid adds
   // run through here as usual.)
   if(g_pendCount > 0) return;

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
         string buyOpenMsg = "OPEN BUY " + DoubleToString(lots, 2) + " @ " + DoubleToString(ask, _Digits) + (isFirstLayer ? " | new basket" : " | add layer") + " | SL " + DoubleToString(sl, _Digits) + (tp > 0 ? " TP " + DoubleToString(tp, _Digits) : "");
         LogInfo(buyOpenMsg);
         if(InpNotifyOnOpen) NotifyPush(buyOpenMsg);
         g_lastEntryBar = g_lastBarTime;
         if(g_T1_UseSrBreak || g_T1_UseSrBounce) g_srDoneLvlBuy = g_srEvtLvlBuy; // ENTRY consumes the S/R level
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
         string sellOpenMsg = "OPEN SELL " + DoubleToString(lots, 2) + " @ " + DoubleToString(bid, _Digits) + (isFirstLayer ? " | new basket" : " | add layer") + " | SL " + DoubleToString(sl, _Digits) + (tp > 0 ? " TP " + DoubleToString(tp, _Digits) : "");
         LogInfo(sellOpenMsg);
         if(InpNotifyOnOpen) NotifyPush(sellOpenMsg);
         g_lastEntryBar = g_lastBarTime;
         if(g_T1_UseSrBreak || g_T1_UseSrBounce) g_srDoneLvlSell = g_srEvtLvlSell; // ENTRY consumes the S/R level
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

// Lowest / highest index in an inclusive [from..to] slice of a non-series array.
int RangeLowest(const double &arr[], int from, int to)
{
   if(from < 0) from = 0;
   int idx = from; double v = arr[from];
   for(int i = from + 1; i <= to; i++) if(arr[i] < v) { v = arr[i]; idx = i; }
   return idx;
}
int RangeHighest(const double &arr[], int from, int to)
{
   if(from < 0) from = 0;
   int idx = from; double v = arr[from];
   for(int i = from + 1; i <= to; i++) if(arr[i] > v) { v = arr[i]; idx = i; }
   return idx;
}

// Plain ZigZag — a faithful port of the standard MetaQuotes ZigZag indicator
// (Depth / Deviation / Backstep, NO ATR). Returns the most recent swing high
// and swing low prices over the lookback window. Drop a ZigZag indicator with
// the same three params on the chart and the pivots line up exactly.
bool ScanZigZag(const ENUM_TIMEFRAMES tf, const int inpDepth, const int inpDeviation,
                const int inpBackstep, const int lookback,
                double &lastHigh, double &lastLow)
{
   lastHigh = 0; lastLow = 0;
   const int    depth    = MathMax(1, inpDepth);
   const int    backstep = MathMax(0, inpBackstep);
   const double devPts   = MathMax(0, inpDeviation) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   int want = MathMax(lookback, depth * 3 + backstep + 10);
   int bars = (int)MathMin((long)want, (long)Bars(_Symbol, tf));
   if(bars < depth + backstep + 3)
   { LogDebugGuard("dbg_zz", "ScanZigZag " + EnumToString(tf) + ": not enough bars yet"); return false; }

   MqlRates rates[];
   ArraySetAsSeries(rates, false); // [0]=oldest, [total-1]=forming
   int total = CopyRates(_Symbol, tf, 0, bars, rates);
   if(total < depth + backstep + 3)
   { LogDebugGuard("dbg_zz", "ScanZigZag " + EnumToString(tf) + ": short rates read"); return false; }

   double high[], low[], highMap[], lowMap[];
   ArrayResize(high, total); ArrayResize(low, total);
   ArrayResize(highMap, total); ArrayResize(lowMap, total);
   for(int i = 0; i < total; i++)
   {
      high[i] = rates[i].high; low[i] = rates[i].low;
      highMap[i] = 0.0; lowMap[i] = 0.0;
   }

   // ---- pass 1: mark local extremes (with deviation + backstep cleanup) ----
   double p1low = 0.0, p1high = 0.0;
   for(int i = depth; i < total; i++)
   {
      double ext = low[RangeLowest(low, i - depth + 1, i)];
      if(ext == p1low) ext = 0.0;
      else
      {
         p1low = ext;
         if(low[i] - ext > devPts) ext = 0.0;
         else
            for(int back = 1; back <= backstep; back++)
            {
               int pos = i - back; if(pos < 0) break;
               if(lowMap[pos] != 0.0 && lowMap[pos] > ext) lowMap[pos] = 0.0;
            }
      }
      lowMap[i] = (low[i] == ext) ? ext : 0.0;

      ext = high[RangeHighest(high, i - depth + 1, i)];
      if(ext == p1high) ext = 0.0;
      else
      {
         p1high = ext;
         if(ext - high[i] > devPts) ext = 0.0;
         else
            for(int back = 1; back <= backstep; back++)
            {
               int pos = i - back; if(pos < 0) break;
               if(highMap[pos] != 0.0 && highMap[pos] < ext) highMap[pos] = 0.0;
            }
      }
      highMap[i] = (high[i] == ext) ? ext : 0.0;
   }

   // ---- pass 2: keep only alternating pivots; track the latest of each ----
   int    whatlookfor = 0;      // 0 = first pivot, 1 = expecting a high, -1 = expecting a low
   int    lastHighPos = -1, lastLowPos = -1;
   double curHigh = 0.0, curLow = 0.0;
   for(int i = depth; i < total; i++)
   {
      switch(whatlookfor)
      {
         case 0: // first pivot either way
            if(lowMap[i] != 0.0)  { curLow = lowMap[i];  lastLowPos = i;  whatlookfor = 1;  }
            if(highMap[i] != 0.0) { curHigh = highMap[i]; lastHighPos = i; whatlookfor = -1; }
            break;
         case 1: // expecting a high; a deeper low relocates the last low
            if(lowMap[i] != 0.0 && lowMap[i] < curLow && highMap[i] == 0.0)
            { lastLowPos = i; curLow = lowMap[i]; }
            if(highMap[i] != 0.0 && lowMap[i] == 0.0)
            { curHigh = highMap[i]; lastHighPos = i; whatlookfor = -1; }
            break;
         case -1: // expecting a low; a higher high relocates the last high
            if(highMap[i] != 0.0 && highMap[i] > curHigh && lowMap[i] == 0.0)
            { lastHighPos = i; curHigh = highMap[i]; }
            if(lowMap[i] != 0.0 && highMap[i] == 0.0)
            { curLow = lowMap[i]; lastLowPos = i; whatlookfor = 1; }
            break;
      }
   }

   lastHigh = (lastHighPos >= 0) ? curHigh : 0.0;
   lastLow  = (lastLowPos  >= 0) ? curLow  : 0.0;
   return true;
}

// Resolve the T1 swing anchor for the basket direction: the latest ZigZag low
// for a long, the latest ZigZag high for a short.
bool GetSwingAnchor(const bool isBuy, double &swing, string &engineTag)
{
   swing = 0;
   engineTag = "zigzag";

   double zzHigh = 0, zzLow = 0;
   if(!ScanZigZag(g_t1, SwingZZDepth, SwingZZDeviation, SwingZZBackstep, SwingZZLookback, zzHigh, zzLow))
      return false;

   if(isBuy)  { if(zzLow  <= 0) return false; swing = zzLow;  }
   else       { if(zzHigh <= 0) return false; swing = zzHigh; }
   return true;
}

// Swing / last-low(high): plain ZigZag anchor, ratchet tighten-only.
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
                " (T1 " + engineTag + " ZigZag " + IntegerToString(SwingZZDepth) + "/" +
                IntegerToString(SwingZZDeviation) + "/" + IntegerToString(SwingZZBackstep) +
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