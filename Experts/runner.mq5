//+------------------------------------------------------------------+
//|                                                       runner.mq5 |
//|           Non-stop S/R runner — simplified lets-go               |
//|                                                                  |
//|  Idea : one timeframe, S/R break OR reject (chip toggle, dynamic |
//|         mid-trade). Rests REAL broker stop/limit orders at the   |
//|         nearest pivot level, per direction. HEDGING account:     |
//|         one BUY slot + one SELL slot, both can be live at once,  |
//|         max 1 layer each.                                        |
//|                                                                  |
//|  Runner: REST-AHEAD. A pending is always pre-positioned at the   |
//|         broker for every direction that should hold one — empty  |
//|         slot = entry/hedge pending, profitable open layer = roll |
//|         pending resting at the next level ahead. A fast spike    |
//|         FILLS it (no race, no naked gap). On a roll fill the     |
//|         direction briefly holds 2 layers; the older/profitable   |
//|         one is banked, the runner kept — so it ladders and banks |
//|         (small or large) while staying 1 layer per direction.    |
//|         The LOSING side just runs; the banked winner cycles net  |
//|         against its floating loss.                               |
//|                                                                  |
//|  Exits: NO per-trade SL. The backstop is a set of stackable      |
//|         guards (OR — first to trip wins): global DD%, global     |
//|         DD money, or pips-per-layer (per-direction or global).   |
//|         A global DD guard is the disaster stop: it closes all    |
//|         AND latches BUY+SELL off until you re-enable them on the |
//|         panel. The pips guard does not latch. Optional offline   |
//|         hard SL (default off).                                   |
//|                                                                  |
//|  Panel: runner / TF / lot title, BUY/SELL/break/Flat, the        |
//|         session-guard row, and the risk-exit guard row. GV       |
//|         memory. Panel is runner-only (never on the base EAs).    |
//|                                                                  |
//|  Journal: Tag "runner #magic SYMBOL". Own magic so its history   |
//|           reads cleanly on a shared cent account.                |
//|                                                                  |
//|  TEST ON DEMO / STRATEGY TESTER FIRST. Not a profit guarantee.   |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "1.03"
// v1.03: Pending engine rebuilt clean (lets-go style) to kill the churn — a
//        resting order is placed once and left untouched intra-candle; when the
//        candle closes and the pivot has genuinely moved it is MOVED in place
//        with OrderModify (no delete+replace, no gap, no jumping). Nothing
//        resting + wanted -> placed instantly (instant re-arm after a fill).
//        A transient (no level for a tick) never drops a resting order.
// v1.02: Multi-layer WEB — MaxLayersPerDir (panel 'Lyr' chip, cycles 1..6). A
//        side accumulates up to N layers while its frontier layer is in profit;
//        ResolveDoubleLayers peels the OLDEST (deepest-profit) layer once the
//        count exceeds N (MaxLayersPerDir=1 = the v1.01 single-layer roll). The
//        pips guard now trips on the WORST layer and closes the whole side.
//        Manual SL-halt (panel 'SL halt' chip): drag an SL onto a layer; if any
//        layer's SL hits, the EA flattens ALL and disarms BUY/SELL until you
//        re-enable them — a manual emergency stop for the whole basket.
// v1.01: REST-AHEAD engine. Pendings are pre-positioned at the broker so a fast
//        spike fills them instead of racing a last-millisecond placement (the
//        v1.00 "bad stops" reject that left a naked, unhedged position).
//        ValidPendingLevel walks outward to the first placeable level (never
//        rejected). A profitable open layer keeps a ROLL pending resting ahead;
//        on fill the momentary 2-layer is collapsed by ResolveDoubleLayers —
//        bank the older if in profit, else abort — so it ladders and banks
//        (small or large) while always staying 1 layer per direction. Replaces
//        the v1.00 live-detect ManageRolls (which missed fast moves).

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_LABEL "runner"

//====================== ENUMS ======================
enum ENUM_PIP_SCOPE
{
   PIP_PER_DIR,  // pips guard closes only the offending direction
   PIP_GLOBAL    // pips guard closes both directions
};

//====================== INPUTS ======================
input group "===== Timeframe / Direction ====="
input ENUM_TIMEFRAMES InpT1       = PERIOD_CURRENT; // Signal timeframe (levels + roll clock)
input bool   TradeBuy             = true;   // Allow BUY slot
input bool   TradeSell            = true;   // Allow SELL slot

input group "===== Orders ====="
input double LotSize              = 0.01;   // Lots per layer
input long   MagicNumber          = 556677; // EA id (own history on a shared account)
input int    MaxSpreadPips        = 0;      // Skip new pendings above this spread (0 = ignore)
input int    SlippagePoints       = 20;     // Max deviation for market closes (points)
input int    HardSLPips           = 0;      // Optional OFFLINE broker SL, pips (0 = none; guards are the SL)

input group "===== S/R Pivot Levels ====="
input bool   StartBreakMode       = true;   // Panel mode default: true=break (stops), false=reject (limits)
input int    PivotLeftBars        = 10;     // Pivot left bars (match sr-breaks indicator)
input int    PivotRightBars       = 10;     // Pivot right bars (match sr-breaks indicator)
input int    LevelsLookback       = 100;    // Bars scanned for pivots
input double SrBufferPips          = 100;   // Break: beyond level by this. Reject: within this of level. 0 = exact

input group "===== Runner roll / web ====="
input double RollMinProfitPips     = 0;     // Min floating profit (pips) to arm a roll / add a web layer (0 = any profit)
input int    MaxLayersPerDir       = 1;     // Max layers per direction (1 = single roll; >1 = web). Panel Lyr chip cycles 1..6
input bool   UseManualSLHalt       = false; // Recognize a manually-set position SL: when any layer's SL hits -> close ALL + halt (grey BUY/SELL)

input group "===== Guards (stackable, OR — first to trip wins; all default OFF) ====="
// DD guards are GLOBAL: measured across BOTH legs' net floating, close everything.
// Pips guard: per-direction (close only the losing side) or global (close both).
input bool   UseGuardDDPct         = false; // Global drawdown-% guard
input double GuardDDPctValue       = 20;    // Close all when net floating <= -this % of base
input double AccountRiskBase       = 0;     // DD% base (0 = live account balance; else your allocation)
input bool   UseGuardDDMoney       = false; // Global drawdown-money guard
input double GuardDDMoneyValue     = 20;    // Close all when net floating <= -this (account currency)
input bool   UseGuardPips          = false; // Pips-per-layer guard
input double GuardPipsValue        = 1000;  // Close when a layer's floating <= -this (pips)
input ENUM_PIP_SCOPE GuardPipsScope = PIP_PER_DIR; // pips guard: per-dir (loss side) or global (both)

