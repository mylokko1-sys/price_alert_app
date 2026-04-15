// ─── services/api_service.dart ──────────────────────
// API abstraction service - handles switching between
// different exchange API providers

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'binance_service.dart';
export 'binance_service.dart';

/// API endpoints for different exchange providers
class ApiEndpoints {
  final String baseUrl;
  final String klinesEndpoint;
  final String tickerEndpoint;

  const ApiEndpoints({
    required this.baseUrl,
    required this.klinesEndpoint,
    required this.tickerEndpoint,
  });

  String getKlinesUrl({required String symbol, String? interval, int? limit}) {
    final uri = Uri.parse('$baseUrl$klinesEndpoint');
    return _buildUrl(uri, symbol, interval, limit);
  }

  String getTickerUrl(String symbol) {
    final uri = Uri.parse('$baseUrl$tickerEndpoint');
    final qs = Uri(queryParameters: {'symbol': symbol.toUpperCase()}).query;
    return '$uri?$qs';
  }

  String _buildUrl(Uri base, String symbol, String? interval, int? limit) {
    final params = {'symbol': symbol.toUpperCase()};
    if (interval != null) params['interval'] = interval;
    if (limit != null) params['limit'] = limit.toString();
    final qs = Uri(queryParameters: params).query;
    return '${base.toString()}?$qs';
  }
}

/// Exchange-specific API endpoints
class ApiProviderEndpoints {
  static ApiEndpoints getEndpoints(ApiProvider provider) {
    switch (provider) {
      case ApiProvider.binance:
        return ApiEndpoints(
          baseUrl: 'https://api.binance.com/api/v3',
          klinesEndpoint: '/klines',
          tickerEndpoint: '/ticker/price',
        );
      case ApiProvider.okx:
        return ApiEndpoints(
          baseUrl: 'https://www.okx.com/api/v5',
          klinesEndpoint: '/market/candles',
          tickerEndpoint: '/market/ticker',
        );
      case ApiProvider.bybit:
        return ApiEndpoints(
          baseUrl: 'https://api.bybit.com/v5',
          klinesEndpoint: '/market/kline',
          tickerEndpoint: '/market/tickers',
        );
      case ApiProvider.kucoin:
        return ApiEndpoints(
          baseUrl: 'https://api.kucoin.com/api/v1',
          klinesEndpoint: '/market/candles',
          tickerEndpoint: '/market/orderbook/level1',
        );
      case ApiProvider.kraken:
        return ApiEndpoints(
          baseUrl: 'https://api.kraken.com/0/public',
          klinesEndpoint: '/OHLC',
          tickerEndpoint: '/Ticker',
        );
    }
  }
}

/// Main API Service - Router for different providers
class ApiService {
  static ApiProvider get currentProvider => Config.apiProvider;

  static ApiEndpoints get endpoints =>
      ApiProviderEndpoints.getEndpoints(currentProvider);

  /// Fetch OHLCV data from the configured API provider
  static Future<List<Candle>> fetchCandles({
    required String symbol,
    required String interval,
    int? limit,
  }) async {
    switch (currentProvider) {
      case ApiProvider.binance:
        return await _fetchBinanceCandles(symbol, interval, limit);
      case ApiProvider.okx:
        return await _fetchOkxCandles(symbol, interval, limit);
      case ApiProvider.bybit:
        return await _fetchBybitCandles(symbol, interval, limit);
      case ApiProvider.kucoin:
        return await _fetchKucoinCandles(symbol, interval, limit);
      case ApiProvider.kraken:
        return await _fetchKrakenCandles(symbol, interval, limit);
    }
  }

