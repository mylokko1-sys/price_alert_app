// ─── screens/settings_screen.dart ────────────────────────
// Settings pages. TelegramBotsPage lets each bot choose
// independent timeframes per alert type (Hit / New Level).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config.dart';
import '../services/binance_service.dart';
import '../services/telegram_service.dart';

// ══════════════════════════════════════════════════════════
// ─── PAGE 1: TELEGRAM BOTS ───────────────────────────────
// ══════════════════════════════════════════════════════════
class TelegramBotsPage extends StatefulWidget {
  final VoidCallback onSaved;
  const TelegramBotsPage({super.key, required this.onSaved});

  @override
  State<TelegramBotsPage> createState() => _TelegramBotsPageState();
}

class _TelegramBotsPageState extends State<TelegramBotsPage> {
  late List<TelegramBot> _bots;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _bots = Config.bots.map((b) => b.copyWith()).toList();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ConfigService.saveBots(_bots);
    setState(() => _saving = false);
    widget.onSaved();
  }

  Future<void> _openEdit(TelegramBot bot) async {
    final updated = await showModalBottomSheet<TelegramBot>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BotEditSheet(bot: bot),
    );
    if (updated != null && mounted) {
      setState(() {
        final idx = _bots.indexWhere((b) => b.id == updated.id);
        if (idx >= 0) _bots[idx] = updated;
        else _bots.add(updated);
      });
    }
  }

  void _addBot() => _openEdit(TelegramBot(
    id:            DateTime.now().millisecondsSinceEpoch.toString(),
    name:          'Bot ${_bots.length + 1}',
    token:         '',
    chatId:        '',
    hitTimeframes: ['1h'],
    newTimeframes: [],
  ));

  void _deleteBot(String id) {
    if (_bots.length <= 1) {
      _snack('At least one bot is required', isError: true);
      return;
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Bot'),
        content: const Text('Are you sure you want to delete this bot?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() => _bots.removeWhere((b) => b.id == id));
            },
            child: const Text('Delete',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  void _snack(String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          isError ? Colors.red.shade700 : Colors.green.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoBanner(
            icon: Icons.smart_toy_rounded,
            text: 'Each bot can subscribe to different timeframes per alert type. '
                '"Hit" fires when price touches a level. '
                '"New Level" fires when a fresh HH/LL pivot forms.',
          ),
          const SizedBox(height: 16),

          ..._bots.asMap().entries.map((e) => _BotCard(
                bot:      e.value,
                index:    e.key,
                onEdit:   () => _openEdit(e.value),
                onDelete: () => _deleteBot(e.value.id),
              )),

          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _addBot,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add Another Bot'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.blueAccent,
                side: const BorderSide(color: Colors.blueAccent),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),

          const SizedBox(height: 20),
          _SaveButton(onPressed: _save, loading: _saving),
        ],
      ),
    );
  }
}

// ─── Bot summary card ─────────────────────────────────────
class _BotCard extends StatefulWidget {
  final TelegramBot bot;
  final int         index;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _BotCard({required this.bot, required this.index,
      required this.onEdit, required this.onDelete});

  @override
  State<_BotCard> createState() => _BotCardState();
}

class _BotCardState extends State<_BotCard> {
  bool _testing = false;

