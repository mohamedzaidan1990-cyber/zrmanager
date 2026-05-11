//+------------------------------------------------------------------+
//|                                              ZizoScalper_v1.6.mq5|
//|                                        Built for Mohamed @ Bayline|
//|                    Hit & Run Scalping — v1.6 LIVE-SAFE            |
//|   Fixes: handle leak, bar-0 bias, per-bar lock, spread filter,   |
//|          deal direction, DEAL_ENTRY_OUT guard                     |
//+------------------------------------------------------------------+
#property copyright "Zizo Scalper v1.6"
#property version   "1.60"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| SETTINGS                                                          |
//+------------------------------------------------------------------+
input double RiskPercent           = 1.65;
input double DailyLossLimit        = 3.0;
input int    MaxOpenTrades         = 5;
input int    MaxDailyTrades        = 5;
input int    FastEMA               = 5;
input int    SlowEMA               = 13;
input int    RSI_Period            = 14;
input double RSI_Overbought        = 70.0;
input double RSI_Oversold          = 30.0;
input int    ATR_Period            = 14;
input double SL_Multiplier         = 1.0;
input double TP_Multiplier         = 1.8;
input double VolatileSL_Multi      = 1.5;
// v1.6: expressed as ATR multiplier (e.g. 2.0 = ATR is 2x its own 50-bar average)
// Set to 0 to disable volatile detection
input double VolatileATR_Multi     = 2.0;
input int    RangeLookback         = 10;
input double RangeATR_Multi        = 1.5;
input int    MaxConsecutiveLosses  = 2;
input int    PauseAfterLossMinutes = 30;
input int    SameDirectionBars     = 6;
input bool   Use24hTrading         = true;
input int    StartHour             = 0;
input int    EndHour               = 23;
input string TradingSymbol         = "XAUUSD";
// v1.6: max spread allowed in points (0 = no filter). 50 pts = $0.50 on XAUUSD
input double MaxSpreadPoints       = 50;
input string TelegramBotToken      = "8360184972:AAEPatjOcGWi_esCUNowrN1900U8yXrNQVc";
input string FreeChatID            = "-1003507395391";
input string VIPChatID             = "-1003723825502";
input bool   SendTelegramSignals   = true;

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
double   startingDayBalance    = 0;
datetime lastTradeTime         = 0;
datetime currentDay            = 0;
int      dailyTradeCount       = 0;
bool     isBacktesting         = false;
int      tickCount             = 0;
string   lastTradeDirection    = "";
datetime lastDirectionTime     = 0;
int      consecutiveLosses     = 0;
datetime lastLossTime          = 0;

// v1.6: cached indicator handles (created once in OnInit)
int handleFastEMA  = INVALID_HANDLE;
int handleSlowEMA  = INVALID_HANDLE;
int handleRSI      = INVALID_HANDLE;
int handleATR      = INVALID_HANDLE;
int handleATR50    = INVALID_HANDLE; // 50-period ATR for volatility baseline

// v1.6: per-bar lock — only evaluate signals on a new closed bar
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Telegram                                                          |
//+------------------------------------------------------------------+
void SendTelegram(string chatID, string message)
{
   if(!SendTelegramSignals || isBacktesting) return;
   string url     = "https://api.telegram.org/bot" + TelegramBotToken + "/sendMessage";
   string params  = "chat_id=" + chatID + "&text=" + message + "&parse_mode=Markdown";
   char   post[], result[];
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string resultHeaders;
   ArrayResize(post, StringToCharArray(params, post, 0, WHOLE_ARRAY) - 1);
   int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
   if(res == -1) Print("Telegram error: ", GetLastError());
   else Print("Telegram sent to ", chatID);
}

