// ─── services/background_service.dart ───────────────────
// Background bot. Five alert types run each tick:
//   1. HIT            — price touches an existing HH/LL level
//   2. NEW            — a fresh HH/LL pivot is formed
//   3. PRICE ALERT    — price crosses a manually set level
//   4. CANDLE PATTERN — BE / MS / ES pattern detected on closed candle
//   5. CHART LINES    — price touches drawn trendlines or horizontal lines

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../models/chart_models.dart';
import 'binance_service.dart';
import 'candle_pattern_service.dart';
import 'chart_drawings_storage.dart';
import 'pivot_service.dart';
import 'telegram_service.dart';

Timer? _checkTimer;
bool _isBusy = false;
bool _shouldStop = false;

// ─── Init ─────────────────────────────────────────────────
Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'hh_ll_bot_channel',
    'HH/LL Bot',
    description: 'Running HH/LL Alert Bot',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();
  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'hh_ll_bot_channel',
      initialNotificationTitle: 'HH/LL Bot',
      initialNotificationContent: 'Bot is running...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onBackgroundStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

// ─── Background entry point ───────────────────────────────
@pragma('vm:entry-point')
void onBackgroundStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  _shouldStop = false;
  _isBusy = false;
  _checkTimer?.cancel();
  _checkTimer = null;

  print('🚀 Background service started');
  await ConfigService.load();

  print(
    '✅ Config: ${Config.symbols} | '
    'TFs: ${Config.effectiveTimeframes} | '
    'every ${Config.checkEveryMinutes}m | '
    '${Config.bots.length} bot(s) | '
    '${Config.priceAlerts.length} price alert(s) | '
    '${Config.candlePatternAlerts.length} candle pattern alert(s)',
  );

  // ── Stop ────────────────────────────────────────────────
  service.on('stop').listen((event) {
    print('🛑 Stop command received');
    _shouldStop = true;
    _checkTimer?.cancel();
    _checkTimer = null;
    service.stopSelf();
  });

  // ── Live config update ───────────────────────────────────
  service.on('updateConfig').listen((data) {
    if (data == null) return;
    if (data['bots'] != null) {
      try {
        Config.bots = (data['bots'] as List)
            .map(
              (j) => TelegramBot.fromJson(Map<String, dynamic>.from(j as Map)),
            )
            .toList();
      } catch (e) {
        print('⚠️ Bots parse error: $e');
      }
    }
    if (data['priceAlerts'] != null) {
      try {
        Config.priceAlerts = (data['priceAlerts'] as List)
            .map(
              (j) => PriceAlert.fromJson(Map<String, dynamic>.from(j as Map)),
            )
            .toList();
      } catch (e) {
        print('⚠️ PriceAlerts parse error: $e');
      }
    }
    if (data['candlePatternAlerts'] != null) {
      try {
        Config.candlePatternAlerts = (data['candlePatternAlerts'] as List)
            .map(
              (j) => CandlePatternAlert.fromJson(
                Map<String, dynamic>.from(j as Map),
              ),
            )
            .toList();
      } catch (e) {
        print('⚠️ CandlePatternAlerts parse error: $e');
      }
    }
    if (data['symbols'] != null)
      Config.symbols = List<String>.from(data['symbols'] as List);
    if (data['pivotLen'] != null) Config.pivotLen = data['pivotLen'] as int;
    if (data['limit'] != null) Config.limit = data['limit'] as int;
    if (data['checkEveryMinutes'] != null) {
      final newInterval = data['checkEveryMinutes'] as int;
      if (newInterval != Config.checkEveryMinutes) {
        Config.checkEveryMinutes = newInterval;
        _restartTimer(service);
      }
    }
    print(
      '🔄 Config updated | TFs: ${Config.effectiveTimeframes} | '
      '${Config.priceAlerts.length} price alert(s) | '
      '${Config.candlePatternAlerts.length} candle pattern alert(s)',
    );
  });

  await _runAllChecks(service);
  _restartTimer(service);
}

void _restartTimer(ServiceInstance service) {
  _checkTimer?.cancel();
  _checkTimer = Timer.periodic(Duration(minutes: Config.checkEveryMinutes), (
    timer,
  ) async {
    if (_shouldStop) {
      timer.cancel();
      return;
    }
    if (_isBusy) {
      print('⏳ Skipping tick — still busy');
      return;
    }
    await ConfigService.load();
    await _runAllChecks(service);
  });
  print('⏱ Timer: every ${Config.checkEveryMinutes}m');
}

