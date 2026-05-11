//+------------------------------------------------------------------+
//|                                              ZizoScalper_v1.7.mq5|
//|                                        Built for Mohamed @ Bayline|
//|               Hit & Run — v1.7 CALCULATED RISK EDITION           |
//|  Signal scoring, dynamic lots, trend filter, daily loss cap       |
//+------------------------------------------------------------------+
#property copyright "Zizo Scalper v1.7"
#property version   "1.70"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| SETTINGS                                                          |
//+------------------------------------------------------------------+
input double BaseRiskPercent       = 1.65;   // Base risk % (Score 2). Score 1 = 60%, Score 3 = 150%
input double DailyLossLimit        = 3.0;    // Equity drawdown % to halt all trading
input int    MaxDailyLosses        = 3;      // Losing trades per day before stopping for the day
input int    MaxOpenTrades         = 5;
input int    MaxDailyTrades        = 6;
input int    FastEMA               = 5;
input int    SlowEMA               = 13;
input int    TrendEMA              = 50;     // v1.7: trend filter — only trade with this EMA direction
input int    RSI_Period            = 14;
input double RSI_Overbought        = 70.0;
input double RSI_Oversold          = 30.0;
input int    ATR_Period            = 14;
input double SL_Multiplier         = 1.0;
input double TP_Multiplier         = 2.0;    // v1.7: raised from 1.8 — let winners run
input double VolatileSL_Multi      = 1.5;
input double VolatileATR_Multi     = 2.0;
input int    RangeLookback         = 10;
input double RangeATR_Multi        = 1.5;
input int    MaxConsecutiveLosses  = 2;      // Pause timer after streak
input int    PauseAfterLossMinutes = 60;     // v1.7: raised from 30 to 60
input int    SameDirectionBars     = 6;
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
double   startingDayBalance    = 0;
datetime lastTradeTime         = 0;
datetime currentDay            = 0;
int      dailyTradeCount       = 0;
int      dailyLossCount        = 0;   // v1.7: total losses today (hard daily cap)
bool     isBacktesting         = false;
string   lastTradeDirection    = "";
datetime lastDirectionTime     = 0;
int      consecutiveLosses     = 0;
datetime lastLossTime          = 0;

// Cached handles
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

void BroadcastSignal(string direction, double entry, double sl, double tp, int score)
{
   if(isBacktesting) return;
   double rr    = MathAbs(tp - entry) / MathAbs(sl - entry);
   string arrow = (direction == "SELL") ? "[ SELL ]" : "[ BUY ]";
   string stars = (score == 1) ? "STANDARD" : (score == 2) ? "QUALITY" : "PREMIUM";

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
                  + "Signal Grade: *" + stars + "* (" + IntegerToString(score) + "/3)\n\n"
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
              + "Trades today: " + IntegerToString(dailyTradeCount) + "/" + IntegerToString(MaxDailyTrades) + "\n"
              + "Losses today: " + IntegerToString(dailyLossCount) + "/" + IntegerToString(MaxDailyLosses) + "\n\n"
              + "Not financial advice.";
   SendTelegram(FreeChatID, msg);
   SendTelegram(VIPChatID, msg);
}

//+------------------------------------------------------------------+
//| v1.7: Signal quality score (1-3)                                 |
//| 1 = crossover only                                               |
//| 2 = crossover + RSI in momentum sweet spot                       |
//| 3 = crossover + RSI sweet spot + trend EMA aligned               |
//+------------------------------------------------------------------+
int ScoreSignal(string direction, double rsi, double price, double trendEMA)
{
   int score = 1; // base: crossover happened

   // RSI sweet spot — momentum confirmed without being extreme
   bool rsiBuySweet  = (direction == "BUY"  && rsi >= 45 && rsi <= 62);
   bool rsiSellSweet = (direction == "SELL" && rsi >= 38 && rsi <= 55);
   if(rsiBuySweet || rsiSellSweet) score++;

   // Trend alignment — price on correct side of 50 EMA
   bool trendBuy  = (direction == "BUY"  && price > trendEMA);
   bool trendSell = (direction == "SELL" && price < trendEMA);
   if(trendBuy || trendSell) score++;

   return score;
}

