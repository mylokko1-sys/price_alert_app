# 🔄 Multi-API Provider Support Guide

## Overview

The bot now supports multiple cryptocurrency exchange APIs with a single unified interface. Users can switch between different API providers in **Bot Settings** tab.

## ✅ Supported Exchanges

- **Binance** (Default) - Largest exchange by volume
- **OKX** - Multi-chain derivative exchange
- **ByBit** - Advanced derivatives trading platform
- **KuCoin** - Community-focused exchange platform
- **Kraken** - US-based regulated exchange

## 🎯 How to Use

### Switching API Providers

1. Navigate to the **Bot Settings** tab (bottom navigation)
2. Scroll to the top section: **"Trading API Provider"**
3. Select your preferred exchange from the list
4. The currently selected provider is displayed with a blue checkmark and border
5. Click **Save Settings** at the bottom

### Features

- **Instant Switching**: Change API providers anytime without restarting the app
- **Persistent Storage**: Your selected API provider is saved automatically
- **Real-time Validation**: Symbol validation uses the currently selected API
- **Background Service Support**: The background bot uses the configured API provider

## 🔧 Technical Implementation

### Files Modified

#### 1. **config.dart**

- Added `ApiProvider` enum with all supported exchanges
- Added `apiProvider` field to Config class
- Added `_kApiProvider` persistence key to ConfigService
- Updated `saveBotSettings()` to accept optional `apiProvider` parameter

#### 2. **settings_screen.dart** (BotSettingsPage)

- Added API provider selector UI with radio buttons
- Shows provider description and current selection
- Integrated with `onSaved` callback to persist changes
- Updated error messages to reflect selected API

#### 3. **services/api_service.dart** (NEW)

Core abstraction service that:

- Routes API calls to the appropriate provider
- Handles interval format conversions for each exchange
- Implements `fetchCandles()`, `validateSymbol()`, `getCurrentPrice()`
- Includes chart-specific methods: `fetchCandlesForChart()`, `fetchCandlesFrom()`
- Gracefully handles API-specific response formats

#### 4. **Updated Service Files**

- `background_service.dart` - Uses `ApiService` instead of `BinanceService`
- `price_alerts_screen.dart` - Symbol validation via `ApiService`
- `candle_pattern_alerts_screen.dart` - Symbol validation via `ApiService`
- `chart_screen.dart` - Chart data fetching via `ApiService`

## 📊 API Provider Details

### Interval Mapping

Each exchange uses different interval naming conventions. `ApiService` automatically converts between them:

| Binance | OKX | ByBit | KuCoin | Kraken |
| ------- | --- | ----- | ------ | ------ |
| 1m      | 1m  | 1     | 1min   | 1      |
| 5m      | 5m  | 5     | 5min   | 5      |
| 1h      | 1H  | 60    | 1hour  | 60     |
| 4h      | 4H  | 240   | 4hour  | 240    |
| 1d      | 1D  | 1D    | 1day   | 1440   |

### Symbol Format

- **Binance, OKX, ByBit, KuCoin**: Standard format (e.g., `BTCUSDT`)
- **Kraken**: Uses `XBT` instead of `BTC` (e.g., `XBTUSDT`) - Auto-converted by ApiService

## 🚀 Future Enhancements

### Planned Features

1. **Multi-Exchange Support**: Monitor multiple exchanges simultaneously
2. **Exchange-Specific Chart APIs**: Native pagination for OKX, ByBit, etc.
3. **API Key Management**: Optional authenticated endpoints for private data
4. **Rate Limit Handling**: Exchange-specific rate limit management
5. **Fallback Chains**: Automatic failover if primary API is down

### Adding New Exchanges

To add a new exchange:

1. Add to `ApiProvider` enum in `config.dart`:

   ```dart
   enum ApiProvider {
     newExchange('New Exchange'),
   }
   ```

2. Add endpoints in `ApiProviderEndpoints.getEndpoints()`:

   ```dart
   case ApiProvider.newExchange:
     return ApiEndpoints(...);
   ```

3. Implement fetch method in `ApiService`:

   ```dart
   static Future<List<Candle>> _fetchNewExchangeCandles(...) async {
     // Implementation
   }
   ```

4. Add interval mapping function:
   ```dart
   static String _mapIntervalToNewExchange(String interval) {
     // Return exchange-specific interval format
   }
   ```

## ⚙️ Configuration

### Persistence

API provider selection is stored in SharedPreferences with key: `cfg_api_provider`

### Background Service

The background service receives the current API provider as part of `updateConfig`:

```dart
'apiProvider': Config.apiProvider.name,
```

### Default Provider

If no provider is saved, Binance is used as default for backward compatibility.

## 🐛 Troubleshooting

### Symbol Not Found

- Verify the symbol exists on the selected exchange
- Symbol formats may differ between exchanges
- Some exchanges may not support all trading pairs

### Invalid Interval

- Some exchanges might not support very short intervals (1m, 3m)
- Try using 5m or longer intervals
- Each exchange has different minimum and maximum intervals

### API Rate Limiting

- If getting errors, reduce the check interval in Bot Settings
- Default is 5 minutes - consider increasing to 10-15 minutes for high-volume monitoring

## 📝 Notes

- All API calls follow the official exchange REST API documentation
- Charts currently use Binance's pagination for all providers (to be updated)
- WebSocket support (real-time price feeds) remains Binance-specific
- No authentication required for public market data endpoints used by the bot