input group "===== Session Filter (WIB / Jakarta time) ====="
input bool UseSession          = true; // Enable daily trading-hours window
input int  SessionStartHour    = 6;    // Daily window FROM this hour WIB (0-23)
input int  SessionEndHour      = 3;    // NO new entries from this hour WIB (crosses midnight: 6->3)
input bool CloseAtSessionEnd   = true; // Flatten when outside the daily window (e.g. at 03:00)
input bool UseWeekendFilter    = true; // Block weekend gap (WIB)
input int  WeekendStopDayWIB   = 6;    // Weekend starts this day (0=Sun ... 5=Fri 6=Sat)
input int  WeekendStopHourWIB  = 3;    // ...from this hour (Sat 03:00 = after last Fri session)
input int  WeekendStartDayWIB  = 1;    // Weekend ends this day (1=Mon)
input int  WeekendStartHourWIB = 6;    // ...resume from this hour (Mon 06:00)
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
input bool InpDebugLog     = false; // Panel clicks + memory notes
input bool InpNotifyOnOpen = false; // Push notification on OPEN / ROLL

//====================== RUNTIME TOGGLES (panel + GV; inputs = defaults) ======================
bool           g_TradeBuy, g_TradeSell;
bool           g_SrBreakSel = true;   // true=break (stops), false=reject (limits)
int            g_MaxLayersPerDir = 1; // web depth per direction (chip-cycled 1..6)
bool           g_UseSLHalt = false;   // manual-SL recognition: SL hit -> close all + halt
bool           g_UseGuardDDPct, g_UseGuardDDMoney, g_UseGuardPips;
ENUM_PIP_SCOPE g_GuardPipsScope;
bool           g_UseSession, g_UseWeekendFilter, g_UseNewsFilter, g_UseBrokerSessionGuard;

#define MAX_LAYERS_CAP 6              // panel Lyr chip cycles 1..this

string g_gvPrefix       = "";
string g_panelPrefix    = "";
bool   g_panelCollapsed = false;
bool   g_quietInit      = false;      // TF-change reinit: keep logs quiet
ulong  g_panelLastClickMs = 0;
ulong  g_flatFlashUntilMs = 0;        // Flat chip: brief green flash after a click

// Per-category throttle for LogGuardOnce.
string   g_guardLogKeys[];
datetime g_guardLogTimes[];

//====================== GLOBALS ======================
ENUM_TIMEFRAMES g_t1;
double   g_pip = 0;
datetime g_lastBarTime = 0;           // per-candle latch clock (log cadence only)

// PENDING ENGINE tracking: one buy-side + one sell-side pending, never a
// same-side double. Only orders we placed (or adopted by comment tag) are
// tracked — reconcile never touches others.
#define PEND_MAX 2
ulong  g_pendTicket[PEND_MAX];
double g_pendLevel[PEND_MAX];
bool   g_pendIsBuy[PEND_MAX];
int    g_pendCount = 0;
datetime g_srRecalcBar = 0;           // levels-TF bar of the last relocate while orders rest

datetime g_lastEntryFailTime = 0;
datetime g_lastCloseFailTime = 0;

bool  g_newsBlackoutCached = false;
ulong g_newsLastCheckMs    = 0;
bool  g_slHaltPending      = false;   // a manual SL hit -> flatten + halt on next tick

//====================== LOGGING / PUSH ======================
string Tag() { return EA_LABEL + " #" + IntegerToString(MagicNumber) + " " + _Symbol; }
void LogInfo(const string msg)  { Print(Tag(), " | ", msg); }
void LogDebug(const string msg) { if(InpDebugLog) Print(Tag(), " | ", msg); }

void NotifyPush(const string msg)
{
   if(!SendNotification(Tag() + ": " + msg))
      LogInfo("PUSH FAILED - " + msg);
}

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

void LogDebugGuard(const string key, const string msg)
{
   if(!InpDebugLog) return;
   LogGuardOnce(key, "DBG " + msg);
}

//====================== PANEL STATE (GlobalVariables) ======================
// Memory: fingerprint Inputs; if unchanged restore last clicks, else reset.
// Scope: account + symbol + magic. GV keys are STABLE — never rename them.
void PanelInitPrefix()
{
   string sym = _Symbol;
   StringReplace(sym, ".", "_");
   g_gvPrefix = "RN_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "_"
              + sym + "_" + IntegerToString(MagicNumber) + "_";
   g_panelPrefix = "RNUI_" + IntegerToString(ChartID()) + "_";
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
   return "rn102|"
        + IntegerToString((int)TradeBuy) + IntegerToString((int)TradeSell) + "|"
        + IntegerToString((int)StartBreakMode) + "|"
        + IntegerToString(MaxLayersPerDir) + IntegerToString((int)UseManualSLHalt) + "|"
        + IntegerToString((int)UseGuardDDPct) + IntegerToString((int)UseGuardDDMoney)
        + IntegerToString((int)UseGuardPips) + IntegerToString((int)GuardPipsScope) + "|"
        + IntegerToString((int)UseSession) + IntegerToString((int)UseWeekendFilter)
        + IntegerToString((int)UseNewsFilter) + IntegerToString((int)UseBrokerSessionGuard);
}

void RuntimeApplyInputDefaults()
{
   g_TradeBuy = TradeBuy;
   g_TradeSell = TradeSell;
   g_SrBreakSel = StartBreakMode;
   g_MaxLayersPerDir = (int)MathMax(1, MathMin(MAX_LAYERS_CAP, MaxLayersPerDir));
   g_UseSLHalt = UseManualSLHalt;
   g_UseGuardDDPct = UseGuardDDPct;
   g_UseGuardDDMoney = UseGuardDDMoney;
   g_UseGuardPips = UseGuardPips;
   g_GuardPipsScope = GuardPipsScope;
   g_UseSession = UseSession;
   g_UseWeekendFilter = UseWeekendFilter;
   g_UseNewsFilter = UseNewsFilter;
   g_UseBrokerSessionGuard = UseBrokerSessionGuard;
}

void RuntimeSaveAllToGV()
{
   if(!PanelRemember) return;
   PanelSaveBool("Buy", g_TradeBuy);
   PanelSaveBool("Sell", g_TradeSell);
   PanelSaveBool("SrBR", g_SrBreakSel);
   PanelSaveInt("MaxLyr", g_MaxLayersPerDir);
   PanelSaveBool("SLhalt", g_UseSLHalt);
   PanelSaveBool("gDDp", g_UseGuardDDPct);
   PanelSaveBool("gDDm", g_UseGuardDDMoney);
   PanelSaveBool("gPip", g_UseGuardPips);
   PanelSaveInt("gScope", (int)g_GuardPipsScope);
   PanelSaveBool("Session", g_UseSession);
   PanelSaveBool("Weekend", g_UseWeekendFilter);
   PanelSaveBool("News", g_UseNewsFilter);
   PanelSaveBool("Broker", g_UseBrokerSessionGuard);
   PanelSaveBool("Collapsed", g_panelCollapsed);
}

