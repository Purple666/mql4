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
input string usersList = "1,2,3"; // Имена участников для копирования через запятую, либо место в рейтинге для данного инструмента: 1,2,3
input double lots = 0.1; // Объём сделки (лотность)
input int minSL = 30; // Минимальный размер Stop Loss. Будет использован если SL выставленный трейдером ниже.
input int maxSL = 100; // Максимальный размер Stop Loss. Будет использоваться если SL выставленный трейдером выше или его нет.
input int minTP = 50; // Минимальный разрем Take Profit. Будет использован если TP выставленный трейдером ниже.
input int maxTP = 100; // Максимальный размер Take Profit. Будет использоваться если TP выставленный трейдером выше или его нет.
input int slippage = 0; // Параметр slippage при открытии ордеров
input int startHour = 1; // Час начала копирования. Начиная с этого часа копирование разрешено. 0..23 по времени сервера
input int stopHour = 12; // Час завершения копирования. Начиная с этого часа в сутках копирование запрещено. 

// Код инструмента от Investflow: EURUSD, GBPUSD, USDJPY, USDRUB, XAUUSD, BRENT
string iflowInstrument = "";

// Константа для перевода Investflow points в дельту для цены
double pointsToPriceMultiplier = 0;

string users[];

int OnInit() {
    if (StringLen(usersList) == 0 || StringSplit(usersList, ',', users) == 0) {
        Print("Не указан логин пользователя!");
        return INIT_PARAMETERS_INCORRECT;
    }
    if (lots <= 0 || lots > 10) {
        Print("Недопустимая лотность сделки!");
        return INIT_PARAMETERS_INCORRECT;
    }
    if (startHour > 23 || startHour >= stopHour) {
        Print("Некорректный диапазон времени для копирования! C ", startHour, " по ", stopHour);
        return INIT_PARAMETERS_INCORRECT;
    }
    iflowInstrument = symbolToIflowInstrument();
    if (StringLen(iflowInstrument) == 0) {
        Print("Инструмент не участвует в конкурсе: ", Symbol());
        return INIT_PARAMETERS_INCORRECT;
    }
    pointsToPriceMultiplier = Digits() >= 4 ? 1/10000.0 : 1/100.0;
   
    Print("Инициализация завершена. Копируем: ", iflowInstrument, " от " ,  usersList);
   
    // раз в минуту будем проверять данные с Investflow.
    EventSetTimer(60);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    Print("OnDeinit, reason: ", reason);
}

void OnTick() {
    // для каждого открытого ордера проверяем - не пришло ли время его закрыть по истечении дня.
    // TODO
}


void OnTimer() {
    // проверяем открыт ли рынок для текущего инструмента
    if (MarketInfo(Symbol(), MODE_TRADEALLOWED) <= 0) {
        Print("Рынок закрыт для ", Symbol());
        return;
    }
    if (Hour() < startHour || Hour() >= stopHour) {
        Print("Копирование запрещено. Часы копирования с ", startHour , " по " , stopHour ,
                " сейчас: ", Hour(), "ч.");
        return;
    }
    // проверяем состояние на investflow, открываем новые позиции, если нужно.
    Print("Запрашиваем позиции с сервера");
    char request[], response[];
    string requestHeaders = "User-Agent: investflow-tc", responseHeaders;
    int rc = WebRequest("GET", "http://investflow.ru/api/get-tc-orders?mode=csv", requestHeaders, 30 * 1000, request, response, responseHeaders);
    if (rc < 0) {
        int err = GetLastError();
        Print("Ошибка при доступе к investflow. Код ошибки: ", ErrorDescription(err));
        return;
    }
    string csv = CharArrayToString(response, 0, WHOLE_ARRAY, CP_UTF8);
    string lines[];
    rc = StringSplit(csv, '\n', lines);
    if (rc < 0) {
        Print("Пустой ответ от investflow. Код ошибки: ", GetLastError());
        return;
    }
    if (StringCompare("order_id, user_id, user_login, instrument, order_type, open, close, stop, class_rating", lines[0]) != 0) {
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
        if (rc != 9) {
            Print("Ошибка парсинга строки: ", line);
            break;
        }
        int orderId = StrToInteger(tokens[0]);
        int userId = StrToInteger(tokens[1]);
       
        string instrument = tokens[3];
        if (StringCompare(instrument, iflowInstrument) != 0) {
            continue;
        }
              
        string userLogin = tokens[2];
        string ratingPos = tokens[8];
        if (!isTrackedUser(userLogin) && !isTrackedUser(ratingPos)) {
            continue;
        }
        string orderType = tokens[4];
        double openPrice = StrToDouble(tokens[5]);
        double closePrice = StrToDouble(tokens[6]);
        if (closePrice > 0) { // позиция уже закрыта - нет смысла копировать.
            continue;
        }
        int stopPoints = StrToInteger(tokens[7]);
      
        Print("Найдена позиция для копирования от ", userLogin, ", тип: ", orderType);
        
        int type = StringCompare("buy", orderType) == 0 ? OP_BUY : OP_SELL;
        openOrderIfNeeded(orderId, type, openPrice, stopPoints, userLogin);
    }
}

