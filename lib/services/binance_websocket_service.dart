// ─── services/binance_websocket_service.dart ─────────────
// Real-time Binance WebSocket client.
//
// Connects to the combined stream:
//   wss://stream.binance.com:9443/stream?streams=
//     <symbol>@kline_<interval>/<symbol>@miniTicker
//
// Pushes two kinds of updates:
//   • CandleTickUpdate  — live candle every time a trade fires (~100 ms)
//   • PriceTickUpdate   — latest close price from miniTicker
//
// Auto-reconnects with exponential backoff (1 s → 2 s → 4 s … max 30 s).
// Caller must call connect() then listen to the stream.
// Call dispose() when done.

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'binance_service.dart'; // for Candle class

// ── Tick update types ─────────────────────────────────────

class CandleTickUpdate {
  final Candle  candle;
  final bool    isClosed; // true when the kline bar has closed
  const CandleTickUpdate({required this.candle, required this.isClosed});
}

class PriceTickUpdate {
  final double price;
  const PriceTickUpdate(this.price);
}

// ══════════════════════════════════════════════════════════
class BinanceWebSocketService {
  static const String _wsBase = 'wss://stream.binance.com:9443/stream';

  final String _symbol;
  final String _interval;

  WebSocketChannel?          _channel;
  StreamSubscription<dynamic>? _sub;
  final StreamController<Object> _ctrl = StreamController.broadcast();

  Timer?  _reconnectTimer;
  int     _reconnectDelay = 1; // seconds, doubles on each failure
  bool    _disposed       = false;
  bool    _connected      = false;

  /// Stream emits [CandleTickUpdate] and [PriceTickUpdate] objects.
  Stream<Object> get stream => _ctrl.stream;
  bool get isConnected => _connected;

  BinanceWebSocketService({
    required String symbol,
    required String interval,
  })  : _symbol   = symbol.toLowerCase(),
        _interval = interval;

  // ── Connect ───────────────────────────────────────────
  void connect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();

    final sym = _symbol;
    final uri = Uri.parse(
      '$_wsBase?streams=$sym@kline_$_interval/$sym@miniTicker',
    );

    try {
      _channel = WebSocketChannel.connect(uri);
      _connected = true;
      _reconnectDelay = 1; // reset backoff on successful connect

      _sub = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone:  _onDone,
        cancelOnError: false,
      );

      print('🔌 WS connected: $uri');
    } catch (e) {
      print('❌ WS connect failed: $e');
      _connected = false;
      _scheduleReconnect();
    }
  }

  // ── Disconnect / dispose ──────────────────────────────
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _ctrl.close();
    _connected = false;
  }

  // ── Message handler ───────────────────────────────────
  void _onMessage(dynamic raw) {
    if (_disposed) return;
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;

      // Combined stream wraps each message in {"stream":"...","data":{...}}
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final type = data['e'] as String?;

      if (type == 'kline') {
        final k = data['k'] as Map<String, dynamic>;
        final candle = Candle(
          time:   DateTime.fromMillisecondsSinceEpoch(k['t'] as int),
          open:   double.parse(k['o'].toString()),
          high:   double.parse(k['h'].toString()),
          low:    double.parse(k['l'].toString()),
          close:  double.parse(k['c'].toString()),
          volume: double.parse(k['v'].toString()),
        );
        final isClosed = k['x'] as bool? ?? false;
        if (!_ctrl.isClosed) {
          _ctrl.add(CandleTickUpdate(candle: candle, isClosed: isClosed));
        }
      } else if (type == '24hrMiniTicker') {
        final price = double.tryParse(data['c']?.toString() ?? '');
        if (price != null && !_ctrl.isClosed) {
          _ctrl.add(PriceTickUpdate(price));
        }
      }
    } catch (e) {
      // Silently ignore malformed frames
    }
  }

  void _onError(Object error) {
    print('⚠️ WS error: $error');
    _connected = false;
    if (!_disposed) _scheduleReconnect();
  }

  void _onDone() {
    _connected = false;
    if (!_disposed) {
      print('🔌 WS closed — reconnecting in ${_reconnectDelay}s');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _reconnectDelay), () {
      if (!_disposed) connect();
    });
    // Exponential backoff capped at 30 s
    _reconnectDelay = (_reconnectDelay * 2).clamp(1, 30);
  }
}