// ─── Master check loop ────────────────────────────────────
Future<void> _runAllChecks(ServiceInstance service) async {
  if (_isBusy) return;
  _isBusy = true;

  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final timeframes = Config.effectiveTimeframes;
    final now = DateTime.now();
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'HH/LL Bot — $timeStr',
        content: '${Config.symbols.length} pairs · ${timeframes.join(', ')}',
      );
    }
    service.invoke('update', {'lastCheck': timeStr});

    // ── HH/LL checks (hit + new level) ──────────────────
    if (timeframes.isNotEmpty) {
      print('🔍 HH/LL: ${Config.symbols} on $timeframes at $timeStr');
      for (final symbol in Config.symbols) {
        for (final tf in timeframes) {
          if (_shouldStop) return;
          await _checkHHLL(symbol, tf, prefs, service);
        }
      }
    }

    // ── Manual price alerts ──────────────────────────────
    await _checkPriceAlerts(prefs, service);

    // ── Candle pattern alerts ────────────────────────────
    await _checkCandlePatternAlerts(prefs, service);

    // ── Chart line (trendline & horizontal) alerts ────────
    await _checkChartLineAlerts(prefs, service);
  } catch (e) {
    print('❌ Error in _runAllChecks: $e');
  } finally {
    _isBusy = false;
  }
}

// ─── HH/LL check for one symbol + timeframe ───────────────
Future<void> _checkHHLL(
  String symbol,
  String timeframe,
  SharedPreferences prefs,
  ServiceInstance service,
) async {
  try {
    final candles = await BinanceService.fetchCandles(symbol, timeframe);
    if (candles.length < 2) return;

    final result = PivotService.getHHLL(candles);
    final lastClosed = candles[candles.length - 2];
    final liveCandle = candles[candles.length - 1];

    Future<void> checkHit(String type, double? level, bool isHH) async {
      if (level == null) return;
      final key =
          '${type}_HIT_${symbol}_${timeframe}_${level.toStringAsFixed(5)}';
      if (prefs.getBool(key) ?? false) return;
      final isHit = PivotService.isHit(lastClosed, level, isHH) ||
          PivotService.isHit(liveCandle, level, isHH);
      if (!isHit) return;
      final ok = await TelegramService.sendHitAlert(
        levelType: type,
        levelPrice: level,
        timeframe: timeframe,
        currentPrice: liveCandle.close,
        symbol: symbol,
      );
      if (ok) {
        await prefs.setBool(key, true);
        service.invoke('alert', {
          'symbol': symbol,
          'type': type,
          'kind': 'hit',
          'price': level,
          'timeframe': timeframe,
          'time': DateTime.now().toIso8601String(),
        });
        print('✅ HIT $symbol $type @ $level ($timeframe)');
      }
    }

    Future<void> checkNew(String type, double? level) async {
      if (level == null) return;
      final key =
          '${type}_NEW_${symbol}_${timeframe}_${level.toStringAsFixed(5)}';
      if (prefs.getBool(key) ?? false) return;
      final ok = await TelegramService.sendNewLevelAlert(
        levelType: type,
        levelPrice: level,
        timeframe: timeframe,
        symbol: symbol,
      );
      await prefs.setBool(key, true);
      if (ok) {
        service.invoke('alert', {
          'symbol': symbol,
          'type': type,
          'kind': 'new',
          'price': level,
          'timeframe': timeframe,
          'time': DateTime.now().toIso8601String(),
        });
        print('✨ NEW $symbol $type @ $level ($timeframe)');
      }
    }

    await checkHit('HH', result.hh, true);
    await checkHit('LL', result.ll, false);
    await checkNew('HH', result.hh);
    await checkNew('LL', result.ll);
  } catch (e) {
    print('❌ Error on $symbol $timeframe: $e');
  }
}

