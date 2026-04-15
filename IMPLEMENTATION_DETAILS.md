# 🛠️ API Provider Implementation Details

## Architecture Overview

The implementation uses an **abstraction layer pattern** to support multiple exchange APIs:

```
┌─────────────────────────────────────────────────────────┐
│                    UI Layer                              │
│        (price_alerts_screen, chart_screen, etc.)         │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│              ApiService (Router)                         │
│    Routes calls to appropriate provider based on         │
│            Config.apiProvider                            │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
        ▼            ▼            ▼
   ┌────────┐  ┌────────┐   ┌──────────┐
   │Binance │  │  OKX   │   │ ByBit    │  ...
   │ API    │  │  API   │   │ API      │
   └────────┘  └────────┘   └──────────┘
```

## Key Components

### 1. ApiProvider Enum

Location: `lib/config.dart`

```dart
enum ApiProvider {
  binance('Binance'),
  okx('OKX'),
  bybit('ByBit'),
  kucoin('KuCoin'),
  kraken('Kraken');

  final String displayName;
  const ApiProvider(this.displayName);
}
```

**Purpose**: Type-safe representation of exchange choices with human-readable names.

### 2. ApiEndpoints Class

Location: `lib/services/api_service.dart`

```dart
class ApiEndpoints {
  final String baseUrl;
  final String klinesEndpoint;   // OHLCV candlestick endpoint
  final String tickerEndpoint;   // Single price endpoint

  String getKlinesUrl(...) { ... }
  String getTickerUrl(String symbol) { ... }
}
```

**Purpose**: Encapsulates API endpoint URLs and provides URL builder methods.

### 3. ApiProviderEndpoints Factory

Location: `lib/services/api_service.dart`

```dart
class ApiProviderEndpoints {
  static ApiEndpoints getEndpoints(ApiProvider provider) {
    switch (provider) {
      case ApiProvider.binance:
        return ApiEndpoints(
          baseUrl: 'https://api.binance.com/api/v3',
          klinesEndpoint: '/klines',
          tickerEndpoint: '/ticker/price',
        );
      // ... other providers
    }
  }
}
```

**Purpose**: Centralized configuration for all exchange endpoints.

### 4. ApiService Main Router

Location: `lib/services/api_service.dart`

Five main public methods:

#### a) `fetchCandles()`

```dart
static Future<List<Candle>> fetchCandles({
  required String symbol,
  required String interval,
  int? limit,
}) async
```

- Routes to exchange-specific implementation
- Handles interval mapping
- Returns standardized `Candle` objects

#### b) `validateSymbol()`

```dart
static Future<SymbolValidationResult> validateSymbol(String symbol) async
```

- Checks if a symbol exists on the selected exchange
- Returns validation result with error message if invalid

#### c) `getCurrentPrice()`

```dart
static Future<double?> getCurrentPrice(String symbol) async
```

- Gets current market price
- Returns null on failure
- Used for real-time price monitoring

#### d) `fetchCandlesForChart()`

```dart
static Future<List<Candle>> fetchCandlesForChart(
  String symbol,
  String timeframe,
  {int months = 9}
) async
```

- Fetches historical data for chart display
- Currently delegates to BinanceService (to be enhanced)

#### e) `fetchCandlesFrom()`

```dart
static Future<List<Candle>> fetchCandlesFrom(
  String symbol,
  String timeframe,
  DateTime fromTime,
) async
```

- Fetches recent candles from a given timestamp
- Used for live chart updates

## Data Flow Examples

### Example 1: Fetching Candles

```
BackgroundService._checkHHLL()
  │ Calls: ApiService.fetchCandles(
  │   symbol: 'BTCUSDT',
  │   interval: '1h'
  │ )
  │
  └─▶ ApiService checks Config.apiProvider
      │
      ├─ If Binance: _fetchBinanceCandles()
      ├─ If OKX: _fetchOkxCandles()
      ├─ If ByBit: _fetchBybitCandles()
      ├─ If KuCoin: _fetchKucoinCandles()
      └─ If Kraken: _fetchKrakenCandles()
         │
         ├─ Maps interval format
         ├─ Builds request URL
         ├─ Fetches from exchange
         ├─ Parses response (format varies by exchange)
         └─ Returns List<Candle> (standardized format)
```

### Example 2: Symbol Validation

```
PriceAlertsScreen._validateSymbol('ETHUSDT')
  │
  └─▶ ApiService.validateSymbol('ETHUSDT')
      │
      ├─ Gets current provider endpoints
      ├─ Builds ticker URL for selected exchange
      ├─ Sends HTTP GET request
      ├─ Parses exchange-specific response
      └─ Returns SymbolValidationResult
         │
         ├─ If valid: isValid=true
         └─ If invalid: isValid=false, error="Symbol not found"
```

## Provider-Specific Implementations

### Binance Implementation

