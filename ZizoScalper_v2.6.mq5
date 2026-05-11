//+------------------------------------------------------------------+
//|                                              ZizoScalper_v2.6.mq5|
//|                                        Built for Mohamed @ Bayline|
//|         Hit & Run — v2.6 UPTREND ZONE ONLY EDITION               |
//|  Both BUY and SELL require price > 50 EMA                        |
//|  Bull market: trade pullbacks AND failed bounces in uptrend only  |
//+------------------------------------------------------------------+
#property copyright "Zizo Scalper v2.6"
#property version   "2.60"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| SETTINGS                                                          |
//+------------------------------------------------------------------+
input double BaseRiskPercent       = 1.65;
input double DailyLossLimit        = 3.0;
input int    MaxDailyLosses        = 2;
input int    MaxOpenTrades         = 3;
input int    MaxDailyTrades        = 5;
input int    FastEMA               = 5;
input int    SlowEMA               = 13;
input int    TrendEMA              = 50;
input int    RSI_Period            = 14;
input double RSI_BuyMin            = 45.0;
input double RSI_BuyMax            = 65.0;
input double RSI_SellMin           = 37.0;
input double RSI_SellMax           = 55.0;
input int    ATR_Period            = 14;
input double SL_Multiplier         = 1.0;
input double TP_Multiplier         = 2.0;
input double VolatileSL_Multi      = 1.4;
input double VolatileATR_Multi     = 2.0;
input int    RangeLookback         = 10;
input double RangeATR_Multi        = 1.5;
input int    MaxConsecutiveLosses  = 2;
input int    PauseAfterLossMinutes = 60;
input int    SameDirectionBars     = 4;
input bool   Use24hTrading         = true;
input int    StartHour             = 0;
input int    EndHour               = 23;
input string TradingSymbol         = "XAUUSD";
input double MaxSpreadPoints       = 50;
input string TelegramBotToken      = "8360184972:AAEPatjOcGWi_esCUNowrN1900U8yXrNQVc";
input string FreeChatID            = "-1003507395391";
input string VIPChatID             = "-1003723825502";
input bool   SendTelegramSignals   = true;

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
double   startingDayBalance = 0;
datetime lastTradeTime      = 0;
datetime currentDay         = 0;
int      dailyTradeCount    = 0;
int      dailyLossCount     = 0;
bool     isBacktesting      = false;
string   lastTradeDirection = "";
datetime lastDirectionTime  = 0;
int      consecutiveLosses  = 0;
datetime lastLossTime       = 0;

int handleFastEMA  = INVALID_HANDLE;
int handleSlowEMA  = INVALID_HANDLE;
int handleTrendEMA = INVALID_HANDLE;
int handleRSI      = INVALID_HANDLE;
int handleATR      = INVALID_HANDLE;
int handleATR50    = INVALID_HANDLE;

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

void BroadcastSignal(string direction, double entry, double sl, double tp)
{
   if(isBacktesting) return;
   double rr    = MathAbs(tp - entry) / MathAbs(sl - entry);
   string arrow = (direction == "SELL") ? "[ SELL ]" : "[ BUY ]";
   string freeMsg = "*-- GOLD SIGNAL ALERT --*\n\nInstrument: *" + TradingSymbol + "*\nDirection: *" + arrow + "*\n\nFull entry, SL and TP in VIP channel.\nSubscribe: t.me/GoldAlertsVIPBot\n\nNot financial advice.";
   string vipMsg  = "*-- GOLD ALERTS VIP SIGNAL --*\n\nInstrument:  *" + TradingSymbol + "*\nDirection:   *" + arrow + "*\nEntry:       *" + DoubleToString(entry,2) + "*\nStop Loss:   *" + DoubleToString(sl,2) + "*\nTake Profit: *" + DoubleToString(tp,2) + "*\nR/R Ratio:   *1:" + DoubleToString(rr,1) + "*\nGrade: *PREMIUM* (3/3)\n\nUptrend zone signal.\n\nNot financial advice. Trade at your own risk.";
   SendTelegram(FreeChatID, freeMsg);
   SendTelegram(VIPChatID, vipMsg);
}

