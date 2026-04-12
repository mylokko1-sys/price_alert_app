// ─── models/chart_models.dart ────────────────────────────
// Shared data models for chart drawings.
// TrendLineData stores TIMESTAMPS + PRICES (not candle indices)
// so lines display correctly on any timeframe.

import 'dart:ui' show Color;

enum DrawTool { cursor, trendLine, hLine }

// ── Trend Line ────────────────────────────────────────────
// Anchor points are stored as (timestamp, price) pairs.
// Candle indices are computed at render time by looking up
// the closest candle by time — so the line is timeframe-agnostic.
class TrendLineData {
  final String   id;
  DateTime time1;   // timestamp of anchor point 1
  double   price1;
  DateTime time2;   // timestamp of anchor point 2
  double   price2;
  Color    color;
  bool     hasAlert;
  String   botId;

  TrendLineData({
    required this.id,
    required this.time1,
    required this.price1,
    required this.time2,
    required this.price2,
    required this.color,
    this.hasAlert = false,
    this.botId    = '',
  });

  TrendLineData copyWith({
    DateTime? time1,  double? price1,
    DateTime? time2,  double? price2,
    bool?   hasAlert,
    String? botId,
  }) => TrendLineData(
    id:       id,
    color:    color,
    time1:    time1    ?? this.time1,
    price1:   price1   ?? this.price1,
    time2:    time2    ?? this.time2,
    price2:   price2   ?? this.price2,
    hasAlert: hasAlert ?? this.hasAlert,
    botId:    botId    ?? this.botId,
  );

  /// Interpolates / extrapolates the line's price at a given timestamp.
  /// Works on any timeframe because it uses real time, not candle index.
  double priceAtTime(DateTime t) {
    final span = time2.millisecondsSinceEpoch - time1.millisecondsSinceEpoch;
    if (span == 0) return price1;
    final ratio = (t.millisecondsSinceEpoch - time1.millisecondsSinceEpoch) / span;
    return price1 + (price2 - price1) * ratio;
  }

  /// Returns the candle index in [candles] whose time is closest to [t].
  /// Used to convert a timestamp anchor back to a screen x-position.
  static int timeToIdx(DateTime t, List<dynamic> candles) {
    if (candles.isEmpty) return 0;
    int best = 0;
    int bestDiff = (candles[0].time.millisecondsSinceEpoch - t.millisecondsSinceEpoch).abs();
    for (int i = 1; i < candles.length; i++) {
      final diff = (candles[i].time.millisecondsSinceEpoch - t.millisecondsSinceEpoch).abs();
      if (diff < bestDiff) { bestDiff = diff; best = i; }
    }
    return best;
  }
}

// ── Horizontal Line ───────────────────────────────────────
class HorizLineData {
  final String id;
  double price;
  Color  color;
  bool   hasAlert;
  String botId;

  HorizLineData({
    required this.id,
    required this.price,
    required this.color,
    this.hasAlert = false,
    this.botId    = '',
  });

  HorizLineData copyWith({
    double? price,
    bool?   hasAlert,
    String? botId,
  }) => HorizLineData(
    id:       id,
    color:    color,
    price:    price    ?? this.price,
    hasAlert: hasAlert ?? this.hasAlert,
    botId:    botId    ?? this.botId,
  );
}

// ── Internal price range helper ───────────────────────────
class PriceRange {
  final double lo;
  final double hi;
  const PriceRange(this.lo, this.hi);
}
