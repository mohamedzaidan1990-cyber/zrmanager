//+------------------------------------------------------------------+
//|                                              ZizoScalper_v3.0.mq5|
//|                                        Built for Mohamed @ Bayline|
//|         Hit & Run — v3.0 STRONG CANDLE MOMENTUM SYSTEM           |
//|  No more EMA crossovers. Enter ONLY on proven momentum candles.  |
//|  BUY: bullish body + uptrend | SELL: bearish body + uptrend dip  |
//+------------------------------------------------------------------+
#property copyright "Zizo Scalper v3.0"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| SETTINGS                                                          |
//+------------------------------------------------------------------+
input double BaseRiskPercent      = 2.15;   // slightly higher — fewer but higher quality trades
input double DailyLossLimit       = 3.0;
input int    MaxDailyLosses       = 2;
input int    MaxOpenTrades        = 3;
input int    MaxDailyTrades       = 5;
// Trend EMAs — no more fast/slow crossover
input int    EMA_Medium           = 21;     // momentum trend (above EMA50 = uptrend healthy)
input int    EMA_Trend            = 50;     // primary trend filter
input int    RSI_Period           = 14;
input double RSI_BuyMin           = 45.0;   // BUY: RSI not overbought
input double RSI_BuyMax           = 65.0;
input double RSI_SellMin          = 35.0;   // SELL: RSI fading from overbought
input double RSI_SellMax          = 58.0;
input int    ATR_Period           = 14;
input double SL_Multiplier        = 1.0;
input double TP_Multiplier        = 2.5;    // wider TP — fewer signals, let them run
// Candle quality filters (the core of v3.0)
input double MomentumBodyATR      = 0.35;   // body must be >= this x ATR (proves real move)
input double MomentumBodyRatio    = 0.50;   // body must be >= this fraction of total bar range
input double VolatileSL_Multi     = 1.4;
input double VolatileATR_Multi    = 2.0;
input int    RangeLookback        = 10;
input double RangeATR_Multi       = 1.5;
input int    MaxConsecutiveLosses = 2;
input int    PauseAfterLossMinutes= 60;
input int    SameDirectionBars    = 3;      // tighter cooldown — momentum signals are precise
input bool   Use24hTrading        = true;
input int    StartHour            = 0;
input int    EndHour              = 23;
input string TradingSymbol        = "XAUUSD";
input double MaxSpreadPoints      = 50;
input string TelegramBotToken     = "8360184972:AAEPatjOcGWi_esCUNowrN1900U8yXrNQVc";
input string FreeChatID           = "-1003507395391";
input string VIPChatID            = "-1003723825502";
input bool   SendTelegramSignals  = true;

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

int handleEMA21  = INVALID_HANDLE;
int handleEMA50  = INVALID_HANDLE;
int handleRSI    = INVALID_HANDLE;
int handleATR    = INVALID_HANDLE;
int handleATR50  = INVALID_HANDLE;

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

void BroadcastSignal(string direction, double entry, double sl, double tp,
                     double bodyRatio, double bodyATR)
{
   if(isBacktesting) return;
   double rr    = MathAbs(tp - entry) / MathAbs(sl - entry);
   string arrow = (direction == "SELL") ? "[ SELL ]" : "[ BUY ]";
   string type  = (direction == "BUY") ? "Trend Continuation" : "Bearish Reversal";
   string freeMsg = "*-- GOLD SIGNAL ALERT --*\n\nInstrument: *" + TradingSymbol + "*\nDirection: *" + arrow + "*\n\nFull entry, SL and TP in VIP channel.\nSubscribe: t.me/GoldAlertsVIPBot\n\nNot financial advice.";
   string vipMsg  = "*-- GOLD ALERTS VIP --*\n\n"
                  + "Instrument:  *" + TradingSymbol + "*\n"
                  + "Direction:   *" + arrow + "*\n"
                  + "Type:        *" + type + "*\n"
                  + "Entry:       *" + DoubleToString(entry,2) + "*\n"
                  + "Stop Loss:   *" + DoubleToString(sl,2) + "*\n"
                  + "Take Profit: *" + DoubleToString(tp,2) + "*\n"
                  + "R/R Ratio:   *1:" + DoubleToString(rr,1) + "*\n"
                  + "Body/ATR:    *" + DoubleToString(bodyATR,2) + "x*\n"
                  + "Body/Range:  *" + DoubleToString(bodyRatio*100,0) + "%*\n\n"
                  + "Momentum candle confirmed.\n\nNot financial advice.";
   SendTelegram(FreeChatID, freeMsg);
   SendTelegram(VIPChatID, vipMsg);
}

