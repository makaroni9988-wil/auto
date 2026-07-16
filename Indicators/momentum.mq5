//+------------------------------------------------------------------+
//|                                                     Momentum.mq5 |
//|        Multi-timeframe EMA/ADX/DI/RSI momentum dashboard         |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//==================================================================
// DASHBOARD POSITION / STYLE
//==================================================================
input ENUM_BASE_CORNER InpCorner = CORNER_LEFT_UPPER; // Chart corner to anchor the dashboard to
input int X_Distance  = 3;   // X distance FROM the chosen corner (260)
input int Y_Distance  = 25;  // Y distance FROM the chosen corner (LB 3)

input int CellWidth   = 50;
input int CellHeight  = 25;

input string FontName = "Consolas Bold";
input int    FontSize = 9;

input color TextColor       = clrYellow;
input color BackgroundColor = clrBlack;

// Background fill and border are now independent toggles. Previously the
// BackgroundColor fill only appeared when ShowBorder was on, because the
// cell box object was only created for the border.
input bool  ShowBackground  = false;
input bool  ShowBorder      = false;
input color BorderColor     = clrGray;
input int   BorderThickness = 1;

input color WeakColor   = clrRed;
input color MediumColor = clrWhiteSmoke;
input color StrongColor = clrLime;

//==================================================================
// SIGNAL SETTINGS
//==================================================================
input int EMAPeriod = 20;
input int RSIPeriod = 9;
input int ADXPeriod = 14;

input double MinDIDifference = 3.0;

input double BuyRSILevel  = 60.0;
input double SellRSILevel = 40.0;

input double WeakADXLevel   = 20.0;
input double StrongADXLevel = 25.0;

//==================================================================
// TIMEFRAME SETTINGS
//==================================================================
input bool ShowM1  = false;
input bool ShowM5  = true;
input bool ShowM15 = false;
input bool ShowM30 = true;
input bool ShowH1  = false;
input bool ShowH4  = true;
input bool ShowD1  = false;

//==================================================================
// REFRESH SETTINGS
//==================================================================
input int RefreshSeconds = 1;

//==================================================================
// INTERNAL
//==================================================================
// Instance-unique object prefix, built in OnInit from the panel position
// (suite standard: identity by configuration) -- two copies anchored to
// different corners/offsets own separate objects.
string Prefix;

//==================================================================
// CORNER -> TOP-LEFT BASE POINT
//==================================================================
// Every dashboard object stays CORNER_LEFT_UPPER internally (grid math,
// anchors, growth direction all untouched -- the panel CANNOT break).
// The chosen corner + offsets are simply TRANSLATED into a top-left
// base point (g_baseX/g_baseY) using the chart's pixel size and the
// dashboard's own size. Recomputed every timer pass: a chart resize
// moves the base, which invalidates the draw caches, and the next
// draw repositions everything -- corner-anchored within one second.
int g_baseX = 0;
int g_baseY = 0;

int PanelWidth(void)
{
   // columns 0..4 at 1.0 width + the SIGNAL column at 1.9 width
   return 5 * CellWidth + (int)(CellWidth * 1.9);
}

int PanelHeight(void)
{
   int rows = 1; // header
   for(int i = 0; i < 7; i++)
      if(TFEnabled[i])
         rows++;
   return rows * CellHeight;
}

// Returns true when the base point moved (init, chart resize, or a
// window-size change from adding/removing subwindows).
bool ComputeBase(void)
{
   int cw = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);

   int bx = X_Distance;
   int by = Y_Distance;

   if(InpCorner == CORNER_RIGHT_UPPER || InpCorner == CORNER_RIGHT_LOWER)
      bx = cw - X_Distance - PanelWidth();
   if(InpCorner == CORNER_LEFT_LOWER || InpCorner == CORNER_RIGHT_LOWER)
      by = ch - Y_Distance - PanelHeight();

   if(bx == g_baseX && by == g_baseY)
      return false;

   g_baseX = bx;
   g_baseY = by;
   return true;
}

ENUM_TIMEFRAMES TFList[7] =
{
   PERIOD_M1,
   PERIOD_M5,
   PERIOD_M15,
   PERIOD_M30,
   PERIOD_H1,
   PERIOD_H4,
   PERIOD_D1
};

