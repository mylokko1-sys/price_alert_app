// ─── services/pivot_service.dart ────────────────────────
// Detects pivot highs/lows and finds HH / LL.
// Same as find_pivots() and get_hh_ll() in Python version.

import '../config.dart';
import 'binance_service.dart';

class PivotPoint {
  final DateTime time;
  final double price;

  PivotPoint({required this.time, required this.price});
}

class PivotResult {
  final double? hh; // Higher High
  final double? ll; // Lower Low

  PivotResult({this.hh, this.ll});
}

class PivotService {
  /// Find all pivot highs and lows from candle list
  static Map<String, List<PivotPoint>> findPivots(List<Candle> candles) {
    List<PivotPoint> highs = [];
    List<PivotPoint> lows  = [];

    int len = Config.pivotLen;

    for (int i = len; i < candles.length - len; i++) {
      // Window of candles around index i
      List<Candle> window = candles.sublist(i - len, i + len + 1);

      double maxHigh = window.map((c) => c.high).reduce((a, b) => a > b ? a : b);
      double minLow  = window.map((c) => c.low).reduce((a, b) => a < b ? a : b);

      // Pivot High: candle[i].high is highest in window
      if (candles[i].high == maxHigh) {
        highs.add(PivotPoint(time: candles[i].time, price: candles[i].high));
      }

      // Pivot Low: candle[i].low is lowest in window
      if (candles[i].low == minLow) {
        lows.add(PivotPoint(time: candles[i].time, price: candles[i].low));
      }
    }

    return {'highs': highs, 'lows': lows};
  }

  /// Compare last two pivots to detect HH or LL
  static PivotResult getHHLL(List<Candle> candles) {
    final pivots = findPivots(candles);
    final highs  = pivots['highs']!;
    final lows   = pivots['lows']!;

    double? hh;
    double? ll;

    // Higher High: last pivot high > previous pivot high
    if (highs.length >= 2) {
      if (highs.last.price > highs[highs.length - 2].price) {
        hh = highs.last.price;
      }
    }

    // Lower Low: last pivot low < previous pivot low
    if (lows.length >= 2) {
      if (lows.last.price < lows[lows.length - 2].price) {
        ll = lows.last.price;
      }
    }

    return PivotResult(hh: hh, ll: ll);
  }

  /// Check if the current candle has hit the level
  static bool isHit(Candle candle, double level, bool isHH) {
    if (isHH) {
      return candle.high >= level; // Resistance hit
    } else {
      return candle.low <= level;  // Support hit
    }
  }
}
