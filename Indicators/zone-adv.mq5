//+------------------------------------------------------------------+
//| IntradayMTF_SR_Zones.mq5                                         |
//| MQL5 port of "Intraday MTF SR Zones" (Pine v6, open-source)      |
//|                                                                  |
//| - 4 independent timeframe slots (M30/H1/H2/H4 default), pivot    |
//|   highs/lows with left/right strength, non-repainting (a pivot   |
//|   only exists once its right-hand HTF bars have closed).         |
//| - Session engine: a fresh stack of zones per WIB day (broker     |
//|   time + TZ offset, fibo-gun style). Keeps last N sessions,      |
//|   caps zones per session (weakest dropped first).                |
//| - Confluence merge: same-side zones overlapping within an ATR    |
//|   tolerance fuse into one zone (wick-weighted level, union of    |
//|   timeframes, re-scored with a per-extra-TF bonus).              |
//| - Strength engine 0-10: TF rank / confluence / rejection wick /  |
//|   pivot prominence, all weights adjustable.                      |
//| - Rendering: filled OBJ_RECTANGLE, opacity simulated by blending |
//|   the zone color toward the chart background (BlendWith-         |
//|   Background pattern from user's fibo.mq5) and graded by score.  |
//| - Tidy labels: arrow/diamond + timeframe set + stars only.       |
//|   (score text optional, tier words removed)                      |
//| - Dashboard panel: per-TF counts + bias, strongest zone,         |
//|   nearest res/sup, position/room, session tag - hideable,        |
//|   4 corners, colors adjustable.                                  |
//| - Alerts: new res/sup level, price at zone, price at STRONG      |
//|   zone (popup + push toggles).                                   |
//+------------------------------------------------------------------+
#property copyright "MQL5 port for personal use"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots   1
#property indicator_type1   DRAW_NONE
#property indicator_label1  "SRZ"

//====================== ENUMS ======================
enum eThickMode
  {
   THICK_ATR = 0,   // ATR multiple
   THICK_PCT = 1    // % of price
  };
enum eLabSize
  {
   LS_TINY   = 0,   // Tiny
   LS_SMALL  = 1,   // Small
   LS_NORMAL = 2,   // Normal
   LS_LARGE  = 3    // Large
  };
enum eDashPos
  {
   DP_TR = 0,       // Top Right
   DP_TL = 1,       // Top Left
   DP_BR = 2,       // Bottom Right
   DP_BL = 3        // Bottom Left
  };
enum eDashSize
  {
   DS_TINY   = 0,   // Tiny
   DS_SMALL  = 1,   // Small
   DS_NORMAL = 2    // Normal
  };

//====================== INPUTS ======================
input group "===== 1. Timeframe Levels (pivot core) ====="
input bool            InpEn1        = true;        // Slot 1 enable
input ENUM_TIMEFRAMES InpTf1        = PERIOD_M30;  // Slot 1 timeframe
input bool            InpEn2        = true;        // Slot 2 enable
input ENUM_TIMEFRAMES InpTf2        = PERIOD_H1;   // Slot 2 timeframe
input bool            InpEn3        = true;        // Slot 3 enable
input ENUM_TIMEFRAMES InpTf3        = PERIOD_H2;   // Slot 3 timeframe
input bool            InpEn4        = true;        // Slot 4 enable
input ENUM_TIMEFRAMES InpTf4        = PERIOD_H4;   // Slot 4 timeframe
input int             InpPivotL     = 5;           // Pivot strength (left bars)
input int             InpPivotR     = 5;           // Pivot strength (right bars)
input bool            InpShowRes    = true;        // Resistance (pivot highs)
input bool            InpShowSup    = true;        // Support (pivot lows)

input group "===== 2. Session Handling (WIB / Jakarta) ====="
input int             InpTZOffset      = 7;        // Hours added to broker time -> WIB (7 if server=UTC)
input int             InpDayStartHour  = 0;        // Session rollover hour in WIB (0 = WIB midnight)
input int             InpKeepN         = 3;        // Sessions of zones to keep (1-10)
input int             InpCapSes        = 14;       // Max zones per session (2-30)
input int             InpExtendBars    = 10;       // Extend latest session right (chart bars)

input group "===== 3. Zone Shape ====="
input eThickMode      InpThickMode  = THICK_ATR;   // Thickness method
input double          InpThickATR   = 0.28;        // Thickness (ATR x)
input double          InpThickPct   = 0.10;        // Thickness (% of price)
input int             InpATRLen     = 14;          // ATR length

input group "===== 4. Confluence Merge ====="
input bool            InpMerge      = true;        // Merge overlapping same-side levels
input double          InpMergeATR   = 0.35;        // Merge distance (ATR x)
input double          InpConfBonus  = 0.9;         // Confluence bonus per extra TF

input group "===== 5. Strength Engine (0-10) ====="
input double          InpMinScore   = 0.0;         // Hide zones below score
input double          InpWTf        = 0.40;        // Weight: timeframe rank
input double          InpWConf      = 0.28;        // Weight: confluence
input double          InpWWick      = 0.18;        // Weight: rejection wick
input double          InpWPro       = 0.14;        // Weight: pivot prominence
input double          InpStrongTh   = 7.0;         // Strong-zone threshold (alerts)

input group "===== 6. Labels (tidy) ====="
input bool            InpShowLabels   = true;      // Show zone labels
input bool            InpShowStars    = true;      // Show stars (strength)
input bool            InpShowScoreTxt = false;     // Also show numeric score (x.x/10)
input bool            InpLatestOnly   = false;     // Labels on latest session only
input eLabSize        InpLabSize      = LS_SMALL;  // Label size
input color           InpLabelColor   = C'228,233,242'; // Label text color
input string          InpLabelFont    = "Arial";   // Label font