void BroadcastSignal(string direction, double entry, double sl, double tp, bool isVolatile)
{
   if(isBacktesting) return;
   double rr    = MathAbs(tp - entry) / MathAbs(sl - entry);
   string arrow = (direction == "SELL") ? "[ SELL ]" : "[ BUY ]";
   string market = isVolatile ? "High volatility — wider SL active" : "Normal conditions";

   string freeMsg = "*-- GOLD SIGNAL ALERT --*\n\n"
                  + "Instrument: *" + TradingSymbol + "*\n"
                  + "Direction: *" + arrow + "*\n\n"
                  + "Full entry, SL and TP in VIP channel.\n"
                  + "Subscribe: t.me/GoldAlertsVIPBot\n\n"
                  + "Not financial advice.";

   string vipMsg  = "*-- GOLD ALERTS VIP SIGNAL --*\n\n"
                  + "Instrument:  *" + TradingSymbol + "*\n"
                  + "Direction:   *" + arrow + "*\n"
                  + "Entry:       *" + DoubleToString(entry, 2) + "*\n"
                  + "Stop Loss:   *" + DoubleToString(sl, 2) + "*\n"
                  + "Take Profit: *" + DoubleToString(tp, 2) + "*\n"
                  + "R/R Ratio:   *1:" + DoubleToString(rr, 1) + "*\n"
                  + "Market:      *" + market + "*\n\n"
                  + "Signal live now — enter immediately.\n\n"
                  + "Not financial advice. Trade at your own risk.";

   SendTelegram(FreeChatID, freeMsg);
   SendTelegram(VIPChatID, vipMsg);
}

void BroadcastResult(string direction, double profit)
{
   if(isBacktesting) return;
   string label     = (profit > 0) ? "WIN" : "LOSS";
   string profitStr = (profit > 0 ? "+" : "") + DoubleToString(profit, 2);
   string msg = "*-- TRADE CLOSED: " + label + " --*\n\n"
              + "Instrument: *" + TradingSymbol + "*\n"
              + "Direction:  *" + direction + "*\n"
              + "Result:     *$" + profitStr + "*\n\n"
              + "Daily trades: " + IntegerToString(dailyTradeCount) + "/" + IntegerToString(MaxDailyTrades) + "\n\n"
              + "Not financial advice.";
   SendTelegram(FreeChatID, msg);
   SendTelegram(VIPChatID, msg);
}

//+------------------------------------------------------------------+
//| Range Filter                                                      |
//+------------------------------------------------------------------+
bool IsRangingMarket(double atr)
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   if(CopyHigh(TradingSymbol, PERIOD_M5, 1, RangeLookback, highs) <= 0) return false;
   if(CopyLow(TradingSymbol, PERIOD_M5, 1, RangeLookback, lows) <= 0) return false;
   double range = highs[ArrayMaximum(highs, 0, RangeLookback)] - lows[ArrayMinimum(lows, 0, RangeLookback)];
   bool ranging = (range < atr * RangeATR_Multi);
   if(ranging) Print("Range filter: CHOPPY — skipping");
   return ranging;
}

//+------------------------------------------------------------------+
//| Weekend check                                                     |
//+------------------------------------------------------------------+
bool IsWeekend()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 0 || dt.day_of_week == 6);
}

