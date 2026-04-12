// ─── screens/chart_screen.dart ──────────────────────────
// Interactive candlestick chart with full drawing persistence,
// per-line Telegram alerts, and a Bell toolbar button.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/chart_models.dart';
import '../services/binance_service.dart';
import '../services/binance_websocket_service.dart';
import '../services/telegram_service.dart';
import '../services/chart_drawings_storage.dart';

// ── Private enums (screen-only) ───────────────────────────
enum _TlHandle { p1, p2, body }

class _PriceRange {
  final double lo;
  final double hi;
  _PriceRange(this.lo, this.hi);
}

// ══════════════════════════════════════════════════════════
// CHART SCREEN
// ══════════════════════════════════════════════════════════
class ChartScreen extends StatefulWidget {
  const ChartScreen({super.key});
  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // ── Symbol / timeframe ────────────────────────────────
  late String _symbol;
  String _timeframe = '1h';

  // ── Candle data ───────────────────────────────────────
  List<Candle> _candles = [];
  bool _loading = false;
  String? _error;
  DateTime? _lastUpdated;

  // ── Live price ────────────────────────────────────────
  // WebSocket provides real-time ticks; HTTP fallback polls
  // every 30 s if the WS is disconnected.
  BinanceWebSocketService? _wsService;
  StreamSubscription<Object>? _wsSub;
  Timer? _fallbackTimer; // HTTP polling when WS is down
  bool _wsLive = false; // true when WS is connected & streaming
  double? _livePrice;
  double? _prevLivePrice;
  bool _refreshing = false;

  // ── Viewport ──────────────────────────────────────────
  static const double _rightPad = 3.0;
  static const double _priceAxisW = 66.0;
  static const double _timeAxisH = 26.0;
  static const double _hitSlop = 14.0;

  double _candleWidth = 8.0;
  double _scrollCandles = 0.0;

  // ── Auto-scale ────────────────────────────────────────
  bool _autoScale = true;
  double _manualLo = 0;
  double _manualHi = 1;

  // ── Draw tools ────────────────────────────────────────
  DrawTool _drawTool = DrawTool.cursor;
  static int _idCtr = 0; // static → unique across symbol switches

  final List<TrendLineData> _trendLines = [];
  final List<HorizLineData> _horizLines = [];

  int? _pendingIdx;
  double? _pendingPrice;
  DateTime? _pendingTime; // timestamp for first trend line anchor

  // ── Selection & Move ──────────────────────────────────
  String? _selId;
  bool _isMoving = false;
  _TlHandle? _dragHandle;
  double _dragAnchorPrice = 0;
  double _dragAnchorPrice1 = 0;
  double _dragAnchorPrice2 = 0;
  DateTime _dragAnchorTime1 = DateTime(2000);
  DateTime _dragAnchorTime2 = DateTime(2000);
  Offset _dragStartPos = Offset.zero;

  // ── Gesture tracking ──────────────────────────────────
  Offset _gStartFocal = Offset.zero;
  double _gStartCW = 8.0;
  double _gStartScroll = 0.0;
  bool _tapMoved = false;
  int _tapPointers = 1;

  // ── Crosshair ─────────────────────────────────────────
  Offset? _crosshair;
  int? _selectedIdx;
  Offset? _touchPos;

  // ── Drawings persistence (in-memory cache + SharedPrefs) ─
  final Map<String, List<TrendLineData>> _drawingsBySymbol = {};
  final Map<String, List<HorizLineData>> _horizBySymbol = {};

  // ── Alert dedup ───────────────────────────────────────
  final Set<String> _alertedLineIds = {};

  // ── Chart size ────────────────────────────────────────
  Size _chartSize = Size.zero;

  // ── Pair search ───────────────────────────────────────
  final TextEditingController _searchCtrl = TextEditingController();

  static const List<String> _timeframes = [
    '5m',
    '15m',
    '30m',
    '1h',
    '4h',
    '1d',
    '1w',
  ];

  static const List<Color> _palette = [
    Color(0xFF26C6DA),
    Color(0xFFFFB74D),
    Color(0xFFAB47BC),
    Color(0xFF66BB6A),
    Color(0xFFEF9A9A),
    Color(0xFFFFEE58),
  ];

  Color _nextColor() =>
      _palette[(_trendLines.length + _horizLines.length) % _palette.length];
  String _nextId() => '${++_idCtr}';

  // ── Default bot for new alerts ────────────────────────
  String _defaultBotId() {
    if (Config.bots.isEmpty) return '';
    try {
      return Config.bots
          .firstWhere((b) => b.isConfigured && b.canReceiveManualAlerts)
          .id;
    } catch (_) {}
    try {
      return Config.bots.firstWhere((b) => b.isConfigured).id;
    } catch (_) {
      return Config.bots.first.id;
    }
  }

