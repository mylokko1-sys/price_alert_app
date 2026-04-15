// ─── config.dart ────────────────────────────────────────
// Runtime-editable config. Supports multiple Telegram bots
// with per-bot per-alert-type timeframe selection,
// plus manual price alerts and candle pattern alerts.

import 'dart:convert';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ══════════════════════════════════════════════════════════
// ─── API PROVIDERS ───────────────────────────────────────
// ══════════════════════════════════════════════════════════
enum ApiProvider {
  binance('Binance'),
  okx('OKX'),
  bybit('ByBit'),
  kucoin('KuCoin'),
  kraken('Kraken');

  final String displayName;
  const ApiProvider(this.displayName);

  static ApiProvider fromString(String? value) {
    if (value == null || value.isEmpty) return binance;
    return ApiProvider.values.firstWhere(
      (p) => p.name == value,
      orElse: () => binance,
    );
  }
}

const List<String> kAllTimeframes = [
  '1m',
  '3m',
  '5m',
  '15m',
  '30m',
  '1h',
  '2h',
  '4h',
  '6h',
  '8h',
  '12h',
  '1d',
  '3d',
  '1w',
  '1M',
];

// ══════════════════════════════════════════════════════════
// ─── TELEGRAM BOT ────────────────────────────────────────
// ══════════════════════════════════════════════════════════
class TelegramBot {
  final String id;
  String name;
  String token;
  String chatId;
  List<String> hitTimeframes;
  List<String> newTimeframes;
  bool canReceiveManualAlerts;

  TelegramBot({
    required this.id,
    required this.name,
    required this.token,
    required this.chatId,
    List<String>? hitTimeframes,
    List<String>? newTimeframes,
    this.canReceiveManualAlerts = false,
  }) : hitTimeframes = hitTimeframes ?? [],
       newTimeframes = newTimeframes ?? [];

  bool get alertOnHit => hitTimeframes.isNotEmpty;
  bool get alertOnNew => newTimeframes.isNotEmpty;
  bool get isConfigured =>
      token.isNotEmpty &&
      token != 'YOUR_TELEGRAM_BOT_TOKEN' &&
      chatId.isNotEmpty &&
      chatId != 'YOUR_TELEGRAM_CHAT_ID';

  TelegramBot copyWith({
    String? name,
    String? token,
    String? chatId,
    List<String>? hitTimeframes,
    List<String>? newTimeframes,
    bool? canReceiveManualAlerts,
  }) => TelegramBot(
    id: id,
    name: name ?? this.name,
    token: token ?? this.token,
    chatId: chatId ?? this.chatId,
    hitTimeframes: hitTimeframes ?? List.from(this.hitTimeframes),
    newTimeframes: newTimeframes ?? List.from(this.newTimeframes),
    canReceiveManualAlerts:
        canReceiveManualAlerts ?? this.canReceiveManualAlerts,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'token': token,
    'chatId': chatId,
    'hitTimeframes': hitTimeframes,
    'newTimeframes': newTimeframes,
    'canReceiveManualAlerts': canReceiveManualAlerts,
  };

  factory TelegramBot.fromJson(Map<String, dynamic> j) {
    List<String> parseTfList(dynamic raw, bool fallback) =>
        raw is List ? List<String>.from(raw) : (fallback ? ['30m', '1h'] : []);
    return TelegramBot(
      id: j['id'] as String? ?? _genId(),
      name: j['name'] as String? ?? 'Bot',
      token: j['token'] as String? ?? '',
      chatId: j['chatId'] as String? ?? '',
      hitTimeframes: parseTfList(
        j['hitTimeframes'],
        j['alertOnHit'] as bool? ?? true,
      ),
      newTimeframes: parseTfList(
        j['newTimeframes'],
        j['alertOnNew'] as bool? ?? false,
      ),
      canReceiveManualAlerts: j['canReceiveManualAlerts'] as bool? ?? false,
    );
  }

  static String _genId() => DateTime.now().millisecondsSinceEpoch.toString();
}

// ══════════════════════════════════════════════════════════
// ─── PRICE ALERT ─────────────────────────────────────────
// ══════════════════════════════════════════════════════════
class PriceAlert {
  final String id;
  String symbol;
  double targetPrice;
  String condition;
  String botId;
  String label;
  bool isActive;
  bool isTriggered;
  final DateTime createdAt;

