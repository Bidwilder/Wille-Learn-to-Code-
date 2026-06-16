#include <Trade/Trade.mqh>
CTrade Trade;

//--- Input Parameters
input double LotSize = 0.01;                  // Lot size for trades
input double TakeProfit = 2500;               // Take profit in points
input double StopLoss = 1000;                 // Stop loss in points
input double TrailingStop = 1000;             // Trailing stop in points
input int SMA_Period = 10;                    // SMA period
input int SMA_BufferPoints = 100;             // Safety buffer above SMA (in points)

//--- Global Variables
datetime lastTradeCandle = 0;                // Track the last candle that executed a trade

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
Print("Stinger EA Initialized. LotSize: ", LotSize, ", SMA Period: ", SMA_Period, ", SMA Buffer: ", SMA_BufferPoints, " points");
return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
// Check if we are on a new candle
if (!IsNewCandle()) return;

// Get the current candle time
datetime currentCandleTime = iTime(NULL, PERIOD_CURRENT, 0);

// Prevent multiple trades on the same candle
if (lastTradeCandle == currentCandleTime)
{
    Print("DEBUG: Trade already executed on this candle. Skipping.");
    return;
}

// Calculate the SMA
double smaValue = iMA(NULL, PERIOD_CURRENT, SMA_Period, 0, MODE_SMA, PRICE_CLOSE);
if (smaValue == EMPTY_VALUE)
{
    Print("ERROR: Invalid SMA value. Exiting OnTick.");
    return;
}

smaValue = NormalizeDouble(smaValue, _Digits);

// Calculate SMA with buffer (add 100 points as safety cushion)
double smaWithBuffer = NormalizeDouble(smaValue + (SMA_BufferPoints * _Point), _Digits);

// Get price data we need for our conditions
double priceClose1 = iClose(NULL, PERIOD_CURRENT, 1);     // Close[-1] - Previous candle close
double priceHigh2  = iHigh(NULL, PERIOD_CURRENT, 2);      // High[-2] - Two candles ago high
double openPrice   = iOpen(NULL, PERIOD_CURRENT, 0);      // Open[0] - Current candle open

// Debugging information
Print("DEBUG: New Bar Detected.");
Print("DEBUG: SMA: ", smaValue);
Print("DEBUG: SMA + Buffer (", SMA_BufferPoints, " pts): ", smaWithBuffer);
Print("DEBUG: Close[-1]: ", priceClose1, " (must be > SMA + buffer for buy)");
Print("DEBUG: High[-2]: ", priceHigh2);
Print("DEBUG: Open[0]: ", openPrice);

// HARD FILTER: NO TRADES ALLOWED BELOW SMA + BUFFER
if (priceClose1 <= smaWithBuffer)
{
    Print("DEBUG: BLOCKED - Close[-1] (", priceClose1, ") is AT or BELOW SMA+Buffer (", smaWithBuffer, "). NO TRADES ALLOWED.");
    return;  // EXIT - Do not proceed with any trade logic
}

// ENTRY CONDITION: Close[-1] > SMA+Buffer AND Close[-1] > High[-2]
// This ensures: previous candle closed above SMA+buffer and above the high of 2 candles ago
if (priceClose1 > smaWithBuffer && priceClose1 > priceHigh2)
{
    Print("DEBUG: Entry conditions MET!");
    Print("DEBUG: Close[-1] (", priceClose1, ") > SMA+Buffer (", smaWithBuffer, ") ✓");
    Print("DEBUG: Close[-1] (", priceClose1, ") > High[-2] (", priceHigh2, ") ✓");
    
    if (PositionsTotal() == 0) // Ensure no open positions
    {
        Print("DEBUG: No existing positions. Attempting to open a trade.");
        if (OpenTrade(openPrice, smaValue))
        {
            lastTradeCandle = currentCandleTime; // Update the last candle with a trade
        }
    }
    else
    {
        Print("DEBUG: Existing position detected. No new trades allowed.");
    }
}
else
{
    Print("DEBUG: Entry conditions NOT met.");
    if (priceClose1 <= smaWithBuffer)
        Print("DEBUG REASON: Close[-1] (", priceClose1, ") is NOT > SMA+Buffer (", smaWithBuffer, ")");
    if (priceClose1 <= priceHigh2)
        Print("DEBUG REASON: Close[-1] (", priceClose1, ") is NOT > High[-2] (", priceHigh2, ")");
}

// Apply trailing stop for open positions
if (PositionsTotal() > 0)
{
    ApplyTrailingStop();
}

}

//+------------------------------------------------------------------+
//| Open Trade Function                                              |
//+------------------------------------------------------------------+
bool OpenTrade(double openPrice, double smaValue)
{
double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
double sl = NormalizeDouble(askPrice - StopLoss * _Point, _Digits);
double tp = NormalizeDouble(askPrice + TakeProfit * _Point, _Digits);

Print("DEBUG: Attempting to open a Buy trade. LotSize: ", LotSize, ", Ask Price: ", askPrice, ", SL: ", sl, ", TP: ", tp);

// Use CTrade::Buy
if (!Trade.Buy(LotSize, NULL, askPrice, sl, tp))
{
    int errorCode = GetLastError();
    Print("ERROR: Trade execution failed. Error Code: ", errorCode);
    return false;
}
else
{
    Print("SUCCESS: Trade opened successfully.");
    return true;
}

}

//+------------------------------------------------------------------+
//| Apply Trailing Stop                                              |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
if (PositionSelect(_Symbol)) // Select the current position
{
double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
double trailingStopLevel = NormalizeDouble(currentPrice - TrailingStop * _Point, _Digits);
double currentStopLoss = PositionGetDouble(POSITION_SL);
double currentTakeProfit = PositionGetDouble(POSITION_TP);

    Print("DEBUG: Current Price: ", currentPrice, ", Trailing Stop Level: ", trailingStopLevel);

    if (trailingStopLevel > currentStopLoss) // Update SL only if the new level is better
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
    else
    {
        Print("DEBUG: Trailing stop not updated. Current SL: ", currentStopLoss, ", Proposed: ", trailingStopLevel);
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
