// ─── services/candle_pattern_service.dart ────────────────
// Detects Bullish Engulfing (BE), Morning Star (MS), and
// Evening Star (ES) from OHLCV candle data.
// Logic ported 1-to-1 from the Pine Script v6 indicator.

import 'binance_service.dart';

// ══════════════════════════════════════════════════════════
// ─── PATTERN ENUM ────────────────────────────────────────
// ══════════════════════════════════════════════════════════
enum CandlePattern { BE, MS, ES }

extension CandlePatternExt on CandlePattern {
  String get label {
    switch (this) {
      case CandlePattern.BE: return 'Bullish Engulfing';
      case CandlePattern.MS: return 'Morning Star';
      case CandlePattern.ES: return 'Evening Star';
    }
  }

  String get shortLabel {
    switch (this) {
      case CandlePattern.BE: return 'BE';
      case CandlePattern.MS: return 'MS';
      case CandlePattern.ES: return 'ES';
    }
  }

  String get emoji {
    switch (this) {
      case CandlePattern.BE: return '🟢';
      case CandlePattern.MS: return '☀️';
      case CandlePattern.ES: return '🌙';
    }
  }

  bool get isBullish {
    switch (this) {
      case CandlePattern.BE: return true;
      case CandlePattern.MS: return true;
      case CandlePattern.ES: return false;
    }
  }

  static CandlePattern fromString(String s) {
    switch (s.toUpperCase()) {
      case 'BE': return CandlePattern.BE;
      case 'MS': return CandlePattern.MS;
      case 'ES': return CandlePattern.ES;
      default:   return CandlePattern.BE;
    }
  }
}

// ══════════════════════════════════════════════════════════
// ─── SERVICE ─────────────────────────────────────────────
// ══════════════════════════════════════════════════════════
class CandlePatternService {
  // Pine Script defaults
  static const double _starBodyPct = 30.0; // star max body % of range
  static const double _recoveryPct = 50.0; // C3 must recover this % of C1 body

  static double _body(Candle c) => (c.close - c.open).abs();
  static double _rng(Candle c)  => c.high - c.low;

  /// 14-bar SMA of high-low range ending at [endIdx] (avg_rng in Pine).
  static double _avgRng14(List<Candle> candles, int endIdx) {
    final start = (endIdx - 13).clamp(0, candles.length - 1);
    double sum = 0;
    int    cnt = 0;
    for (int i = start; i <= endIdx; i++) {
      sum += _rng(candles[i]);
      cnt++;
    }
    return cnt > 0 ? sum / cnt : 0;
  }

  /// True when candle body is ≤ starBodyPct% of its full range (is_star in Pine).
  static bool _isStar(Candle c) {
    final r = _rng(c);
    if (r == 0) return true;
    return (_body(c) / r * 100) <= _starBodyPct;
  }

  /// True when candle body is ≥ 50% of the 14-bar avg range (is_large in Pine).
  static bool _isLarge(Candle c, double avgRng) => _body(c) >= avgRng * 0.5;

  // ─────────────────────────────────────────────────────────
  // detect()
  //
  // Checks the pattern on the LAST FULLY CLOSED candle set.
  // We use [n-2] as "bar[0]" (last closed), [n-1] is the live
  // in-progress candle — same as how Pine sees the closed bars.
  //
  // Minimum candle count needed:
  //   BE:  5  (c0..c3 + 1 live)
  //   MS/ES: 7  (c0..c4 + 1 live; downtrend needs c4 & c3 & c2)
  // ─────────────────────────────────────────────────────────
  static bool detect(List<Candle> candles, CandlePattern pattern) {
    final last = candles.length - 1; // index of live candle
    if (last < 6) return false;      // need at least 7 candles for all patterns

    // c0 = last closed candle (Pine bar[0] on closed bar)
    final c0 = candles[last - 1];
    final c1 = candles[last - 2];
    final c2 = candles[last - 3];
    final c3 = candles[last - 4];
    final c4 = candles[last - 5];

    final avgRng = _avgRng14(candles, last - 1);

    switch (pattern) {

      // ── Bullish Engulfing ──────────────────────────────
      // C1: bearish  |  C0: bullish, wick-to-wick engulf
      // Prior downtrend: c3.close > c2.close > c1.close
      case CandlePattern.BE:
        final c1Bear    = c1.close < c1.open;
        final c0Bull    = c0.close > c0.open;
        final engulfs   = c0.open <= c1.low && c0.close >= c1.high;
        final downtrend = c3.close > c2.close && c2.close > c1.close;
        return c1Bear && c0Bull && engulfs && downtrend;

      // ── Morning Star ───────────────────────────────────
      // C2: large bearish  |  C1: star  |  C0: bullish recovery ≥ 50 %
      // Prior downtrend: c4.close > c3.close > c2.close
      case CandlePattern.MS:
        final c2Bear    = c2.close < c2.open && _isLarge(c2, avgRng);
        final c1Star    = _isStar(c1);
        final c0Bull    = c0.close > c0.open;
        final recovery  = c0.close >
            c2.close + (c2.open - c2.close) * (_recoveryPct / 100);
        final downtrend = c4.close > c3.close && c3.close > c2.close;
        return c2Bear && c1Star && c0Bull && recovery && downtrend;

      // ── Evening Star ───────────────────────────────────
      // C2: large bullish  |  C1: star  |  C0: bearish recovery ≥ 50 %
      // Prior uptrend: c4.close < c3.close < c2.close
      case CandlePattern.ES:
        final c2Bull   = c2.close > c2.open && _isLarge(c2, avgRng);
        final c1Star   = _isStar(c1);
        final c0Bear   = c0.close < c0.open;
        final recovery = c0.close <
            c2.close - (c2.close - c2.open) * (_recoveryPct / 100);
        final uptrend  = c4.close < c3.close && c3.close < c2.close;
        return c2Bull && c1Star && c0Bear && recovery && uptrend;
    }
  }

  /// Returns the open-time of the signal candle (c0 = last closed).
  /// Used as part of the dedup key so we don't re-alert the same bar.
  static DateTime? signalCandleTime(List<Candle> candles) {
    if (candles.length < 2) return null;
    return candles[candles.length - 2].time;
  }
}
