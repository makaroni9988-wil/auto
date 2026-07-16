//+---------------------------------------------------------------------+
//|                                              AOI_Indicator.mq5      |
//|   Multi-Timeframe Swing High/Low Area of Interest (AOI) drawer      |
//|                                                                     |
//|   - Two independently "locked" timeframes (each scans its own TF    |
//|     regardless of the chart's current timeframe), each with its     |
//|     own color.                                                      |
//|   - Line width / line style are global (apply to both TFs).         |
//|   - Zones are formed by clustering swing highs & lows (fractals)    |
//|     within an ATR-based tolerance.                                  |
//|   - A zone only becomes a valid AOI once its combined support +     |
//|     resistance touch count reaches InpMinTouches.                   |
//|   - Only the newest InpMaxZonesPerTF valid zones per timeframe are  |
//|     drawn (slot 0 = newest). A zone drops off once a newer valid    |
//|     AOI bumps it out of the top N, or it ages out of InpScanBars.   |
//|     Getting retested does NOT remove it on its own.                 |
//+---------------------------------------------------------------------+
#property copyright "Custom AOI Indicator"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots   0

//================== TIMEFRAME 1 ==================
input ENUM_TIMEFRAMES InpTF1              = PERIOD_M5;         // TF1: Timeframe (locked)
input color           InpColor1           = clrSilver;         // TF1: Zone color

//================== TIMEFRAME 2 ==================
input bool            InpEnableTF2        = true;              // TF2: Enable
input ENUM_TIMEFRAMES InpTF2              = PERIOD_M30;        // TF2: Timeframe (locked)
input color           InpColor2           = clrGold;           // TF2: Zone color

//================== GLOBAL ZONE STYLE (applies to both TFs) ==================
input int               InpLineWidth      = 1;                 // Border line width
input ENUM_LINE_STYLE   InpLineStyle      = STYLE_SOLID;       // Border line style

//================== ZONE DETECTION ==================
input int     InpScanBars         = 200;   // Bars to scan back (old zones age out beyond this)
input int     InpFractalPeriod    = 2;     // Bars each side to confirm a swing point
input int     InpATRPeriod        = 14;    // ATR period (clustering tolerance)
input double  InpToleranceATRMult = 0.3;   // Cluster tolerance = ATR * this multiplier
input int     InpMinTouches       = 3;     // Min combined support+resistance touches to validate a zone
input int     InpMaxZonesPerTF    = 2;     // Max AOI zones shown PER locked timeframe (1-3 recommended)

//================== ZONE STRENGTH LABEL ==================
// change to "fresh" zone, newly formed
input bool    InpShowTouchLabel   = true;            // Show "xB / yW" (body/wick touch) label on each AOI
input color   InpLabelColor       = clrLime;         // Label color (normal / not-yet-solid zones)
input string  InpLabelFont        = "Consolas Bold"; // Label font
input int     InpLabelFontSize    = 8;               // Label font size

//================== SOLID (RISK) ZONE HIGHLIGHT ================== 
// change to "risk" zone, already been touch/retested many times
input bool    InpHighlightSolid    = true;      // Highlight label when a zone is "solid" (risk)
input color   InpSolidColor        = clrWhite;  // Label color when a zone is solid
input int     InpSolidMinTouches   = 4;         // Solid (risk) needs at least this many total touches
input double  InpSolidMinBodyRatio = 0.6;       // Solid (risk) needs body touches / total >= this (0.6 = 60%)

//================== REFRESH SETTINGS ==================
input int     InpRefreshSeconds    = 30;        // Force refresh interval in seconds (0 = only on new bars)

// Instance-unique object prefix, built in OnInit: "AOI_<TF1>_<TF2>_".
// A fixed "AOI_" meant two attached copies shared one namespace:
// removing/reiniting ONE deleted the OTHER's zones via ObjectsDeleteAll,
// and same-TF copies collided outright. TF-pair prefix = each instance
// cleans and owns only its own objects.
string g_objPrefix;

