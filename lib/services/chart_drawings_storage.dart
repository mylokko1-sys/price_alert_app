// ─── services/chart_drawings_storage.dart ───────────────
// Persists chart drawings to SharedPreferences.
// TrendLineData is stored with timestamps (not candle indices)
// so drawings survive timeframe switches.
//
// Storage layout:
//   chart_drawings_tl_<SYMBOL>  →  JSON array of TrendLineData
//   chart_drawings_hl_<SYMBOL>  →  JSON array of HorizLineData

import 'dart:convert';
import 'dart:ui' show Color;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chart_models.dart';

class ChartDrawingsStorage {
  static const String _tlPrefix = 'chart_drawings_tl_';
  static const String _hlPrefix = 'chart_drawings_hl_';

  // ─── Save ──────────────────────────────────────────────
  static Future<void> save({
    required String              symbol,
    required List<TrendLineData> trendLines,
    required List<HorizLineData> horizLines,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_tlPrefix$symbol',
        jsonEncode(trendLines.map(_encodeTl).toList()));
    await prefs.setString('$_hlPrefix$symbol',
        jsonEncode(horizLines.map(_encodeHl).toList()));
  }

  // ─── Load one symbol ───────────────────────────────────
  static Future<DrawingsBundle> load(String symbol) async {
    final prefs = await SharedPreferences.getInstance();
    return _loadFromPrefs(prefs, symbol);
  }

  // ─── Load ALL symbols that have active alerts ──────────
  static Future<Map<String, DrawingsBundle>> loadAllWithAlerts() async {
    final prefs   = await SharedPreferences.getInstance();
    final keys    = prefs.getKeys();
    final symbols = <String>{};

    for (final key in keys) {
      if (key.startsWith(_tlPrefix)) symbols.add(key.substring(_tlPrefix.length));
      else if (key.startsWith(_hlPrefix)) symbols.add(key.substring(_hlPrefix.length));
    }

    final result = <String, DrawingsBundle>{};
    for (final sym in symbols) {
      final bundle = _loadFromPrefs(prefs, sym);
      final hasAny = bundle.trendLines.any((t) => t.hasAlert) ||
                     bundle.horizLines.any((h) => h.hasAlert);
      if (hasAny) result[sym] = bundle;
    }
    return result;
  }

  // ─── Clear ────────────────────────────────────────────
  static Future<void> clear(String symbol) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_tlPrefix$symbol');
    await prefs.remove('$_hlPrefix$symbol');
  }

  // ─── Internal ─────────────────────────────────────────
  static DrawingsBundle _loadFromPrefs(SharedPreferences prefs, String symbol) {
    List<TrendLineData> tls = [];
    List<HorizLineData> hls = [];

    final tlStr = prefs.getString('$_tlPrefix$symbol');
    if (tlStr != null && tlStr.isNotEmpty) {
      try {
        tls = (jsonDecode(tlStr) as List)
            .map((j) => _decodeTl(Map<String, dynamic>.from(j as Map)))
            .toList();
      } catch (e) { print('⚠️ chart TL parse error ($symbol): $e'); }
    }

    final hlStr = prefs.getString('$_hlPrefix$symbol');
    if (hlStr != null && hlStr.isNotEmpty) {
      try {
        hls = (jsonDecode(hlStr) as List)
            .map((j) => _decodeHl(Map<String, dynamic>.from(j as Map)))
            .toList();
      } catch (e) { print('⚠️ chart HL parse error ($symbol): $e'); }
    }

    return DrawingsBundle(trendLines: tls, horizLines: hls);
  }

  // ─── Encode ───────────────────────────────────────────
  static Map<String, dynamic> _encodeTl(TrendLineData t) => {
    'id':       t.id,
    // Store timestamps as ISO strings — timeframe-independent
    'time1':    t.time1.toIso8601String(),
    'price1':   t.price1,
    'time2':    t.time2.toIso8601String(),
    'price2':   t.price2,
    'color':    t.color.value,
    'hasAlert': t.hasAlert,
    'botId':    t.botId,
  };

  static Map<String, dynamic> _encodeHl(HorizLineData h) => {
    'id':       h.id,
    'price':    h.price,
    'color':    h.color.value,
    'hasAlert': h.hasAlert,
    'botId':    h.botId,
  };

  // ─── Decode ───────────────────────────────────────────
  static TrendLineData _decodeTl(Map<String, dynamic> j) {
    // Support old format (idx1/idx2) by falling back to epoch 0
    DateTime parseTime(String key, String fallback) {
      final raw = j[key];
      if (raw is String) return DateTime.tryParse(raw) ?? DateTime(2000);
      return DateTime(2000); // old format — line will be at chart start
    }
    return TrendLineData(
      id:       j['id']       as String,
      time1:    parseTime('time1', 'idx1'),
      price1:   (j['price1']  as num).toDouble(),
      time2:    parseTime('time2', 'idx2'),
      price2:   (j['price2']  as num).toDouble(),
      color:    Color(j['color'] as int),
      hasAlert: j['hasAlert'] as bool?   ?? false,
      botId:    j['botId']    as String? ?? '',
    );
  }

  static HorizLineData _decodeHl(Map<String, dynamic> j) => HorizLineData(
    id:       j['id']       as String,
    price:    (j['price']   as num).toDouble(),
    color:    Color(j['color'] as int),
    hasAlert: j['hasAlert'] as bool?   ?? false,
    botId:    j['botId']    as String? ?? '',
  );
}

class DrawingsBundle {
  final List<TrendLineData> trendLines;
  final List<HorizLineData> horizLines;
  const DrawingsBundle({required this.trendLines, required this.horizLines});
}
