// ─── screens/chart_screen.dart ──────────────────────────
// Interactive candlestick chart
//   • Live price auto-refresh every 15 s
//   • 9 months of historical data with gap-fill
//   • Multi-pair switcher (drawings persist per symbol)
//   • Pinch-zoom · Pan · Crosshair
//   • Auto-scale toggle
//   • Draw Trend Lines & Horizontal Lines
//   • Select, Move drawn lines (tap to select, drag to move)
//   • Set price alerts on drawn lines (fires in real-time via live refresh)

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../services/binance_service.dart';
import '../services/telegram_service.dart';
import '../services/pivot_service.dart';

// ══════════════════════════════════════════════════════════
// DATA CLASSES
// ══════════════════════════════════════════════════════════

enum DrawTool { cursor, trendLine, hLine }

enum _TlHandle { p1, p2, body }

class TrendLineData {
  final String id;
  int    idx1;
  double price1;
  int    idx2;
  double price2;
  Color  color;
  bool   hasAlert;

  TrendLineData({
    required this.id,
    required this.idx1,
    required this.price1,
    required this.idx2,
    required this.price2,
    required this.color,
    this.hasAlert = false,
  });

  TrendLineData copyWith({
    int? idx1, double? price1,
    int? idx2, double? price2,
    bool? hasAlert,
  }) => TrendLineData(
    id: id, color: color,
    idx1:     idx1     ?? this.idx1,
    price1:   price1   ?? this.price1,
    idx2:     idx2     ?? this.idx2,
    price2:   price2   ?? this.price2,
    hasAlert: hasAlert ?? this.hasAlert,
  );

  double priceAt(int idx) {
    if (idx1 == idx2) return price1;
    return price1 + (price2 - price1) * (idx - idx1) / (idx2 - idx1);
  }
}

class HorizLineData {
  final String id;
  double price;
  Color  color;
  bool   hasAlert;

  HorizLineData({
    required this.id,
    required this.price,
    required this.color,
    this.hasAlert = false,
  });

