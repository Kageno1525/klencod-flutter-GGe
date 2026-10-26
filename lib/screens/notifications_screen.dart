import 'package:flutter/material.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/services/notifications_service.dart';
import 'package:gge/services/background_service.dart';
import 'package:gge/services/settings_guide_service.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

class NotificationsScreen extends StatefulWidget {
  final GgeClient client;
  const NotificationsScreen({super.key, required this.client});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with WidgetsBindingObserver {
  bool _batteryOptimized = true;
  bool _oemRestricted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationsService.startListening();
    Future.microtask(() async {
      await NotificationsService.checkPermission();
      await _refreshSettingsState();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // re-check when user comes back from system settings
    if (state == AppLifecycleState.resumed) {
      _refreshSettingsState();
    }
  }

  Future<void> _refreshSettingsState() async {
    final bat = await SettingsGuideService.isBatteryOptimized();
    final notif = await NotificationsService.checkPermission();
    final oem = await SettingsGuideService.isOemRestricted();
    if (!mounted) return;
    setState(() {
      _batteryOptimized = bat;
      _oemRestricted = oem;
    });
    // ignore: unused_local_variable
    final _ = notif;
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
                  child: RefreshIndicator(
                    onRefresh: _refreshSettingsState,
                    color: AppTheme.purple,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        _setupGuideCard(context),
                        const SizedBox(height: 12),
                        _serviceCard(context),
                        const SizedBox(height: 12),
                        _settingsCard(context),
                        const SizedBox(height: 12),
                        _historySection(context),
                      ],
                    ),
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

  // ═══════════════════════════════════════════════════════════
  //  SETUP GUIDE — checklist with auto-detection
  // ═══════════════════════════════════════════════════════════
  Widget _setupGuideCard(BuildContext context) {
    final notifDone = NotificationsService.permissionGranted;
    final batteryDone = !_batteryOptimized;

    final allDone = notifDone && batteryDone;

    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  gradient: allDone
                      ? AppTheme.successGradient
                      : AppTheme.orangeGradient,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  allDone
                      ? Icons.check_circle_rounded
                      : Icons.assignment_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      allDone
                          ? 'الإعدادات جاهزة ✓'
                          : 'إعدادات مطلوبة',
                      style: TextStyle(
                        color: AppTheme.textColor(context),
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    Text(
                      allDone
                          ? 'كل حاجة متظبطة، الإشعارات شغالة'
                          : 'اتبع الخطوات دي مرة واحدة',
                      style: TextStyle(
                        color: AppTheme.subTextColor(context),
                        fontSize: 11,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          _setupItem(
            context: context,
            icon: Icons.notifications_active_rounded,
            title: 'صلاحية الإشعارات',
            subtitle: notifDone
                ? 'مفعّلة ✓'
                : 'مطلوبة عشان توصلك التنبيهات',
            done: notifDone,
            actionLabel: notifDone ? 'تعديل' : 'فتح',
            actionColor: notifDone ? AppTheme.blue : AppTheme.red,
            onTap: () async {
              await SettingsGuideService.openNotificationSettings();
              await Future.delayed(const Duration(seconds: 1));
              await _refreshSettingsState();
            },
          ),
          Divider(
              height: 1,
              color: AppTheme.subTextColor(context).withOpacity(0.08)),
          _setupItem(
            context: context,
            icon: Icons.battery_saver_rounded,
            title: 'إيقاف تحسين البطارية',
            subtitle: batteryDone
                ? 'متوقف ✓ — النظام مش هيقتل التطبيق'
                : 'مطلوب عشان التطبيق يشتغل في الخلفية',
            done: batteryDone,
            actionLabel: batteryDone ? 'تعديل' : 'فتح',
            actionColor: batteryDone ? AppTheme.blue : AppTheme.orange,
            onTap: () async {
              await SettingsGuideService.openBatteryOptimization();
              await Future.delayed(const Duration(seconds: 2));
              await _refreshSettingsState();
            },
          ),
          if (_oemRestricted) ...[
            Divider(
                height: 1,
                color: AppTheme.subTextColor(context).withOpacity(0.08)),
            _setupItem(
              context: context,
              icon: Icons.rocket_launch_rounded,
              title: 'Autostart (تشغيل تلقائي)',
              subtitle:
                  'جهازك (${_oemRestricted ? "Xiaomi/OPPO/etc" : "Android"}) محتاج تفعيلها يدوياً',
              done: null,
              actionLabel: 'فتح',
              actionColor: AppTheme.purple,
              onTap: () async {
                await SettingsGuideService.openAutostart();
              },
            ),
          ],
          Divider(
              height: 1,
              color: AppTheme.subTextColor(context).withOpacity(0.08)),
          _setupItem(
            context: context,
            icon: Icons.lock_rounded,
            title: 'قفل التطبيق في Recent Apps',
            subtitle: 'اسحب التطبيق لأسفل واضغط 🔒 عشان ما يتقفلش',
            done: null,
            actionLabel: 'شرح',
            actionColor: AppTheme.teal,
            onTap: () => _showLockGuide(context),
          ),
        ],
      ),
    );
  }

  Widget _setupItem({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool? done,
    required String actionLabel,
    required Color actionColor,
    required VoidCallback onTap,
  }) {
    final Color iconColor;
    final IconData statusIcon;

    if (done == true) {
      iconColor = AppTheme.green;
      statusIcon = Icons.check_circle_rounded;
    } else if (done == false) {
      iconColor = AppTheme.red;
      statusIcon = Icons.cancel_rounded;
    } else {
      iconColor = AppTheme.orange;
      statusIcon = Icons.info_rounded;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: AppTheme.textColor(context),
                          fontWeight: FontWeight.bold,
                          fontSize: 12.5,
                          decoration: TextDecoration.none,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(statusIcon, color: iconColor, size: 14),
                  ],
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
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onTap,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: actionColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: actionColor.withOpacity(0.4)),
              ),
              child: Text(
                actionLabel,
                style: TextStyle(
                  color: actionColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showLockGuide(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.lock_rounded, color: AppTheme.teal),
            const SizedBox(width: 8),
            const Text('قفل التطبيق',
                style: TextStyle(decoration: TextDecoration.none)),
          ],
        ),
        content: const Text(
          '1. اضغط زر الـ Home عشان تطلع من التطبيق\n'
          '2. افتح شاشة الـ Recent Apps (الزرار اللي جنب الـ Home)\n'
          '3. اسحب التطبيق لأسفل → هتلاقي أيقونة 🔒\n'
          '4. اضغطها عشان التطبيق يفضل شغال\n\n'
          'ده بيمنع النظام من إغلاقه تلقائي.',
          style: TextStyle(decoration: TextDecoration.none, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('فهمت'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  //  SERVICE CARD
  // ═══════════════════════════════════════════════════════════
  Widget _serviceCard(BuildContext context) {
    final running = BackgroundService.isRunning;
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(16),
      child: Row(
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
              running ? Icons.shield_moon_rounded : Icons.shield_outlined,
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
                      ? 'التطبيق شغال في الخلفية'
                      : 'شغّلها عشان الإشعارات تشتغل في الخلفية',
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