input group "===== 7. Zone Colors ====="
input color           InpRes1       = C'21,131,98';   // Resistance shade 1 (weak)
input color           InpRes2       = C'25,108,100';  // Resistance shade 2
input color           InpRes3       = C'0,89,80';     // Resistance shade 3
input color           InpRes4       = C'0,50,42';     // Resistance shade 4 (elite)
input color           InpSup1       = C'133,23,147';  // Support shade 1 (weak)
input color           InpSup2       = C'119,18,18';   // Support shade 2
input color           InpSup3       = C'88,9,51';     // Support shade 3
input color           InpSup4       = C'48,13,91';    // Support shade 4 (elite)
input color           InpConfCol    = C'116,88,166';  // Confluence zone color
input int             InpBaseTransp = 60;             // Weakest transparency % (30-96)
input int             InpTranspSpan = 34;             // Strength opacity span (0-55)
input bool            InpBorders    = true;           // Show zone borders

input group "===== 8. Dashboard ====="
input bool            InpShowDash   = true;           // Show dashboard
input eDashPos        InpDashPos    = DP_TR;          // Position
input eDashSize       InpDashSize   = DS_SMALL;       // Text size
input string          InpDashFont   = "Consolas";     // Dashboard font (monospace)
input color           InpDashBg     = C'16,20,28';    // Panel background
input color           InpDashHdr    = C'30,37,48';    // Title row background
input color           InpDashAlt    = C'23,28,38';    // Section row background
input color           InpDashTxt    = C'228,233,242'; // Main text
input color           InpDashMuted  = C'138,147,163'; // Muted text
input color           InpDashAccR   = C'32,160,120';  // Resistance accent
input color           InpDashAccS   = C'190,60,200';  // Support accent
input color           InpDashGold   = C'150,120,210'; // Highlight accent

input group "===== 9. Alerts ====="
input bool            InpAlertsOn    = false;      // Enable alerts
input bool            InpAlertNew    = true;       // Alert: new res/sup level formed
input bool            InpAlertTouch  = true;       // Alert: price at any zone
input bool            InpAlertStrong = true;       // Alert: price at STRONG zone
input bool            InpAlertPopup  = true;       // Popup alert
input bool            InpAlertPush   = false;      // Push notification

input group "===== 10. Misc ====="
input int             InpRefreshSec = 30;          // Refresh interval sec (object recovery)
input string          InpObjPrefix  = "SRZmtf_";   // Object name prefix

//====================== STRUCTS ======================
struct Ev            // one confirmed pivot event
  {
   datetime          conf;      // server time the pivot confirmed (HTF bar close)
   int               tf;        // slot index 0..3
   bool              isRes;
   double            lvl;
   double            wick;
   double            prom;
   double            atr;       // HTF ATR at confirmation bar
  };

struct ZoneS
  {
   bool              isRes;
   bool              hasTf[4];
   double            level;
   double            topP;
   double            botP;
   double            tfW;
   double            wickSum;
   int               wickN;
   double            prom;
   double            score;
   int               sesIdx;    // index into g_ses[]
  };

struct SesS
  {
   datetime          startSrv;  // session window start (server time)
   datetime          endSrv;    // session window end
   datetime          firstBarT; // first chart bar inside window
   datetime          lastBarT;  // last chart bar inside window
  };

//====================== GLOBALS ======================
double   g_buf[];
string   g_prefix;
bool     g_tfEn[4];
ENUM_TIMEFRAMES g_tfPer[4];
string   g_tfLab[4];
int      g_pL, g_pR;
int      g_chartSec;

Ev       g_ev[];
ZoneS    g_zones[];
SesS     g_ses[];
int      g_nSes = 0;

double   g_atrChart = 0;
double   g_thick    = 0;
double   g_lastClose = 0;
datetime g_lastBarT  = 0;
datetime g_prevBarT  = 0;

int      g_maxDrawn  = 0;
bool     g_dataOk    = true;
datetime g_lastEvConf  = 0;
datetime g_lastTouchBar = 0;
bool     g_firstPass = true;

// dashboard geometry (current)
int      g_dx = 0, g_dy = 0, g_dw = 0, g_rowH = 16, g_dfs = 8;
int      g_colX[4];
#define DASH_ROWS 14

// unicode symbols (built at init)
string   g_symUp, g_symDn, g_symDia, g_symStar, g_symDot, g_symMid, g_symOn, g_symOff;

//====================== SMALL HELPERS ======================
double Clamp(const double v, const double lo, const double hi)
  {
   return MathMax(lo, MathMin(hi, v));
  }

string TfLabelStr(const ENUM_TIMEFRAMES tf)
  {
   int s = PeriodSeconds(tf);
   if(s <= 0) return "?";
   if(s % 86400 == 0)              return "D" + IntegerToString(s / 86400);
   if(s >= 3600 && s % 3600 == 0)  return "H" + IntegerToString(s / 3600);
   if(s >= 60)                     return "M" + IntegerToString(s / 60);
   return "S" + IntegerToString(s);
  }

double TfWeight(const int sec)
  {
   if(sec >= 14400) return 1.0;
   if(sec >= 3600)  return 0.78;
   if(sec >= 900)   return 0.55;
   if(sec >= 300)   return 0.38;
   if(sec >= 60)    return 0.30;
   return 0.25;
  }

string Stars(const double s)
  {
   int n = s >= 8 ? 5 : s >= 6.5 ? 4 : s >= 5 ? 3 : s >= 3.5 ? 2 : s >= 2 ? 1 : 0;
   if(n == 0) return g_symMid;
   string r = "";
   for(int i = 0; i < n; i++) r += g_symStar;
   return r;
  }

int LabFontSize(const eLabSize sz)
  {
   switch(sz)
     {
      case LS_TINY:   return 7;
      case LS_NORMAL: return 10;
      case LS_LARGE:  return 12;
      default:        return 8;
     }
  }