  HorizLineData copyWith({double? price, bool? hasAlert}) => HorizLineData(
    id:       id,
    color:    color,
    price:    price    ?? this.price,
    hasAlert: hasAlert ?? this.hasAlert,
  );
}

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

  // ── Data ──────────────────────────────────────────────
  List<Candle> _candles    = [];
  bool         _loading    = false;
  bool         _refreshing = false;
  String?      _error;
  DateTime?    _lastUpdated;

  // ── Live price ────────────────────────────────────────
  Timer?  _liveTimer;
  double? _livePrice;
  double? _prevLivePrice; // ← tracks previous tick for crossing detection

  // ── Viewport ──────────────────────────────────────────
  static const double _rightPadCandles = 3.0;
  static const double _priceAxisW      = 66.0;
  static const double _timeAxisH       = 26.0;
  static const double _hitSlop         = 14.0;

  double _candleWidth   = 8.0;
  double _scrollCandles = 0.0;

  // ── Auto-scale ────────────────────────────────────────
  bool   _autoScale = true;
  double _manualLo  = 0;
  double _manualHi  = 1;

  // ── Draw tools ────────────────────────────────────────
  DrawTool _drawTool = DrawTool.cursor;
  int      _idCtr    = 0;

  final List<TrendLineData> _trendLines = [];
  final List<HorizLineData> _horizLines = [];

  int?    _pendingIdx;
  double? _pendingPrice;

  // ── Selection & Move state ────────────────────────────
  String?    _selId;
  bool       _isMoving    = false;
  _TlHandle? _dragHandle;

  double _dragAnchorPrice  = 0;
  int    _dragAnchorIdx    = 0;
  double _dragAnchorPrice1 = 0;
  double _dragAnchorPrice2 = 0;
  int    _dragAnchorIdx1   = 0;
  int    _dragAnchorIdx2   = 0;
  Offset _dragStartPos     = Offset.zero;

  // ── Gesture tracking ──────────────────────────────────
  Offset _gStartFocal  = Offset.zero;
  double _gStartCW     = 8.0;
  double _gStartScroll = 0.0;
  bool   _tapMoved     = false;
  int    _tapPointers  = 1;

  // ── Crosshair (cursor mode) ───────────────────────────
  Offset? _crosshair;
  int?    _selectedIdx;

  // ── Touch pos for rubber-band preview ─────────────────
  Offset? _touchPos;

  // ── Drawings persistence: keyed by symbol ─────────────
  // Drawings are saved when switching symbols and restored
  // when returning to the same symbol.
  final Map<String, List<TrendLineData>> _drawingsBySymbol = {};
  final Map<String, List<HorizLineData>> _horizBySymbol    = {};

  // ── Alert dedup: prevents re-alerting the same line ───
  // A line ID is added when it fires; removed when price
  // moves >0.5% away so it can fire again on next approach.
  final Set<String> _alertedLineIds = {};

  // ── Chart size (set by LayoutBuilder) ─────────────────
  Size _chartSize = Size.zero;

  // ── Pair search ───────────────────────────────────────
  final TextEditingController _searchCtrl = TextEditingController();

  static const List<String> _timeframes = [
    '5m','15m','30m','1h','4h','1d','1w',
  ];

  static const List<Color> _linePalette = [
    Color(0xFF26C6DA), Color(0xFFFFB74D), Color(0xFFAB47BC),
    Color(0xFF66BB6A), Color(0xFFEF9A9A), Color(0xFFFFEE58),
  ];

  Color _nextColor() => _linePalette[
      (_trendLines.length + _horizLines.length) % _linePalette.length];
  String _nextId() => '${++_idCtr}';

  // ══════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _symbol = Config.symbols.isNotEmpty ? Config.symbols.first : 'BTCUSDT';
    _fetchHistory();
    _startLiveTimer();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════
  // DATA
  // ══════════════════════════════════════════════════════

  Future<void> _fetchHistory() async {
    setState(() {
      _loading = true; _error = null;
      _candles = []; _selectedIdx = null;
      _crosshair = null; _livePrice = null;
      _prevLivePrice = null;
      _pendingIdx = null; _pendingPrice = null;
      _touchPos = null; _selId = null; _isMoving = false;
      // ← Do NOT clear _trendLines/_horizLines here;
      //   _restoreDrawings() repopulates them after fetch.
    });
    try {
      final candles = await BinanceService.fetchCandlesForChart(
          _symbol, _timeframe, months: 9);
      if (!mounted) return;
      setState(() {
        _candles       = candles;
        _loading       = false;
        _scrollCandles = 0;
        _lastUpdated   = DateTime.now();
        if (_autoScale) _captureRange(candles);
      });
      // Restore saved drawings for this symbol (after data is ready)
      _restoreDrawings();
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _liveRefresh() async {
    if (_loading || _candles.isEmpty) return;
    setState(() => _refreshing = true);
    try {
      final price  = await BinanceService.getCurrentPrice(_symbol);
      final recent = await BinanceService.fetchCandlesFrom(
          _symbol, _timeframe, _candles.last.time);
      if (!mounted) return;

      // Capture previous price BEFORE updating state
      final prevPrice = _prevLivePrice ??
          (_candles.isNotEmpty ? _candles.last.close : null);

      setState(() {
        _livePrice   = price;
        _lastUpdated = DateTime.now();
        for (final fresh in recent) {
          final idx = _candles.indexWhere(
              (c) => c.time.isAtSameMomentAs(fresh.time));
          if (idx >= 0) {
            _candles[idx] = fresh;
          } else if (fresh.time.isAfter(_candles.last.time)) {
            _candles.add(fresh);
          }
        }
        _refreshing = false;
      });

      // Track for next tick
      _prevLivePrice = price;

      // ── Check drawn-line alerts ──────────────────────
      if (price != null && prevPrice != null) {
        _checkDrawnLineAlerts(price, prevPrice);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _refreshing = false);
    }
  }

  void _startLiveTimer() {
    _liveTimer?.cancel();
    _liveTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => _liveRefresh());
  }

  // ══════════════════════════════════════════════════════
  // DRAWINGS PERSISTENCE
  // ══════════════════════════════════════════════════════

  /// Call before switching to a different symbol.
  /// Saves current trendLines + horizLines under the current symbol key.
  void _saveCurrentDrawings() {
    _drawingsBySymbol[_symbol] =
        _trendLines.map((t) => t.copyWith()).toList();
    _horizBySymbol[_symbol] =
        _horizLines.map((h) => h.copyWith()).toList();
  }

  /// Call after fetching history for _symbol.
  /// Repopulates _trendLines / _horizLines from the saved maps.
  void _restoreDrawings() {
    setState(() {
      _trendLines
        ..clear()
        ..addAll(_drawingsBySymbol[_symbol] ?? []);
      _horizLines
        ..clear()
        ..addAll(_horizBySymbol[_symbol] ?? []);
    });
    _alertedLineIds.clear(); // reset alert dedup when context changes
  }

  // ══════════════════════════════════════════════════════
  // DRAWN-LINE ALERT LOGIC (runs on every live-refresh tick)
  // ══════════════════════════════════════════════════════

  /// Checks all drawn lines with hasAlert == true.
  /// Fires a Telegram notification + snackbar on crossing.
  void _checkDrawnLineAlerts(double current, double prev) {
    final hasHAlerts = _horizLines.any((h) => h.hasAlert);
    final hasTAlerts = _trendLines.any((t) => t.hasAlert);
    if (!hasHAlerts && !hasTAlerts) return;

    final currentIdx = _candles.isEmpty ? 0 : _candles.length - 1;

    // ── Horizontal lines ─────────────────────────────
    for (final hl in List<HorizLineData>.from(_horizLines)) {
      if (!hl.hasAlert) continue;

      // If already alerted, reset dedup when price is >0.5% away
      if (_alertedLineIds.contains(hl.id)) {
        if (hl.price != 0 &&
            (current - hl.price).abs() / hl.price.abs() > 0.005) {
          _alertedLineIds.remove(hl.id);
        }
        continue;
      }

      if (_priceCrossedLevel(current, prev, hl.price)) {
        _alertedLineIds.add(hl.id);
        _sendDrawnLineHitAlert(
          lineType:  'Horizontal Line',
          linePrice: hl.price,
          current:   current,
        );
      }
    }

    // ── Trend lines ───────────────────────────────────
    for (final tl in List<TrendLineData>.from(_trendLines)) {
      if (!tl.hasAlert) continue;

      final linePrice = tl.priceAt(currentIdx);

      // Reset dedup when price is >0.5% away
      if (_alertedLineIds.contains(tl.id)) {
        if (linePrice != 0 &&
            (current - linePrice).abs() / linePrice.abs() > 0.005) {
          _alertedLineIds.remove(tl.id);
        }
        continue;
      }

      if (_priceCrossedLevel(current, prev, linePrice)) {
        _alertedLineIds.add(tl.id);
        _sendDrawnLineHitAlert(
          lineType:  'Trend Line',
          linePrice: linePrice,
          current:   current,
        );
      }
    }
  }

  /// Returns true when the live price either crossed through [level]
  /// or is within 0.2% of it (touch tolerance).
  bool _priceCrossedLevel(double current, double prev, double level) {
    // Crossed from below or above
    if ((prev < level && current >= level) ||
        (prev > level && current <= level)) return true;
    // Touch: within 0.2%
    if (level == 0) return false;
    return (current - level).abs() / level.abs() <= 0.002;
  }

  /// Sends a Telegram message and shows an in-app snackbar.
  Future<void> _sendDrawnLineHitAlert({
    required String lineType,
    required double linePrice,
    required double current,
  }) async {
    // Pick the best configured bot
    TelegramBot? bot;
    try {
      bot = Config.bots
          .firstWhere((b) => b.isConfigured && b.canReceiveManualAlerts);
    } catch (_) {
      try {
        bot = Config.bots.firstWhere((b) => b.isConfigured);
      } catch (_) {}
    }
    if (bot == null) return;

    final ok = await TelegramService.sendDrawnLineHitAlert(
      bot:          bot,
      symbol:       _symbol,
      timeframe:    _timeframe,
      lineType:     lineType,
      linePrice:    linePrice,
      currentPrice: current,
    );

    if (!mounted) return;

    // Always show snackbar (even if Telegram send failed)
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
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
                ? '🎯 $_symbol $lineType hit @ ${_fmtP(linePrice)}'
                : '⚠️ Line hit but Telegram send failed',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ]),
      backgroundColor:
          ok ? Colors.orange.shade800 : Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12),
      duration: const Duration(seconds: 5),
    ));
  }

  // ══════════════════════════════════════════════════════
  // COORDINATE HELPERS (must match painter)
  // ══════════════════════════════════════════════════════

  double get _cW => _chartSize.width  - _priceAxisW;
  double get _cH => _chartSize.height - _timeAxisH;

  int get _lastVis => (_candles.isEmpty ? 0 :
      (_candles.length - 1 - _scrollCandles).round()
          .clamp(0, _candles.length - 1));

  double _cX(int idx) {
    final rightPx = _rightPadCandles * _candleWidth;
    return _cW - rightPx - (_lastVis - idx) * _candleWidth - _candleWidth / 2;
  }

  double _p2y(double price, _PriceRange r) =>
      _cH * (1 - (price - r.lo) / (r.hi - r.lo));

  double _y2p(double y, _PriceRange r) =>
      r.lo + (1 - y / _cH) * (r.hi - r.lo);

  int _x2idx(double x) {
    final rightPx = _rightPadCandles * _candleWidth;
    final i = _lastVis -
        (_cW - rightPx - _candleWidth / 2 - x) / _candleWidth;
    return i.round().clamp(0, math.max(0, _candles.length - 1));
  }

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
    final rightPx  = _rightPadCandles * _candleWidth;
    final lastV    = _lastVis;
    final nVis     = ((_cW - rightPx) / _candleWidth).ceil() + 2;
    final firstV   = (lastV - nVis).clamp(0, _candles.length - 1);
    if (firstV > lastV) return [];
    return _candles.sublist(firstV, lastV + 1);
  }

  // ══════════════════════════════════════════════════════
  // HIT TESTING
  // ══════════════════════════════════════════════════════

  double _pointToLineDistance(
      double px, double py, double x1, double y1, double x2, double y2) {
    final dx = x2 - x1;
    final dy = y2 - y1;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-10) {
      return math.sqrt((px - x1) * (px - x1) + (py - y1) * (py - y1));
    }
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
      final x1 = _cX(tl.idx1); final y1 = _p2y(tl.price1, r);
      final x2 = _cX(tl.idx2); final y2 = _p2y(tl.price2, r);
      if ((pos - Offset(x1, y1)).distance < _hitSlop + 4) {
        return _HitResult('t', tl.id, _TlHandle.p1);
      }
      if ((pos - Offset(x2, y2)).distance < _hitSlop + 4) {
        return _HitResult('t', tl.id, _TlHandle.p2);
      }
      final dist = _pointToLineDistance(pos.dx, pos.dy, x1, y1, x2, y2);
      if (dist < _hitSlop && pos.dx <= _cW) {
        return _HitResult('t', tl.id, _TlHandle.body);
      }
    }
    return null;
  }

  // ══════════════════════════════════════════════════════
  // GESTURES
  // ══════════════════════════════════════════════════════

  void _onScaleStart(ScaleStartDetails d) {
    _tapPointers  = d.pointerCount;
    _tapMoved     = false;
    _gStartFocal  = d.localFocalPoint;
    _gStartCW     = _candleWidth;
    _gStartScroll = _scrollCandles;
    _isMoving     = false;
    _dragHandle   = null;

    if (_candles.isEmpty || d.pointerCount > 1) return;
    if (_drawTool != DrawTool.cursor) return;

    final r    = _activeRange;
    final hit  = _hitTest(d.localFocalPoint, r);
    if (hit != null) {
      _selId      = hit.id;
      _isMoving   = true;
      _dragHandle = hit.handle;
      _dragStartPos = d.localFocalPoint;

      if (hit.type == 'h') {
        final hl = _horizLines.firstWhere((l) => l.id == hit.id);
        _dragAnchorPrice = hl.price;
      } else {
        final tl = _trendLines.firstWhere((l) => l.id == hit.id);
        _dragAnchorPrice1 = tl.price1;
        _dragAnchorPrice2 = tl.price2;
        _dragAnchorIdx1   = tl.idx1;
        _dragAnchorIdx2   = tl.idx2;
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    _tapPointers = d.pointerCount;
    _touchPos    = d.localFocalPoint;

    final dx = (d.localFocalPoint.dx - _gStartFocal.dx).abs();
    final dy = (d.localFocalPoint.dy - _gStartFocal.dy).abs();
    if (dx > 6 || dy > 6 || (d.scale - 1.0).abs() > 0.04) {
      _tapMoved = true;
    }

    if (d.pointerCount >= 2) {
      setState(() {
        _candleWidth =
            (_gStartCW * d.scale).clamp(2.0, 40.0);
        final maxScroll = (_candles.length - 5)
            .toDouble().clamp(0.0, double.infinity);
        final panDx = d.localFocalPoint.dx - _gStartFocal.dx;
        _scrollCandles =
            (_gStartScroll - panDx / _candleWidth).clamp(0.0, maxScroll);
        _isMoving = false;
      });
      return;
    }

    if (_isMoving && _selId != null && _tapMoved) {
      final r     = _activeRange;
      final diffY = d.localFocalPoint.dy - _dragStartPos.dy;
      final diffX = d.localFocalPoint.dx - _dragStartPos.dx;
      final priceDelta = -diffY / _cH * (r.hi - r.lo);
      final idxDelta   = (-diffX / _candleWidth).round();

      setState(() {
        final hiIdx = _candles.length - 1;

        final hiIdx_h = _horizLines.indexWhere((l) => l.id == _selId);
        if (hiIdx_h >= 0) {
          final newP = (_dragAnchorPrice + priceDelta)
              .clamp(r.lo, r.hi);
          _horizLines[hiIdx_h] = _horizLines[hiIdx_h].copyWith(price: newP);
          return;
        }

        final tiIdx = _trendLines.indexWhere((l) => l.id == _selId);
        if (tiIdx < 0) return;
        final tl = _trendLines[tiIdx];

        if (_dragHandle == _TlHandle.p1) {
          _trendLines[tiIdx] = tl.copyWith(
            idx1:   (_dragAnchorIdx1 + idxDelta).clamp(0, hiIdx),
            price1: _dragAnchorPrice1 + priceDelta,
          );
        } else if (_dragHandle == _TlHandle.p2) {
          _trendLines[tiIdx] = tl.copyWith(
            idx2:   (_dragAnchorIdx2 + idxDelta).clamp(0, hiIdx),
            price2: _dragAnchorPrice2 + priceDelta,
          );
        } else {
          _trendLines[tiIdx] = tl.copyWith(
            idx1:   (_dragAnchorIdx1 + idxDelta).clamp(0, hiIdx),
            price1: _dragAnchorPrice1 + priceDelta,
            idx2:   (_dragAnchorIdx2 + idxDelta).clamp(0, hiIdx),
            price2: _dragAnchorPrice2 + priceDelta,
          );
        }
      });
      return;
    }

    if (_drawTool == DrawTool.cursor && _tapMoved && !_isMoving) {
      setState(() {
        _candleWidth =
            (_gStartCW * d.scale).clamp(2.0, 40.0);
        final maxScroll = (_candles.length - 5)
            .toDouble().clamp(0.0, double.infinity);
        final panDx = d.localFocalPoint.dx - _gStartFocal.dx;
        _scrollCandles =
            (_gStartScroll - panDx / _candleWidth).clamp(0.0, maxScroll);
        _crosshair   = d.localFocalPoint;
        _selectedIdx = _x2idx(d.localFocalPoint.dx);
      });
      return;
    }

    if (_drawTool != DrawTool.cursor) {
      setState(() {});
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final wasTap    = !_tapMoved && _tapPointers == 1;
    final tapPos    = _gStartFocal;

    setState(() {
      _crosshair   = null;
      _selectedIdx = null;
      _touchPos    = null;
      _isMoving    = false;
      _dragHandle  = null;
    });

    if (!wasTap) return;

    if (_drawTool == DrawTool.cursor) {
      final r   = _activeRange;
      final hit = _hitTest(tapPos, r);
      if (hit != null) {
        setState(() => _selId = (_selId == hit.id) ? null : hit.id);
        if (_selId == hit.id) {
          _showLineActions(hit.id, hit.type);
        }
      } else {
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
    final r     = _activeRange;
    final idx   = _x2idx(pos.dx);
    final price = _y2p(pos.dy, r);
    if (pos.dx < 0 || pos.dx > _cW) return;
    if (pos.dy < 0 || pos.dy > _cH) return;

    setState(() {
      if (_drawTool == DrawTool.hLine) {
        _horizLines.add(HorizLineData(
            id: _nextId(), price: price, color: _nextColor()));
        _selId = _horizLines.last.id;
        _drawTool = DrawTool.cursor;
      } else if (_drawTool == DrawTool.trendLine) {
        if (_pendingIdx == null) {
          _pendingIdx   = idx;
          _pendingPrice = price;
        } else {
          _trendLines.add(TrendLineData(
            id: _nextId(),
            idx1: _pendingIdx!, price1: _pendingPrice!,
            idx2: idx,          price2: price,
            color: _nextColor(),
          ));
          _selId        = _trendLines.last.id;
          _pendingIdx   = null;
          _pendingPrice = null;
          _drawTool     = DrawTool.cursor;
        }
      }
    });
  }

  // ══════════════════════════════════════════════════════
  // LINE ACTIONS BOTTOM SHEET
  // ══════════════════════════════════════════════════════

  void _showLineActions(String id, String type) {
    final isH  = type == 'h';
    final hl   = isH ? _horizLines.firstWhere((l) => l.id == id,
        orElse: () => HorizLineData(id: '', price: 0, color: Colors.white))
        : null;
    final tl   = !isH ? _trendLines.firstWhere((l) => l.id == id,
        orElse: () => TrendLineData(id: '', idx1: 0, price1: 0,
            idx2: 0, price2: 0, color: Colors.white))
        : null;

    if ((hl?.id ?? tl?.id ?? '') == '') return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _LineActionsSheet(
        lineId:    id,
        lineType:  type,
        price:     isH ? hl!.price : tl!.priceAt(_candles.length - 1),
        hasAlert:  isH ? hl!.hasAlert : tl!.hasAlert,
        symbol:    _symbol,
        onDelete:  () {
          Navigator.pop(context);
          setState(() {
            _horizLines.removeWhere((l) => l.id == id);
            _trendLines.removeWhere((l) => l.id == id);
            _alertedLineIds.remove(id);
            _selId = null;
          });
        },
        onSetAlert: (botId, condition) {
          Navigator.pop(context);
          _activateLineAlert(id, type);
        },
        onRemoveAlert: () {
          Navigator.pop(context);
          _deactivateLineAlert(id, type);
        },
      ),
    );
  }

  /// Marks a drawn line as having an active alert (hasAlert = true).
  void _activateLineAlert(String id, String type) {
    setState(() {
      if (type == 'h') {
        final i = _horizLines.indexWhere((l) => l.id == id);
        if (i >= 0) _horizLines[i] = _horizLines[i].copyWith(hasAlert: true);
      } else {
        final i = _trendLines.indexWhere((l) => l.id == id);
        if (i >= 0) _trendLines[i] = _trendLines[i].copyWith(hasAlert: true);
      }
      // Remove from dedup so it can fire immediately on next hit
      _alertedLineIds.remove(id);
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Row(children: [
          Icon(Icons.notifications_active_rounded,
              color: Colors.white, size: 16),
          SizedBox(width: 8),
          Text('Alert set — fires when price hits this line'),
        ]),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  /// Removes the alert from a drawn line (hasAlert = false).
  void _deactivateLineAlert(String id, String type) {
    setState(() {
      if (type == 'h') {
        final i = _horizLines.indexWhere((l) => l.id == id);
        if (i >= 0) _horizLines[i] = _horizLines[i].copyWith(hasAlert: false);
      } else {
        final i = _trendLines.indexWhere((l) => l.id == id);
        if (i >= 0) _trendLines[i] = _trendLines[i].copyWith(hasAlert: false);
      }
      _alertedLineIds.remove(id);
    });
  }

  // ── Legacy helpers kept for backwards compat ──────────
  void _saveLineAlert(String id, String type, String botId, String condition) =>
      _activateLineAlert(id, type);

  void _removeLineAlert(String id, String type) =>
      _deactivateLineAlert(id, type);

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
        current:    _symbol,
        searchCtrl: _searchCtrl,
        onSelect:   (sym) {
          Navigator.pop(context);
          if (sym != _symbol) {
            // ── Save drawings for current symbol ────────
            _saveCurrentDrawings();
            setState(() {
              _symbol       = sym;
              _pendingIdx   = null;
              _pendingPrice = null;
              _selId        = null;
              // ← intentionally NOT clearing _trendLines/_horizLines;
              //   _restoreDrawings() will replace them after fetch.
            });
            _fetchHistory();
          }
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════
  // RANGE HELPER
  // ══════════════════════════════════════════════════════

  _PriceRange get _activeRange => _autoScale
      ? _computeRange()
      : _PriceRange(_manualLo, _manualHi);

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
      elevation: 0, titleSpacing: 0,
      automaticallyImplyLeading: false,
      title: GestureDetector(
        onTap: _openPairSelector,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_symbol,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold,
                    color: Colors.white)),
            const SizedBox(width: 3),
            const Icon(Icons.keyboard_arrow_down_rounded,
                size: 18, color: Color(0xFF888899)),
            const SizedBox(width: 10),
            if (displayPrice != null)
              Text(_fmtP(displayPrice),
                  style: TextStyle(fontSize: 15,
                      fontWeight: FontWeight.bold, color: liveColor)),
            if (_refreshing) ...[
              const SizedBox(width: 6),
              SizedBox(width: 8, height: 8,
                  child: CircularProgressIndicator(strokeWidth: 1.5,
                      color: Colors.blueAccent.withOpacity(0.7))),
            ],
          ]),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 4, top: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 7, height: 7,
                  decoration: BoxDecoration(
                    color: _refreshing ? Colors.orange : const Color(0xFF26A69A),
                    shape: BoxShape.circle)),
              const SizedBox(height: 1),
              Text('LIVE', style: TextStyle(
                  fontSize: 7, color: Colors.grey.shade600,
                  letterSpacing: 0.5)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20),
          onPressed: _loading ? null : _fetchHistory,
        ),
        const SizedBox(width: 2),
      ],
    );
  }

  Widget _buildTfBar() {
    return Container(
      color: const Color(0xFF12121E), height: 34,
      child: Row(children: [
        const SizedBox(width: 6),
        ..._timeframes.map((tf) {
          final sel = tf == _timeframe;
          return GestureDetector(
            onTap: () {
              if (tf != _timeframe) {
                setState(() => _timeframe = tf);
                _fetchHistory();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
              decoration: BoxDecoration(
                color: sel ? Colors.blueAccent.withOpacity(0.9) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: sel ? null : Border.all(color: const Color(0xFF2A2A40)),
              ),
              child: Text(tf, style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                  color: sel ? Colors.white : Colors.grey.shade500)),
            ),
          );
        }),
        const Spacer(),
        if (_lastUpdated != null)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              '${_p2(_lastUpdated!.hour)}:${_p2(_lastUpdated!.minute)}:${_p2(_lastUpdated!.second)}',
              style: const TextStyle(fontSize: 9, color: Color(0xFF444466))),
          ),
      ]),
    );
  }

  Widget _buildDrawToolbar() {
    final totalAlerts =
        _horizLines.where((h) => h.hasAlert).length +
        _trendLines.where((t) => t.hasAlert).length;

    return Container(
      height: 38, color: const Color(0xFF0D0D1A),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(children: [
        _ToolBtn(
          icon: Icons.near_me_rounded, label: 'Cursor',
          active: _drawTool == DrawTool.cursor,
          onTap: () => setState(() {
            _drawTool = DrawTool.cursor;
            _pendingIdx = null; _pendingPrice = null;
          }),
        ),
        const SizedBox(width: 4),
        _ToolBtn(
          icon: Icons.show_chart_rounded, label: 'Trend',
          active: _drawTool == DrawTool.trendLine,
          badge: _drawTool == DrawTool.trendLine && _pendingIdx != null ? '1/2' : null,
          onTap: () => setState(() {
            _drawTool = DrawTool.trendLine;
            _pendingIdx = null; _pendingPrice = null;
          }),
        ),
        const SizedBox(width: 4),
        _ToolBtn(
          icon: Icons.horizontal_rule_rounded, label: 'H-Line',
          active: _drawTool == DrawTool.hLine,
          onTap: () => setState(() {
            _drawTool = DrawTool.hLine;
            _pendingIdx = null; _pendingPrice = null;
          }),
        ),
        // Active alert badge
        if (totalAlerts > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.orange.withOpacity(0.5)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.notifications_active_rounded,
                  size: 11, color: Colors.orange),
              const SizedBox(width: 3),
              Text('$totalAlerts',
                  style: const TextStyle(
                      fontSize: 10, color: Colors.orange,
                      fontWeight: FontWeight.bold)),
            ]),
          ),
        ],
        const Spacer(),
        // Auto-scale
        GestureDetector(
          onTap: () {
            setState(() {
              _autoScale = !_autoScale;
              if (!_autoScale) {
                final r = _computeRange();
                _manualLo = r.lo; _manualHi = r.hi;
              }
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _autoScale ? Colors.blueAccent.withOpacity(0.18) : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                  color: _autoScale ? Colors.blueAccent.withOpacity(0.7) : Colors.grey.shade700),
            ),
            child: Text('Auto', style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: _autoScale ? Colors.blueAccent : Colors.grey.shade500)),
          ),
        ),
        if (_trendLines.isNotEmpty || _horizLines.isNotEmpty) ...[
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => setState(() {
              _trendLines.clear(); _horizLines.clear();
              _pendingIdx = null; _pendingPrice = null;
              _selId = null; _alertedLineIds.clear();
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Colors.grey.shade800)),
              child: Icon(Icons.delete_outline_rounded,
                  size: 14, color: Colors.grey.shade500),
            ),
          ),
        ],
        const SizedBox(width: 2),
      ]),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 32, height: 32,
              child: CircularProgressIndicator(color: Colors.blueAccent, strokeWidth: 2)),
          const SizedBox(height: 14),
          Text('Loading $_symbol...',
              style: const TextStyle(color: Color(0xFF555577), fontSize: 13)),
          const SizedBox(height: 4),
          const Text('Fetching historical data',
              style: TextStyle(color: Color(0xFF333355), fontSize: 11)),
        ],
      ));
    }
    if (_error != null) {
      return Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF888888), fontSize: 12)),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _fetchHistory,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
          ),
        ],
      ));
    }
    if (_candles.isEmpty) {
      return const Center(child: Text('No data',
          style: TextStyle(color: Color(0xFF555577), fontSize: 14)));
    }

    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: LayoutBuilder(builder: (ctx, constraints) {
        _chartSize = Size(constraints.maxWidth, constraints.maxHeight);
        final priceRange = _activeRange;
        return CustomPaint(
          painter: _ChartPainter(
            candles:           _candles,
            candleWidth:       _candleWidth,
            scrollCandles:     _scrollCandles,
            rightPadCandles:   _rightPadCandles,
            trendLines:        List.unmodifiable(_trendLines),
            horizLines:        List.unmodifiable(_horizLines),
            pendingIdx:        _pendingIdx,
            pendingPrice:      _pendingPrice,
            pendingScreen:     (_pendingIdx != null && _touchPos != null)
                ? _touchPos : null,
            selectedId:        _selId,
            rangeLo:           priceRange.lo,
            rangeHi:           priceRange.hi,
            selectedCandleIdx: _selectedIdx,
            crosshair:         _crosshair,
            livePrice:         _livePrice,
            drawTool:          _drawTool,
            isMoving:          _isMoving,
          ),
          size: Size(constraints.maxWidth, constraints.maxHeight),
        );
      }),
    );
  }

  Widget _buildInfoBar() {
    Candle? c;
    if (_selectedIdx != null &&
        _selectedIdx! >= 0 && _selectedIdx! < _candles.length) {
      c = _candles[_selectedIdx!];
    } else if (_candles.isNotEmpty) {
      c = _candles.last;
    }
    if (c == null) return Container(color: const Color(0xFF0D0D1A), height: 38);

    final isBull = c.close >= c.open;
    final col    = isBull ? const Color(0xFF26A69A) : const Color(0xFFEF5350);
    final chg    = (c.close - c.open) / c.open * 100;
    final date   = '${c.time.year}-${_p2(c.time.month)}-${_p2(c.time.day)}'
        ' ${_p2(c.time.hour)}:${_p2(c.time.minute)}';

    return Container(
      color: const Color(0xFF0D0D1A),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(children: [
        Text(date, style: const TextStyle(fontSize: 9, color: Color(0xFF555577))),
        const SizedBox(width: 6),
        _ov('O', c.open,  const Color(0xFF888899)),
        _ov('H', c.high,  const Color(0xFF26A69A)),
        _ov('L', c.low,   const Color(0xFFEF5350)),
        _ov('C', c.close, col),
        _ovVol('V', c.volume),
        const Spacer(),
        Text('${chg >= 0 ? '+' : ''}${chg.toStringAsFixed(2)}%',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: col)),
        const SizedBox(width: 4),
        if (_selectedIdx == null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF26A69A).withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFF26A69A).withOpacity(0.4)),
            ),
            child: const Text('LIVE', style: TextStyle(
                fontSize: 8, color: Color(0xFF26A69A), fontWeight: FontWeight.bold)),
          ),
      ]),
    );
  }

  Widget _ov(String lbl, double v, Color c) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: RichText(text: TextSpan(children: [
      TextSpan(text: '$lbl ', style: const TextStyle(fontSize: 9, color: Color(0xFF555577))),
      TextSpan(text: _fmtP(v), style: TextStyle(fontSize: 9.5, color: c, fontWeight: FontWeight.w600)),
    ])),
  );

  Widget _ovVol(String lbl, double v) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: RichText(text: TextSpan(children: [
      TextSpan(text: '$lbl ', style: const TextStyle(fontSize: 9, color: Color(0xFF555577))),
      TextSpan(text: _fmtVol(v), style: const TextStyle(
          fontSize: 9.5, color: Color(0xFF888899), fontWeight: FontWeight.w600)),
    ])),
  );

  String _fmtP(double v) {
    if (v >= 10000) return v.toStringAsFixed(0);
    if (v >= 100)   return v.toStringAsFixed(2);
    if (v >= 1)     return v.toStringAsFixed(4);
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
  final String    type;
  final String    id;
  final _TlHandle handle;
  _HitResult(this.type, this.id, this.handle);
}