//--- a swing point found on a chart
struct SwingPoint
{
   datetime time;
   double   price;
   double   bodyPrice; // candle's body extreme (open/close side) at this swing point
   bool     isHigh;    // true = swing high (resistance touch), false = swing low (support touch)
};

//--- a clustered zone built from one or more swing points
struct ZoneData
{
   double   upper;
   double   lower;
   int      touchSupport;
   int      touchResistance;
   int      touchBody;    // touches confirmed by candle body (open/close), not just wick
   int      touchWick;    // touches that only reached the zone by wick
   datetime firstTime;
   datetime lastTouchTime;
};

datetime g_lastBarTime[2];
datetime g_lastForceRefresh[2];   // Track force refresh per slot
string   g_tfName[2];
int      g_atrHandle[2];
ENUM_TIMEFRAMES g_tf[2];
color    g_color[2];

// Only print a given failure once while it persists, not every bar.
bool g_loggedNoHistory[2]      = {false, false};
bool g_loggedATRCopyFail[2]    = {false, false};

//------------------------------------------------------------------
// HANDLE WARM-UP GRACE
//------------------------------------------------------------------
// An indicator handle recreated on init/reinit is calculated
// asynchronously by the terminal, so the very first CopyBuffer() read
// after e.g. a chart-timeframe switch can land before the data exists
// (error 4806). That is a normal transient, not a failure: it retries
// on the next time this slot is processed and succeeds. During a
// short grace window after init, "not ready" is therefore retried
// silently; only if it persists past the window (missing broker
// history, broken symbol, etc.) is it reported.
uint g_initTick = 0;

#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
}

// Forward declarations
bool CheckZoneObjectsMissing(int slot);

