import 'package:flutter/material.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/services/notifications_service.dart';
import 'package:gge/services/background_service.dart';
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
            // ─── Header ───
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
                          if (alert.attackerAlliance != null &&
                              alert.attackerAlliance!.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.orange.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                alert.attackerAlliance!,
                                style: const TextStyle(
                                    color: AppTheme.orange,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    decoration: TextDecoration.none),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
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

            // ─── Quick info chips ───
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (alert.attackerCastleName != null &&
                    alert.attackerCastleName!.isNotEmpty)
                  InfoChip(
                    icon: Icons.castle_rounded,
                    label: alert.attackerCastleName!,
                    color: AppTheme.blue,
                  ),
                if (alert.totalUnits > 0)
                  InfoChip(
                    icon: Icons.shield_rounded,
                    label: '${alert.totalUnits} ${S.units}',
                    color: AppTheme.purple,
                  ),
              ],
            ),

            // ─── Actions ───
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _actionBtn(
                    icon: Icons.info_outline_rounded,
                    label: S.details,
                    color: AppTheme.blue,
                    onTap: () => _showDetails(alert),
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
        title: Text(S.delete, style: const TextStyle(decoration: TextDecoration.none)),
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

  void _showDetails(AttackAlert alert) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AlertDetailsSheet(alert: alert),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  Details sheet
// ═══════════════════════════════════════════════════════════
class _AlertDetailsSheet extends StatelessWidget {
  final AttackAlert alert;
  const _AlertDetailsSheet({required this.alert});

  @override
  Widget build(BuildContext context) {
    final defense =
        GgeClient().cachedStatsByArea?[alert.targetAreaId];

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.subTextColor(context).withOpacity(0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ─── Attacker ───
                    _infoRow(context,
                        icon: Icons.person_rounded,
                        label: S.isAr ? 'المهاجم' : 'Attacker',
                        value: alert.attackerName,
                        color: AppTheme.red),
                    if (alert.attackerAlliance != null &&
                        alert.attackerAlliance!.isNotEmpty)
                      _infoRow(context,
                          icon: Icons.group_rounded,
                          label: S.isAr ? 'التحالف' : 'Alliance',
                          value: alert.attackerAlliance!,
                          color: AppTheme.orange),
                    if (alert.attackerCastleName != null &&
                        alert.attackerCastleName!.isNotEmpty)
                      _infoRow(context,
                          icon: Icons.castle_rounded,
                          label: S.attackerCastle,
                          value:
                              '${alert.attackerCastleName!} (${alert.attackerX}, ${alert.attackerY})',
                          color: AppTheme.blue),
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
                              '${alert.targetCastleName!} (${alert.targetX}, ${alert.targetY})',
                          color: AppTheme.purple),
                    _infoRow(context,
                        icon: Icons.timer_rounded,
                        label: S.timeRemaining,
                        value: alert.remainingLabel,
                        color: AppTheme.orange),
                    _infoRow(context,
                        icon: Icons.shield_rounded,
                        label: S.isAr ? 'إجمالي الجنود' : 'Total units',
                        value: '${alert.totalUnits}',
                        color: AppTheme.red),

                    const SizedBox(height: 20),

                    // ─── Attacking units ───
                    _sectionTitle(context, S.attackingUnits,
                        Icons.gavel_rounded, AppTheme.red),
                    const SizedBox(height: 10),
                    if (alert.units.isEmpty)
                      _noData(context)
                    else
                      ...alert.units.map((u) => _unitRow(
                            context,
                            name: S.unitName(u.displayName),
                            amount: u.amount,
                            icon: Icons.gavel_rounded,
                            color: AppTheme.red,
                          )),

                    const SizedBox(height: 20),

                    // ─── Defense info ───
                    _sectionTitle(context, S.defenseInfo,
                        Icons.shield_moon_rounded, AppTheme.teal),
                    const SizedBox(height: 10),
                    if (defense == null)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: AppTheme.orange.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline_rounded,
                                color: AppTheme.orange, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                S.defenseNotAvailable,
                                style: TextStyle(
                                    color: AppTheme.textColor(context),
                                    fontSize: 12,
                                    decoration: TextDecoration.none),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      _infoRow(context,
                          icon: Icons.security_rounded,
                          label: S.defenseStat,
                          value: '${defense.defense}',
                          color: AppTheme.teal),
                      const SizedBox(height: 8),
                      if (defense.units.isEmpty)
                        _noData(context)
                      else
                        ...defense.units.map((u) => _unitRow(
                              context,
                              name: S.unitName(u.displayName),
                              amount: u.amount,
                              icon: u.icon,
                              color: u.roleColor,
                            )),
                    ],

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(
      BuildContext context, String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
              color: AppTheme.textColor(context),
              fontWeight: FontWeight.bold,
              fontSize: 14,
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
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 10),
          Text(
            '$label:',
            style: TextStyle(
                color: AppTheme.subTextColor(context),
                fontSize: 12,
                decoration: TextDecoration.none),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                  color: AppTheme.textColor(context),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none),
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _unitRow(
    BuildContext context, {
    required String name,
    required int amount,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
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
          Text(
            '$amount',
            style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                decoration: TextDecoration.none),
          ),
        ],
      ),
    );
  }

  Widget _noData(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.subTextColor(context).withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        S.isAr ? 'لا توجد بيانات' : 'No data',
        textAlign: TextAlign.center,
        style: TextStyle(
            color: AppTheme.subTextColor(context),
            fontSize: 12,
            decoration: TextDecoration.none),
      ),
    );
  }
}