//--- transparency % for a score (Pine: clamp(baseTr - score/10*span, 30, 96))
int TranspOf(const double score)
  {
   return (int)Clamp(InpBaseTransp - (score / 10.0) * InpTranspSpan, 30.0, 96.0);
  }

//--- blend zone color toward chart background (pattern from user's fibo.mq5)
color BlendWithBackground(const color c, const int transparencyPct)
  {
   long bg;
   if(!ChartGetInteger(0, CHART_COLOR_BACKGROUND, 0, bg))
      bg = (long)clrBlack;
   int bgR = (int)(bg & 0xFF);
   int bgG = (int)((bg >> 8) & 0xFF);
   int bgB = (int)((bg >> 16) & 0xFF);

   int cR = (int)(c & 0xFF);
   int cG = (int)((c >> 8) & 0xFF);
   int cB = (int)((c >> 16) & 0xFF);

   double t = Clamp(transparencyPct, 0, 100) / 100.0;
   int r = (int)MathRound(cR * (1.0 - t) + bgR * t);
   int g = (int)MathRound(cG * (1.0 - t) + bgG * t);
   int b = (int)MathRound(cB * (1.0 - t) + bgB * t);
   return (color)(r | (g << 8) | (b << 16));
  }

//--- strength score 0-10 (direct Pine port)
double Score(const double tfW, const int cc, const double wickAvg,
             const double prom, const double atrv)
  {
   double tfF  = Clamp(tfW, 0.0, 1.0);
   double cnfF = Clamp((cc - 1) / 2.0, 0.0, 1.0);
   double wkF  = atrv > 0 ? Clamp(wickAvg / (atrv * 0.6), 0.0, 1.0) : 0.0;
   double prF  = atrv > 0 ? Clamp(prom / (atrv * 3.0), 0.0, 1.0) : 0.0;
   double wSum = MathMax(InpWTf + InpWConf + InpWWick + InpWPro, 1e-6);
   double raw  = (tfF * InpWTf + cnfF * InpWConf + wkF * InpWWick + prF * InpWPro) / wSum;
   return Clamp(raw * 10.0 + InpConfBonus * (cc - 1), 0.0, 10.0);
  }

int CC(const ZoneS &z)
  {
   int c = 0;
   for(int i = 0; i < 4; i++) if(z.hasTf[i]) c++;
   return c;
  }

color Shade(const bool isRes, const double s)
  {
   if(isRes)
      return s >= 6.5 ? InpRes4 : s >= 5 ? InpRes3 : s >= 3.5 ? InpRes2 : InpRes1;
   return s >= 6.5 ? InpSup4 : s >= 5 ? InpSup3 : s >= 3.5 ? InpSup2 : InpSup1;
  }

color ZoneColor(const ZoneS &z)
  {
   return CC(z) > 1 ? InpConfCol : Shade(z.isRes, z.score);
  }

string TfSet(const ZoneS &z)
  {
   string s = "";
   for(int i = 0; i < 4; i++)
      if(z.hasTf[i])
         s = (s == "" ? g_tfLab[i] : s + g_symDot + g_tfLab[i]);
   return s == "" ? "-" : s;
  }

string ZoneLabelTxt(const ZoneS &z)
  {
   int cc = CC(z);
   string dir = cc > 1 ? g_symDia : (z.isRes ? g_symUp : g_symDn);
   string t = dir + " " + TfSet(z);
   if(InpShowStars)    t += "  " + Stars(z.score);
   if(InpShowScoreTxt) t += "  " + DoubleToString(z.score, 1) + "/10";
   return t;
  }

//====================== WIB SESSION MATH ======================
long DayIdx(const datetime t)
  {
   long adj = (long)t + (long)InpTZOffset * 3600 - (long)InpDayStartHour * 3600;
   return adj / 86400;
  }

datetime DayStartSrv(const long idx)
  {
   return (datetime)(idx * 86400 + (long)InpDayStartHour * 3600 - (long)InpTZOffset * 3600);
  }

//--- Asian / London / NY tag (Pine GMT windows; GMT = WIB - 7)
string SessTag()
  {
   datetime gmt = TimeCurrent() + (datetime)((InpTZOffset - 7) * 3600);
   MqlDateTime dt;
   TimeToStruct(gmt, dt);
   int m = dt.hour * 60 + dt.min;
   if(m >= 480 && m < 780)  return "London";
   if(m >= 780 && m < 1320) return "NY";
   if(m >= 0 && m < 540)    return "Asian";
   return "Other";
  }

//--- first index in chart rates with time >= t
int LowerBound(const MqlRates &a[], const int n, const datetime t)
  {
   int lo = 0, hi = n;
   while(lo < hi)
     {
      int m = (lo + hi) / 2;
      if(a[m].time < t) lo = m + 1; else hi = m;
     }
   return lo;
  }

bool CollectSessions(const MqlRates &cr[], const int n)
  {
   g_nSes = 0;
   int keep = (int)Clamp(InpKeepN, 1, 10);
   SesS tmp[];
   ArrayResize(tmp, keep);
   int got = 0, tries = 0;
   long idx = DayIdx(cr[n - 1].time);
   while(got < keep && tries < keep * 7 + 21 && idx >= 0)
     {
      datetime s = DayStartSrv(idx);
      datetime e = s + 86400;
      int i1 = LowerBound(cr, n, s);
      if(i1 < n && cr[i1].time < e)
        {
         int i2 = LowerBound(cr, n, e) - 1;
         if(i2 >= i1)
           {
            tmp[got].startSrv  = s;
            tmp[got].endSrv    = e;
            tmp[got].firstBarT = cr[i1].time;
            tmp[got].lastBarT  = cr[i2].time;
            got++;
           }
        }
      idx--;
      tries++;
     }
   if(got == 0) return false;
   ArrayResize(g_ses, got);
   for(int k = 0; k < got; k++) g_ses[k] = tmp[got - 1 - k];   // ascending
   g_nSes = got;
   return true;
  }

