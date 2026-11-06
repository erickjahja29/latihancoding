//+------------------------------------------------------------------+
//|                                                    ScalperEA.mq5 |
//|  EA scalping: EMA cross + filter tren EMA + RSI, SL/TP berbasis  |
//|  ATR, money management %risk, breakeven, trailing stop, filter   |
//|  spread & jam trading, serta batas loss harian.                  |
//+------------------------------------------------------------------+
#property copyright "latihancoding"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Umum
input group "=== Umum ==="
input ulong            InpMagic          = 20261106;    // Magic number
input ENUM_TIMEFRAMES  InpTF             = PERIOD_M5;   // Timeframe sinyal
input string           InpComment        = "ScalperEA"; // Komentar order

//--- Indikator
input group "=== Indikator ==="
input int              InpFastEMA        = 9;           // EMA cepat
input int              InpSlowEMA        = 21;          // EMA lambat
input int              InpTrendEMA       = 200;         // EMA filter tren (0 = nonaktif)
input int              InpRSIPeriod      = 14;          // Periode RSI
input double           InpRSIBuyMax      = 70.0;        // RSI maks untuk BUY (hindari overbought)
input double           InpRSISellMin     = 30.0;        // RSI min untuk SELL (hindari oversold)
input int              InpATRPeriod      = 14;          // Periode ATR

//--- Risk & Money Management
input group "=== Risiko ==="
input bool             InpUseRiskPercent = true;        // true = lot dari % risiko, false = lot tetap
input double           InpRiskPercent    = 1.0;         // Risiko per trade (% dari balance)
input double           InpFixedLot       = 0.01;        // Lot tetap (jika %risiko nonaktif)
input double           InpSL_ATR         = 1.0;         // Stop Loss = ATR x
input double           InpTP_ATR         = 1.5;         // Take Profit = ATR x
input int              InpMaxPositions   = 1;           // Maks posisi terbuka (EA ini, simbol ini)
input double           InpMaxDailyLoss   = 3.0;         // Maks loss harian (% equity awal hari, 0 = off)

//--- Manajemen posisi
input group "=== Breakeven & Trailing ==="
input bool             InpUseBreakeven   = true;        // Aktifkan breakeven
input double           InpBE_ATR         = 0.7;         // Pindah SL ke BE saat profit >= ATR x
input int              InpBE_OffsetPts   = 10;          // Offset BE (points) untuk menutup biaya
input bool             InpUseTrailing    = true;        // Aktifkan trailing stop
input double           InpTrailStart_ATR = 1.0;         // Mulai trailing saat profit >= ATR x
input double           InpTrailDist_ATR  = 0.8;         // Jarak trailing = ATR x

//--- Filter
input group "=== Filter ==="
input int              InpMaxSpreadPts   = 25;          // Spread maksimum (points)
input bool             InpUseSession     = true;        // Filter jam trading (jam server broker)
input int              InpStartHour      = 8;           // Jam mulai (server)
input int              InpEndHour        = 20;          // Jam selesai (server, eksklusif)
input bool             InpNoFridayLate   = true;        // Stop entry Jumat setelah jam berikut
input int              InpFridayHour     = 18;          // Jam batas hari Jumat (server)
input int              InpSlippagePts    = 10;          // Deviasi/slippage maks (points)

