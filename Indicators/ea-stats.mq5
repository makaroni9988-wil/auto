#property copyright "Copyright 2026"
#property version   "1.03"
#property indicator_chart_window
#property indicator_plots 0

// Runs alongside the trading EAs (indicators stack unlimited on one chart,
// only the EA itself is limited to one per chart). Auto-detects every magic
// number seen in this symbol's history + open positions and writes two
// files to this terminal's MQL5/Files:
//
//  1) InpStatsFile (ea-stats.csv) - one row per magic PER PERIOD (Daily/
//     Weekly/Monthly/AllTime), each with its own win rate, profit factor
//     and recovery factor (drawdown replayed fresh from that period's own
//     start, not carried over from before it). Always current, no input
//     needed - this is what to read for a normal check.
//  2) InpDealsFile (ea-deals.csv) - the raw ledger: one row per individual
//     closed deal (magic, close time, direction, volume, net P/L), full
//     history, unfiltered. Not meant to be read directly - it exists so
//     an outside reader (or a chat request for an arbitrary range like
//     "July 1 to 10") can compute ANY custom window on demand without
//     ever touching this file's inputs or recompiling.
//
// Daily uses the SYMBOL's broker/server daily candle open (iTime D1),
// same as any "today" reading in MT5 itself - not your local calendar
// day, since that depends on the broker's server timezone. Weekly/Monthly
// are simple rolling windows (last 7 / 30 days from now), not calendar
// week/month, so there's no "which day does the week start on" ambiguity.

input string InpMagicNumbers = "778899,111,222,555"; // Comma list of magics to track (empty = auto-detect all)
input string InpStatsFile    = "ea-stats.csv"; // Period summary output (MQL5/Files)
input string InpDealsFile    = "ea-deals.csv"; // Raw per-deal ledger output (MQL5/Files)
input int    InpRefreshMs    = 3000;    // Timer refresh interval (ms)

ulong  g_magics[];
int    g_magicCount;
string g_lastFingerprint;
string g_lastLedgerFingerprint;

int OnInit()
{
   g_lastFingerprint = "";
   g_lastLedgerFingerprint = "";
   EventSetMillisecondTimer(InpRefreshMs);
   BuildStats();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
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
   return(rates_total);
}

void OnTimer()
{
   BuildStats();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // A closed deal changes win rate/profit factor immediately - don't wait
   // for the next timer tick.
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      BuildStats();
}

// --- magic number list: manual override or auto-detect from history + open trades ---

void ParseMagicList()
{
   ArrayResize(g_magics,0);
   g_magicCount = 0;

   if(InpMagicNumbers == "")
      return;

   string parts[];
   int n = StringSplit(InpMagicNumbers,',',parts);
   for(int i = 0; i < n; i++)
   {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      if(p == "")
         continue;
      AddMagic((ulong)StringToInteger(p));
   }
}

bool HasMagic(ulong magic)
{
   for(int i = 0; i < g_magicCount; i++)
      if(g_magics[i] == magic)
         return true;
   return false;
}

void AddMagic(ulong magic)
{
   if(HasMagic(magic))
      return;
   ArrayResize(g_magics,g_magicCount + 1);
   g_magics[g_magicCount] = magic;
   g_magicCount++;
}

void DiscoverMagics()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      AddMagic((ulong)PositionGetInteger(POSITION_MAGIC));
   }

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(ticket,DEAL_ENTRY) != DEAL_ENTRY_OUT &&
         HistoryDealGetInteger(ticket,DEAL_ENTRY) != DEAL_ENTRY_OUT_BY)
         continue;
      AddMagic((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC));
   }
}

int FindMagicIndex(ulong magic)
{
   for(int i = 0; i < g_magicCount; i++)
      if(g_magics[i] == magic)
         return i;
   return -1;
}

// --- per-magic, per-period stat accumulation ---

enum ENUM_STAT_PERIOD
{
   PERIOD_DAILY = 0,
   PERIOD_WEEKLY,
   PERIOD_MONTHLY,
   PERIOD_ALLTIME,
   PERIOD_COUNT
};

string PeriodName(int p)
{
   switch(p)
   {
      case PERIOD_DAILY:   return "Daily";
      case PERIOD_WEEKLY:  return "Weekly";
      case PERIOD_MONTHLY: return "Monthly";
      case PERIOD_ALLTIME: return "AllTime";
   }
   return "?";
}