//--- session a confirmation time belongs to (persists across gaps until next session)
int SessionOf(const datetime conf)
  {
   if(g_nSes == 0 || conf < g_ses[0].startSrv) return -1;
   for(int k = g_nSes - 1; k >= 0; k--)
      if(conf >= g_ses[k].startSrv) return k;
   return -1;
  }

//====================== PIVOT SCAN (per timeframe) ======================
void AddEvent(const datetime conf, const int tfIdx, const bool isRes,
              const double lvl, const double wick, const double prom, const double atrv)
  {
   if(SessionOf(conf) < 0) return;   // older than kept sessions
   int n = ArraySize(g_ev);
   ArrayResize(g_ev, n + 1);
   g_ev[n].conf  = conf;
   g_ev[n].tf    = tfIdx;
   g_ev[n].isRes = isRes;
   g_ev[n].lvl   = lvl;
   g_ev[n].wick  = wick;
   g_ev[n].prom  = prom;
   g_ev[n].atr   = atrv;
  }

void ScanTf(const int tfIdx)
  {
   if(!g_tfEn[tfIdx]) return;
   ENUM_TIMEFRAMES tf = g_tfPer[tfIdx];
   int tfSec = PeriodSeconds(tf);
   if(tfSec <= 0) return;

   int lenRef = g_pL + g_pR;
   int bufBars = lenRef + g_pL + g_pR + InpATRLen + 10;
   datetime fromT = g_ses[0].startSrv - (datetime)((long)bufBars * tfSec) - 4 * 86400;

   MqlRates r[];
   int n = CopyRates(_Symbol, tf, fromT, TimeCurrent() + tfSec, r);
   if(n < lenRef + g_pL + g_pR + 3)
     {
      g_dataOk = false;   // HTF history not ready yet; timer will retry
      return;
     }

   // running Wilder ATR + SMA(hl2, lenRef)
   double atrArr[], smaArr[];
   ArrayResize(atrArr, n);
   ArrayResize(smaArr, n);
   double atr = 0, sum = 0;
   for(int i = 0; i < n; i++)
     {
      double tr = (i == 0) ? (r[i].high - r[i].low)
                  : MathMax(r[i].high - r[i].low,
                            MathMax(MathAbs(r[i].high - r[i - 1].close),
                                    MathAbs(r[i].low  - r[i - 1].close)));
      if(i < InpATRLen) atr = (atr * i + tr) / (i + 1);
      else              atr = (atr * (InpATRLen - 1) + tr) / InpATRLen;
      atrArr[i] = atr;

      double hl2 = (r[i].high + r[i].low) / 2.0;
      sum += hl2;
      if(i >= lenRef) sum -= (r[i - lenRef].high + r[i - lenRef].low) / 2.0;
      smaArr[i] = (i >= lenRef - 1) ? sum / lenRef : sum / (i + 1);
     }

   double lastRes = EMPTY_VALUE, lastSup = EMPTY_VALUE;

   // r[n-1] is the forming bar; confirmation bar c must be closed (c <= n-2)
   for(int p = g_pL; p + g_pR <= n - 2; p++)
     {
      int c = p + g_pR;

      if(InpShowRes)
        {
         bool isPH = true;
         for(int k = 1; k <= g_pL && isPH; k++) if(r[p - k].high >= r[p].high) isPH = false;
         for(int k = 1; k <= g_pR && isPH; k++) if(r[p + k].high >= r[p].high) isPH = false;
         if(isPH)
           {
            double lvl = r[p].high;
            if(lastRes == EMPTY_VALUE || lvl != lastRes)
              {
               datetime conf = r[c].time + tfSec;
               double wick = MathMax(lvl - MathMax(r[p].open, r[p].close), 0.0);
               double prom = MathMax(lvl - smaArr[c], 0.0);
               AddEvent(conf, tfIdx, true, lvl, wick, prom, atrArr[c]);
               lastRes = lvl;
              }
           }
        }

      if(InpShowSup)
        {
         bool isPL = true;
         for(int k = 1; k <= g_pL && isPL; k++) if(r[p - k].low <= r[p].low) isPL = false;
         for(int k = 1; k <= g_pR && isPL; k++) if(r[p + k].low <= r[p].low) isPL = false;
         if(isPL)
           {
            double lvl = r[p].low;
            if(lastSup == EMPTY_VALUE || lvl != lastSup)
              {
               datetime conf = r[c].time + tfSec;
               double wick = MathMax(MathMin(r[p].open, r[p].close) - lvl, 0.0);
               double prom = MathMax(smaArr[c] - lvl, 0.0);
               AddEvent(conf, tfIdx, false, lvl, wick, prom, atrArr[c]);
               lastSup = lvl;
              }
           }
        }
     }
  }

//--- sort events: conf time asc, then resistance before support, then slot order
bool EvGreater(const Ev &a, const Ev &b)
  {
   if(a.conf != b.conf)   return a.conf > b.conf;
   if(a.isRes != b.isRes) return (!a.isRes && b.isRes);
   return a.tf > b.tf;
  }

void SortEvents()
  {
   int n = ArraySize(g_ev);
   for(int i = 1; i < n; i++)
     {
      Ev key = g_ev[i];
      int j = i - 1;
      while(j >= 0 && EvGreater(g_ev[j], key))
        {
         g_ev[j + 1] = g_ev[j];
         j--;
        }
      g_ev[j + 1] = key;
     }
  }

//====================== ZONE BUILD (spawn / merge / cap) ======================
void RemoveZone(const int idx)
  {
   int n = ArraySize(g_zones);
   for(int i = idx; i < n - 1; i++) g_zones[i] = g_zones[i + 1];
   ArrayResize(g_zones, n - 1);
  }

