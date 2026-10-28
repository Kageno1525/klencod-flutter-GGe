import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/services/auto_defense_service.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

class AutoDefenseScreen extends StatefulWidget {
  final GgeClient client;
  const AutoDefenseScreen({super.key, required this.client});

  @override
  State<AutoDefenseScreen> createState() => _AutoDefenseScreenState();
}

class _AutoDefenseScreenState extends State<AutoDefenseScreen> {
  final svc = AutoDefenseService.instance;
  Timer? _ticker;
  StreamSubscription? _logSub;

  bool _loading = true;

  final _normalTriggerCtrl = TextEditingController();
  final _spyTriggerCtrl = TextEditingController();
  final _saveHoursCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _logSub = svc.logStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _load() async {
    await svc.init();
    if (!mounted) return;
    _syncControllers();
    setState(() => _loading = false);
  }

  void _syncControllers() {
    _normalTriggerCtrl.text = '${svc.settings.normalTriggerSeconds}';
    _spyTriggerCtrl.text = '${svc.settings.spyTriggerSeconds}';
    _saveHoursCtrl.text = '${svc.settings.saveHours}';
  }

  Future<void> _update() async {
    await svc.settings.save();
    await svc.reloadSettings();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _logSub?.cancel();
    _normalTriggerCtrl.dispose();
    _spyTriggerCtrl.dispose();
    _saveHoursCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          AppTheme.background(context),
          SafeArea(
            child: Column(
              children: [
                _header(context),
                Expanded(
                  child: _loading
                      ? const Center(
                          child:
                              CircularProgressIndicator(color: AppTheme.purple))
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          children: [
                            _masterCard(context),
                            const SizedBox(height: 14),
                            _modesCard(context),
                            const SizedBox(height: 14),
                            _timingCard(context),
                            const SizedBox(height: 14),
                            _priorityCard(context),
                            const SizedBox(height: 14),
                            _statusCard(context),
                            const SizedBox(height: 14),
                            _logCard(context),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          AppIconBtn(
            icon: Icons.arrow_back_rounded,
            onTap: () => Navigator.pop(context),
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              S.isAr ? 'الدفاع التلقائي' : 'Auto Defense',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppTheme.textColor(context),
                letterSpacing: -0.3,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _masterCard(BuildContext context) {
    final on = svc.settings.enabled;
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              gradient: on
                  ? AppTheme.successGradient
                  : const LinearGradient(colors: [Colors.grey, Colors.grey]),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              on ? Icons.security_rounded : Icons.shield_outlined,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.isAr ? 'الوضع العام' : 'Master switch',
                  style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  on
                      ? (S.isAr ? 'يعمل الآن' : 'Active')
                      : (S.isAr ? 'متوقف' : 'Disabled'),
                  style: TextStyle(
                    color: on ? AppTheme.green : AppTheme.subTextColor(context),
                    fontSize: 11,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: on,
            activeColor: AppTheme.green,
            onChanged: (v) async {
              svc.settings.enabled = v;
              await _update();
            },
          ),
        ],
      ),
    );
  }

  Widget _modesCard(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune_rounded, color: AppTheme.purple, size: 18),
              const SizedBox(width: 8),
              Text(
                S.isAr ? 'الأوضاع' : 'Modes',
                style: TextStyle(
                  color: AppTheme.textColor(context),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _toggle(
            context,
            icon: Icons.shield_rounded,
            title: S.isAr ? 'الوضع العادي' : 'Normal mode',
            subtitle: S.isAr
                ? 'تهريب لأقرب حليف عند اقتراب الهجوم'
                : 'Evacuate to best ally when attack nears',
            value: svc.settings.normalModeEnabled,
            onChanged: (v) {
              svc.settings.normalModeEnabled = v;
              _update();
            },
          ),
          Divider(color: AppTheme.subTextColor(context).withOpacity(0.1)),
          _toggle(
            context,
            icon: Icons.bookmark_added_rounded,
            title: S.isAr ? 'وضع الحفظ' : 'Save mode',
            subtitle: S.isAr
                ? 'يحفظ الجنود ${svc.settings.saveHours} ساعة عند الحليف المفضّل'
                : 'Save units ${svc.settings.saveHours}h at preferred ally',
            value: svc.settings.saveModeEnabled,
            onChanged: (v) {
              svc.settings.saveModeEnabled = v;
              _update();
            },
          ),
          Divider(color: AppTheme.subTextColor(context).withOpacity(0.1)),
          _toggle(
            context,
            icon: Icons.visibility_off_rounded,
            title: S.isAr ? 'وضع Spy' : 'Spy mode',
            subtitle: S.isAr
                ? 'يهرب ${svc.settings.spyTriggerSeconds}s قبل، ويسحب بعد الهجمة'
                : 'Evacuate ${svc.settings.spyTriggerSeconds}s before, recall after hit',
            value: svc.settings.spyModeEnabled,
            onChanged: (v) {
              svc.settings.spyModeEnabled = v;
              _update();
            },
          ),
          Divider(color: AppTheme.subTextColor(context).withOpacity(0.1)),
          _toggle(
            context,
            icon: Icons.block_rounded,
            title: S.isAr ? 'تجاهل هجمات NPC' : 'Skip NPC attacks',
            subtitle: S.isAr
                ? 'لا تهرب من هجمات الوحوش/البرابرة'
                : 'Ignore monster/barbarian attacks',
            value: svc.settings.skipNpcAttacks,
            onChanged: (v) {
              svc.settings.skipNpcAttacks = v;
              _update();
            },
          ),
        ],
      ),
    );
  }

  Widget _toggle(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon,
              size: 18,
              color: value ? AppTheme.teal : AppTheme.subTextColor(context)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: AppTheme.subTextColor(context),
                    fontSize: 10.5,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          Switch(
              value: value, activeColor: AppTheme.teal, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _timingCard(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule_rounded,
                  color: AppTheme.blue, size: 18),
              const SizedBox(width: 8),
              Text(
                S.isAr ? 'التوقيت' : 'Timing',
                style: TextStyle(
                  color: AppTheme.textColor(context),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _numberRow(
            context,
            label: S.isAr ? 'Normal: وقت التهريب' : 'Normal: trigger',
            ctrl: _normalTriggerCtrl,
            suffix: 's',
            onChanged: (v) {
              svc.settings.normalTriggerSeconds = v.clamp(10, 300);
              _update();
            },
          ),
          _numberRow(
            context,
            label: S.isAr ? 'Spy: وقت التهريب' : 'Spy: trigger',
            ctrl: _spyTriggerCtrl,
            suffix: 's',
            onChanged: (v) {
              svc.settings.spyTriggerSeconds = v.clamp(10, 300);
              _update();
            },
          ),
          _numberRow(
            context,
            label: S.isAr ? 'وضع الحفظ: مدة (ساعات)' : 'Save: hours',
            ctrl: _saveHoursCtrl,
            suffix: 'h',
            onChanged: (v) {
              svc.settings.saveHours = v.clamp(1, 48);
              _update();
            },
          ),
        ],
      ),
    );
  }

  Widget _numberRow(
    BuildContext context, {
    required String label,
    required TextEditingController ctrl,
    required String suffix,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AppTheme.textColor(context),
                fontSize: 12.5,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            height: 38,
            child: TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textColor(context),
                fontSize: 13,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none,
              ),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                suffixText: suffix,
                suffixStyle: TextStyle(
                    color: AppTheme.subTextColor(context), fontSize: 11),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                      color: AppTheme.subTextColor(context).withOpacity(0.2)),
                ),
              ),
              onSubmitted: (s) {
                final v = int.tryParse(s);
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _priorityCard(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sort_rounded, color: AppTheme.orange, size: 18),
              const SizedBox(width: 8),
              Text(
                S.isAr ? 'أولوية الجنود' : 'Unit priority',
                style: TextStyle(
                  color: AppTheme.textColor(context),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            svc.settings.unitPriority.isEmpty
                ? (S.isAr
                    ? 'لا توجد أولوية — الأكبر عددًا أولاً'
                    : 'No priority — largest first')
                : '${svc.settings.unitPriority.length} types ordered',
            style: TextStyle(
              color: AppTheme.subTextColor(context),
              fontSize: 11,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showUnitPriorityPicker(context),
                  icon: const Icon(Icons.edit_rounded, size: 14),
                  label: Text(
                    S.isAr ? 'تعديل' : 'Edit',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        decoration: TextDecoration.none),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.orange,
                    side: BorderSide(color: AppTheme.orange.withOpacity(0.5)),
                  ),
                ),
              ),
              if (svc.settings.unitPriority.isNotEmpty) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    svc.settings.unitPriority.clear();
                    _update();
                  },
                  child: Text(
                    S.isAr ? 'مسح' : 'Clear',
                    style: const TextStyle(
                        color: AppTheme.red,
                        fontSize: 12,
                        decoration: TextDecoration.none),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showUnitPriorityPicker(BuildContext context) async {
    final ctrl =
        TextEditingController(text: svc.settings.unitPriority.join(','));
    final res = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(
          S.isAr ? 'أولوية الجنود (wodIds)' : 'Unit priority (wodIds)',
          style: const TextStyle(decoration: TextDecoration.none),
        ),
        content: TextField(
          controller: ctrl,
          style: TextStyle(
              color: AppTheme.textColor(context),
              decoration: TextDecoration.none),
          decoration: InputDecoration(
            hintText: '227,628,630,...',
            hintStyle: TextStyle(
                color: AppTheme.subTextColor(context).withOpacity(0.5)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(S.cancel)),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: Text(S.save)),
        ],
      ),
    );
    if (res != null) {
      svc.settings.unitPriority = res
          .split(',')
          .map((s) => int.tryParse(s.trim()) ?? 0)
          .where((i) => i > 0)
          .toList();
      await _update();
    }
    ctrl.dispose();
  }

  Widget _statusCard(BuildContext context) {
    final pending = svc.pendingAttacks;
    final evacs = svc.activeEvacuations;
    final activeEvacs = evacs.values.where((e) => !e.recalled).length;

    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.monitor_heart_rounded,
                  color: AppTheme.teal, size: 18),
              const SizedBox(width: 8),
              Text(
                S.isAr ? 'الحالة الحالية' : 'Current status',
                style: TextStyle(
                  color: AppTheme.textColor(context),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _statRow(
            context,
            label: S.isAr ? 'هجمات قادمة' : 'Incoming attacks',
            value: '${pending.length}',
            color: pending.isEmpty ? AppTheme.green : AppTheme.orange,
          ),
          _statRow(
            context,
            label: S.isAr ? 'عمليات تهريب نشطة' : 'Active evacuations',
            value: '$activeEvacs',
            color: activeEvacs == 0
                ? AppTheme.subTextColor(context)
                : AppTheme.teal,
          ),
          if (pending.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...pending.values.take(5).map((a) {
              final r = a.remainingSeconds();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(Icons.timer_rounded,
                        size: 12,
                        color: r > 0 ? AppTheme.orange : AppTheme.green),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${a.attackerName} → ${a.targetAreaId}',
                        style: TextStyle(
                          color: AppTheme.textColor(context),
                          fontSize: 11.5,
                          decoration: TextDecoration.none,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      r > 0 ? '${r}s' : 'HIT',
                      style: TextStyle(
                        color: r > 0 ? AppTheme.orange : AppTheme.green,
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _statRow(BuildContext context,
      {required String label, required String value, required Color color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AppTheme.subTextColor(context),
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  Widget _logCard(BuildContext context) {
    final entries = svc.log;
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded,
                  color: AppTheme.purple, size: 18),
              const SizedBox(width: 8),
              Text(
                S.isAr ? 'سجل الأحداث' : 'Event log',
                style: TextStyle(
                  color: AppTheme.textColor(context),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                S.isAr ? 'لا توجد أحداث بعد' : 'No events yet',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.subTextColor(context),
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              ),
            )
          else
            ...entries.take(30).map((e) {
              final color = switch (e.kind) {
                'evac' => AppTheme.teal,
                'recall' => AppTheme.blue,
                'warn' => AppTheme.orange,
                'error' => AppTheme.red,
                _ => AppTheme.subTextColor(context),
              };
              final t =
                  '${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}:${e.at.second.toString().padLeft(2, '0')}';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t,
                      style: TextStyle(
                        color: AppTheme.subTextColor(context),
                        fontSize: 10,
                        fontFamily: 'monospace',
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        e.message,
                        style: TextStyle(
                          color: color,
                          fontSize: 11,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}