void RuntimeLoadFromGV()
{
   g_TradeBuy = PanelLoadBool("Buy", g_TradeBuy);
   g_TradeSell = PanelLoadBool("Sell", g_TradeSell);
   g_SrBreakSel = PanelLoadBool("SrBR", g_SrBreakSel);
   g_MaxLayersPerDir = PanelLoadInt("MaxLyr", g_MaxLayersPerDir);
   g_UseSLHalt = PanelLoadBool("SLhalt", g_UseSLHalt);
   g_UseGuardDDPct = PanelLoadBool("gDDp", g_UseGuardDDPct);
   g_UseGuardDDMoney = PanelLoadBool("gDDm", g_UseGuardDDMoney);
   g_UseGuardPips = PanelLoadBool("gPip", g_UseGuardPips);
   g_GuardPipsScope = (ENUM_PIP_SCOPE)PanelLoadInt("gScope", (int)g_GuardPipsScope);
   g_UseSession = PanelLoadBool("Session", g_UseSession);
   g_UseWeekendFilter = PanelLoadBool("Weekend", g_UseWeekendFilter);
   g_UseNewsFilter = PanelLoadBool("News", g_UseNewsFilter);
   g_UseBrokerSessionGuard = PanelLoadBool("Broker", g_UseBrokerSessionGuard);
   g_panelCollapsed = PanelLoadBool("Collapsed", g_panelCollapsed);

   // Corrupt GV memory -> fall back to sane values.
   if(g_GuardPipsScope != PIP_PER_DIR && g_GuardPipsScope != PIP_GLOBAL)
      g_GuardPipsScope = PIP_PER_DIR;
   g_MaxLayersPerDir = (int)MathMax(1, MathMin(MAX_LAYERS_CAP, g_MaxLayersPerDir));
}

void RuntimeLoadFromInputsThenGV()
{
   PanelInitPrefix();
   RuntimeApplyInputDefaults();
   g_panelCollapsed = PanelStartCollapsed;

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
      if(!g_quietInit) LogDebug("PANEL memory restored (inputs unchanged)");
   }
   else
   {
      GlobalVariableSet(kFp, fpHash);
      RuntimeSaveAllToGV();
      if(!g_quietInit) LogDebug("PANEL defaults from Inputs (fresh or inputs changed)");
   }
}

void PanelClearMemory()
{
   string ids[] = {
      "INP_FP","Buy","Sell","SrBR","MaxLyr","SLhalt","Collapsed",
      "gDDp","gDDm","gPip","gScope",
      "Session","Weekend","News","Broker"
   };
   for(int i = 0; i < ArraySize(ids); i++)
      GlobalVariableDel(PanelGvKey(ids[i]));
}

//====================== CHIP PANEL UI ======================
string PanelObj(const string id) { return g_panelPrefix + id; }

bool PanelIsNonInteractiveId(const string id)
{
   return (id == "LG" || id == "LR");
}

void PanelDeleteAll()
{
   if(StringLen(g_panelPrefix) == 0)
      g_panelPrefix = "RNUI_" + IntegerToString(ChartID()) + "_";
   ObjectsDeleteAll(0, g_panelPrefix);
}

// Panel palette — single source for every chip color (shared with lets-go).
const color PNL_MODE_BG   = C'36,52,68';    // mode chip (always clickable, blue)
const color PNL_MODE_FG   = C'220,235,250';
const color PNL_MODE_BD   = C'70,110,140';
const color PNL_ON_BG     = C'40,110,92';   // toggle ON (green); also status OPEN, Flat press-flash
const color PNL_ON_FG     = C'235,255,248';
const color PNL_ON_BD     = C'80,160,130';
const color PNL_OFF_BG    = C'48,48,48';    // toggle OFF (gray)
const color PNL_OFF_FG    = C'160,160,160';
const color PNL_OFF_BD    = C'36,36,36';
const color PNL_DIS_BG    = C'32,32,32';    // locked / disabled
const color PNL_DIS_FG    = C'90,90,90';
const color PNL_DIS_BD    = C'28,28,28';
const color PNL_BLOCK_BG  = C'130,55,55';   // status BLOCK + Flat resting (red)
const color PNL_BLOCK_BD  = C'175,75,75';
const color PNL_STATUS_FG = C'245,245,245';

void PanelStyleChip(const string name, const string text, const string tip,
                    const bool on, const bool isModeChip)
{
   color bg, fg, bd;
   if(isModeChip)      { bg = PNL_MODE_BG; fg = PNL_MODE_FG; bd = PNL_MODE_BD; }
   else if(on)         { bg = PNL_ON_BG;   fg = PNL_ON_FG;   bd = PNL_ON_BD;   }
   else                { bg = PNL_OFF_BG;  fg = PNL_OFF_FG;  bd = PNL_OFF_BD;  }

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

// Flat = manual close-all ACTION button (not a toggle): brick-red at rest,
// brief green flash right after a click, then back to red.
void PanelStyleAction(const string name, const string text, const string tip, const bool flashing)
{
   ObjectSetString (0, name, OBJPROP_TEXT, text);
   ObjectSetString (0, name, OBJPROP_TOOLTIP, tip);
   ObjectSetInteger(0, name, OBJPROP_COLOR, PNL_STATUS_FG);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, flashing ? PNL_ON_BG : PNL_BLOCK_BG);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, flashing ? PNL_ON_BD : PNL_BLOCK_BD);
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

// Short timeframe tag for the title ("PERIOD_M1" -> "M1").
string TfText(const ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   int u = StringFind(s, "_");
   return (u >= 0) ? StringSubstr(s, u + 1) : s;
}

string SrBrChipText() { return g_SrBreakSel ? "break" : "reject"; }
string SrBrChipTip()
{
   return g_SrBreakSel
      ? "Break mode: rest STOP orders beyond the level. Click for reject (limits)"
      : "Reject mode: rest LIMIT orders at the level. Click for break (stops)";
}

string PipScopeChipText() { return (g_GuardPipsScope == PIP_PER_DIR) ? "per-dir" : "global"; }
string PipScopeChipTip()
{
   return (g_GuardPipsScope == PIP_PER_DIR)
      ? "Pips guard closes ONLY the losing direction. Click for global (both)"
      : "Pips guard closes BOTH directions. Click for per-dir (loss side only)";
}

