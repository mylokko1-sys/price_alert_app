// ─── services/telegram_service.dart ─────────────────────
// Sends HH/LL, manual price alerts, and candle pattern alerts
// to Telegram. Each method routes to the correct bot(s).

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'candle_pattern_service.dart';

class TelegramService {
  static const String _baseUrl = 'https://api.telegram.org/bot';

  static const Map<String, String> _tfNames = {
    '1m':  '1 Minute',   '3m':  '3 Minutes',  '5m':  '5 Minutes',
    '15m': '15 Minutes', '30m': '30 Minutes',  '1h':  '1 Hour',
    '2h':  '2 Hours',    '4h':  '4 Hours',     '6h':  '6 Hours',
    '8h':  '8 Hours',    '12h': '12 Hours',    '1d':  '1 Day',
    '3d':  '3 Days',     '1w':  '1 Week',      '1M':  '1 Month',
  };

  // ──────────────────────────────────────────────────────
  // ALERT TYPE 1: HIT
  // ──────────────────────────────────────────────────────
  static Future<bool> sendHitAlert({
    required String levelType,
    required double levelPrice,
    required String timeframe,
    required double currentPrice,
    required String symbol,
  }) async {
    final targets = Config.bots.where(
        (b) => b.isConfigured && b.hitTimeframes.contains(timeframe));
    if (targets.isEmpty) return false;

    final isHH   = levelType == 'HH';
    final tfName = _tfNames[timeframe] ?? timeframe;
    final msg =
        '${isHH ? "🔴" : "🟢"} <b>$levelType Level Hit!</b>\n\n'
        '📊 <b>Symbol:</b>        $symbol\n'
        '⏱ <b>Timeframe:</b>    $tfName\n'
        '🎯 <b>Level Price:</b>  <code>${levelPrice.toStringAsFixed(5)}</code>\n'
        '💰 <b>Current Price:</b> <code>${currentPrice.toStringAsFixed(5)}</code>\n'
        '📌 <b>Signal:</b>       ${isHH ? "Resistance hit — watch for reversal ↓" : "Support hit — watch for bounce ↑"}\n';

    bool anyOk = false;
    for (final bot in targets) {
      if (await _sendToBot(bot, msg)) anyOk = true;
    }
    return anyOk;
  }

  // ──────────────────────────────────────────────────────
  // ALERT TYPE 2: NEW LEVEL
  // ──────────────────────────────────────────────────────
  static Future<bool> sendNewLevelAlert({
    required String levelType,
    required double levelPrice,
    required String timeframe,
    required String symbol,
  }) async {
    final targets = Config.bots.where(
        (b) => b.isConfigured && b.newTimeframes.contains(timeframe));
    if (targets.isEmpty) return false;

    final isHH  = levelType == 'HH';
    final tfName = _tfNames[timeframe] ?? timeframe;
    final msg =
        '${isHH ? "📈" : "📉"} <b>New ${isHH ? "Higher High" : "Lower Low"} Formed!</b>\n\n'
        '📊 <b>Symbol:</b>       $symbol\n'
        '⏱ <b>Timeframe:</b>   $tfName\n'
        '🎯 <b>Level Price:</b> <code>${levelPrice.toStringAsFixed(5)}</code>\n'
        '📌 <b>Signal:</b>      ${isHH ? "New resistance zone formed ↑" : "New support zone formed ↓"}\n';

    bool anyOk = false;
    for (final bot in targets) {
      if (await _sendToBot(bot, msg)) anyOk = true;
    }
    return anyOk;
  }

  // ──────────────────────────────────────────────────────
  // ALERT TYPE 3: PRICE ALERT
  // ──────────────────────────────────────────────────────
  static Future<bool> sendPriceAlert({
    required TelegramBot bot,
    required PriceAlert  alert,
    required double      currentPrice,
  }) async {
    if (!bot.isConfigured) return false;

    final String emoji;
    final String signal;
    switch (alert.condition) {
      case 'above':
        emoji  = '🚀';
        signal = 'Price crossed above ${alert.targetPrice.toStringAsFixed(5)}';
        break;
      case 'below':
        emoji  = '📉';
        signal = 'Price crossed below ${alert.targetPrice.toStringAsFixed(5)}';
        break;
      case 'touch':
        emoji  = '🎯';
        signal = 'Price touched ${alert.targetPrice.toStringAsFixed(5)}';
        break;
      default:
        emoji  = '🔔';
        signal = 'Price reached ${alert.targetPrice.toStringAsFixed(5)}';
    }

    final dispLabel = alert.label.isNotEmpty
        ? alert.label
        : '${alert.symbol} Price Alert';

    final msg =
        '$emoji <b>Price Alert Triggered!</b>\n\n'
        '🏷 <b>Alert:</b>   $dispLabel\n'
        '📊 <b>Symbol:</b>  ${alert.symbol}\n'
        '🎯 <b>Target:</b>  <code>${alert.targetPrice.toStringAsFixed(5)}</code>\n'
        '💰 <b>Current:</b> <code>${currentPrice.toStringAsFixed(5)}</code>\n'
        '📌 <b>Signal:</b>  $signal\n';

    return _sendToBot(bot, msg);
  }