void SpawnZone(const Ev &e, const int ses)
  {
   int n = ArraySize(g_zones);
   ArrayResize(g_zones, n + 1);
   ZoneS z;
   ZeroMemory(z);
   z.isRes    = e.isRes;
   for(int i = 0; i < 4; i++) z.hasTf[i] = (i == e.tf);
   z.level    = e.lvl;
   z.topP     = e.lvl + g_thick / 2.0;
   z.botP     = e.lvl - g_thick / 2.0;
   z.tfW      = TfWeight(PeriodSeconds(g_tfPer[e.tf]));
   z.wickSum  = e.wick;
   z.wickN    = e.wick > 0 ? 1 : 0;
   z.prom     = e.prom;
   double a   = (e.atr > 0) ? e.atr : g_atrChart;
   z.score    = Score(z.tfW, 1, e.wick, e.prom, a);
   z.sesIdx   = ses;
   g_zones[n] = z;
  }

void Absorb(const int ia, const int ib)
  {
   for(int k = 0; k < 4; k++)
      g_zones[ia].hasTf[k] = g_zones[ia].hasTf[k] || g_zones[ib].hasTf[k];

   double wkA = MathMax(g_zones[ia].wickN, 1);
   double wkB = MathMax(g_zones[ib].wickN, 1);
   g_zones[ia].level   = (g_zones[ia].level * wkA + g_zones[ib].level * wkB) / (wkA + wkB);
   g_zones[ia].wickSum += g_zones[ib].wickSum;
   g_zones[ia].wickN   += g_zones[ib].wickN;
   g_zones[ia].prom     = MathMax(g_zones[ia].prom, g_zones[ib].prom);
   g_zones[ia].tfW      = MathMax(g_zones[ia].tfW, g_zones[ib].tfW);
   g_zones[ia].topP     = g_zones[ia].level + g_thick / 2.0;
   g_zones[ia].botP     = g_zones[ia].level - g_thick / 2.0;

   int cc = CC(g_zones[ia]);
   double wickAvg = g_zones[ia].wickSum / MathMax(g_zones[ia].wickN, 1);
   g_zones[ia].score = Score(g_zones[ia].tfW, cc, wickAvg, g_zones[ia].prom, g_atrChart);
  }

bool ConsolidateOnce(const int ses)
  {
   int n = ArraySize(g_zones);
   if(n < 2) return false;
   double tol = g_atrChart * InpMergeATR;
   for(int a = 0; a < n - 1; a++)
     {
      if(g_zones[a].sesIdx != ses) continue;
      for(int b = a + 1; b < n; b++)
        {
         if(g_zones[b].sesIdx != ses)          continue;
         if(g_zones[a].isRes != g_zones[b].isRes) continue;
         if(g_zones[a].botP <= g_zones[b].topP + tol &&
            g_zones[b].botP <= g_zones[a].topP + tol)
           {
            Absorb(a, b);
            RemoveZone(b);
            return true;
           }
        }
     }
   return false;
  }

void CapSession(const int ses)
  {
   int guard = 0;
   while(guard < 200)
     {
      int cnt = 0;
      for(int i = 0; i < ArraySize(g_zones); i++)
         if(g_zones[i].sesIdx == ses) cnt++;
      if(cnt <= InpCapSes) break;
      int worst = -1;
      double ws = 1e18;
      for(int i = 0; i < ArraySize(g_zones); i++)
         if(g_zones[i].sesIdx == ses && g_zones[i].score < ws)
           {
            ws = g_zones[i].score;
            worst = i;
           }
      if(worst < 0) break;
      RemoveZone(worst);
      guard++;
     }
  }

void BuildZones()
  {
   ArrayResize(g_zones, 0);
   int ne = ArraySize(g_ev);
   int i = 0;
   while(i < ne)
     {
      long bucket = (long)g_ev[i].conf / g_chartSec;   // group by chart bar
      int j = i;
      bool spawned = false;
      int  sesTouched = -1;
      while(j < ne && (long)g_ev[j].conf / g_chartSec == bucket)
        {
         int ses = SessionOf(g_ev[j].conf);
         if(ses >= 0)
           {
            SpawnZone(g_ev[j], ses);
            spawned = true;
            sesTouched = ses;
           }
         j++;
        }
      if(spawned && InpMerge && sesTouched >= 0)
        {
         int g = 0;
         while(ConsolidateOnce(sesTouched) && g < 200) g++;
        }
      if(spawned && sesTouched >= 0)
         CapSession(sesTouched);
      i = j;
     }
  }

//====================== OBJECT HELPERS ======================
void DelObj(const string name)
  {
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
  }

void RectSet(const string name, const datetime t1, const double p1,
             const datetime t2, const double p2, const color c, const bool fill)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
  }

void TextSet(const string name, const datetime t, const double p,
             const string txt, const color c, const int fs)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetString(0, name, OBJPROP_FONT, InpLabelFont);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fs);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
  }

//====================== ZONE RENDER ======================
void DrawAll()
  {
   int drawn = 0;
   int fs = LabFontSize(InpLabSize);
   datetime rightCur = g_lastBarT + (datetime)((long)InpExtendBars * g_chartSec);

   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(g_zones[i].score < InpMinScore) continue;
      int sk = g_zones[i].sesIdx;
      if(sk < 0 || sk >= g_nSes) continue;

      datetime lt = g_ses[sk].firstBarT;
      datetime rt = (sk == g_nSes - 1) ? rightCur : g_ses[sk].lastBarT;
      if(rt <= lt) rt = lt + g_chartSec;

      color zc = ZoneColor(g_zones[i]);
      string base = g_prefix + "z" + IntegerToString(drawn);

      RectSet(base + "f", lt, g_zones[i].topP, rt, g_zones[i].botP,
              BlendWithBackground(zc, TranspOf(g_zones[i].score)), true);

      if(InpBorders)
         RectSet(base + "b", lt, g_zones[i].topP, rt, g_zones[i].botP,
                 BlendWithBackground(zc, 30), false);
      else
         DelObj(base + "b");

      bool wantLab = InpShowLabels && (!InpLatestOnly || sk == g_nSes - 1);
      if(wantLab)
        {
         datetime mid = (datetime)(((long)lt + (long)rt) / 2);
         TextSet(base + "t", mid, g_zones[i].level, ZoneLabelTxt(g_zones[i]),
                 InpLabelColor, fs);
        }
      else
         DelObj(base + "t");

      drawn++;
     }

   // remove stale zone objects from previous, larger draws
   for(int k = drawn; k < g_maxDrawn; k++)
     {
      string base = g_prefix + "z" + IntegerToString(k);
      DelObj(base + "f");
      DelObj(base + "b");
      DelObj(base + "t");
     }
   g_maxDrawn = drawn;
  }