void BroadcastResult(string direction, double profit)
{
   if(isBacktesting) return;
   string label     = (profit > 0) ? "WIN" : (profit == 0 ? "BREAKEVEN" : "LOSS");
   string profitStr = (profit > 0 ? "+" : "") + DoubleToString(profit, 2);
   string msg = "*-- TRADE CLOSED: " + label + " --*\n\n"
              + "Instrument: *" + TradingSymbol + "*\n"
              + "Direction:  *" + direction + "*\n"
              + "Result:     *$" + profitStr + "*\n\n"
              + "Trades today: " + IntegerToString(dailyTradeCount) + "/" + IntegerToString(MaxDailyTrades) + "\n"
              + "Losses today: " + IntegerToString(dailyLossCount)  + "/" + IntegerToString(MaxDailyLosses) + "\n\n"
              + "Not financial advice.";
   SendTelegram(FreeChatID, msg);
   SendTelegram(VIPChatID, msg);
}

//+------------------------------------------------------------------+
//| Core: is bar a strong momentum candle?                            |
//+------------------------------------------------------------------+
bool IsStrongBullCandle(double open, double close, double high, double low, double atr,
                        double &bodyRatioOut, double &bodyATROut)
{
   if(close <= open) return false;                      // must close up
   double body  = close - open;
   double range = high - low;
   if(range <= 0) return false;
   bodyRatioOut = body / range;
   bodyATROut   = body / atr;
   return (body >= atr * MomentumBodyATR) && (bodyRatioOut >= MomentumBodyRatio);
}