// ─── Manual price alert check ─────────────────────────────
Future<void> _checkPriceAlerts(
  SharedPreferences prefs,
  ServiceInstance service,
) async {
  final active = Config.priceAlerts.where((a) => a.shouldFire).toList();
  if (active.isEmpty) return;

  print('🔔 Checking ${active.length} price alert(s)...');

  final Map<String, List<PriceAlert>> bySymbol = {};
  for (final alert in active) {
    bySymbol.putIfAbsent(alert.symbol, () => []).add(alert);
  }

  bool anyTriggered = false;

  for (final entry in bySymbol.entries) {
    if (_shouldStop) break;

    final symbol = entry.key;
    final currentPrice = await BinanceService.getCurrentPrice(symbol);
    if (currentPrice == null) {
      print('⚠️ Could not get price for $symbol — skipping');
      continue;
    }

    for (final alert in entry.value) {
      if (!alert.matches(currentPrice)) continue;

      TelegramBot? bot;
      try {
        bot = Config.bots.firstWhere((b) => b.id == alert.botId);
      } catch (_) {
        try {
          bot = Config.bots.firstWhere(
            (b) => b.isConfigured && b.canReceiveManualAlerts,
          );
        } catch (_) {}
      }

      if (bot == null || !bot.isConfigured) {
        print('⚠️ No configured bot for alert "${alert.label}" — skipping');
        alert.isTriggered = true;
        anyTriggered = true;
        continue;
      }

      final ok = await TelegramService.sendPriceAlert(
        bot: bot,
        alert: alert,
        currentPrice: currentPrice,
      );

      alert.isTriggered = true;
      anyTriggered = true;

      if (ok) {
        service.invoke('priceAlert', {
          'id': alert.id,
          'symbol': alert.symbol,
          'label': alert.label,
          'targetPrice': alert.targetPrice,
          'currentPrice': currentPrice,
          'condition': alert.condition,
          'time': DateTime.now().toIso8601String(),
        });
        print(
          '🔔 PRICE ALERT: ${alert.label.isNotEmpty ? alert.label : alert.symbol} '
          '@ $currentPrice (target ${alert.targetPrice})',
        );
      } else {
        print('❌ Price alert send failed for ${alert.symbol}');
      }
    }
  }

  if (anyTriggered) {
    await ConfigService.savePriceAlertsFromBackground(prefs);
  }
}

// ─── Candle pattern alert check ───────────────────────────
// Each alert now carries List<patterns> × List<timeframes>.
// We collect all unique (symbol, timeframe) pairs first so we
// only fetch candles once per pair, then check every pattern
// for every alert that references that pair.
//
// Dedup key: CP_<PATTERN>_<SYMBOL>_<TF>_<signalCandleEpochSec>
// ensures the same closed candle never fires the same alert twice.
Future<void> _checkCandlePatternAlerts(
  SharedPreferences prefs,
  ServiceInstance service,
) async {
  final active =
      Config.candlePatternAlerts.where((a) => a.shouldCheck).toList();
  if (active.isEmpty) return;

  // ── 1. Collect all unique (symbol, timeframe) combos needed ──
  final Set<String> uniquePairs = {};
  for (final alert in active) {
    for (final tf in alert.timeframes) {
      uniquePairs.add('${alert.symbol}|$tf');
    }
  }

  print(
    '🕯 Candle pattern check: ${active.length} alert(s) → '
    '${uniquePairs.length} symbol/TF pair(s)',
  );

  // ── 2. Fetch candles once per unique pair ─────────────────
  final Map<String, List<Candle>> candleCache = {};
  for (final pair in uniquePairs) {
    if (_shouldStop) return;
    final parts = pair.split('|');
    final symbol = parts[0];
    final tf = parts[1];
    try {
      final candles = await BinanceService.fetchCandles(symbol, tf);
      if (candles.length >= 7) {
        candleCache[pair] = candles;
      } else {
        print('⚠️ Not enough candles for $symbol $tf (got ${candles.length})');
      }
    } catch (e) {
      print('❌ Candle fetch failed for $symbol $tf: $e');
    }
  }

  // ── 3. For every alert, iterate patterns × timeframes ─────
  for (final alert in active) {
    if (_shouldStop) break;

    // Resolve bot once per alert
    TelegramBot? bot;
    try {
      bot = Config.bots.firstWhere((b) => b.id == alert.botId);
    } catch (_) {
      try {
        bot = Config.bots.firstWhere((b) => b.isConfigured);
      } catch (_) {}
    }

    if (bot == null || !bot.isConfigured) {
      print(
        '⚠️ No configured bot for candle pattern alert '
        '"${alert.label.isNotEmpty ? alert.label : alert.symbol}" — skipping',
      );
      continue;
    }

    for (final tf in alert.timeframes) {
      if (_shouldStop) break;

      final cacheKey = '${alert.symbol}|$tf';
      final candles = candleCache[cacheKey];
      if (candles == null) continue;

      final signalTime = CandlePatternService.signalCandleTime(candles);
      if (signalTime == null) continue;
      final candleTs = (signalTime.millisecondsSinceEpoch ~/ 1000).toString();
      final livePrice = candles.last.close;

      for (final patternCode in alert.patterns) {
        if (_shouldStop) break;

        final patternEnum = CandlePatternExt.fromString(patternCode);

        // Dedup key — unique per pattern + symbol + timeframe + closed candle
        final dedupKey = 'CP_${patternCode}_${alert.symbol}_${tf}_$candleTs';
        if (prefs.getBool(dedupKey) ?? false) continue;

        final detected = CandlePatternService.detect(candles, patternEnum);
        if (!detected) continue;

        final ok = await TelegramService.sendCandlePatternAlert(
          bot: bot,
          alert: alert,
          pattern: patternCode,
          timeframe: tf,
          livePrice: livePrice,
          signalTime: signalTime,
        );

        // Always mark dedup so we don't re-alert the same candle
        await prefs.setBool(dedupKey, true);

        if (ok) {
          service.invoke('candlePatternAlert', {
            'id': alert.id,
            'symbol': alert.symbol,
            'pattern': patternCode,
            'timeframe': tf,
            'label': alert.label,
            'price': livePrice,
            'time': DateTime.now().toIso8601String(),
          });
          print(
            '🕯 CANDLE PATTERN: $patternCode on ${alert.symbol} $tf '
            '@ ${livePrice.toStringAsFixed(5)}',
          );
        } else {
          print(
            '❌ Candle pattern send failed: $patternCode ${alert.symbol} $tf',
          );
        }
      }
    }
  }
}