  // ──────────────────────────────────────────────────────
  // ALERT TYPE 4: CANDLE PATTERN
  // Called once per detected (pattern × timeframe) combo.
  // [pattern]   — the specific code that fired: 'BE', 'MS', or 'ES'
  // [timeframe] — the specific timeframe on which it fired
  // ──────────────────────────────────────────────────────
  static Future<bool> sendCandlePatternAlert({
    required TelegramBot        bot,
    required CandlePatternAlert alert,
    required String             pattern,
    required String             timeframe,
    required double             livePrice,
    required DateTime           signalTime,
  }) async {
    if (!bot.isConfigured) return false;

    final patternEnum = CandlePatternExt.fromString(pattern);
    final tfName      = _tfNames[timeframe] ?? timeframe;
    final dispLabel   = alert.label.isNotEmpty
        ? alert.label
        : '${alert.symbol} — ${patternEnum.label}';

    final String directionNote;
    switch (patternEnum) {
      case CandlePattern.BE:
        directionNote = 'Bullish reversal signal — potential upside ↑';
        break;
      case CandlePattern.MS:
        directionNote = 'Bullish reversal signal — potential upside ↑';
        break;
      case CandlePattern.ES:
        directionNote = 'Bearish reversal signal — potential downside ↓';
        break;
    }

    final timeStr =
        '${signalTime.hour.toString().padLeft(2, '0')}:'
        '${signalTime.minute.toString().padLeft(2, '0')}';

    final msg =
        '${patternEnum.emoji} <b>${patternEnum.label} Detected!</b>\n\n'
        '🏷 <b>Alert:</b>      $dispLabel\n'
        '📊 <b>Symbol:</b>     ${alert.symbol}\n'
        '⏱ <b>Timeframe:</b>  $tfName\n'
        '🕯 <b>Pattern:</b>    ${patternEnum.label} (${patternEnum.shortLabel})\n'
        '💰 <b>Price:</b>      <code>${livePrice.toStringAsFixed(5)}</code>\n'
        '🕐 <b>Signal bar:</b> $timeStr\n'
        '📌 <b>Signal:</b>     $directionNote\n';

    return _sendToBot(bot, msg);
  }

  // ──────────────────────────────────────────────────────
  // TEST connection for a specific bot
  // ──────────────────────────────────────────────────────
  static Future<String?> testConnection(TelegramBot bot) async {
    if (!bot.isConfigured) {
      return bot.token.isEmpty || bot.token == 'YOUR_TELEGRAM_BOT_TOKEN'
          ? 'Bot token is not set'
          : 'Chat ID is not set';
    }
    final hitTfs = bot.hitTimeframes.isEmpty ? 'None' : bot.hitTimeframes.join(', ');
    final newTfs = bot.newTimeframes.isEmpty ? 'None' : bot.newTimeframes.join(', ');
    try {
      final uri      = Uri.parse('${_baseUrl}${bot.token}/sendMessage');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id':    bot.chatId,
          'text':
              '✅ <b>HH/LL Bot Connected!</b>\n\n'
              '🤖 Bot: <b>${bot.name}</b>\n\n'
              '🎯 Hit alert timeframes: <code>$hitTfs</code>\n'
              '✨ New level timeframes: <code>$newTfs</code>\n\n'
              'Bot is configured and ready.',
          'parse_mode': 'HTML',
        }),
      ).timeout(const Duration(seconds: 10));
      final body = jsonDecode(response.body);
      if (response.statusCode == 200 && body['ok'] == true) return null;
      return body['description'] as String? ?? 'Unknown Telegram error';
    } catch (e) {
      return 'Network error: $e';
    }
  }

  // ──────────────────────────────────────────────────────
  // PRIVATE: send one message to one bot
  // ──────────────────────────────────────────────────────
  static Future<bool> _sendToBot(TelegramBot bot, String message) async {
    try {
      final uri      = Uri.parse('${_baseUrl}${bot.token}/sendMessage');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id':    bot.chatId,
          'text':       message,
          'parse_mode': 'HTML',
        }),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body['ok'] == true) return true;
        print('❌ Telegram error [${bot.name}]: ${body['description']}');
        return false;
      }
      print('❌ Telegram HTTP ${response.statusCode} [${bot.name}]');
      return false;
    } catch (e) {
      print('❌ Telegram network error [${bot.name}]: $e');
      return false;
    }
  }
}
