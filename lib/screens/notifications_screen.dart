import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/services/notifications_service.dart';
import 'package:gge/screens/notifications_settings_screen.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationsService.startListening();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NotificationsService.checkPermission();
    }
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
                          delay: Duration(milliseconds: 40 + i * 40),
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
                  '${NotificationsService.history.length} ${S.isAr ? "تنبيه" : "alerts"}',
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
            icon: Icons.settings_rounded,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      NotificationsSettingsScreen(client: widget.client),
                ),
              );
            },
            size: 42,
          ),
          const SizedBox(width: 8),
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
    final isAlly = alert.isAllianceAttack;

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
                    gradient: isAlly
                        ? AppTheme.successGradient
                        : AppTheme.dangerGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isAlly ? Icons.shield_moon_rounded : Icons.gavel_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              alert.attackerName,
                              style: TextStyle(
                                  color: AppTheme.textColor(context),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  decoration: TextDecoration.none),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isAlly) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.teal.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                S.allianceMember,
                                style: const TextStyle(
                                    color: AppTheme.teal,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    decoration: TextDecoration.none),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${alert.kingdomName} · ${alert.attackerX},${alert.attackerY}',
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
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (alert.attackerAlliance != null &&
                    alert.attackerAlliance!.isNotEmpty)
                  InfoChip(
                    icon: Icons.group_rounded,
                    label: alert.attackerAlliance!,
                    color: AppTheme.orange,
                  ),
                if (alert.attackerCastleName != null &&
                    alert.attackerCastleName!.isNotEmpty)
                  InfoChip(
                    icon: Icons.castle_rounded,
                    label: alert.attackerCastleName!,
                    color: AppTheme.blue,
                  ),
                InfoChip(
                  icon: Icons.shield_rounded,
                  label: '${alert.totalUnits} ${S.units}',
                  color: AppTheme.purple,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _actionBtn(
                    icon: Icons.info_outline_rounded,
                    label: S.details,
                    color: AppTheme.blue,
                    onTap: () => _showDetails(context, alert),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _actionBtn(
                    icon: Icons.delete_outline_rounded,
                    label: S.delete,
                    color: AppTheme.red,
                    onTap: () => _confirmDelete(alert),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: color,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(AttackAlert alert) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(S.delete,
            style: const TextStyle(decoration: TextDecoration.none)),
        content: Text(S.deleteAlertConfirm,
            style: const TextStyle(decoration: TextDecoration.none)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: Text(S.delete,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true) {
      NotificationsService.removeAlert(alert.movementId);
    }
  }

  void _showDetails(BuildContext context, AttackAlert alert) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (_, __, ___) => _AlertDetailsDialog(alert: alert),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  Details Dialog — blur + X + clean sections
// ═══════════════════════════════════════════════════════════
class _AlertDetailsDialog extends StatelessWidget {
  final AttackAlert alert;
  const _AlertDetailsDialog({required this.alert});

  @override
  Widget build(BuildContext context) {
    final isAlly = alert.isAllianceAttack;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenH = MediaQuery.of(context).size.height;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final topPad = MediaQuery.of(context).padding.top;
    final defense = GgeClient().cachedStatsByArea?[alert.targetAreaId];

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Blur backdrop
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(color: Colors.black.withOpacity(0.55)),
              ),
            ),
          ),

          // Sheet content
          Positioned(
            left: 12,
            right: 12,
            top: topPad + 40,
            bottom: bottomPad + 12,
            child: Container(
              constraints: BoxConstraints(maxHeight: screenH * 0.88),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1C1E29) : Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.fromLTRB(18, 14, 14, 18),
                      decoration: BoxDecoration(
                        gradient: isAlly
                            ? AppTheme.successGradient
                            : AppTheme.dangerGradient,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 40,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.5),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const Spacer(),
                              _closeBtn(context),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.22),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  isAlly
                                      ? Icons.shield_moon_rounded
                                      : Icons.gavel_rounded,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isAlly
                                          ? (S.isAr
                                              ? 'هجوم على عضو تحالف'
                                              : 'Ally under attack')
                                          : (S.isAr
                                              ? 'هجوم عليك'
                                              : 'Attack on you'),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      alert.remainingLabel,
                                      style: TextStyle(
                                        color:
                                            Colors.white.withOpacity(0.85),
                                        fontSize: 12,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Content
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Attacker info
                            _sectionLabel(
                              context,
                              S.isAr ? 'معلومات المهاجم' : 'Attacker info',
                              Icons.person_rounded,
                              AppTheme.red,
                            ),
                            const SizedBox(height: 8),
                            _infoRow(context,
                                icon: Icons.person_rounded,
                                label: S.isAr ? 'الاسم' : 'Name',
                                value: alert.attackerName,
                                color: AppTheme.red),
                            if (alert.attackerAlliance != null &&
                                alert.attackerAlliance!.isNotEmpty)
                              _infoRow(context,
                                  icon: Icons.group_rounded,
                                  label: S.isAr ? 'التحالف' : 'Alliance',
                                  value: alert.attackerAlliance!,
                                  color: AppTheme.orange)
                            else
                              _infoRow(context,
                                  icon: Icons.group_rounded,
                                  label: S.isAr ? 'التحالف' : 'Alliance',
                                  value:
                                      S.isAr ? 'بدون تحالف' : 'No alliance',
                                  color: AppTheme.subTextColor(context)),
                            if (alert.attackerCastleName != null &&
                                alert.attackerCastleName!.isNotEmpty)
                              _infoRow(context,
                                  icon: Icons.castle_rounded,
                                  label: S.attackerCastle,
                                  value:
                                      '${alert.attackerCastleName!}\n(${alert.attackerX}, ${alert.attackerY})',
                                  color: AppTheme.blue),

                            const SizedBox(height: 16),

                            // Attack info
                            _sectionLabel(
                              context,
                              S.isAr ? 'معلومات الهجوم' : 'Attack info',
                              Icons.gavel_rounded,
                              AppTheme.purple,
                            ),
                            const SizedBox(height: 8),
                            _infoRow(context,
                                icon: Icons.map_rounded,
                                label: S.isAr ? 'الخريطة' : 'Map',
                                value: alert.kingdomName,
                                color: AppTheme.teal),
                            if (alert.targetCastleName != null &&
                                alert.targetCastleName!.isNotEmpty)
                              _infoRow(context,
                                  icon: Icons.flag_rounded,
                                  label: S.targetCastle,
                                  value:
                                      '${alert.targetCastleName!}\n(${alert.targetX}, ${alert.targetY})',
                                  color: AppTheme.purple),
                            _infoRow(context,
                                icon: Icons.timer_rounded,
                                label: S.timeRemaining,
                                value: alert.remainingLabel,
                                color: AppTheme.orange),
                            _infoRow(context,
                                icon: Icons.groups_rounded,
                                label: S.isAr
                                    ? 'إجمالي الجنود'
                                    : 'Total units',
                                value:
                                    '${alert.totalUnits} ${S.isAr ? "جندي" : "units"}',
                                color: AppTheme.red),

                            const SizedBox(height: 16),

                            // Attacking Units — ✅ ياخد List<AttackUnit>
                            _sectionLabel(
                              context,
                              S.attackingUnits,
                              Icons.military_tech_rounded,
                              AppTheme.red,
                            ),
                            const SizedBox(height: 8),
                            if (alert.units.isEmpty)
                              _noDataCard(
                                context,
                                S.isAr
                                    ? 'لم تصل تفاصيل الجنود بعد'
                                    : 'Unit details not received yet',
                              )
                            else
                              ..._buildAttackUnitRows(
                                context,
                                alert.units,
                                color: AppTheme.red,
                              ),

                            const SizedBox(height: 16),

                            // Defense
                            _sectionLabel(
                              context,
                              S.defenseInfo,
                              Icons.shield_moon_rounded,
                              AppTheme.teal,
                            ),
                            const SizedBox(height: 8),
                            if (defense == null)
                              _noDataCard(context, S.defenseNotAvailable)
                            else ...[
                              _infoRow(context,
                                  icon: Icons.security_rounded,
                                  label: S.defenseStat,
                                  value: '${defense.defense}',
                                  color: AppTheme.teal),
                              const SizedBox(height: 8),
                              if (defense.units.isEmpty)
                                _noDataCard(
                                    context,
                                    S.isAr
                                        ? 'لا توجد وحدات دفاع'
                                        : 'No defense units')
                              else
                                ..._buildCastleUnitRows(
                                  context,
                                  defense.units,
                                  color: AppTheme.teal,
                                ),
                            ],

                            const SizedBox(height: 10),
                          ],
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
    );
  }

  Widget _closeBtn(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.25),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.4)),
          ),
          child:
              const Icon(Icons.close_rounded, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Widget _sectionLabel(
      BuildContext context, String text, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
              color: AppTheme.textColor(context),
              fontWeight: FontWeight.bold,
              fontSize: 13,
              decoration: TextDecoration.none),
        ),
      ],
    );
  }

  Widget _infoRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: TextStyle(
                  color: AppTheme.subTextColor(context),
                  fontSize: 11.5,
                  decoration: TextDecoration.none),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: TextStyle(
                  color: AppTheme.textColor(context),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  // ═══ للـ AttackUnit (هجوم) ═══
  List<Widget> _buildAttackUnitRows(
    BuildContext context,
    List<AttackUnit> attackUnits, {
    required Color color,
  }) {
    final grouped = <String, int>{};
    for (final u in attackUnits) {
      final name = S.unitName(u.displayName);
      grouped[name] = (grouped[name] ?? 0) + u.amount;
    }
    return grouped.entries
        .map((e) =>
            _unitRow(context, name: e.key, amount: e.value, color: color))
        .toList();
  }

  // ═══ للـ CastleUnit (دفاع) ═══
  List<Widget> _buildCastleUnitRows(
    BuildContext context,
    List<CastleUnit> castleUnits, {
    required Color color,
  }) {
    final grouped = <String, int>{};
    for (final u in castleUnits) {
      final name = S.unitName(u.displayName);
      grouped[name] = (grouped[name] ?? 0) + u.amount;
    }
    return grouped.entries
        .map((e) =>
            _unitRow(context, name: e.key, amount: e.value, color: color))
        .toList();
  }

  Widget _unitRow(
    BuildContext context, {
    required String name,
    required int amount,
    required Color color,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.18)),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.gavel_rounded, color: color, size: 13),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                  color: AppTheme.textColor(context),
                  fontSize: 12,
                  decoration: TextDecoration.none),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$amount',
              style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  decoration: TextDecoration.none),
            ),
          ),
        ],
      ),
    );
  }

  Widget _noDataCard(BuildContext context, String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.subTextColor(context).withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
            color: AppTheme.subTextColor(context),
            fontSize: 11.5,
            decoration: TextDecoration.none),
      ),
    );
  }
}