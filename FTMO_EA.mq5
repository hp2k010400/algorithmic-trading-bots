//+------------------------------------------------------------------+
//|                   FTMO_NAS_V4_BreakoutRetest_EA.mq5             |
//|               Aggressive Breakout + Retest EA (NAS100)          |
//+------------------------------------------------------------------+
#property strict
#property version   "4.00"
#property description "Aggressive breakout retest EA for NAS100 / US100 on M5"
#property description "Designed for higher opportunity and FTMO-style growth"

input group "=== SESSION / RANGE (SERVER TIME) ==="
input int    InpRangeStartHour        = 14;
input int    InpRangeStartMinute      = 30;
input int    InpRangeEndHour          = 15;
input int    InpRangeEndMinute        = 0;
input int    InpTradeEndHour          = 20;
input int    InpTradeEndMinute        = 0;
input bool   InpCloseAtSessionEnd     = false;

input group "=== BREAKOUT / RETEST RULES ==="
input double InpBreakoutBufferPoints  = 20.0;   // smaller = more setups
input double InpRetestTolerancePoints = 80.0;   // how close price can come back to breakout level
input int    InpMaxBarsAfterBreakout  = 8;      // retest must happen within this many bars
input double InpMinBodyPct            = 20.0;   // reclaim candle quality
input bool   InpRequirePrevBreak      = false;  // aggressive mode defaults false
input int    InpMaxTradesPerDay       = 2;
input int    InpCooldownBars          = 0;

input group "=== STOP / TARGET ==="
input int    InpATRPeriod             = 14;
input double InpStopATRMultiplier     = 0.8;
input double InpRRRatio               = 2.5;
input double InpMaxSLPoints           = 5000.0;
input double InpMinRangePoints        = 80.0;   // allow more days
input double InpMaxRangePoints        = 3000.0;

input group "=== OPTIONAL TREND FILTER ==="
input bool   InpUseTrendFilter        = false;
input int    InpTrendFastEMA          = 20;
input int    InpTrendSlowEMA          = 50;
input ENUM_TIMEFRAMES InpTrendTF      = PERIOD_M15;

input group "=== RISK ==="
input double InpRiskPct               = 1.0;
input double InpStartBalanceOverride  = 0.0;
input double InpMaxDailyLossPct       = 2.5;
input double InpMaxTotalLossPct       = 8.0;
input double InpProfitTargetPct       = 10.0;
input bool   InpPermanentHalt         = false;

input group "=== EXECUTION ==="
input int    InpMagic                 = 20250420;
input int    InpSlippage              = 20;

enum RetestState
{
   RS_IDLE = 0,
   RS_WAIT_RETEST,
   RS_WAIT_CONFIRM
};

int      g_atrHandle = INVALID_HANDLE;
int      g_trendFastHandle = INVALID_HANDLE;
int      g_trendSlowHandle = INVALID_HANDLE;

double   g_startBalance = 0.0;
double   g_dayStartBalance = 0.0;
double   g_dayStartEquity = 0.0;
datetime g_lastDayTime = 0;
datetime g_lastBarTime = 0;

bool     g_haltedToday = false;
bool     g_permanentHalt = false;
int      g_tradesToday = 0;
int      g_cooldownBarsLeft = 0;

bool     g_rangeBuilt = false;
bool     g_rangeLocked = false;
double   g_rangeHigh = 0.0;
double   g_rangeLow = 0.0;

RetestState g_state = RS_IDLE;
int      g_direction = 0;         // 1 = bullish breakout, -1 = bearish breakout
int      g_barsSinceBreakout = 0;
double   g_breakLevel = 0.0;
double   g_retestExtreme = 0.0;

// diagnostics
int g_cntDaysProcessed = 0;
int g_cntRangesBuilt = 0;
int g_cntRangeRejectedSize = 0;
int g_cntBreakoutsLong = 0;
int g_cntBreakoutsShort = 0;
int g_cntRetestsLong = 0;
int g_cntRetestsShort = 0;
int g_cntConfirmsLong = 0;
int g_cntConfirmsShort = 0;
int g_cntExpired = 0;
int g_cntTradesOpened = 0;
int g_cntRejectedSLTooWide = 0;
int g_cntRejectedLotSize = 0;
int g_cntRejectedDailyCap = 0;
int g_cntRejectedDrawdown = 0;