  Future<void> _test() async {
    setState(() => _testing = true);
    final error = await TelegramService.testConnection(widget.bot);
    setState(() => _testing = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(error == null ? Icons.check_circle : Icons.error_outline,
            color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(error == null
              ? '✅ Test sent to ${widget.bot.name}!'
              : '❌ ${widget.bot.name}: $error'),
        ),
      ]),
      backgroundColor:
          error == null ? Colors.green.shade700 : Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12),
      duration: Duration(seconds: error == null ? 3 : 5),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bot    = widget.bot;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: bot.isConfigured
              ? Colors.blueAccent.withOpacity(0.3)
              : Colors.orange.withOpacity(0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────
          Row(
            children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text('${widget.index + 1}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blueAccent,
                        fontSize: 14)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bot.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    Text(
                      bot.isConfigured ? 'Configured ✓' : '⚠ Not yet configured',
                      style: TextStyle(
                          fontSize: 11,
                          color: bot.isConfigured
                              ? Colors.green
                              : Colors.orange),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_rounded, size: 20),
                color: Colors.blueAccent,
                tooltip: 'Edit',
                onPressed: widget.onEdit,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                color: Colors.redAccent,
                tooltip: 'Delete',
                onPressed: widget.onDelete,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Hit alert timeframes ─────────────────────────
          _TfSummaryRow(
            emoji: '🎯',
            label: 'Hit alerts',
            timeframes: bot.hitTimeframes,
            color: Colors.orange,
          ),

          const SizedBox(height: 6),

          // ── New level timeframes ─────────────────────────
          _TfSummaryRow(
            emoji: '✨',
            label: 'New level',
            timeframes: bot.newTimeframes,
            color: Colors.purple,
          ),

          const SizedBox(height: 6),

          // ── Manual price alerts toggle ───────────────────
          _ManualAlertSummaryRow(enabled: bot.canReceiveManualAlerts),

          if (bot.token.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Token: ${_mask(bot.token)}',
              style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? Colors.grey.shade400
                      : Colors.grey.shade600),
            ),
          ],

          const SizedBox(height: 10),

          SizedBox(
            width: double.infinity,
            height: 38,
            child: OutlinedButton.icon(
              onPressed: (bot.isConfigured && !_testing) ? _test : null,
              icon: _testing
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(Colors.blueAccent)),
                    )
                  : const Icon(Icons.send_rounded, size: 14),
              label: Text(_testing ? 'Sending...' : 'Test Connection',
                  style: const TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.blueAccent,
                side: const BorderSide(color: Colors.blueAccent),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _mask(String s) =>
      s.length <= 8 ? '****' : '${s.substring(0, 4)}...${s.substring(s.length - 4)}';
}

// ─── Manual alert summary row ─────────────────────────────
class _ManualAlertSummaryRow extends StatelessWidget {
  final bool enabled;
  const _ManualAlertSummaryRow({required this.enabled});

  @override
  Widget build(BuildContext context) {
    const color = Colors.teal;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: enabled ? color.withOpacity(0.12) : Colors.grey.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: enabled ? color.withOpacity(0.4) : Colors.grey.withOpacity(0.25),
            ),
          ),
          child: Text(
            '🔔 Manual alerts',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: enabled ? color : Colors.grey),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          enabled ? 'Enabled' : 'Off',
          style: TextStyle(
              fontSize: 11,
              color: enabled ? color : Colors.grey.shade500),
        ),
      ],
    );
  }
}

// ─── Timeframe summary row ────────────────────────────────
class _TfSummaryRow extends StatelessWidget {
  final String       emoji;
  final String       label;
  final List<String> timeframes;
  final Color        color;
  const _TfSummaryRow({required this.emoji, required this.label,
      required this.timeframes, required this.color});

  @override
  Widget build(BuildContext context) {
    final enabled = timeframes.isNotEmpty;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: enabled ? color.withOpacity(0.12) : Colors.grey.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: enabled ? color.withOpacity(0.4) : Colors.grey.withOpacity(0.25),
            ),
          ),
          child: Text(
            '$emoji $label',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: enabled ? color : Colors.grey),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: enabled
              ? Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: timeframes.map((tf) => Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(tf,
                        style: TextStyle(
                            fontSize: 10,
                            color: color,
                            fontWeight: FontWeight.w600)),
                  )).toList(),
                )
              : Text('Off',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade500)),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════
// ─── BOT EDIT SHEET ──────────────────────────────────────
// ══════════════════════════════════════════════════════════
class _BotEditSheet extends StatefulWidget {
  final TelegramBot bot;
  const _BotEditSheet({required this.bot});