// ══════════════════════════════════════════════════════════
// LINE ACTIONS BOTTOM SHEET
// ══════════════════════════════════════════════════════════
class _LineActionsSheet extends StatefulWidget {
  final String   lineId;
  final String   lineType;
  final double   price;
  final bool     hasAlert;
  final String   symbol;
  final VoidCallback        onDelete;
  final Function(String botId, String condition) onSetAlert;
  final VoidCallback        onRemoveAlert;

  const _LineActionsSheet({
    required this.lineId,
    required this.lineType,
    required this.price,
    required this.hasAlert,
    required this.symbol,
    required this.onDelete,
    required this.onSetAlert,
    required this.onRemoveAlert,
  });

  @override
  State<_LineActionsSheet> createState() => _LineActionsSheetState();
}

class _LineActionsSheetState extends State<_LineActionsSheet> {
  String _condition     = 'touch';
  String _selectedBotId = '';

  @override
  void initState() {
    super.initState();
    _selectedBotId = _defaultBot();
  }

  String _defaultBot() {
    if (Config.bots.isEmpty) return '';
    try { return Config.bots.firstWhere((b) => b.isConfigured && b.canReceiveManualAlerts).id; }
    catch (_) {}
    try { return Config.bots.firstWhere((b) => b.isConfigured).id; }
    catch (_) { return Config.bots.first.id; }
  }

