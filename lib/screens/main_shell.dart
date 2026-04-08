// ─── screens/main_shell.dart ─────────────────────────────
// Root widget:
//   • 5-tab BottomNavigationBar → Home | Pairs | Indicator | Bot | Chart
//   • Left hamburger drawer → Price Alerts · Candle Pattern Alerts
//   • Right AppBar icon → Telegram Bots sheet

import 'package:flutter/material.dart';
import '../config.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'price_alerts_screen.dart';
import 'candle_pattern_alerts_screen.dart';
import 'chart_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  // ── Tab definitions ───────────────────────────────────
  static const _tabs = [
    _TabItem(label: 'Home',      icon: Icons.home_rounded),
    _TabItem(label: 'Pairs',     icon: Icons.currency_bitcoin),
    _TabItem(label: 'Indicator', icon: Icons.tune_rounded),
    _TabItem(label: 'Bot',       icon: Icons.settings_rounded),
    _TabItem(label: 'Chart',     icon: Icons.candlestick_chart_rounded),
  ];

  static const _titles = [
    'HH/LL Alert Bot',
    'Trading Pairs',
    'Indicator Settings',
    'Bot Settings',
    '',            // Chart screen owns its own AppBar
  ];

  // ── Saved snack ───────────────────────────────────────
  void _onSaved() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(children: [
          Icon(Icons.check_circle, color: Colors.white, size: 18),
          SizedBox(width: 8),
          Text('Settings saved successfully'),
        ]),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── Telegram Bots sheet ───────────────────────────────
  void _openTelegramBots() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TelegramBotsSheet(onSaved: _onSaved),
    );
  }

  // ── Drawer nav ────────────────────────────────────────
  void _openPriceAlerts() {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PriceAlertsScreen()),
    ).then((_) => setState(() {}));
  }

  void _openCandlePatternAlerts() {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CandlePatternAlertsScreen()),
    ).then((_) => setState(() {}));
  }

  // ══════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final isDark      = Theme.of(context).brightness == Brightness.dark;
    final isChartTab  = _index == 4;

    // Pages — ChartScreen kept alive via AutomaticKeepAliveClientMixin
    final pages = [
      const HomeBody(),
      TradingPairsSettingsPage(onSaved: _onSaved),
      IndicatorSettingsPage(onSaved: _onSaved),
      BotSettingsPage(onSaved: _onSaved),
      const ChartScreen(),   // ← tab 4
    ];

    return Scaffold(
      // Chart tab owns its own AppBar → hide shell AppBar for tab 4
      appBar: isChartTab
          ? null
          : AppBar(
              title: Text(_titles[_index]),
              centerTitle: false,
              actions: [
                IconButton(
                  tooltip: 'Telegram Bots',
                  icon: const Icon(Icons.smart_toy_rounded),
                  onPressed: _openTelegramBots,
                ),
              ],
            ),

      // Drawer only visible when not on chart tab
      drawer: isChartTab
          ? null
          : _AppDrawer(
              onPriceAlerts:         _openPriceAlerts,
              onCandlePatternAlerts: _openCandlePatternAlerts,
            ),

      body: IndexedStack(index: _index, children: pages),

      // ── Bottom nav ─────────────────────────────────────
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor:   Colors.blueAccent,
        unselectedItemColor:
            isDark ? Colors.grey.shade600 : Colors.grey.shade500,
        backgroundColor:
            isChartTab
                ? const Color(0xFF0D0D1A)   // dark bg for chart tab
                : (isDark ? const Color(0xFF1E1E2E) : Colors.white),
        selectedFontSize:   10,
        unselectedFontSize: 10,
        elevation: 12,
        items: _tabs
            .map((t) => BottomNavigationBarItem(
                  icon: Icon(t.icon),
                  label: t.label,
                ))
            .toList(),
      ),
    );
  }
}

class _TabItem {
  final String label;
  final IconData icon;
  const _TabItem({required this.label, required this.icon});
}

// ══════════════════════════════════════════════════════════
// DRAWER
// ══════════════════════════════════════════════════════════
class _AppDrawer extends StatelessWidget {
  final VoidCallback onPriceAlerts;
  final VoidCallback onCandlePatternAlerts;