  // ══════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _symbol = Config.symbols.isNotEmpty ? Config.symbols.first : 'BTCUSDT';
    _loadAllDrawingsFromStorage().then((_) {
      _fetchHistory();
      _startWebSocket();
    });
  }

  @override
  void dispose() {
    _stopWebSocket();
    _searchCtrl.dispose();
    _persistDrawings(_symbol);
    super.dispose();
  }

  // ══════════════════════════════════════════════════════
  // DATA
  // ══════════════════════════════════════════════════════

  Future<void> _fetchHistory() async {
    setState(() {
      _loading = true;
      _error = null;
      _candles = [];
      _selectedIdx = null;
      _crosshair = null;
      _livePrice = null;
      _prevLivePrice = null;
      _pendingIdx = null;
      _pendingPrice = null;
      _pendingTime = null;
      _touchPos = null;
      _selId = null;
      _isMoving = false;
    });
    try {
      final candles = await BinanceService.fetchCandlesForChart(
        _symbol,
        _timeframe,
        months: 9,
      );
      if (!mounted) return;
      setState(() {
        _candles = candles;
        _loading = false;
        _scrollCandles = 0;
        _lastUpdated = DateTime.now();
        if (_autoScale) _captureRange(candles);
      });
      await _restoreDrawings();
      // Start WebSocket now that we have candle history
      _startWebSocket();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ══════════════════════════════════════════════════════
  // WEBSOCKET — real-time live data
  // ══════════════════════════════════════════════════════

  /// Start (or restart) the WebSocket for the current symbol+timeframe.
  /// Cancels any existing connection first.
  void _startWebSocket() {
    _stopWebSocket();
    if (_candles.isEmpty) return; // wait for history first

    _wsService = BinanceWebSocketService(symbol: _symbol, interval: _timeframe);

    _wsSub = _wsService!.stream.listen(_onWsTick);
    _wsService!.connect();

    // Fallback HTTP poll every 30 s in case WS drops for a while
    _fallbackTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_wsLive) _httpFallbackRefresh();
    });

    // Mark WS as live once we get the first tick (checked in _onWsTick)
    // Initial status: not yet confirmed live
    setState(() => _wsLive = false);
  }

  void _stopWebSocket() {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _wsSub?.cancel();
    _wsSub = null;
    _wsService?.dispose();
    _wsService = null;
    _wsLive = false;
  }

  /// Called on every WebSocket message.
  void _onWsTick(Object event) {
    if (!mounted || _loading) return;

    if (!_wsLive) {
      // First tick received — mark as live, stop showing stale indicator
      setState(() {
        _wsLive = true;
        _refreshing = false;
      });
    }

    if (event is PriceTickUpdate) {
      // miniTicker → update live price & run alert check
      final prev = _prevLivePrice ?? _livePrice;
      final current = event.price;

      setState(() {
        _livePrice = current;
        _lastUpdated = DateTime.now();
      });

      if (prev != null && prev != current) {
        _prevLivePrice = prev;
        _checkDrawnLineAlerts(current, prev);
      }
      _prevLivePrice = current;
    } else if (event is CandleTickUpdate) {
      // kline tick → update the live candle in place
      final fresh = event.candle;
      setState(() {
        _lastUpdated = DateTime.now();
        final idx = _candles.indexWhere(
          (c) => c.time.isAtSameMomentAs(fresh.time),
        );
        if (idx >= 0) {
          _candles[idx] = fresh;
        } else if (_candles.isNotEmpty &&
            fresh.time.isAfter(_candles.last.time)) {
          _candles.add(fresh);
        }
        // Keep livePrice in sync with kline close too
        _livePrice = fresh.close;
      });
    }
  }

  /// HTTP fallback: only runs when WebSocket is disconnected.
  Future<void> _httpFallbackRefresh() async {
    if (_loading || _candles.isEmpty) return;
    setState(() => _refreshing = true);
    try {
      final price = await BinanceService.getCurrentPrice(_symbol);
      final recent = await BinanceService.fetchCandlesFrom(
        _symbol,
        _timeframe,
        _candles.last.time,
      );
      if (!mounted) return;

      final prev = _prevLivePrice ?? _livePrice;
      setState(() {
        if (price != null) _livePrice = price;
        _lastUpdated = DateTime.now();
        for (final c in recent) {
          final idx = _candles.indexWhere(
            (e) => e.time.isAtSameMomentAs(c.time),
          );
          if (idx >= 0) {
            _candles[idx] = c;
          } else if (c.time.isAfter(_candles.last.time)) {
            _candles.add(c);
          }
        }
        _refreshing = false;
      });

      if (price != null && prev != null) {
        _prevLivePrice = price;
        _checkDrawnLineAlerts(price, prev);
      }
    } catch (_) {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Manual refresh button — re-fetches all history and reconnects WS.
  Future<void> _manualRefresh() async {
    _stopWebSocket();
    await _fetchHistory();
    _startWebSocket();
  }

  // ══════════════════════════════════════════════════════
  // DRAWINGS PERSISTENCE
  // ══════════════════════════════════════════════════════

  Future<void> _loadAllDrawingsFromStorage() async {
    await _loadDrawingsForSymbol(_symbol);
  }

  Future<void> _loadDrawingsForSymbol(String sym) async {
    final bundle = await ChartDrawingsStorage.load(sym);
    _drawingsBySymbol[sym] = bundle.trendLines;
    _horizBySymbol[sym] = bundle.horizLines;
    // Bump ID counter so new lines never clash with saved IDs
    for (final t in bundle.trendLines) {
      final n = int.tryParse(t.id) ?? 0;
      if (n > _idCtr) _idCtr = n;
    }
    for (final h in bundle.horizLines) {
      final n = int.tryParse(h.id) ?? 0;
      if (n > _idCtr) _idCtr = n;
    }
  }

  Future<void> _persistDrawings(String sym) async {
    _drawingsBySymbol[sym] = List.from(_trendLines.map((t) => t.copyWith()));
    _horizBySymbol[sym] = List.from(_horizLines.map((h) => h.copyWith()));
    await ChartDrawingsStorage.save(
      symbol: sym,
      trendLines: _drawingsBySymbol[sym]!,
      horizLines: _horizBySymbol[sym]!,
    );
  }

  Future<void> _saveCurrentDrawings() async {
    await _persistDrawings(_symbol);
  }

  Future<void> _restoreDrawings() async {
    if (!_drawingsBySymbol.containsKey(_symbol)) {
      await _loadDrawingsForSymbol(_symbol);
    }
    if (!mounted) return;
    setState(() {
      _trendLines
        ..clear()
        ..addAll(_drawingsBySymbol[_symbol] ?? []);
      _horizLines
        ..clear()
        ..addAll(_horizBySymbol[_symbol] ?? []);
    });
    _alertedLineIds.clear();
  }

  // ══════════════════════════════════════════════════════
  // ALERT LOGIC
  // ══════════════════════════════════════════════════════

  void _checkDrawnLineAlerts(double current, double prev) {
    if (!_horizLines.any((h) => h.hasAlert) &&
        !_trendLines.any((t) => t.hasAlert))
      return;

    // Use the live candle's timestamp for trend line interpolation
    final now = _candles.isNotEmpty ? _candles.last.time : DateTime.now();

    for (final hl in List<HorizLineData>.from(_horizLines)) {
      if (!hl.hasAlert) continue;
      if (_alertedLineIds.contains(hl.id)) {
        // Reset dedup when price moves >1% away from line
        if (hl.price != 0 &&
            (current - hl.price).abs() / hl.price.abs() > 0.01) {
          _alertedLineIds.remove(hl.id);
        }
        continue;
      }
      if (_priceNearOrCrossed(current, prev, hl.price)) {
        _alertedLineIds.add(hl.id);
        _sendLineAlert(
          lineId: hl.id,
          lineType: 'h',
          lineName: 'Horizontal Line',
          linePrice: hl.price,
          current: current,
          botId: hl.botId,
        );
      }
    }

    for (final tl in List<TrendLineData>.from(_trendLines)) {
      if (!tl.hasAlert) continue;
      // Compute line price at the current time — works on any timeframe
      final linePrice = tl.priceAtTime(now);
      if (_alertedLineIds.contains(tl.id)) {
        // Reset dedup when price moves >1% away from line
        if (linePrice != 0 &&
            (current - linePrice).abs() / linePrice.abs() > 0.01) {
          _alertedLineIds.remove(tl.id);
        }
        continue;
      }
      if (_priceNearOrCrossed(current, prev, linePrice)) {
        _alertedLineIds.add(tl.id);
        _sendLineAlert(
          lineId: tl.id,
          lineType: 't',
          lineName: 'Trend Line',
          linePrice: linePrice,
          current: current,
          botId: tl.botId,
        );
      }
    }
  }

  /// Fires when price:
  ///   1. Crosses the level (from either direction), OR
  ///   2. Comes within 0.5% of it (approaching — early warning)
  bool _priceNearOrCrossed(double current, double prev, double level) {
    if (level == 0) return false;
    // Crossed
    if ((prev < level && current >= level) ||
        (prev > level && current <= level))
      return true;
    // Within 0.5% — approaching
    return (current - level).abs() / level.abs() <= 0.0001;
  }

  /// Resolves the bot, sends Telegram message, shows snackbar,
  /// then deactivates the alert on the line so it won't fire again.
  Future<void> _sendLineAlert({
    required String lineId,
    required String lineType, // 'h' | 't'
    required String
    lineName, // human-readable: 'Horizontal Line' | 'Trend Line'
    required double linePrice,
    required double current,
    required String botId,
  }) async {
    TelegramBot? bot;
    if (botId.isNotEmpty) {
      try {
        bot = Config.bots.firstWhere((b) => b.id == botId && b.isConfigured);
      } catch (_) {}
    }
    bot ??= _fallbackBot();
    if (bot == null) return;

    final ok = await TelegramService.sendDrawnLineHitAlert(
      bot: bot,
      symbol: _symbol,
      timeframe: _timeframe,
      lineType: lineName,
      linePrice: linePrice,
      currentPrice: current,
    );

    if (!mounted) return;

    // ── Auto-deactivate alert on the line after it fires ──
    // Regardless of whether Telegram succeeded, turn off the alert
    // so it doesn't fire repeatedly. The line itself is kept —
    // only the alert flag is cleared.
    _deactivateLineAlert(lineId, lineType);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              ok
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_off_rounded,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ok
                    ? '🎯 $_symbol · $lineName hit @ ${_fmtP(linePrice)} — alert removed'
                    : '⚠️ Line hit — Telegram send failed · alert removed',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
        backgroundColor: ok ? Colors.orange.shade800 : Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  TelegramBot? _fallbackBot() {
    try {
      return Config.bots.firstWhere(
        (b) => b.isConfigured && b.canReceiveManualAlerts,
      );
    } catch (_) {}
    try {
      return Config.bots.firstWhere((b) => b.isConfigured);
    } catch (_) {
      return null;
    }
  }

  // ── Activate alert on a line, storing chosen botId ────
  void _activateLineAlert(String id, String type, String botId) {
    setState(() {
      if (type == 'h') {
        final i = _horizLines.indexWhere((l) => l.id == id);
        if (i >= 0) {
          _horizLines[i] = _horizLines[i].copyWith(
            hasAlert: true,
            botId: botId,
          );
        }
      } else {
        final i = _trendLines.indexWhere((l) => l.id == id);
        if (i >= 0) {
          _trendLines[i] = _trendLines[i].copyWith(
            hasAlert: true,
            botId: botId,
          );
        }
      }
      _alertedLineIds.remove(id);
    });
    _persistDrawings(_symbol);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(
                Icons.notifications_active_rounded,
                color: Colors.white,
                size: 16,
              ),
              SizedBox(width: 8),
              Text('Alert set — fires when price hits this line'),
            ],
          ),
          backgroundColor: Colors.green.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          margin: const EdgeInsets.all(12),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _deactivateLineAlert(String id, String type) {
    setState(() {
      if (type == 'h') {
        final i = _horizLines.indexWhere((l) => l.id == id);
        if (i >= 0)
          _horizLines[i] = _horizLines[i].copyWith(hasAlert: false, botId: '');
      } else {
        final i = _trendLines.indexWhere((l) => l.id == id);
        if (i >= 0)
          _trendLines[i] = _trendLines[i].copyWith(hasAlert: false, botId: '');
      }
      _alertedLineIds.remove(id);
    });
    _persistDrawings(_symbol);
  }

  // ══════════════════════════════════════════════════════
  // COORDINATE HELPERS
  // ══════════════════════════════════════════════════════

  double get _cW => _chartSize.width - _priceAxisW;
  double get _cH => _chartSize.height - _timeAxisH;

  int get _lastVis => (_candles.isEmpty
      ? 0
      : (_candles.length - 1 - _scrollCandles).round().clamp(
          0,
          _candles.length - 1,
        ));

  double _cX(int idx) {
    final rp = _rightPad * _candleWidth;
    return _cW - rp - (_lastVis - idx) * _candleWidth - _candleWidth / 2;
  }

  double _p2y(double price, _PriceRange r) =>
      _cH * (1 - (price - r.lo) / (r.hi - r.lo));

  double _y2p(double y, _PriceRange r) => r.lo + (1 - y / _cH) * (r.hi - r.lo);

  int _x2idx(double x) {
    final rp = _rightPad * _candleWidth;
    final i = _lastVis - (_cW - rp - _candleWidth / 2 - x) / _candleWidth;
    return i.round().clamp(0, math.max(0, _candles.length - 1));
  }

  /// Convert screen x-position → the candle timestamp at that position.
  DateTime _x2time(double x) {
    if (_candles.isEmpty) return DateTime.now();
    final idx = _x2idx(x);
    return _candles[idx].time;
  }

  /// Convert a stored timestamp → nearest candle index in current candle list.
  int _timeToIdx(DateTime t) => TrendLineData.timeToIdx(t, _candles);

  /// Convert a stored timestamp → screen x-position.
  double _time2x(DateTime t) => _cX(_timeToIdx(t));

  _PriceRange _computeRange() {
    if (_candles.isEmpty) return _PriceRange(_manualLo, _manualHi);
    final vis = _getVisibleCandles();
    if (vis.isEmpty) return _PriceRange(_manualLo, _manualHi);
    var lo = vis.map((c) => c.low).reduce(math.min);
    var hi = vis.map((c) => c.high).reduce(math.max);
    if (_livePrice != null) {
      lo = math.min(lo, _livePrice!);
      hi = math.max(hi, _livePrice!);
    }
    for (final hl in _horizLines) {
      lo = math.min(lo, hl.price);
      hi = math.max(hi, hl.price);
    }
    final rng = hi - lo;
    if (rng < 1e-10) return _PriceRange(lo - 1, hi + 1);
    return _PriceRange(lo - rng * 0.07, hi + rng * 0.07);
  }

  void _captureRange(List<Candle> vis) {
    if (vis.isEmpty) return;
    var lo = vis.map((c) => c.low).reduce(math.min);
    var hi = vis.map((c) => c.high).reduce(math.max);
    final rng = hi - lo;
    if (rng < 1e-10) return;
    _manualLo = lo - rng * 0.07;
    _manualHi = hi + rng * 0.07;
  }

  List<Candle> _getVisibleCandles() {
    if (_candles.isEmpty || _chartSize == Size.zero) return _candles;
    final rp = _rightPad * _candleWidth;
    final lastV = _lastVis;
    final nVis = ((_cW - rp) / _candleWidth).ceil() + 2;
    final firstV = (lastV - nVis).clamp(0, _candles.length - 1);
    if (firstV > lastV) return [];
    return _candles.sublist(firstV, lastV + 1);
  }

  _PriceRange get _activeRange =>
      _autoScale ? _computeRange() : _PriceRange(_manualLo, _manualHi);

  // ══════════════════════════════════════════════════════
  // HIT TESTING
  // ══════════════════════════════════════════════════════

  double _ptLineDist(
    double px,
    double py,
    double x1,
    double y1,
    double x2,
    double y2,
  ) {
    final dx = x2 - x1;
    final dy = y2 - y1;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-10)
      return math.sqrt((px - x1) * (px - x1) + (py - y1) * (py - y1));
    return ((dy * px - dx * py + x2 * y1 - y2 * x1) / math.sqrt(len2)).abs();
  }

  _HitResult? _hitTest(Offset pos, _PriceRange r) {
    for (final hl in _horizLines) {
      final y = _p2y(hl.price, r);
      if ((pos.dy - y).abs() < _hitSlop && pos.dx <= _cW) {
        return _HitResult('h', hl.id, _TlHandle.body);
      }
    }
    for (final tl in _trendLines) {
      final x1 = _time2x(tl.time1);
      final y1 = _p2y(tl.price1, r);
      final x2 = _time2x(tl.time2);
      final y2 = _p2y(tl.price2, r);
      if ((pos - Offset(x1, y1)).distance < _hitSlop + 4)
        return _HitResult('t', tl.id, _TlHandle.p1);
      if ((pos - Offset(x2, y2)).distance < _hitSlop + 4)
        return _HitResult('t', tl.id, _TlHandle.p2);
      if (_ptLineDist(pos.dx, pos.dy, x1, y1, x2, y2) < _hitSlop &&
          pos.dx <= _cW) {
        return _HitResult('t', tl.id, _TlHandle.body);
      }
    }
    return null;
  }

  // ══════════════════════════════════════════════════════
  // GESTURES
  // ══════════════════════════════════════════════════════

  void _onScaleStart(ScaleStartDetails d) {
    _tapPointers = d.pointerCount;
    _tapMoved = false;
    _gStartFocal = d.localFocalPoint;
    _gStartCW = _candleWidth;
    _gStartScroll = _scrollCandles;
    _isMoving = false;
    _dragHandle = null;

    if (_candles.isEmpty || d.pointerCount > 1) return;
    if (_drawTool != DrawTool.cursor) return;

    final hit = _hitTest(d.localFocalPoint, _activeRange);
    if (hit != null) {
      _selId = hit.id;
      _isMoving = true;
      _dragHandle = hit.handle;
      _dragStartPos = d.localFocalPoint;
      if (hit.type == 'h') {
        _dragAnchorPrice = _horizLines.firstWhere((l) => l.id == hit.id).price;
      } else {
        final tl = _trendLines.firstWhere((l) => l.id == hit.id);
        _dragAnchorPrice1 = tl.price1;
        _dragAnchorPrice2 = tl.price2;
        _dragAnchorTime1 = tl.time1;
        _dragAnchorTime2 = tl.time2;
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    _tapPointers = d.pointerCount;
    _touchPos = d.localFocalPoint;
    if ((d.localFocalPoint - _gStartFocal).distance > 6 ||
        (d.scale - 1.0).abs() > 0.04) {
      _tapMoved = true;
    }

    if (d.pointerCount >= 2) {
      setState(() {
        _candleWidth = (_gStartCW * d.scale).clamp(2.0, 40.0);
        final maxScroll = (_candles.length - 5).toDouble().clamp(
          0.0,
          double.infinity,
        );
        _scrollCandles =
            (_gStartScroll +
                    (d.localFocalPoint.dx - _gStartFocal.dx) / _candleWidth)
                .clamp(0.0, maxScroll);
        _isMoving = false;
      });
      return;
    }

    if (_isMoving && _selId != null && _tapMoved) {
      final r = _activeRange;
      final priceDelta =
          -(d.localFocalPoint.dy - _dragStartPos.dy) / _cH * (r.hi - r.lo);
      // Time delta: how many milliseconds does the horizontal drag represent?
      final xDelta = d.localFocalPoint.dx - _dragStartPos.dx;
      final msDelta = _candles.length >= 2
          ? (xDelta /
                    _candleWidth *
                    (_candles.last.time.millisecondsSinceEpoch -
                        _candles[_candles.length - 2]
                            .time
                            .millisecondsSinceEpoch))
                .round()
          : 0;

      setState(() {
        final hiIdx_h = _horizLines.indexWhere((l) => l.id == _selId);
        if (hiIdx_h >= 0) {
          _horizLines[hiIdx_h] = _horizLines[hiIdx_h].copyWith(
            price: (_dragAnchorPrice + priceDelta).clamp(r.lo, r.hi),
          );
          return;
        }
        final tiIdx = _trendLines.indexWhere((l) => l.id == _selId);
        if (tiIdx < 0) return;
        final tl = _trendLines[tiIdx];
        if (_dragHandle == _TlHandle.p1) {
          _trendLines[tiIdx] = tl.copyWith(
            time1: DateTime.fromMillisecondsSinceEpoch(
              _dragAnchorTime1.millisecondsSinceEpoch + msDelta,
            ),
            price1: _dragAnchorPrice1 + priceDelta,
          );
        } else if (_dragHandle == _TlHandle.p2) {
          _trendLines[tiIdx] = tl.copyWith(
            time2: DateTime.fromMillisecondsSinceEpoch(
              _dragAnchorTime2.millisecondsSinceEpoch + msDelta,
            ),
            price2: _dragAnchorPrice2 + priceDelta,
          );
        } else {
          _trendLines[tiIdx] = tl.copyWith(
            time1: DateTime.fromMillisecondsSinceEpoch(
              _dragAnchorTime1.millisecondsSinceEpoch + msDelta,
            ),
            price1: _dragAnchorPrice1 + priceDelta,
            time2: DateTime.fromMillisecondsSinceEpoch(
              _dragAnchorTime2.millisecondsSinceEpoch + msDelta,
            ),
            price2: _dragAnchorPrice2 + priceDelta,
          );
        }
      });
      return;
    }

    if (_drawTool == DrawTool.cursor && _tapMoved && !_isMoving) {
      setState(() {
        _candleWidth = (_gStartCW * d.scale).clamp(2.0, 40.0);
        final maxScroll = (_candles.length - 5).toDouble().clamp(
          0.0,
          double.infinity,
        );
        _scrollCandles =
            (_gStartScroll +
                    (d.localFocalPoint.dx - _gStartFocal.dx) / _candleWidth)
                .clamp(0.0, maxScroll);
        _crosshair = d.localFocalPoint;
        _selectedIdx = _x2idx(d.localFocalPoint.dx);
      });
      return;
    }

    if (_drawTool != DrawTool.cursor) setState(() {});
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final wasTap = !_tapMoved && _tapPointers == 1;
    final wasMoving = _isMoving && _tapMoved;
    final tapPos = _gStartFocal;
    setState(() {
      _crosshair = null;
      _selectedIdx = null;
      _touchPos = null;
      _isMoving = false;
      _dragHandle = null;
    });
    if (wasMoving) _persistDrawings(_symbol);
    if (!wasTap) return;

    if (_drawTool == DrawTool.cursor) {
      final hit = _hitTest(tapPos, _activeRange);
      if (hit != null) {
        // Always select the line and open the actions sheet.
        // No toggle — tapping a line always shows its actions.
        setState(() => _selId = hit.id);
        _showLineActions(hit.id, hit.type);
      } else {
        // Tapped empty area → deselect
        setState(() => _selId = null);
      }
      return;
    }
    _handleDrawTap(tapPos);
  }

  // ══════════════════════════════════════════════════════
  // DRAW TAPS
  // ══════════════════════════════════════════════════════

  void _handleDrawTap(Offset pos) {
    if (_candles.isEmpty) return;
    final r = _activeRange;
    final price = _y2p(pos.dy, r);
    final time = _x2time(pos.dx); // timestamp at tap position
    if (pos.dx < 0 || pos.dx > _cW || pos.dy < 0 || pos.dy > _cH) return;

    bool didComplete = false;
    setState(() {
      if (_drawTool == DrawTool.hLine) {
        _horizLines.add(
          HorizLineData(id: _nextId(), price: price, color: _nextColor()),
        );
        _selId = _horizLines.last.id;
        _drawTool = DrawTool.cursor;
        didComplete = true;
      } else if (_drawTool == DrawTool.trendLine) {
        if (_pendingIdx == null) {
          _pendingIdx = _x2idx(pos.dx); // keep for rubber-band painter
          _pendingPrice = price;
          _pendingTime = time; // store timestamp for first anchor
        } else {
          _trendLines.add(
            TrendLineData(
              id: _nextId(),
              time1: _pendingTime!,
              price1: _pendingPrice!,
              time2: time,
              price2: price,
              color: _nextColor(),
            ),
          );
          _selId = _trendLines.last.id;
          _pendingIdx = null;
          _pendingPrice = null;
          _pendingTime = null;
          _drawTool = DrawTool.cursor;
          didComplete = true;
        }
      }
    });
    if (didComplete) _persistDrawings(_symbol);
  }

  // ══════════════════════════════════════════════════════
  // LINE ACTIONS SHEET
  // ══════════════════════════════════════════════════════

  void _showLineActions(String id, String type) {
    final isH = type == 'h';
    final hl = isH
        ? _horizLines.firstWhere(
            (l) => l.id == id,
            orElse: () => HorizLineData(id: '', price: 0, color: Colors.white),
          )
        : null;
    final tl = !isH
        ? _trendLines.firstWhere(
            (l) => l.id == id,
            orElse: () => TrendLineData(
              id: '',
              time1: DateTime(2000),
              price1: 0,
              time2: DateTime(2000),
              price2: 0,
              color: Colors.white,
            ),
          )
        : null;
    if ((hl?.id ?? tl?.id ?? '') == '') return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _LineActionsSheet(
        lineId: id,
        lineType: type,
        price: isH
            ? hl!.price
            : tl!.priceAtTime(
                _candles.isNotEmpty ? _candles.last.time : DateTime.now(),
              ),
        hasAlert: isH ? hl!.hasAlert : tl!.hasAlert,
        currentBotId: isH ? hl!.botId : tl!.botId,
        symbol: _symbol,
        onDelete: () {
          Navigator.pop(context);
          setState(() {
            _horizLines.removeWhere((l) => l.id == id);
            _trendLines.removeWhere((l) => l.id == id);
            _alertedLineIds.remove(id);
            _selId = null;
          });
          _persistDrawings(_symbol);
        },
        onSetAlert: (botId) {
          Navigator.pop(context);
          _activateLineAlert(id, type, botId);
        },
        onRemoveAlert: () {
          Navigator.pop(context);
          _deactivateLineAlert(id, type);
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════
  // BELL BUTTON — shows all lines with alert management
  // ══════════════════════════════════════════════════════

  void _openAlertManager() {
    // Ensure current symbol's latest lines are in the cache
    _drawingsBySymbol[_symbol] = List.from(
      _trendLines.map((t) => t.copyWith()),
    );
    _horizBySymbol[_symbol] = List.from(_horizLines.map((h) => h.copyWith()));

    // Pass all in-memory caches — covers every symbol opened this session
    final allTl = Map<String, List<TrendLineData>>.from(_drawingsBySymbol);
    final allHl = Map<String, List<HorizLineData>>.from(_horizBySymbol);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _AlertManagerSheet(
        currentSymbol: _symbol,
        trendLines: List.from(_trendLines),
        horizLines: List.from(_horizLines),
        allTlBySymbol: allTl,
        allHlBySymbol: allHl,
        onActivate: (id, type, botId) {
          Navigator.pop(context);
          _activateLineAlert(id, type, botId);
        },
        onDeactivate: (id, type) {
          Navigator.pop(context);
          _deactivateLineAlert(id, type);
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════
  // PAIR SELECTOR
  // ══════════════════════════════════════════════════════

  void _openPairSelector() {
    _searchCtrl.clear();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PairSheet(
        current: _symbol,
        searchCtrl: _searchCtrl,
        onSelect: (sym) async {
          Navigator.pop(context);
          if (sym != _symbol) {
            _stopWebSocket();
            await _saveCurrentDrawings();
            setState(() {
              _symbol = sym;
              _pendingIdx = null;
              _pendingPrice = null;
              _pendingTime = null;
              _selId = null;
            });
            _fetchHistory(); // will call _startWebSocket() internally
          }
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildTfBar(),
          _buildDrawToolbar(),
          Expanded(child: _buildBody()),
          _buildInfoBar(),
        ],
      ),
    );
  }

  // ── Bell button for AppBar ────────────────────────────
  Widget _buildBellButton() {
    final totalAlerts =
        _horizLines.where((h) => h.hasAlert).length +
        _trendLines.where((t) => t.hasAlert).length;
    return GestureDetector(
      onTap: _openAlertManager,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: totalAlerts > 0
                    ? Colors.orange.withOpacity(0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: totalAlerts > 0
                      ? Colors.orange.withOpacity(0.7)
                      : Colors.grey.shade700,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    totalAlerts > 0
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    size: 16,
                    color: totalAlerts > 0
                        ? Colors.orange
                        : Colors.grey.shade500,
                  ),
                  if (totalAlerts > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      '$totalAlerts',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final liveColor = _candles.isNotEmpty
        ? (_candles.last.close >= _candles.last.open
              ? const Color(0xFF26A69A)
              : const Color(0xFFEF5350))
        : Colors.grey;
    final displayPrice =
        _livePrice ?? (_candles.isNotEmpty ? _candles.last.close : null);

    return AppBar(
      backgroundColor: const Color(0xFF12121E),
      foregroundColor: Colors.white,
      elevation: 0,
      titleSpacing: 0,
      automaticallyImplyLeading: false,
      title: GestureDetector(
        onTap: _openPairSelector,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _symbol,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 3),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: Color(0xFF888899),
              ),
              const SizedBox(width: 10),
              if (displayPrice != null)
                Text(
                  _fmtP(displayPrice),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: liveColor,
                  ),
                ),
              if (_refreshing) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 8,
                  height: 8,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.blueAccent.withOpacity(0.7),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        // ── 🔔 Bell alert button ──────────────────────
        _buildBellButton(),
        // ── LIVE dot ─────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(right: 4, top: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: _wsLive
                      ? const Color(0xFF26A69A)
                      : _refreshing
                      ? Colors.orange
                      : Colors.grey,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                _wsLive ? 'LIVE' : (_refreshing ? 'SYNC' : 'OFF'),
                style: TextStyle(
                  fontSize: 7,
                  color: Colors.grey.shade600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20),
          onPressed: _loading ? null : _manualRefresh,
        ),
        const SizedBox(width: 2),
      ],
    );
  }

  Widget _buildTfBar() {
    return Container(
      color: const Color(0xFF12121E),
      height: 34,
      child: Row(
        children: [
          const SizedBox(width: 6),
          ..._timeframes.map((tf) {
            final sel = tf == _timeframe;
            return GestureDetector(
              onTap: () {
                if (tf != _timeframe) {
                  _stopWebSocket();
                  setState(() => _timeframe = tf);
                  _fetchHistory(); // will call _startWebSocket() internally
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                decoration: BoxDecoration(
                  color: sel
                      ? Colors.blueAccent.withOpacity(0.9)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: sel
                      ? null
                      : Border.all(color: const Color(0xFF2A2A40)),
                ),
                child: Text(
                  tf,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                    color: sel ? Colors.white : Colors.grey.shade500,
                  ),
                ),
              ),
            );
          }),
          const Spacer(),
          if (_lastUpdated != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                '${_p2(_lastUpdated!.hour)}:${_p2(_lastUpdated!.minute)}:${_p2(_lastUpdated!.second)}',
                style: const TextStyle(fontSize: 9, color: Color(0xFF444466)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDrawToolbar() {
    final hasLines = _trendLines.isNotEmpty || _horizLines.isNotEmpty;

    return Container(
      height: 42,
      color: const Color(0xFF0D0D1A),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          // ── Draw tools ──────────────────────────────────
          _ToolBtn(
            icon: Icons.near_me_rounded,
            label: 'Cursor',
            active: _drawTool == DrawTool.cursor,
            onTap: () => setState(() {
              _drawTool = DrawTool.cursor;
              _pendingIdx = null;
              _pendingPrice = null;
              _pendingTime = null;
            }),
          ),
          const SizedBox(width: 4),
          _ToolBtn(
            icon: Icons.show_chart_rounded,
            label: 'Trend',
            active: _drawTool == DrawTool.trendLine,
            badge: _drawTool == DrawTool.trendLine && _pendingIdx != null
                ? '1/2'
                : null,
            onTap: () => setState(() {
              _drawTool = DrawTool.trendLine;
              _pendingIdx = null;
              _pendingPrice = null;
              _pendingTime = null;
            }),
          ),
          const SizedBox(width: 4),
          _ToolBtn(
            icon: Icons.horizontal_rule_rounded,
            label: 'H-Line',
            active: _drawTool == DrawTool.hLine,
            onTap: () => setState(() {
              _drawTool = DrawTool.hLine;
              _pendingIdx = null;
              _pendingPrice = null;
              _pendingTime = null;
            }),
          ),

          const Spacer(),

          // ── Auto-scale ──────────────────────────────────
          GestureDetector(
            onTap: () {
              setState(() {
                _autoScale = !_autoScale;
                if (!_autoScale) {
                  final r = _computeRange();
                  _manualLo = r.lo;
                  _manualHi = r.hi;
                }
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _autoScale
                    ? Colors.blueAccent.withOpacity(0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: _autoScale
                      ? Colors.blueAccent.withOpacity(0.7)
                      : Colors.grey.shade700,
                ),
              ),
              child: Text(
                'Auto',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _autoScale ? Colors.blueAccent : Colors.grey.shade500,
                ),
              ),
            ),
          ),

          // ── Delete button ───────────────────────────────
          // • If a line is selected → deletes only that line
          // • If no selection      → asks confirmation then clears all
          if (hasLines) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () {
                if (_selId != null) {
                  // Delete only the selected line
                  final id = _selId!;
                  setState(() {
                    _horizLines.removeWhere((l) => l.id == id);
                    _trendLines.removeWhere((l) => l.id == id);
                    _alertedLineIds.remove(id);
                    _selId = null;
                  });
                  _persistDrawings(_symbol);
                } else {
                  // No selection → confirm clear-all
                  showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: const Color(0xFF1A1A2E),
                      title: const Text(
                        'Clear all lines?',
                        style: TextStyle(color: Colors.white, fontSize: 15),
                      ),
                      content: const Text(
                        'This will remove every trend line and horizontal line on this chart.',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: Colors.blueAccent),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text(
                            'Clear All',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                  ).then((confirmed) {
                    if (confirmed == true && mounted) {
                      setState(() {
                        _trendLines.clear();
                        _horizLines.clear();
                        _pendingIdx = null;
                        _pendingPrice = null;
                        _pendingTime = null;
                        _selId = null;
                        _alertedLineIds.clear();
                      });
                      _persistDrawings(_symbol);
                    }
                  });
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _selId != null
                      ? Colors.redAccent.withOpacity(0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: _selId != null
                        ? Colors.redAccent.withOpacity(0.6)
                        : Colors.grey.shade800,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.delete_outline_rounded,
                      size: 14,
                      color: _selId != null
                          ? Colors.redAccent
                          : Colors.grey.shade500,
                    ),
                    if (_selId != null) ...[
                      const SizedBox(width: 4),
                      const Text(
                        'Del',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.redAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                color: Colors.blueAccent,
                strokeWidth: 2,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Loading $_symbol...',
              style: const TextStyle(color: Color(0xFF555577), fontSize: 13),
            ),
            const SizedBox(height: 4),
            const Text(
              'Fetching historical data',
              style: TextStyle(color: Color(0xFF333355), fontSize: 11),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Colors.redAccent,
              size: 48,
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _fetchHistory,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      );
    }
    if (_candles.isEmpty) {
      return const Center(
        child: Text(
          'No data',
          style: TextStyle(color: Color(0xFF555577), fontSize: 14),
        ),
      );
    }

    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd: _onScaleEnd,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          _chartSize = Size(constraints.maxWidth, constraints.maxHeight);
          final r = _activeRange;
          return CustomPaint(
            painter: _ChartPainter(
              candles: _candles,
              candleWidth: _candleWidth,
              scrollCandles: _scrollCandles,
              rightPad: _rightPad,
              trendLines: List.unmodifiable(_trendLines),
              horizLines: List.unmodifiable(_horizLines),
              pendingIdx: _pendingIdx,
              pendingPrice: _pendingPrice,
              pendingScreen: (_pendingIdx != null && _touchPos != null)
                  ? _touchPos
                  : null,
              selectedId: _selId,
              rangeLo: r.lo,
              rangeHi: r.hi,
              selectedCandleIdx: _selectedIdx,
              crosshair: _crosshair,
              livePrice: _livePrice,
              drawTool: _drawTool,
            ),
            size: Size(constraints.maxWidth, constraints.maxHeight),
          );
        },
      ),
    );
  }

  Widget _buildInfoBar() {
    Candle? c;
    if (_selectedIdx != null &&
        _selectedIdx! >= 0 &&
        _selectedIdx! < _candles.length) {
      c = _candles[_selectedIdx!];
    } else if (_candles.isNotEmpty) {
      c = _candles.last;
    }
    if (c == null) return Container(color: const Color(0xFF0D0D1A), height: 38);

    final isBull = c.close >= c.open;
    final col = isBull ? const Color(0xFF26A69A) : const Color(0xFFEF5350);
    final chg = (c.close - c.open) / c.open * 100;
    final date =
        '${c.time.year}-${_p2(c.time.month)}-${_p2(c.time.day)}'
        ' ${_p2(c.time.hour)}:${_p2(c.time.minute)}';

    return Container(
      color: const Color(0xFF0D0D1A),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          Text(
            date,
            style: const TextStyle(fontSize: 9, color: Color(0xFF555577)),
          ),
          const SizedBox(width: 6),
          _ov('O', c.open, const Color(0xFF888899)),
          _ov('H', c.high, const Color(0xFF26A69A)),
          _ov('L', c.low, const Color(0xFFEF5350)),
          _ov('C', c.close, col),
          _ovVol('V', c.volume),
          const Spacer(),
          Text(
            '${chg >= 0 ? '+' : ''}${chg.toStringAsFixed(2)}%',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: col,
            ),
          ),
          const SizedBox(width: 4),
          if (_selectedIdx == null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF26A69A).withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: const Color(0xFF26A69A).withOpacity(0.4),
                ),
              ),
              child: const Text(
                'LIVE',
                style: TextStyle(
                  fontSize: 8,
                  color: Color(0xFF26A69A),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _ov(String lbl, double v, Color c) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$lbl ',
            style: const TextStyle(fontSize: 9, color: Color(0xFF555577)),
          ),
          TextSpan(
            text: _fmtP(v),
            style: TextStyle(
              fontSize: 9.5,
              color: c,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _ovVol(String lbl, double v) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$lbl ',
            style: const TextStyle(fontSize: 9, color: Color(0xFF555577)),
          ),
          TextSpan(
            text: _fmtVol(v),
            style: const TextStyle(
              fontSize: 9.5,
              color: Color(0xFF888899),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );

  String _fmtP(double v) {
    if (v >= 10000) return v.toStringAsFixed(0);
    if (v >= 100) return v.toStringAsFixed(2);
    if (v >= 1) return v.toStringAsFixed(4);
    return v.toStringAsFixed(6);
  }

  String _fmtVol(double v) {
    if (v >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}B';
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }

  String _p2(int n) => n.toString().padLeft(2, '0');
}

// ── Hit result ────────────────────────────────────────────
class _HitResult {
  final String type;
  final String id;
  final _TlHandle handle;
  _HitResult(this.type, this.id, this.handle);
}

// ══════════════════════════════════════════════════════════
// 🔔 ALERT MANAGER SHEET
// Shows all drawn lines for the current symbol and lets the
// user set/remove alerts + choose which bot fires them.
// ══════════════════════════════════════════════════════════
class _AlertManagerSheet extends StatefulWidget {
  final String currentSymbol;
  final List<TrendLineData>
  trendLines; // current symbol's lines (for All Lines tab)
  final List<HorizLineData> horizLines;
  final Map<String, List<TrendLineData>> allTlBySymbol; // all symbols
  final Map<String, List<HorizLineData>> allHlBySymbol;
  final void Function(String id, String type, String botId) onActivate;
  final void Function(String id, String type) onDeactivate;

  const _AlertManagerSheet({
    required this.currentSymbol,
    required this.trendLines,
    required this.horizLines,
    required this.allTlBySymbol,
    required this.allHlBySymbol,
    required this.onActivate,
    required this.onDeactivate,
  });

  @override
  State<_AlertManagerSheet> createState() => _AlertManagerSheetState();
}

class _AlertManagerSheetState extends State<_AlertManagerSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  late Map<String, String> _selectedBot;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _selectedBot = {};
    final defaultId = _defaultBotId();
    for (final tl in widget.trendLines) {
      _selectedBot[tl.id] = tl.botId.isNotEmpty ? tl.botId : defaultId;
    }
    for (final hl in widget.horizLines) {
      _selectedBot[hl.id] = hl.botId.isNotEmpty ? hl.botId : defaultId;
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  String _defaultBotId() {
    if (Config.bots.isEmpty) return '';
    try {
      return Config.bots
          .firstWhere((b) => b.isConfigured && b.canReceiveManualAlerts)
          .id;
    } catch (_) {}
    try {
      return Config.bots.firstWhere((b) => b.isConfigured).id;
    } catch (_) {
      return Config.bots.isEmpty ? '' : Config.bots.first.id;
    }
  }

  String _fmtP(double v) {
    if (v >= 10000) return v.toStringAsFixed(0);
    if (v >= 100) return v.toStringAsFixed(2);
    if (v >= 1) return v.toStringAsFixed(4);
    return v.toStringAsFixed(6);
  }

  String _botName(String botId) {
    try {
      return Config.bots.firstWhere((b) => b.id == botId).name;
    } catch (_) {
      return 'Unknown';
    }
  }

  /// Build entries for the current symbol's All Lines tab
  List<_LineEntry> _currentEntries() => [
    ...widget.trendLines.map(
      (tl) => _LineEntry(
        id: tl.id,
        type: 't',
        label: 'Trend Line',
        symbol: widget.currentSymbol,
        price: tl.priceAtTime(tl.time2),
        hasAlert: tl.hasAlert,
        color: tl.color,
        botId: tl.botId,
      ),
    ),
    ...widget.horizLines.map(
      (hl) => _LineEntry(
        id: hl.id,
        type: 'h',
        label: 'H-Line',
        symbol: widget.currentSymbol,
        price: hl.price,
        hasAlert: hl.hasAlert,
        color: hl.color,
        botId: hl.botId,
      ),
    ),
  ];

  /// Build entries for ALL symbols that have alerts set
  List<_LineEntry> _allActiveEntries() {
    final result = <_LineEntry>[];
    // Collect from every symbol in the cache
    final symbols = {
      ...widget.allTlBySymbol.keys,
      ...widget.allHlBySymbol.keys,
    };
    for (final sym in symbols) {
      final tls = widget.allTlBySymbol[sym] ?? [];
      final hls = widget.allHlBySymbol[sym] ?? [];
      for (final tl in tls) {
        if (tl.hasAlert) {
          result.add(
            _LineEntry(
              id: tl.id,
              type: 't',
              label: 'Trend Line',
              symbol: sym,
              price: tl.priceAtTime(tl.time2),
              hasAlert: true,
              color: tl.color,
              botId: tl.botId,
            ),
          );
        }
      }
      for (final hl in hls) {
        if (hl.hasAlert) {
          result.add(
            _LineEntry(
              id: hl.id,
              type: 'h',
              label: 'H-Line',
              symbol: sym,
              price: hl.price,
              hasAlert: true,
              color: hl.color,
              botId: hl.botId,
            ),
          );
        }
      }
    }
    // Sort: current symbol first, then alphabetically
    result.sort((a, b) {
      if (a.symbol == widget.currentSymbol && b.symbol != widget.currentSymbol)
        return -1;
      if (b.symbol == widget.currentSymbol && a.symbol != widget.currentSymbol)
        return 1;
      final sc = a.symbol.compareTo(b.symbol);
      return sc != 0 ? sc : a.price.compareTo(b.price);
    });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final bots = Config.bots.where((b) => b.isConfigured).toList();
    final allActive = _allActiveEntries();
    final allCurrent = _currentEntries();
    final inactive = allCurrent.where((e) => !e.hasAlert).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade700,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),

            // ── Header ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(
                    Icons.notifications_active_rounded,
                    color: Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Line Alerts',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (allActive.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.orange.withOpacity(0.5),
                        ),
                      ),
                      child: Text(
                        '${allActive.length} active',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // ── Tabs ────────────────────────────────────────
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              decoration: BoxDecoration(
                color: const Color(0xFF12121E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: TabBar(
                controller: _tabCtrl,
                indicator: BoxDecoration(
                  color: Colors.orange.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.withOpacity(0.5)),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                labelColor: Colors.orange,
                unselectedLabelColor: Colors.grey.shade500,
                labelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
                tabs: [
                  Tab(text: '🔔 Active (${allActive.length})'),
                  Tab(
                    text: '📋 ${widget.currentSymbol} (${allCurrent.length})',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 4),
            const Divider(color: Color(0xFF2A2A40), height: 1),

            // ── Tab views ───────────────────────────────────
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  // ══════════════════════════════════════════
                  // Tab 0: ALL ACTIVE ALERTS (all symbols)
                  // ══════════════════════════════════════════
                  allActive.isEmpty
                      ? _buildEmptyState(
                          icon: Icons.notifications_off_rounded,
                          title: 'No active alerts',
                          subtitle:
                              'Switch to the "${widget.currentSymbol}" tab\nand toggle any line to activate.',
                        )
                      : ListView.builder(
                          controller: ctrl,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          itemCount: allActive.length,
                          itemBuilder: (_, i) {
                            final entry = allActive[i];
                            final botId = entry.botId;
                            return _ActiveAlertCard(
                              entry: entry,
                              botName: botId.isNotEmpty
                                  ? _botName(botId)
                                  : 'No bot',
                              fmtP: _fmtP,
                              // Only allow remove for current symbol's lines
                              onRemove: entry.symbol == widget.currentSymbol
                                  ? () => widget.onDeactivate(
                                      entry.id,
                                      entry.type,
                                    )
                                  : null,
                            );
                          },
                        ),

                  // ══════════════════════════════════════════
                  // Tab 1: ALL LINES on current symbol
                  // ══════════════════════════════════════════
                  allCurrent.isEmpty
                      ? _buildEmptyState(
                          icon: Icons.show_chart_rounded,
                          title: 'No lines on ${widget.currentSymbol}',
                          subtitle:
                              'Draw a Trend Line or H-Line\non the chart first.',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          itemCount: allCurrent.length + (bots.isEmpty ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (bots.isEmpty && i == 0)
                              return _buildNoBotWarning();
                            final idx = bots.isEmpty ? i - 1 : i;
                            final entry = allCurrent[idx];
                            final botId = _selectedBot[entry.id] ?? '';
                            return _LineAlertTile(
                              entry: entry,
                              botId: botId,
                              botName: botId.isNotEmpty ? _botName(botId) : '—',
                              bots: bots,
                              fmtP: _fmtP,
                              onBotChanged: (v) =>
                                  setState(() => _selectedBot[entry.id] = v),
                              onToggle: () {
                                if (entry.hasAlert) {
                                  widget.onDeactivate(entry.id, entry.type);
                                } else {
                                  widget.onActivate(
                                    entry.id,
                                    entry.type,
                                    _selectedBot[entry.id] ?? '',
                                  );
                                }
                              },
                            );
                          },
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 52, color: Colors.grey.shade800),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _buildNoBotWarning() => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.orange.withOpacity(0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.orange.withOpacity(0.35)),
    ),
    child: const Row(
      children: [
        Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'No configured Telegram bots found. Add one in Bot Settings.',
            style: TextStyle(fontSize: 12, color: Colors.orange),
          ),
        ),
      ],
    ),
  );
}

// ── Active alert card (Tab 0) ─────────────────────────────
class _ActiveAlertCard extends StatelessWidget {
  final _LineEntry entry;
  final String botName;
  final String Function(double) fmtP;
  final VoidCallback? onRemove; // null = from another symbol, can't remove here

  const _ActiveAlertCard({
    required this.entry,
    required this.botName,
    required this.fmtP,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isH = entry.type == 'h';
    final canRemove = onRemove != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF12121E),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: Colors.orange, width: 3)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            // Icon
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                isH ? Icons.horizontal_rule_rounded : Icons.show_chart_rounded,
                color: Colors.orange,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Symbol badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blueAccent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          entry.symbol,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        entry.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '@ ${fmtP(entry.price)}',
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        Icons.smart_toy_rounded,
                        size: 11,
                        color: Colors.grey.shade600,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        botName,
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          '🔔 Active',
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Colors.orange,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(width: 8),

            // Remove button or "other pair" hint
            canRemove
                ? GestureDetector(
                    onTap: onRemove,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withOpacity(0.3)),
                      ),
                      child: const Text(
                        'Remove',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.redAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                : Tooltip(
                    message: 'Switch to ${entry.symbol} to remove',
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.withOpacity(0.2)),
                      ),
                      child: Icon(
                        Icons.lock_outline_rounded,
                        size: 14,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

// ── Entry model for the alert manager ────────────────────
class _LineEntry {
  final String id;
  final String type; // 'h' | 't'
  final String label;
  final String symbol; // which trading pair this line belongs to
  final double price;
  final bool hasAlert;
  final Color color;
  final String botId;
  const _LineEntry({
    required this.id,
    required this.type,
    required this.label,
    required this.symbol,
    required this.price,
    required this.hasAlert,
    required this.color,
    required this.botId,
  });
}

// ── Single row in the alert manager ──────────────────────
class _LineAlertTile extends StatelessWidget {
  final _LineEntry entry;
  final String botId;
  final String botName;
  final List<TelegramBot> bots;
  final String Function(double) fmtP;
  final void Function(String) onBotChanged;
  final VoidCallback onToggle;

  const _LineAlertTile({
    required this.entry,
    required this.botId,
    required this.botName,
    required this.bots,
    required this.fmtP,
    required this.onBotChanged,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = entry.hasAlert;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF12121E),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(
            color: isActive ? Colors.orange : entry.color,
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Line info row ────────────────────────────────
          Row(
            children: [
              Icon(
                entry.type == 'h'
                    ? Icons.horizontal_rule_rounded
                    : Icons.show_chart_rounded,
                color: entry.color,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                entry.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Text(
                fmtP(entry.price),
                style: TextStyle(
                  color: isActive ? Colors.orange : Colors.grey.shade400,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 12),
              // Alert toggle switch
              Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: isActive,
                  onChanged: (_) => onToggle(),
                  activeColor: Colors.orange,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),

          // ── Bot picker (only shown when alert is active or being set) ──
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.smart_toy_rounded,
                size: 13,
                color: Colors.grey.shade500,
              ),
              const SizedBox(width: 6),
              const Text(
                'Bot:',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: bots.isEmpty
                    ? Text(
                        'No bots configured',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade400,
                        ),
                      )
                    : DropdownButton<String>(
                        value: bots.any((b) => b.id == botId)
                            ? botId
                            : bots.first.id,
                        isDense: true,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF1A1A2E),
                        underline: Container(
                          height: 1,
                          color: const Color(0xFF2A2A40),
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                        icon: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: Colors.grey.shade500,
                        ),
                        onChanged: (v) {
                          if (v != null) onBotChanged(v);
                        },
                        items: bots
                            .map(
                              (bot) => DropdownMenuItem(
                                value: bot.id,
                                child: Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: bot.isConfigured
                                            ? Colors.green
                                            : Colors.orange,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      bot.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                      ),
              ),
            ],
          ),

          // ── Status chip ──────────────────────────────────
          if (isActive) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.orange.withOpacity(0.4)),
                  ),
                  child: const Text(
                    '🔔 Alert active — fires on price hit',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.orange,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// LINE ACTIONS SHEET (tap a line → this appears)
// ══════════════════════════════════════════════════════════
class _LineActionsSheet extends StatefulWidget {
  final String lineId;
  final String lineType;
  final double price;
  final bool hasAlert;
  final String currentBotId;
  final String symbol;
  final VoidCallback onDelete;
  final Function(String botId) onSetAlert;
  final VoidCallback onRemoveAlert;

  const _LineActionsSheet({
    required this.lineId,
    required this.lineType,
    required this.price,
    required this.hasAlert,
    required this.currentBotId,
    required this.symbol,
    required this.onDelete,
    required this.onSetAlert,
    required this.onRemoveAlert,
  });

  @override
  State<_LineActionsSheet> createState() => _LineActionsSheetState();
}

class _LineActionsSheetState extends State<_LineActionsSheet> {
  late String _selectedBotId;

  @override
  void initState() {
    super.initState();
    _selectedBotId = widget.currentBotId.isNotEmpty
        ? widget.currentBotId
        : _defaultBot();
  }

  String _defaultBot() {
    if (Config.bots.isEmpty) return '';
    try {
      return Config.bots
          .firstWhere((b) => b.isConfigured && b.canReceiveManualAlerts)
          .id;
    } catch (_) {}
    try {
      return Config.bots.firstWhere((b) => b.isConfigured).id;
    } catch (_) {
      return Config.bots.first.id;
    }
  }

  String _fmtP(double v) {
    if (v >= 10000) return v.toStringAsFixed(0);
    if (v >= 100) return v.toStringAsFixed(2);
    if (v >= 1) return v.toStringAsFixed(4);
    return v.toStringAsFixed(6);
  }

  @override
  Widget build(BuildContext context) {
    final bots = Config.bots.where((b) => b.isConfigured).toList();
    if (bots.isNotEmpty && !bots.any((b) => b.id == _selectedBotId)) {
      _selectedBotId = bots.first.id;
    }

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade700,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // ── Title ─────────────────────────────────
              Row(
                children: [
                  Icon(
                    widget.lineType == 'h'
                        ? Icons.horizontal_rule_rounded
                        : Icons.show_chart_rounded,
                    color: Colors.blueAccent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.lineType == 'h' ? 'Horizontal Line' : 'Trend Line',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _fmtP(widget.price),
                    style: const TextStyle(
                      color: Color(0xFF26A69A),
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.symbol,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
              ),

              const SizedBox(height: 16),
              const Divider(color: Color(0xFF2A2A40), height: 1),
              const SizedBox(height: 14),

              // ── Alert section ─────────────────────────
              Row(
                children: [
                  Icon(
                    Icons.notifications_rounded,
                    size: 15,
                    color: widget.hasAlert
                        ? Colors.orange
                        : Colors.grey.shade500,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.hasAlert ? 'Alert active' : 'Set price alert',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: widget.hasAlert ? Colors.orange : Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.hasAlert
                    ? 'Telegram alert fires when live price hits this line.'
                    : 'Choose a bot and activate to get notified when price hits this line.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 14),

              if (!widget.hasAlert) ...[
                // ── Bot selector ─────────────────────────
                if (bots.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.withOpacity(0.4)),
                    ),
                    child: const Text(
                      'No configured Telegram bots. Add one in Bot settings.',
                      style: TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  )
                else ...[
                  const Text(
                    'Send alert via:',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFF888899),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...bots.map(
                    (bot) => GestureDetector(
                      onTap: () => setState(() => _selectedBotId = bot.id),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 130),
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: _selectedBotId == bot.id
                              ? Colors.blueAccent.withOpacity(0.1)
                              : const Color(0xFF12121E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _selectedBotId == bot.id
                                ? Colors.blueAccent.withOpacity(0.5)
                                : const Color(0xFF2A2A40),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: bot.isConfigured
                                    ? Colors.green
                                    : Colors.orange,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Icon(
                              Icons.smart_toy_rounded,
                              size: 14,
                              color: _selectedBotId == bot.id
                                  ? Colors.blueAccent
                                  : Colors.grey.shade500,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                bot.name,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _selectedBotId == bot.id
                                      ? Colors.white
                                      : Colors.grey.shade400,
                                ),
                              ),
                            ),
                            if (_selectedBotId == bot.id)
                              const Icon(
                                Icons.check_rounded,
                                size: 15,
                                color: Colors.blueAccent,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton.icon(
                      onPressed: bots.isEmpty
                          ? null
                          : () => widget.onSetAlert(_selectedBotId),
                      icon: const Icon(
                        Icons.notifications_active_rounded,
                        size: 16,
                      ),
                      label: const Text(
                        'Activate Alert',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ] else ...[
                // ── Active alert info ────────────────────
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.orange.withOpacity(0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.notifications_active_rounded,
                        size: 14,
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Alert is active',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.currentBotId.isNotEmpty
                                  ? 'Sending to: ${Config.bots.where((b) => b.id == widget.currentBotId).map((b) => b.name).firstOrNull ?? "Unknown"}'
                                  : 'Bot not assigned',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: widget.onRemoveAlert,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: Colors.red.withOpacity(0.3),
                            ),
                          ),
                          child: const Text(
                            'Remove',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.redAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),
              const Divider(color: Color(0xFF2A2A40), height: 1),
              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                height: 42,
                child: OutlinedButton.icon(
                  onPressed: widget.onDelete,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 16,
                    color: Colors.redAccent,
                  ),
                  label: const Text(
                    'Delete Line',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.redAccent.withOpacity(0.4)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// TOOL BUTTON
// ══════════════════════════════════════════════════════════
class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final String? badge;

  const _ToolBtn({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active
                ? Colors.blueAccent.withOpacity(0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: active
                  ? Colors.blueAccent.withOpacity(0.7)
                  : Colors.grey.shade800,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: active ? Colors.blueAccent : Colors.grey.shade500,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.blueAccent : Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
        if (badge != null)
          Positioned(
            top: -4,
            right: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.orange,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                badge!,
                style: const TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

// ══════════════════════════════════════════════════════════
// PAIR SELECTOR SHEET
// ══════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════
// PAIR SELECTOR SHEET — searches all Binance symbols
// ══════════════════════════════════════════════════════════
class _PairSheet extends StatefulWidget {
  final String current;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSelect;
  const _PairSheet({
    required this.current,
    required this.searchCtrl,
    required this.onSelect,
  });
  @override
  State<_PairSheet> createState() => _PairSheetState();
}

class _PairSheetState extends State<_PairSheet> {
  String _query = '';

  // Full Binance symbol list — loaded once, cached in static field
  static List<String> _allBinanceSymbols = [];
  static bool _symbolsLoaded = false;
  static bool _symbolsLoading = false;

  bool _searching = false; // spinner while fetching

  // Popular pairs shown before the user types anything
  static const List<String> _popular = [
    'BTCUSDT',
    'ETHUSDT',
    'SOLUSDT',
    'BNBUSDT',
    'XRPUSDT',
    'DOGEUSDT',
    'ADAUSDT',
    'AVAXUSDT',
    'DOTUSDT',
    'LINKUSDT',
    'MATICUSDT',
    'LTCUSDT',
    'UNIUSDT',
    'ATOMUSDT',
    'NEARUSDT',
    'APTUSDT',
    'ARBUSDT',
    'OPUSDT',
    'SUIUSDT',
    'SEIUSDT',
    'INJUSDT',
    'TIAUSDT',
    'WIFUSDT',
    'BONKUSDT',
    'PEPEUSDT',
    'TRXUSDT',
    'FTMUSDT',
    'LDOUSDT',
    'STXUSDT',
    'RUNEUSDT',
    'ETHBTC',
    'BNBBTC',
    'SOLUSDT',
    'XRPUSDT',
    'TONUSDT',
    'SHIBUSDT',
    'LTCUSDT',
    'BCHUSDT',
    'FILUSDT',
    'VETUSDT',
  ];

  @override
  void initState() {
    super.initState();
    // Load full symbol list in background on first open
    if (!_symbolsLoaded && !_symbolsLoading) {
      _fetchAllSymbols();
    }
  }

  Future<void> _fetchAllSymbols() async {
    if (_symbolsLoading || _symbolsLoaded) return;
    _symbolsLoading = true;
    if (mounted) setState(() => _searching = true);
    try {
      final uri = Uri.parse('https://api.binance.com/api/v3/exchangeInfo');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final symbols =
            (body['symbols'] as List)
                .where((s) => s['status'] == 'TRADING')
                .map((s) => s['symbol'] as String)
                .toList()
              ..sort();
        _allBinanceSymbols = symbols;
        _symbolsLoaded = true;
      }
    } catch (_) {
      // Silently fail — we'll still show the popular list
    } finally {
      _symbolsLoading = false;
      if (mounted) setState(() => _searching = false);
    }
  }

  List<String> get _displaySymbols {
    // Merge watchlist + popular into a base list
    final base = {...Config.symbols, ..._popular}.toList();

    if (_query.isEmpty) return base;

    final q = _query.toUpperCase();

    // When typing, search the full Binance list (if loaded)
    // Priority: exact start match → contains match
    final searchPool = _symbolsLoaded ? _allBinanceSymbols : base;
    final startMatch = searchPool.where((s) => s.startsWith(q)).toList();
    final contains = searchPool
        .where((s) => s.contains(q) && !s.startsWith(q))
        .toList();
    final results = [...startMatch, ...contains];

    // Always show watchlist matches at the very top
    final wl = Config.symbols.where((s) => s.contains(q)).toList();
    final combined = {...wl, ...results}.toList();

    return combined.take(80).toList(); // cap at 80 for performance
  }

  @override
  Widget build(BuildContext context) {
    final symbols = _displaySymbols;

    return DraggableScrollableSheet(
      initialChildSize: 0.80,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF12121E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade700,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),

            // ── Header ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Text(
                    'Select Pair',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Symbol count badge
                  if (_symbolsLoaded)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blueAccent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_allBinanceSymbols.length} pairs',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.blueAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  else if (_symbolsLoading || _searching)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.blueAccent,
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // ── Search field ─────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: TextField(
                controller: widget.searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                ],
                decoration: InputDecoration(
                  hintText: 'Search any pair — e.g. BTC, ETH, SOL…',
                  hintStyle: const TextStyle(
                    color: Color(0xFF555577),
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Color(0xFF555577),
                    size: 20,
                  ),
                  suffixIcon: _query.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            widget.searchCtrl.clear();
                            setState(() => _query = '');
                          },
                          child: const Icon(
                            Icons.close,
                            color: Color(0xFF555577),
                            size: 18,
                          ),
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFF1A1A2E),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF2A2A40)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF2A2A40)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(
                      color: Colors.blueAccent,
                      width: 1.5,
                    ),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (v) {
                  final s = v.trim().toUpperCase();
                  if (s.isNotEmpty) widget.onSelect(s);
                },
              ),
            ),

            // ── Section label ────────────────────────────────
            if (_query.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  children: [
                    Text(
                      'Popular pairs',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Divider(color: Colors.grey.shade800, height: 1),
                    ),
                  ],
                ),
              )
            else if (symbols.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  children: [
                    Text(
                      '${symbols.length} results for "$_query"',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (!_symbolsLoaded && !_symbolsLoading)
                      GestureDetector(
                        onTap: _fetchAllSymbols,
                        child: const Text(
                          'Load all pairs →',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.blueAccent,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

            // ── Results list ──────────────────────────────────
            Expanded(
              child: symbols.isEmpty && _query.isNotEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.search_off_rounded,
                            color: Color(0xFF444466),
                            size: 44,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'No results for "$_query"',
                            style: const TextStyle(color: Color(0xFF555577)),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: () {
                              final s = _query.trim().toUpperCase();
                              if (s.isNotEmpty) widget.onSelect(s);
                            },
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 14,
                            ),
                            label: Text('Open "$_query" anyway'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueAccent,
                              foregroundColor: Colors.white,
                              textStyle: const TextStyle(fontSize: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: ctrl,
                      itemCount: symbols.length,
                      itemBuilder: (_, i) {
                        final sym = symbols[i];
                        final isCur = sym == widget.current;
                        final isWL = Config.symbols.contains(sym);
                        final base = sym.replaceAll(
                          RegExp(r'(USDT|BUSD|BTC|ETH|BNB|EUR|TRY)$'),
                          '',
                        );

                        return ListTile(
                          dense: true,
                          onTap: () => widget.onSelect(sym),
                          leading: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: isCur
                                  ? Colors.blueAccent.withOpacity(0.2)
                                  : const Color(0xFF1A1A2E),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              base.isNotEmpty ? base[0] : sym[0],
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: isCur
                                    ? Colors.blueAccent
                                    : Colors.grey.shade500,
                              ),
                            ),
                          ),
                          title: Row(
                            children: [
                              // Base currency in white
                              Text(
                                base.isNotEmpty ? base : sym,
                                style: TextStyle(
                                  color: isCur
                                      ? Colors.blueAccent
                                      : Colors.white,
                                  fontWeight: isCur
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                  fontSize: 14,
                                ),
                              ),
                              // Quote currency dimmed
                              Text(
                                sym.substring(base.length),
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 12,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                              const SizedBox(width: 6),
                              if (isWL)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.blueAccent.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'WL',
                                    style: TextStyle(
                                      fontSize: 8,
                                      color: Colors.blueAccent,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          trailing: isCur
                              ? const Icon(
                                  Icons.check_rounded,
                                  color: Colors.blueAccent,
                                  size: 18,
                                )
                              : const Icon(
                                  Icons.arrow_forward_ios_rounded,
                                  color: Color(0xFF333355),
                                  size: 13,
                                ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// CUSTOM PAINTER
// ══════════════════════════════════════════════════════════
class _ChartPainter extends CustomPainter {
  final List<Candle> candles;
  final double candleWidth;
  final double scrollCandles;
  final double rightPad;
  final List<TrendLineData> trendLines;
  final List<HorizLineData> horizLines;
  final int? pendingIdx;
  final double? pendingPrice;
  final Offset? pendingScreen;
  final String? selectedId;
  final double rangeLo;
  final double rangeHi;
  final int? selectedCandleIdx;
  final Offset? crosshair;
  final double? livePrice;
  final DrawTool drawTool;

  const _ChartPainter({
    required this.candles,
    required this.candleWidth,
    required this.scrollCandles,
    required this.rightPad,
    required this.trendLines,
    required this.horizLines,
    required this.rangeLo,
    required this.rangeHi,
    this.pendingIdx,
    this.pendingPrice,
    this.pendingScreen,
    this.selectedId,
    this.selectedCandleIdx,
    this.crosshair,
    this.livePrice,
    this.drawTool = DrawTool.cursor,
  });

  static const double _priceW = 66.0;
  static const double _timeH = 26.0;
  static const Color _bull = Color(0xFF26A69A);
  static const Color _bear = Color(0xFFEF5350);
  static const Color _grid = Color(0xFF181828);
  static const Color _axis = Color(0xFF555575);

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;
    final cW = size.width - _priceW;
    final cH = size.height - _timeH;
    final rp = rightPad * candleWidth;

    final lastVis = (candles.length - 1 - scrollCandles).round().clamp(
      0,
      candles.length - 1,
    );
    final nVis = ((cW - rp) / candleWidth).ceil() + 2;
    final firstVis = (lastVis - nVis).clamp(0, candles.length - 1);
    if (firstVis > lastVis) return;

    final lo = rangeLo;
    final hi = rangeHi;
    if ((hi - lo).abs() < 1e-10) return;

    double cX(int i) => cW - rp - (lastVis - i) * candleWidth - candleWidth / 2;
    double p2y(double p) => cH * (1 - (p - lo) / (hi - lo));

    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF0A0A14),
    );

    // Grid
    final gp = Paint()
      ..color = _grid
      ..strokeWidth = 0.5;
    for (int i = 0; i <= 6; i++) {
      canvas.drawLine(Offset(0, cH * i / 6), Offset(cW, cH * i / 6), gp);
    }
    if (lastVis > firstVis) {
      final ts = math.max(1, (lastVis - firstVis) ~/ (cW ~/ 80).clamp(1, 12));
      for (int i = firstVis; i <= lastVis; i += ts) {
        final x = cX(i);
        if (x > 0 && x < cW) canvas.drawLine(Offset(x, 0), Offset(x, cH), gp);
      }
    }
    canvas.drawLine(
      Offset(cW, 0),
      Offset(cW, size.height),
      Paint()
        ..color = const Color(0xFF1E1E35)
        ..strokeWidth = 1,
    );

    // Horizontal lines
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, cW, cH));
    for (final hl in horizLines) {
      final y = p2y(hl.price);
      if (y < -1 || y > cH + 1) continue;
      final sel = hl.id == selectedId;
      _dashH(
        canvas,
        y,
        cW,
        sel ? Colors.white : hl.color,
        dash: 8,
        gap: 5,
        width: sel ? 1.8 : 1.1,
      );
      if (sel) {
        _dashH(
          canvas,
          y,
          cW,
          hl.color.withOpacity(0.3),
          dash: 8,
          gap: 5,
          width: 5,
        );
        _drawHandle(canvas, Offset(cW / 2, y), hl.color, sel: true);
      }
      if (hl.hasAlert) {
        // Orange dot = active alert
        canvas.drawCircle(
          Offset(20, y),
          5,
          Paint()
            ..color = Colors.orange
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          Offset(20, y),
          7,
          Paint()
            ..color = Colors.orange.withOpacity(0.25)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
    canvas.restore();

    // Trend lines
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, cW, cH));
    for (final tl in trendLines) {
      // Convert timestamps to candle indices for screen position
      final idx1 = TrendLineData.timeToIdx(tl.time1, candles);
      final idx2 = TrendLineData.timeToIdx(tl.time2, candles);
      final x1 = cX(idx1);
      final y1 = p2y(tl.price1);
      final x2 = cX(idx2);
      final y2 = p2y(tl.price2);
      final sel = tl.id == selectedId;
      _drawExtLine(
        canvas,
        cW,
        cH,
        x1,
        y1,
        x2,
        y2,
        sel ? Colors.white : tl.color,
        width: sel ? 1.8 : 1.3,
        glow: sel ? tl.color : null,
      );
      for (final pt in [Offset(x1, y1), Offset(x2, y2)]) {
        _drawHandle(canvas, pt, tl.color, sel: sel);
      }
      if (tl.hasAlert) {
        final mx = (x1 + x2) / 2;
        final my = (y1 + y2) / 2;
        if (mx >= 0 && mx <= cW) {
          canvas.drawCircle(
            Offset(mx, my),
            5,
            Paint()
              ..color = Colors.orange
              ..style = PaintingStyle.fill,
          );
          canvas.drawCircle(
            Offset(mx, my),
            7,
            Paint()
              ..color = Colors.orange.withOpacity(0.25)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
        }
      }
    }
    canvas.restore();

    // Candles
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, cW, cH));
    for (int i = firstVis; i <= lastVis; i++) {
      final c = candles[i];
      final x = cX(i);
      if (x < -candleWidth * 2 || x > cW + candleWidth) continue;
      final isBull = c.close >= c.open;
      final isLive = i == candles.length - 1;
      final col = isLive
          ? (isBull ? const Color(0xFF00C8B4) : const Color(0xFFFF5252))
          : (isBull ? _bull : _bear);
      final wickW = math.max(candleWidth * 0.12, 1.0);
      final bodyW = math.max(candleWidth * 0.65, 1.0);
      canvas.drawLine(
        Offset(x, p2y(c.high)),
        Offset(x, p2y(c.low)),
        Paint()
          ..color = col
          ..strokeWidth = wickW,
      );
      final bTop = p2y(math.max(c.open, c.close));
      final bBot = p2y(math.min(c.open, c.close));
      final bodyH = math.max(bBot - bTop, 1.0);
      canvas.drawRect(
        Rect.fromLTWH(x - bodyW / 2, bTop, bodyW, bodyH),
        Paint()..color = col,
      );
      if (i == selectedCandleIdx) {
        canvas.drawRect(
          Rect.fromLTWH(x - bodyW / 2 - 1.5, bTop - 1.5, bodyW + 3, bodyH + 3),
          Paint()
            ..color = Colors.white.withOpacity(0.25)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }
      if (isLive) {
        canvas.drawRect(
          Rect.fromLTWH(x - bodyW / 2 - 1, bTop - 1, bodyW + 2, bodyH + 2),
          Paint()
            ..color = col.withOpacity(0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8,
        );
      }
    }
    canvas.restore();

    // Pending rubber-band
    if (pendingIdx != null && pendingPrice != null) {
      final x1 = cX(pendingIdx!);
      final y1 = p2y(pendingPrice!);
      canvas.drawCircle(
        Offset(x1, y1),
        5,
        Paint()
          ..color = Colors.cyan
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        Offset(x1, y1),
        5,
        Paint()
          ..color = Colors.white.withOpacity(0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      if (pendingScreen != null) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, cW, cH));
        canvas.drawLine(
          Offset(x1, y1),
          pendingScreen!,
          Paint()
            ..color = Colors.cyan.withOpacity(0.6)
            ..strokeWidth = 1.5
            ..isAntiAlias = true,
        );
        canvas.restore();
      }
    }

    // Live price line
    final dispP = livePrice ?? candles.last.close;
    final lpY = p2y(dispP);
    if (lpY >= 0 && lpY <= cH) {
      final isBull = candles.last.close >= candles.last.open;
      _dashH(
        canvas,
        lpY,
        cW,
        (isBull ? _bull : _bear).withOpacity(0.45),
        dash: 3,
        gap: 6,
      );
      _drawPriceBox(
        canvas,
        cW,
        lpY,
        dispP,
        Colors.white,
        isBull ? const Color(0xFF1A3A38) : const Color(0xFF3A1A1A),
      );
    }

    // Crosshair
    if (crosshair != null && crosshair!.dx >= 0 && crosshair!.dx <= cW) {
      final xp = Paint()
        ..color = Colors.white.withOpacity(0.2)
        ..strokeWidth = 0.8;
      canvas.drawLine(Offset(crosshair!.dx, 0), Offset(crosshair!.dx, cH), xp);
      if (crosshair!.dy >= 0 && crosshair!.dy <= cH) {
        canvas.drawLine(
          Offset(0, crosshair!.dy),
          Offset(cW, crosshair!.dy),
          xp,
        );
        final chP = lo + (1 - crosshair!.dy / cH) * (hi - lo);
        _drawPriceBox(
          canvas,
          cW,
          crosshair!.dy,
          chP,
          Colors.white.withOpacity(0.9),
          const Color(0xFF222240),
        );
      }
    }

    // Price axis
    for (int i = 0; i <= 6; i++) {
      final y = cH * i / 6;
      final pr = lo + (1 - i / 6) * (hi - lo);
      _pt(_fmtP(pr), _axis, 9.0, canvas, Offset(cW + 4, y - 5));
    }

    // H-line axis tags
    for (final hl in horizLines) {
      final y = p2y(hl.price);
      if (y < -10 || y > cH + 10) continue;
      _drawTagBox(
        canvas,
        cW,
        y.clamp(4.0, cH - 14.0),
        hl.price,
        hl.id == selectedId ? Colors.white : hl.color,
        hasAlert: hl.hasAlert,
      );
    }

    // Time axis
    final totalVis = lastVis - firstVis + 1;
    final step = math.max(1, totalVis ~/ 6);
    for (int i = firstVis; i <= lastVis; i += step) {
      final x = cX(i);
      if (x < 8 || x > cW - 8) continue;
      final tp = _mkTP(_fmtT(candles[i].time), _axis, 9.0);
      tp.paint(
        canvas,
        Offset((x - tp.width / 2).clamp(0.0, cW - tp.width), cH + 5),
      );
    }

    // Draw tool hint
    if (drawTool != DrawTool.cursor) {
      final hint = drawTool == DrawTool.trendLine
          ? (pendingIdx == null ? 'Tap first point' : 'Tap second point')
          : 'Tap to place line';
      final tp = _mkTP(hint, Colors.white.withOpacity(0.3), 10.0);
      tp.paint(canvas, Offset((cW - tp.width) / 2, cH - 22));
    }
  }

  void _drawHandle(Canvas c, Offset pt, Color col, {bool sel = false}) {
    if (sel)
      c.drawCircle(
        pt,
        7,
        Paint()
          ..color = col.withOpacity(0.2)
          ..style = PaintingStyle.fill,
      );
    c.drawCircle(
      pt,
      sel ? 5 : 3.5,
      Paint()
        ..color = sel ? Colors.white : col
        ..style = PaintingStyle.fill,
    );
    c.drawCircle(
      pt,
      sel ? 5 : 3.5,
      Paint()
        ..color = col.withOpacity(0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _drawExtLine(
    Canvas canvas,
    double cW,
    double cH,
    double x1,
    double y1,
    double x2,
    double y2,
    Color color, {
    double width = 1.3,
    Color? glow,
  }) {
    const far = 9999.0;
    void draw(Paint p) {
      if ((x2 - x1).abs() < 0.5) {
        canvas.drawLine(Offset(x1, -far), Offset(x1, far), p);
      } else {
        final m = (y2 - y1) / (x2 - x1);
        final b = y1 - m * x1;
        canvas.drawLine(
          Offset(-far, m * -far + b),
          Offset(cW + far, m * (cW + far) + b),
          p,
        );
      }
    }

    if (glow != null)
      draw(
        Paint()
          ..color = glow.withOpacity(0.25)
          ..strokeWidth = width + 4
          ..isAntiAlias = true,
      );
    draw(
      Paint()
        ..color = color
        ..strokeWidth = width
        ..isAntiAlias = true,
    );
  }

  void _dashH(
    Canvas c,
    double y,
    double w,
    Color col, {
    double dash = 6,
    double gap = 4,
    double width = 1.0,
  }) {
    final p = Paint()
      ..color = col
      ..strokeWidth = width;
    double x = 0;
    bool draw = true;
    while (x < w) {
      final end = math.min(x + (draw ? dash : gap), w);
      if (draw) c.drawLine(Offset(x, y), Offset(end, y), p);
      x = end;
      draw = !draw;
    }
  }

  void _drawPriceBox(
    Canvas canvas,
    double cW,
    double y,
    double price,
    Color textCol,
    Color bgCol,
  ) {
    final tp = _mkTP(_fmtP(price), textCol, 10.0, bold: true);
    final rect = Rect.fromLTWH(
      cW + 2,
      y - tp.height / 2 - 2,
      tp.width + 8,
      tp.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = bgCol,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()
        ..color = textCol.withOpacity(0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
    tp.paint(canvas, Offset(cW + 6, y - tp.height / 2));
  }

  void _drawTagBox(
    Canvas canvas,
    double cW,
    double y,
    double price,
    Color color, {
    bool hasAlert = false,
  }) {
    final tp = _mkTP(_fmtP(price), color, 9.0, bold: true);
    final bgW = tp.width + (hasAlert ? 22 : 8);
    final rect = Rect.fromLTWH(
      cW + 2,
      y - tp.height / 2 - 2,
      bgW,
      tp.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = color.withOpacity(0.2),
    );
    if (hasAlert) {
      canvas.drawCircle(
        Offset(cW + 2 + bgW - 8, y),
        3,
        Paint()
          ..color = Colors.orange
          ..style = PaintingStyle.fill,
      );
    }
    tp.paint(canvas, Offset(cW + 6, y - tp.height / 2));
  }

  void _pt(String text, Color color, double sz, Canvas canvas, Offset o) =>
      _mkTP(text, color, sz).paint(canvas, o);

  TextPainter _mkTP(String text, Color color, double sz, {bool bold = false}) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: sz,
            color: color,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  String _fmtP(double v) {
    if (v >= 10000) return v.toStringAsFixed(0);
    if (v >= 100) return v.toStringAsFixed(2);
    if (v >= 1) return v.toStringAsFixed(4);
    return v.toStringAsFixed(6);
  }

  String _fmtT(DateTime t) {
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    if (t.hour == 0 && t.minute == 0) return '$m/$d';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(_ChartPainter o) =>
      o.candles.length != candles.length ||
      o.candleWidth != candleWidth ||
      o.scrollCandles != scrollCandles ||
      o.trendLines.length != trendLines.length ||
      o.horizLines.length != horizLines.length ||
      o.pendingIdx != pendingIdx ||
      o.pendingPrice != pendingPrice ||
      o.pendingScreen != pendingScreen ||
      o.selectedId != selectedId ||
      o.rangeLo != rangeLo ||
      o.rangeHi != rangeHi ||
      o.selectedCandleIdx != selectedCandleIdx ||
      o.crosshair != crosshair ||
      o.livePrice != livePrice ||
      o.drawTool != drawTool;
}