// Risk multiplier per score tier
// Score 1: 60% of base (cautious)
// Score 2: 100% of base (standard)
// Score 3: 150% of base (high conviction)
double RiskMultiplier(int score)
{
   if(score == 1) return 0.60;
   if(score == 2) return 1.00;
   return 1.50;
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
   if(spread > MaxSpreadPoints) { Print("Spread too wide: ", spread, " pts — skipping"); return true; }
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

   if(handleFastEMA  == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE ||
      handleTrendEMA == INVALID_HANDLE || handleRSI     == INVALID_HANDLE ||
      handleATR      == INVALID_HANDLE || handleATR50   == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles.");
      return(INIT_FAILED);
   }

   Print("=== ZIZO SCALPER v1.7 STARTED ===");
   Print("Base Risk: ", BaseRiskPercent, "% | Score tiers: 60% / 100% / 150%");
   Print("Trend EMA: ", TrendEMA, " | TP Multiplier: ", TP_Multiplier);
   Print("Daily loss cap: ", MaxDailyLosses, " losses = stop for the day");
   Print("Consecutive loss pause: ", MaxConsecutiveLosses, " losses = pause ", PauseAfterLossMinutes, " mins");
   Print("Mode: ", isBacktesting ? "BACKTEST" : "LIVE");
   Print("Yalla yalla — Calculated Risk activated!");

   startingDayBalance = AccountInfoDouble(ACCOUNT_EQUITY);
   trade.SetExpertMagicNumber(20260510);
   trade.SetDeviationInPoints(30);

   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v1.7 ONLINE — Calculated Risk Edition*\n\n"
                            + "Symbol: " + TradingSymbol + "\n"
                            + "Base Risk: " + DoubleToString(BaseRiskPercent, 2) + "% (scales 60%/100%/150% by signal score)\n"
                            + "Trend filter: " + IntegerToString(TrendEMA) + " EMA\n"
                            + "Daily loss cap: " + IntegerToString(MaxDailyLosses) + " losses\n\n"
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

   Print("=== ZIZO SCALPER v1.7 STOPPED ===");
   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v1.7 is now OFFLINE*\n\nNo new signals until bot restarts.");
}