int OnInit()
{
   g_atrHandle = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Alert("Failed to create ATR handle");
      return INIT_FAILED;
   }

   if(InpUseTrendFilter)
   {
      g_trendFastHandle = iMA(_Symbol, InpTrendTF, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_trendSlowHandle = iMA(_Symbol, InpTrendTF, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_trendFastHandle == INVALID_HANDLE || g_trendSlowHandle == INVALID_HANDLE)
      {
         Alert("Failed to create trend EMA handles");
         return INIT_FAILED;
      }
   }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_startBalance = (InpStartBalanceOverride > 0.0) ? InpStartBalanceOverride : bal;
   g_dayStartBalance = bal;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDayTime = TimeCurrent();
   g_lastBarTime = 0;
   g_haltedToday = false;
   g_permanentHalt = false;
   g_tradesToday = 0;
   g_cooldownBarsLeft = 0;
   ResetRangeState();

   PrintFormat("V4 Breakout Retest EA initialized | %s | Risk %.2f%% | RR 1:%.2f",
               _Symbol, InpRiskPct, InpRRRatio);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_trendFastHandle != INVALID_HANDLE) IndicatorRelease(g_trendFastHandle);
   if(g_trendSlowHandle != INVALID_HANDLE) IndicatorRelease(g_trendSlowHandle);
   PrintDiagnostics();
}

void OnTick()
{
   ResetDailyTracking();
   if(g_permanentHalt) return;
   if(!CheckRiskLimits()) return;

   HandleSessionClose();

   datetime curBar = iTime(_Symbol, PERIOD_M5, 0);
   if(curBar == 0 || curBar == g_lastBarTime) return;
   g_lastBarTime = curBar;

   if(g_cooldownBarsLeft > 0)
      g_cooldownBarsLeft--;

   UpdateRange();
   if(!g_rangeBuilt || !g_rangeLocked) return;
   if(!IsTradeWindow()) return;
   if(HasOpenPosition()) return;
   if(g_haltedToday) return;

   if(g_tradesToday >= InpMaxTradesPerDay)
   {
      g_cntRejectedDailyCap++;
      return;
   }

   ProcessRetestStateMachine();
}

void ResetRangeState()
{
   g_rangeBuilt = false;
   g_rangeLocked = false;
   g_rangeHigh = 0.0;
   g_rangeLow = 0.0;
   g_state = RS_IDLE;
   g_direction = 0;
   g_barsSinceBreakout = 0;
   g_breakLevel = 0.0;
   g_retestExtreme = 0.0;
}

void ResetDailyTracking()
{
   MqlDateTime today, last;
   TimeToStruct(TimeCurrent(), today);
   TimeToStruct(g_lastDayTime, last);

   if(today.year != last.year || today.mon != last.mon || today.day != last.day)
   {
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_haltedToday = false;
      g_tradesToday = 0;
      g_lastDayTime = TimeCurrent();
      g_cntDaysProcessed++;
      ResetRangeState();
   }
}

int MinutesNow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour * 60 + dt.min;
}

int RangeStartMinutes() { return InpRangeStartHour * 60 + InpRangeStartMinute; }
int RangeEndMinutes()   { return InpRangeEndHour   * 60 + InpRangeEndMinute; }
int TradeEndMinutes()   { return InpTradeEndHour   * 60 + InpTradeEndMinute; }

bool IsTradeWindow()
{
   int now = MinutesNow();
   return (now >= RangeEndMinutes() && now < TradeEndMinutes());
}

void UpdateRange()
{
   int now = MinutesNow();
   int start = RangeStartMinutes();
   int end = RangeEndMinutes();

   if(now < start) return;

   if(now >= start && now < end)
   {
      double high1[1], low1[1];
      ArraySetAsSeries(high1, true);
      ArraySetAsSeries(low1, true);
      if(CopyHigh(_Symbol, PERIOD_M5, 1, 1, high1) < 1) return;
      if(CopyLow(_Symbol, PERIOD_M5, 1, 1, low1) < 1) return;

      if(!g_rangeBuilt)
      {
         g_rangeHigh = high1[0];
         g_rangeLow = low1[0];
         g_rangeBuilt = true;
      }
      else
      {
         if(high1[0] > g_rangeHigh) g_rangeHigh = high1[0];
         if(low1[0]  < g_rangeLow)  g_rangeLow = low1[0];
      }
      return;
   }

   if(now >= end && g_rangeBuilt && !g_rangeLocked)
   {
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double rangePts = (g_rangeHigh - g_rangeLow) / point;
      g_rangeLocked = true;
      if(rangePts < InpMinRangePoints || rangePts > InpMaxRangePoints)
         g_cntRangeRejectedSize++;
      g_cntRangesBuilt++;
   }
}

void HandleSessionClose()
{
   if(!InpCloseAtSessionEnd) return;
   if(MinutesNow() >= TradeEndMinutes() && HasOpenPosition())
      CloseAll();
}

double GetATRValue()
{
   double atr[1];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) < 1)
      return 0.0;
   return atr[0];
}