  @override
  State<_BotEditSheet> createState() => _BotEditSheetState();
}

class _BotEditSheetState extends State<_BotEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _tokenCtrl;
  late final TextEditingController _chatCtrl;
  late List<String> _hitTimeframes;
  late List<String> _newTimeframes;
  late bool _manualAlerts;
  bool _obscureToken = true;
  bool _testing      = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl       = TextEditingController(text: widget.bot.name);
    _tokenCtrl      = TextEditingController(text: widget.bot.token);
    _chatCtrl       = TextEditingController(text: widget.bot.chatId);
    _hitTimeframes  = List.from(widget.bot.hitTimeframes);
    _newTimeframes  = List.from(widget.bot.newTimeframes);
    _manualAlerts   = widget.bot.canReceiveManualAlerts;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _tokenCtrl.dispose();
    _chatCtrl.dispose();
    super.dispose();
  }

  TelegramBot _buildBot() => widget.bot.copyWith(
    name:                   _nameCtrl.text.trim(),
    token:                  _tokenCtrl.text.trim(),
    chatId:                 _chatCtrl.text.trim(),
    hitTimeframes:          List.from(_hitTimeframes),
    newTimeframes:          List.from(_newTimeframes),
    canReceiveManualAlerts: _manualAlerts,
  );

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _testing = true);
    final error = await TelegramService.testConnection(_buildBot());
    setState(() => _testing = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(error == null ? Icons.check_circle : Icons.error_outline,
            color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child: Text(error == null
                ? '✅ Test message sent! Check Telegram.'
                : '❌ Failed: $error')),
      ]),
      backgroundColor:
          error == null ? Colors.green.shade700 : Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12),
      duration: Duration(seconds: error == null ? 3 : 5),
    ));
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_hitTimeframes.isEmpty && _newTimeframes.isEmpty && !_manualAlerts) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(
            'Enable at least one alert type: Hit, New Level, or Manual Alerts.'),
        backgroundColor: Colors.orange.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
      ));
      return;
    }
    Navigator.pop(context, _buildBot());
  }

  @override
  Widget build(BuildContext context) {
    final isDark     = Theme.of(context).brightness == Brightness.dark;
    final sheetColor = isDark ? const Color(0xFF1E1E2E) : Colors.white;

    return DraggableScrollableSheet(
      initialChildSize: 0.93,
      minChildSize:     0.5,
      maxChildSize:     0.97,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: sheetColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.smart_toy_rounded,
                      color: Colors.blueAccent, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.bot.token.isEmpty ? 'Add New Bot' : 'Edit Bot',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                  ),
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

                      // ── Name ───────────────────────────
                      const _FieldLabel('Bot Name'),
                      _StyledField(
                        controller: _nameCtrl,
                        hint: 'e.g. Price Alert Bot',
                        validator: (v) =>
                            (v == null || v.trim().isEmpty)
                                ? 'Name is required'
                                : null,
                      ),
                      const SizedBox(height: 16),

                      // ── Token ──────────────────────────
                      const _FieldLabel('Bot Token'),
                      _StyledField(
                        controller: _tokenCtrl,
                        hint: 'e.g. 123456:ABC-DEF...',
                        obscure: _obscureToken,
                        suffixIcon: IconButton(
                          icon: Icon(_obscureToken
                              ? Icons.visibility_off
                              : Icons.visibility,
                              size: 20),
                          onPressed: () => setState(
                              () => _obscureToken = !_obscureToken),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty)
                                ? 'Bot token is required'
                                : null,
                        inputType: TextInputType.visiblePassword,
                      ),
                      const SizedBox(height: 16),

                      // ── Chat ID ────────────────────────
                      const _FieldLabel('Chat ID'),
                      _StyledField(
                        controller: _chatCtrl,
                        hint: 'e.g. -100123456789',
                        validator: (v) =>
                            (v == null || v.trim().isEmpty)
                                ? 'Chat ID is required'
                                : null,
                        inputType: TextInputType.number,
                      ),
                      const SizedBox(height: 28),

                      // ══════════════════════════════════
                      // ALERT TYPE 1: HIT
                      // ══════════════════════════════════
                      _AlertTypeSection(
                        emoji:        '🎯',
                        title:        'Hit Alert Timeframes',
                        subtitle:     'Alert when price touches an existing HH/LL level on these timeframes.',
                        color:        Colors.orange,
                        selected:     _hitTimeframes,
                        onToggle:     (tf) => setState(() {
                          if (_hitTimeframes.contains(tf)) {
                            _hitTimeframes.remove(tf);
                          } else {
                            _hitTimeframes.add(tf);
                            _hitTimeframes.sort((a, b) =>
                                kAllTimeframes.indexOf(a)
                                    .compareTo(kAllTimeframes.indexOf(b)));
                          }
                        }),
                      ),
                      const SizedBox(height: 24),

                      // ══════════════════════════════════
                      // ALERT TYPE 2: NEW LEVEL
                      // ══════════════════════════════════
                      _AlertTypeSection(
                        emoji:        '✨',
                        title:        'New Level Timeframes',
                        subtitle:     'Alert when a brand-new Higher High or Lower Low pivot forms on these timeframes.',
                        color:        Colors.purple,
                        selected:     _newTimeframes,
                        onToggle:     (tf) => setState(() {
                          if (_newTimeframes.contains(tf)) {
                            _newTimeframes.remove(tf);
                          } else {
                            _newTimeframes.add(tf);
                            _newTimeframes.sort((a, b) =>
                                kAllTimeframes.indexOf(a)
                                    .compareTo(kAllTimeframes.indexOf(b)));
                          }
                        }),
                      ),
                      const SizedBox(height: 24),

                      // ══════════════════════════════════
                      // ALERT TYPE 3: MANUAL PRICE ALERTS
                      // ══════════════════════════════════
                      _ManualAlertSection(
                        enabled:   _manualAlerts,
                        onChanged: (v) => setState(() => _manualAlerts = v),
                      ),
                      const SizedBox(height: 28),

                      // ── Test ───────────────────────────
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: _testing ? null : _testConnection,
                          icon: _testing
                              ? const SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation(
                                        Colors.blueAccent),
                                  ),
                                )
                              : const Icon(Icons.send_rounded, size: 18),
                          label: Text(
                              _testing ? 'Sending test...' : 'Test Connection'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.blueAccent,
                            side: const BorderSide(color: Colors.blueAccent),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _SaveButton(onPressed: _save, loading: false),
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
}