// ─── Chart Line Alert Check ──────────────────────────────
// Checks trendlines and horizontal lines with hasAlert=true
// for price touches. Uses proximity detection with 0.1% tolerance.
//
// Dedup key: CHARTLINE_<LINE_ID>_<PRICE_TOUCH_TIMESTAMP>
// ensures the same touch doesn't fire twice.
Future<void> _checkChartLineAlerts(
  SharedPreferences prefs,
  ServiceInstance service,
) async {
  try {
    final allDrawings = await ChartDrawingsStorage.loadAllWithAlerts();
    if (allDrawings.isEmpty) {
      print('📏 Chart line alerts: no drawings with alerts found');
      return;
    }

    print(
      '📏 Checking ${allDrawings.length} symbol(s) for chart line alerts...',
    );

    for (final entry in allDrawings.entries) {
      if (_shouldStop) return;

      final symbol = entry.key;
      final bundle = entry.value;

      // Get current price for this symbol
      final currentPrice = await BinanceService.getCurrentPrice(symbol);
      if (currentPrice == null) {
        print(
          '⚠️ Could not get current price for $symbol — skipping chart lines',
        );
        continue;
      }

      // Check trendlines with alerts enabled
      for (final tl in bundle.trendLines.where((t) => t.hasAlert)) {
        if (_shouldStop) return;
        await _checkTrendlineTouch(symbol, tl, currentPrice, prefs, service);
      }

      // Check horizontal lines with alerts enabled
      for (final hl in bundle.horizLines.where((h) => h.hasAlert)) {
        if (_shouldStop) return;
        await _checkHorizontalTouch(symbol, hl, currentPrice, prefs, service);
      }
    }
  } catch (e) {
    print('❌ Error in _checkChartLineAlerts: $e');
  }
}

// ─── Trendline Touch Check ────────────────────────────────
// Calculates the trendline price at current time and checks
// if current price is within 0.1% tolerance (proximity detection).
Future<void> _checkTrendlineTouch(
  String symbol,
  TrendLineData tl,
  double currentPrice,
  SharedPreferences prefs,
  ServiceInstance service,
) async {
  try {
    // Calculate the expected price on the trendline at current time
    final now = DateTime.now();
    final expectedPrice = tl.priceAtTime(now);

    // ±0.05% proximity tolerance
    final tolerance = expectedPrice * 0.0005;
    final priceDiff = (currentPrice - expectedPrice).abs();

    // Check if price is within tolerance (touching the line)
    if (priceDiff > tolerance) {
      return; // Not close enough to trigger
    }

    // Dedup key: prevent firing the same touch multiple times within a time window
    final dedupKey = 'TRENDLINE_${tl.id}_TOUCH_${now.hour}_${now.minute}';
    if (prefs.getBool(dedupKey) ?? false) {
      return; // Already fired this minute
    }

    // Get the bot assigned to this trendline alert
    TelegramBot? bot;
    try {
      bot = Config.bots.firstWhere((b) => b.id == tl.botId);
    } catch (_) {
      try {
        bot = Config.bots.firstWhere(
          (b) => b.isConfigured && b.canReceiveManualAlerts,
        );
      } catch (_) {}
    }

    if (bot == null || !bot.isConfigured) {
      print('⚠️ No configured bot for trendline "${tl.id}" — skipping');
      return;
    }

    // Send alert via Telegram
    final ok = await TelegramService.sendDrawnLineHitAlert(
      bot: bot,
      symbol: symbol,
      timeframe: 'Live', // No specific timeframe for drawn lines
      lineType: 'Trend Line',
      linePrice: expectedPrice,
      currentPrice: currentPrice,
    );

    // Mark as sent to prevent duplicate alerts this minute
    await prefs.setBool(dedupKey, true);

    if (ok) {
      service.invoke('chartLineAlert', {
        'symbol': symbol,
        'lineId': tl.id,
        'lineType': 'Trend Line',
        'linePrice': expectedPrice,
        'currentPrice': currentPrice,
        'time': DateTime.now().toIso8601String(),
      });
      print(
        '🚀 TRENDLINE HIT: $symbol @ ${expectedPrice.toStringAsFixed(5)} '
        '(current: ${currentPrice.toStringAsFixed(5)})',
      );
    } else {
      print('❌ Trendline alert send failed for $symbol');
    }

    // Remove the alert from storage (always execute)
    try {
      final bundle = await ChartDrawingsStorage.load(symbol);
      final updatedTls = bundle.trendLines
          .map(
            (t) => t.id == tl.id ? t.copyWith(hasAlert: false, botId: '') : t,
          )
          .toList();
      await ChartDrawingsStorage.save(
        symbol: symbol,
        trendLines: updatedTls,
        horizLines: bundle.horizLines,
      );
      print('✅ Trendline alert removed from list after firing');
    } catch (e) {
      print('⚠️ Could not remove trendline alert from storage: $e');
    }
  } catch (e) {
    print('❌ Error checking trendline touch: $e');
  }
}