bool TrendAllowsLong()
{
   if(!InpUseTrendFilter) return true;
   double fast[1], slow[1];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(CopyBuffer(g_trendFastHandle, 0, 1, 1, fast) < 1) return false;
   if(CopyBuffer(g_trendSlowHandle, 0, 1, 1, slow) < 1) return false;
   return (fast[0] > slow[0]);
}

bool TrendAllowsShort()
{
   if(!InpUseTrendFilter) return true;
   double fast[1], slow[1];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(CopyBuffer(g_trendFastHandle, 0, 1, 1, fast) < 1) return false;
   if(CopyBuffer(g_trendSlowHandle, 0, 1, 1, slow) < 1) return false;
   return (fast[0] < slow[0]);
}

void ProcessRetestStateMachine()
{
   double open2[2], close2[2], high2[2], low2[2];
   ArraySetAsSeries(open2, true);
   ArraySetAsSeries(close2, true);
   ArraySetAsSeries(high2, true);
   ArraySetAsSeries(low2, true);

   if(CopyOpen(_Symbol, PERIOD_M5, 1, 2, open2) < 2) return;
   if(CopyClose(_Symbol, PERIOD_M5, 1, 2, close2) < 2) return;
   if(CopyHigh(_Symbol, PERIOD_M5, 1, 2, high2) < 2) return;
   if(CopyLow(_Symbol, PERIOD_M5, 1, 2, low2) < 2) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double breakBuf = InpBreakoutBufferPoints * point;
   double retestTol = InpRetestTolerancePoints * point;

   double o = open2[0];
   double c = close2[0];
   double h = high2[0];
   double l = low2[0];
   double prevHigh = high2[1];
   double prevLow = low2[1];
   double candleRange = h - l;
   if(candleRange <= 0.0) return;
   double bodyPct = MathAbs(c - o) / candleRange * 100.0;

   double rangePts = (g_rangeHigh - g_rangeLow) / point;
   if(rangePts < InpMinRangePoints || rangePts > InpMaxRangePoints)
      return;

   if(g_state == RS_IDLE)
   {
      if(TrendAllowsLong())
      {
         bool longBreak = (c > g_rangeHigh + breakBuf);
         if(longBreak)
         {
            g_state = RS_WAIT_RETEST;
            g_direction = 1;
            g_barsSinceBreakout = 0;
            g_breakLevel = g_rangeHigh;
            g_retestExtreme = 0.0;
            g_cntBreakoutsLong++;
            return;
         }
      }

      if(TrendAllowsShort())
      {
         bool shortBreak = (c < g_rangeLow - breakBuf);
         if(shortBreak)
         {
            g_state = RS_WAIT_RETEST;
            g_direction = -1;
            g_barsSinceBreakout = 0;
            g_breakLevel = g_rangeLow;
            g_retestExtreme = 0.0;
            g_cntBreakoutsShort++;
            return;
         }
      }
      return;
   }

   if(g_state == RS_WAIT_RETEST)
   {
      g_barsSinceBreakout++;
      if(g_barsSinceBreakout > InpMaxBarsAfterBreakout)
      {
         g_cntExpired++;
         g_state = RS_IDLE;
         g_direction = 0;
         return;
      }

      if(g_direction == 1)
      {
         bool retested = (l <= g_breakLevel + retestTol);
         if(retested)
         {
            g_retestExtreme = l;
            bool bullish = (c > o);
            bool backAboveLevel = (c > g_breakLevel);
            bool brokePrev = InpRequirePrevBreak ? (c > prevHigh) : true;
            bool bodyOK = (bodyPct >= InpMinBodyPct);
            if(bodyOK && bullish && backAboveLevel && brokePrev)
            {
               g_cntRetestsLong++;
               ExecuteTrade(1, h, l);
               g_state = RS_IDLE;
               g_direction = 0;
               return;
            }
         }
      }
      else if(g_direction == -1)
      {
         bool retested = (h >= g_breakLevel - retestTol);
         if(retested)
         {
            g_retestExtreme = h;
            bool bearish = (c < o);
            bool backBelowLevel = (c < g_breakLevel);
            bool brokePrev = InpRequirePrevBreak ? (c < prevLow) : true;
            bool bodyOK = (bodyPct >= InpMinBodyPct);
            if(bodyOK && bearish && backBelowLevel && brokePrev)
            {
               g_cntRetestsShort++;
               ExecuteTrade(-1, h, l);
               g_state = RS_IDLE;
               g_direction = 0;
               return;
            }
         }
      }
   }
}