// Each period keeps its OWN equity-curve replay (peak/drawdown reset at
// that period's own start) so, e.g., Weekly's recovery factor reflects
// this week's drawdown only, not one inherited from before the window.
struct PeriodBucket
{
   double netProfit;
   int    closedTrades;
   int    wins;
   double grossProfit;
   double grossLoss;
   double peakBalance;
   double runningBalance;
   double maxDrawdown;
};

struct MagicStats
{
   ulong        magic;
   PeriodBucket periods[PERIOD_COUNT];
   double       openFloatingPL;
   int          openPositions;
};

void ResetBucket(PeriodBucket &b)
{
   b.netProfit      = 0;
   b.closedTrades   = 0;
   b.wins           = 0;
   b.grossProfit    = 0;
   b.grossLoss      = 0;
   b.peakBalance    = 0;
   b.runningBalance = 0;
   b.maxDrawdown    = 0;
}

void ResetStats(MagicStats &s, ulong magic)
{
   s.magic = magic;
   for(int p = 0; p < PERIOD_COUNT; p++)
      ResetBucket(s.periods[p]);
   s.openFloatingPL = 0;
   s.openPositions  = 0;
}

void ApplyDealToBucket(PeriodBucket &b, double dealNet)
{
   b.netProfit += dealNet;
   b.closedTrades++;

   if(dealNet > 0)
   {
      b.wins++;
      b.grossProfit += dealNet;
   }
   else if(dealNet < 0)
   {
      b.grossLoss += -dealNet;
   }

   // Equity-curve replay in chronological order (HistoryDealGetTicket
   // returns deals oldest-first) to get THIS PERIOD's own max drawdown,
   // independent of anything before it or of other magics on the account.
   b.runningBalance += dealNet;
   if(b.runningBalance > b.peakBalance)
      b.peakBalance = b.runningBalance;
   double dd = b.peakBalance - b.runningBalance;
   if(dd > b.maxDrawdown)
      b.maxDrawdown = dd;
}

// A deal older than a period's start simply never touches that period's
// bucket - AllTime always gets it, Daily/Weekly/Monthly only if the deal
// falls inside their own window. Buckets are otherwise fully independent.
void ApplyDealToStats(MagicStats &s, double dealNet, datetime dealTime,
                      datetime dayStart, datetime weekStart, datetime monthStart)
{
   if(dealTime >= dayStart)   ApplyDealToBucket(s.periods[PERIOD_DAILY],   dealNet);
   if(dealTime >= weekStart)  ApplyDealToBucket(s.periods[PERIOD_WEEKLY],  dealNet);
   if(dealTime >= monthStart) ApplyDealToBucket(s.periods[PERIOD_MONTHLY], dealNet);
   ApplyDealToBucket(s.periods[PERIOD_ALLTIME], dealNet);
}

void BuildStats()
{
   HistorySelect(0,TimeCurrent());

   ParseMagicList();
   if(g_magicCount == 0)
      DiscoverMagics();

   if(g_magicCount == 0)
      return;

   MagicStats stats[];
   ArrayResize(stats,g_magicCount);
   for(int i = 0; i < g_magicCount; i++)
      ResetStats(stats[i],g_magics[i]);

   datetime now        = TimeCurrent();
   datetime dayStart    = iTime(_Symbol,PERIOD_D1,0);   // broker/server day, same as MT5's own "today"
   datetime weekStart   = now - 7 * 86400;               // rolling 7 days
   datetime monthStart  = now - 30 * 86400;              // rolling 30 days

   // Ledger rows (File 2) collected in the same pass as the stat buckets
   // (File 1) so history only gets scanned once.
   ulong    ledgerMagic[]; datetime ledgerTime[]; string ledgerType[];
   double   ledgerVolume[]; double ledgerNet[];
   int      ledgerCount = 0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL) != _Symbol)
         continue;

      long entry = HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      ulong magic = (ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC);
      int idx = FindMagicIndex(magic);
      if(idx < 0)
         continue;

      double net = HistoryDealGetDouble(ticket,DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket,DEAL_SWAP)
                 + HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      datetime dealTime = (datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
      long dealType = HistoryDealGetInteger(ticket,DEAL_TYPE);

      ApplyDealToStats(stats[idx],net,dealTime,dayStart,weekStart,monthStart);

      ArrayResize(ledgerMagic,ledgerCount + 1);
      ArrayResize(ledgerTime,ledgerCount + 1);
      ArrayResize(ledgerType,ledgerCount + 1);
      ArrayResize(ledgerVolume,ledgerCount + 1);
      ArrayResize(ledgerNet,ledgerCount + 1);
      ledgerMagic[ledgerCount]  = magic;
      ledgerTime[ledgerCount]   = dealTime;
      ledgerType[ledgerCount]   = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
      ledgerVolume[ledgerCount] = HistoryDealGetDouble(ticket,DEAL_VOLUME);
      ledgerNet[ledgerCount]    = net;
      ledgerCount++;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      int idx = FindMagicIndex(magic);
      if(idx < 0)
         continue;

      stats[idx].openFloatingPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      stats[idx].openPositions++;
   }

   WriteStats(stats);
   WriteLedger(ledgerMagic,ledgerTime,ledgerType,ledgerVolume,ledgerNet,ledgerCount);
}

