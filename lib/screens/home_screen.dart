// ─── screens/home_screen.dart ────────────────────────────
// HomeBody: bot toggle, watched pairs, alert log.
// No Scaffold here — MainShell owns the Scaffold + bottom nav.

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';

class AlertLog {
  final String symbol;
  final String type; // 'HH' or 'LL'
  final String kind; // 'hit' or 'new'
  final double price;
  final String timeframe;
  final DateTime time;

  AlertLog({
    required this.symbol,
    required this.type,
    required this.kind,
    required this.price,
    required this.timeframe,
    required this.time,
  });
}

class HomeBody extends StatefulWidget {
  const HomeBody({super.key});

  @override
  State<HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends State<HomeBody> {
  bool _isRunning = false;
  String _lastCheck = '—';
  final List<AlertLog> _alertLogs = [];

  @override
  void initState() {
    super.initState();
    _checkIfRunning();
    _listenToBackground();
  }

  Future<void> _checkIfRunning() async {
    final running = await FlutterBackgroundService().isRunning();
    if (mounted) setState(() => _isRunning = running);
  }

  void _listenToBackground() {
    final service = FlutterBackgroundService();

    service.on('update').listen((data) {
      if (data != null && mounted) {
        setState(() => _lastCheck = data['lastCheck'] ?? '—');
      }
    });

    service.on('alert').listen((data) {
      if (data != null && mounted) {
        setState(() {
          _alertLogs.insert(
            0,
            AlertLog(
              symbol: data['symbol'] as String,
              type: data['type'] as String,
              kind: data['kind'] as String? ?? 'hit',
              price: (data['price'] as num).toDouble(),
              timeframe: data['timeframe'] as String,
              time: DateTime.parse(data['time'] as String),
            ),
          );
        });
      }
    });
  }

  Future<void> _toggleBot() async {
    final service = FlutterBackgroundService();
    if (_isRunning) {
      service.invoke('stop');
      setState(() => _isRunning = false);
    } else {
      await service.startService();
      setState(() => _isRunning = true);
    }
  }

  Future<void> _clearAlertedLevels() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where((k) => k.startsWith('HH_') || k.startsWith('LL_'))
        .toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('All alerted levels cleared'),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF1E1E2E) : Colors.white;
    final accentColor = _isRunning ? Colors.greenAccent : Colors.redAccent;

    // Summarize active bots
    final hitBots = Config.bots
        .where((b) => b.alertOnHit && b.isConfigured)
        .length;
    final newBots = Config.bots
        .where((b) => b.alertOnNew && b.isConfigured)
        .length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ─── Status Card ──────────────────────────────
        _buildCard(
          cardColor: cardColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isRunning
                              ? '🟢 Bot is Running'
                              : '🔴 Bot is Stopped',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: accentColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Last check: $_lastCheck',
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(
                          'Every ${Config.checkEveryMinutes} min · '
                          '${Config.symbols.length} pairs · '
                          '${Config.effectiveTimeframes.join(', ')}',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        // Active bots summary
                        Row(
                          children: [
                            if (hitBots > 0)
                              _BadgeChip(
                                label:
                                    '$hitBots hit bot${hitBots > 1 ? 's' : ''}',
                                color: Colors.orange,
                                isDark: isDark,
                              ),
                            if (hitBots > 0 && newBots > 0)
                              const SizedBox(width: 6),
                            if (newBots > 0)
                              _BadgeChip(
                                label:
                                    '$newBots new-level bot${newBots > 1 ? 's' : ''}',
                                color: Colors.purple,
                                isDark: isDark,
                              ),
                            if (hitBots == 0 && newBots == 0)
                              Text(
                                'No bots configured',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.red.shade400,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _isRunning,
                    onChanged: (_) => _toggleBot(),
                    activeColor: Colors.greenAccent,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _toggleBot,
                  icon: Icon(_isRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(_isRunning ? 'Stop Services' : 'Start Services'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ─── Watched Pairs ────────────────────────────
        _buildCard(
          cardColor: cardColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Watched Pairs', style: theme.textTheme.titleSmall),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: Config.symbols.map((s) {
                  return Chip(
                    label: Text(s, style: const TextStyle(fontSize: 12)),
                    backgroundColor: isDark
                        ? const Color(0xFF2A2A3E)
                        : Colors.blue.shade50,
                    side: BorderSide(
                      color: isDark
                          ? Colors.blueAccent.withOpacity(0.3)
                          : Colors.blue.shade200,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ─── Alert Log ────────────────────────────────
        _buildCard(
          cardColor: cardColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Alert Log', style: theme.textTheme.titleSmall),
                  TextButton.icon(
                    onPressed: _clearAlertedLevels,
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text(
                      'Clear Levels',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_alertLogs.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.notifications_none_rounded,
                          size: 40,
                          color: isDark
                              ? Colors.grey.shade700
                              : Colors.grey.shade400,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No alerts yet.\nStart the bot to begin watching.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...(_alertLogs
                    .take(20)
                    .map((log) => _buildAlertTile(log, isDark))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAlertTile(AlertLog log, bool isDark) {
    final isHH = log.type == 'HH';
    final isNew = log.kind == 'new';

    // Colors: orange tint for "new level", red/green for "hit"
    final Color color;
    final String emoji;
    final String title;
    final String subtitle;

    if (isNew) {
      color = isHH ? Colors.orange.shade400 : Colors.purple.shade300;
      emoji = isHH ? '📈' : '📉';
      title =
          '$emoji ${log.symbol} · New ${isHH ? "HH" : "LL"} · ${log.timeframe}';
      subtitle = isHH ? 'New Higher High Formed' : 'New Lower Low Formed';
    } else {
      color = isHH ? Colors.redAccent : Colors.greenAccent;
      emoji = isHH ? '🔴' : '🟢';
      title = '$emoji ${log.symbol} · ${log.type} Hit · ${log.timeframe}';
      subtitle = isHH ? 'Resistance Hit' : 'Support Hit';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A3E) : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              Text(subtitle, style: TextStyle(color: color, fontSize: 12)),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                log.price.toStringAsFixed(2),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                '${log.time.hour.toString().padLeft(2, '0')}:'
                '${log.time.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child, required Color cardColor}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ─── Small badge chip ─────────────────────────────────────
class _BadgeChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool isDark;
  const _BadgeChip({
    required this.label,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