  String _fmtP(double v) {
    if (v >= 10000) return v.toStringAsFixed(0);
    if (v >= 100)   return v.toStringAsFixed(2);
    if (v >= 1)     return v.toStringAsFixed(4);
    return v.toStringAsFixed(6);
  }

  @override
  Widget build(BuildContext context) {
    final sheetColor = const Color(0xFF1A1A2E);
    final bots       = Config.bots;
    if (bots.isNotEmpty && !bots.any((b) => b.id == _selectedBotId)) {
      _selectedBotId = bots.first.id;
    }

    return Container(
      decoration: BoxDecoration(
        color: sheetColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(width: 36, height: 4,
                    decoration: BoxDecoration(
                        color: Colors.grey.shade700,
                        borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 14),

              // Title
              Row(children: [
                Icon(
                  widget.lineType == 'h'
                      ? Icons.horizontal_rule_rounded
                      : Icons.show_chart_rounded,
                  color: Colors.blueAccent, size: 18),
                const SizedBox(width: 8),
                Text(
                  widget.lineType == 'h' ? 'Horizontal Line' : 'Trend Line',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 15,
                      fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(_fmtP(widget.price),
                    style: const TextStyle(
                        color: Color(0xFF26A69A), fontSize: 13,
                        fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 4),
              Text(widget.symbol,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),

              const SizedBox(height: 16),
              const Divider(color: Color(0xFF2A2A40), height: 1),
              const SizedBox(height: 16),

              // ── ALERT SECTION ──────────────────────────
              Row(children: [
                Icon(Icons.notifications_rounded,
                    size: 15,
                    color: widget.hasAlert ? Colors.orange : Colors.grey.shade500),
                const SizedBox(width: 8),
                Text(
                  widget.hasAlert ? 'Alert active' : 'Set price alert',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: widget.hasAlert ? Colors.orange : Colors.white)),
              ]),
              const SizedBox(height: 4),
              Text(
                widget.hasAlert
                    ? 'A Telegram alert fires when the live price hits this line.'
                    : 'Sends a Telegram message when live price crosses this line.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 12),

              if (!widget.hasAlert) ...[
                // Bot selector
                if (bots.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.withOpacity(0.4)),
                    ),
                    child: const Text(
                      'No Telegram bots configured. Add one in Bot settings.',
                      style: TextStyle(fontSize: 12, color: Colors.orange)),
                  )
                else ...[
                  const Text('Send via:',
                      style: TextStyle(fontSize: 11, color: Color(0xFF888899))),
                  const SizedBox(height: 8),
                  ...bots.map((bot) => GestureDetector(
                    onTap: () => setState(() => _selectedBotId = bot.id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 130),
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
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
                      child: Row(children: [
                        Icon(Icons.smart_toy_rounded, size: 13,
                            color: _selectedBotId == bot.id
                                ? Colors.blueAccent
                                : Colors.grey.shade500),
                        const SizedBox(width: 8),
                        Text(bot.name,
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600,
                                color: _selectedBotId == bot.id
                                    ? Colors.white
                                    : Colors.grey.shade400)),
                        const Spacer(),
                        if (_selectedBotId == bot.id)
                          const Icon(Icons.check_rounded,
                              size: 14, color: Colors.blueAccent),
                      ]),
                    ),
                  )),
                ],

                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: bots.isEmpty
                        ? null
                        : () => widget.onSetAlert(_selectedBotId, _condition),
                    icon: const Icon(Icons.notifications_active_rounded, size: 16),
                    label: const Text('Activate Alert',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ] else ...[
                // Already has alert
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.4)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.notifications_active_rounded,
                        size: 14, color: Colors.orange),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Alert is active — fires when price hits this line',
                        style: TextStyle(fontSize: 12, color: Colors.orange)),
                    ),
                    GestureDetector(
                      onTap: widget.onRemoveAlert,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.red.withOpacity(0.3)),
                        ),
                        child: const Text('Remove',
                            style: TextStyle(fontSize: 11,
                                color: Colors.redAccent,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ]),
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
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 16, color: Colors.redAccent),
                  label: const Text('Delete Line',
                      style: TextStyle(color: Colors.redAccent)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.redAccent.withOpacity(0.4)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
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
  final String   label;
  final bool     active;
  final VoidCallback onTap;
  final String?  badge;

  const _ToolBtn({required this.icon, required this.label,
      required this.active, required this.onTap, this.badge});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(clipBehavior: Clip.none, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? Colors.blueAccent.withOpacity(0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: active ? Colors.blueAccent.withOpacity(0.7) : Colors.grey.shade800),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15,
                color: active ? Colors.blueAccent : Colors.grey.shade500),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600,
                color: active ? Colors.blueAccent : Colors.grey.shade500)),
          ]),
        ),
        if (badge != null)
          Positioned(
            top: -4, right: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                  color: Colors.orange, borderRadius: BorderRadius.circular(8)),
              child: Text(badge!,
                  style: const TextStyle(fontSize: 8,
                      fontWeight: FontWeight.bold, color: Colors.white)),
            ),
          ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════