bool TFEnabled[7];

int EMAHandle[7];
int RSIHandle[7];
int ADXHandle[7];

//==================================================================
// CHANGE-DETECTION CACHE
//==================================================================
// The header (labels "TF/EMA/ADX/DI/RSI/SIGNAL") never changes after
// init/reinit, so it only needs to be (re)drawn once -- g_headerNeedsRedraw
// is reset to true in OnInit (which runs right after OnDeinit wipes all
// dashboard objects), guaranteeing it gets rebuilt whenever it needs to be
// and skipped on every other timer tick otherwise.
bool g_headerNeedsRedraw = true;

// Per-timeframe-row cache: a row is only re-drawn (and only then does the
// chart get marked for a redraw) when its computed text or color actually
// differs from what's already on screen. g_cellInitialized[] is reset to
// false in OnInit for the same reason as above, so every row is guaranteed
// a full draw right after init/reinit even though its cached values are
// otherwise untouched.
bool   g_cellInitialized[7];

string g_lastEmaText[7];
color  g_lastEmaColor[7];

string g_lastAdxText[7];
color  g_lastAdxColor[7];

string g_lastDiText[7];
color  g_lastDiColor[7];

string g_lastRsiText[7];
color  g_lastRsiColor[7];

string g_lastSigText[7];
color  g_lastSigColor[7];

//==================================================================
// TIMEFRAME NAME
//==================================================================
string TFName(ENUM_TIMEFRAMES tf)
{
   if(tf == PERIOD_M1)  return "M1";
   if(tf == PERIOD_M5)  return "M5";
   if(tf == PERIOD_M15) return "M15";
   if(tf == PERIOD_M30) return "M30";
   if(tf == PERIOD_H1)  return "H1";
   if(tf == PERIOD_H4)  return "H4";
   if(tf == PERIOD_D1)  return "D1";

   return "TF";
}

///==================================================================
// DELETE DASHBOARD
//==================================================================
void DeleteDashboard()
{
   ObjectsDeleteAll(0,
                    Prefix);

   ChartRedraw(0);
}

//==================================================================
// MAKE CELL BACKGROUND / BORDER
//==================================================================
// The cell box object carries BOTH the background fill and the border,
// so it has to exist when either feature is turned on.
bool CellBoxVisible()
{
   return (ShowBorder || ShowBackground);
}

void MakeCellBox(string name,
                 int x,
                 int y,
                 int w,
                 int h)
{
   if(ObjectFind(0,name) < 0)
   {
      ResetLastError();
      if(!ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0))
      {
         Print("Momentum ERROR: failed to create cell box '", name, "', error code ", GetLastError(), ".");
         return;
      }
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }

   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,BackgroundColor);

   if(ShowBorder)
      ObjectSetInteger(0,name,OBJPROP_COLOR,BorderColor);
   else
      ObjectSetInteger(0,name,OBJPROP_COLOR,BackgroundColor);

   ObjectSetInteger(0,name,OBJPROP_WIDTH,BorderThickness);
}

//==================================================================
// MAKE TEXT LABEL
//==================================================================
void MakeLabel(string name,
               string text,
               int x,
               int y,
               color txtColor)
{
   if(ObjectFind(0,name) < 0)
   {
      ResetLastError();
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
      {
         Print("Momentum ERROR: failed to create label '", name, "', error code ", GetLastError(), ".");
         return;
      }
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }

   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x + 6);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y + 4);
   ObjectSetInteger(0,name,OBJPROP_COLOR,txtColor);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,FontSize);
   ObjectSetString(0,name,OBJPROP_FONT,FontName);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
}