//====================== DASHBOARD ======================
void DashGeometry()
  {
   switch(InpDashSize)
     {
      case DS_TINY:
         g_dfs = 7;  g_rowH = 14; g_dw = 254;
         g_colX[0] = 6; g_colX[1] = 116; g_colX[2] = 162; g_colX[3] = 204;
         break;
      case DS_NORMAL:
         g_dfs = 10; g_rowH = 19; g_dw = 344;
         g_colX[0] = 8; g_colX[1] = 156; g_colX[2] = 218; g_colX[3] = 272;
         break;
      default:
         g_dfs = 8;  g_rowH = 16; g_dw = 290;
         g_colX[0] = 8; g_colX[1] = 132; g_colX[2] = 184; g_colX[3] = 232;
         break;
     }
   int cw = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS, 0);
   int ch = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   int H  = g_rowH * DASH_ROWS + 8;
   g_dx = (InpDashPos == DP_TL || InpDashPos == DP_BL) ? 8 : MathMax(0, cw - g_dw - 8);
   g_dy = (InpDashPos == DP_TL || InpDashPos == DP_TR) ? 8 : MathMax(0, ch - H - 28);
  }

void DashBg(const string name, const int x, const int y,
            const int w, const int h, const color c)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, c);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
  }

void Cell(const int r, const int c, const string txt, const color tc)
  {
   string nm = g_prefix + "d_r" + IntegerToString(r) + "c" + IntegerToString(c);
   if(txt == "")
     {
      DelObj(nm);
      return;
     }
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nm, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, g_dx + g_colX[c]);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, g_dy + 4 + r * g_rowH);
   ObjectSetString(0, nm, OBJPROP_TEXT, txt);
   ObjectSetString(0, nm, OBJPROP_FONT, InpDashFont);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, g_dfs);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, tc);
  }

string BiasTxt(const int nr, const int ns)
  {
   if(nr + ns == 0) return "-";
   if(nr > ns) return g_symUp + " RES";
   if(ns > nr) return g_symDn + " SUP";
   return g_symOn + " BAL";
  }

color BiasCol(const int nr, const int ns)
  {
   if(nr + ns == 0) return InpDashMuted;
   if(nr > ns) return InpDashAccR;
   if(ns > nr) return InpDashAccS;
   return InpDashMuted;
  }