void BroadcastResult(string direction, double profit)
{
   if(isBacktesting) return;
   string label     = (profit > 0) ? "WIN" : (profit == 0 ? "BREAKEVEN" : "LOSS");
   string profitStr = (profit > 0 ? "+" : "") + DoubleToString(profit, 2);
   string msg = "*-- TRADE CLOSED: " + label + " --*\n\nInstrument: *" + TradingSymbol + "*\nDirection:  *" + direction + "*\nResult:     *$" + profitStr + "*\n\nTrades today: " + IntegerToString(dailyTradeCount) + "/" + IntegerToString(MaxDailyTrades) + "\nLosses today: " + IntegerToString(dailyLossCount) + "/" + IntegerToString(MaxDailyLosses) + "\n\nNot financial advice.";
   SendTelegram(FreeChatID, msg);
   SendTelegram(VIPChatID, msg);
}

//+------------------------------------------------------------------+
//| Filters                                                           |
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

bool IsWeekend()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 0 || dt.day_of_week == 6);
}

bool IsSpreadTooWide()
{
   if(MaxSpreadPoints <= 0) return false;
   double spread = (SymbolInfoDouble(TradingSymbol, SYMBOL_ASK) - SymbolInfoDouble(TradingSymbol, SYMBOL_BID))
                   / SymbolInfoDouble(TradingSymbol, SYMBOL_POINT);
   if(spread > MaxSpreadPoints) { Print("Spread too wide: ", spread, " pts"); return true; }
   return false;
}

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   isBacktesting = (MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION));

   handleFastEMA  = iMA(TradingSymbol, PERIOD_M5, FastEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA  = iMA(TradingSymbol, PERIOD_M5, SlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleTrendEMA = iMA(TradingSymbol, PERIOD_M5, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI      = iRSI(TradingSymbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   handleATR      = iATR(TradingSymbol, PERIOD_M5, ATR_Period);
   handleATR50    = iATR(TradingSymbol, PERIOD_M5, 50);

   if(handleFastEMA==INVALID_HANDLE || handleSlowEMA==INVALID_HANDLE ||
      handleTrendEMA==INVALID_HANDLE || handleRSI==INVALID_HANDLE ||
      handleATR==INVALID_HANDLE || handleATR50==INVALID_HANDLE)
   { Print("ERROR: Failed to create handles."); return(INIT_FAILED); }

   Print("=== ZIZO SCALPER v2.6 STARTED ===");
   Print("Uptrend zone only: both BUY and SELL require price > 50 EMA");
   Print("TP: ", TP_Multiplier, "x ATR | SL: ", SL_Multiplier, "x ATR | Risk: ", BaseRiskPercent * 1.30, "%");
   Print("Daily loss cap: ", MaxDailyLosses, " | Mode: ", isBacktesting ? "BACKTEST" : "LIVE");

   startingDayBalance = AccountInfoDouble(ACCOUNT_EQUITY);
   trade.SetExpertMagicNumber(20260510);
   trade.SetDeviationInPoints(30);

   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v2.6 ONLINE — Uptrend Zone Edition*\n\n"
                            + "Both BUY and SELL: price > 50 EMA only\n"
                            + "Trade pullbacks AND failed bounces in bull market.\n"
                            + "TP: " + DoubleToString(TP_Multiplier,1) + "x ATR\n"
                            + "Daily loss cap: " + IntegerToString(MaxDailyLosses) + "\n\n"
                            + "Yalla yalla — Hit and Run activated!");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleFastEMA  != INVALID_HANDLE) { IndicatorRelease(handleFastEMA);  handleFastEMA  = INVALID_HANDLE; }
   if(handleSlowEMA  != INVALID_HANDLE) { IndicatorRelease(handleSlowEMA);  handleSlowEMA  = INVALID_HANDLE; }
   if(handleTrendEMA != INVALID_HANDLE) { IndicatorRelease(handleTrendEMA); handleTrendEMA = INVALID_HANDLE; }
   if(handleRSI      != INVALID_HANDLE) { IndicatorRelease(handleRSI);      handleRSI      = INVALID_HANDLE; }
   if(handleATR      != INVALID_HANDLE) { IndicatorRelease(handleATR);      handleATR      = INVALID_HANDLE; }
   if(handleATR50    != INVALID_HANDLE) { IndicatorRelease(handleATR50);    handleATR50    = INVALID_HANDLE; }

   Print("=== ZIZO SCALPER v2.6 STOPPED ===");
   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v2.6 OFFLINE*\n\nNo signals until restart.");
}

//+------------------------------------------------------------------+
//| Main tick                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   if(IsWeekend()) return;

   datetime currentBarTime = iTime(TradingSymbol, PERIOD_M5, 1);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   if(todayStart != currentDay)
   {
      startingDayBalance = AccountInfoDouble(ACCOUNT_EQUITY);
      currentDay = todayStart; dailyTradeCount = 0; dailyLossCount = 0;
      consecutiveLosses = 0; lastTradeDirection = ""; lastDirectionTime = 0;
      Print("New day — Equity: $", startingDayBalance);
   }

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLossPct  = ((startingDayBalance - currentEquity) / startingDayBalance) * 100.0;
   if(dailyLossPct >= DailyLossLimit)   { Print("Daily equity limit hit."); return; }
   if(dailyLossCount >= MaxDailyLosses) { Print("Daily loss cap — stopped today."); return; }
   if(dailyTradeCount >= MaxDailyTrades){ Print("Max daily trades hit."); return; }
   if(!Use24hTrading && (dt.hour < StartHour || dt.hour >= EndHour)) return;
   if(CountOpenTrades() >= MaxOpenTrades) return;
   if(IsSpreadTooWide()) return;

   if(consecutiveLosses >= MaxConsecutiveLosses)
   {
      int minsSinceLoss = (int)(TimeCurrent() - lastLossTime) / 60;
      if(minsSinceLoss < PauseAfterLossMinutes)
      { Print("Streak pause — ", PauseAfterLossMinutes - minsSinceLoss, " mins left"); return; }
      consecutiveLosses = 0;
      Print("Streak pause over — resuming");
   }

   if(TimeCurrent() - lastTradeTime < PeriodSeconds(PERIOD_M5) * 2) return;

   double fastEMA_cur  = GetValue(handleFastEMA,  1);
   double fastEMA_prev = GetValue(handleFastEMA,  2);
   double slowEMA_cur  = GetValue(handleSlowEMA,  1);
   double slowEMA_prev = GetValue(handleSlowEMA,  2);
   double trendEMA     = GetValue(handleTrendEMA, 1);
   double rsi          = GetValue(handleRSI,      1);
   double atr          = GetValue(handleATR,      1);
   double atr50        = GetValue(handleATR50,    1);

   if(fastEMA_cur==0 || slowEMA_cur==0 || atr==0) return;
   if(IsRangingMarket(atr)) return;

   bool isVolatile = (VolatileATR_Multi > 0 && atr50 > 0 && atr > atr50 * VolatileATR_Multi);
   double sl_multi = isVolatile ? VolatileSL_Multi : SL_Multiplier;

   double ask = SymbolInfoDouble(TradingSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradingSymbol, SYMBOL_BID);

   bool buyCooldown  = (lastTradeDirection=="BUY"  && TimeCurrent()-lastDirectionTime < PeriodSeconds(PERIOD_M5)*SameDirectionBars);
   bool sellCooldown = (lastTradeDirection=="SELL" && TimeCurrent()-lastDirectionTime < PeriodSeconds(PERIOD_M5)*SameDirectionBars);

   bool emaBuyCross  = (fastEMA_prev <= slowEMA_prev) && (fastEMA_cur > slowEMA_cur);
   bool emaSellCross = (fastEMA_prev >= slowEMA_prev) && (fastEMA_cur < slowEMA_cur);
   bool rsiBuyOk     = (rsi >= RSI_BuyMin  && rsi <= RSI_BuyMax);
   bool rsiSellOk    = (rsi >= RSI_SellMin && rsi <= RSI_SellMax);

   // v2.6: BOTH directions only taken when price is in uptrend (above 50 EMA)
   // BUY = trend continuation pullback | SELL = failed bounce / mean reversion
   bool inUptrend = (bid > trendEMA);

   // All trades are Score 3 (uptrend confirmed) — always 1.30x risk
   double riskPct = BaseRiskPercent * 1.30;

   bool buySignal  = emaBuyCross  && rsiBuyOk  && inUptrend && !buyCooldown;
   bool sellSignal = emaSellCross && rsiSellOk && inUptrend && !sellCooldown;

   if(buySignal)
   {
      double sl_dist = atr * sl_multi;
      double tp_dist = atr * TP_Multiplier;
      double lotSize = CalculateLotSize(sl_dist, riskPct);
      if(lotSize <= 0) return;
      double sl = ask - sl_dist;
      double tp = ask + tp_dist;
      Print("BUY uptrend Risk:", DoubleToString(riskPct,2), "% RSI:", DoubleToString(rsi,1));
      BroadcastSignal("BUY", ask, sl, tp);
      if(trade.Buy(lotSize, TradingSymbol, ask, sl, tp, "Zizo BUY v2.6"))
      {
         lastTradeTime=TimeCurrent(); lastTradeDirection="BUY"; lastDirectionTime=TimeCurrent();
         dailyTradeCount++;
         Print("BUY opened Lot:", lotSize, " Daily:", dailyTradeCount, "/", MaxDailyTrades);
      }
   }
   else if(sellSignal)
   {
      double sl_dist = atr * sl_multi;
      double tp_dist = atr * TP_Multiplier;
      double lotSize = CalculateLotSize(sl_dist, riskPct);
      if(lotSize <= 0) return;
      double sl = bid + sl_dist;
      double tp = bid - tp_dist;
      Print("SELL failed-bounce Risk:", DoubleToString(riskPct,2), "% RSI:", DoubleToString(rsi,1));
      BroadcastSignal("SELL", bid, sl, tp);
      if(trade.Sell(lotSize, TradingSymbol, bid, sl, tp, "Zizo SELL v2.6"))
      {
         lastTradeTime=TimeCurrent(); lastTradeDirection="SELL"; lastDirectionTime=TimeCurrent();
         dailyTradeCount++;
         Print("SELL opened Lot:", lotSize, " Daily:", dailyTradeCount, "/", MaxDailyTrades);
      }
   }
}