// ─── Manual alert toggle section ─────────────────────────
class _ManualAlertSection extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onChanged;
  const _ManualAlertSection({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const color  = Colors.teal;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: enabled
            ? color.withOpacity(0.06)
            : (isDark ? const Color(0xFF1A1A2E) : Colors.grey.shade50),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: enabled
              ? color.withOpacity(0.35)
              : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
        ),
      ),
      child: Row(
        children: [
          const Text('🔔', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Manual Price Alerts',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        color: enabled ? color : null)),
                const SizedBox(height: 2),
                Text(
                  'This bot can be selected when creating manual\n'
                  'price alerts (cross above / below / touch).',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: isDark
                          ? Colors.grey.shade400
                          : Colors.grey.shade600),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: onChanged,
            activeColor: color,
          ),
        ],
      ),
    );
  }
}

// ─── Alert type section with inline timeframe grid ───────
class _AlertTypeSection extends StatelessWidget {
  final String       emoji;
  final String       title;
  final String       subtitle;
  final Color        color;
  final List<String> selected;
  final void Function(String tf) onToggle;

  const _AlertTypeSection({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark   = Theme.of(context).brightness == Brightness.dark;
    final isActive = selected.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isActive
            ? color.withOpacity(0.06)
            : (isDark ? const Color(0xFF1A1A2E) : Colors.grey.shade50),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? color.withOpacity(0.35)
              : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                            color: isActive ? color : null)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: isDark
                                ? Colors.grey.shade400
                                : Colors.grey.shade600)),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // "None" indicator or selected count
          Row(
            children: [
              Text(
                selected.isEmpty
                    ? 'Disabled — tap timeframes to enable'
                    : '${selected.length} selected',
                style: TextStyle(
                  fontSize: 11,
                  fontStyle: selected.isEmpty
                      ? FontStyle.italic
                      : FontStyle.normal,
                  color: selected.isEmpty
                      ? Colors.grey
                      : color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (selected.isNotEmpty) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    for (final tf in List.from(selected)) {
                      onToggle(tf);
                    }
                  },
                  child: Text('Clear all',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.redAccent.withOpacity(0.8))),
                ),
              ],
            ],
          ),

          const SizedBox(height: 10),

          // Timeframe grid
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: kAllTimeframes.map((tf) {
              final sel = selected.contains(tf);
              return GestureDetector(
                onTap: () => onToggle(tf),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel
                        ? color
                        : (isDark
                            ? const Color(0xFF2A2A3E)
                            : Colors.white),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: sel
                          ? color
                          : (isDark
                              ? Colors.grey.shade600
                              : Colors.grey.shade300),
                      width: sel ? 1.5 : 1,
                    ),
                    boxShadow: sel
                        ? [
                            BoxShadow(
                                color: color.withOpacity(0.25),
                                blurRadius: 4,
                                offset: const Offset(0, 2))
                          ]
                        : null,
                  ),
                  child: Text(
                    tf,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: sel
                          ? Colors.white
                          : (isDark
                              ? Colors.grey.shade300
                              : Colors.grey.shade700),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// ─── PAGE 2: TRADING PAIRS ───────────────────────────────
// ══════════════════════════════════════════════════════════
class TradingPairsSettingsPage extends StatefulWidget {
  final VoidCallback onSaved;
  const TradingPairsSettingsPage({super.key, required this.onSaved});

  @override
  State<TradingPairsSettingsPage> createState() =>
      _TradingPairsSettingsPageState();
}

class _TradingPairsSettingsPageState
    extends State<TradingPairsSettingsPage> {
  late List<String> _symbols;
  final _addCtrl   = TextEditingController();
  bool _saving     = false;
  bool _validating = false;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _symbols = List<String>.from(Config.symbols);
  }

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  Future<void> _addPair() async {
    final val = _addCtrl.text.trim().toUpperCase();
    if (val.isEmpty) return;
    if (_symbols.contains(val)) {
      _snack('$val is already in the list', isError: true);
      return;
    }
    setState(() => _validating = true);
    final result = await BinanceService.validateSymbol(val);
    setState(() => _validating = false);
    if (!mounted) return;
    if (!result.isValid) {
      _snack('❌ "$val" not found on Binance: ${result.error}',
          isError: true, duration: 4);
      return;
    }
    setState(() {
      _symbols.add(val);
      _addCtrl.clear();
      _hasChanges = true;
    });
    _snack('✅ $val added', isError: false);
  }

  void _removePair(String symbol) {
    if (_symbols.length <= 1) {
      _snack('At least one trading pair is required', isError: true);
      return;
    }
    setState(() { _symbols.remove(symbol); _hasChanges = true; });
  }

  void _snack(String msg, {required bool isError, int duration = 2}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          isError ? Colors.red.shade700 : Colors.green.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12),
      duration: Duration(seconds: duration),
    ));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ConfigService.saveSymbols(_symbols);
    setState(() { _saving = false; _hasChanges = false; });
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _PageScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoBanner(
            icon: Icons.currency_bitcoin,
            text: 'Type a Binance symbol and tap + to validate & add.',
          ),
          const SizedBox(height: 16),

          if (_hasChanges)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.shade400),
              ),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded,
                    color: Colors.orange.shade600, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Save then restart the bot for new pairs to take effect.',
                    style: TextStyle(fontSize: 12.5, color: Colors.orange),
                  ),
                ),
              ]),
            ),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _StyledField(
                  controller: _addCtrl,
                  hint: 'e.g. BNBUSDT',
                  inputType: TextInputType.text,
                  capitalization: TextCapitalization.characters,
                  onSubmitted: (_) => _addPair(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _validating ? null : _addPair,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    elevation: 0,
                  ),
                  child: _validating
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : const Icon(Icons.add_rounded, size: 22),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),
          _FieldLabel('Active Pairs (${_symbols.length})'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _symbols.map((s) => Chip(
              label: Text(s,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              deleteIcon: const Icon(Icons.close, size: 16),
              onDeleted: () => _removePair(s),
              backgroundColor:
                  isDark ? const Color(0xFF2A2A3E) : Colors.blue.shade50,
              side: BorderSide(
                color: isDark
                    ? Colors.blueAccent.withOpacity(0.3)
                    : Colors.blue.shade200,
              ),
              deleteIconColor: Colors.redAccent,
            )).toList(),
          ),

          const SizedBox(height: 28),
          _SaveButton(onPressed: _save, loading: _saving),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// ─── PAGE 3: INDICATOR SETTINGS ──────────────────────────
// ══════════════════════════════════════════════════════════
class IndicatorSettingsPage extends StatefulWidget {
  final VoidCallback onSaved;
  const IndicatorSettingsPage({super.key, required this.onSaved});

  @override
  State<IndicatorSettingsPage> createState() => _IndicatorSettingsPageState();
}

class _IndicatorSettingsPageState extends State<IndicatorSettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _pivotCtrl;
  late final TextEditingController _limitCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _pivotCtrl = TextEditingController(text: Config.pivotLen.toString());
    _limitCtrl = TextEditingController(text: Config.limit.toString());
  }

  @override
  void dispose() {
    _pivotCtrl.dispose();
    _limitCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    await ConfigService.saveIndicator(
      pivotLen: int.parse(_pivotCtrl.text.trim()),
      limit:    int.parse(_limitCtrl.text.trim()),
    );
    setState(() => _saving = false);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoBanner(
              icon: Icons.tune_rounded,
              text: 'Pivot Length: how many candles on each side define a pivot point.',
            ),
            const SizedBox(height: 20),
            const _FieldLabel('Pivot Length'),
            _StyledField(
              controller: _pivotCtrl,
              hint: 'e.g. 5',
              inputType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              helperText: 'Recommended: 3 – 10',
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n < 1) return 'Must be a positive number';
                if (n > 50) return 'Maximum is 50';
                return null;
              },
            ),
            const SizedBox(height: 16),
            const _FieldLabel('Candle Limit'),
            _StyledField(
              controller: _limitCtrl,
              hint: 'e.g. 1000',
              inputType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              helperText: 'Max 1000 (Binance API limit)',
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n < 50) return 'Minimum is 50 candles';
                if (n > 1000) return 'Maximum is 1000 (Binance limit)';
                return null;
              },
            ),
            const SizedBox(height: 28),
            _SaveButton(onPressed: _save, loading: _saving),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// ─── PAGE 4: BOT SETTINGS ────────────────────────────────