double CalcLots(double entryPrice, double slPrice)
{
   double slDist = MathAbs(entryPrice - slPrice);
   if(slDist <= 0.0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCash = balance * InpRiskPct / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickVal <= 0.0 || tickSize <= 0.0 || lotStep <= 0.0)
      return 0.0;

   double rawLot = riskCash / (slDist / tickSize * tickVal);
   if(rawLot < minLot) return 0.0;

   double lot = MathFloor(rawLot / lotStep) * lotStep;
   if(lot < minLot) return 0.0;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

bool ExecuteTrade(int direction, double signalHigh, double signalLow)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double entry = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = GetATRValue();
   if(atr <= 0.0) return false;

   double sl = 0.0;
   if(direction == 1)
   {
      double baseLow = (g_retestExtreme > 0.0) ? g_retestExtreme : signalLow;
      sl = baseLow - (atr * InpStopATRMultiplier);
   }
   else
   {
      double baseHigh = (g_retestExtreme > 0.0) ? g_retestExtreme : signalHigh;
      sl = baseHigh + (atr * InpStopATRMultiplier);
   }

   double slPts = MathAbs(entry - sl) / point;
   if(slPts > InpMaxSLPoints)
   {
      g_cntRejectedSLTooWide++;
      return false;
   }

   double tp = (direction == 1)
               ? entry + (MathAbs(entry - sl) * InpRRRatio)
               : entry - (MathAbs(entry - sl) * InpRRRatio);

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double lots = CalcLots(entry, sl);
   if(lots <= 0.0)
   {
      g_cntRejectedLotSize++;
      return false;
   }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.magic        = InpMagic;
   req.volume       = lots;
   req.type         = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price        = entry;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = InpSlippage;
   req.comment      = "V4BreakoutRetest";
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
   {
      PrintFormat("OrderSend failed | err=%d retcode=%d", GetLastError(), res.retcode);
      return false;
   }

   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
   {
      g_cntTradesOpened++;
      g_tradesToday++;
      if(InpCooldownBars > 0)
         g_cooldownBarsLeft = InpCooldownBars;
      return true;
   }

   return false;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      return true;
   }
   return false;
}

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.position     = tk;
      req.magic        = InpMagic;
      req.volume       = PositionGetDouble(POSITION_VOLUME);
      req.deviation    = InpSlippage;
      req.type_filling = ORDER_FILLING_IOC;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY)
      {
         req.type = ORDER_TYPE_SELL;
         req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      }
      else
      {
         req.type = ORDER_TYPE_BUY;
         req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }

      OrderSend(req, res);
   }
}

bool CheckRiskLimits()
{
   if(g_startBalance <= 0.0) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   double totalProfitPct = (balance - g_startBalance) / g_startBalance * 100.0;
   double totalDrawPct = (g_startBalance - equity) / g_startBalance * 100.0;
   double dailyDrawPct = 0.0;
   if(g_dayStartBalance > 0.0)
      dailyDrawPct = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;

   if(InpProfitTargetPct > 0.0 && totalProfitPct >= InpProfitTargetPct)
   {
      CloseAll();
      if(InpPermanentHalt) g_permanentHalt = true;
      g_cntRejectedDrawdown++;
      return false;
   }

   if(totalDrawPct >= InpMaxTotalLossPct)
   {
      CloseAll();
      if(InpPermanentHalt) g_permanentHalt = true;
      g_cntRejectedDrawdown++;
      return false;
   }

   if(dailyDrawPct >= InpMaxDailyLossPct)
   {
      if(!g_haltedToday)
      {
         CloseAll();
         g_haltedToday = true;
      }
      g_cntRejectedDrawdown++;
      return false;
   }

   return true;
}

void PrintDiagnostics()
{
   Print("================ V4 BREAKOUT RETEST DIAGNOSTICS ================");
   PrintFormat("Days processed:              %d", g_cntDaysProcessed);
   PrintFormat("Ranges built:                %d", g_cntRangesBuilt);
   PrintFormat("Ranges rejected by size:     %d", g_cntRangeRejectedSize);
   PrintFormat("Long breakouts:              %d", g_cntBreakoutsLong);
   PrintFormat("Short breakouts:             %d", g_cntBreakoutsShort);
   PrintFormat("Long retest entries:         %d", g_cntRetestsLong);
   PrintFormat("Short retest entries:        %d", g_cntRetestsShort);
   PrintFormat("Expired setups:              %d", g_cntExpired);
   PrintFormat("Trades opened:               %d", g_cntTradesOpened);
   PrintFormat("Rejected - SL too wide:      %d", g_cntRejectedSLTooWide);
   PrintFormat("Rejected - Lot too small:    %d", g_cntRejectedLotSize);
   PrintFormat("Rejected - Daily cap:        %d", g_cntRejectedDailyCap);
   PrintFormat("Rejected - Drawdown / halt:  %d", g_cntRejectedDrawdown);
   Print("===============================================================");
}
