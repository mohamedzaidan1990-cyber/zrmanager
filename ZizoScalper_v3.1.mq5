//+------------------------------------------------------------------+
//|                                              ZizoScalper_v3.1.mq5|
//|                                        Built for Mohamed @ Bayline|
//|         Hit & Run — v3.1 QUALITY CROSSOVER SYSTEM                |
//|  v2.4 EMA crossover + candle body filter on the crossover bar    |
//|  Only take crossovers that happen on REAL directional candles     |
//+------------------------------------------------------------------+
#property copyright "Zizo Scalper v3.1"
#property version   "3.10"
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
// Crossover candle quality — the bar that CAUSED the EMA cross must prove commitment
// Too strict = too few trades | Too loose = same as v2.4
input double CrossBodyRatio        = 0.40;  // body >= 40% of (high-low) — filters doji/spinning top
input double CrossBodyATR          = 0.20;  // body >= 20% of ATR — minimum meaningful move
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

void BroadcastSignal(string direction, double entry, double sl, double tp, int score)
{
   if(isBacktesting) return;
   double rr    = MathAbs(tp - entry) / MathAbs(sl - entry);
   string arrow = (direction == "SELL") ? "[ SELL ]" : "[ BUY ]";
   string grade = (score == 3) ? "PREMIUM" : "QUALITY";
   string freeMsg = "*-- GOLD SIGNAL ALERT --*\n\nInstrument: *" + TradingSymbol + "*\nDirection: *" + arrow + "*\n\nFull entry, SL and TP in VIP channel.\nSubscribe: t.me/GoldAlertsVIPBot\n\nNot financial advice.";
   string vipMsg  = "*-- GOLD ALERTS VIP SIGNAL --*\n\nInstrument:  *" + TradingSymbol + "*\nDirection:   *" + arrow + "*\nEntry:       *" + DoubleToString(entry,2) + "*\nStop Loss:   *" + DoubleToString(sl,2) + "*\nTake Profit: *" + DoubleToString(tp,2) + "*\nR/R Ratio:   *1:" + DoubleToString(rr,1) + "*\nGrade: *" + grade + "* (" + IntegerToString(score) + "/3)\n\nQuality crossover confirmed.\n\nNot financial advice.";
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
//| Scoring (same as v2.4)                                           |
//+------------------------------------------------------------------+
int ScoreSignal(string direction, double price, double trendEMA)
{
   bool aligned = (direction == "BUY" && price > trendEMA) ||
                  (direction == "SELL" && price < trendEMA);
   return aligned ? 3 : 2;
}

double RiskMultiplier(int score) { return (score == 3) ? 1.30 : 1.00; }

//+------------------------------------------------------------------+
//| Candle body quality check                                        |
//+------------------------------------------------------------------+
bool HasQualityBody(double open, double close, double high, double low, double atr)
{
   double body  = MathAbs(close - open);
   double range = high - low;
   if(range <= 0 || atr <= 0) return false;
   return (body / range >= CrossBodyRatio) && (body >= atr * CrossBodyATR);
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

   Print("=== ZIZO SCALPER v3.1 STARTED — Quality Crossover System ===");
   Print("EMA cross filter: body >= ", CrossBodyRatio*100, "% of range AND >= ", CrossBodyATR, "x ATR");
   Print("BUY: cross up + price > EMA50 | SELL: cross down + price > EMA50 (counter-trend)");
   Print("TP: ", TP_Multiplier, "x ATR | SL: ", SL_Multiplier, "x ATR");
   Print("Daily loss cap: ", MaxDailyLosses, " | Mode: ", isBacktesting ? "BACKTEST" : "LIVE");

   startingDayBalance = AccountInfoDouble(ACCOUNT_EQUITY);
   trade.SetExpertMagicNumber(20260510);
   trade.SetDeviationInPoints(30);

   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v3.1 ONLINE — Quality Crossover*\n\n"
                            + "EMA cross only on real candles:\n"
                            + "Body >= " + DoubleToString(CrossBodyRatio*100,0) + "% of range\n"
                            + "Body >= " + DoubleToString(CrossBodyATR,2) + "x ATR\n"
                            + "TP: " + DoubleToString(TP_Multiplier,1) + "x ATR\n"
                            + "Daily loss cap: " + IntegerToString(MaxDailyLosses) + "\n\n"
                            + "Yalla yalla — Hit and Run v3.1 activated!");
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
   Print("=== ZIZO SCALPER v3.1 STOPPED ===");
   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v3.1 OFFLINE*\n\nNo signals until restart.");
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
   if(dailyLossPct >= DailyLossLimit)    { Print("Daily equity limit hit."); return; }
   if(dailyLossCount >= MaxDailyLosses)  { Print("Daily loss cap — stopped today."); return; }
   if(dailyTradeCount >= MaxDailyTrades) { Print("Max daily trades hit."); return; }
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

   // --- Indicator values ---
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

   // --- Crossover bar data ---
   double barOpen  = iOpen (TradingSymbol, PERIOD_M5, 1);
   double barClose = iClose(TradingSymbol, PERIOD_M5, 1);
   double barHigh  = iHigh (TradingSymbol, PERIOD_M5, 1);
   double barLow   = iLow  (TradingSymbol, PERIOD_M5, 1);

   double ask = SymbolInfoDouble(TradingSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradingSymbol, SYMBOL_BID);

   bool buyCooldown  = (lastTradeDirection=="BUY"  && TimeCurrent()-lastDirectionTime < PeriodSeconds(PERIOD_M5)*SameDirectionBars);
   bool sellCooldown = (lastTradeDirection=="SELL" && TimeCurrent()-lastDirectionTime < PeriodSeconds(PERIOD_M5)*SameDirectionBars);

   // --- EMA crossover ---
   bool emaBuyCross  = (fastEMA_prev <= slowEMA_prev) && (fastEMA_cur > slowEMA_cur);
   bool emaSellCross = (fastEMA_prev >= slowEMA_prev) && (fastEMA_cur < slowEMA_cur);

   // --- RSI zones ---
   bool rsiBuyOk  = (rsi >= RSI_BuyMin  && rsi <= RSI_BuyMax);
   bool rsiSellOk = (rsi >= RSI_SellMin && rsi <= RSI_SellMax);

   // --- Trend context (v2.4 proven logic) ---
   bool trendAlignedBuy = (ask > trendEMA);   // BUY only in uptrend

   // --- Candle body quality on the crossover bar ---
   bool bullishBody = (barClose > barOpen) && HasQualityBody(barOpen, barClose, barHigh, barLow, atr);
   bool bearishBody = (barClose < barOpen) && HasQualityBody(barOpen, barClose, barHigh, barLow, atr);

   // --- Final signals ---
   // BUY: crossover happened + crossover bar was bullish with real body + trend aligned + RSI ok
   bool buySignal  = emaBuyCross  && bullishBody && trendAlignedBuy && rsiBuyOk  && !buyCooldown;
   // SELL: crossover happened + crossover bar was bearish with real body + price still in uptrend + RSI ok
   bool sellSignal = emaSellCross && bearishBody && (bid > trendEMA) && rsiSellOk && !sellCooldown;

   if(buySignal)
   {
      int    score   = ScoreSignal("BUY", ask, trendEMA); // always 3 (price > EMA50)
      double riskPct = BaseRiskPercent * RiskMultiplier(score);
      double sl_dist = atr * sl_multi;
      double tp_dist = atr * TP_Multiplier;
      double lotSize = CalculateLotSize(sl_dist, riskPct);
      if(lotSize <= 0) return;
      double sl = ask - sl_dist;
      double tp = ask + tp_dist;
      Print("BUY xover+body S:", score, " body:", DoubleToString(MathAbs(barClose-barOpen)/atr,2), "xATR RSI:", DoubleToString(rsi,1));
      BroadcastSignal("BUY", ask, sl, tp, score);
      if(trade.Buy(lotSize, TradingSymbol, ask, sl, tp, "Zizo BUY v3.1 S"+IntegerToString(score)))
      {
         lastTradeTime=TimeCurrent(); lastTradeDirection="BUY"; lastDirectionTime=TimeCurrent();
         dailyTradeCount++;
         Print("BUY opened Lot:", lotSize, " Daily:", dailyTradeCount, "/", MaxDailyTrades);
      }
   }
   else if(sellSignal)
   {
      int    score   = ScoreSignal("SELL", bid, trendEMA);
      double riskPct = BaseRiskPercent * RiskMultiplier(score);
      double sl_dist = atr * sl_multi;
      double tp_dist = atr * TP_Multiplier;
      double lotSize = CalculateLotSize(sl_dist, riskPct);
      if(lotSize <= 0) return;
      double sl = bid + sl_dist;
      double tp = bid - tp_dist;
      Print("SELL xover+body S:", score, " body:", DoubleToString(MathAbs(barClose-barOpen)/atr,2), "xATR RSI:", DoubleToString(rsi,1));
      BroadcastSignal("SELL", bid, sl, tp, score);
      if(trade.Sell(lotSize, TradingSymbol, bid, sl, tp, "Zizo SELL v3.1 S"+IntegerToString(score)))
      {
         lastTradeTime=TimeCurrent(); lastTradeDirection="SELL"; lastDirectionTime=TimeCurrent();
         dailyTradeCount++;
         Print("SELL opened Lot:", lotSize, " S:", score, " Daily:", dailyTradeCount, "/", MaxDailyTrades);
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
