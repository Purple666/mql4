//+------------------------------------------------------------------+
//|                                                 InvestflowTC.mq4 |
//|                                                  Investflow & Co |
//|                                             http://investflow.ru |
//+------------------------------------------------------------------+
#property copyright "Investflow & Co"
#property link      "http://investflow.ru"
#property version   "1.00"
#property strict

#include <stdlib.mqh> 

// входные параметры:
input string login = "AndreyB"; // логин участника
input double volume = 0.1; // объём сделки (лотность)
input int defaultStopPoints = 50; // размер стопа, в случае если его не выставил трейдер.

// Код инструмента от Investflow: EURUSD, GBPUSD, USDJPY, USDRUB, XAUUSD, BRENT
string iflowInstrument = "";

// Константа для перевода Investflow points в дельту для цены
double pointsToPriceMultiplier = 0;

int OnInit() {
   if (StringLen(login) == 0) {
      Print("Не указан логин пользователя!");
      return INIT_PARAMETERS_INCORRECT;
   }
   if (volume <= 0 || volume > 10) {
      Print("Недопустимая лотность сделки!");
      return INIT_PARAMETERS_INCORRECT;
   }
   iflowInstrument = symbolToIflowInstrument();
   if (StringLen(iflowInstrument) == 0) {
      Print("Инструмент не участвует в конкурсе: ", Symbol());
      return INIT_PARAMETERS_INCORRECT;
   }
   pointsToPriceMultiplier = Digits() >= 4 ? 1/10000.0 : 1/100.0;
   
   Print("Инициализация завершена. Копируем: ", iflowInstrument, " от пользователя ",  login);
   
   // раз в 5 минут будем проверять данные с Investflow.
   EventSetTimer(300);
   //EventSetTimer(3);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   Print("OnDeinit");
   EventKillTimer();
}

void OnTick() {
   // для каждого открытого ордера проверяем - не пришло ли время его закрыть по истечении дня.
   // TODO
}


void OnTimer() {
   // проверяем состояние на investflow, открываем новые позиции, если нужно.
   char request[], response[];
   string requestHeaders = "User-Agent: investflow-tc", responseHeaders;
   int rc = WebRequest("GET", "http://investflow.ru/api/get-tc-orders?mode=csv", requestHeaders, 30 * 1000, request, response, responseHeaders);
   if (rc < 0) {
      Print("Ошибка при доступе к investflow. Код ошибки: ", GetLastError());
      return;
   }
   string csv = CharArrayToString(response, 0, WHOLE_ARRAY, CP_UTF8);
   string lines[];
   rc = StringSplit(csv, '\n', lines);
   if (rc < 0) {
      Print("Пустой ответ от investflow. Код ошибки: ", GetLastError());
      return;
   }
   if (StringCompare("order_id, user_id, user_login, instrument, order_type, open, close, stop", lines[0]) != 0) {
      Print("Неподдерживаемый формат ответа: ", lines[0]);
      return;
   }
   for (int i = 1, n = ArraySize(lines); i < n; i++) {
      string line = lines[i];
      if (StringLen(line) == 0) {
         continue;
      }
      string tokens[];
      rc = StringSplit(line, ',', tokens);
      if (rc != 8) {
         Print("Ошибка парсинга строки: ", line);
         break;
      }
      int orderId = StrToInteger(tokens[0]);
      int userId = StrToInteger(tokens[1]);
      string userLogin = tokens[2];
      if (StringCompare(login, userLogin) != 0) {
         continue;
      }
      string instrument = tokens[3];
      if (StringCompare(instrument, iflowInstrument) != 0) {
         continue;
      }
      string orderType = tokens[4];
      double openPrice = StrToDouble(tokens[5]);
      // double closePrice = StrToDouble(tokens[6]);
      int stopPoints = StrToInteger(tokens[7]);
      
      int type = StringCompare("buy", orderType) == 0 ? OP_BUY : OP_SELL;
      openOrderIfNeeded(orderId, type, openPrice, stopPoints);
   }
}
string IFLOW_INSTRUMENTS[] = {"EURUSD", "GBPUSD", "USDJPY", "USDRUB", "XAUUSD", "BRENT"};

string symbolToIflowInstrument() {
   for (int i = 0, n = ArraySize(IFLOW_INSTRUMENTS); i < n; i++) {
      string iflowSymbol = IFLOW_INSTRUMENTS[i];
      if (StringCompare(Symbol(), iflowSymbol) == 0) {
         return iflowSymbol;
      }
   }
   //todo: добавить дополнительные варианты отображения investflow инструментов в инструмент брокера.
   return "";
}


void openOrderIfNeeded(int magicNumber, int orderType, double openPrice, int stopPoints) {
   for(int i = 0, n = OrdersTotal(); i < n; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         continue;
      }
      if (magicNumber == OrderMagicNumber()) { // ордер уже сделан
         return;
      }
   }
   // ордер еще не отработан: откроем его если текущие условия те же или лучше указанных трейдером
   bool isBuy = orderType == OP_BUY;
   double currentPrice = MarketInfo(Symbol(), isBuy ? MODE_ASK : MODE_BID);
   bool placeOrder  = openPrice <=0 || (isBuy ? openPrice <= currentPrice : openPrice >= currentPrice);
   
   string comment = "Investflow: " + login;
   int slippage = 0;
   double stopInPrice = (stopPoints <= 0 ? defaultStopPoints : stopPoints) * pointsToPriceMultiplier;
   double stopLoss = isBuy ? currentPrice - stopInPrice : currentPrice + stopInPrice;
   double takeProfit = isBuy ? currentPrice + stopInPrice : currentPrice - stopInPrice;
   
   Print("Открываем позицию, цена: ", currentPrice, 
      ", объём: ", volume, 
      ", тип: ", (isBuy ? "BUY" : "SELL"),
      ", SL: ", stopLoss, 
      ", TP: ", takeProfit, 
      ", iflow-код: ", magicNumber);
   
   int ticket = OrderSend(Symbol(), orderType, volume, currentPrice, slippage, stopLoss, takeProfit, comment, magicNumber);
   if (ticket == -1) {
      int err = GetLastError();
      Print("Ошибка открытия позиции ", err, ": ", ErrorDescription(err));
   } else {
      Print("Позиция открыта, тикет: ", ticket);
   }
}