//==================================================================
// MAKE CENTER LABEL
//==================================================================
void MakeCenterLabel(string name,
                     string text,
                     int x,
                     int y,
                     color txtColor)
{
   if(ObjectFind(0,name) < 0)
   {
      ResetLastError();
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
      {
         Print("Momentum ERROR: failed to create center label '", name, "', error code ", GetLastError(), ".");
         return;
      }

      ObjectSetInteger(0,name,
                       OBJPROP_CORNER,
                       CORNER_LEFT_UPPER);

      ObjectSetInteger(0,name,
                       OBJPROP_ANCHOR,
                       ANCHOR_CENTER);

      ObjectSetInteger(0,name,
                       OBJPROP_SELECTABLE,
                       false);

      ObjectSetInteger(0,name,
                       OBJPROP_HIDDEN,
                       true);
   }

   ObjectSetInteger(0,name,
                    OBJPROP_XDISTANCE,
                    x + CellWidth / 2);

   ObjectSetInteger(0,name,
                    OBJPROP_YDISTANCE,
                    y + CellHeight / 2);

   ObjectSetInteger(0,name,
                    OBJPROP_COLOR,
                    txtColor);

   ObjectSetInteger(0,name,
                    OBJPROP_FONTSIZE,
                    FontSize);

   ObjectSetString(0,name,
                   OBJPROP_FONT,
                   FontName);

   ObjectSetString(0,name,
                   OBJPROP_TEXT,
                   text);
}

//==================================================================
// MAKE COMPLETE CELL
//==================================================================
void MakeCell(string name,
              string text,
              int col,
              int row,
              color txtColor,
              double widthMultiplier = 1.0)
{
   int x =
      g_baseX + col * CellWidth;

   int y =
      g_baseY + row * CellHeight;

   int w =
      (int)(CellWidth * widthMultiplier);

   if(CellBoxVisible())
   {
   MakeCellBox(name + "_BOX",
               x,
               y,
               w,
               CellHeight);
   }

   MakeLabel(name + "_TEXT",
             text,
             x,
             y,
             txtColor);
}

//==================================================================
// ADX COLOR
//==================================================================
color ADXColor(double adx)
{
   if(adx < WeakADXLevel)
      return WeakColor;

   if(adx >= StrongADXLevel)
      return StrongColor;

   return MediumColor;
}

// Only print a given "context" failure once while it persists.
string g_loggedBufferFailKeys[];

//==================================================================
// HANDLE WARM-UP GRACE
//==================================================================
// Indicator handles (iMA/iRSI/iADX) recreated on init/reinit are
// calculated asynchronously by the terminal. Right after a chart
// timeframe switch, the very first CopyBuffer() call can land before
// that background calculation finishes -- CopyBuffer then returns
// error 4806 ("indicator data not found"). That is a NORMAL transient
// state, not a failure: the 1-second timer retries and the cell fills
// in on the next tick. So during a short grace window after init the
// dashboard retries silently. Only if data is STILL unavailable after
// the grace window (genuinely missing broker history, broken symbol,
// etc.) is it reported as a real error.
uint g_initTick = 0;

#define WARMUP_GRACE_MS 5000

bool StillWarmingUp()
{
   // uint subtraction is wrap-safe (GetTickCount wraps every ~49 days).
   return (GetTickCount() - g_initTick) < WARMUP_GRACE_MS;
}

bool AlreadyLoggedBufferFail(string key)
{
   for(int i = 0; i < ArraySize(g_loggedBufferFailKeys); i++)
      if(g_loggedBufferFailKeys[i] == key)
         return true;

   int n = ArraySize(g_loggedBufferFailKeys);
   ArrayResize(g_loggedBufferFailKeys, n + 1);
   g_loggedBufferFailKeys[n] = key;
   return false;
}

void ClearLoggedBufferFail(string key)
{
   for(int i = 0; i < ArraySize(g_loggedBufferFailKeys); i++)
   {
      if(g_loggedBufferFailKeys[i] == key)
      {
         int last = ArraySize(g_loggedBufferFailKeys) - 1;
         g_loggedBufferFailKeys[i] = g_loggedBufferFailKeys[last];
         ArrayResize(g_loggedBufferFailKeys, last);
         return;
      }
   }
}