//+------------------------------------------------------------------+
//| Track closed trades                                              |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;
   if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != TradingSymbol) return;

   long   dealType  = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   string direction = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";

   if(profit > 0)
   {
      consecutiveLosses = 0;
      Print("WIN — streak reset | Daily losses: ", dailyLossCount, "/", MaxDailyLosses);
   }
   else if(profit < 0)
   {
      consecutiveLosses++; dailyLossCount++; lastLossTime = TimeCurrent();
      Print("LOSS — streak:", consecutiveLosses, " | Daily:", dailyLossCount, "/", MaxDailyLosses);
      if(consecutiveLosses >= MaxConsecutiveLosses)
      {
         Print("Streak limit — pausing ", PauseAfterLossMinutes, " mins");
         if(!isBacktesting)
            SendTelegram(VIPChatID, "*-- ZIZO PAUSED --*\n\n"
                                  + IntegerToString(MaxConsecutiveLosses) + " consecutive losses.\n"
                                  + "Pausing " + IntegerToString(PauseAfterLossMinutes) + " minutes.\n\n"
                                  + "Not financial advice.");
      }
      if(dailyLossCount >= MaxDailyLosses)
      {
         Print("Daily cap reached — done for today");
         if(!isBacktesting)
            SendTelegram(VIPChatID, "*-- ZIZO: DAILY CAP --*\n\n"
                                  + IntegerToString(MaxDailyLosses) + " losses today.\n"
                                  + "Stopped until tomorrow.\n\n"
                                  + "Not financial advice.");
      }
   }
   else
      Print("BREAKEVEN — no count change");

   BroadcastResult(direction, profit);
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance, double riskPct)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (riskPct / 100.0);
   double tickValue  = SymbolInfoDouble(TradingSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(TradingSymbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot     = SymbolInfoDouble(TradingSymbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(TradingSymbol, SYMBOL_VOLUME_MAX);
   double lotStep    = SymbolInfoDouble(TradingSymbol, SYMBOL_VOLUME_STEP);
   if(tickValue==0 || tickSize==0 || slDistance==0) return minLot;
   double lotSize = riskAmount / ((slDistance / tickSize) * tickValue);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lotSize));
}

int CountOpenTrades()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol()==TradingSymbol && posInfo.Magic()==20260510) count++;
   return count;
}

double GetValue(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return 0;
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, 0, shift, 1, val) <= 0) return 0;
   return val[0];
}
//+------------------------------------------------------------------+
