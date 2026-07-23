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
//|  Runner: unlike lets-go, scanning NEVER freezes while positions  |
//|         are live. Each direction keeps re-marking its next level |
//|         and resting a fresh pending. When price reaches a        |
//|         direction's next level and that direction's open         |
//|         position is in PROFIT, the position is banked (closed)   |
//|         and a fresh pending re-arms from the new level. The      |
//|         LOSING side is never touched by this — it just runs, and |
//|         the banked profit from the winning side's roll cycles    |
//|         nets against its floating loss.                          |
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
#property version   "1.00"

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

input group "===== Runner roll (close profit + reopen fresh) ====="
input double RollMinProfitPips     = 0;     // Min floating profit (pips) before a level-revisit banks the layer

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
bool           g_UseGuardDDPct, g_UseGuardDDMoney, g_UseGuardPips;
ENUM_PIP_SCOPE g_GuardPipsScope;
bool           g_UseSession, g_UseWeekendFilter, g_UseNewsFilter, g_UseBrokerSessionGuard;

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
   return "rn100|"
        + IntegerToString((int)TradeBuy) + IntegerToString((int)TradeSell) + "|"
        + IntegerToString((int)StartBreakMode) + "|"
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
      "INP_FP","Buy","Sell","SrBR","Collapsed",
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
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("LG", x0, y, rowW, chipH); y += chipH + gap;
   string guards[] = { "Session", "Weekend", "News", "Broker" };
   PanelPlaceEvenRow(guards, 4, x0, y, rowW, gap, chipH);
   y += chipH + gap + sectionGap;

   PanelEnsureLabel("LR", x0, y, rowW, chipH); y += chipH + gap;
   string risk[] = { "gDDp", "gDDm", "gPip", "gScope" };
   PanelPlaceEvenRow(risk, 4, x0, y, rowW, gap, chipH);

   string liveIds[] = {
      "TTL","BUY","SELL","SrBR","Flat","LG",
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

   ManageGuards();     // DD% / DD$ / pips backstop — may close
   ManageRolls();      // bank a profitable layer when price reaches its next level
   ManagePendings();   // rest / refresh / pull broker pendings, per direction
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

// Nearest pivot level each side of price, picked from ALL pivots in the
// lookback window. Fetch MORE than LevelsLookback by the pivot margin so a
// pivot at the oldest edge can still be confirmed and LevelsLookback means
// what it says (matches the sr-breaks indicator's real reach — same fix as
// lets-go's GetNearestSrLevels).
bool GetNearestSrLevels(const double px,
                        double &aboveLvl, bool &haveAbove,
                        double &belowLvl, bool &haveBelow)
{
   aboveLvl = 0; belowLvl = 0; haveAbove = false; haveBelow = false;

   int need = LevelsLookback + PivotLeftBars + PivotRightBars;
   MqlRates rates[];
   int got = CopyRates(_Symbol, g_t1, 0, need, rates);
   if(got < PivotLeftBars + PivotRightBars + 3)
   { LogDebugGuard("dbg_sr", "GetNearestSrLevels: not enough bars yet"); return false; }

   int total = got;
   int lastCompleted = total - 2;
   int startBar = MathMax(PivotLeftBars, total - LevelsLookback);

   for(int i = startBar; i <= lastCompleted; i++)
   {
      int pivotIdx = i - PivotRightBars;
      if(pivotIdx < PivotLeftBars) continue;
      if(pivotIdx + PivotRightBars > lastCompleted) continue;

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
   { LogDebugGuard("dbg_sr", "GetNearestSrLevels: no pivots found yet"); return false; }
   return true;
}

// The pending PRICE a direction wants right now, given the current mode.
//   break  buy : nearest level ABOVE price -> buy STOP at level + buf
//   break  sell: nearest level BELOW price -> sell STOP at level - buf
//   reject buy : nearest level BELOW price -> buy LIMIT at level + buf
//   reject sell: nearest level ABOVE price -> sell LIMIT at level - buf
// Returns false when the needed level does not exist yet. isStop mirrors the
// mode (break = stop, reject = limit).
bool DirectionTargetLevel(const bool isBuy, double &price, bool &isStop)
{
   price = 0; isStop = g_SrBreakSel;
   const double buf = MathMax(0.0, SrBufferPips) * g_pip;
   const double px  = 0.5 * (SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                           + SymbolInfoDouble(_Symbol, SYMBOL_BID));
   double aboveLvl = 0, belowLvl = 0; bool haveAbove = false, haveBelow = false;
   if(!GetNearestSrLevels(px, aboveLvl, haveAbove, belowLvl, haveBelow))
      return false;

   if(g_SrBreakSel)
   {
      if(isBuy)  { if(!haveAbove) return false; price = aboveLvl + buf; }
      else       { if(!haveBelow) return false; price = belowLvl - buf; }
   }
   else
   {
      if(isBuy)  { if(!haveBelow) return false; price = belowLvl + buf; }
      else       { if(!haveAbove) return false; price = aboveLvl - buf; }
   }
   return true;
}

//====================== POSITION / PENDING HELPERS ======================
// One open position per direction. Returns its ticket (0 if none) + entry.
ulong DirectionPosition(const bool isBuy, double &entry)
{
   entry = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      bool posBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(posBuy != isBuy) continue;
      entry = PositionGetDouble(POSITION_PRICE_OPEN);
      return tk;
   }
   return 0;
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

// Floating pips of a direction's open position (>=0 profit, <0 loss). 0 if flat.
double DirectionFloatPips(const bool isBuy)
{
   double entry = 0;
   if(DirectionPosition(isBuy, entry) == 0) return 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   return isBuy ? (bid - entry) / g_pip : (entry - ask) / g_pip;
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

//====================== PENDING RECONCILE (per direction, never freezes) ======================
// Each tick, compute the pending each ARMED, EMPTY direction should rest, then
// reconcile (delete stale, keep matching, place missing). Unlike lets-go, a
// live position on ONE side never stops the OTHER side (or a re-armed same
// side) from resting a fresh pending. A direction that already holds a
// position rests nothing (1 layer/direction) — its roll is handled in
// ManageRolls, which frees the slot when it banks.
void ManagePendings()
{
   // sync tracked list with the broker (fills untrack in the fill handler;
   // this also catches orders deleted by hand in the terminal)
   for(int i = g_pendCount - 1; i >= 0; i--)
      if(!OrderSelect(g_pendTicket[i])) PendUntrackIndex(i);

   // Entries paused: pull everything, but leave open positions running.
   if(!InSession() || !CanAttemptEntry())
   { if(g_pendCount > 0) DeleteOurPendings("entry blocked"); return; }

   // Relocation cadence: an already-resting order is only moved to a NEW level
   // once the T1 candle closes, so intra-candle wiggles can't churn the broker
   // with cancel/replace. A direction with NO resting order is placed
   // immediately, any tick — so a fresh pending re-arms instantly after a roll
   // or a fill (that is the whole point of runner).
   const datetime curBar = iTime(_Symbol, g_t1, 0);
   const bool newBar = (curBar != g_srRecalcBar);

   // ---- desired pendings, one per armed + empty direction ----
   double dLvl[PEND_MAX]; bool dBuy[PEND_MAX], dStop[PEND_MAX];
   int dn = 0;
   for(int s = 0; s < 2 && dn < PEND_MAX; s++)
   {
      bool isBuy = (s == 0);
      if(isBuy ? !g_TradeBuy : !g_TradeSell) continue; // direction disarmed
      double dummy = 0;
      if(DirectionPosition(isBuy, dummy) != 0) continue; // slot occupied -> no pending
      double price = 0; bool isStop = true;
      if(!DirectionTargetLevel(isBuy, price, isStop)) continue; // level not there yet
      dLvl[dn] = price; dBuy[dn] = isBuy; dStop[dn] = isStop; dn++;
   }

   // Broker validity = the arming rule: a stop rests only with price on the
   // pre-break side, a limit only on the approach side. Wrong side = the touch
   // already happened; skip (nothing rests, the level re-marks next candle).
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

   // Reconcile tracked vs desired. A desired slot matched by a resting order is
   // flagged negative so the placement pass skips it.
   for(int i = g_pendCount - 1; i >= 0; i--)
   {
      // exact same-direction, same-level match -> keep as-is
      bool keep = false;
      for(int j = 0; j < dn; j++)
         if(dLvl[j] > 0 && g_pendIsBuy[i] == dBuy[j]
            && MathAbs(g_pendLevel[i] - dLvl[j]) < point * 0.5)
         { keep = true; dLvl[j] = -dLvl[j]; break; }
      if(keep) continue;

      // No same-level match. If the same direction is still desired at a
      // DIFFERENT level, that is a relocation — only act on a new candle. Until
      // then keep the resting order and suppress the new same-direction level.
      bool sameDirDesired = false;
      for(int j = 0; j < dn; j++)
         if(dLvl[j] > 0 && dBuy[j] == g_pendIsBuy[i]) { sameDirDesired = true; break; }

      if(sameDirDesired && !newBar)
      {
         for(int j = 0; j < dn; j++)
            if(dLvl[j] > 0 && dBuy[j] == g_pendIsBuy[i]) dLvl[j] = -dLvl[j];
         continue;
      }

      // Stale direction, or relocation allowed (new candle): pull it.
      if(!trade.OrderDelete(g_pendTicket[i]))
      {
         LogGuardOnce("fail_pend_del", "FAIL pending delete rc=" + IntegerToString(trade.ResultRetcode())
                      + " " + trade.ResultRetcodeDescription());
         continue;
      }
      LogInfo("PEND DEL " + (g_pendIsBuy[i] ? "BUY" : "SELL") + " @ "
              + DoubleToString(g_pendLevel[i], _Digits) + (sameDirDesired ? " (relevel)" : " (stale)"));
      PendUntrackIndex(i);
   }
   for(int j = 0; j < dn && g_pendCount < PEND_MAX; j++)
      if(dLvl[j] > 0)
         PlacePendingOrder(dBuy[j], dStop[j], dLvl[j]);

   g_srRecalcBar = curBar; // advance the relocation clock once per pass
}

//====================== RUNNER ROLL (bank profit, reopen fresh) ======================
// For each open direction, when price reaches that direction's NEXT level (the
// same price a fresh pending would sit at) AND the layer is in profit by at
// least RollMinProfitPips, the layer is banked (closed). Next tick the
// reconciler sees the slot empty and rests a fresh pending from the new level.
// The LOSING side never satisfies the profit test, so it is never rolled here
// (only the guards can close it). Runs regardless of session — closing to bank
// is always safe.
void ManageRolls()
{
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double buf = MathMax(0.0, SrBufferPips) * g_pip;
   const double px  = 0.5 * (ask + bid);

   double aboveLvl = 0, belowLvl = 0; bool haveAbove = false, haveBelow = false;
   bool haveLevels = GetNearestSrLevels(px, aboveLvl, haveAbove, belowLvl, haveBelow);
   if(!haveLevels) return;

   for(int s = 0; s < 2; s++)
   {
      bool isBuy = (s == 0);
      double entry = 0;
      ulong tk = DirectionPosition(isBuy, entry);
      if(tk == 0) continue; // slot empty — nothing to roll

      // Has price reached this direction's next level? Same condition the
      // pending would fill at.
      bool reached = false;
      if(g_SrBreakSel)
      {
         if(isBuy)  reached = haveAbove && ask >= aboveLvl + buf;
         else       reached = haveBelow && bid <= belowLvl - buf;
      }
      else
      {
         if(isBuy)  reached = haveBelow && bid <= belowLvl + buf;
         else       reached = haveAbove && ask >= aboveLvl - buf;
      }
      if(!reached) continue;

      double floatPips = isBuy ? (bid - entry) / g_pip : (entry - ask) / g_pip;
      if(floatPips < RollMinProfitPips) continue; // hanging in loss/flat — leave it running

      if(!CanAttemptClose())
      { LogGuardOnce("roll_blocked", "BLOCKED roll — trade path guard; will retry"); continue; }

      double pl = 0;
      if(PositionSelectByTicket(tk))
         pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(trade.PositionClose(tk))
      {
         DeleteDirectionPending(isBuy, "roll — reopen fresh"); // will re-arm next tick
         string msg = "ROLL " + (isBuy ? "BUY" : "SELL") + " banked +"
                    + DoubleToString(floatPips, 1) + "p | P/L " + DoubleToString(pl, 2)
                    + " | reopen fresh from new level";
         LogInfo(msg);
         if(InpNotifyOnOpen) NotifyPush(msg);
      }
      else
      {
         g_lastCloseFailTime = TimeCurrent();
         LogGuardOnce("fail_roll", "FAIL roll close rc=" + IntegerToString(trade.ResultRetcode())
                      + " " + trade.ResultRetcodeDescription());
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

// A global DD guard is the DISASTER backstop: after it closes everything it
// LATCHES the EA off (disarms BUY + SELL) so runner does not walk straight back
// into the same hole. Click BUY / SELL on the panel to resume. The pips guard
// does NOT latch — it is a per-layer stop, re-entry at a fresh level is the
// strategy.
void LatchHaltAfterDD(const string which)
{
   g_TradeBuy = false;
   g_TradeSell = false;
   PanelSaveBool("Buy", false);
   PanelSaveBool("Sell", false);
   string msg = "GUARD " + which + " HALT — BUY+SELL disarmed; re-enable on the panel to resume";
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
      LatchHaltAfterDD("DD$");
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
            LatchHaltAfterDD("DD%");
            return;
         }
      }
   }

   // --- Pips per layer: per-direction (loss side only) or global (both) ---
   if(g_UseGuardPips && GuardPipsValue > 0)
   {
      // Guard protects ALL open positions — a disarmed BUY/SELL chip stops new
      // entries, it does not stop guarding a position that is still running.
      double eB = 0, eS = 0;
      bool haveBuy  = (DirectionPosition(true,  eB) != 0);
      bool haveSell = (DirectionPosition(false, eS) != 0);
      double buyPips  = haveBuy  ? DirectionFloatPips(true)  : 0;
      double sellPips = haveSell ? DirectionFloatPips(false) : 0;
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

   // A pending of ours filled: untrack it, log the open. One-per-direction, so
   // there is no same-direction sibling to pull; the OPPOSITE side keeps
   // resting. The reconciler simply won't re-arm this side while it holds a
   // position.
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

// Broker-side SL/stop-out fill (only possible when HardSLPips is set): give it
// a Journal + push line so it is not a silent close.
void NotifyBrokerClose(const ulong dealTicket)
{
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
   string tag;
   switch(reason)
   {
      case DEAL_REASON_SL: tag = "offline SL"; break;
      case DEAL_REASON_SO: tag = "stop out";   break;
      default: return; // EXPERT close is logged where it happens
   }
   double dealPL = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   string msg = "POSITION CLOSED (" + tag + ") | Net P/L: " + DoubleToString(dealPL, 2);
   LogInfo(msg);
   NotifyPush(msg);
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
// Close one direction's open position (used by per-dir pips guard + rolls).
void CloseDirection(const bool isBuy, const string reason)
{
   double entry = 0;
   ulong tk = DirectionPosition(isBuy, entry);
   if(tk == 0) return;
   if(!CanAttemptClose())
   {
      LogGuardOnce("close_blocked", "BLOCKED close " + (isBuy ? "BUY" : "SELL")
                   + " (" + reason + ") — trade path guard; will retry");
      return;
   }
   double pl = 0;
   if(PositionSelectByTicket(tk))
      pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   if(trade.PositionClose(tk))
   {
      LogInfo("CLOSE " + (isBuy ? "BUY" : "SELL") + " (" + reason + ") | P/L " + DoubleToString(pl, 2));
      NotifyPush((isBuy ? "BUY" : "SELL") + " CLOSED (" + reason + ") | P/L: " + DoubleToString(pl, 2));
   }
   else
   {
      g_lastCloseFailTime = TimeCurrent();
      LogGuardOnce("fail_close", "FAIL close rc=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
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