//==================================================================
// READ BUFFER VALUE
//==================================================================
bool ReadBufferValue(int handle,
                     int bufferIndex,
                     double &value,
                     string context = "")
{
   if(handle == INVALID_HANDLE)
      return false;

   // Ask the terminal FIRST whether this handle has finished calculating,
   // instead of blindly calling CopyBuffer into a not-ready handle.
   if(BarsCalculated(handle) <= 0)
   {
      if(!StillWarmingUp() && context != "")
      {
         string key = context + "_" + IntegerToString(bufferIndex) + "_CALC";
         if(!AlreadyLoggedBufferFail(key))
            Print("Momentum: indicator data for ", context,
                  " isn't ready yet after warm-up (error code ", GetLastError(), "). Will keep retrying..");
      }
      return false; // warm-up: retry silently on the next timer tick
   }

   // BarsCalculated is healthy (again): clear its log-once key so a future
   // re-stuck handle gets reported anew, and the key list stays bounded --
   // at most one live entry per failing stream, removed on recovery.
   if(context != "")
      ClearLoggedBufferFail(context + "_" + IntegerToString(bufferIndex) + "_CALC");

   double data[];
   ArraySetAsSeries(data,true);

   ResetLastError();
   if(CopyBuffer(handle,bufferIndex,0,1,data) <= 0)
   {
      int err = GetLastError();

      // 4806 = data not ready yet. Inside the grace window this is the
      // normal asynchronous warm-up right after init/reinit -- stay
      // silent, the next 1-second timer tick will succeed.
      if(err == 4806 && StillWarmingUp())
         return false;

      string key = context + "_" + IntegerToString(bufferIndex);
      if(context != "" && !AlreadyLoggedBufferFail(key))
      {
         Print("Momentum ERROR: CopyBuffer() failed for ", context,
               " (buffer index ", bufferIndex, "), error code ", err, ".");
      }
      return false;
   }

   if(context != "")
      ClearLoggedBufferFail(context + "_" + IntegerToString(bufferIndex));

   value = data[0];

   if(value == EMPTY_VALUE)
      return false;

   return true;
}

//==================================================================
// GET CLOSE PRICE (with history sync kick)
//==================================================================
// iClose() only reports what's already synced -- it never triggers a
// sync request itself. For a locked TF the chart isn't on (e.g. H4 row
// while charting M1), nothing else may ever trigger that sync, so
// iClose() could return 0 indefinitely and the row's EMA arrow would
// stay "-" forever. CopyRates() DOES request the sync, so when iClose
// comes back 0 we fire one off (fire-and-forget) to get things moving
// -- same pattern as the candle-timer panels.
double GetClosePrice(ENUM_TIMEFRAMES tf)
{
   double c = iClose(_Symbol, tf, 0);
   if(c <= 0.0)
   {
      MqlRates r[];
      ArraySetAsSeries(r, true);
      CopyRates(_Symbol, tf, 0, 1, r); // kicks off history sync
      if(ArraySize(r) > 0)
         c = r[0].close;
   }
   return c;
}

//==================================================================
// UPDATE TIMEFRAME ENABLED ARRAY
//==================================================================
void UpdateTFEnabled()
{
   TFEnabled[0] = ShowM1;
   TFEnabled[1] = ShowM5;
   TFEnabled[2] = ShowM15;
   TFEnabled[3] = ShowM30;
   TFEnabled[4] = ShowH1;
   TFEnabled[5] = ShowH4;
   TFEnabled[6] = ShowD1;
}

//==================================================================
// CHECK IF DASHBOARD OBJECTS ARE MISSING
//==================================================================
bool CheckDashboardObjectsMissing()
{
   // Check if any enabled TF label exists as a canary
   for(int i = 0; i < 7; i++)
   {
      if(TFEnabled[i])
      {
         if(ObjectFind(0, Prefix + "TF_" + IntegerToString(i)) >= 0)
            return false; // Found at least one, dashboard is intact
      }
   }
   
   // If we have enabled timeframes but no labels exist, objects are missing
   for(int i = 0; i < 7; i++)
   {
      if(TFEnabled[i])
         return true; // Should have objects but none found
   }
   
   return false; // No timeframes enabled, nothing to check
}