- **URL**: `https://api.binance.com/api/v3/klines`
- **Params**: `symbol`, `interval`, `limit` (default limit: 1000)
- **Response**: Array of [time, open, high, low, close, volume, ...]
- **Intervals**: Standard format (1m, 5m, 1h, 1d, etc.)

### OKX Implementation

- **URL**: `https://www.okx.com/api/v5/market/candles`
- **Params**: `instId` (pair), `bar` (interval), `limit`
- **Response**: `data` array with OHLCV
- **Intervals**: 1m, 5m, 1H (uppercase H), 1D, etc.
- **Differences**: Uses `instId` instead of `symbol`

### ByBit Implementation

- **URL**: `https://api.bybit.com/v5/market/kline`
- **Params**: `category`, `symbol`, `interval`, `limit`
- **Response**: `result.list` array with OHLCV
- **Intervals**: 1, 3, 5, 15, 30, 60, 120, 240, 360, 720, 1D, 1W, 1M
- **Differences**: Uses numeric intervals

### KuCoin Implementation

- **URL**: `https://api.kucoin.com/api/v1/market/candles`
- **Params**: `symbol`, `type` (interval), `limit`
- **Response**: `data` array with OHLCV
- **Intervals**: 1min, 5min, 15min, 1hour, 1day, 1week, 1month
- **Differences**: Close time format and interval naming

### Kraken Implementation

- **URL**: `https://api.kraken.com/0/public/OHLC`
- **Params**: `pair`, `interval`, limit
- **Response**: Object with pair name mapping to OHLC array
- **Pair Format**: Uses `XBT` instead of `BTC` (auto-converted)
- **Intervals**: 1, 5, 15, 30, 60, 240, 1440, 10080, 21600 (in minutes)

## Interval Mapping System

Each provider uses different interval formats. The system handles conversion transparently:

### Mapping Function Pattern

```dart
static String _mapIntervalToOkx(String interval) {
  // Standard intervals in: 1m, 5m, 15m, 30m, 1h, 4h, 1d, 1w, 1M
  // OKX format out: 1m, 5m, 15m, 30m, 1H, 4H, 1D, 1W, 1M
  return interval.replaceAll('h', 'H').replaceAll('d', 'D');
}
```

### Supported Base Intervals (Konfigurable in Config)

```dart
const List<String> kAllTimeframes = [
  '1m', '3m', '5m', '15m', '30m',
  '1h', '2h', '4h', '6h', '8h', '12h',
  '1d', '3d', '1w', '1M'
];
```

## State Management & Persistence

### Config Updates

```dart
// In Config class
static ApiProvider apiProvider = ApiProvider.binance;

// In ConfigService
static const _kApiProvider = 'cfg_api_provider';

// Load from SharedPreferences
Config.apiProvider = ApiProvider.fromString(
  prefs.getString(_kApiProvider)
);

// Save to SharedPreferences
await prefs.setString(_kApiProvider, apiProvider.name);
```

### Background Service Sync

```dart
// When settings change, push to background service
static Future<void> _pushToBackground() async {
  svc.invoke('updateConfig', {
    'apiProvider': Config.apiProvider.name,
    // ... other config
  });
}
```

## Error Handling

### Network Errors

- Timeouts: 8 seconds for price queries, 15-20 seconds for bulk candle fetches
- HTTP errors: Parse response for exchange-specific error messages
- Fallback: Return empty list or null to allow graceful degradation

### API Response Parsing

```dart
try {
  final data = jsonDecode(response.body);
  // Provider-specific error checking
  if (data['error'] != null) {
    throw Exception('Provider error: ${data['error']}');
  }
  // Parse candles and return
} catch (e) {
  print('❌ Provider fetch error: $e');
  rethrow;
}
```

### Validation Flow

```dart
if (symbol.isEmpty) {
  return SymbolValidationResult(
    isValid: false,
    error: 'Symbol cannot be empty'
  );
}
try {
  // Make HTTP request
} catch (e) {
  return SymbolValidationResult(
    isValid: false,
    error: 'Network error: $e'
  );
}
```

## Performance Considerations

### Caching Strategy

- No built-in caching in ApiService
- Rely on Config.limit to control data volume (1000 candles default)
- Background service uses checkEveryMinutes to avoid excessive requests

### Request Optimization

- Binance: Fetches Config.limit candles per request (efficient)
- Chart mode: Pagination through 1000-candle blocks
- Price queries: Single lightweight request per symbol

### Rate Limiting

- Binance: 1200 requests/minute per IP
- OKX: 10 requests/second
- ByBit: 30 requests/second
- KuCoin: 100 requests/minute
- Kraken: 15 requests/second

## Testing Recommendations

### Unit Tests

- Test interval mapping for each provider
- Test response parsing for each provider
- Test validation with invalid symbols

### Integration Tests

- Test actual API calls (consider mocking for CI)
- Test failover when API is unavailable
- Test background service sync

### Manual Testing

1. Switch between providers in Bot Settings
2. Test symbol validation for each provider
3. Monitor background service logs for errors
4. Check chart loading with different providers
5. Verify price alerts trigger correctly
