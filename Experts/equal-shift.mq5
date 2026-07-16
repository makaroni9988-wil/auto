//+------------------------------------------------------------------+
//|                                                  SetMyShift.mq5  |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property script_show_inputs 

input int MyShiftPercent = 10; // Shift percent (10-50)

void OnStart()
{
   int percent = MyShiftPercent;
   if(percent < 10) percent = 10;
   if(percent > 50) percent = 50;
   
   ChartSetInteger(0, CHART_SHIFT, true);
   ChartSetDouble(0, CHART_SHIFT_SIZE, (double)percent);
   ChartRedraw(0);
}