  const _AppDrawer({
    required this.onPriceAlerts,
    required this.onCandlePatternAlerts,
  });

  @override
  Widget build(BuildContext context) {
    final isDark       = Theme.of(context).brightness == Brightness.dark;
    final headerBg     = isDark ? const Color(0xFF1E1E2E) : Colors.blueAccent;
    final drawerBg     = isDark ? const Color(0xFF15152A) : Colors.white;
    final divColor     = isDark ? Colors.grey.shade800 : Colors.grey.shade200;
    final activeAlerts = Config.priceAlerts.where((a) => a.shouldFire).length;
    final triggered    = Config.priceAlerts.where((a) => a.isTriggered).length;
    final activeCp     = Config.candlePatternAlerts.where((a) => a.isActive).length;

    return Drawer(
      backgroundColor: drawerBg,
      child: Column(
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 56, 20, 24),
            color: headerBg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Text('📈',
                      style: TextStyle(fontSize: 24)),
                ),
                const SizedBox(height: 12),
                const Text('HH/LL Alert Bot',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text('Crypto trading alerts',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 12.5)),
              ],
            ),
          ),

          // Nav items
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [

                // Price Alerts
                _DrawerItem(
                  icon:       Icons.notifications_rounded,
                  label:      'Price Alerts',
                  badge:      activeAlerts > 0 ? '$activeAlerts active' : null,
                  badgeColor: Colors.blueAccent,
                  sub:        triggered > 0
                      ? '$triggered triggered'
                      : 'Set custom price targets',
                  subColor:   triggered > 0 ? Colors.orange : null,
                  onTap:      onPriceAlerts,
                ),

                Divider(height: 1, indent: 16, endIndent: 16,
                    color: divColor),

                // Candle Pattern Alerts
                _DrawerItem(
                  icon:       Icons.bar_chart_rounded,
                  label:      'Candle Patterns',
                  badge:      activeCp > 0 ? '$activeCp active' : null,
                  badgeColor: Colors.teal,
                  sub:        'BE · MS · ES detection',
                  subColor:   null,
                  onTap:      onCandlePatternAlerts,
                ),

                Divider(height: 1, indent: 16, endIndent: 16,
                    color: divColor),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('More features coming soon',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                          letterSpacing: 0.5)),
                ),
              ],
            ),
          ),

          // Footer
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('HH/LL Alert Bot  •  v1.0',
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade500)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Single drawer item ───────────────────────────────────
class _DrawerItem extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final String?      badge;
  final Color?       badgeColor;
  final String?      sub;
  final Color?       subColor;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
    this.badgeColor,
    this.sub,
    this.subColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: Colors.blueAccent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.blueAccent, size: 20),
      ),
      title: Row(children: [
        Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 14.5)),
        if (badge != null) ...[
          const SizedBox(width: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color:
                  (badgeColor ?? Colors.blueAccent).withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(badge!,
                style: TextStyle(
                    fontSize: 10,
                    color: badgeColor ?? Colors.blueAccent,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ]),
      subtitle: sub != null
          ? Text(sub!,
              style: TextStyle(
                  fontSize: 11.5,
                  color: subColor ?? Colors.grey.shade500))
          : null,
      trailing: Icon(Icons.chevron_right_rounded,
          color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
          size: 20),
    );
  }
}

// ══════════════════════════════════════════════════════════
// TELEGRAM BOTS SHEET
// ══════════════════════════════════════════════════════════
class _TelegramBotsSheet extends StatelessWidget {
  final VoidCallback onSaved;
  const _TelegramBotsSheet({required this.onSaved});

  @override
  Widget build(BuildContext context) {
    final isDark     = Theme.of(context).brightness == Brightness.dark;
    final sheetColor = isDark ? const Color(0xFF1E1E2E) : Colors.white;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize:     0.5,
      maxChildSize:     0.97,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: sheetColor,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.grey.shade700
                    : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(children: [
                const Icon(Icons.smart_toy_rounded,
                    color: Colors.blueAccent, size: 22),
                const SizedBox(width: 10),
                const Text('Telegram Bots',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context)),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: controller,
                child: TelegramBotsPage(
                  onSaved: () {
                    onSaved();
                    Navigator.pop(context);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
