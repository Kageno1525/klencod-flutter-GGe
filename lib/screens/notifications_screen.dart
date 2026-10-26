import 'package:flutter/material.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/services/notifications_service.dart';
import 'package:gge/services/background_service.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

class NotificationsScreen extends StatefulWidget {
  final GgeClient client;
  const NotificationsScreen({super.key, required this.client});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    NotificationsService.startListening();
    Future.microtask(() => NotificationsService.checkPermission());
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
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _serviceCard(context),
                      const SizedBox(height: 12),
                      _settingsCard(context),
                      const SizedBox(height: 12),
                      _historySection(context),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.notificationsTitle,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textColor(context),
                    letterSpacing: -0.3,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  '${NotificationsService.history.length} alerts',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subTextColor(context),
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          AppIconBtn(
            icon: Icons.delete_sweep_rounded,
            color: AppTheme.red,
            onTap: () {
              NotificationsService.clearHistory();
              setState(() {});
            },
            size: 42,
          ),
        ],
      ),
    );
  }

  Widget _serviceCard(BuildContext context) {
    final running = BackgroundService.isRunning;
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: running
                      ? AppTheme.successGradient
                      : const LinearGradient(
                          colors: [Colors.grey, Colors.grey],
                        ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  running
                      ? Icons.shield_moon_rounded
                      : Icons.shield_outlined,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      running ? 'الحماية شغالة' : 'الحماية متوقفة',
                      style: TextStyle(
                        color: AppTheme.textColor(context),
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    Text(
                      running
                          ? 'التطبيق شغال في الخلفية — هيوصلك إشعار أي هجوم'
                          : 'شغّل الحماية عشان يوصلك إشعارات في الخلفية',
                      style: TextStyle(
                        color: AppTheme.subTextColor(context),
                        fontSize: 11,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: running,
                onChanged: (v) async {
                  if (v) {
                    await BackgroundService.start();
                  } else {
                    await BackgroundService.stop();
                  }
                  if (mounted) setState(() {});
                },
                activeColor: AppTheme.green,
              ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 12),
            Divider(color: AppTheme.subTextColor(context).withOpacity(0.1)),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                final optimized = await BackgroundService.isBatteryOptimized();
                if (optimized) {
                  await BackgroundService.requestBatteryOptimizationExemption();
                  if (mounted) setState(() {});
                }
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.orange.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppTheme.orange.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.battery_alert_rounded,
                        color: AppTheme.orange, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'إيقاف تحسين البطارية (مهم لشاومي وأوبو)',
                        style: TextStyle(
                          color: AppTheme.textColor(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios_rounded,
                        size: 12, color: AppTheme.orange),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _settingsCard(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(
        children: [
          _toggleRow(
            icon: Icons.notifications_active_rounded,
            title: S.notificationsEnabled,
            subtitle: S.notificationsEnabledDesc,
            value: NotificationsService.enabled,
            onChanged: (v) async {
              await NotificationsService.setEnabled(v);
              if (mounted) setState(() {});
            },
          ),
          Divider(color: AppTheme.subTextColor(context).withOpacity(0.1)),
          _toggleRow(
            icon: Icons.volume_up_rounded,
            title: S.soundAlert,
            subtitle: S.soundAlertDesc,
            value: NotificationsService.soundEnabled,
            onChanged: (v) async {
              await NotificationsService.setSound(v);
              if (mounted) setState(() {});
            },
          ),
          if (!NotificationsService.permissionGranted) ...[
            Divider(color: AppTheme.subTextColor(context).withOpacity(0.1)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: InkWell(
                onTap: () async {
                  final granted =
                      await NotificationsService.requestPermission();
                  if (!granted && mounted) {
                    await NotificationsService.openNotificationSettings();
                  }
                  if (mounted) setState(() {});
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.red.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: AppTheme.red.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: AppTheme.red, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'صلاحية الإشعارات مش مفعّلة — اضغط للتفعيل',
                          style: TextStyle(
                            color: AppTheme.red,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _toggleRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Future<void> Function(bool) onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppTheme.purple.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppTheme.purple, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                      color: AppTheme.textColor(context),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      decoration: TextDecoration.none),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                      color: AppTheme.subTextColor(context),
                      fontSize: 10.5,
                      decoration: TextDecoration.none),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: (v) => onChanged(v),
            activeColor: AppTheme.purple,
          ),
        ],
      ),
    );
  }

  Widget _historySection(BuildContext context) {
    return StreamBuilder<List<AttackAlert>>(
      stream: NotificationsService.historyStream,
      initialData: NotificationsService.history,
      builder: (_, snap) {
        final alerts = snap.data ?? [];
        if (alerts.isEmpty) return _emptyView(context);
        return Column(
          children: alerts
              .map((a) => FadeSlideIn(
                    delay: const Duration(milliseconds: 60),
                    child: _alertCard(a),
                  ))
              .toList(),
        );
      },
    );
  }

  Widget _emptyView(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: AppTheme.purple.withOpacity(0.12),
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.purple.withOpacity(0.3)),
            ),
            child: Icon(Icons.shield_moon_rounded,
                size: 56, color: AppTheme.purple.withOpacity(0.7)),
          ),
          const SizedBox(height: 20),
          Text(
            S.noAlerts,
            style: TextStyle(
                color: AppTheme.textColor(context),
                fontSize: 15,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none),
          ),
          const SizedBox(height: 8),
          Text(
            S.noAlertsDesc,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppTheme.subTextColor(context),
                fontSize: 12,
                decoration: TextDecoration.none),
          ),
        ],
      ),
    );
  }

  Widget _alertCard(AttackAlert alert) {
    final isIncoming = alert.remainingSeconds > 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: AppTheme.glassCard(
        context: context,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: AppTheme.dangerGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.gavel_rounded,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        alert.attackerName,
                        style: TextStyle(
                            color: AppTheme.textColor(context),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            decoration: TextDecoration.none),
                      ),
                      Text(
                        '${alert.kingdomName} · (${alert.targetX}, ${alert.targetY})',
                        style: TextStyle(
                            color: AppTheme.subTextColor(context),
                            fontSize: 10.5,
                            decoration: TextDecoration.none),
                      ),
                    ],
                  ),
                ),
                InfoChip(
                  icon: isIncoming
                      ? Icons.timer_rounded
                      : Icons.check_circle_rounded,
                  label: alert.remainingLabel,
                  color: isIncoming ? AppTheme.orange : AppTheme.green,
                ),
              ],
            ),
            if (alert.units.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: alert.units.map((u) {
                  return InfoChip(
                    icon: Icons.shield_rounded,
                    label: '${u.displayName} ${u.amount}',
                    color: AppTheme.purple,
                  );
                }).toList(),
              ),
            ],
            if (alert.totalUnits > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${alert.totalUnits} ${S.units}',
                style: TextStyle(
                    color: AppTheme.subTextColor(context),
                    fontSize: 11,
                    decoration: TextDecoration.none),
              ),
            ],
          ],
        ),
      ),
    );
  }
}