//==================================================================
// DRAW DASHBOARD
//==================================================================
void DrawDashboard()
{
   UpdateTFEnabled();

   bool anyChanged = false;

   // Check every 5 seconds if dashboard objects have been accidentally
   // deleted (by another script, manual deletion, etc.) and force a full
   // redraw if needed. This is a lightweight canary check - it just looks
   // for one known object name instead of scanning everything.
   static int g_checkCounter = 0;
   
   g_checkCounter++;
   if(g_checkCounter >= 5) // Check every 5 timer ticks to save CPU
   {
      g_checkCounter = 0;
      
      if(CheckDashboardObjectsMissing())
      {
         // Force complete redraw - header and all rows
         g_headerNeedsRedraw = true;
         for(int i = 0; i < 7; i++)
            g_cellInitialized[i] = false;
      }
   }

   // Header only needs to be built once per init/reinit -- its text and
   // position never change on their own between timer ticks.
   if(g_headerNeedsRedraw)
   {
   MakeCell(Prefix+"HEAD_TF",     "TIME",     0,0,TextColor);
   if(CellBoxVisible())
   {
   MakeCellBox(Prefix+"HEAD_EMA_BOX",
               g_baseX + 1 * CellWidth,
               g_baseY,
               CellWidth,
               CellHeight);
   }

   MakeCenterLabel(Prefix+"HEAD_EMA",
                   "EMA",
                   g_baseX + 1 * CellWidth,
                   g_baseY,
                   TextColor);
   MakeCell(Prefix+"HEAD_ADX",    "ADX",    2,0,TextColor);
   if(CellBoxVisible())
   {
   MakeCellBox(Prefix+"HEAD_DI_BOX",
               g_baseX + 3 * CellWidth,
               g_baseY,
               CellWidth,
               CellHeight);
   }
 
   MakeCenterLabel(Prefix+"HEAD_DI",
                   "DI",
                   g_baseX + 3 * CellWidth,
                   g_baseY,
                   TextColor);
   MakeCell(Prefix+"HEAD_RSI",    "RSI",    4,0,TextColor);
   MakeCell(Prefix+"HEAD_SIGNAL", "SIGNAL", 5,0,TextColor,1.9);

   g_headerNeedsRedraw = false;
   anyChanged = true;
   }

   int row = 1;

   for(int i = 0; i < 7; i++)
   {
      if(!TFEnabled[i])
         continue;

      ENUM_TIMEFRAMES tf =
         TFList[i];

      double ema = 0.0;
      double rsi = 0.0;
      double adx = 0.0;
      double plusDI = 0.0;
      double minusDI = 0.0;

      bool emaOK =
         ReadBufferValue(EMAHandle[i],0,ema,TFName(tf)+"_EMA");

      bool rsiOK =
         ReadBufferValue(RSIHandle[i],0,rsi,TFName(tf)+"_RSI");

      bool adxOK =
         ReadBufferValue(ADXHandle[i],0,adx,TFName(tf)+"_ADX");

      bool plusOK =
         ReadBufferValue(ADXHandle[i],1,plusDI,TFName(tf)+"_ADX");

      bool minusOK =
         ReadBufferValue(ADXHandle[i],2,minusDI,TFName(tf)+"_ADX");

      double closePrice =
         GetClosePrice(tf);

      string emaText = "-";
      string adxText = "N/A";
      string diText  = "-";
      string rsiText = "N/A";
      string sigText = "WAIT";

      color emaColor = MediumColor;
      color adxColorValue = MediumColor;
      color diColor = MediumColor;
      color rsiColor = MediumColor;
      color sigColor = MediumColor;

      bool emaBuy = false;
      bool emaSell = false;

      bool diBuy = false;
      bool diSell = false;

      bool rsiBuy = false;
      bool rsiSell = false;

      bool adxStrong = false;

      if(emaOK && closePrice > 0.0)
      {
         if(closePrice > ema)
         {
            emaText  = "▲";
            emaColor = StrongColor;
            emaBuy   = true;
         }
         else if(closePrice < ema)
         {
            emaText  = "▼";
            emaColor = WeakColor;
            emaSell  = true;
         }
      }

      if(adxOK)
      {
         adxText =
            DoubleToString(adx,1);

         adxColorValue =
            ADXColor(adx);

         adxStrong =
            (adx >= StrongADXLevel);
      }

if(plusOK && minusOK)
{
   double diDiff =
      MathAbs(plusDI - minusDI);

   if(diDiff < MinDIDifference)
   {
      diText  = "-";
      diColor = MediumColor;
   }
   else if(plusDI > minusDI)
   {
      diText  = "▲";
      diColor = StrongColor;
      diBuy   = true;
   }
   else
   {
      diText  = "▼";
      diColor = WeakColor;
      diSell  = true;
   }
}

      if(rsiOK)
      {
         rsiText =
            DoubleToString(rsi,1);

         if(rsi >= BuyRSILevel)
         {
            rsiColor = StrongColor;
            rsiBuy   = true;
         }
         else if(rsi <= SellRSILevel)
         {
            rsiColor = WeakColor;
            rsiSell  = true;
         }
      }

      bool buyOK =
         emaBuy &&
         adxStrong &&
         diBuy &&
         rsiBuy;

      bool sellOK =
         emaSell &&
         adxStrong &&
         diSell &&
         rsiSell;

      if(buyOK)
      {
         sigText  = "▲ BULLISH";
         sigColor = StrongColor;
      }
      else if(sellOK)
      {
         sigText  = "▼ BEARISH";
         sigColor = WeakColor;
      }
      else
      {
         sigText  = "- SIDEWAYS";
         sigColor = MediumColor;
      }

      // Only touch this row's chart objects (and mark the chart for
      // redraw) when something about it actually changed since the last
      // timer tick. Higher timeframes like H1/H4/D1 often go many seconds
      // without their EMA/RSI/ADX/signal changing at all, so this avoids
      // rewriting identical text/colors and forcing a repaint every second
      // for no visible difference.
      bool rowChanged =
         !g_cellInitialized[i]                 ||
         g_lastEmaText[i]  != emaText          ||
         g_lastEmaColor[i] != emaColor         ||
         g_lastAdxText[i]  != adxText          ||
         g_lastAdxColor[i] != adxColorValue    ||
         g_lastDiText[i]   != diText           ||
         g_lastDiColor[i]  != diColor          ||
         g_lastRsiText[i]  != rsiText          ||
         g_lastRsiColor[i] != rsiColor         ||
         g_lastSigText[i]  != sigText          ||
         g_lastSigColor[i] != sigColor;

      if(rowChanged)
      {
      MakeCell(Prefix+"TF_"+IntegerToString(i),     TFName(tf), 0,row,TextColor);
      if(CellBoxVisible())
      {
      MakeCellBox(Prefix+"EMA_"+IntegerToString(i)+"_BOX",
                  g_baseX + 1 * CellWidth,
                  g_baseY + row * CellHeight,
                  CellWidth,
                  CellHeight);
      }

      MakeCenterLabel(Prefix+"EMA_"+IntegerToString(i),
                      emaText,
                      g_baseX + 1 * CellWidth,
                      g_baseY + row * CellHeight,
                      emaColor);
      MakeCell(Prefix+"ADX_"+IntegerToString(i),    adxText,    2,row,adxColorValue);
      if(CellBoxVisible())
      {
      MakeCellBox(Prefix+"DI_"+IntegerToString(i)+"_BOX",
                  g_baseX + 3 * CellWidth,
                  g_baseY + row * CellHeight,
                  CellWidth,
                  CellHeight);
      }

      MakeCenterLabel(Prefix+"DI_"+IntegerToString(i),
                      diText,
                      g_baseX + 3 * CellWidth,
                      g_baseY + row * CellHeight,
                      diColor);
      MakeCell(Prefix+"RSI_"+IntegerToString(i),    rsiText,    4,row,rsiColor);
      MakeCell(Prefix+"SIG_"+IntegerToString(i),    sigText,    5,row,sigColor,1.9);

      g_lastEmaText[i]  = emaText;
      g_lastEmaColor[i] = emaColor;
      g_lastAdxText[i]  = adxText;
      g_lastAdxColor[i] = adxColorValue;
      g_lastDiText[i]   = diText;
      g_lastDiColor[i]  = diColor;
      g_lastRsiText[i]  = rsiText;
      g_lastRsiColor[i] = rsiColor;
      g_lastSigText[i]  = sigText;
      g_lastSigColor[i] = sigColor;
      g_cellInitialized[i] = true;

      anyChanged = true;
      }

      row++;
   }

   // Only force a chart repaint when something was actually drawn/updated
   // this call. On ticks where every enabled row is unchanged (common for
   // slower timeframes), this is skipped entirely.
   if(anyChanged)
      ChartRedraw(0);
}