//+------------------------------------------------------------------+
//| Spread check (v1.6)                                              |
//+------------------------------------------------------------------+
bool IsSpreadTooWide()
{
   if(MaxSpreadPoints <= 0) return false;
   double ask    = SymbolInfoDouble(TradingSymbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(TradingSymbol, SYMBOL_BID);
   double point  = SymbolInfoDouble(TradingSymbol, SYMBOL_POINT);
   double spread = (ask - bid) / point;
   if(spread > MaxSpreadPoints)
   {
      Print("Spread too wide: ", spread, " pts — skipping");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   isBacktesting = (MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION));

   // v1.6: create all handles once here — no per-tick handle creation
   handleFastEMA = iMA(TradingSymbol, PERIOD_M5, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA = iMA(TradingSymbol, PERIOD_M5, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(TradingSymbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   handleATR     = iATR(TradingSymbol, PERIOD_M5, ATR_Period);
   handleATR50   = iATR(TradingSymbol, PERIOD_M5, 50);

   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE ||
      handleRSI     == INVALID_HANDLE || handleATR     == INVALID_HANDLE ||
      handleATR50   == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles. Check symbol/timeframe.");
      return(INIT_FAILED);
   }

   Print("=== ZIZO SCALPER v1.6 STARTED ===");
   Print("24/5 Trading: ", Use24hTrading ? "ON" : "OFF");
   Print("Range filter: ON (", RangeLookback, " bars, ", RangeATR_Multi, "x ATR)");
   Print("Max consecutive losses: ", MaxConsecutiveLosses, " pause ", PauseAfterLossMinutes, " mins");
   Print("Same direction cooldown: ", SameDirectionBars, " bars");
   Print("Risk: ", RiskPercent, "% | SL/TP: ", SL_Multiplier, "/", TP_Multiplier);
   Print("Spread filter: ", MaxSpreadPoints > 0 ? DoubleToString(MaxSpreadPoints, 0) + " pts max" : "OFF");
   Print("Mode: ", isBacktesting ? "BACKTEST" : "LIVE");
   Print("Volatile detection: ATR > ", VolatileATR_Multi, "x 50-bar ATR baseline");
   Print("Yalla yalla — Hit and Run activated!");

   // v1.6: use equity as starting balance so open positions don't skew day calc
   startingDayBalance = AccountInfoDouble(ACCOUNT_EQUITY);
   trade.SetExpertMagicNumber(20260510);
   trade.SetDeviationInPoints(30);

   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v1.6 is now ONLINE*\n\n"
                            + "24/5 trading: ACTIVE\n"
                            + "Range filter: ACTIVE\n"
                            + "Loss protection: ACTIVE\n"
                            + "Spread filter: " + (MaxSpreadPoints > 0 ? DoubleToString(MaxSpreadPoints, 0) + " pts" : "OFF") + "\n"
                            + "Symbol: " + TradingSymbol + "\n"
                            + "Risk: " + DoubleToString(RiskPercent, 2) + "%\n\n"
                            + "Yalla yalla — Hit and Run activated!");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // v1.6: release all handles to avoid leaks
   if(handleFastEMA != INVALID_HANDLE) { IndicatorRelease(handleFastEMA); handleFastEMA = INVALID_HANDLE; }
   if(handleSlowEMA != INVALID_HANDLE) { IndicatorRelease(handleSlowEMA); handleSlowEMA = INVALID_HANDLE; }
   if(handleRSI     != INVALID_HANDLE) { IndicatorRelease(handleRSI);     handleRSI     = INVALID_HANDLE; }
   if(handleATR     != INVALID_HANDLE) { IndicatorRelease(handleATR);     handleATR     = INVALID_HANDLE; }
   if(handleATR50   != INVALID_HANDLE) { IndicatorRelease(handleATR50);   handleATR50   = INVALID_HANDLE; }

   Print("=== ZIZO SCALPER v1.6 STOPPED ===");
   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v1.6 is now OFFLINE*\n\nNo new signals until bot restarts.");
}

//+------------------------------------------------------------------+
//| Main tick                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   if(IsWeekend()) return;

   // v1.6: per-bar lock — only run signal logic on a freshly closed bar
   datetime currentBarTime = iTime(TradingSymbol, PERIOD_M5, 1);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   if(todayStart != currentDay)
   {
      // v1.6: use equity so open floating P&L is included in day reset
      startingDayBalance  = AccountInfoDouble(ACCOUNT_EQUITY);
      currentDay          = todayStart;
      dailyTradeCount     = 0;
      consecutiveLosses   = 0;
      lastTradeDirection  = "";
      lastDirectionTime   = 0;
      Print("New day — Equity: $", startingDayBalance, " | All counters reset");
   }

   // Safety checks
   double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLossPct   = ((startingDayBalance - currentEquity) / startingDayBalance) * 100.0;
   if(dailyLossPct >= DailyLossLimit) { Print("Daily loss limit hit — Paused."); return; }
   if(dailyTradeCount >= MaxDailyTrades) { Print("Max daily trades hit."); return; }
   if(!Use24hTrading && (dt.hour < StartHour || dt.hour >= EndHour)) return;
   if(CountOpenTrades() >= MaxOpenTrades) return;

   // v1.6: spread filter
   if(IsSpreadTooWide()) return;

   // Consecutive loss pause
   if(consecutiveLosses >= MaxConsecutiveLosses)
   {
      int minutesSinceLoss = (int)(TimeCurrent() - lastLossTime) / 60;
      if(minutesSinceLoss < PauseAfterLossMinutes)
      {
         Print("Loss pause — ", PauseAfterLossMinutes - minutesSinceLoss, " mins left");
         return;
      }
      else
      {
         consecutiveLosses = 0;
         Print("Loss pause over — resuming trading");
      }
   }

   if(TimeCurrent() - lastTradeTime < PeriodSeconds(PERIOD_M5) * 2) return;

   // v1.6: read confirmed bars (shift 1 = last closed bar, shift 2 = bar before that)
   // This eliminates look-ahead bias from reading the forming bar
   double fastEMA_current = GetCachedEMA(handleFastEMA, 1);
   double fastEMA_prev    = GetCachedEMA(handleFastEMA, 2);
   double slowEMA_current = GetCachedEMA(handleSlowEMA, 1);
   double slowEMA_prev    = GetCachedEMA(handleSlowEMA, 2);
   double rsi             = GetCachedValue(handleRSI,   1);
   double atr             = GetCachedValue(handleATR,   1);
   double atr50           = GetCachedValue(handleATR50, 1);

   if(fastEMA_current == 0 || slowEMA_current == 0 || atr == 0) return;

   // Range filter (also reads closed bars now)
   if(IsRangingMarket(atr)) return;

   // v1.6: adaptive volatility — compare current ATR against its own 50-bar baseline
   bool isVolatile = (VolatileATR_Multi > 0 && atr50 > 0 && atr > atr50 * VolatileATR_Multi);
   double sl_multi = isVolatile ? VolatileSL_Multi : SL_Multiplier;

   double ask         = SymbolInfoDouble(TradingSymbol, SYMBOL_ASK);
   double bid         = SymbolInfoDouble(TradingSymbol, SYMBOL_BID);
   double sl_distance = atr * sl_multi;
   double tp_distance = atr * TP_Multiplier;
   double lotSize     = CalculateLotSize(sl_distance);
   if(lotSize <= 0) return;

   tickCount++;
   Print("Bar closed | RSI: ", DoubleToString(rsi, 1),
         " | ATR: ", DoubleToString(atr, 2),
         " | ATR50: ", DoubleToString(atr50, 2),
         " | Volatile: ", isVolatile ? "YES" : "NO",
         " | Losses: ", consecutiveLosses,
         " | Trades: ", dailyTradeCount, "/", MaxDailyTrades);

   // Same direction cooldown
   bool buyCooldown  = (lastTradeDirection == "BUY" &&
                        TimeCurrent() - lastDirectionTime < PeriodSeconds(PERIOD_M5) * SameDirectionBars);
   bool sellCooldown = (lastTradeDirection == "SELL" &&
                        TimeCurrent() - lastDirectionTime < PeriodSeconds(PERIOD_M5) * SameDirectionBars);

   // Entry conditions (using closed bars 1 and 2 — no look-ahead)
   bool buySignal  = (fastEMA_prev <= slowEMA_prev) &&
                     (fastEMA_current > slowEMA_current) &&
                     (rsi < RSI_Overbought) &&
                     (rsi > 40) &&
                     !buyCooldown;

   bool sellSignal = (fastEMA_prev >= slowEMA_prev) &&
                     (fastEMA_current < slowEMA_current) &&
                     (rsi > RSI_Oversold) &&
                     (rsi < 60) &&
                     !sellCooldown;

   if(buySignal)
   {
      double sl = ask - sl_distance;
      double tp = ask + tp_distance;
      Print("BUY signal! RSI: ", DoubleToString(rsi, 1), " | Volatile: ", isVolatile ? "YES" : "NO");
      BroadcastSignal("BUY", ask, sl, tp, isVolatile);
      if(trade.Buy(lotSize, TradingSymbol, ask, sl, tp, "Zizo BUY v1.6"))
      {
         lastTradeTime      = TimeCurrent();
         lastTradeDirection = "BUY";
         lastDirectionTime  = TimeCurrent();
         dailyTradeCount++;
         Print("BUY opened | Lot: ", lotSize, " | Daily: ", dailyTradeCount, "/", MaxDailyTrades);
      }
   }
   else if(sellSignal)
   {
      double sl = bid + sl_distance;
      double tp = bid - tp_distance;
      Print("SELL signal! RSI: ", DoubleToString(rsi, 1), " | Volatile: ", isVolatile ? "YES" : "NO");
      BroadcastSignal("SELL", bid, sl, tp, isVolatile);
      if(trade.Sell(lotSize, TradingSymbol, bid, sl, tp, "Zizo SELL v1.6"))
      {
         lastTradeTime      = TimeCurrent();
         lastTradeDirection = "SELL";
         lastDirectionTime  = TimeCurrent();
         dailyTradeCount++;
         Print("SELL opened | Lot: ", lotSize, " | Daily: ", dailyTradeCount, "/", MaxDailyTrades);
      }
   }
}

//+------------------------------------------------------------------+
//| Track closed trades + consecutive loss counter                   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;

   // v1.6: only process closing deals — entry deals carry 0 profit
   long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   if(symbol != TradingSymbol) return;

   // v1.6: closing deal type is the OPPOSITE of the original position direction
   // DEAL_TYPE_BUY on close = was a SELL position; DEAL_TYPE_SELL on close = was a BUY position
   long   dealType  = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   string direction = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";

   if(profit > 0)
   {
      consecutiveLosses = 0;
      Print("WIN — Consecutive losses reset to 0");
   }
   else
   {
      consecutiveLosses++;
      lastLossTime = TimeCurrent();
      Print("LOSS — Consecutive losses: ", consecutiveLosses);
      if(consecutiveLosses >= MaxConsecutiveLosses)
      {
         Print("Max consecutive losses — pausing ", PauseAfterLossMinutes, " mins");
         if(!isBacktesting)
            SendTelegram(VIPChatID, "*-- ZIZO PAUSED --*\n\n"
                                  + "2 consecutive losses detected.\n"
                                  + "Pausing for " + IntegerToString(PauseAfterLossMinutes) + " minutes.\n"
                                  + "Will resume automatically.\n\n"
                                  + "Not financial advice.");
      }
   }
   BroadcastResult(direction, profit);
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);
   double tickValue  = SymbolInfoDouble(TradingSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(TradingSymbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot     = SymbolInfoDouble(TradingSymbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(TradingSymbol, SYMBOL_VOLUME_MAX);
   double lotStep    = SymbolInfoDouble(TradingSymbol, SYMBOL_VOLUME_STEP);
   if(tickValue == 0 || tickSize == 0 || slDistance == 0) return minLot;
   double lotSize = riskAmount / ((slDistance / tickSize) * tickValue);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   return lotSize;
}

int CountOpenTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == TradingSymbol && posInfo.Magic() == 20260510)
            count++;
   return count;
}

// v1.6: reads from a pre-created handle at the specified closed-bar shift
double GetCachedEMA(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return 0;
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, 0, shift, 1, val) <= 0) return 0;
   return val[0];
}

double GetCachedValue(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return 0;
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, 0, shift, 1, val) <= 0) return 0;
   return val[0];
}
//+------------------------------------------------------------------+