//--- Variabel global
CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hTrend = INVALID_HANDLE;
int      hRSI  = INVALID_HANDLE, hATR  = INVALID_HANDLE;
datetime lastBarTime   = 0;
double   lastATR       = 0.0;
int      currentDay    = -1;
double   dayStartEquity = 0.0;
bool     dailyLimitHit = false;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEMA >= InpSlowEMA)
   {
      Print("Error: EMA cepat harus lebih kecil dari EMA lambat.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSL_ATR <= 0 || InpTP_ATR <= 0)
   {
      Print("Error: SL/TP multiplier harus > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   hFast = iMA(_Symbol, InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(InpTrendEMA > 0)
      hTrend = iMA(_Symbol, InpTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI  = iRSI(_Symbol, InpTF, InpRSIPeriod, PRICE_CLOSE);
   hATR  = iATR(_Symbol, InpTF, InpATRPeriod);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hRSI == INVALID_HANDLE ||
      hATR == INVALID_HANDLE || (InpTrendEMA > 0 && hTrend == INVALID_HANDLE))
   {
      Print("Error: gagal membuat handle indikator. Kode: ", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();

   ResetDailyIfNeeded();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hFast  != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow  != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hTrend != INVALID_HANDLE) IndicatorRelease(hTrend);
   if(hRSI   != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR   != INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyIfNeeded();

   //--- Batas loss harian
   if(InpMaxDailyLoss > 0 && !dailyLimitHit)
   {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq <= dayStartEquity * (1.0 - InpMaxDailyLoss / 100.0))
      {
         dailyLimitHit = true;
         CloseAllPositions();
         Print("Batas loss harian tercapai. Trading dihentikan sampai besok.");
      }
   }

   //--- Ambil ATR terakhir (bar tertutup) untuk manajemen posisi
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf) == 1)
      lastATR = atrBuf[0];

   //--- Kelola posisi terbuka di setiap tick
   if(lastATR > 0)
      ManagePositions();

   UpdateComment();

   //--- Cek sinyal hanya saat bar baru terbentuk
   datetime barTime = iTime(_Symbol, InpTF, 0);
   if(barTime == 0 || barTime == lastBarTime)
      return;
   lastBarTime = barTime;

   if(dailyLimitHit)              return;
   if(!IsTradingTime())           return;
   if(!IsSpreadOK())              return;
   if(CountPositions() >= InpMaxPositions) return;

   int signal = GetSignal();
   if(signal == 1)       OpenTrade(ORDER_TYPE_BUY);
   else if(signal == -1) OpenTrade(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Sinyal: 1 = BUY, -1 = SELL, 0 = tidak ada                         |
//+------------------------------------------------------------------+
int GetSignal()
{
   double fast[], slow[], rsi[], trend[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(trend, true);

   // index 0 = bar[1] (baru tertutup), index 1 = bar[2]
   if(CopyBuffer(hFast, 0, 1, 2, fast) != 2) return 0;
   if(CopyBuffer(hSlow, 0, 1, 2, slow) != 2) return 0;
   if(CopyBuffer(hRSI,  0, 1, 1, rsi)  != 1) return 0;

   double close1 = iClose(_Symbol, InpTF, 1);
   if(close1 == 0) return 0;

   bool trendUp = true, trendDown = true;
   if(InpTrendEMA > 0)
   {
      if(CopyBuffer(hTrend, 0, 1, 1, trend) != 1) return 0;
      trendUp   = close1 > trend[0] && fast[0] > trend[0];
      trendDown = close1 < trend[0] && fast[0] < trend[0];
   }

   bool crossUp   = fast[0] > slow[0] && fast[1] <= slow[1];
   bool crossDown = fast[0] < slow[0] && fast[1] >= slow[1];

   if(crossUp && trendUp && rsi[0] > 50.0 && rsi[0] < InpRSIBuyMax)
      return 1;
   if(crossDown && trendDown && rsi[0] < 50.0 && rsi[0] > InpRSISellMin)
      return -1;
   return 0;
}

//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
{
   if(lastATR <= 0) return;

   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minStop  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   double slDist = MathMax(lastATR * InpSL_ATR, minStop + 2 * point);
   double tpDist = MathMax(lastATR * InpTP_ATR, minStop + 2 * point);

   double price, sl, tp;
   if(type == ORDER_TYPE_BUY)
   {
      price = ask;
      sl    = NormalizeDouble(price - slDist, digits);
      tp    = NormalizeDouble(price + tpDist, digits);
   }
   else
   {
      price = bid;
      sl    = NormalizeDouble(price + slDist, digits);
      tp    = NormalizeDouble(price - tpDist, digits);
   }

   double lot = CalcLot(type, price, slDist);
   if(lot <= 0)
   {
      Print("Lot tidak valid, entry dibatalkan.");
      return;
   }

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, price, sl, tp, InpComment)
             : trade.Sell(lot, _Symbol, price, sl, tp, InpComment);

   if(!ok || (trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED))
      PrintFormat("Gagal open %s: retcode=%u (%s)",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else
      PrintFormat("Open %s %.2f lot @ %s SL=%s TP=%s",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lot,
                  DoubleToString(price, digits), DoubleToString(sl, digits), DoubleToString(tp, digits));
}

//+------------------------------------------------------------------+
//| Hitung lot berdasarkan % risiko dan jarak SL                      |
//+------------------------------------------------------------------+
double CalcLot(ENUM_ORDER_TYPE type, double price, double slDist)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lot = InpFixedLot;

   if(InpUseRiskPercent)
   {
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      double slPrice   = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
      double lossPerLot = 0.0;

      if(!OrderCalcProfit(type, _Symbol, 1.0, price, slPrice, lossPerLot) || lossPerLot == 0.0)
      {
         // fallback: pakai tick value
         double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tickVal <= 0 || tickSize <= 0) return 0;
         lossPerLot = slDist / tickSize * tickVal;
      }
      lossPerLot = MathAbs(lossPerLot);
      if(lossPerLot <= 0) return 0;

      lot = riskMoney / lossPerLot;
   }

   // normalisasi ke step lot broker
   if(stepLot > 0)
      lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   // cek margin cukup
   double margin = 0.0;
   ENUM_ORDER_TYPE ot = type;
   if(OrderCalcMargin(ot, _Symbol, lot, price, margin))
   {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin > freeMargin)
      {
         Print("Margin tidak cukup untuk lot ", DoubleToString(lot, 2));
         return 0;
      }
   }

   int lotDigits = 2;
   if(stepLot > 0)
      lotDigits = (int)MathMax(0, MathCeil(-MathLog10(stepLot)));
   return NormalizeDouble(lot, lotDigits);
}

//+------------------------------------------------------------------+
//| Breakeven & trailing stop                                         |
//+------------------------------------------------------------------+
void ManagePositions()
{
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      long   ptype = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double newSL = curSL;

      if(ptype == POSITION_TYPE_BUY)
      {
         double profitDist = bid - open;

         if(InpUseBreakeven && profitDist >= lastATR * InpBE_ATR)
         {
            double be = NormalizeDouble(open + InpBE_OffsetPts * point, digits);
            if(curSL < be) newSL = be;
         }
         if(InpUseTrailing && profitDist >= lastATR * InpTrailStart_ATR)
         {
            double tr = NormalizeDouble(bid - lastATR * InpTrailDist_ATR, digits);
            if(tr > newSL) newSL = tr;
         }
         // validasi jarak minimum dari harga
         if(newSL > curSL + point / 2 && bid - newSL > minStop)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double profitDist = open - ask;

         if(InpUseBreakeven && profitDist >= lastATR * InpBE_ATR)
         {
            double be = NormalizeDouble(open - InpBE_OffsetPts * point, digits);
            if(curSL == 0 || curSL > be) newSL = be;
         }
         if(InpUseTrailing && profitDist >= lastATR * InpTrailStart_ATR)
         {
            double tr = NormalizeDouble(ask + lastATR * InpTrailDist_ATR, digits);
            if(newSL == 0 || tr < newSL) newSL = tr;
         }
         if(newSL > 0 && (curSL == 0 || newSL < curSL - point / 2) && newSL - ask > minStop)
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts)
   {
      PrintFormat("Spread terlalu besar (%d > %d), skip.", spread, InpMaxSpreadPts);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpNoFridayLate && dt.day_of_week == 5 && dt.hour >= InpFridayHour)
      return false;

   if(!InpUseSession) return true;

   if(InpStartHour <= InpEndHour)
      return dt.hour >= InpStartHour && dt.hour < InpEndHour;
   // sesi melewati tengah malam, mis. 22 -> 5
   return dt.hour >= InpStartHour || dt.hour < InpEndHour;
}

//+------------------------------------------------------------------+
void ResetDailyIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != currentDay)
   {
      currentDay     = dt.day_of_year;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dailyLimitHit  = false;
   }
}

//+------------------------------------------------------------------+
void UpdateComment()
{
   Comment(StringFormat(
      "ScalperEA v1.00\n"
      "Spread: %d pts (maks %d)\n"
      "ATR: %s\n"
      "Posisi terbuka: %d / %d\n"
      "Equity awal hari: %.2f | Equity: %.2f\n"
      "Status: %s",
      (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), InpMaxSpreadPts,
      DoubleToString(lastATR, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
      CountPositions(), InpMaxPositions,
      dayStartEquity, AccountInfoDouble(ACCOUNT_EQUITY),
      dailyLimitHit ? "STOP (batas loss harian)" : (IsTradingTime() ? "Aktif" : "Di luar jam trading")));
}
//+------------------------------------------------------------------+