// PAIR SELECTOR SHEET
// ══════════════════════════════════════════════════════════
class _PairSheet extends StatefulWidget {
  final String current;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSelect;
  const _PairSheet({required this.current, required this.searchCtrl,
      required this.onSelect});
  @override
  State<_PairSheet> createState() => _PairSheetState();
}

class _PairSheetState extends State<_PairSheet> {
  String _query = '';
  static const List<String> _popular = [
    'BTCUSDT','ETHUSDT','SOLUSDT','BNBUSDT','XRPUSDT',
    'DOGEUSDT','ADAUSDT','AVAXUSDT','DOTUSDT','LINKUSDT',
    'MATICUSDT','LTCUSDT','UNIUSDT','ATOMUSDT','NEARUSDT',
    'APTUSDT','ARBUSDT','OPUSDT','SUIUSDT','SEIUSDT',
    'INJUSDT','TIAUSDT','WIFUSDT','BONKUSDT','PEPEUSDT',
    'TRXUSDT','FTMUSDT','LDOUSDT','STXUSDT','RUNEUSDT',
    'ETHBTC','BNBBTC',
  ];

  List<String> get _symbols {
    final all = {...Config.symbols, ..._popular}.toList();
    if (_query.isEmpty) return all;
    final q = _query.toUpperCase();
    return all.where((s) => s.contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.72, minChildSize: 0.4, maxChildSize: 0.92,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF12121E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        child: Column(children: [
          const SizedBox(height: 10),
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.grey.shade700,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Text('Select Pair', style: TextStyle(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                  onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: widget.searchCtrl, autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]'))],
              decoration: InputDecoration(
                hintText: 'Search… e.g. ETH, SOL',
                hintStyle: const TextStyle(color: Color(0xFF555577), fontSize: 13),
                prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF555577), size: 20),
                suffixIcon: _query.isNotEmpty
                    ? GestureDetector(
                        onTap: () { widget.searchCtrl.clear(); setState(() => _query = ''); },
                        child: const Icon(Icons.close, color: Color(0xFF555577), size: 18))
                    : null,
                filled: true, fillColor: const Color(0xFF1A1A2E),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF2A2A40))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF2A2A40))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Colors.blueAccent, width: 1.5)),
              ),
              onChanged: (v) => setState(() => _query = v),
              onSubmitted: (v) { final s = v.trim().toUpperCase(); if (s.isNotEmpty) widget.onSelect(s); },
            ),
          ),
          Expanded(
            child: _symbols.isEmpty
                ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.search_off_rounded, color: Color(0xFF444466), size: 40),
                    const SizedBox(height: 8),
                    const Text('No matches', style: TextStyle(color: Color(0xFF555577))),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () { final s = _query.trim().toUpperCase(); if (s.isNotEmpty) widget.onSelect(s); },
                      child: Text('Open "$_query" anyway →',
                          style: const TextStyle(color: Colors.blueAccent))),
                  ]))
                : ListView.builder(
                    controller: ctrl, itemCount: _symbols.length,
                    itemBuilder: (_, i) {
                      final sym = _symbols[i];
                      final isCur = sym == widget.current;
                      final isWL  = Config.symbols.contains(sym);
                      final base  = sym.replaceAll(RegExp(r'(USDT|BTC|ETH|BNB)$'), '');
                      return ListTile(
                        dense: true, onTap: () => widget.onSelect(sym),
                        leading: Container(width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: isCur ? Colors.blueAccent.withOpacity(0.2) : const Color(0xFF1A1A2E),
                            borderRadius: BorderRadius.circular(8)),
                          alignment: Alignment.center,
                          child: Text(base.isNotEmpty ? base[0] : sym[0],
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                                  color: isCur ? Colors.blueAccent : Colors.grey.shade400))),
                        title: Row(children: [
                          Text(sym, style: TextStyle(
                              color: isCur ? Colors.blueAccent : Colors.white,
                              fontWeight: isCur ? FontWeight.bold : FontWeight.normal,
                              fontSize: 13.5)),
                          if (isWL) ...[const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(4)),
                              child: const Text('WL', style: TextStyle(fontSize: 8,
                                  color: Colors.blueAccent, fontWeight: FontWeight.bold)))],
                        ]),
                        trailing: isCur
                            ? const Icon(Icons.check_rounded, color: Colors.blueAccent, size: 18)
                            : const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF444466), size: 13),
                      );
                    }),
          ),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// CUSTOM PAINTER