//==================================================================
// CREATE INDICATOR HANDLES
//==================================================================
bool CreateIndicatorHandles()
{
   UpdateTFEnabled();

   ResetLastError();

   for(int i = 0; i < 7; i++)
   {
      EMAHandle[i] = INVALID_HANDLE;
      RSIHandle[i] = INVALID_HANDLE;
      ADXHandle[i] = INVALID_HANDLE;

      // Skip disabled timeframes entirely. DrawDashboard() already does
      // "if(!TFEnabled[i]) continue;" before it ever reads these handles,
      // so there's no reason to make MT5 keep computing EMA/RSI/ADX in the
      // background for a row that's never drawn (e.g. M1/H4/D1, which are
      // off by default).
      if(!TFEnabled[i])
         continue;

      EMAHandle[i] =
         iMA(_Symbol,
             TFList[i],
             EMAPeriod,
             0,
             MODE_EMA,
             PRICE_CLOSE);

      RSIHandle[i] =
         iRSI(_Symbol,
              TFList[i],
              RSIPeriod,
              PRICE_CLOSE);

      ADXHandle[i] =
         iADX(_Symbol,
              TFList[i],
              ADXPeriod);

      if(EMAHandle[i] == INVALID_HANDLE ||
         RSIHandle[i] == INVALID_HANDLE ||
         ADXHandle[i] == INVALID_HANDLE)
      {
         Print("Momentum ERROR: failed to create handle for ",
               TFName(TFList[i]), ", error code ", GetLastError(), ".");

         return false;
      }
   }

   return true;
}