//====================== PANEL PAINT ======================
void PanelPaintState()
{
   if(!ShowPanel) return;
   if(g_panelCollapsed)
   {
      PanelStyleChip(PanelObj("TTL"),
         EA_LABEL + "  " + TfText(g_t1) + "  " + DoubleToString(LotSize, 2) + "  <",
         "Click to expand panel", true, true);
      return;
   }

   // Title: name / timeframe / lot. Doubles as collapse toggle.
   PanelStyleChip(PanelObj("TTL"),
      EA_LABEL + "  " + TfText(g_t1) + "  " + DoubleToString(LotSize, 2) + "  v",
      "runner — timeframe " + TfText(g_t1) + ", lot " + DoubleToString(LotSize, 2)
      + ". Click to collapse", true, true);

   // Mode row: BUY / SELL / break / Flat.
   PanelStyleChip(PanelObj("BUY"),  "BUY",  "BUY slot ON/OFF (arms buy pendings)",  g_TradeBuy,  false);
   PanelStyleChip(PanelObj("SELL"), "SELL", "SELL slot ON/OFF (arms sell pendings)", g_TradeSell, false);
   PanelStyleChip(PanelObj("SrBR"), SrBrChipText(), SrBrChipTip(), false, true);
   PanelStyleAction(PanelObj("Flat"), "Flat", "Close ALL runner positions now (manual)",
                    GetTickCount64() < g_flatFlashUntilMs);

   // Control row: manual-SL halt toggle + web depth (max layers per direction).
   PanelStyleChip(PanelObj("SLhalt"), "SL halt",
      "Manual SL recognition: drag an SL onto a layer (outside the range) — if any layer's SL hits, close ALL + halt BUY/SELL",
      g_UseSLHalt, false);
   PanelStyleChip(PanelObj("Lyr"), "Lyr " + IntegerToString(g_MaxLayersPerDir),
      "Web depth: max layers per direction = " + IntegerToString(g_MaxLayersPerDir)
      + " (1 = single roll). Click to cycle 1.." + IntegerToString(MAX_LAYERS_CAP), false, true);

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
                    "Entry-guard status: OPEN = clear to place pendings, BLOCK = a guard holds entries");
   PanelStyleChip(PanelObj("Session"), "Session", "Session guard ON/OFF", g_UseSession, false);
   PanelStyleChip(PanelObj("Weekend"), "Weekend", "Weekend guard ON/OFF", g_UseWeekendFilter, false);
   PanelStyleChip(PanelObj("News"), "News", "News guard ON/OFF", g_UseNewsFilter, false);
   PanelStyleChip(PanelObj("Broker"), "Broker", "Broker session guard ON/OFF", g_UseBrokerSessionGuard, false);

   // Risk-exit guards: DD% / DD$ / pips arm-chips + pips scope.
   PanelStyleChip(PanelObj("LR"), " risk exits", "Backstop guards (first to trip closes)", true, true);
   PanelStyleChip(PanelObj("gDDp"), "DD%",  "Global drawdown-% guard ON/OFF (closes all)",     g_UseGuardDDPct,   false);
   PanelStyleChip(PanelObj("gDDm"), "DD$",  "Global drawdown-money guard ON/OFF (closes all)", g_UseGuardDDMoney, false);
   PanelStyleChip(PanelObj("gPip"), "pips", "Pips-per-layer guard ON/OFF",                     g_UseGuardPips,    false);
   if(g_UseGuardPips)
      PanelStyleChip(PanelObj("gScope"), PipScopeChipText(), PipScopeChipTip(), false, true);
   else
      PanelStyleDisabled(PanelObj("gScope"), PipScopeChipText(), "Pips guard OFF");
}

