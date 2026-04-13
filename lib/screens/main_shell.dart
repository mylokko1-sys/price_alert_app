// ─── screens/main_shell.dart ─────────────────────────────
// Root widget:
//   • 5-tab BottomNavigationBar → Home | Pairs | Indicator | Bot | Chart
//   • Left hamburger drawer → Price Alerts · Candle Pattern Alerts
//                             · Chart Line Alerts (from chart drawings)
//   • Right AppBar icon → Telegram Bots sheet

import 'package:flutter/material.dart';
import '../config.dart';
import '../models/chart_models.dart';
import '../services/chart_drawings_storage.dart';
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
    _TabItem(label: 'Home', icon: Icons.home_rounded),
    _TabItem(label: 'Pairs', icon: Icons.currency_bitcoin),
    _TabItem(label: 'Indicator', icon: Icons.tune_rounded),
    _TabItem(label: 'Bot', icon: Icons.settings_rounded),
    _TabItem(label: 'Chart', icon: Icons.candlestick_chart_rounded),
  ];

  static const _titles = [
    'HH/LL Alert Bot',
    'Trading Pairs',
    'Indicator Settings',
    'Bot Settings',
    '', // Chart screen owns its own AppBar
  ];

  // ── Saved snack ───────────────────────────────────────
  void _onSaved() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('Settings saved successfully'),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

  void _openChartLineAlerts() {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChartLineAlertsScreen()),
    ).then((_) => setState(() {}));
  }

  // ══════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isChartTab = _index == 4;

    final pages = [
      const HomeBody(),
      TradingPairsSettingsPage(onSaved: _onSaved),
      IndicatorSettingsPage(onSaved: _onSaved),
      BotSettingsPage(onSaved: _onSaved),
      const ChartScreen(),
    ];

    return Scaffold(
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
      drawer: isChartTab
          ? null
          : _AppDrawer(
              onPriceAlerts: _openPriceAlerts,
              onCandlePatternAlerts: _openCandlePatternAlerts,
              onChartLineAlerts: _openChartLineAlerts,
            ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.blueAccent,
        unselectedItemColor: isDark
            ? Colors.grey.shade600
            : Colors.grey.shade500,
        backgroundColor: isChartTab
            ? const Color(0xFF0D0D1A)
            : (isDark ? const Color(0xFF1E1E2E) : Colors.white),
        selectedFontSize: 10,
        unselectedFontSize: 10,
        elevation: 12,
        items: _tabs
            .map(
              (t) =>
                  BottomNavigationBarItem(icon: Icon(t.icon), label: t.label),
            )
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
class _AppDrawer extends StatefulWidget {
  final VoidCallback onPriceAlerts;
  final VoidCallback onCandlePatternAlerts;
  final VoidCallback onChartLineAlerts;

  const _AppDrawer({
    required this.onPriceAlerts,
    required this.onCandlePatternAlerts,
    required this.onChartLineAlerts,
  });

  @override
  State<_AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<_AppDrawer> {
  // Chart line alert counts loaded from storage
  int _chartLineAlertCount = 0;
  bool _loadingChartAlerts = false;
  Map<String, DrawingsBundle> _allChartDrawings = {};
  bool _loadingAllDrawings = false;

  @override
  void initState() {
    super.initState();
    _loadChartLineAlertCount();
    _loadAllChartDrawings();
  }

  Future<void> _loadChartLineAlertCount() async {
    setState(() => _loadingChartAlerts = true);
    try {
      final all = await ChartDrawingsStorage.loadAllWithAlerts();
      int count = 0;
      for (final bundle in all.values) {
        count += bundle.trendLines.where((t) => t.hasAlert).length;
        count += bundle.horizLines.where((h) => h.hasAlert).length;
      }
      if (mounted)
        setState(() {
          _chartLineAlertCount = count;
          _loadingChartAlerts = false;
        });
    } catch (_) {
      if (mounted) setState(() => _loadingChartAlerts = false);
    }
  }

  Future<void> _loadAllChartDrawings() async {
    setState(() => _loadingAllDrawings = true);
    try {
      final all = await ChartDrawingsStorage.loadAll();
      if (mounted)
        setState(() {
          _allChartDrawings = all;
          _loadingAllDrawings = false;
        });
    } catch (_) {
      if (mounted) setState(() => _loadingAllDrawings = false);
    }
  }

  // ── Helper: Get total line count across all pairs ────────────────
  int _getAllDrawingsCount() {
    int total = 0;
    for (final bundle in _allChartDrawings.values) {
      total += bundle.trendLines.length + bundle.horizLines.length;
    }
    return total;
  }

  // ── Helper: Show all drawings summary ────────────────────────────
  void _showAllDrawingsSummary(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  const Icon(
                    Icons.collections_rounded,
                    color: Colors.teal,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'All Chart Drawings',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _allChartDrawings.isEmpty
                  ? Center(
                      child: Text(
                        'No drawings yet',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                      itemCount: _allChartDrawings.length,
                      itemBuilder: (_, idx) {
                        final symbol = _allChartDrawings.keys.toList()[idx];
                        final bundle = _allChartDrawings[symbol]!;
                        final trendCount = bundle.trendLines.length;
                        final hlineCount = bundle.horizLines.length;
                        final total = trendCount + hlineCount;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF2A2A3E)
                                : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isDark
                                  ? Colors.grey.shade800
                                  : Colors.grey.shade200,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    symbol,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.blueAccent,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.teal.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Colors.teal.withOpacity(0.3),
                                      ),
                                    ),
                                    child: Text(
                                      '$total line${total != 1 ? 's' : ''}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.teal,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Icon(
                                    Icons.show_chart_rounded,
                                    size: 14,
                                    color: Colors.grey.shade500,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Trend: $trendCount',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Icon(
                                    Icons.horizontal_rule_rounded,
                                    size: 14,
                                    color: Colors.grey.shade500,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'H-Line: $hlineCount',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final headerBg = isDark ? const Color(0xFF1E1E2E) : Colors.blueAccent;
    final drawerBg = isDark ? const Color(0xFF15152A) : Colors.white;
    final divColor = isDark ? Colors.grey.shade800 : Colors.grey.shade200;
    final activeAlerts = Config.priceAlerts.where((a) => a.shouldFire).length;
    final triggered = Config.priceAlerts.where((a) => a.isTriggered).length;
    final activeCp = Config.candlePatternAlerts.where((a) => a.isActive).length;

    return Drawer(
      backgroundColor: drawerBg,
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 56, 20, 24),
            color: headerBg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Text('📈', style: TextStyle(fontSize: 24)),
                ),
                const SizedBox(height: 12),
                const Text(
                  'General Lists',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Crypto trading alerts',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),

          // ── Nav items ───────────────────────────────────
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // ── Price Alerts ──────────────────────────
                _DrawerItem(
                  icon: Icons.notifications_rounded,
                  label: 'Price Alerts',
                  badge: activeAlerts > 0 ? '$activeAlerts active' : null,
                  badgeColor: Colors.blueAccent,
                  sub: triggered > 0
                      ? '$triggered triggered'
                      : 'Set custom price targets',
                  subColor: triggered > 0 ? Colors.orange : null,
                  onTap: widget.onPriceAlerts,
                ),

                Divider(height: 1, indent: 16, endIndent: 16, color: divColor),

                // ── Candle Pattern Alerts ─────────────────
                _DrawerItem(
                  icon: Icons.bar_chart_rounded,
                  label: 'Candle Patterns',
                  badge: activeCp > 0 ? '$activeCp active' : null,
                  badgeColor: Colors.teal,
                  sub: 'BE · MS · ES detection',
                  subColor: null,
                  onTap: widget.onCandlePatternAlerts,
                ),

                Divider(height: 1, indent: 16, endIndent: 16, color: divColor),

                // ── Chart Line Alerts ─────────────────────
                _DrawerItem(
                  icon: Icons.show_chart_rounded,
                  label: 'Chart Line Alerts',
                  badge: _loadingChartAlerts
                      ? null
                      : _chartLineAlertCount > 0
                      ? '$_chartLineAlertCount active'
                      : null,
                  badgeColor: Colors.orange,
                  badgeLoading: _loadingChartAlerts,
                  sub: _chartLineAlertCount > 0
                      ? '$_chartLineAlertCount trend/H-line alerts set'
                      : 'Trend & horizontal line alerts',
                  subColor: _chartLineAlertCount > 0 ? Colors.orange : null,
                  onTap: widget.onChartLineAlerts,
                ),

                Divider(height: 1, indent: 16, endIndent: 16, color: divColor),

                // ── All Chart Drawings ────────────────────
                _DrawerItem(
                  icon: Icons.collections_rounded,
                  label: 'All Chart Drawings',
                  badge: _loadingAllDrawings
                      ? null
                      : _allChartDrawings.isNotEmpty
                      ? '${_allChartDrawings.length} pairs'
                      : null,
                  badgeColor: Colors.teal,
                  badgeLoading: _loadingAllDrawings,
                  sub: _getAllDrawingsCount() > 0
                      ? '${_getAllDrawingsCount()} total lines'
                      : 'View all drawings',
                  subColor: null,
                  onTap: () {
                    // Show all drawings summary
                    _showAllDrawingsSummary(context);
                  },
                ),

                Divider(height: 1, indent: 16, endIndent: 16, color: divColor),
              ],
            ),
          ),

          // ── Footer ──────────────────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'HH/LL Alert Bot  •  v1.0',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Single drawer item ───────────────────────────────────
class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? badge;
  final Color? badgeColor;
  final bool badgeLoading;
  final String? sub;
  final Color? subColor;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
    this.badgeColor,
    this.badgeLoading = false,
    this.sub,
    this.subColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.blueAccent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.blueAccent, size: 20),
      ),
      title: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
          ),
          const SizedBox(width: 8),
          if (badgeLoading)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Colors.grey.shade500,
              ),
            )
          else if (badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: (badgeColor ?? Colors.blueAccent).withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                badge!,
                style: TextStyle(
                  fontSize: 10,
                  color: badgeColor ?? Colors.blueAccent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      subtitle: sub != null
          ? Text(
              sub!,
              style: TextStyle(
                fontSize: 11.5,
                color: subColor ?? Colors.grey.shade500,
              ),
            )
          : null,
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
        size: 20,
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// CHART LINE ALERTS SCREEN
// Full-screen list of all active line alerts across all symbols.
// ══════════════════════════════════════════════════════════
class ChartLineAlertsScreen extends StatefulWidget {
  const ChartLineAlertsScreen({super.key});

  @override
  State<ChartLineAlertsScreen> createState() => _ChartLineAlertsScreenState();
}

class _ChartLineAlertsScreenState extends State<ChartLineAlertsScreen> {
  bool _loading = true;
  Map<String, DrawingsBundle> _data = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await ChartDrawingsStorage.loadAllWithAlerts();
    if (mounted)
      setState(() {
        _data = data;
        _loading = false;
      });
  }

  // ── Deactivate a specific line alert from storage ──────
  Future<void> _removeAlert(String symbol, String id, String type) async {
    // Load the full bundle for this symbol
    final bundle = await ChartDrawingsStorage.load(symbol);
    List<TrendLineData> tls = bundle.trendLines;
    List<HorizLineData> hls = bundle.horizLines;

    if (type == 't') {
      tls = tls
          .map((t) => t.id == id ? t.copyWith(hasAlert: false, botId: '') : t)
          .toList();
    } else {
      hls = hls
          .map((h) => h.id == id ? h.copyWith(hasAlert: false, botId: '') : h)
          .toList();
    }

    await ChartDrawingsStorage.save(
      symbol: symbol,
      trendLines: tls,
      horizLines: hls,
    );
    await _load(); // refresh list

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 16),
              SizedBox(width: 8),
              Text('Alert removed'),
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
      return 'Unknown Bot';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Flatten: collect all active alerts across all symbols, sorted
    final entries = <_AlertEntry>[];
    for (final sym in _data.keys.toList()..sort()) {
      final bundle = _data[sym]!;
      for (final tl in bundle.trendLines.where((t) => t.hasAlert)) {
        entries.add(
          _AlertEntry(
            symbol: sym,
            id: tl.id,
            type: 't',
            label: 'Trend Line',
            price: tl.price2, // use endpoint price
            botId: tl.botId,
            color: tl.color,
          ),
        );
      }
      for (final hl in bundle.horizLines.where((h) => h.hasAlert)) {
        entries.add(
          _AlertEntry(
            symbol: sym,
            id: hl.id,
            type: 'h',
            label: 'Horizontal Line',
            price: hl.price,
            botId: hl.botId,
            color: hl.color,
          ),
        );
      }
    }

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF12121E)
          : const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Chart Line Alerts'),
        centerTitle: false,
        backgroundColor: isDark ? const Color(0xFF1E1E2E) : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black,
        elevation: 0,
        actions: [
          if (entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.orange.withOpacity(0.5)),
                  ),
                  child: Text(
                    '${entries.length} active',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : entries.isEmpty
          ? _buildEmpty()
          : RefreshIndicator(
              onRefresh: _load,
              color: Colors.orange,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                itemCount: entries.length,
                itemBuilder: (_, i) => _buildCard(entries[i], isDark),
              ),
            ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.notifications_none_rounded,
            size: 64,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 16),
          const Text(
            'No chart line alerts active',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Open the Chart tab, draw a Trend Line\nor H-Line, then tap it to set an alert.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(_AlertEntry entry, bool isDark) {
    final isH = entry.type == 'h';
    final cardBg = isDark ? const Color(0xFF1E1E2E) : Colors.white;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: Colors.orange, width: 4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            // ── Line type icon ─────────────────────────────
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isH ? Icons.horizontal_rule_rounded : Icons.show_chart_rounded,
                color: Colors.orange,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),

            // ── Info ──────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Symbol badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blueAccent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          entry.symbol,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        entry.label,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(
                        Icons.price_change_rounded,
                        size: 13,
                        color: Colors.grey.shade500,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Price: ${_fmtP(entry.price)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        Icons.smart_toy_rounded,
                        size: 12,
                        color: Colors.grey.shade500,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        entry.botId.isNotEmpty
                            ? _botName(entry.botId)
                            : 'No bot assigned',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
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
                          '🔔 Watching',
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
              ),
            ),

            // ── Remove button ─────────────────────────────
            GestureDetector(
              onTap: () => _confirmRemove(entry),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: const Text(
                  'Remove',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(_AlertEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Alert'),
        content: Text(
          'Remove the ${entry.label} alert on ${entry.symbol}?\n'
          'The line will remain on the chart.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _removeAlert(entry.symbol, entry.id, entry.type);
    }
  }
}

// ── Data model for the list ───────────────────────────────
class _AlertEntry {
  final String symbol;
  final String id;
  final String type; // 'h' | 't'
  final String label;
  final double price;
  final String botId;
  final Color color;
  const _AlertEntry({
    required this.symbol,
    required this.id,
    required this.type,
    required this.label,
    required this.price,
    required this.botId,
    required this.color,
  });
}

// ══════════════════════════════════════════════════════════
// TELEGRAM BOTS SHEET
// ══════════════════════════════════════════════════════════
class _TelegramBotsSheet extends StatelessWidget {
  final VoidCallback onSaved;
  const _TelegramBotsSheet({required this.onSaved});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetColor = isDark ? const Color(0xFF1E1E2E) : Colors.white;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.97,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: sheetColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  const Icon(
                    Icons.smart_toy_rounded,
                    color: Colors.blueAccent,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Telegram Bots',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
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
