//+------------------------------------------------------------------+
//|                                                 SetMyHeights.mq5 |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property script_show_inputs 

input int MyCustomHeight = 70; // Type your favorite pixel height here

void OnStart()
{
   int totalWindows = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   
   for(int i = 1; i < totalWindows; i++)
   {
      ChartSetInteger(0, CHART_HEIGHT_IN_PIXELS, i, MyCustomHeight);
   }
   
   ChartRedraw(0);
}
