// ─── services/binance_service.dart ──────────────────────
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../config.dart';

class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });
}

class SymbolValidationResult {
  final bool isValid;
  final String? error;
  const SymbolValidationResult({required this.isValid, this.error});
}

class BinanceService {
  static const String _baseUrl   = 'https://api.binance.com/api/v3/klines';
  static const String _tickerUrl = 'https://api.binance.com/api/v3/ticker/price';

  // ─── Validate symbol ─────────────────────────────────
  static Future<SymbolValidationResult> validateSymbol(String symbol) async {
    if (symbol.isEmpty) {
      return const SymbolValidationResult(
          isValid: false, error: 'Symbol cannot be empty');
    }
    try {
      final uri      = Uri.parse('$_tickerUrl?symbol=${symbol.toUpperCase()}');
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        return const SymbolValidationResult(isValid: true);
      }
      final body = jsonDecode(response.body);
      final msg  = body['msg'] as String? ?? 'Invalid symbol';
      return SymbolValidationResult(isValid: false, error: msg);
    } catch (e) {
      return SymbolValidationResult(isValid: false, error: 'Network error: $e');
    }
  }

  // ─── Current ticker price ────────────────────────────
  static Future<double?> getCurrentPrice(String symbol) async {
    try {
      final uri      = Uri.parse('$_tickerUrl?symbol=${symbol.toUpperCase()}');
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final body  = jsonDecode(response.body);
        final price = body['price'] as String?;
        return price != null ? double.tryParse(price) : null;
      }
      return null;
    } catch (e) {
      print('❌ getCurrentPrice failed for $symbol: $e');
      return null;
    }
  }

  // ─── Bot use: fixed Config.limit candles ─────────────
  static Future<List<Candle>> fetchCandles(
      String symbol, String timeframe) async {
    final uri = Uri.parse(
      '$_baseUrl?symbol=$symbol&interval=$timeframe&limit=${Config.limit}',
    );
    final response =
        await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      final msg  = body['msg'] as String? ?? response.statusCode.toString();
      throw Exception('Binance error for $symbol: $msg');
    }
    return _parse(jsonDecode(response.body) as List);
  }

  // ─── Chart use: N months of history, then gap-fill ───
  // Pages through Binance (1000/request) starting [months] ago,
  // then does ONE extra request to fill any gap up to right now.
  static Future<List<Candle>> fetchCandlesForChart(
    String symbol,
    String timeframe, {
    int months = 9,
  }) async {
    final sym = symbol.toUpperCase();

    // How many months back to start, capped by timeframe
    // (very short TFs can't return 9 months within Binance's limits)
    final adjustedMonths = _adjustMonths(timeframe, months);

    final startMs = DateTime.now()
        .subtract(Duration(days: adjustedMonths * 30))
        .millisecondsSinceEpoch;

    final List<Candle> result = [];
    int from  = startMs;
    int pages = 0;

    // Page through history
    while (pages < 20) {
      final uri = Uri.parse(
        '$_baseUrl?symbol=$sym&interval=$timeframe'
        '&startTime=$from&limit=1000',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 20));

      if (res.statusCode != 200) {
        final body = jsonDecode(res.body);
        final msg  = body['msg'] as String? ?? '${res.statusCode}';
        throw Exception('Binance: $msg (symbol: $sym)');
      }

      final raw = jsonDecode(res.body) as List;
      if (raw.isEmpty) break;

      result.addAll(_parse(raw));
      pages++;

      if (raw.length < 1000) break; // last page

      from = result.last.time.millisecondsSinceEpoch + 1;
      if (from > DateTime.now().millisecondsSinceEpoch) break;
    }

    // ── Gap-fill: always fetch the latest candles to bridge
    //    any gap between the last paged candle and right now.
    if (result.isNotEmpty) {
      final gapStart = result.last.time.millisecondsSinceEpoch + 1;
      if (gapStart < DateTime.now().millisecondsSinceEpoch) {
        final uri = Uri.parse(
          '$_baseUrl?symbol=$sym&interval=$timeframe'
          '&startTime=$gapStart&limit=1000',
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 20));
        if (res.statusCode == 200) {
          final raw = jsonDecode(res.body) as List;
          if (raw.isNotEmpty) {
            result.addAll(_parse(raw));
          }
        }
      }
    }

    return result;
  }

  // ─── Fetch all candles from a given time to now ───────
  // Used by live-refresh to fill any gap since the last
  // candle already in memory, without re-fetching history.
  static Future<List<Candle>> fetchCandlesFrom(
    String symbol,
    String timeframe,
    DateTime fromTime,
  ) async {
    final sym     = symbol.toUpperCase();
    // Start one millisecond after the last known candle so we
    // get the current (in-progress) candle and anything after.
    final startMs = fromTime.millisecondsSinceEpoch;

    final List<Candle> result = [];
    int from  = startMs;
    int pages = 0;

    while (pages < 5) {
      final uri = Uri.parse(
        '$_baseUrl?symbol=$sym&interval=$timeframe'
        '&startTime=$from&limit=200',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) break;

      final raw = jsonDecode(res.body) as List;
      if (raw.isEmpty) break;

      result.addAll(_parse(raw));
      pages++;

      if (raw.length < 200) break;
      from = result.last.time.millisecondsSinceEpoch + 1;
      if (from > DateTime.now().millisecondsSinceEpoch) break;
    }

    return result;
  }

  // ─── How many months to adjust per timeframe ─────────
  // Shorter timeframes produce too many candles for 9 months.
  // We cap them so the total stays under ~10,000 candles.
  static int _adjustMonths(String tf, int requested) {
    switch (tf) {
      case '5m':  return math.min(requested, 1);   // ~8,640 candles/mo
      case '15m': return math.min(requested, 3);   // ~2,880/mo
      case '30m': return math.min(requested, 6);   // ~1,440/mo
      case '1h':  return math.min(requested, 9);
      case '4h':  return math.min(requested, 9);
      case '1d':  return math.min(requested, 9);
      case '1w':  return math.min(requested, 9);
      default:    return math.min(requested, 9);
    }
  }

  // ─── Parse raw Binance kline array ───────────────────
  static List<Candle> _parse(List<dynamic> raw) {
    return raw.map((item) => Candle(
      time:   DateTime.fromMillisecondsSinceEpoch(item[0] as int),
      open:   double.parse(item[1].toString()),
      high:   double.parse(item[2].toString()),
      low:    double.parse(item[3].toString()),
      close:  double.parse(item[4].toString()),
      volume: double.parse(item[5].toString()),
    )).toList();
  }
}