//==================================================================
// RELEASE INDICATOR HANDLES
//==================================================================
void ReleaseIndicatorHandles()
{
   for(int i = 0; i < 7; i++)
   {
      if(EMAHandle[i] != INVALID_HANDLE)
      {
         IndicatorRelease(EMAHandle[i]);
         EMAHandle[i] = INVALID_HANDLE;
      }

      if(RSIHandle[i] != INVALID_HANDLE)
      {
         IndicatorRelease(RSIHandle[i]);
         RSIHandle[i] = INVALID_HANDLE;
      }

      if(ADXHandle[i] != INVALID_HANDLE)
      {
         IndicatorRelease(ADXHandle[i]);
         ADXHandle[i] = INVALID_HANDLE;
      }
   }
}

//==================================================================
// INIT
//==================================================================
int OnInit()
{
   // Identity by configuration (see Prefix above).
   Prefix = StringFormat("GM_DASH_%d_%d_%d_", (int)InpCorner, X_Distance, Y_Distance);

   if(!CreateIndicatorHandles())
      return INIT_FAILED;

   // Start the warm-up grace clock: fresh handles need a moment before
   // their data is readable (see the comment above StillWarmingUp).
   g_initTick = GetTickCount();

   // Force a full redraw on the very next DrawDashboard() call. This matters
   // both on the first-ever init and on any reinit (input changed, etc.):
   // OnDeinit already wipes every dashboard object via DeleteDashboard(), so
   // the cache must be invalidated too or the change-detection below would
   // wrongly think "nothing changed" and skip recreating objects that no
   // longer exist on the chart.
   g_headerNeedsRedraw = true;

   for(int i = 0; i < 7; i++)
      g_cellInitialized[i] = false;

   // Corner translation: compute the top-left base point before the
   // first draw (TFEnabled[] is already set by CreateIndicatorHandles).
   ComputeBase();

   int refresh =
      RefreshSeconds;

   if(refresh < 1)
      refresh = 1;

   EventSetTimer(refresh);

   DrawDashboard();

   return INIT_SUCCEEDED;
}

//==================================================================
// DEINIT
//==================================================================
void OnDeinit(const int reason)
{
   EventKillTimer();

   DeleteDashboard();

   ReleaseIndicatorHandles();

   ChartRedraw(0);
}

//==================================================================
// TIMER
//==================================================================
void OnTimer()
{
   // Chart resized / subwindow added or removed -> base point moved.
   // Invalidate the draw caches so this same pass repositions every
   // cell at the new base. Cost when nothing moved: two ChartGetInteger.
   if(ComputeBase())
   {
      g_headerNeedsRedraw = true;
      for(int i = 0; i < 7; i++)
         g_cellInitialized[i] = false;
   }

   DrawDashboard();
}

//==================================================================
// CALCULATE
//==================================================================
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
   return rates_total;
}
//+------------------------------------------------------------------+