void DrawDash()
  {
   if(!InpShowDash)
     {
      ObjectsDeleteAll(0, g_prefix + "d_");
      return;
     }
   DashGeometry();

   // rebuild in correct z-order if background vanished
   if(ObjectFind(0, g_prefix + "d_bg") < 0)
      ObjectsDeleteAll(0, g_prefix + "d_");

   int H = g_rowH * DASH_ROWS + 8;
   DashBg(g_prefix + "d_bg", g_dx, g_dy, g_dw, H, InpDashBg);
   DashBg(g_prefix + "d_h0", g_dx, g_dy + 2, g_dw, g_rowH, InpDashHdr);
   DashBg(g_prefix + "d_h1", g_dx, g_dy + 2 + 1 * g_rowH, g_dw, g_rowH, InpDashAlt);
   DashBg(g_prefix + "d_h2", g_dx, g_dy + 2 + 6 * g_rowH, g_dw, g_rowH, InpDashAlt);
   DashBg(g_prefix + "d_h3", g_dx, g_dy + 2 + 10 * g_rowH, g_dw, g_rowH, InpDashAlt);

   //--- stats over kept zones (score filter applied, like Pine)
   int tr_[4] = {0, 0, 0, 0}, ts_[4] = {0, 0, 0, 0};
   bool hasUp = false, hasDn = false, hasBest = false, bestRes = true;
   double nearUp = 0, nearDn = 0, upS = 0, dnS = 0, bestS = 0, bestPx = 0;
   string upTf = "", dnTf = "", bestTf = "";
   int bestCC = 0, active = 0, confl = 0, curCnt = 0;
   double sSum = 0;
   double px = g_lastClose;

   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(g_zones[i].score < InpMinScore) continue;
      active++;
      if(g_zones[i].sesIdx == g_nSes - 1) curCnt++;
      int cc = CC(g_zones[i]);
      if(cc > 1) confl++;
      sSum += g_zones[i].score;
      for(int t = 0; t < 4; t++)
         if(g_zones[i].hasTf[t])
           {
            if(g_zones[i].isRes) tr_[t]++; else ts_[t]++;
           }
      if(g_zones[i].level >= px && (!hasUp || g_zones[i].level < nearUp))
        {
         hasUp = true; nearUp = g_zones[i].level;
         upTf = TfSet(g_zones[i]); upS = g_zones[i].score;
        }
      if(g_zones[i].level <= px && (!hasDn || g_zones[i].level > nearDn))
        {
         hasDn = true; nearDn = g_zones[i].level;
         dnTf = TfSet(g_zones[i]); dnS = g_zones[i].score;
        }
      if(g_zones[i].score > bestS)
        {
         hasBest = true;
         bestS  = g_zones[i].score;
         bestPx = g_zones[i].level;
         bestRes = g_zones[i].isRes;
         bestTf = TfSet(g_zones[i]);
         bestCC = cc;
        }
     }
   double avg = active > 0 ? sSum / active : 0;

   //--- row 0: title
   Cell(0, 0, g_symDia + " INTRADAY S/R " + g_symDot + " MTF", InpDashGold);
   Cell(0, 1, "", InpDashMuted);
   Cell(0, 2, "", InpDashMuted);
   Cell(0, 3, TfLabelStr(_Period) + g_symDot + _Symbol, InpDashMuted);

   //--- row 1: TF table header
   Cell(1, 0, "TIMEFRAMES", InpDashTxt);
   Cell(1, 1, "RES", InpDashMuted);
   Cell(1, 2, "SUP", InpDashMuted);
   Cell(1, 3, "BIAS", InpDashMuted);

   //--- rows 2..5: per TF
   for(int t = 0; t < 4; t++)
     {
      int r = 2 + t;
      string dot = g_tfEn[t] ? g_symOn + " " : g_symOff + " ";
      Cell(r, 0, dot + g_tfLab[t], g_tfEn[t] ? InpDashTxt : InpDashMuted);
      Cell(r, 1, g_tfEn[t] ? IntegerToString(tr_[t]) : "-", InpDashAccR);
      Cell(r, 2, g_tfEn[t] ? IntegerToString(ts_[t]) : "-", InpDashAccS);
      Cell(r, 3, g_tfEn[t] ? BiasTxt(tr_[t], ts_[t]) : "off",
           g_tfEn[t] ? BiasCol(tr_[t], ts_[t]) : InpDashMuted);
     }

   //--- row 6: key levels header
   Cell(6, 0, "KEY LEVELS", InpDashTxt);
   Cell(6, 1, "PRICE", InpDashMuted);
   Cell(6, 2, "TF", InpDashMuted);
   Cell(6, 3, "SCORE", InpDashMuted);

   //--- row 7: strongest
   Cell(7, 0, (bestCC > 1 ? g_symStar + " Strongest " + g_symDia
                          : g_symStar + " Strongest"), InpDashGold);
   Cell(7, 1, hasBest ? DoubleToString(bestPx, _Digits) : "-",
        bestRes ? InpDashAccR : InpDashAccS);
   Cell(7, 2, hasBest ? bestTf : "-", InpDashTxt);
   Cell(7, 3, hasBest ? DoubleToString(bestS, 1) : "-", InpDashGold);

   //--- row 8: nearest resistance (nearest zone above)
   Cell(8, 0, g_symUp + " Nearest Res", InpDashAccR);
   Cell(8, 1, hasUp ? DoubleToString(nearUp, _Digits) : "-", InpDashTxt);
   Cell(8, 2, hasUp ? upTf : "-", InpDashTxt);
   Cell(8, 3, hasUp ? DoubleToString(upS, 1) : "-", InpDashMuted);

   //--- row 9: nearest support (nearest zone below)
   Cell(9, 0, g_symDn + " Nearest Sup", InpDashAccS);
   Cell(9, 1, hasDn ? DoubleToString(nearDn, _Digits) : "-", InpDashTxt);
   Cell(9, 2, hasDn ? dnTf : "-", InpDashTxt);
   Cell(9, 3, hasDn ? DoubleToString(dnS, 1) : "-", InpDashMuted);

   //--- row 10: structure header
   Cell(10, 0, "STRUCTURE", InpDashTxt);
   Cell(10, 1, "", InpDashMuted);
   Cell(10, 2, "", InpDashMuted);
   Cell(10, 3, "", InpDashMuted);

   //--- row 11: position + room
   string posTxt = (!hasUp || !hasDn) ? "-" :
                   ((px - nearDn) < (nearUp - px) ? "Near SUP" : "Near RES");
   color posCol = posTxt == "Near SUP" ? InpDashAccS :
                  posTxt == "Near RES" ? InpDashAccR : InpDashMuted;
   Cell(11, 0, "Position", InpDashMuted);
   Cell(11, 1, posTxt, posCol);
   Cell(11, 2, "Room", InpDashMuted);
   Cell(11, 3, (!hasUp || !hasDn) ? "-" :
        DoubleToString((nearUp - nearDn) / MathMax(g_atrChart, 1e-9), 1) + " ATR",
        InpDashTxt);

   //--- row 12: zone counts
   Cell(12, 0, "Zones now/kept", InpDashMuted);
   Cell(12, 1, IntegerToString(curCnt) + "/" + IntegerToString(active), InpDashTxt);
   Cell(12, 2, "Confl", InpDashMuted);
   Cell(12, 3, IntegerToString(confl), InpDashGold);

   //--- row 13: avg + session tag
   Cell(13, 0, "Avg Score", InpDashMuted);
   Cell(13, 1, active > 0 ? DoubleToString(avg, 1) + "/10" : "-", InpDashTxt);
   Cell(13, 2, "Session", InpDashMuted);
   Cell(13, 3, SessTag(), InpDashTxt);
  }

//====================== ALERTS ======================
void Fire(const string msg)
  {
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
  }