void PanelBuild()
{
   if(!ShowPanel) { PanelDeleteAll(); return; }
   if(StringLen(g_panelPrefix) == 0)
      PanelInitPrefix();

   const int chipW      = 66;
   const int chipH      = 19;
   const int gap        = 3;
   const int sectionGap = 2;
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
   string modeIds[] = { "BUY", "SELL", "SrBR", "Flat" };
   PanelPlaceEvenRow(modeIds, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap;

   // Control row (below BUY/SELL, above the guards): SL-halt toggle + web depth.
   // Two half-width chips.
   const int halfW = (rowW - gap) / 2;
   PanelEnsureButton("SLhalt", x0, y, halfW, chipH);
   PanelEnsureButton("Lyr", x0 + halfW + gap, y, rowW - halfW - gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("LG", x0, y, rowW, chipH); y += chipH + gap;
   string guards[] = { "Session", "Weekend", "News", "Broker" };
   PanelPlaceEvenRow(guards, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("LR", x0, y, rowW, chipH); y += chipH + gap;
   string risk[] = { "gDDp", "gDDm", "gPip", "gScope" };
   PanelPlaceEvenRow(risk, 4, x0, y, rowW, gap, chipH);

   string liveIds[] = {
      "TTL","BUY","SELL","SrBR","Flat","SLhalt","Lyr","LG",
      "Session","Weekend","News","Broker","LR",
      "gDDp","gDDm","gPip","gScope"
   };
   PanelPruneOrphans(liveIds);

   PanelPaintState();
}

// Delete any panel button/label whose id is not in this build's live set.
void PanelPruneOrphans(const string &liveIds[])
{
   int total = ObjectsTotal(0, -1, OBJ_BUTTON);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, OBJ_BUTTON);
      if(StringFind(name, g_panelPrefix) != 0) continue;
      string id = StringSubstr(name, StringLen(g_panelPrefix));
      bool live = false;
      for(int j = 0; j < ArraySize(liveIds); j++)
         if(liveIds[j] == id) { live = true; break; }
      if(!live) ObjectDelete(0, name);
   }
}

//====================== PANEL CLICK ======================
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
   else if(id == "BUY")  PanelToggleBool(g_TradeBuy, "Buy");
   else if(id == "SELL") PanelToggleBool(g_TradeSell, "Sell");
   else if(id == "SrBR")
   {
      g_SrBreakSel = !g_SrBreakSel; // break <-> reject, dynamic mid-trade
      PanelSaveBool("SrBR", g_SrBreakSel);
   }
   else if(id == "Flat")
   {
      g_flatFlashUntilMs = GetTickCount64() + 300; // green press-flash
      CloseAllEA("panel flat");
      if(g_pendCount > 0) DeleteOurPendings("panel flat");
   }
   else if(id == "SLhalt") PanelToggleBool(g_UseSLHalt, "SLhalt");
   else if(id == "Lyr")
   {
      g_MaxLayersPerDir = (g_MaxLayersPerDir >= MAX_LAYERS_CAP) ? 1 : g_MaxLayersPerDir + 1;
      PanelSaveInt("MaxLyr", g_MaxLayersPerDir);
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
   else if(id == "gDDp") PanelToggleBool(g_UseGuardDDPct, "gDDp");
   else if(id == "gDDm") PanelToggleBool(g_UseGuardDDMoney, "gDDm");
   else if(id == "gPip") PanelToggleBool(g_UseGuardPips, "gPip");
   else if(id == "gScope")
   {
      if(!g_UseGuardPips) return true; // scope locked while pips guard OFF
      g_GuardPipsScope = (g_GuardPipsScope == PIP_PER_DIR) ? PIP_GLOBAL : PIP_PER_DIR;
      PanelSaveInt("gScope", (int)g_GuardPipsScope);
   }
   else changed = false;

   if(changed)
   {
      if(needFullBuild) PanelBuild();
      else PanelPaintState();
      ChartRedraw(0);
      if(!g_quietInit) LogDebug("PANEL " + id);
   }
   return true;
}

// Strategy Tester does NOT call OnChartEvent: poll button pressed state.
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

   if(PivotLeftBars < 1 || PivotRightBars < 1)
   {
      LogInfo("INIT FAILED - PivotLeftBars/PivotRightBars must be >= 1");
      NotifyPush("INIT FAILED - PivotLeftBars/PivotRightBars must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(!g_TradeBuy && !g_TradeSell && !g_quietInit)
      LogInfo("NOTE Buy and Sell both off — enable from panel/inputs to trade.");

   g_pip = PipSize();
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   AdoptOurPendings(); // re-track orders a previous attach left resting

   if(!g_quietInit)
   {
      LogInfo("INIT T1=" + EnumToString(g_t1)
              + " mode=" + (g_SrBreakSel ? "break" : "reject")
              + " layers=" + IntegerToString(g_MaxLayersPerDir)
              + " SLhalt=" + (g_UseSLHalt ? "ON" : "off")
              + " | Buy=" + (g_TradeBuy ? "ON" : "OFF")
              + " Sell=" + (g_TradeSell ? "ON" : "OFF")
              + " | guards DD%=" + (g_UseGuardDDPct ? "ON" : "off")
              + " DD$=" + (g_UseGuardDDMoney ? "ON" : "off")
              + " pips=" + (g_UseGuardPips ? ("ON/" + PipScopeChipText()) : "off")
              + " | HardSL=" + (HardSLPips > 0 ? IntegerToString(HardSLPips) + "p" : "off")
              + " | panel=" + (ShowPanel ? "ON" : "off"));
      if(_Period != g_t1)
         LogInfo("NOTE chart TF differs from T1 (" + EnumToString(g_t1) + "). Levels run on T1.");
   }

   PanelBuild();
   EventSetTimer(1);
   if(!g_quietInit) ChartRedraw(0);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   if(reason != REASON_CHARTCHANGE)
      PanelDeleteAll();

   if(reason == REASON_REMOVE && PanelRemember)
      PanelClearMemory();

   // Deliberate remove = pull our resting orders too (nothing left unmanaged).
   if(reason == REASON_REMOVE && g_pendCount > 0)
      DeleteOurPendings("EA removed");
}

void OnTimer()
{
   if(!ShowPanel) return;
   if(StringLen(g_panelPrefix) == 0) PanelInitPrefix();
   PanelPollClicks();
   if(ObjectFind(0, PanelObj("TTL")) < 0)
   {
      PanelBuild();
      ChartRedraw(0);
   }
   else if(!g_panelCollapsed)
   {
      PanelPaintState(); // refresh OPEN/BLOCK + Flat flash without a click
      ChartRedraw(0);
   }
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
      PanelHandleClick(sparam);
}

void OnTick()
{
   PanelPollClicks();

   // Per-candle latch clock — used only for once-per-bar log cadence.
   datetime bt[];
   if(CopyTime(_Symbol, g_t1, 0, 1, bt) == 1 && bt[0] != g_lastBarTime)
      g_lastBarTime = bt[0];

   if(ShouldCloseForSchedule())
   {
      CloseAllEA("session/weekend/news schedule");
      if(g_pendCount > 0) DeleteOurPendings("schedule close");
      return;
   }

   // Manual SL was hit (flagged in the trade-transaction handler): flatten the
   // rest of the book and latch BUY/SELL off — your dragged SL is the emergency
   // stop for the whole basket.
   if(g_slHaltPending)
   {
      g_slHaltPending = false;
      CloseAllEA("manual SL hit");
      if(g_pendCount > 0) DeleteOurPendings("manual SL hit");
      LatchHalt("MANUAL SL");
      return;
   }

   ResolveDoubleLayers(); // peel the web back to MaxLayersPerDir (bank oldest winner)
   ManageGuards();        // DD% / DD$ / pips backstop — may close
   ManagePendings();      // rest-ahead broker pendings: entry hedge + web ladder
}

//====================== SESSION (WIB inputs; true Jakarta via GMT) ======================
void GetWIBTime(MqlDateTime &dt)
{
   TimeToStruct(TimeGMT() + 7 * 3600, dt); // WIB = UTC+7 fixed (no DST)
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

//====================== S/R PIVOT LEVELS ======================
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

// The broker-VALID pending price a direction wants right now, given the mode.
// Walks OUTWARD from price to the first pivot level whose order price clears
// the broker stops-level — so if the nearest level is already breached / too
// close (the "bad stops" reject that leaves a naked position), it skips to the
// next level out and always returns a placeable price. This is the whole
// safety fix: a hedge/roll pending is pre-positioned and never rejected.
//   break  buy : level ABOVE  -> buy  STOP  at level + buf  (walk up)
//   break  sell: level BELOW  -> sell STOP  at level - buf  (walk down)
//   reject buy : level BELOW  -> buy  LIMIT at level + buf  (walk down)
//   reject sell: level ABOVE  -> sell LIMIT at level - buf  (walk up)
// Fetch MORE than LevelsLookback by the pivot margin so a pivot at the oldest
// edge can still be confirmed and LevelsLookback means what it says (matches
// the sr-breaks indicator's real reach — same fix as lets-go).
bool ValidPendingLevel(const bool isBuy, double &price, bool &isStop)
{
   price = 0; isStop = g_SrBreakSel;
   const double buf   = MathMax(0.0, SrBufferPips) * g_pip;
   const double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   const double px    = 0.5 * (ask + bid);

   int need = LevelsLookback + PivotLeftBars + PivotRightBars;
   MqlRates rates[];
   int got = CopyRates(_Symbol, g_t1, 0, need, rates);
   if(got < PivotLeftBars + PivotRightBars + 3)
   { LogDebugGuard("dbg_sr", "ValidPendingLevel: not enough bars yet"); return false; }

   int total = got;
   int lastCompleted = total - 2;
   int startBar = MathMax(PivotLeftBars, total - LevelsLookback);

   // collect every confirmed pivot price into one list, then sort ascending
   double lv[]; int n = 0;
   for(int i = startBar; i <= lastCompleted; i++)
   {
      int pivotIdx = i - PivotRightBars;
      if(pivotIdx < PivotLeftBars) continue;
      if(pivotIdx + PivotRightBars > lastCompleted) continue;
      if(IsPivotHighAt_Rates(rates, pivotIdx, total, PivotLeftBars, PivotRightBars))
      { ArrayResize(lv, n + 1); lv[n] = rates[pivotIdx].high; n++; }
      if(IsPivotLowAt_Rates(rates, pivotIdx, total, PivotLeftBars, PivotRightBars))
      { ArrayResize(lv, n + 1); lv[n] = rates[pivotIdx].low; n++; }
   }
   if(n == 0)
   { LogDebugGuard("dbg_sr", "ValidPendingLevel: no pivots found yet"); return false; }
   ArraySort(lv); // ascending

   // wantAbove: break buy / reject sell -> levels above; else levels below.
   const bool wantAbove = (g_SrBreakSel == isBuy);
   if(wantAbove)
   {
      for(int k = 0; k < n; k++) // ascending: nearest above first, then out
      {
         if(lv[k] <= px) continue;
         double cand = NormalizePrice(isBuy ? lv[k] + buf : lv[k] - buf);
         bool ok = isStop ? (cand - ask > minStop)   // break  buy  stop  (above market)
                          : (cand - bid > minStop);  // reject sell limit (above market)
         if(ok) { price = cand; return true; }
      }
   }
   else
   {
      for(int k = n - 1; k >= 0; k--) // descending: nearest below first, then out
      {
         if(lv[k] >= px) continue;
         double cand = NormalizePrice(isBuy ? lv[k] + buf : lv[k] - buf);
         bool ok = isStop ? (bid - cand > minStop)   // break  sell stop  (below market)
                          : (ask - cand > minStop);  // reject buy  limit (below market)
         if(ok) { price = cand; return true; }
      }
   }
   return false; // no placeable level on that side yet
}

//====================== POSITION / PENDING HELPERS ======================
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

// How many layers this direction holds (multi-layer web).
int DirectionLayerCount(const bool isBuy)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) == isBuy) count++;
   }
   return count;
}

