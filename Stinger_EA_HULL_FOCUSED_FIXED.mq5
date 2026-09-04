#include <Trade/Trade.mqh>
CTrade Trade;

//--- Input Parameters
input double LotSize = 0.01;                      // Lot size for trades
input double TakeProfit = 2500;                   // Take profit in points
input double StopLoss = 1000;                     // Stop loss in points
input double TrailingStop = 1000;                 // Trailing stop in points
input int SMA_Period = 10;                        // SMA period (reference only)
input int RSI_Threshold = 25;                     // RSI(5) threshold for entry
input double BullishPinRatio = 3.0;               // Bullish pin body-to-wick ratio (default 3:1)
input bool UseMACD_Confirmation = true;           // Use MACD(4,13,4) as confirmation
input bool HullCrossoverWaitConfirm = true;       // Wait for candle close to confirm Hull crossover

//--- Trading Time Filter (Server Time)
input bool UseTimeFilter = false;                 // Enable trading time filter (DISABLED for testing)
input int StartHour = 9;                          // Start trading hour (server time, 0-23)
input int StartMinute = 0;                        // Start trading minute
input int EndHour = 17;                           // End trading hour (server time, 0-23)
input int EndMinute = 0;                          // End trading minute

//--- Global Variables
datetime lastTradeCandle = 0;                     // Track last candle that executed a trade
bool hullCrossoverDetected = false;               // Flag for Hull crossover detected on current candle
datetime hullCrossoverTime = 0;                   // Time when Hull crossover was detected
datetime lastProcessedCandle = 0;                 // Track last candle processed
bool indicatorDataReady = false;                  // Track if indicator data is initialized

// Indicator Handles
int handle_rsicombo = INVALID_HANDLE;
int handle_hull5 = INVALID_HANDLE;
int handle_hull10 = INVALID_HANDLE;
int handle_macd = INVALID_HANDLE;
int handle_sma10 = INVALID_HANDLE;