void CheckAlerts(const MqlRates &cr[], const int n)
  {
   if(!InpAlertsOn) return;

   //--- new level alerts: any event confirmed after the last seen watermark
   datetime maxConf = g_lastEvConf;
   bool newR = false, newS = false;
   for(int i = 0; i < ArraySize(g_ev); i++)
     {
      if(g_ev[i].conf > g_lastEvConf)
        {
         if(g_ev[i].isRes) newR = true; else newS = true;
        }
      if(g_ev[i].conf > maxConf) maxConf = g_ev[i].conf;
     }
   if(!g_firstPass && InpAlertNew)
     {
      string p = DoubleToString(g_lastClose, _Digits);
      if(newR) Fire("Intraday S/R: new RESISTANCE level formed on " + _Symbol + " @ " + p);
      if(newS) Fire("Intraday S/R: new SUPPORT level formed on " + _Symbol + " @ " + p);
     }
   g_lastEvConf = maxConf;

   //--- touch alerts on the last CLOSED chart bar
   if(n < 3) return;
   datetime bt = cr[n - 2].time;
   if(g_firstPass) { g_lastTouchBar = bt; return; }
   if(bt <= g_lastTouchBar) return;

   double bh = cr[n - 2].high, bl = cr[n - 2].low;
   bool nearRes = false, nearSup = false, strong = false;
   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(g_zones[i].score < InpMinScore) continue;
      if(bh >= g_zones[i].botP && bl <= g_zones[i].topP)
        {
         if(g_zones[i].isRes) nearRes = true; else nearSup = true;
         if(g_zones[i].score >= InpStrongTh) strong = true;
        }
     }
   string p = DoubleToString(g_lastClose, _Digits);
   if(InpAlertTouch && nearRes) Fire("Intraday S/R: price testing a RESISTANCE zone on " + _Symbol + " @ " + p);
   if(InpAlertTouch && nearSup) Fire("Intraday S/R: price testing a SUPPORT zone on " + _Symbol + " @ " + p);
   if(InpAlertStrong && strong) Fire("Intraday S/R: price testing a STRONG zone on " + _Symbol + " @ " + p);
   g_lastTouchBar = bt;
  }

//====================== MAIN REBUILD ======================
void Refresh()
  {
   g_dataOk = true;

   //--- chart rates covering the kept sessions (+weekend margin)
   int keep = (int)Clamp(InpKeepN, 1, 10);
   datetime fromT = DayStartSrv(DayIdx(TimeCurrent()) - (keep * 7 + 21));
   MqlRates cr[];
   int n = CopyRates(_Symbol, _Period, fromT, TimeCurrent() + g_chartSec, cr);
   if(n < 50)
     {
      g_dataOk = false;
      return;
     }

   g_lastBarT  = cr[n - 1].time;
   g_lastClose = cr[n - 1].close;

   //--- chart ATR (Wilder), value at last closed bar
   double atr = 0;
   for(int i = 0; i < n - 1; i++)
     {
      double tr = (i == 0) ? (cr[i].high - cr[i].low)
                  : MathMax(cr[i].high - cr[i].low,
                            MathMax(MathAbs(cr[i].high - cr[i - 1].close),
                                    MathAbs(cr[i].low  - cr[i - 1].close)));
      if(i < InpATRLen) atr = (atr * i + tr) / (i + 1);
      else              atr = (atr * (InpATRLen - 1) + tr) / InpATRLen;
     }
   g_atrChart = atr;

   g_thick = (InpThickMode == THICK_ATR)
             ? g_atrChart * InpThickATR
             : g_lastClose * InpThickPct / 100.0;
   if(g_thick <= 0) g_thick = _Point * 10;

   //--- sessions
   if(!CollectSessions(cr, n))
     {
      g_dataOk = false;
      return;
     }

   //--- pivot events on all enabled timeframes
   ArrayResize(g_ev, 0);
   for(int t = 0; t < 4; t++) ScanTf(t);
   SortEvents();

   //--- zones
   BuildZones();

   //--- render
   DrawAll();
   DrawDash();

   //--- alerts
   CheckAlerts(cr, n);
   g_firstPass = false;

   ChartRedraw();
  }

//====================== STANDARD HANDLERS ======================
int OnInit()
  {
   g_prefix = InpObjPrefix;
   g_pL = MathMax(1, InpPivotL);
   g_pR = MathMax(1, InpPivotR);
   g_chartSec = PeriodSeconds(_Period);
   if(g_chartSec <= 0) g_chartSec = 60;

   g_tfEn[0] = InpEn1; g_tfPer[0] = InpTf1;
   g_tfEn[1] = InpEn2; g_tfPer[1] = InpTf2;
   g_tfEn[2] = InpEn3; g_tfPer[2] = InpTf3;
   g_tfEn[3] = InpEn4; g_tfPer[3] = InpTf4;
   for(int i = 0; i < 4; i++) g_tfLab[i] = TfLabelStr(g_tfPer[i]);

   // unicode symbols
   g_symUp   = ShortToString(0x25B2);   // filled up triangle
   g_symDn   = ShortToString(0x25BC);   // filled down triangle
   g_symDia  = ShortToString(0x25C6);   // filled diamond
   g_symStar = ShortToString(0x2605);   // filled star
   g_symMid  = ShortToString(0x00B7);   // middle dot (no stars)
   g_symDot  = ShortToString(0x00B7);   // separator dot
   g_symOn   = ShortToString(0x25CF);   // filled circle
   g_symOff  = ShortToString(0x25CB);   // hollow circle

   SetIndexBuffer(0, g_buf, INDICATOR_DATA);
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
   IndicatorSetString(INDICATOR_SHORTNAME, "Intraday MTF SR Zones");

   g_maxDrawn = 0;
   g_firstPass = true;
   g_lastEvConf = 0;
   g_lastTouchBar = 0;
   g_prevBarT = 0;

   EventSetTimer(MathMax(5, InpRefreshSec));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
  }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 2) return rates_total;

   datetime curBar = time[rates_total - 1];
   if(prev_calculated == 0 || curBar != g_prevBarT || !g_dataOk)
     {
      g_prevBarT = curBar;
      Refresh();
     }
   return rates_total;
  }

void OnTimer()
  {
   // recovery: missing objects (template load, object wipe) or pending HTF data
   bool needsRedraw = !g_dataOk;
   if(!needsRedraw && InpShowDash && ObjectFind(0, g_prefix + "d_bg") < 0)
      needsRedraw = true;
   if(!needsRedraw && g_maxDrawn > 0 && ObjectFind(0, g_prefix + "z0f") < 0)
      needsRedraw = true;
   // dashboard session tag / clock refresh is cheap enough to always run
   Refresh();
   if(needsRedraw) ChartRedraw();
  }

void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
      DrawDash();   // reposition panel on resize/scale
  }
//+------------------------------------------------------------------+