void WriteStats(MagicStats &stats[])
{
   // Fingerprint the output so we don't rewrite the file when nothing changed.
   string fp = "";
   for(int i = 0; i < ArraySize(stats); i++)
      for(int p = 0; p < PERIOD_COUNT; p++)
         fp += StringFormat("%I64u:%d:%.2f:%d:%d:%.2f:%.2f;",
                            stats[i].magic,p,stats[i].periods[p].netProfit,
                            stats[i].periods[p].closedTrades,stats[i].periods[p].wins,
                            stats[i].periods[p].grossProfit,stats[i].periods[p].grossLoss);
   for(int i = 0; i < ArraySize(stats); i++)
      fp += StringFormat("open%I64u:%.2f:%d;",stats[i].magic,stats[i].openFloatingPL,stats[i].openPositions);

   if(fp == g_lastFingerprint)
      return;
   g_lastFingerprint = fp;

   int handle = FileOpen(InpStatsFile,FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(handle == INVALID_HANDLE)
      return;

   FileWrite(handle,"Magic","Symbol","Period","NetProfit","ClosedTrades",
             "WinRatePct","ProfitFactor","RecoveryFactor","OpenFloatingPL","OpenPositions","UpdatedAt");

   string updatedAt = TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS);

   for(int i = 0; i < ArraySize(stats); i++)
   {
      for(int p = 0; p < PERIOD_COUNT; p++)
      {
         PeriodBucket b = stats[i].periods[p];
         double winRate       = (b.closedTrades > 0) ? 100.0 * b.wins / b.closedTrades : 0;
         double profitFactor  = (b.grossLoss > 0) ? b.grossProfit / b.grossLoss : 0;
         double recoveryFactor= (b.maxDrawdown > 0) ? b.netProfit / b.maxDrawdown : 0;

         FileWrite(handle,
                   (long)stats[i].magic,
                   _Symbol,
                   PeriodName(p),
                   DoubleToString(b.netProfit,2),
                   b.closedTrades,
                   DoubleToString(winRate,1),
                   DoubleToString(profitFactor,2),
                   DoubleToString(recoveryFactor,2),
                   DoubleToString(stats[i].openFloatingPL,2),
                   stats[i].openPositions,
                   updatedAt);
      }
   }

   FileClose(handle);
}

// Raw ledger: one row per closed deal, full history, no aggregation. Not
// for eyeballing - it's the source data for any custom date-range question
// that Daily/Weekly/Monthly in ea-stats.csv doesn't cover, computed by
// whoever/whatever reads this file, on demand, without touching this EA.
void WriteLedger(ulong &magic[], datetime &dealTime[], string &type[],
                 double &volume[], double &net[], int count)
{
   // Cheap fingerprint (count + last row) - the ledger only ever grows by
   // appending new closed deals, so count changing (or the newest deal's
   // own fields changing, e.g. a late swap adjustment) is enough to detect
   // "something's different" without hashing every row every 3 seconds.
   string fp = IntegerToString(count);
   if(count > 0)
      fp += StringFormat("|%I64u:%s:%s:%.2f:%.2f",magic[count-1],
                         TimeToString(dealTime[count-1]),type[count-1],
                         volume[count-1],net[count-1]);
   if(fp == g_lastLedgerFingerprint)
      return;
   g_lastLedgerFingerprint = fp;

   int handle = FileOpen(InpDealsFile,FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(handle == INVALID_HANDLE)
      return;

   FileWrite(handle,"Magic","Symbol","CloseTime","Type","Volume","NetProfit");

   for(int i = 0; i < count; i++)
      FileWrite(handle,
                (long)magic[i],
                _Symbol,
                TimeToString(dealTime[i],TIME_DATE|TIME_SECONDS),
                type[i],
                DoubleToString(volume[i],2),
                DoubleToString(net[i],2));

   FileClose(handle);
}