// Buffers
double rsi5_buffer[], rsi14_buffer[];
double hull5_buffer[], hull5_color_buffer[];
double hull10_buffer[], hull10_color_buffer[];
double macd_buffer[], macd_signal_buffer[], macd_histogram[];
double sma10_buffer[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("========== Stinger EA (Hull-Focused) FIXED Initialized ==========");
   Print("LotSize: ", LotSize, ", TP: ", TakeProfit, ", SL: ", StopLoss);
   Print("RSI Threshold: ", RSI_Threshold, ", Pin Ratio: ", BullishPinRatio, ":1");
   Print("MACD Confirmation: ", (UseMACD_Confirmation ? "ENABLED" : "DISABLED"));
   Print("Hull Crossover Wait Confirm: ", (HullCrossoverWaitConfirm ? "ENABLED" : "DISABLED"));
   
   if (UseTimeFilter)
   {
      Print("TIME FILTER ENABLED - Trading between ", 
            StringFormat("%02d:%02d", StartHour, StartMinute), " and ",
            StringFormat("%02d:%02d", EndHour, EndMinute), " (Server Time, Monday-Friday only)");
   }
   else
   {
      Print("TIME FILTER DISABLED - Trading available when market is open (Monday-Friday)");
   }
   Print("===================================================================");
   
   // Create RSICombo handle
   handle_rsicombo = iCustom(_Symbol, PERIOD_CURRENT, "RSICombo");
   if (handle_rsicombo == INVALID_HANDLE)
   {
      Print("ERROR: Failed to load RSICombo indicator. Error: ", GetLastError());
      return INIT_FAILED;
   }
   
   // Create Hull(5) handle - try multiple possible filenames/paths to avoid tester load errors
   handle_hull5 = iCustom(_Symbol, PERIOD_CURRENT, "Hull_5");
   if (handle_hull5 == INVALID_HANDLE) handle_hull5 = iCustom(_Symbol, PERIOD_CURRENT, "Hull5");
   if (handle_hull5 == INVALID_HANDLE) handle_hull5 = iCustom(_Symbol, PERIOD_CURRENT, "Hull 5");
   if (handle_hull5 == INVALID_HANDLE) handle_hull5 = iCustom(_Symbol, PERIOD_CURRENT, "Indicators\\Hull_5");
   if (handle_hull5 == INVALID_HANDLE) handle_hull5 = iCustom(_Symbol, PERIOD_CURRENT, "Indicators\\Hull5");
   if (handle_hull5 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to load Hull(5) indicator with any known name. Last GetLastError(): ", GetLastError());
      return INIT_FAILED;
   }
   else
   {
      Print("INFO: Hull(5) indicator loaded (handle=", handle_hull5, ")");
   }
   
   // Create Hull(10) handle - try multiple possible filenames/paths
   handle_hull10 = iCustom(_Symbol, PERIOD_CURRENT, "Hull_10");
   if (handle_hull10 == INVALID_HANDLE) handle_hull10 = iCustom(_Symbol, PERIOD_CURRENT, "Hull10");
   if (handle_hull10 == INVALID_HANDLE) handle_hull10 = iCustom(_Symbol, PERIOD_CURRENT, "Hull 10");
   if (handle_hull10 == INVALID_HANDLE) handle_hull10 = iCustom(_Symbol, PERIOD_CURRENT, "Indicators\\Hull_10");
   if (handle_hull10 == INVALID_HANDLE) handle_hull10 = iCustom(_Symbol, PERIOD_CURRENT, "Indicators\\Hull10");
   if (handle_hull10 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to load Hull(10) indicator with any known name. Last GetLastError(): ", GetLastError());
      return INIT_FAILED;
   }
   else
   {
      Print("INFO: Hull(10) indicator loaded (handle=", handle_hull10, ")");
   }
   
   // Create MACD handle
   if (UseMACD_Confirmation)
   {
      handle_macd = iMACD(_Symbol, PERIOD_CURRENT, 4, 13, 4, PRICE_CLOSE);
      if (handle_macd == INVALID_HANDLE)
      {
         Print("ERROR: Failed to load MACD(4,13,4) indicator. Error: ", GetLastError());
         return INIT_FAILED;
      }
   }
   
   // Create SMA(10) handle
   handle_sma10 = iMA(_Symbol, PERIOD_CURRENT, SMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   if (handle_sma10 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to load SMA(10) indicator. Error: ", GetLastError());
      return INIT_FAILED;
   }
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if we are on a new candle
   if (!IsNewCandle()) return;
   
   // Check if within trading time window
   if (UseTimeFilter && !IsWithinTradingTime())
   {
      return;
   }
   
   datetime currentCandleTime = iTime(NULL, PERIOD_CURRENT, 0);
   
   // Prevent multiple trades on the same candle
   if (lastTradeCandle == currentCandleTime)
   {
      Print("DEBUG: Trade already executed on this candle. Skipping.");
      return;
   }
   
   // Get indicator values
   if (!GetIndicatorValues())
   {
      Print("ERROR: Failed to get indicator values.");
      return;
   }
   
   // CRITICAL FIX #1: Validate indicator data is ready before using it
   // On first few ticks, buffers may contain zeros or invalid data
   if (!indicatorDataReady)
   {
      if (rsi5_buffer[0] != 0 && hull5_buffer[0] != 0 && hull10_buffer[0] != 0)
      {
         indicatorDataReady = true;
         Print("DEBUG: Indicator data is now ready. Starting trade logic.");
      }
      else
      {
         Print("DEBUG: Waiting for indicator data to be ready...");
         return;
      }
   }
   
   // Check for Hull(5) crossing above Hull(10) on the PREVIOUS candle
   bool hullCrossoverOnPreviousCandle = CheckHullCrossover();
   
   // If Hull crossover detected and confirmation enabled, set flag
   if (hullCrossoverOnPreviousCandle && HullCrossoverWaitConfirm)
   {
      hullCrossoverDetected = true;
      hullCrossoverTime = iTime(NULL, PERIOD_CURRENT, 1);  // Time of the candle where crossover occurred
      Print("DEBUG: Hull(5) crossed above Hull(10) on previous candle - Waiting for confirmation on next candle...");
      return;
   }
   
   // Check if we should execute (Hull crossover confirmed or immediate mode)
   bool shouldExecute = false;
   
   if (HullCrossoverWaitConfirm && hullCrossoverDetected)
   {
      // This is the confirmation candle (we're on a new candle after the crossover was detected)
      shouldExecute = true;
      hullCrossoverDetected = false;  // Reset flag
      Print("DEBUG: Hull crossover confirmed on new candle! Checking entry conditions...");
   }
   else if (!HullCrossoverWaitConfirm && hullCrossoverOnPreviousCandle)
   {
      // Immediate mode - execute on same candle as crossover
      shouldExecute = true;
      Print("DEBUG: Hull crossover detected (immediate mode). Checking entry conditions...");
   }
   
   if (!shouldExecute)
      return;
   
   // Check all entry conditions
   if (CheckEntryConditions())
   {
      if (PositionsTotal() == 0)
      {
         Print("DEBUG: All conditions MET! Attempting to open BUY trade.");
         if (OpenTrade())
         {
            lastTradeCandle = currentCandleTime;
         }
      }
      else
      {
         Print("DEBUG: Existing position detected. No new trades allowed.");
      }
   }
   
   // Apply trailing stop for open positions
   if (PositionsTotal() > 0)
   {
      ApplyTrailingStop();
   }
}

//+------------------------------------------------------------------+
//| Check if current time is within trading time window (Server Time) |
//+------------------------------------------------------------------+
bool IsWithinTradingTime()
{
   datetime serverTime = TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(serverTime, timeStruct);
   
   int currentHour = timeStruct.hour;
   int currentMinute = timeStruct.min;
   int currentDayOfWeek = timeStruct.day_of_week;
   
   // Check if it's a weekday (1=Monday, 5=Friday; 0=Sunday, 6=Saturday)
   if (currentDayOfWeek == 0 || currentDayOfWeek == 6)
   {
      Print("DEBUG: BLOCKED - Market closed on weekends. Day: ", currentDayOfWeek);
      return false;
   }
   
   // Convert current time to minutes since midnight
   int currentTimeInMinutes = currentHour * 60 + currentMinute;
   int startTimeInMinutes = StartHour * 60 + StartMinute;
   int endTimeInMinutes = EndHour * 60 + EndMinute;
   
   // Handle case where end time is on next day (e.g., 22:00 to 06:00)
   if (endTimeInMinutes < startTimeInMinutes)
   {
      // Wraps around midnight
      bool withinTime = (currentTimeInMinutes >= startTimeInMinutes) || (currentTimeInMinutes < endTimeInMinutes);
      
      if (!withinTime)
      {
         Print("DEBUG: BLOCKED - Outside trading time window (", 
               StringFormat("%02d:%02d", StartHour, StartMinute), " to ",
               StringFormat("%02d:%02d", EndHour, EndMinute), "). Current: ",
               StringFormat("%02d:%02d", currentHour, currentMinute));
      }
      
      return withinTime;
   }
   else
   {
      // Normal case: same day
      bool withinTime = (currentTimeInMinutes >= startTimeInMinutes) && (currentTimeInMinutes < endTimeInMinutes);
      
      if (!withinTime)
      {
         Print("DEBUG: BLOCKED - Outside trading time window (", 
               StringFormat("%02d:%02d", StartHour, StartMinute), " to ",
               StringFormat("%02d:%02d", EndHour, EndMinute), "). Current: ",
               StringFormat("%02d:%02d", currentHour, currentMinute));
      }
      
      return withinTime;
   }
}

//+------------------------------------------------------------------+
//| Get Indicator Values                                             |
//+------------------------------------------------------------------+
bool GetIndicatorValues()
{
   // Copy RSICombo buffers
   if (CopyBuffer(handle_rsicombo, 0, 0, 2, rsi5_buffer) <= 0 ||
       CopyBuffer(handle_rsicombo, 1, 0, 2, rsi14_buffer) <= 0)
   {
      Print("ERROR: Failed to copy RSICombo data.");
      return false;
   }
   
   // Copy Hull(5) buffers
   if (CopyBuffer(handle_hull5, 0, 0, 2, hull5_buffer) <= 0 ||
       CopyBuffer(handle_hull5, 1, 0, 2, hull5_color_buffer) <= 0)
   {
      Print("ERROR: Failed to copy Hull(5) data.");
      return false;
   }
   
   // Copy Hull(10) buffers
   if (CopyBuffer(handle_hull10, 0, 0, 2, hull10_buffer) <= 0 ||
       CopyBuffer(handle_hull10, 1, 0, 2, hull10_color_buffer) <= 0)
   {
      Print("ERROR: Failed to copy Hull(10) data.");
      return false;
   }
   
   // Copy SMA(10)
   if (CopyBuffer(handle_sma10, 0, 0, 2, sma10_buffer) <= 0)
   {
      Print("ERROR: Failed to copy SMA(10) data.");
      return false;
   }
   
   // Copy MACD if enabled
   if (UseMACD_Confirmation)
   {
      if (CopyBuffer(handle_macd, 0, 0, 2, macd_buffer) <= 0 ||
          CopyBuffer(handle_macd, 1, 0, 2, macd_signal_buffer) <= 0 ||
          CopyBuffer(handle_macd, 2, 0, 2, macd_histogram) <= 0)
      {
         Print("ERROR: Failed to copy MACD data.");
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check Hull Crossover: Hull(5) crosses above Hull(10)             |
//| This checks if crossover happened between candle[1] and candle[0]|
//+------------------------------------------------------------------+
bool CheckHullCrossover()
{
   // Current candle (index 0) and previous candle (index 1)
   double hull5_current = hull5_buffer[0];
   double hull5_prev = hull5_buffer[1];
   double hull10_current = hull10_buffer[0];
   double hull10_prev = hull10_buffer[1];
   
   // CRITICAL FIX #2: Improved crossover detection logic
   // Check for crossover: Hull(5) was below Hull(10) and now above
   // Using < instead of <= for more reliable crossover detection
   bool crossoverDetected = (hull5_prev < hull10_prev) && (hull5_current > hull10_current);
   
   if (crossoverDetected)
   {
      Print("DEBUG: Hull(5) (", hull5_current, ") crossed ABOVE Hull(10) (", hull10_current, ")");
      Print("DEBUG: Previous - Hull(5): ", hull5_prev, ", Hull(10): ", hull10_prev);
      return true;
   }
   
   // Optional: Add debug output every N candles to see the actual crossover values
   // This helps diagnose if crossovers are actually happening
   Print("DEBUG: Hull comparison - Hull(5): ", hull5_current, " vs Hull(10): ", hull10_current);
   
   return false;
}

//+------------------------------------------------------------------+
//| Check All Entry Conditions                                       |
//+------------------------------------------------------------------+
bool CheckEntryConditions()
{
   double rsi5 = rsi5_buffer[0];
   double rsi14 = rsi14_buffer[0];
   double smaValue = sma10_buffer[0];
   double priceClose1 = iClose(NULL, PERIOD_CURRENT, 1);
   double priceOpen1 = iOpen(NULL, PERIOD_CURRENT, 1);
   double priceLow1 = iLow(NULL, PERIOD_CURRENT, 1);
   
   // Debug info
   Print("DEBUG: === Entry Condition Check ===");
   Print("DEBUG: RSI(5): ", rsi5, " (threshold: < ", RSI_Threshold, ")");
   Print("DEBUG: RSI(14): ", rsi14);
   Print("DEBUG: SMA(10): ", smaValue, " (price is ", (priceClose1 > smaValue ? "ABOVE" : "BELOW"), ")");
   
   // Condition 1: RSI(5) < Threshold (in the zone, e.g., < 25)
   if (rsi5 >= RSI_Threshold)
   {
      Print("DEBUG: FAILED - RSI(5) (", rsi5, ") is NOT < ", RSI_Threshold);
      return false;
   }
   Print("DEBUG: ✓ RSI(5) < ", RSI_Threshold);
   
   // Condition 2: RSI(5) moving toward/crossing RSI(14) (separation closing)
   if (rsi5 <= rsi14)
   {
      Print("DEBUG: ✓ RSI(5) (", rsi5, ") <= RSI(14) (", rsi14, ") - Separation closing/crossed");
   }
   else
   {
      Print("DEBUG: WARNING - RSI(5) (", rsi5, ") > RSI(14) (", rsi14, ") - Not yet converged");
      // This is not a hard fail, just a warning
   }
   
   // Condition 3: Bullish pin on Candle[-1] (body-to-wick ratio)
   double bodySize = priceClose1 - priceOpen1;
   double lowerWick = priceOpen1 - priceLow1;
   
   if (bodySize <= 0)
   {
      Print("DEBUG: FAILED - Candle[-1] is NOT bullish (Close <= Open)");
      return false;
   }
   
   double pinRatio = lowerWick / bodySize;
   Print("DEBUG: Candle[-1] Body: ", bodySize, ", Lower Wick: ", lowerWick, ", Ratio: ", pinRatio, ":1");
   
   if (pinRatio < BullishPinRatio)
   {
      Print("DEBUG: FAILED - Pin ratio (", pinRatio, ":1) is NOT >= ", BullishPinRatio, ":1");
      return false;
   }
   Print("DEBUG: ✓ Bullish pin detected (", pinRatio, ":1)");
   
   // Condition 4: Price preference (above SMA10 = green light, below = yellow light)
   if (priceClose1 > smaValue)
   {
      Print("DEBUG: ✓ Price ABOVE SMA(10) - SAFE AREA");
   }
   else
   {
      Print("DEBUG: WARNING - Price BELOW SMA(10) - Trading below safe area (but allowed)");
   }
   
   // Condition 5: MACD confirmation (if enabled)
   if (UseMACD_Confirmation)
   {
      double macd_current = macd_buffer[0];
      double macd_signal = macd_signal_buffer[0];
      
      if (macd_current > macd_signal)
      {
         Print("DEBUG: ✓ MACD (", macd_current, ") > Signal (", macd_signal, ") - Bullish");
      }
      else
      {
         Print("DEBUG: WARNING - MACD (", macd_current, ") <= Signal (", macd_signal, ") - Not bullish");
         // This is not a hard fail, just a warning
      }
   }
   
   Print("DEBUG: === ALL PRIMARY CONDITIONS MET ===");
   return true;
}

//+------------------------------------------------------------------+
//| Open Trade Function                                              |
//+------------------------------------------------------------------+
bool OpenTrade()
{
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(askPrice - StopLoss * _Point, _Digits);
   double tp = NormalizeDouble(askPrice + TakeProfit * _Point, _Digits);
   
   Print("DEBUG: Attempting to open BUY trade. Ask: ", askPrice, ", SL: ", sl, ", TP: ", tp);
   
   // CRITICAL FIX #3: Use _Symbol instead of NULL in Trade.Buy()
   // This ensures the trade is placed on the correct symbol
   if (!Trade.Buy(LotSize, _Symbol, askPrice, sl, tp))
   {
      int errorCode = GetLastError();
      Print("ERROR: Trade execution failed. Error Code: ", errorCode);
      Print("ERROR: Error Description: ", GetLastError());
      return false;
   }
   else
   {
      Print("SUCCESS: BUY trade opened successfully at ", askPrice);
      return true;
   }
}

//+------------------------------------------------------------------+
//| Apply Trailing Stop                                              |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   if (PositionSelect(_Symbol))
   {
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double trailingStopLevel = NormalizeDouble(currentPrice - TrailingStop * _Point, _Digits);
      double currentStopLoss = PositionGetDouble(POSITION_SL);
      double currentTakeProfit = PositionGetDouble(POSITION_TP);
      
      if (trailingStopLevel > currentStopLoss)
      {
         if (!Trade.PositionModify(_Symbol, trailingStopLevel, currentTakeProfit))
         {
            int errorCode = GetLastError();
            Print("ERROR: Trailing stop modification failed. Error Code: ", errorCode);
         }
         else
         {
            Print("SUCCESS: Trailing stop updated to: ", trailingStopLevel);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper Function: IsNewCandle                                     |
//+------------------------------------------------------------------+
bool IsNewCandle()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(NULL, PERIOD_CURRENT, 0);
   
   if (currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   if (handle_rsicombo != INVALID_HANDLE) IndicatorRelease(handle_rsicombo);
   if (handle_hull5 != INVALID_HANDLE) IndicatorRelease(handle_hull5);
   if (handle_hull10 != INVALID_HANDLE) IndicatorRelease(handle_hull10);
   if (handle_macd != INVALID_HANDLE) IndicatorRelease(handle_macd);
   if (handle_sma10 != INVALID_HANDLE) IndicatorRelease(handle_sma10);
   
   Print("Stinger EA (Hull-Focused) FIXED - Deinitialized");
}