//+------------------------------------------------------------------+
int OnInit()
{
   g_tf[0]    = InpTF1;
   g_tf[1]    = InpTF2;
   g_color[0] = InpColor1;
   g_color[1] = InpColor2;

   for(int s = 0; s < 2; s++)
   {
      g_tfName[s]        = TimeframeToString(g_tf[s]);
      g_lastBarTime[s]   = 0;
      g_lastForceRefresh[s] = 0;
      g_atrHandle[s]     = INVALID_HANDLE;
   }

   g_objPrefix = "AOI_" + g_tfName[0] + "_" + (InpEnableTF2 ? g_tfName[1] : "X") + "_";

   // Clear any stale error so a failure below reports ITS code, not a leftover one.
   ResetLastError();

   // Only create the ATR handle for a slot that will actually be scanned.
   // Creating the TF2 handle while TF2 is disabled would make MT5 keep
   // calculating an ATR series in the background that is never read.
   g_atrHandle[0] = iATR(_Symbol, g_tf[0], InpATRPeriod);
   if(InpEnableTF2)
      g_atrHandle[1] = iATR(_Symbol, g_tf[1], InpATRPeriod);

   if(g_atrHandle[0] == INVALID_HANDLE ||
      (InpEnableTF2 && g_atrHandle[1] == INVALID_HANDLE))
   {
      Print("AOI_Indicator ERROR: failed to create ATR handle, error code ", GetLastError(), ".");
      return(INIT_FAILED);
   }

   // Start the warm-up grace clock (see StillWarmingUp above).
   g_initTick = GetTickCount();

   // Duplicate-timeframe sanity check: with TF1 == TF2 both slots would
   // scan the same bars and stack identical zones in two colors on top of
   // each other. Not fatal, but almost certainly not what was intended.
   if(InpEnableTF2)
   {
      ENUM_TIMEFRAMES r1 = (g_tf[0] == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : g_tf[0];
      ENUM_TIMEFRAMES r2 = (g_tf[1] == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : g_tf[1];
      if(r1 == r2)
         Print("AOI_Indicator WARNING: TF1 and TF2 are the same timeframe (",
               g_tfName[0], "). Both slots will draw identical overlapping zones.");
   }

   // 1-second self-heal timer (suite standard, matches Sub-/Float-Chart).
   // Ticks alone can't recover wiped zones or force-refresh on a dead or
   // closed market -- the timer runs the same slot logic once a second so
   // missing-object recovery and new locked-TF bar detection keep working
   // with zero ticks. The per-tick path (OnCalculate) is unchanged.
   EventSetTimer(1);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   // Keep the zones drawn when only the chart's visible timeframe changes
   // (REASON_CHARTCHANGE) -- the locked timeframes are independent of that.
   // For every other reason (inputs changed, indicator removed, chart
   // closed, template loaded, recompiled, etc.) clear the old objects so
   // stale zones from a previous setting/timeframe don't get left behind.
   if(reason != REASON_CHARTCHANGE)
      ObjectsDeleteAll(0, g_objPrefix);

   if(g_atrHandle[0] != INVALID_HANDLE) IndicatorRelease(g_atrHandle[0]);
   if(g_atrHandle[1] != INVALID_HANDLE) IndicatorRelease(g_atrHandle[1]);
}

//+------------------------------------------------------------------+
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
   ProcessAllSlots();
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Timer: self-heal + new-bar/refresh without needing a tick.       |
//| Runs the exact same slot logic as OnCalculate, so wiped zones    |
//| recover and new locked-TF bars are picked up on a frozen/closed  |
//| market. Cheap when nothing changed (one CopyTime per slot).      |
//+------------------------------------------------------------------+
void OnTimer()
{
   ProcessAllSlots();
}

//+------------------------------------------------------------------+
//| Shared slot processing (called from both OnCalculate and OnTimer)|
//| -- identical logic to the original OnCalculate body, unchanged.  |
//+------------------------------------------------------------------+
void ProcessAllSlots()
{
   // Both locked-TF slots share identical gating; slot 1 only when enabled.
   for(int slot = 0; slot < 2; slot++)
   {
      if(slot == 1 && !InpEnableTF2)
         break;

      bool process = false;

      // iTime() only reports what's already synced -- unlike Copy* functions,
      // it doesn't itself trigger a sync request for a locked TF the chart
      // isn't on, so it could sit at 0 for a while after attach/reinit and
      // delay new-bar detection until the next force-refresh. CopyTime()
      // actively requests that sync, same fix as ProcessTimeframe's history
      // check below.
      datetime curBarTime = 0;
      datetime tfTime[];
      ArraySetAsSeries(tfTime, true);
      if(CopyTime(_Symbol, g_tf[slot], 0, 1, tfTime) > 0)
         curBarTime = tfTime[0];
      if(curBarTime > 0 && curBarTime != g_lastBarTime[slot])
         process = true;

      // periodic force refresh for this slot
      if(!process && InpRefreshSeconds > 0)
      {
         datetime curTime = TimeCurrent();
         if(curTime - g_lastForceRefresh[slot] >= InpRefreshSeconds)
         {
            process = true;
            g_lastForceRefresh[slot] = curTime;
         }
      }

      // objects went missing since last time (template reload, delete-all, ..)
      if(!process && CheckZoneObjectsMissing(slot))
         process = true;

      if(process)
         ProcessTimeframe(slot);
   }
}

//+------------------------------------------------------------------+
string TimeframeToString(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

//+------------------------------------------------------------------+
//| Check if zone objects for a slot are missing                     |
//+------------------------------------------------------------------+
bool CheckZoneObjectsMissing(int slot)
{
   // Check if any zone object for this slot exists (label or rectangle)
   for(int idx = 0; idx < InpMaxZonesPerTF; idx++)
   {
      string objName = g_objPrefix + IntegerToString(slot) + "_" + g_tfName[slot] + "_" + IntegerToString(idx);
      if(ObjectFind(0, objName) >= 0 || ObjectFind(0, objName + "_LBL") >= 0)
         return false;
   }
   
   // Only trigger recovery if this slot should have zones (lastBarTime was set, meaning it processed before)
   if(g_lastBarTime[slot] > 0)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Recompute & redraw AOI zones for one locked timeframe slot       |
//+------------------------------------------------------------------+
void ProcessTimeframe(int slot)
{
   ENUM_TIMEFRAMES tf  = g_tf[slot];
   color           clr = g_color[slot];

   int wantedBars = InpScanBars + InpFractalPeriod * 2;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   // CopyRates() is used here instead of iBars() because iBars() only
   // reflects history that something has ALREADY caused the terminal to
   // sync. For a locked TF like M5/M30 that no chart has ever opened,
   // nothing ever triggers that sync, so iBars() can sit at 0
   // indefinitely -- not just during warm-up. CopyRates() actively
   // requests the sync itself, so it both fetches the data and fixes
   // the root cause of the "available=0" case that persisted past the
   // warm-up grace window.
   ResetLastError();
   int copied = CopyRates(_Symbol, tf, 0, wantedBars, rates);

   if(copied < InpFractalPeriod * 4 + 1)
   {
      // Give the terminal a short grace window (right after init/reinit,
      // e.g. attaching the indicator or switching timeframe) to finish
      // syncing this TF's history before treating "no bars yet" as an
      // actual problem. Same protocol as the ATR warm-up check below.
      if(!StillWarmingUp() && !g_loggedNoHistory[slot])
      {
         Print("AOI_Indicator: history for ", g_tfName[slot],
               " isn't fully available yet (have ", copied, ", need at least ", InpFractalPeriod * 4 + 1,
               "). Zones on this TF are on hold and will keep retrying..");
         g_loggedNoHistory[slot] = true;
      }
      return; // history not ready -- retried the next time this slot is processed (new bar / force-refresh / missing objects), not necessarily the next tick
   }
   g_loggedNoHistory[slot] = false;

   // --- ATR for the clustering tolerance, read from the iATR handle ---
   // Warm-up protocol: ask the terminal FIRST whether the handle has
   // finished calculating, instead of blindly calling CopyBuffer into a
   // not-ready handle. While warming up, retried silently the next time
   // this slot is processed.
   if(BarsCalculated(g_atrHandle[slot]) <= 0)
   {
      if(!StillWarmingUp() && !g_loggedATRCopyFail[slot])
      {
         Print("AOI_Indicator: ATR data for ", g_tfName[slot],
               " isn't ready yet after warm-up (error code ", GetLastError(), "). Will keep retrying..");
         g_loggedATRCopyFail[slot] = true;
      }
      return; // ATR not ready -- retried the next time this slot is processed
   }

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   ResetLastError();
   if(CopyBuffer(g_atrHandle[slot], 0, 0, 1, atrBuf) <= 0)
   {
      int err = GetLastError();

      // 4806 = data not ready yet: normal right after init/reinit.
      if(err == 4806 && StillWarmingUp())
         return; // retried the next time this slot is processed, silently

      if(!g_loggedATRCopyFail[slot])
      {
         Print("AOI_Indicator ERROR: CopyBuffer() failed for ", g_tfName[slot],
               " ATR handle, error code ", err, ".");
         g_loggedATRCopyFail[slot] = true;
      }
      return; // retried the next time this slot is processed
   }
   g_loggedATRCopyFail[slot] = false;
   double tolerance = atrBuf[0] * InpToleranceATRMult;

   // Only now that data is confirmed good do we mark this bar as processed.
   // Use rates[0].time (already verified via the successful CopyRates()
   // above) rather than a separate iTime() call -- iTime() can lag behind
   // CopyRates() briefly during sync, which could otherwise leave
   // g_lastBarTime stuck at a stale/zero value and make OnCalculate think
   // every tick is still a new bar.
   g_lastBarTime[slot] = rates[0].time;

   // Stamp the refresh clock on EVERY successful process (new-bar path
   // included) -- previously only the timer path stamped it, so a
   // redundant force-refresh could fire right after a new-bar recompute.
   g_lastForceRefresh[slot] = TimeCurrent();

   if(tolerance <= 0) return;

   //--- 1) Collect swing points (fractals) ---
   SwingPoint points[];
   ArrayResize(points, copied * 2);
   int pCount = 0;

   for(int i = copied - InpFractalPeriod - 1; i >= InpFractalPeriod; i--)
   {
      bool isHigh = true;
      bool isLow  = true;
      for(int k = 1; k <= InpFractalPeriod; k++)
      {
         if(rates[i].high < rates[i-k].high || rates[i].high < rates[i+k].high) isHigh = false;
         if(rates[i].low  > rates[i-k].low  || rates[i].low  > rates[i+k].low)  isLow  = false;
      }
      if(isHigh)
      {
         points[pCount].time      = rates[i].time;
         points[pCount].price     = rates[i].high;
         points[pCount].bodyPrice = MathMax(rates[i].open, rates[i].close);
         points[pCount].isHigh    = true;
         pCount++;
      }
      if(isLow)
      {
         points[pCount].time      = rates[i].time;
         points[pCount].price     = rates[i].low;
         points[pCount].bodyPrice = MathMin(rates[i].open, rates[i].close);
         points[pCount].isHigh    = false;
         pCount++;
      }
   }
   ArrayResize(points, pCount);
   // NOTE: no sort needed here. The collection loop above walks the series
   // array from the oldest index down to the newest index, so points[] is
   // already appended in ascending time order (oldest -> newest) by
   // construction. Sorting it again was pure wasted CPU (O(n^2) bubble sort
   // on data that's already sorted) on every recalculation.

   //--- 2) Cluster swing points into zones ---
   ZoneData zones[];
   int zCount = 0;

   for(int i = 0; i < pCount; i++)
   {
      int foundIdx = -1;
      for(int z = 0; z < zCount; z++)
      {
         double zLow  = zones[z].lower - tolerance;
         double zHigh = zones[z].upper + tolerance;
         if(points[i].price >= zLow && points[i].price <= zHigh)
         {
            foundIdx = z;
            break;
         }
      }
      if(foundIdx == -1)
      {
         ArrayResize(zones, zCount + 1);
         zones[zCount].upper           = points[i].price;
         zones[zCount].lower           = points[i].price;
         zones[zCount].touchSupport    = points[i].isHigh ? 0 : 1;
         zones[zCount].touchResistance = points[i].isHigh ? 1 : 0;
         zones[zCount].firstTime       = points[i].time;
         zones[zCount].lastTouchTime   = points[i].time;
         // A brand-new zone is seeded by one point; body vs wick is judged
         // against that same point's own range (wick price vs body price).
         bool bodyIn = (points[i].bodyPrice >= points[i].price - tolerance &&
                        points[i].bodyPrice <= points[i].price + tolerance);
         zones[zCount].touchBody = bodyIn ? 1 : 0;
         zones[zCount].touchWick = bodyIn ? 0 : 1;
         zCount++;
      }
      else
      {
         if(points[i].price > zones[foundIdx].upper) zones[foundIdx].upper = points[i].price;
         if(points[i].price < zones[foundIdx].lower) zones[foundIdx].lower = points[i].price;
         if(points[i].isHigh) zones[foundIdx].touchResistance++;
         else                 zones[foundIdx].touchSupport++;
         zones[foundIdx].lastTouchTime = points[i].time;

         // Body touch = the candle's open/close also reached into the
         // zone's current range (a real close-based rejection/entry, not
         // just a wick poking in). Wick touch = only the high/low reached.
         double zLowNow  = zones[foundIdx].lower - tolerance;
         double zHighNow = zones[foundIdx].upper + tolerance;
         bool bodyIn = (points[i].bodyPrice >= zLowNow && points[i].bodyPrice <= zHighNow);
         if(bodyIn) zones[foundIdx].touchBody++;
         else       zones[foundIdx].touchWick++;
      }
   }

   //--- 3) Keep only zones meeting the minimum combined touch count ---
   ZoneData validZones[];
   int vCount = 0;
   for(int z = 0; z < zCount; z++)
   {
      int total = zones[z].touchSupport + zones[z].touchResistance;
      if(total >= InpMinTouches)
      {
         ArrayResize(validZones, vCount + 1);
         validZones[vCount] = zones[z];
         vCount++;
      }
   }

   SortZonesByLastTouchDesc(validZones, vCount); // newest first
   int showCount = MathMin(InpMaxZonesPerTF, vCount);

   //--- 4) Draw the newest N valid zones into fixed slots ---
   //     Slot 0 = newest AOI, slot 1 = next newest, etc.
   //     A zone only drops off once a newer valid AOI bumps it out of
   //     the top N, or it ages out beyond InpScanBars. Getting
   //     retested does NOT remove it while it's still among the newest.
   for(int idx = 0; idx < showCount; idx++)
   {
      ZoneData zn = validZones[idx];
      string objName = g_objPrefix + IntegerToString(slot) + "_" + g_tfName[slot] + "_" + IntegerToString(idx);
      datetime endTime = rates[0].time + PeriodSeconds(tf) * 5; // extend a little into the future
      DrawZone(objName, zn.firstTime, endTime, zn.upper, zn.lower, clr);

      if(InpShowTouchLabel)
      {
         string lblName = objName + "_LBL";
         string lblText = IntegerToString(zn.touchBody) + "-B / " + IntegerToString(zn.touchWick) + "W" + StringFormat("%50s", "");

         color lblColor = InpLabelColor;
         if(InpHighlightSolid)
         {
            int totalTouches = zn.touchBody + zn.touchWick;
            double bodyRatio = (totalTouches > 0) ? (double)zn.touchBody / totalTouches : 0.0;
            bool isSolid = (totalTouches >= InpSolidMinTouches && bodyRatio >= InpSolidMinBodyRatio);
            if(isSolid) lblColor = InpSolidColor;
         }

         // Anchored at the zone's right edge (near current price/time) so it's
         // always visible without scrolling back to where the zone first formed.
         DrawLabel(lblName, endTime, zn.upper, lblText, lblColor);
      }
   }

   //--- 5) Clear any slots that no longer have a valid zone ---
   for(int idx = showCount; idx < InpMaxZonesPerTF; idx++)
   {
      string objName = g_objPrefix + IntegerToString(slot) + "_" + g_tfName[slot] + "_" + IntegerToString(idx);
      ObjectDelete(0, objName);
      ObjectDelete(0, objName + "_LBL");
   }

   // Force an immediate repaint now that this TF's zones/labels have been
   // drawn, moved, or cleared. This function only reaches this point when a
   // new bar actually closed on the locked timeframe (see the early return
   // above), so this never adds cost on ticks where nothing changed.
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void DrawZone(string name, datetime t1, datetime t2, double priceHigh, double priceLow, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ResetLastError();
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, priceHigh, t2, priceLow))
      {
         Print("AOI_Indicator ERROR: failed to create zone '", name, "', error code ", GetLastError(), ".");
         return;
      }
   }
   else
   {
      ObjectMove(0, name, 0, t1, priceHigh);
      ObjectMove(0, name, 1, t2, priceLow);
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, name, OBJPROP_STYLE, InpLineStyle);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
void DrawLabel(string name, datetime t, double price, string text, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ResetLastError();
      if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, price))
      {
         Print("AOI_Indicator ERROR: failed to create label '", name, "', error code ", GetLastError(), ".");
         return;
      }
   }
   else
      ObjectMove(0, name, 0, t, price);

   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, InpLabelFont);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpLabelFontSize);
   // RIGHT_LOWER: text sits just above-left of the anchor point, so with the
   // anchor at the zone's right edge, the label hugs current price action.
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
// NOTE: there is intentionally no "sort points by time" helper here.
// The collection loop in ProcessTimeframe() walks the series array from
// the oldest index down to the newest, so points[] is already in
// ascending time order by construction.
//+------------------------------------------------------------------+
void SortZonesByLastTouchDesc(ZoneData &arr[], int count)
{
   for(int i = 0; i < count - 1; i++)
      for(int j = 0; j < count - 1 - i; j++)
         if(arr[j].lastTouchTime < arr[j+1].lastTouchTime)
         {
            ZoneData tmp = arr[j];
            arr[j]   = arr[j+1];
            arr[j+1] = tmp;
         }
}
//+------------------------------------------------------------------+