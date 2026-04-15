// ─── screens/price_alerts_screen.dart ───────────────────
// Manual price alert management.
// Each alert watches one symbol and fires when the current
// price crosses above or below a manually set target.
// Each alert can use any configured Telegram bot.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config.dart';
import '../services/api_service.dart';
import '../services/telegram_service.dart';

// ══════════════════════════════════════════════════════════
// ─── MAIN SCREEN ─────────────────────────────────────────
// ══════════════════════════════════════════════════════════
class PriceAlertsScreen extends StatefulWidget {
  const PriceAlertsScreen({super.key});

  @override
  State<PriceAlertsScreen> createState() => _PriceAlertsScreenState();
}

class _PriceAlertsScreenState extends State<PriceAlertsScreen> {
  List<PriceAlert> _alerts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() => _alerts = List.from(Config.priceAlerts));
  }

  Future<void> _save() async {
    await ConfigService.savePriceAlerts(_alerts);
  }

  Future<void> _openEdit(PriceAlert? existing) async {
    final result = await showModalBottomSheet<PriceAlert>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AlertEditSheet(existing: existing),
    );
    if (result != null && mounted) {
      setState(() {
        final idx = _alerts.indexWhere((a) => a.id == result.id);
        if (idx >= 0)
          _alerts[idx] = result;
        else
          _alerts.insert(0, result);
      });
      await _save();
    }
  }

  Future<void> _toggleActive(PriceAlert alert) async {
    setState(() {
      final idx = _alerts.indexWhere((a) => a.id == alert.id);
      if (idx >= 0) {
        _alerts[idx] = alert.copyWith(
          isActive: !alert.isActive,
          isTriggered: false, // re-arm when re-activated
        );
      }
    });
    await _save();
  }

  Future<void> _resetTriggered(PriceAlert alert) async {
    setState(() {
      final idx = _alerts.indexWhere((a) => a.id == alert.id);
      if (idx >= 0) {
        _alerts[idx] = alert.copyWith(isTriggered: false, isActive: true);
      }
    });
    await _save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Alert reset — will fire again on next price match',
          ),
          backgroundColor: Colors.blue.shade700,
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

  Future<void> _delete(PriceAlert alert) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Alert'),
        content: Text(
          'Delete "${alert.label.isNotEmpty ? alert.label : "${alert.symbol} alert"}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      setState(() => _alerts.removeWhere((a) => a.id == alert.id));
      await _save();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF12121E)
          : const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Price Alerts'),
        centerTitle: false,
        backgroundColor: isDark ? const Color(0xFF1E1E2E) : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black,
        elevation: 0,
        actions: [
          if (_alerts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () => _openEdit(null),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add'),
                style: TextButton.styleFrom(foregroundColor: Colors.blueAccent),
              ),
            ),
        ],
      ),
      body: _alerts.isEmpty ? _buildEmpty() : _buildList(isDark),
      floatingActionButton: _alerts.isEmpty
          ? null
          : FloatingActionButton(
              onPressed: () => _openEdit(null),
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
              child: const Icon(Icons.add_rounded),
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
            'No price alerts yet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap the button below to add your first alert.',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: () => _openEdit(null),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add Price Alert'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(bool isDark) {
    // Group: active alerts first, then triggered, then paused
    final active = _alerts.where((a) => a.isActive && !a.isTriggered).toList();
    final triggered = _alerts.where((a) => a.isTriggered).toList();
    final paused = _alerts.where((a) => !a.isActive && !a.isTriggered).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        if (active.isNotEmpty) ...[
          _SectionLabel('Active (${active.length})'),
          ...active.map(
            (a) => _AlertCard(
              alert: a,
              isDark: isDark,
              onEdit: () => _openEdit(a),
              onToggle: () => _toggleActive(a),
              onDelete: () => _delete(a),
              onReset: () => _resetTriggered(a),
            ),
          ),
        ],
        if (triggered.isNotEmpty) ...[
          const SizedBox(height: 8),
          _SectionLabel('Triggered (${triggered.length})'),
          ...triggered.map(
            (a) => _AlertCard(
              alert: a,
              isDark: isDark,
              onEdit: () => _openEdit(a),
              onToggle: () => _toggleActive(a),
              onDelete: () => _delete(a),
              onReset: () => _resetTriggered(a),
            ),
          ),
        ],
        if (paused.isNotEmpty) ...[
          const SizedBox(height: 8),
          _SectionLabel('Paused (${paused.length})'),
          ...paused.map(
            (a) => _AlertCard(
              alert: a,
              isDark: isDark,
              onEdit: () => _openEdit(a),
              onToggle: () => _toggleActive(a),
              onDelete: () => _delete(a),
              onReset: () => _resetTriggered(a),
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Section label ────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Colors.grey.shade500,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ─── Alert card ───────────────────────────────────────────
class _AlertCard extends StatelessWidget {
  final PriceAlert alert;
  final bool isDark;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onReset;

  const _AlertCard({
    required this.alert,
    required this.isDark,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
    required this.onReset,
  });

  Color get _borderColor {
    if (alert.isTriggered) return Colors.grey.shade400;
    if (!alert.isActive) return Colors.grey.shade500;
    if (alert.condition == 'touch') return Colors.teal.shade400;
    return alert.condition == 'above'
        ? Colors.orange.shade400
        : Colors.green.shade400;
  }

  @override
  Widget build(BuildContext context) {
    final isAbove = alert.condition == 'above';
    final isTouch = alert.condition == 'touch';
    final dirEmoji = isTouch ? '⬡' : (isAbove ? '▲' : '▼');
    final dirColor = isTouch
        ? Colors.teal.shade400
        : (isAbove ? Colors.orange.shade400 : Colors.green.shade400);
    final cardBg = isDark ? const Color(0xFF1E1E2E) : Colors.white;

    // Find bot name
    String botName = 'Unknown Bot';
    try {
      botName = Config.bots.firstWhere((b) => b.id == alert.botId).name;
    } catch (_) {
      botName = 'Bot deleted';
    }

    // Status
    String statusText;
    Color statusColor;
    if (alert.isTriggered) {
      statusText = 'Triggered';
      statusColor = Colors.grey.shade400;
    } else if (!alert.isActive) {
      statusText = 'Paused';
      statusColor = Colors.grey.shade500;
    } else {
      statusText = 'Watching';
      statusColor = Colors.blueAccent;
    }

    return GestureDetector(
      onTap: onEdit,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border(left: BorderSide(color: _borderColor, width: 4)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              // ── Main info ─────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Label / Symbol
                    Text(
                      alert.label.isNotEmpty ? alert.label : alert.symbol,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: alert.isTriggered || !alert.isActive
                            ? Colors.grey.shade500
                            : null,
                      ),
                    ),
                    if (alert.label.isNotEmpty)
                      Text(
                        alert.symbol,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.grey.shade500,
                        ),
                      ),

                    const SizedBox(height: 6),

                    // Target + direction
                    Row(
                      children: [
                        Text(
                          dirEmoji,
                          style: TextStyle(
                            fontSize: 13,
                            color: alert.isTriggered ? Colors.grey : dirColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isTouch
                              ? 'When price touches ${_fmt(alert.targetPrice)}'
                              : 'When price goes ${isAbove ? "above" : "below"} '
                                    '${_fmt(alert.targetPrice)}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: alert.isTriggered
                                ? Colors.grey.shade400
                                : null,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 4),

                    // Bot name + status
                    Row(
                      children: [
                        Icon(
                          Icons.smart_toy_rounded,
                          size: 12,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          botName,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 10,
                              color: statusColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // ── Action buttons ────────────────────────
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Reset (if triggered) or toggle active
                  if (alert.isTriggered)
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                      color: Colors.blueAccent,
                      tooltip: 'Reset alert',
                      onPressed: onReset,
                    )
                  else
                    Switch(
                      value: alert.isActive,
                      onChanged: (_) => onToggle(),
                      activeColor: Colors.blueAccent,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),

                  // Delete
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    color: Colors.redAccent.withOpacity(0.7),
                    tooltip: 'Delete',
                    onPressed: onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(double v) {
    if (v >= 1000) return v.toStringAsFixed(2);
    if (v >= 1) return v.toStringAsFixed(4);
    return v.toStringAsFixed(6);
  }
}

// ══════════════════════════════════════════════════════════
// ─── ADD / EDIT SHEET ────────────────────────────────────
// ══════════════════════════════════════════════════════════
class _AlertEditSheet extends StatefulWidget {
  final PriceAlert? existing;
  const _AlertEditSheet({this.existing});

  @override
  State<_AlertEditSheet> createState() => _AlertEditSheetState();
}

class _AlertEditSheetState extends State<_AlertEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _labelCtrl;
  late final TextEditingController _symbolCtrl;
  late final TextEditingController _priceCtrl;
  late String _condition; // 'above' | 'below'
  late String _selectedBotId;
  bool _validating = false;
  bool _symbolValid = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _labelCtrl = TextEditingController(text: e?.label ?? '');
    _symbolCtrl = TextEditingController(text: e?.symbol ?? '');
    _priceCtrl = TextEditingController(
      text: e != null ? _fmtRaw(e.targetPrice) : '',
    );
    _condition = e?.condition ?? 'above';
    _selectedBotId = e?.botId ?? _defaultBotId();
    _symbolValid = e != null; // existing symbol already validated
  }

  String _defaultBotId() {
    if (Config.bots.isEmpty) return '';
    // Prefer bots that have manual alerts enabled
    try {
      return Config.bots
          .firstWhere((b) => b.isConfigured && b.canReceiveManualAlerts)
          .id;
    } catch (_) {}
    // Fall back to any configured bot
    try {
      return Config.bots.firstWhere((b) => b.isConfigured).id;
    } catch (_) {
      return Config.bots.first.id;
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _symbolCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  Future<void> _validateSymbol(String value) async {
    final sym = value.trim().toUpperCase();
    if (sym.isEmpty) {
      setState(() => _symbolValid = false);
      return;
    }
    setState(() => _validating = true);
    final result = await ApiService.validateSymbol(sym);
    if (mounted)
      setState(() {
        _validating = false;
        _symbolValid = result.isValid;
      });
  }

  PriceAlert _build() {
    final e = widget.existing;
    return PriceAlert(
      id: e?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      symbol: _symbolCtrl.text.trim().toUpperCase(),
      targetPrice: double.parse(_priceCtrl.text.trim()),
      condition: _condition,
      botId: _selectedBotId,
      label: _labelCtrl.text.trim(),
      isActive: e?.isActive ?? true,
      isTriggered: e?.isTriggered ?? false,
      createdAt: e?.createdAt,
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (!_symbolValid) {
      _snack('Validate the symbol first', isError: true);
      return;
    }
    final eligibleBots = Config.bots
        .where((b) => b.canReceiveManualAlerts)
        .toList();
    if (eligibleBots.isEmpty) {
      _snack(
        'No bots have "Manual Price Alerts" enabled.\n'
        'Edit a bot and enable it first.',
        isError: true,
      );
      return;
    }
    // If selected bot is no longer eligible, auto-pick first eligible
    if (!eligibleBots.any((b) => b.id == _selectedBotId)) {
      _selectedBotId = eligibleBots.first.id;
    }
    Navigator.pop(context, _build());
  }

  void _snack(String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetColor = isDark ? const Color(0xFF1E1E2E) : Colors.white;
    final isEdit = widget.existing != null;
    final bots = Config.bots;
    // Ensure selectedBotId is valid
    if (bots.isNotEmpty && !bots.any((b) => b.id == _selectedBotId)) {
      _selectedBotId = bots.first.id;
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
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
            // Drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  const Icon(
                    Icons.notifications_rounded,
                    color: Colors.blueAccent,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isEdit ? 'Edit Price Alert' : 'New Price Alert',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
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
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Label (optional) ──────────────
                      const _Label('Label (optional)'),
                      _Field(
                        controller: _labelCtrl,
                        hint: 'e.g. BTC resistance',
                        isDark: isDark,
                      ),
                      const SizedBox(height: 16),

                      // ── Symbol ─────────────────────────
                      const _Label('Symbol'),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _Field(
                              controller: _symbolCtrl,
                              hint: 'e.g. BTCUSDT',
                              isDark: isDark,
                              capitalization: TextCapitalization.characters,
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) {
                                  return 'Symbol is required';
                                }
                                return null;
                              },
                              suffix: _symbolValid
                                  ? const Icon(
                                      Icons.check_circle_rounded,
                                      color: Colors.green,
                                      size: 20,
                                    )
                                  : null,
                              onChanged: (v) {
                                // Reset validation when user types
                                if (_symbolValid) {
                                  setState(() => _symbolValid = false);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            height: 50,
                            child: ElevatedButton(
                              onPressed: _validating
                                  ? null
                                  : () => _validateSymbol(_symbolCtrl.text),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blueAccent,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                              ),
                              child: _validating
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      'Check',
                                      style: TextStyle(fontSize: 13),
                                    ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // ── Target price ───────────────────
                      const _Label('Target Price'),
                      _Field(
                        controller: _priceCtrl,
                        hint: 'e.g. 95000.00',
                        isDark: isDark,
                        inputType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Target price is required';
                          }
                          if (double.tryParse(v.trim()) == null) {
                            return 'Enter a valid number';
                          }
                          if (double.parse(v.trim()) <= 0) {
                            return 'Price must be greater than 0';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),

                      // ── Condition ──────────────────────
                      const _Label('Alert Condition'),
                      const SizedBox(height: 8),
                      Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _ConditionButton(
                                  label: '▲  Cross Above',
                                  subtitle: 'Price ≥ target',
                                  selected: _condition == 'above',
                                  color: Colors.orange,
                                  isDark: isDark,
                                  onTap: () =>
                                      setState(() => _condition = 'above'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _ConditionButton(
                                  label: '▼  Cross Below',
                                  subtitle: 'Price ≤ target',
                                  selected: _condition == 'below',
                                  color: Colors.green,
                                  isDark: isDark,
                                  onTap: () =>
                                      setState(() => _condition = 'below'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _ConditionButton(
                            label: '⬡  Touch',
                            subtitle:
                                'Price comes within 0.2% of target (either side)',
                            selected: _condition == 'touch',
                            color: Colors.teal,
                            isDark: isDark,
                            onTap: () => setState(() => _condition = 'touch'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // ── Bot selector ───────────────────
                      const _Label('Send Alert Via'),
                      const SizedBox(height: 8),
                      if (bots.isEmpty)
                        _NoBotWarning(reason: 'no-bots')
                      else if (bots
                          .where((b) => b.canReceiveManualAlerts)
                          .isEmpty)
                        _NoBotWarning(reason: 'none-enabled')
                      else
                        ...bots
                            .where((b) => b.canReceiveManualAlerts)
                            .map(
                              (bot) => _BotOption(
                                bot: bot,
                                selected: bot.id == _selectedBotId,
                                isDark: isDark,
                                onTap: () =>
                                    setState(() => _selectedBotId = bot.id),
                              ),
                            ),

                      const SizedBox(height: 28),

                      // ── Save button ────────────────────
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: bots.isEmpty ? null : _save,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            isEdit ? 'Save Changes' : 'Create Alert',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtRaw(double v) => v.toStringAsFixed(
    v >= 1000
        ? 2
        : v >= 1
        ? 4
        : 6,
  );
}

// ─── No-bot warning banner ────────────────────────────────
class _NoBotWarning extends StatelessWidget {
  final String reason; // 'no-bots' | 'none-enabled'
  const _NoBotWarning({required this.reason});

  @override
  Widget build(BuildContext context) {
    final msg = reason == 'no-bots'
        ? 'No Telegram bots configured yet.\nAdd a bot from the main screen first.'
        : 'No bots have "Manual Price Alerts" enabled.\n'
              'Open a bot (🤖 icon top-right) → enable 🔔 Manual Price Alerts.';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange.shade600,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(fontSize: 12.5, color: Colors.orange),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Condition toggle button ──────────────────────────────
class _ConditionButton extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final Color color;
  final bool isDark;
  final VoidCallback onTap;
  const _ConditionButton({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.color,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? color.withOpacity(0.12)
              : (isDark ? const Color(0xFF1A1A2E) : Colors.grey.shade50),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? color.withOpacity(0.6)
                : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: selected ? color : null,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Bot selection tile ───────────────────────────────────
class _BotOption extends StatelessWidget {
  final TelegramBot bot;
  final bool selected;
  final bool isDark;
  final VoidCallback onTap;
  const _BotOption({
    required this.bot,
    required this.selected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? Colors.blueAccent.withOpacity(0.08)
              : (isDark ? const Color(0xFF1A1A2E) : Colors.grey.shade50),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? Colors.blueAccent.withOpacity(0.5)
                : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // Radio dot
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? Colors.blueAccent : Colors.grey.shade400,
                  width: 2,
                ),
              ),
              alignment: Alignment.center,
              child: selected
                  ? Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.blueAccent,
                        shape: BoxShape.circle,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            // Bot info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bot.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                  if (!bot.isConfigured)
                    Text(
                      'Not configured',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.orange.shade400,
                      ),
                    )
                  else
                    Text(
                      'Chat: ${bot.chatId}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                      ),
                    ),
                ],
              ),
            ),
            if (!bot.isConfigured)
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Colors.orange.shade400,
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Shared form widgets ──────────────────────────────────
class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.blueAccent,
      ),
    ),
  );
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool isDark;
  final Widget? suffix;
  final TextInputType? inputType;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization capitalization;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;

  const _Field({
    required this.controller,
    required this.hint,
    required this.isDark,
    this.suffix,
    this.inputType,
    this.inputFormatters,
    this.capitalization = TextCapitalization.none,
    this.validator,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: inputType,
      inputFormatters: inputFormatters,
      textCapitalization: capitalization,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
        suffixIcon: suffix,
        filled: true,
        fillColor: isDark ? const Color(0xFF12121E) : Colors.grey.shade50,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.blueAccent, width: 1.8),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.redAccent, width: 1.8),
        ),
      ),
      validator: validator,
    );
  }
}