// ══════════════════════════════════════════════════════════
class _ChartPainter extends CustomPainter {
  final List<Candle>        candles;
  final double              candleWidth;
  final double              scrollCandles;
  final double              rightPadCandles;
  final List<TrendLineData> trendLines;
  final List<HorizLineData> horizLines;
  final int?                pendingIdx;
  final double?             pendingPrice;
  final Offset?             pendingScreen;
  final String?             selectedId;
  final double              rangeLo;
  final double              rangeHi;
  final int?                selectedCandleIdx;
  final Offset?             crosshair;
  final double?             livePrice;
  final DrawTool            drawTool;
  final bool                isMoving;

  const _ChartPainter({
    required this.candles,
    required this.candleWidth,
    required this.scrollCandles,
    required this.rightPadCandles,
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
    this.isMoving = false,
  });

  static const double _priceW = 66.0;
  static const double _timeH  = 26.0;
  static const Color  _bull   = Color(0xFF26A69A);
  static const Color  _bear   = Color(0xFFEF5350);
  static const Color  _grid   = Color(0xFF181828);
  static const Color  _axis   = Color(0xFF555575);

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;
    final cW = size.width - _priceW;
    final cH = size.height - _timeH;

    final rightPx = rightPadCandles * candleWidth;
    final lastVis  = (candles.length - 1 - scrollCandles)
        .round().clamp(0, candles.length - 1);
    final nVis     = ((cW - rightPx) / candleWidth).ceil() + 2;
    final firstVis = (lastVis - nVis).clamp(0, candles.length - 1);
    if (firstVis > lastVis) return;