//+------------------------------------------------------------------+
//| Main tick                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   if(IsWeekend()) return;

   // Per-bar lock — evaluate only on a freshly closed bar
   datetime currentBarTime = iTime(TradingSymbol, PERIOD_M5, 1);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   if(todayStart != currentDay)
   {
      startingDayBalance = AccountInfoDouble(ACCOUNT_EQUITY);
      currentDay         = todayStart;
      dailyTradeCount    = 0;
      dailyLossCount     = 0;
      consecutiveLosses  = 0;
      lastTradeDirection = "";
      lastDirectionTime  = 0;
      Print("New day — Equity: $", startingDayBalance, " | All counters reset");
   }

   // Safety checks
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLossPct  = ((startingDayBalance - currentEquity) / startingDayBalance) * 100.0;
   if(dailyLossPct >= DailyLossLimit)   { Print("Daily equity limit hit — stopped for today."); return; }
   if(dailyLossCount >= MaxDailyLosses) { Print("Daily loss cap hit (", dailyLossCount, " losses) — stopped for today."); return; }
   if(dailyTradeCount >= MaxDailyTrades){ Print("Max daily trades hit."); return; }
   if(!Use24hTrading && (dt.hour < StartHour || dt.hour >= EndHour)) return;
   if(CountOpenTrades() >= MaxOpenTrades) return;
   if(IsSpreadTooWide()) return;

   // Consecutive loss streak pause
   if(consecutiveLosses >= MaxConsecutiveLosses)
   {
      int minutesSinceLoss = (int)(TimeCurrent() - lastLossTime) / 60;
      if(minutesSinceLoss < PauseAfterLossMinutes)
      {
         Print("Streak pause — ", PauseAfterLossMinutes - minutesSinceLoss, " mins left");
         return;
      }
      consecutiveLosses = 0;
      Print("Streak pause over — resuming");
   }

   if(TimeCurrent() - lastTradeTime < PeriodSeconds(PERIOD_M5) * 2) return;

   // Read confirmed closed bars (shift 1 & 2)
   double fastEMA_cur  = GetValue(handleFastEMA,  1);
   double fastEMA_prev = GetValue(handleFastEMA,  2);
   double slowEMA_cur  = GetValue(handleSlowEMA,  1);
   double slowEMA_prev = GetValue(handleSlowEMA,  2);
   double trendEMA     = GetValue(handleTrendEMA, 1);
   double rsi          = GetValue(handleRSI,      1);
   double atr          = GetValue(handleATR,      1);
   double atr50        = GetValue(handleATR50,    1);

   if(fastEMA_cur == 0 || slowEMA_cur == 0 || atr == 0 || trendEMA == 0) return;
   if(IsRangingMarket(atr)) return;

   bool isVolatile = (VolatileATR_Multi > 0 && atr50 > 0 && atr > atr50 * VolatileATR_Multi);
   double sl_multi = isVolatile ? VolatileSL_Multi : SL_Multiplier;

   double ask = SymbolInfoDouble(TradingSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradingSymbol, SYMBOL_BID);

   bool buyCooldown  = (lastTradeDirection == "BUY"  && TimeCurrent() - lastDirectionTime < PeriodSeconds(PERIOD_M5) * SameDirectionBars);
   bool sellCooldown = (lastTradeDirection == "SELL" && TimeCurrent() - lastDirectionTime < PeriodSeconds(PERIOD_M5) * SameDirectionBars);

   // Entry conditions — EMA crossover + RSI not extreme
   bool buySignal  = (fastEMA_prev <= slowEMA_prev) && (fastEMA_cur > slowEMA_cur)
                     && (rsi > RSI_Oversold) && (rsi < RSI_Overbought) && !buyCooldown;
   bool sellSignal = (fastEMA_prev >= slowEMA_prev) && (fastEMA_cur < slowEMA_cur)
                     && (rsi > RSI_Oversold) && (rsi < RSI_Overbought) && !sellCooldown;

   if(buySignal)
   {
      int    score      = ScoreSignal("BUY", rsi, ask, trendEMA);
      double riskPct    = BaseRiskPercent * RiskMultiplier(score);
      double sl_dist    = atr * sl_multi;
      double tp_dist    = atr * TP_Multiplier;
      double lotSize    = CalculateLotSize(sl_dist, riskPct);
      if(lotSize <= 0) return;

      double sl = ask - sl_dist;
      double tp = ask + tp_dist;
      Print("BUY Score:", score, " Risk:", DoubleToString(riskPct,2), "% | RSI:", DoubleToString(rsi,1),
            " | Trend:", ask > trendEMA ? "WITH" : "AGAINST", " | Volatile:", isVolatile?"YES":"NO");
      BroadcastSignal("BUY", ask, sl, tp, score);
      if(trade.Buy(lotSize, TradingSymbol, ask, sl, tp, "Zizo BUY v1.7 S" + IntegerToString(score)))
      {
         lastTradeTime = TimeCurrent(); lastTradeDirection = "BUY"; lastDirectionTime = TimeCurrent();
         dailyTradeCount++;
         Print("BUY opened | Lot:", lotSize, " Score:", score, " Daily:", dailyTradeCount,"/",MaxDailyTrades);
      }
   }
   else if(sellSignal)
   {
      int    score      = ScoreSignal("SELL", rsi, bid, trendEMA);
      double riskPct    = BaseRiskPercent * RiskMultiplier(score);
      double sl_dist    = atr * sl_multi;
      double tp_dist    = atr * TP_Multiplier;
      double lotSize    = CalculateLotSize(sl_dist, riskPct);
      if(lotSize <= 0) return;

      double sl = bid + sl_dist;
      double tp = bid - tp_dist;
      Print("SELL Score:", score, " Risk:", DoubleToString(riskPct,2), "% | RSI:", DoubleToString(rsi,1),
            " | Trend:", bid < trendEMA ? "WITH" : "AGAINST", " | Volatile:", isVolatile?"YES":"NO");
      BroadcastSignal("SELL", bid, sl, tp, score);
      if(trade.Sell(lotSize, TradingSymbol, bid, sl, tp, "Zizo SELL v1.7 S" + IntegerToString(score)))
      {
         lastTradeTime = TimeCurrent(); lastTradeDirection = "SELL"; lastDirectionTime = TimeCurrent();
         dailyTradeCount++;
         Print("SELL opened | Lot:", lotSize, " Score:", score, " Daily:", dailyTradeCount,"/",MaxDailyTrades);
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

   long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   if(symbol != TradingSymbol) return;

   long   dealType  = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   string direction = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";

   if(profit > 0)
   {
      consecutiveLosses = 0;
      Print("WIN — streak reset | Daily losses: ", dailyLossCount, "/", MaxDailyLosses);
   }
   else
   {
      consecutiveLosses++;
      dailyLossCount++;   // v1.7: tracks total losses today — never resets mid-day
      lastLossTime = TimeCurrent();
      Print("LOSS — streak:", consecutiveLosses, " | Daily losses:", dailyLossCount, "/", MaxDailyLosses);

      if(consecutiveLosses >= MaxConsecutiveLosses)
      {
         Print("Consecutive loss limit — pausing ", PauseAfterLossMinutes, " mins");
         if(!isBacktesting)
            SendTelegram(VIPChatID, "*-- ZIZO PAUSED --*\n\n"
                                  + IntegerToString(MaxConsecutiveLosses) + " consecutive losses.\n"
                                  + "Pausing " + IntegerToString(PauseAfterLossMinutes) + " minutes.\n\n"
                                  + "Not financial advice.");
      }
      if(dailyLossCount >= MaxDailyLosses)
      {
         Print("Daily loss cap reached — no more trades today");
         if(!isBacktesting)
            SendTelegram(VIPChatID, "*-- ZIZO: DAILY CAP HIT --*\n\n"
                                  + IntegerToString(MaxDailyLosses) + " losses today.\n"
                                  + "Bot stopped until tomorrow.\n\n"
                                  + "Not financial advice.");
      }
   }
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
   if(tickValue == 0 || tickSize == 0 || slDistance == 0) return minLot;
   double lotSize = riskAmount / ((slDistance / tickSize) * tickValue);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lotSize));
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

double GetValue(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return 0;
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, 0, shift, 1, val) <= 0) return 0;
   return val[0];
}
//+------------------------------------------------------------------+