bool IsStrongBearCandle(double open, double close, double high, double low, double atr,
                        double &bodyRatioOut, double &bodyATROut)
{
   if(close >= open) return false;                      // must close down
   double body  = open - close;
   double range = high - low;
   if(range <= 0) return false;
   bodyRatioOut = body / range;
   bodyATROut   = body / atr;
   return (body >= atr * MomentumBodyATR) && (bodyRatioOut >= MomentumBodyRatio);
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

   handleEMA21  = iMA(TradingSymbol, PERIOD_M5, EMA_Medium, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA50  = iMA(TradingSymbol, PERIOD_M5, EMA_Trend,  0, MODE_EMA, PRICE_CLOSE);
   handleRSI    = iRSI(TradingSymbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   handleATR    = iATR(TradingSymbol, PERIOD_M5, ATR_Period);
   handleATR50  = iATR(TradingSymbol, PERIOD_M5, 50);

   if(handleEMA21==INVALID_HANDLE || handleEMA50==INVALID_HANDLE ||
      handleRSI==INVALID_HANDLE   || handleATR==INVALID_HANDLE || handleATR50==INVALID_HANDLE)
   { Print("ERROR: Failed to create handles."); return(INIT_FAILED); }

   Print("=== ZIZO SCALPER v3.0 STARTED — Strong Candle System ===");
   Print("Entry: body >= ", MomentumBodyATR, "x ATR AND body >= ", MomentumBodyRatio*100, "% of range");
   Print("BUY: uptrend (EMA21>EMA50) + bullish candle | SELL: bearish candle in uptrend");
   Print("TP: ", TP_Multiplier, "x ATR | SL: ", SL_Multiplier, "x ATR | Risk: ", BaseRiskPercent, "%");

   startingDayBalance = AccountInfoDouble(ACCOUNT_EQUITY);
   trade.SetExpertMagicNumber(20260510);
   trade.SetDeviationInPoints(30);

   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v3.0 ONLINE — Strong Candle System*\n\n"
                            + "Entry: momentum candle confirmation\n"
                            + "Body >= " + DoubleToString(MomentumBodyATR,2) + "x ATR\n"
                            + "Body >= " + DoubleToString(MomentumBodyRatio*100,0) + "% of bar range\n"
                            + "TP: " + DoubleToString(TP_Multiplier,1) + "x ATR\n"
                            + "Daily loss cap: " + IntegerToString(MaxDailyLosses) + "\n\n"
                            + "Yalla yalla — Hit and Run v3 activated!");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleEMA21  != INVALID_HANDLE) { IndicatorRelease(handleEMA21);  handleEMA21  = INVALID_HANDLE; }
   if(handleEMA50  != INVALID_HANDLE) { IndicatorRelease(handleEMA50);  handleEMA50  = INVALID_HANDLE; }
   if(handleRSI    != INVALID_HANDLE) { IndicatorRelease(handleRSI);    handleRSI    = INVALID_HANDLE; }
   if(handleATR    != INVALID_HANDLE) { IndicatorRelease(handleATR);    handleATR    = INVALID_HANDLE; }
   if(handleATR50  != INVALID_HANDLE) { IndicatorRelease(handleATR50);  handleATR50  = INVALID_HANDLE; }
   Print("=== ZIZO SCALPER v3.0 STOPPED ===");
   if(!isBacktesting)
      SendTelegram(VIPChatID, "*Zizo Scalper v3.0 OFFLINE*\n\nNo signals until restart.");
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

   // --- Read confirmed bar (shift=1) ---
   double barOpen  = iOpen (TradingSymbol, PERIOD_M5, 1);
   double barClose = iClose(TradingSymbol, PERIOD_M5, 1);
   double barHigh  = iHigh (TradingSymbol, PERIOD_M5, 1);
   double barLow   = iLow  (TradingSymbol, PERIOD_M5, 1);

   double ema21 = GetValue(handleEMA21, 1);
   double ema50 = GetValue(handleEMA50, 1);
   double rsi   = GetValue(handleRSI,   1);
   double atr   = GetValue(handleATR,   1);
   double atr50 = GetValue(handleATR50, 1);

   if(ema21==0 || ema50==0 || atr==0) return;
   if(IsRangingMarket(atr)) return;

   bool isVolatile = (VolatileATR_Multi > 0 && atr50 > 0 && atr > atr50 * VolatileATR_Multi);
   double sl_multi = isVolatile ? VolatileSL_Multi : SL_Multiplier;

   double ask = SymbolInfoDouble(TradingSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradingSymbol, SYMBOL_BID);

   bool buyCooldown  = (lastTradeDirection=="BUY"  && TimeCurrent()-lastDirectionTime < PeriodSeconds(PERIOD_M5)*SameDirectionBars);
   bool sellCooldown = (lastTradeDirection=="SELL" && TimeCurrent()-lastDirectionTime < PeriodSeconds(PERIOD_M5)*SameDirectionBars);

   // --- Candle quality check ---
   double bodyRatio = 0, bodyATRmult = 0;
   bool strongBull = IsStrongBullCandle(barOpen, barClose, barHigh, barLow, atr, bodyRatio, bodyATRmult);
   bool strongBear = IsStrongBearCandle(barOpen, barClose, barHigh, barLow, atr, bodyRatio, bodyATRmult);

   // --- Trend context ---
   bool uptrendHealthy  = (barClose > ema50) && (ema21 > ema50); // BUY: confirmed uptrend
   bool uptrendContext  = (barClose > ema50);                     // SELL: price in uptrend zone

   // --- RSI ---
   bool rsiBuyOk  = (rsi >= RSI_BuyMin  && rsi <= RSI_BuyMax);
   bool rsiSellOk = (rsi >= RSI_SellMin && rsi <= RSI_SellMax);

   // --- Final signals ---
   // BUY: strong bullish candle + healthy uptrend + RSI not overbought
   bool buySignal  = strongBull && uptrendHealthy && rsiBuyOk  && !buyCooldown;
   // SELL: strong bearish candle + still in uptrend zone + RSI fading
   bool sellSignal = strongBear && uptrendContext  && rsiSellOk && !sellCooldown;

   if(buySignal)
   {
      double sl_dist = atr * sl_multi;
      double tp_dist = atr * TP_Multiplier;
      double lotSize = CalculateLotSize(sl_dist, BaseRiskPercent);
      if(lotSize <= 0) return;
      double sl = ask - sl_dist;
      double tp = ask + tp_dist;
      Print("BUY body:", DoubleToString(bodyATRmult,2), "xATR ", DoubleToString(bodyRatio*100,0), "% RSI:", DoubleToString(rsi,1));
      BroadcastSignal("BUY", ask, sl, tp, bodyRatio, bodyATRmult);
      if(trade.Buy(lotSize, TradingSymbol, ask, sl, tp, "Zizo BUY v3.0"))
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
      double lotSize = CalculateLotSize(sl_dist, BaseRiskPercent);
      if(lotSize <= 0) return;
      double sl = bid + sl_dist;
      double tp = bid - tp_dist;
      Print("SELL body:", DoubleToString(bodyATRmult,2), "xATR ", DoubleToString(bodyRatio*100,0), "% RSI:", DoubleToString(rsi,1));
      BroadcastSignal("SELL", bid, sl, tp, bodyRatio, bodyATRmult);
      if(trade.Sell(lotSize, TradingSymbol, bid, sl, tp, "Zizo SELL v3.0"))
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
