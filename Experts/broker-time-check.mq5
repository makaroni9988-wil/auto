//+------------------------------------------------------------------+
void OnStart()
{
   datetime server = TimeCurrent();
   datetime gmt    = TimeGMT();
   datetime local  = TimeLocal();

   Print("Server (broker): ", TimeToString(server, TIME_DATE|TIME_MINUTES|TIME_SECONDS));
   Print("GMT/UTC:           ", TimeToString(gmt,    TIME_DATE|TIME_MINUTES|TIME_SECONDS));
   Print("Your PC (local):   ", TimeToString(local,  TIME_DATE|TIME_MINUTES|TIME_SECONDS));

   int serverVsGmt   = (int)((server - gmt) / 3600);
   int serverVsLocal = (int)((server - local) / 3600);

   Print("Broker offset from UTC: ", serverVsGmt, " hours");
   Print("Broker offset from PC:  ", serverVsLocal, " hours");
}
//+------------------------------------------------------------------+