// Floating pips of the NEWEST (frontier) layer — gates whether the web adds
// another layer (only extend a side that is pushing into profit).
double DirectionFrontFloatPips(const bool isBuy)
{
   ulong newest = 0; double entry = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) != isBuy) continue;
      if(tk > newest) { newest = tk; entry = PositionGetDouble(POSITION_PRICE_OPEN); }
   }
   if(newest == 0) return 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   return isBuy ? (bid - entry) / g_pip : (entry - ask) / g_pip;
}

// Worst (most negative) single-layer floating pips on a direction — the pips
// guard trips on the worst layer of the web. Returns 0 if the side is flat.
double DirectionWorstLayerPips(const bool isBuy)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double worst = 0; bool any = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) != isBuy) continue;
      double e = PositionGetDouble(POSITION_PRICE_OPEN);
      double fp = isBuy ? (bid - e) / g_pip : (e - ask) / g_pip;
      if(!any || fp < worst) { worst = fp; any = true; }
   }
   return any ? worst : 0;
}

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
      g_pendTicket[i] = g_pendTicket[i + 1];
      g_pendLevel[i]  = g_pendLevel[i + 1];
      g_pendIsBuy[i]  = g_pendIsBuy[i + 1];
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
      PendUntrackIndex(i);
   }
}

// Delete just one direction's resting pending (leave the opposite side alone).
void DeleteDirectionPending(const bool isBuy, const string reason)
{
   for(int i = g_pendCount - 1; i >= 0; i--)
   {
      if(g_pendIsBuy[i] != isBuy) continue;
      if(OrderSelect(g_pendTicket[i]))
      {
         if(!trade.OrderDelete(g_pendTicket[i]))
         {
            LogGuardOnce("fail_pend_del", "FAIL pending delete rc=" + IntegerToString(trade.ResultRetcode())
                         + " " + trade.ResultRetcodeDescription());
            continue;
         }
         LogInfo("PEND DEL " + (isBuy ? "BUY" : "SELL") + " @ "
                 + DoubleToString(g_pendLevel[i], _Digits) + " (" + reason + ")");
      }
      PendUntrackIndex(i);
   }
}

// Re-attach safety: pick up orders a previous attach left resting.
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
      if(StringFind(cm, "runner pend") < 0) continue;
      g_pendTicket[g_pendCount] = tk;
      g_pendLevel[g_pendCount]  = OrderGetDouble(ORDER_PRICE_OPEN);
      g_pendIsBuy[g_pendCount]  = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT);
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
   // No per-trade SL/TP by default (guards are the backstop). HardSLPips, if
   // set, adds an OFFLINE broker SL as a safety net only.
   double sl = 0;
   if(HardSLPips > 0)
      sl = isBuy ? NormalizePrice(lvl - HardSLPips * g_pip)
                 : NormalizePrice(lvl + HardSLPips * g_pip);

   const string cm = "runner pend sr";
   bool ok;
   if(isBuy)  ok = isStop ? trade.BuyStop(lots, lvl, _Symbol, sl, 0, ORDER_TIME_GTC, 0, cm)
                          : trade.BuyLimit(lots, lvl, _Symbol, sl, 0, ORDER_TIME_GTC, 0, cm);
   else       ok = isStop ? trade.SellStop(lots, lvl, _Symbol, sl, 0, ORDER_TIME_GTC, 0, cm)
                          : trade.SellLimit(lots, lvl, _Symbol, sl, 0, ORDER_TIME_GTC, 0, cm);
   if(ok && trade.ResultOrder() > 0)
   {
      g_pendTicket[g_pendCount] = trade.ResultOrder();
      g_pendLevel[g_pendCount]  = lvl;
      g_pendIsBuy[g_pendCount]  = isBuy;
      g_pendCount++;
      LogInfo("PEND SET " + (isBuy ? "BUY " : "SELL ") + (isStop ? "STOP" : "LIMIT")
              + " @ " + DoubleToString(lvl, _Digits)
              + (sl > 0 ? " | offline SL " + DoubleToString(sl, _Digits) : ""));
   }
   else
   {
      g_lastEntryFailTime = TimeCurrent();
      LogGuardOnce("fail_pend", "FAIL pending rc=" + IntegerToString(trade.ResultRetcode())
                   + " " + trade.ResultRetcodeDescription());
   }
}

// Find this direction's resting pending (-1 if none). One per direction.
int PendIndexForDir(const bool isBuy)
{
   for(int i = 0; i < g_pendCount; i++)
      if(g_pendIsBuy[i] == isBuy) return i;
   return -1;
}

// Move a resting pending to a new level IN PLACE (OrderModify) — no cancel, no
// gap. Keeps the offline SL aligned to the new level if HardSLPips is set.
void RelocatePending(const int idx, const double newLvl)
{
   double np = NormalizePrice(newLvl);
   double sl = 0;
   if(HardSLPips > 0)
      sl = g_pendIsBuy[idx] ? NormalizePrice(np - HardSLPips * g_pip)
                            : NormalizePrice(np + HardSLPips * g_pip);
   if(trade.OrderModify(g_pendTicket[idx], np, sl, 0, ORDER_TIME_GTC, 0))
   {
      LogInfo("PEND MOVE " + (g_pendIsBuy[idx] ? "BUY" : "SELL") + " "
              + DoubleToString(g_pendLevel[idx], _Digits) + " -> " + DoubleToString(np, _Digits));
      g_pendLevel[idx] = np;
   }
   else
      LogGuardOnce("fail_pend_mod", "FAIL pending modify rc=" + IntegerToString(trade.ResultRetcode())
                   + " " + trade.ResultRetcodeDescription());
}