// ══════════════════════════════════════════════════════════
class BotSettingsPage extends StatefulWidget {
  final VoidCallback onSaved;
  const BotSettingsPage({super.key, required this.onSaved});

  @override
  State<BotSettingsPage> createState() => _BotSettingsPageState();
}

class _BotSettingsPageState extends State<BotSettingsPage> {
  late int _checkEvery;
  bool _saving = false;
  static const _presets = [1, 3, 5, 10, 15, 30, 60];

  @override
  void initState() {
    super.initState();
    _checkEvery = Config.checkEveryMinutes;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ConfigService.saveBotSettings(checkEveryMinutes: _checkEvery);
    setState(() => _saving = false);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Show effective timeframes for reference
    final tfs = Config.effectiveTimeframes;

    return _PageScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoBanner(
            icon: Icons.timer_rounded,
            text: 'Set how often the bot polls Binance. '
                'Currently monitoring: ${tfs.isEmpty ? "none" : tfs.join(", ")}.',
          ),
          const SizedBox(height: 20),
          const _FieldLabel('Check Interval'),
          const SizedBox(height: 4),
          Text(
            'Every $_checkEvery minute${_checkEvery == 1 ? '' : 's'}',
            style: const TextStyle(
                fontSize: 13,
                color: Colors.blueAccent,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor:
                  isDark ? Colors.grey.shade800 : Colors.grey.shade200,
              thumbColor: Colors.blueAccent,
              overlayColor: Colors.blueAccent.withOpacity(0.15),
              trackHeight: 4,
            ),
            child: Slider(
              value: _checkEvery.toDouble(),
              min: 1, max: 60, divisions: 59,
              onChanged: (v) => setState(() => _checkEvery = v.round()),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('1 min', style: TextStyle(fontSize: 11, color: Colors.grey)),
              Text('60 min', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 20),
          const _FieldLabel('Quick Presets'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: _presets.map((p) {
              final sel = _checkEvery == p;
              return GestureDetector(
                onTap: () => setState(() => _checkEvery = p),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel
                        ? Colors.blueAccent
                        : (isDark
                            ? const Color(0xFF2A2A3E)
                            : Colors.grey.shade100),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: sel ? Colors.blueAccent : Colors.grey.shade600,
                    ),
                  ),
                  child: Text('${p}m',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: sel
                              ? Colors.white
                              : (isDark
                                  ? Colors.grey.shade300
                                  : Colors.grey.shade700))),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 28),
          _SaveButton(onPressed: _save, loading: _saving),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// ─── SHARED PRIVATE WIDGETS ──────────────────────────────
// ══════════════════════════════════════════════════════════

class _PageScaffold extends StatelessWidget {
  final Widget child;
  const _PageScaffold({required this.child});
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: child,
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoBanner({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blueAccent.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blueAccent.withOpacity(0.25)),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: Colors.blueAccent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: const TextStyle(fontSize: 12.5, color: Colors.blueAccent)),
        ),
      ]),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;
  const _FieldLabel(this.label);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(label,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.blueAccent)),
    );
  }
}

class _StyledField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;
  final TextInputType? inputType;
  final List<TextInputFormatter>? inputFormatters;
  final String? helperText;
  final TextCapitalization capitalization;
  final void Function(String)? onSubmitted;

  const _StyledField({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.suffixIcon,
    this.validator,
    this.inputType,
    this.inputFormatters,
    this.helperText,
    this.capitalization = TextCapitalization.none,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: inputType,
      inputFormatters: inputFormatters,
      textCapitalization: capitalization,
      onFieldSubmitted: onSubmitted,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
        helperText: helperText,
        helperStyle: TextStyle(fontSize: 11, color: Colors.grey.shade500),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: isDark ? const Color(0xFF1E1E2E) : Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
                color:
                    isDark ? Colors.grey.shade700 : Colors.grey.shade300)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                const BorderSide(color: Colors.blueAccent, width: 1.8)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Colors.redAccent)),
        focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                const BorderSide(color: Colors.redAccent, width: 1.8)),
      ),
      validator: validator,
    );
  }
}

class _SaveButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool loading;
  const _SaveButton({required this.onPressed, required this.loading});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity, height: 48,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blueAccent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          elevation: 0,
        ),
        child: loading
            ? const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            : const Text('Save Changes',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