bool isTrackedUser(string login) {
    for (int i = 0, n = ArraySize(users); i < n; i++) {
        if (StringCompare(users[i], login) == 0) {
            return true;
        }
    }
    return false;
}

bool findOrderByMagicNumber(int magicNumber) {
    // ищем среди открытых ордеров
    for(int i = 0, n = OrdersTotal(); i < n; i++) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && magicNumber == OrderMagicNumber()) {
            return true;
        }
    }
    // ищем среди закрытых ордеров, проверяем не более 100 последних ордеров
    for(int i = 0, n = OrdersHistoryTotal(); i < n && i < 100; i++) {
        int idx = n - i - 1;
        if (OrderSelect(idx, SELECT_BY_POS, MODE_HISTORY) && magicNumber == OrderMagicNumber()) {
            return true;
        }
    }

    return false;
}

void openOrderIfNeeded(int magicNumber, int orderType, double openPrice, int stopPoints, string user) {
    // проверим, не был ли уже обработан ордер
    bool processed = findOrderByMagicNumber(magicNumber);
    if (processed) {
        Print("Позиция уже была скопирована: ", magicNumber, "/", user);
        return;
    }
    // ордер еще не отработан: откроем его если текущие условия те же или лучше указанных трейдером
    bool isBuy = orderType == OP_BUY;
    double currentPrice = MarketInfo(Symbol(), isBuy ? MODE_ASK : MODE_BID);

    // выставляем ордер только если получили реальную цену открытия из конкурса
    // и текущая ситуация на рынке не хуже, чем когда открывался участник
    bool placeOrder  = openPrice <=0 || (isBuy ? openPrice <= currentPrice : openPrice >= currentPrice);
    if (!placeOrder) {
        Print("Не выполнены условия открытия для ", user);
        return;
    }
    string comment = "Investflow: " + user;
    int stopLossPoints = getStopPoints(minSL, stopPoints, maxSL);
    int takeProfitPoints = getStopPoints(minTP, stopLossPoints, maxTP); 
    double stopLossInPrice =  stopLossPoints * pointsToPriceMultiplier;
    double takeProfitInPrice =  takeProfitPoints * pointsToPriceMultiplier;
    double stopLoss = isBuy ? currentPrice - stopLossInPrice : currentPrice + stopLossInPrice;
    double takeProfit = isBuy ? currentPrice + takeProfitInPrice : currentPrice - takeProfitInPrice;
   
    Print("Копируем позицию ", user, ", цена: ", currentPrice, 
        ", объём: ", lots, 
        ", тип: ", (isBuy ? "BUY" : "SELL"),
        ", SL: ", stopLoss, 
        ", TP: ", takeProfit, 
        ", iflow-код: ", magicNumber);
   
    int ticket = OrderSend(Symbol(), orderType, lots, currentPrice, slippage, stopLoss, takeProfit, comment, magicNumber);
    if (ticket == -1) {
        int err = GetLastError();
        Print("Ошибка открытия позиции ", err, ": ", ErrorDescription(err));
    } else {
        Print("Позиция открыта, тикет: ", ticket);
    }
}

/* Возвращает значение между min & max. При val <=0 возвращается max. */
int getStopPoints(int min, int val, int max) {
    return val <= 0 || val > max ? max : val < min ? min : val; 
}

string IFLOW_INSTRUMENTS[] = {"EURUSD", "GBPUSD", "USDJPY", "USDRUB", "XAUUSD", "BRENT"};

string symbolToIflowInstrument() {
    string chartSymbol = getChartSymbol();
    for (int i = 0, n = ArraySize(IFLOW_INSTRUMENTS); i < n; i++) {
        string iflowSymbol = IFLOW_INSTRUMENTS[i];
        if (StringCompare(chartSymbol, iflowSymbol) == 0) {
            return iflowSymbol;
        }
    }
    
    return "EURUSD";
}

string getChartSymbol() {
    string symbol = Symbol();

    if (StringCompare(symbol, "UKOIL") == 0) {
        return "BRENT";
    }
        
    // Правка для AMarkets: инструменты могут иметь суффикс 'b'
    int len = StringLen(symbol);
    if (StringGetChar(symbol, len - 1) == 'b') {
        return StringSubstr(symbol, 0, len - 1);
    }
    return symbol;
}