//====================== PENDING ENGINE (lets-go clean: place once, move in place) ======================
// The rule, per direction — fast and stable, like lets-go's S/R engine:
//   * Nothing resting and one is wanted -> PLACE it now (instant; so re-arming
//     after a fill/peel is immediate).
//   * One already resting -> LEAVE IT untouched intra-candle. No re-place, no
//     cancel, no jumping. When the candle CLOSES and the pivot has genuinely
//     moved, MOVE the order in place with OrderModify (never delete+replace).
//   * A transient (no valid level for a tick, price hugging the level) NEVER
//     drops a resting order — it just stays.
//   * Deleted only when the direction stops wanting one: disarmed (now), or its
//     frontier went to loss / hit the web cap (on the next candle).
// "Wanted" per direction: EMPTY armed side -> entry/hedge pending; OCCUPIED
// armed side -> a web/roll pending while its frontier layer is in profit.
void ManagePendings()
{
   // sync tracked list with the broker (fills fall out here; also catches
   // orders deleted by hand in the terminal)
   for(int i = g_pendCount - 1; i >= 0; i--)
      if(!OrderSelect(g_pendTicket[i])) PendUntrackIndex(i);

   // Entries paused: pull everything, but leave open positions running.
   if(!InSession() || !CanAttemptEntry())
   { if(g_pendCount > 0) DeleteOurPendings("entry blocked"); return; }

   const datetime curBar = iTime(_Symbol, g_t1, 0);
   const bool newBar = (curBar != g_srRecalcBar);
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int s = 0; s < 2; s++)
   {
      bool isBuy = (s == 0);
      int  ri    = PendIndexForDir(isBuy);
      bool armed = isBuy ? g_TradeBuy : g_TradeSell;

      // Does this direction want a pending right now?
      bool want = false;
      if(armed)
      {
         if(DirectionLayerCount(isBuy) == 0) want = true;                       // entry / hedge
         else if(DirectionFrontFloatPips(isBuy) >= RollMinProfitPips) want = true; // web / roll
      }

      if(!want)
      {
         // Pull a resting order only on a fresh decision: disarmed = now;
         // frontier-went-to-loss / cap = on the next candle (no intra-bar churn).
         if(ri >= 0 && (!armed || newBar))
            DeleteDirectionPending(isBuy, armed ? "no longer wanted" : "disarmed");
         continue;
      }

      double lvl = 0; bool isStop = true;
      bool haveLvl = ValidPendingLevel(isBuy, lvl, isStop);

      if(ri < 0)
      {
         // Nothing resting -> place immediately (instant re-arm).
         if(haveLvl) PlacePendingOrder(isBuy, isStop, lvl);
         continue;
      }

      // Already resting: leave it be. Only when the candle closes and the level
      // has actually changed do we MOVE it in place — no delete, no gap.
      if(newBar && haveLvl && MathAbs(g_pendLevel[ri] - lvl) > point * 0.5)
         RelocatePending(ri, lvl);
   }

   g_srRecalcBar = curBar; // advance the relocation clock once per pass
}

//====================== ROLL / WEB CAP (peel back to MaxLayersPerDir) ======================
// A frontier pending filled -> a direction may exceed its web depth. While the
// layer count is within MaxLayersPerDir the whole web is kept (it runs like a
// web). Once it EXCEEDS the cap, bank the OLDEST (deepest-profit) layer if it
// is in profit — that is the "hit level -> profit close"; otherwise close the
// just-filled one (abort — never bank a loss, never stack past the cap). With
// MaxLayersPerDir=1 this is the plain single-layer roll. Runs first each tick
// so guards/pendings see a settled book. Ticket order is monotonic, so the
// smaller ticket is the older layer.
void ResolveDoubleLayers()
{
   for(int s = 0; s < 2; s++)
   {
      bool isBuy = (s == 0);
      ulong older = 0, newer = 0;
      int cnt = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         bool posBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         if(posBuy != isBuy) continue;
         cnt++;
         if(older == 0 || tk < older) older = tk;
         if(newer == 0 || tk > newer) newer = tk;
      }
      if(cnt <= g_MaxLayersPerDir) continue; // web within its depth — keep all layers

      if(!CanAttemptClose())
      { LogGuardOnce("swap_blocked", "BLOCKED roll swap — trade path guard; will retry"); continue; }

      // Over the web cap: bank the OLDEST (deepest-profit) layer if in profit,
      // else abort the newest. With MaxLayersPerDir=1 this is the plain roll.
      // Older in profit -> bank it (roll). Else close the newer (abort).
      double olderEntry = 0, olderPips = 0, olderPL = 0;
      if(PositionSelectByTicket(older))
      {
         olderEntry = PositionGetDouble(POSITION_PRICE_OPEN);
         olderPL    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         olderPips  = isBuy ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - olderEntry) / g_pip
                            : (olderEntry - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / g_pip;
      }

      if(olderPips > RollMinProfitPips)
      {
         if(trade.PositionClose(older))
         {
            string msg = "ROLL " + (isBuy ? "BUY" : "SELL") + " banked +"
                       + DoubleToString(olderPips, 1) + "p | P/L " + DoubleToString(olderPL, 2)
                       + " | runner laddered to new level";
            LogInfo(msg);
            if(InpNotifyOnOpen) NotifyPush(msg);
         }
         else
         {
            g_lastCloseFailTime = TimeCurrent();
            LogGuardOnce("fail_swap", "FAIL roll bank rc=" + IntegerToString(trade.ResultRetcode())
                         + " " + trade.ResultRetcodeDescription());
         }
      }
      else
      {
         if(trade.PositionClose(newer))
            LogInfo("ROLL ABORT " + (isBuy ? "BUY" : "SELL") + " — older not in profit ("
                    + DoubleToString(olderPips, 1) + "p); kept the runner");
         else
         {
            g_lastCloseFailTime = TimeCurrent();
            LogGuardOnce("fail_swap", "FAIL roll abort rc=" + IntegerToString(trade.ResultRetcode())
                         + " " + trade.ResultRetcodeDescription());
         }
      }
   }
}

//====================== GUARDS (DD% / DD$ / pips — OR, first to trip) ======================
// Net floating P/L (money) of THIS EA's open positions, filtered by magic.
// Both legs combined. Realized/banked profit is already in the balance and is
// NOT counted here — this is the live floating figure only.
double NetFloatingMoney(int &count)
{
   double net = 0; count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      net += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      count++;
   }
   return net;
}

// DISASTER halt: after everything is closed, LATCH the EA off (disarm BUY +
// SELL) so runner does not walk straight back into the same hole. Click BUY /
// SELL on the panel to resume. Used by the global DD guards and by the manual
// SL-halt. The pips guard does NOT latch — it is a per-layer stop, re-entry at
// a fresh level is the strategy.
void LatchHalt(const string which)
{
   g_TradeBuy = false;
   g_TradeSell = false;
   PanelSaveBool("Buy", false);
   PanelSaveBool("Sell", false);
   string msg = which + " HALT — BUY+SELL disarmed; re-enable on the panel to resume";
   LogInfo(msg);
   NotifyPush(msg);
   if(ShowPanel && !g_panelCollapsed) { PanelPaintState(); ChartRedraw(0); }
}