  PriceAlert({
    required this.id,
    required this.symbol,
    required this.targetPrice,
    required this.condition,
    required this.botId,
    this.label = '',
    this.isActive = true,
    this.isTriggered = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get shouldFire => isActive && !isTriggered;

  bool matches(double currentPrice) {
    switch (condition) {
      case 'above':
        return currentPrice >= targetPrice;
      case 'below':
        return currentPrice <= targetPrice;
      case 'touch':
        final pct = (currentPrice - targetPrice).abs() / targetPrice;
        return pct <= 0.0005; // ±0.05% tolerance
      default:
        return false;
    }
  }

  PriceAlert copyWith({
    String? symbol,
    double? targetPrice,
    String? condition,
    String? botId,
    String? label,
    bool? isActive,
    bool? isTriggered,
  }) => PriceAlert(
    id: id,
    symbol: symbol ?? this.symbol,
    targetPrice: targetPrice ?? this.targetPrice,
    condition: condition ?? this.condition,
    botId: botId ?? this.botId,
    label: label ?? this.label,
    isActive: isActive ?? this.isActive,
    isTriggered: isTriggered ?? this.isTriggered,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'symbol': symbol,
    'targetPrice': targetPrice,
    'condition': condition,
    'botId': botId,
    'label': label,
    'isActive': isActive,
    'isTriggered': isTriggered,
    'createdAt': createdAt.toIso8601String(),
  };

  factory PriceAlert.fromJson(Map<String, dynamic> j) => PriceAlert(
    id: j['id'] as String? ?? _genId(),
    symbol: j['symbol'] as String,
    targetPrice: (j['targetPrice'] as num).toDouble(),
    condition: j['condition'] as String,
    botId: j['botId'] as String,
    label: j['label'] as String? ?? '',
    isActive: j['isActive'] as bool? ?? true,
    isTriggered: j['isTriggered'] as bool? ?? false,
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
  );

  static String _genId() => DateTime.now().microsecondsSinceEpoch.toString();
}

// ══════════════════════════════════════════════════════════
// ─── CANDLE PATTERN ALERT ────────────────────────────────
// One alert can watch MULTIPLE patterns (BE / MS / ES) across
// MULTIPLE timeframes on a single symbol.
// The background service fires once per unique
// (pattern × timeframe) combination that detects a signal.
// ══════════════════════════════════════════════════════════
class CandlePatternAlert {
  final String id;
  String symbol;

  /// One or more pattern codes: 'BE', 'MS', 'ES'
  List<String> patterns;

  /// One or more timeframes: e.g. ['1h', '4h', '1d']
  List<String> timeframes;

  String botId;
  String label;
  bool isActive;
  final DateTime createdAt;

  CandlePatternAlert({
    required this.id,
    required this.symbol,
    required this.patterns,
    required this.timeframes,
    required this.botId,
    this.label = '',
    this.isActive = true,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get shouldCheck =>
      isActive && patterns.isNotEmpty && timeframes.isNotEmpty;

  CandlePatternAlert copyWith({
    String? symbol,
    List<String>? patterns,
    List<String>? timeframes,
    String? botId,
    String? label,
    bool? isActive,
  }) => CandlePatternAlert(
    id: id,
    symbol: symbol ?? this.symbol,
    patterns: patterns ?? List.from(this.patterns),
    timeframes: timeframes ?? List.from(this.timeframes),
    botId: botId ?? this.botId,
    label: label ?? this.label,
    isActive: isActive ?? this.isActive,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'symbol': symbol,
    'patterns': patterns,
    'timeframes': timeframes,
    'botId': botId,
    'label': label,
    'isActive': isActive,
    'createdAt': createdAt.toIso8601String(),
  };

  factory CandlePatternAlert.fromJson(Map<String, dynamic> j) {
    // Backwards-compat: old schema stored single 'pattern' / 'timeframe' strings
    List<String> parseList(dynamic raw, String? singleFallback) {
      if (raw is List) return List<String>.from(raw);
      if (singleFallback != null && singleFallback.isNotEmpty) {
        return [singleFallback];
      }
      return [];
    }

    return CandlePatternAlert(
      id: j['id'] as String? ?? _genId(),
      symbol: j['symbol'] as String,
      patterns: parseList(j['patterns'], j['pattern'] as String?),
      timeframes: parseList(j['timeframes'], j['timeframe'] as String?),
      botId: j['botId'] as String,
      label: j['label'] as String? ?? '',
      isActive: j['isActive'] as bool? ?? true,
      createdAt:
          DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  static String _genId() => DateTime.now().microsecondsSinceEpoch.toString();
}

// ══════════════════════════════════════════════════════════
// ─── CONFIG ──────────────────────────────────────────────
// ══════════════════════════════════════════════════════════
class Config {
  static List<TelegramBot> bots = [_defaultBot()];
  static List<String> symbols = ['BTCUSDT', 'ETHUSDT', 'SOLUSDT', 'XRPUSDT'];
  static int pivotLen = 5;
  static int limit = 1000;
  static int checkEveryMinutes = 5;
  static ApiProvider apiProvider = ApiProvider.binance;
  static List<PriceAlert> priceAlerts = [];
  static List<CandlePatternAlert> candlePatternAlerts = [];

  static List<String> get effectiveTimeframes {
    final Set<String> all = {};
    for (final bot in bots) {
      all.addAll(bot.hitTimeframes);
      all.addAll(bot.newTimeframes);
    }
    return kAllTimeframes.where(all.contains).toList();
  }
}

TelegramBot _defaultBot() => TelegramBot(
  id: 'default',
  name: 'Main Bot',
  token: 'YOUR_TELEGRAM_BOT_TOKEN',
  chatId: 'YOUR_TELEGRAM_CHAT_ID',
  hitTimeframes: ['30m', '1h'],
  newTimeframes: [],
);

// ══════════════════════════════════════════════════════════
// ─── CONFIG SERVICE ──────────────────────────────────────
// ══════════════════════════════════════════════════════════
class ConfigService {
  static const _kBotsV2 = 'cfg_bots_v2';
  static const _kBotToken = 'cfg_bot_token';
  static const _kChatId = 'cfg_chat_id';
  static const _kSymbols = 'cfg_symbols';
  static const _kPivotLen = 'cfg_pivot_len';
  static const _kLimit = 'cfg_limit';
  static const _kCheckEvery = 'cfg_check_every';
  static const _kApiProvider = 'cfg_api_provider';
  static const _kPriceAlerts = 'cfg_price_alerts_v1';
  static const _kCandlePatternAlerts = 'cfg_candle_pattern_alerts_v1';

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // ── Bots ──────────────────────────────────────────────
    final botsStr = prefs.getString(_kBotsV2);
    if (botsStr != null && botsStr.isNotEmpty) {
      try {
        final list = jsonDecode(botsStr) as List;
        final bots = list
            .map(
              (j) => TelegramBot.fromJson(Map<String, dynamic>.from(j as Map)),
            )
            .toList();
        Config.bots = bots.isNotEmpty ? bots : [_defaultBot()];
      } catch (_) {
        Config.bots = [_defaultBot()];
      }
    } else {
      final oldToken = prefs.getString(_kBotToken);
      final oldChatId = prefs.getString(_kChatId);
      if (oldToken != null && oldToken.isNotEmpty) {
        Config.bots = [
          TelegramBot(
            id: 'migrated',
            name: 'Main Bot',
            token: oldToken,
            chatId: oldChatId ?? '',
            hitTimeframes: ['30m', '1h'],
            newTimeframes: [],
          ),
        ];
        await _persistBots(prefs);
      }
    }

    // ── Price Alerts ──────────────────────────────────────
    final alertsStr = prefs.getString(_kPriceAlerts);
    if (alertsStr != null && alertsStr.isNotEmpty) {
      try {
        final list = jsonDecode(alertsStr) as List;
        Config.priceAlerts = list
            .map(
              (j) => PriceAlert.fromJson(Map<String, dynamic>.from(j as Map)),
            )
            .toList();
      } catch (_) {
        Config.priceAlerts = [];
      }
    }

    // ── Candle Pattern Alerts ─────────────────────────────
    final cpStr = prefs.getString(_kCandlePatternAlerts);
    if (cpStr != null && cpStr.isNotEmpty) {
      try {
        final list = jsonDecode(cpStr) as List;
        Config.candlePatternAlerts = list
            .map(
              (j) => CandlePatternAlert.fromJson(
                Map<String, dynamic>.from(j as Map),
              ),
            )
            .toList();
      } catch (_) {
        Config.candlePatternAlerts = [];
      }
    }

    Config.symbols = prefs.getStringList(_kSymbols) ?? Config.symbols;
    Config.pivotLen = prefs.getInt(_kPivotLen) ?? Config.pivotLen;
    Config.limit = prefs.getInt(_kLimit) ?? Config.limit;
    Config.checkEveryMinutes =
        prefs.getInt(_kCheckEvery) ?? Config.checkEveryMinutes;
    Config.apiProvider = ApiProvider.fromString(prefs.getString(_kApiProvider));
  }

  static Future<void> _pushToBackground() async {
    final svc = FlutterBackgroundService();
    if (!await svc.isRunning()) return;
    svc.invoke('updateConfig', {
      'bots': Config.bots.map((b) => b.toJson()).toList(),
      'symbols': Config.symbols,
      'pivotLen': Config.pivotLen,
      'limit': Config.limit,
      'checkEveryMinutes': Config.checkEveryMinutes,
      'apiProvider': Config.apiProvider.name,
      'priceAlerts': Config.priceAlerts.map((a) => a.toJson()).toList(),
      'candlePatternAlerts': Config.candlePatternAlerts
          .map((a) => a.toJson())
          .toList(),
    });
  }

  static Future<void> _persistBots(SharedPreferences prefs) async =>
      prefs.setString(
        _kBotsV2,
        jsonEncode(Config.bots.map((b) => b.toJson()).toList()),
      );

  static Future<void> _persistAlerts(SharedPreferences prefs) async =>
      prefs.setString(
        _kPriceAlerts,
        jsonEncode(Config.priceAlerts.map((a) => a.toJson()).toList()),
      );

  static Future<void> _persistCandlePatternAlerts(
    SharedPreferences prefs,
  ) async => prefs.setString(
    _kCandlePatternAlerts,
    jsonEncode(Config.candlePatternAlerts.map((a) => a.toJson()).toList()),
  );

  static Future<void> _clearAllDedupKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final stale = prefs
        .getKeys()
        .where(
          (k) =>
              k.startsWith('HH_') || k.startsWith('LL_') || k.startsWith('CP_'),
        )
        .toList();
    for (final k in stale) await prefs.remove(k);
    print('🧹 Cleared ${stale.length} dedup keys');
  }

  static Future<void> saveBots(List<TelegramBot> bots) async {
    final prefs = await SharedPreferences.getInstance();
    Config.bots = List.from(bots);
    await _persistBots(prefs);
    await _pushToBackground();
  }

  static Future<void> saveSymbols(List<String> newSymbols) async {
    final prefs = await SharedPreferences.getInstance();
    await _clearAllDedupKeys();
    await prefs.setStringList(_kSymbols, newSymbols);
    Config.symbols = newSymbols;
    await _pushToBackground();
  }

  static Future<void> saveIndicator({
    required int pivotLen,
    required int limit,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPivotLen, pivotLen);
    await prefs.setInt(_kLimit, limit);
    Config.pivotLen = pivotLen;
    Config.limit = limit;
    await _pushToBackground();
  }

  static Future<void> saveBotSettings({
    required int checkEveryMinutes,
    ApiProvider? apiProvider,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kCheckEvery, checkEveryMinutes);
    Config.checkEveryMinutes = checkEveryMinutes;
    if (apiProvider != null) {
      await prefs.setString(_kApiProvider, apiProvider.name);
      Config.apiProvider = apiProvider;
    }
    await _pushToBackground();
  }

  static Future<void> savePriceAlerts(List<PriceAlert> alerts) async {
    final prefs = await SharedPreferences.getInstance();
    Config.priceAlerts = List.from(alerts);
    await _persistAlerts(prefs);
    await _pushToBackground();
  }

  static Future<void> savePriceAlertsFromBackground(
    SharedPreferences prefs,
  ) async {
    await _persistAlerts(prefs);
  }

  static Future<void> saveCandlePatternAlerts(
    List<CandlePatternAlert> alerts,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    Config.candlePatternAlerts = List.from(alerts);
    await _persistCandlePatternAlerts(prefs);
    await _pushToBackground();
  }

  static Future<void> saveCandlePatternAlertsFromBackground(
    SharedPreferences prefs,
  ) async {
    await _persistCandlePatternAlerts(prefs);
  }
}
