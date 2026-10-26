import 'package:flutter/material.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/services/notifications_service.dart';
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
                _settingsCard(context),
                const SizedBox(height: 8),
                Expanded(
                  child: StreamBuilder<List<AttackAlert>>(
                    stream: NotificationsService.historyStream,
                    initialData: NotificationsService.history,
                    builder: (_, snap) {
                      final alerts = snap.data ?? [];
                      if (alerts.isEmpty) return _emptyView(context);
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: alerts.length,
                        itemBuilder: (_, i) => FadeSlideIn(
                          delay: Duration(milliseconds: 60 + i * 50),
                          child: _alertCard(alerts[i]),
                        ),
                      );
                    },
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

  Widget _settingsCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: AppTheme.glassCard(
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
          ],
        ),
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

  Widget _emptyView(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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