void ManageGuards()
{
   int count = 0;
   double net = NetFloatingMoney(count);
   if(count == 0) return;

   // --- Global DD money: close everything, then latch off ---
   if(g_UseGuardDDMoney && GuardDDMoneyValue > 0 && net <= -GuardDDMoneyValue)
   {
      CloseAllEA("guard DD$ " + DoubleToString(net, 2) + " <= -" + DoubleToString(GuardDDMoneyValue, 2));
      if(g_pendCount > 0) DeleteOurPendings("guard DD$");
      LatchHalt("GUARD DD$");
      return;
   }

   // --- Global DD percent: close everything, then latch off ---
   if(g_UseGuardDDPct && GuardDDPctValue > 0)
   {
      double base = (AccountRiskBase > 0) ? AccountRiskBase : AccountInfoDouble(ACCOUNT_BALANCE);
      if(base > 0)
      {
         double pct = net / base * 100.0;
         if(pct <= -GuardDDPctValue)
         {
            CloseAllEA("guard DD% " + DoubleToString(pct, 2) + "% <= -" + DoubleToString(GuardDDPctValue, 2) + "%");
            if(g_pendCount > 0) DeleteOurPendings("guard DD%");
            LatchHalt("GUARD DD%");
            return;
         }
      }
   }

   // --- Pips per layer: per-direction (loss side only) or global (both) ---
   if(g_UseGuardPips && GuardPipsValue > 0)
   {
      // Guard protects ALL open positions — a disarmed BUY/SELL chip stops new
      // entries, it does not stop guarding a position that is still running.
      // In a web, the guard trips on the WORST single layer of the direction.
      bool haveBuy  = (DirectionLayerCount(true)  > 0);
      bool haveSell = (DirectionLayerCount(false) > 0);
      double buyPips  = haveBuy  ? DirectionWorstLayerPips(true)  : 0;
      double sellPips = haveSell ? DirectionWorstLayerPips(false) : 0;
      bool buyHit  = haveBuy  && buyPips  <= -GuardPipsValue;
      bool sellHit = haveSell && sellPips <= -GuardPipsValue;

      if(buyHit || sellHit)
      {
         if(g_GuardPipsScope == PIP_GLOBAL)
         {
            CloseAllEA("guard pips global " + DoubleToString(GuardPipsValue, 0) + "p");
            if(g_pendCount > 0) DeleteOurPendings("guard pips");
         }
         else
         {
            if(buyHit)  { CloseDirection(true,  "guard pips BUY -" + DoubleToString(GuardPipsValue, 0) + "p");
                          DeleteDirectionPending(true,  "guard pips"); }
            if(sellHit) { CloseDirection(false, "guard pips SELL -" + DoubleToString(GuardPipsValue, 0) + "p");
                          DeleteDirectionPending(false, "guard pips"); }
         }
      }
   }
}

//====================== TRADE TRANSACTIONS ======================
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

   // A pending of ours filled: untrack it and log the open. If this was a roll
   // fill the direction now holds two layers — ResolveDoubleLayers (next tick,
   // and it runs first) banks the older/profitable one. We do NO trade ops here
   // (closing from inside OnTradeTransaction is re-entrant/unsafe).
   int idx = PendFindByOrder((ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER));
   if(idx < 0) return; // not one of ours (all entries are pendings)
   const bool isBuy = g_pendIsBuy[idx];
   const double lvl = g_pendLevel[idx];
   PendUntrackIndex(idx);
   string msg = "OPEN " + (isBuy ? "BUY" : "SELL") + " "
              + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_VOLUME), 2)
              + " @ " + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PRICE), _Digits)
              + " | pending fill at level " + DoubleToString(lvl, _Digits);
   LogInfo(msg);
   if(InpNotifyOnOpen) NotifyPush(msg);
}

// Broker-side SL/stop-out fill (a manually-dragged SL, or HardSLPips): give it
// a Journal + push line so it is not a silent close. If the SL-halt feature is
// on, flag a full halt — OnTick flattens the rest + disarms BUY/SELL next tick
// (trade ops here would be re-entrant).
void NotifyBrokerClose(const ulong dealTicket)
{
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
   string tag;
   switch(reason)
   {
      case DEAL_REASON_SL: tag = "SL hit";   break;
      case DEAL_REASON_SO: tag = "stop out"; break;
      default: return; // EXPERT close is logged where it happens
   }
   double dealPL = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   string msg = "POSITION CLOSED (" + tag + ") | Net P/L: " + DoubleToString(dealPL, 2);
   LogInfo(msg);
   NotifyPush(msg);

   if(g_UseSLHalt && (reason == DEAL_REASON_SL || reason == DEAL_REASON_SO))
      g_slHaltPending = true; // OnTick flattens all + latches BUY/SELL off
}

//====================== MARKET GUARD ======================
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
   return !found; // no published sessions -> don't block (use stale-tick guard)
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

//====================== CLOSE HELPERS ======================
// Close ALL layers of one direction (used by the per-dir pips guard). In a web
// a direction can hold several layers; the guard closes the whole side.
void CloseDirection(const bool isBuy, const string reason)
{
   if(DirectionLayerCount(isBuy) == 0) return;
   if(!CanAttemptClose())
   {
      LogGuardOnce("close_blocked", "BLOCKED close " + (isBuy ? "BUY" : "SELL")
                   + " (" + reason + ") — trade path guard; will retry");
      return;
   }
   double totalPL = 0; int closed = 0; bool anyFail = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) != isBuy) continue;
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(trade.PositionClose(tk)) { totalPL += pl; closed++; }
      else
      {
         anyFail = true;
         LogGuardOnce("fail_close", "FAIL close rc=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      }
   }
   if(anyFail) g_lastCloseFailTime = TimeCurrent();
   if(closed > 0)
   {
      LogInfo("CLOSE " + (isBuy ? "BUY" : "SELL") + " x" + IntegerToString(closed)
              + " (" + reason + ") | P/L " + DoubleToString(totalPL, 2));
      NotifyPush((isBuy ? "BUY" : "SELL") + " CLOSED x" + IntegerToString(closed)
                 + " (" + reason + ") | P/L: " + DoubleToString(totalPL, 2));
   }
}

void CloseAllEA(const string reason = "")
{
   if(!HasEAPositions()) return;
   if(!CanAttemptClose())
   {
      LogGuardOnce("close_blocked", "BLOCKED close" + (reason != "" ? " (" + reason + ")" : "")
                   + " — trade path guard (broker session/stale tick/retry cooldown); will retry");
      return;
   }

   double totalPL = 0;
   int closedCount = 0;
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
      LogInfo("CLOSE ALL" + (reason != "" ? " (" + reason + ")" : "") + " | net P/L " + DoubleToString(totalPL, 2));
      NotifyPush("CLOSED ALL" + (reason != "" ? " (" + reason + ")" : "") + " | Net P/L: " + DoubleToString(totalPL, 2));
   }
}

//====================== PRICE / LOT HELPERS ======================
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