    final lo = rangeLo, hi = rangeHi;
    if ((hi - lo).abs() < 1e-10) return;

    double cX(int i) =>
        cW - rightPx - (lastVis - i) * candleWidth - candleWidth / 2;
    double p2y(double p) => cH * (1 - (p - lo) / (hi - lo));

    // ── Background ────────────────────────────────────
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF0A0A14));

    // ── Grid ──────────────────────────────────────────
    final gp = Paint()..color = _grid..strokeWidth = 0.5;
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
    canvas.drawLine(Offset(cW, 0), Offset(cW, size.height),
        Paint()..color = const Color(0xFF1E1E35)..strokeWidth = 1);

    // ── Horizontal lines ──────────────────────────────
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, cW, cH));
    for (final hl in horizLines) {
      final y   = p2y(hl.price);
      if (y < -1 || y > cH + 1) continue;
      final sel = hl.id == selectedId;
      _dashH(canvas, y, cW, sel ? Colors.white : hl.color,
          dash: 8, gap: 5, width: sel ? 1.8 : 1.1);
      if (sel) {
        _dashH(canvas, y, cW, hl.color.withOpacity(0.3),
            dash: 8, gap: 5, width: 5);
        _drawHandle(canvas, Offset(cW / 2, y), hl.color, sel: true);
      }
      if (hl.hasAlert) {
        // Orange bell badge indicating active alert
        canvas.drawCircle(Offset(16, y), 5,
            Paint()..color = Colors.orange..style = PaintingStyle.fill);
        canvas.drawCircle(Offset(16, y), 5,
            Paint()..color = Colors.orange.withOpacity(0.3)
              ..style = PaintingStyle.stroke..strokeWidth = 3);
      }
    }
    canvas.restore();

    // ── Trend lines ───────────────────────────────────
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, cW, cH));
    for (final tl in trendLines) {
      final x1 = cX(tl.idx1); final y1 = p2y(tl.price1);
      final x2 = cX(tl.idx2); final y2 = p2y(tl.price2);
      final sel = tl.id == selectedId;
      _drawExtendedLine(canvas, cW, cH, x1, y1, x2, y2,
          sel ? Colors.white : tl.color,
          width: sel ? 1.8 : 1.3,
          glow: sel ? tl.color : null);
      for (final pt in [Offset(x1, y1), Offset(x2, y2)]) {
        _drawHandle(canvas, pt, tl.color, sel: sel);
      }
      if (tl.hasAlert) {
        final mx = (x1 + x2) / 2; final my = (y1 + y2) / 2;
        if (mx >= 0 && mx <= cW) {
          canvas.drawCircle(Offset(mx, my), 5,
              Paint()..color = Colors.orange..style = PaintingStyle.fill);
          canvas.drawCircle(Offset(mx, my), 5,
              Paint()..color = Colors.orange.withOpacity(0.3)
                ..style = PaintingStyle.stroke..strokeWidth = 3);
        }
      }
    }
    canvas.restore();

    // ── Candles ───────────────────────────────────────
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, cW, cH));
    for (int i = firstVis; i <= lastVis; i++) {
      final c = candles[i];
      final x = cX(i);
      if (x < -candleWidth * 2 || x > cW + candleWidth) continue;

      final isBull = c.close >= c.open;
      final isLive = i == candles.length - 1;
      final col    = isLive
          ? (isBull ? const Color(0xFF00C8B4) : const Color(0xFFFF5252))
          : (isBull ? _bull : _bear);

      final wickW = math.max(candleWidth * 0.12, 1.0);
      final bodyW = math.max(candleWidth * 0.65, 1.0);

      canvas.drawLine(Offset(x, p2y(c.high)), Offset(x, p2y(c.low)),
          Paint()..color = col..strokeWidth = wickW);

      final bTop  = p2y(math.max(c.open, c.close));
      final bBot  = p2y(math.min(c.open, c.close));
      final bodyH = math.max(bBot - bTop, 1.0);

      canvas.drawRect(Rect.fromLTWH(x - bodyW / 2, bTop, bodyW, bodyH),
          Paint()..color = col);

      if (i == selectedCandleIdx) {
        canvas.drawRect(
          Rect.fromLTWH(x - bodyW / 2 - 1.5, bTop - 1.5, bodyW + 3, bodyH + 3),
          Paint()
            ..color = Colors.white.withOpacity(0.25)
            ..style = PaintingStyle.stroke..strokeWidth = 1.2);
      }
      if (isLive) {
        canvas.drawRect(
          Rect.fromLTWH(x - bodyW / 2 - 1, bTop - 1, bodyW + 2, bodyH + 2),
          Paint()
            ..color = col.withOpacity(0.35)
            ..style = PaintingStyle.stroke..strokeWidth = 0.8);
      }
    }
    canvas.restore();

    // ── Pending trend line rubber-band ────────────────
    if (pendingIdx != null && pendingPrice != null) {
      final x1 = cX(pendingIdx!); final y1 = p2y(pendingPrice!);
      canvas.drawCircle(Offset(x1, y1), 5,
          Paint()..color = Colors.cyan..style = PaintingStyle.fill);
      canvas.drawCircle(Offset(x1, y1), 5,
          Paint()..color = Colors.white.withOpacity(0.4)
            ..style = PaintingStyle.stroke..strokeWidth = 1.5);
      if (pendingScreen != null) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, cW, cH));
        canvas.drawLine(Offset(x1, y1), pendingScreen!,
            Paint()..color = Colors.cyan.withOpacity(0.6)
              ..strokeWidth = 1.5..isAntiAlias = true);
        canvas.restore();
      }
    }

    // ── Live price line ───────────────────────────────
    final dispPrice = livePrice ?? candles.last.close;
    final lpY = p2y(dispPrice);
    if (lpY >= 0 && lpY <= cH) {
      final isBull = candles.last.close >= candles.last.open;
      _dashH(canvas, lpY, cW,
          (isBull ? _bull : _bear).withOpacity(0.45), dash: 3, gap: 6);
      _drawPriceBox(canvas, cW, lpY, dispPrice, Colors.white,
          isBull ? const Color(0xFF1A3A38) : const Color(0xFF3A1A1A));
    }

    // ── Crosshair ─────────────────────────────────────
    if (crosshair != null && crosshair!.dx >= 0 && crosshair!.dx <= cW) {
      final xp = Paint()..color = Colors.white.withOpacity(0.2)..strokeWidth = 0.8;
      canvas.drawLine(Offset(crosshair!.dx, 0), Offset(crosshair!.dx, cH), xp);
      if (crosshair!.dy >= 0 && crosshair!.dy <= cH) {
        canvas.drawLine(Offset(0, crosshair!.dy), Offset(cW, crosshair!.dy), xp);
        final chP = lo + (1 - crosshair!.dy / cH) * (hi - lo);
        _drawPriceBox(canvas, cW, crosshair!.dy, chP,
            Colors.white.withOpacity(0.9), const Color(0xFF222240));
      }
    }

    // ── Price axis ────────────────────────────────────
    for (int i = 0; i <= 6; i++) {
      final y  = cH * i / 6;
      final pr = lo + (1 - i / 6) * (hi - lo);
      _pt(_fmtP(pr), _axis, 9.0, canvas, Offset(cW + 4, y - 5));
    }

    // ── H-line price tags on axis ─────────────────────
    for (final hl in horizLines) {
      final y = p2y(hl.price);
      if (y < -10 || y > cH + 10) continue;
      _drawTagBox(canvas, cW, y.clamp(4.0, cH - 14.0), hl.price,
          hl.id == selectedId ? Colors.white : hl.color,
          hasAlert: hl.hasAlert);
    }

    // ── Time axis ─────────────────────────────────────
    final totalVis = lastVis - firstVis + 1;
    final step     = math.max(1, totalVis ~/ 6);
    for (int i = firstVis; i <= lastVis; i += step) {
      final x = cX(i);
      if (x < 8 || x > cW - 8) continue;
      final tp = _mkTP(_fmtT(candles[i].time), _axis, 9.0);
      tp.paint(canvas,
          Offset((x - tp.width / 2).clamp(0.0, cW - tp.width), cH + 5));
    }

    // ── Hint text ─────────────────────────────────────
    if (drawTool != DrawTool.cursor) {
      final hint = drawTool == DrawTool.trendLine
          ? (pendingIdx == null ? 'Tap first point' : 'Tap second point')
          : 'Tap to place line';
      final tp = _mkTP(hint, Colors.white.withOpacity(0.3), 10.0);
      tp.paint(canvas, Offset((cW - tp.width) / 2, cH - 22));
    }
  }

  void _drawHandle(Canvas canvas, Offset pt, Color color, {bool sel = false}) {
    if (sel) {
      canvas.drawCircle(pt, 7,
          Paint()..color = color.withOpacity(0.2)..style = PaintingStyle.fill);
    }
    canvas.drawCircle(pt, sel ? 5 : 3.5,
        Paint()..color = sel ? Colors.white : color..style = PaintingStyle.fill);
    canvas.drawCircle(pt, sel ? 5 : 3.5,
        Paint()..color = color.withOpacity(0.5)
          ..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  void _drawExtendedLine(Canvas canvas, double cW, double cH,
      double x1, double y1, double x2, double y2, Color color,
      {double width = 1.3, Color? glow}) {
    const far = 9999.0;
    if (glow != null) {
      final gp = Paint()
        ..color = glow.withOpacity(0.25)
        ..strokeWidth = width + 4
        ..isAntiAlias = true;
      if ((x2 - x1).abs() < 0.5) {
        canvas.drawLine(Offset(x1, -far), Offset(x1, far), gp);
      } else {
        final m = (y2 - y1) / (x2 - x1);
        final b = y1 - m * x1;
        canvas.drawLine(Offset(-far, m * -far + b), Offset(cW + far, m * (cW + far) + b), gp);
      }
    }
    final paint = Paint()..color = color..strokeWidth = width..isAntiAlias = true;
    if ((x2 - x1).abs() < 0.5) {
      canvas.drawLine(Offset(x1, -far), Offset(x1, far), paint);
    } else {
      final m = (y2 - y1) / (x2 - x1);
      final b = y1 - m * x1;
      canvas.drawLine(
          Offset(-far, m * -far + b), Offset(cW + far, m * (cW + far) + b), paint);
    }
  }

  void _dashH(Canvas c, double y, double w, Color col,
      {double dash = 6, double gap = 4, double width = 1.0}) {
    final p = Paint()..color = col..strokeWidth = width;
    double x = 0; bool draw = true;
    while (x < w) {
      final end = math.min(x + (draw ? dash : gap), w);
      if (draw) c.drawLine(Offset(x, y), Offset(end, y), p);
      x = end; draw = !draw;
    }
  }

  void _drawPriceBox(Canvas canvas, double cW, double y, double price,
      Color textCol, Color bgCol) {
    final tp   = _mkTP(_fmtP(price), textCol, 10.0, bold: true);
    final rect = Rect.fromLTWH(cW + 2, y - tp.height / 2 - 2, tp.width + 8, tp.height + 4);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()..color = bgCol);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()..color = textCol.withOpacity(0.35)
          ..style = PaintingStyle.stroke..strokeWidth = 0.8);
    tp.paint(canvas, Offset(cW + 6, y - tp.height / 2));
  }

  void _drawTagBox(Canvas canvas, double cW, double y, double price,
      Color color, {bool hasAlert = false}) {
    final tp   = _mkTP(_fmtP(price), color, 9.0, bold: true);
    final bgW  = tp.width + (hasAlert ? 22 : 8);
    final rect = Rect.fromLTWH(cW + 2, y - tp.height / 2 - 2, bgW, tp.height + 4);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()..color = color.withOpacity(0.2));
    if (hasAlert) {
      // Small bell icon indicator
      canvas.drawCircle(
        Offset(cW + 2 + bgW - 8, y),
        3,
        Paint()..color = Colors.orange..style = PaintingStyle.fill,
      );
    }
    tp.paint(canvas, Offset(cW + 6, y - tp.height / 2));
  }

  void _pt(String text, Color color, double sz, Canvas canvas, Offset o) =>
      _mkTP(text, color, sz).paint(canvas, o);

  TextPainter _mkTP(String text, Color color, double sz, {bool bold = false}) =>
      TextPainter(
        text: TextSpan(text: text, style: TextStyle(
            fontSize: sz, color: color,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        textDirection: TextDirection.ltr,
      )..layout();

  String _fmtP(double v) {
    if (v >= 10000) return v.toStringAsFixed(0);
    if (v >= 100)   return v.toStringAsFixed(2);
    if (v >= 1)     return v.toStringAsFixed(4);
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
      o.candles.length        != candles.length        ||
      o.candleWidth           != candleWidth           ||
      o.scrollCandles         != scrollCandles         ||
      o.trendLines.length     != trendLines.length     ||
      o.horizLines.length     != horizLines.length     ||
      o.pendingIdx            != pendingIdx            ||
      o.pendingPrice          != pendingPrice          ||
      o.pendingScreen         != pendingScreen         ||
      o.selectedId            != selectedId            ||
      o.rangeLo               != rangeLo               ||
      o.rangeHi               != rangeHi               ||
      o.selectedCandleIdx     != selectedCandleIdx     ||
      o.crosshair             != crosshair             ||
      o.livePrice             != livePrice             ||
      o.drawTool              != drawTool              ||
      o.isMoving              != isMoving;
}