// ─── Horizontal Line Touch Check ──────────────────────────
// Checks if current price is within 0.1% tolerance of the
// horizontal line price (proximity detection).
Future<void> _checkHorizontalTouch(
  String symbol,
  HorizLineData hl,
  double currentPrice,
  SharedPreferences prefs,
  ServiceInstance service,
) async {
  try {
    // ±0.05% proximity tolerance
    final tolerance = hl.price * 0.0005;
    final priceDiff = (currentPrice - hl.price).abs();

    // Check if price is within tolerance (touching the line)
    if (priceDiff > tolerance) {
      return; // Not close enough to trigger
    }

    // Dedup key: prevent firing the same touch multiple times within a time window
    final now = DateTime.now();
    final dedupKey = 'HLINE_${hl.id}_TOUCH_${now.hour}_${now.minute}';
    if (prefs.getBool(dedupKey) ?? false) {
      return; // Already fired this minute
    }

    // Get the bot assigned to this horizontal line alert
    TelegramBot? bot;
    try {
      bot = Config.bots.firstWhere((b) => b.id == hl.botId);
    } catch (_) {
      try {
        bot = Config.bots.firstWhere(
          (b) => b.isConfigured && b.canReceiveManualAlerts,
        );
      } catch (_) {}
    }

    if (bot == null || !bot.isConfigured) {
      print('⚠️ No configured bot for horizontal line "${hl.id}" — skipping');
      return;
    }

    // Send alert via Telegram
    final ok = await TelegramService.sendDrawnLineHitAlert(
      bot: bot,
      symbol: symbol,
      timeframe: 'Live', // No specific timeframe for drawn lines
      lineType: 'Horizontal Line',
      linePrice: hl.price,
      currentPrice: currentPrice,
    );

    // Mark as sent to prevent duplicate alerts this minute
    await prefs.setBool(dedupKey, true);

    if (ok) {
      service.invoke('chartLineAlert', {
        'symbol': symbol,
        'lineId': hl.id,
        'lineType': 'Horizontal Line',
        'linePrice': hl.price,
        'currentPrice': currentPrice,
        'time': DateTime.now().toIso8601String(),
      });
      print(
        '🚀 HLINE HIT: $symbol @ ${hl.price.toStringAsFixed(5)} '
        '(current: ${currentPrice.toStringAsFixed(5)})',
      );
    } else {
      print('❌ Horizontal line alert send failed for $symbol');
    }

    // Remove the alert from storage (always execute)
    try {
      final bundle = await ChartDrawingsStorage.load(symbol);
      final updatedHls = bundle.horizLines
          .map(
            (h) => h.id == hl.id ? h.copyWith(hasAlert: false, botId: '') : h,
          )
          .toList();
      await ChartDrawingsStorage.save(
        symbol: symbol,
        trendLines: bundle.trendLines,
        horizLines: updatedHls,
      );
      print('✅ Horizontal line alert removed from list after firing');
    } catch (e) {
      print('⚠️ Could not remove horizontal line alert from storage: $e');
    }
  } catch (e) {
    print('❌ Error checking horizontal line touch: $e');
  }
}