  /// Validate symbol on the configured API provider
  static Future<SymbolValidationResult> validateSymbol(String symbol) async {
    if (symbol.isEmpty) {
      return const SymbolValidationResult(
        isValid: false,
        error: 'Symbol cannot be empty',
      );
    }
    try {
      final url = endpoints.getTickerUrl(symbol);
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        return const SymbolValidationResult(isValid: true);
      }
      final body = jsonDecode(response.body);
      final msg = body['msg'] as String? ?? 'Invalid symbol';
      return SymbolValidationResult(isValid: false, error: msg);
    } catch (e) {
      return SymbolValidationResult(
        isValid: false,
        error: 'Failed to validate symbol: $e',
      );
    }
  }

  /// Get current price from the configured API provider
  static Future<double?> getCurrentPrice(String symbol) async {
    try {
      final url = endpoints.getTickerUrl(symbol);
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        switch (currentProvider) {
          case ApiProvider.binance:
            return double.tryParse(data['price'] as String? ?? '0');
          case ApiProvider.okx:
            final list = data['data'] as List?;
            if (list != null && list.isNotEmpty) {
              return double.tryParse(list[0]['last'] as String? ?? '0');
            }
            break;
          case ApiProvider.bybit:
            final list = data['result']?['list'] as List?;
            if (list != null && list.isNotEmpty) {
              return double.tryParse(list[0]['lastPrice'] as String? ?? '0');
            }
            break;
          case ApiProvider.kucoin:
            return double.tryParse(data['data']['price'] as String? ?? '0');
          case ApiProvider.kraken:
            final keys = data.keys.toList();
            if (keys.isNotEmpty) {
              final tick = data[keys[0]];
              return double.tryParse(tick['c'][0] as String? ?? '0');
            }
            break;
        }
      }
    } catch (e) {
      print('❌ Error fetching price from $currentProvider: $e');
    }
    return null;
  }

  // ═════════════════════════════════════════════════════════════════
  // PROVIDER-SPECIFIC IMPLEMENTATIONS
  // ═════════════════════════════════════════════════════════════════

  static Future<List<Candle>> _fetchBinanceCandles(
    String symbol,
    String interval,
    int? limit,
  ) async {
    // BinanceService.fetchCandles uses positional parameters (symbol, timeframe)
    return await BinanceService.fetchCandles(symbol, interval);
  }

  static Future<List<Candle>> _fetchOkxCandles(
    String symbol,
    String interval,
    int? limit,
  ) async {
    try {
      final url = endpoints.getKlinesUrl(
        symbol: symbol,
        interval: _mapIntervalToOkx(interval),
        limit: limit,
      );
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch from OKX: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map;
      if (data['code'] != '0') {
        throw Exception('OKX API error: ${data['msg']}');
      }

      final candles = data['data'] as List;
      return candles
          .map(
            (c) => Candle(
              time: DateTime.fromMillisecondsSinceEpoch(int.parse(c[0])),
              open: double.parse(c[1]),
              high: double.parse(c[2]),
              low: double.parse(c[3]),
              close: double.parse(c[4]),
              volume: double.parse(c[5]),
            ),
          )
          .toList();
    } catch (e) {
      print('❌ OKX fetch candles error: $e');
      rethrow;
    }
  }

  static Future<List<Candle>> _fetchBybitCandles(
    String symbol,
    String interval,
    int? limit,
  ) async {
    try {
      final params = {
        'category': 'spot',
        'symbol': symbol.toUpperCase(),
        'interval': _mapIntervalToBybit(interval),
        if (limit != null) 'limit': limit.toString(),
      };
      final uri = Uri.parse(
        '${endpoints.baseUrl}${endpoints.klinesEndpoint}',
      ).replace(queryParameters: params);
      final response = await http.get(uri).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch from ByBit: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map;
      if (data['retCode'] != 0) {
        throw Exception('ByBit API error: ${data['retMsg']}');
      }

      final candles = (data['result']?['list'] as List?) ?? [];
      return candles
          .map(
            (c) => Candle(
              time: DateTime.fromMillisecondsSinceEpoch(int.parse(c[0])),
              open: double.parse(c[1]),
              high: double.parse(c[2]),
              low: double.parse(c[3]),
              close: double.parse(c[4]),
              volume: double.parse(c[5]),
            ),
          )
          .toList();
    } catch (e) {
      print('❌ ByBit fetch candles error: $e');
      rethrow;
    }
  }

  static Future<List<Candle>> _fetchKucoinCandles(
    String symbol,
    String interval,
    int? limit,
  ) async {
    try {
      final params = {
        'symbol': symbol.toUpperCase(),
        'type': _mapIntervalToKucoin(interval),
        if (limit != null) 'limit': limit.toString(),
      };
      final uri = Uri.parse(
        '${endpoints.baseUrl}${endpoints.klinesEndpoint}',
      ).replace(queryParameters: params);
      final response = await http.get(uri).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch from KuCoin: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map;
      if (data['code'] != '200000') {
        throw Exception('KuCoin API error: ${data['msg']}');
      }

      final candles = (data['data'] as List?) ?? [];
      return candles
          .map(
            (c) => Candle(
              time: DateTime.fromMillisecondsSinceEpoch(int.parse(c[0]) * 1000),
              open: double.parse(c[1]),
              high: double.parse(c[3]),
              low: double.parse(c[4]),
              close: double.parse(c[2]),
              volume: double.parse(c[5]),
            ),
          )
          .toList();
    } catch (e) {
      print('❌ KuCoin fetch candles error: $e');
      rethrow;
    }
  }

  static Future<List<Candle>> _fetchKrakenCandles(
    String symbol,
    String interval,
    int? limit,
  ) async {
    try {
      final pair = _convertToKrakenPair(symbol);
      final params = {
        'pair': pair,
        'interval': _mapIntervalToKraken(interval),
        if (limit != null) 'limit': limit.toString(),
      };
      final uri = Uri.parse(
        '${endpoints.baseUrl}${endpoints.klinesEndpoint}',
      ).replace(queryParameters: params);
      final response = await http.get(uri).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch from Kraken: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map;
      if (data['error'] != null && (data['error'] as List).isNotEmpty) {
        throw Exception('Kraken API error: ${data['error'][0]}');
      }

      final candles = (data['result']?[pair] as List?) ?? [];
      return candles
          .map(
            (c) => Candle(
              time: DateTime.fromMillisecondsSinceEpoch(
                (c[0] as num).toInt() * 1000,
              ),
              open: double.parse(c[1]),
              high: double.parse(c[2]),
              low: double.parse(c[3]),
              close: double.parse(c[4]),
              volume: double.parse(c[6]),
            ),
          )
          .toList();
    } catch (e) {
      print('❌ Kraken fetch candles error: $e');
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // INTERVAL MAPPING FUNCTIONS
  // ─────────────────────────────────────────────────────────────────

  static String _mapIntervalToOkx(String interval) {
    // OKX uses: 1m, 5m, 15m, 30m, 1H, 2H, 4H, 6H, 12H, 1D, 1W, 1M
    return interval
        .replaceAll('m', 'm')
        .replaceAll('h', 'H')
        .replaceAll('d', 'D');
  }

  static String _mapIntervalToBybit(String interval) {
    // ByBit uses: 1, 3, 5, 15, 30, 60, 120, 240, 360, 720, 1D, 1W, 1M
    final mapping = {
      '1m': '1',
      '3m': '3',
      '5m': '5',
      '15m': '15',
      '30m': '30',
      '1h': '60',
      '2h': '120',
      '4h': '240',
      '6h': '360',
      '8h': '480',
      '12h': '720',
      '1d': '1D',
      '3d': '1W',
      '1w': '1W',
      '1M': '1M',
    };
    return mapping[interval] ?? '60';
  }

  static String _mapIntervalToKucoin(String interval) {
    // KuCoin uses: 1min, 3min, 5min, 15min, 30min, 1hour, 2hour, 4hour,
    // 6hour, 8hour, 12hour, 1day, 1week, 1month
    final mapping = {
      '1m': '1min',
      '3m': '3min',
      '5m': '5min',
      '15m': '15min',
      '30m': '30min',
      '1h': '1hour',
      '2h': '2hour',
      '4h': '4hour',
      '6h': '6hour',
      '8h': '8hour',
      '12h': '12hour',
      '1d': '1day',
      '1w': '1week',
      '1M': '1month',
    };
    return mapping[interval] ?? '1hour';
  }

  static String _mapIntervalToKraken(String interval) {
    // Kraken uses: 1, 5, 15, 30, 60, 240, 1440, 10080, 21600
    final mapping = {
      '1m': '1',
      '5m': '5',
      '15m': '15',
      '30m': '30',
      '1h': '60',
      '4h': '240',
      '1d': '1440',
      '1w': '10080',
    };
    return mapping[interval] ?? '60';
  }

  static String _convertToKrakenPair(String symbol) {
    // Convert BTCUSDT to XBTUSDT (Kraken uses XBT instead of BTC)
    return symbol.replaceFirst('BTC', 'XBT');
  }

  // ═════════════════════════════════════════════════════════════════
  // CHART-SPECIFIC CANDLE FETCHING
  // ═════════════════════════════════════════════════════════════════
  // For now, these delegate to Binance or use basic pagination
  // Future: implement exchange-specific pagination for other providers

  /// Fetch historical candles for chart display
  static Future<List<Candle>> fetchCandlesForChart(
    String symbol,
    String timeframe, {
    int months = 9,
  }) async {
    // For now, delegate to Binance for all providers
    // We'll add exchange-specific implementations as needed
    return await BinanceService.fetchCandlesForChart(
      symbol,
      timeframe,
      months: months,
    );
  }

  /// Fetch candles from a given timestamp onwards
  static Future<List<Candle>> fetchCandlesFrom(
    String symbol,
    String timeframe,
    DateTime fromTime,
  ) async {
    // For now, delegate to Binance for all providers
    return await BinanceService.fetchCandlesFrom(symbol, timeframe, fromTime);
  }
}
