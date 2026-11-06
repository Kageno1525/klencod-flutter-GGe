import 'dart:async';
import 'package:flutter/material.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

class CommandersScreen extends StatefulWidget {
  final GgeClient client;
  const CommandersScreen({super.key, required this.client});

  @override
  State<CommandersScreen> createState() => _CommandersScreenState();
}

class _CommandersScreenState extends State<CommandersScreen> {
  List<CommanderInfo> _commanders = [];
  bool _loading = true;
  Timer? _timer;

  bool _bulkRunning = false;
  int _bulkDone = 0;
  int _bulkTotal = 0;
  String _bulkScope = '';

  int _staleReloadAttempts = 0;
  static const int _maxStaleReloadAttempts = 3;

  @override
  void initState() {
    super.initState();
    _loadCommanders();
  }

  Future<void> _loadCommanders({bool silent = false}) async {
    if (!silent) {
      setState(() => _loading = true);
      _staleReloadAttempts = 0;
    }
    try {
      final cmds = await widget.client.getCommanders();
      if (!mounted) return;
      setState(() {
        _commanders = cmds;
        if (!silent) _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        setState(() => _loading = false);
        _snack('$e', color: AppTheme.red);
      }
    } finally {
      if (mounted) _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      final hasAnyMovement = _commanders.any((c) => c.movement != null);
      if (!hasAnyMovement) {
        _timer?.cancel();
        return;
      }

      final hasActiveMovement = _commanders.any((c) =>
          c.movement != null && !_isMovementFullyDone(c.movement!));

      if (hasActiveMovement) {
        setState(() {});
        return;
      }

      setState(() {});
      _timer?.cancel();
      _silentReloadAndRestart();
    });
  }

  bool _isMovementFullyDone(LordMovement m) {
    if (!m.isArrived) return false;
    if (m.type == 1 && m.isStationed) return false;
    return true;
  }

  Future<void> _silentReloadAndRestart() async {
    if (_staleReloadAttempts >= _maxStaleReloadAttempts) return;
    _staleReloadAttempts++;

    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;

    await _loadCommanders(silent: true);
    if (!mounted) return;

    final stillStale = _commanders.any((c) =>
        c.movement != null && _isMovementFullyDone(c.movement!));
    if (!stillStale) {
      _staleReloadAttempts = 0;
    }
  }

  /// ✅ الحركة قابلة للاسترجاع بـ mcm بس لو:
  /// - MID > 0
  /// - مش return (type 2)
  /// - type 0 (هجوم/transfer) أو type 1 لسه ما وصلش (مش stationed)
  bool _isRecallable(CommanderInfo c) {
    final m = c.movement;
    if (m == null) return false;
    if (m.movementId <= 0) return false;
    if (m.isReturning) return false;
    if (m.type == 1 && m.isStationed) return false; // stationed → لازم من اللعبة
    if (m.type != 0 && m.type != 1) return false;
    return true;
  }

  /// ✅ الحركة stationed support — قابلة للسحب من اللعبة فقط
  bool _isStationedNonRecallable(CommanderInfo c) {
    final m = c.movement;
    if (m == null) return false;
    return m.type == 1 && m.isStationed && !m.isReturning;
  }

  Future<void> _recall(CommanderInfo cmd) async {
    final m = cmd.movement;
    if (m == null) return;

    if (_isStationedNonRecallable(cmd)) {
      _snack(
        S.isAr
            ? 'القائد متمركز في قلعة الحليف — لازم ترجعه من جوّه اللعبة'
            : 'Commander is stationed — recall from in-game only',
        color: AppTheme.orange,
      );
      return;
    }

    if (!_isRecallable(cmd)) {
      _snack(
        S.isAr
            ? 'الحركة دي مش قابلة للاسترجاع (${m.actionLabel})'
            : 'This movement cannot be recalled (${m.actionLabel})',
        color: AppTheme.orange,
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(S.recall,
            style: const TextStyle(decoration: TextDecoration.none)),
        content: Text('${S.recall} ${cmd.lord.displayName}?',
            style: const TextStyle(decoration: TextDecoration.none)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(S.cancel)),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
              child: Text(S.recall,
                  style: const TextStyle(color: Colors.white))),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _loading = true);
    final res = await widget.client.recallMovement(m.movementId);
    if (!mounted) return;

    if (res.success) {
      _snack('✓ ${S.recallSuccess}', color: AppTheme.green);
      await _loadCommanders();
    } else {
      setState(() => _loading = false);
      _snack('${S.recallFail}: ${res.error}', color: AppTheme.red);
    }
  }

  List<CommanderInfo> _recallableList({required String scope}) {
    final list = <CommanderInfo>[];
    for (final c in _commanders) {
      if (!_isRecallable(c)) continue;
      final t = c.movement!.type;
      if (scope == 'all') {
        if (t == 0 || t == 1) list.add(c);
      } else if (scope == 'smuggle') {
        if (t == 1) list.add(c);
      } else if (scope == 'attack') {
        if (t == 0) list.add(c);
      }
    }
    return list;
  }

  Future<void> _bulkRecall({required String scope}) async {
    if (_bulkRunning) return;

    final targets = _recallableList(scope: scope);
    if (targets.isEmpty) {
      _snack(
        S.isAr
            ? 'مفيش حركات قابلة للاسترجاع في النطاق ده'
            : 'Nothing recallable in this scope',
        color: AppTheme.orange,
      );
      return;
    }

    final label = switch (scope) {
      'all' => S.isAr ? 'كل الحركات' : 'all movements',
      'smuggle' => S.isAr ? 'حركات التهريب' : 'smuggle movements',
      'attack' => S.isAr ? 'حركات الهجوم' : 'attack movements',
      _ => '',
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(S.isAr ? 'تأكيد الاسترجاع الجماعي' : 'Confirm bulk recall',
            style: const TextStyle(decoration: TextDecoration.none)),
        content: Text(
          S.isAr
              ? 'هيتم استرجاع ${targets.length} من $label — يكمل؟\n\n'
                  'ملاحظة: الحركات المتمركزة (stationed) مش بتترجع من التطبيق.'
              : 'Recall ${targets.length} of $label?\n\n'
                  'Note: Stationed movements cannot be recalled from the app.',
          style: const TextStyle(decoration: TextDecoration.none, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(S.cancel)),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
              child: Text(
                  S.isAr ? 'استرجاع الكل' : 'Recall all',
                  style: const TextStyle(color: Colors.white))),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _bulkRunning = true;
      _bulkDone = 0;
      _bulkTotal = targets.length;
      _bulkScope = label;
    });

    int success = 0;
    int failed = 0;

    for (int i = 0; i < targets.length; i++) {
      if (!mounted || !_bulkRunning) break;
      final c = targets[i];
      final res = await widget.client.recallMovement(c.movement!.movementId);
      if (res.success) {
        success++;
      } else {
        failed++;
      }
      if (mounted) {
        setState(() => _bulkDone = i + 1);
      }
      if (i < targets.length - 1) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    if (!mounted) return;
    setState(() {
      _bulkRunning = false;
      _bulkDone = 0;
      _bulkTotal = 0;
      _bulkScope = '';
    });

    _snack(
      S.isAr
          ? '✓ نجح: $success · فشل: $failed'
          : '✓ Success: $success · Failed: $failed',
      color: failed == 0 ? AppTheme.green : AppTheme.orange,
    );

    await _loadCommanders();
  }

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content:
            Text(msg, style: const TextStyle(decoration: TextDecoration.none)),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  void dispose() {
    _timer?.cancel();
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
                _bulkRecallBar(context),
                Expanded(
                  child: _loading
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const CircularProgressIndicator(
                                  color: AppTheme.purple),
                              const SizedBox(height: 16),
                              Text(
                                'Loading commanders...',
                                style: TextStyle(
                                    color: AppTheme.subTextColor(context),
                                    fontSize: 12,
                                    decoration: TextDecoration.none),
                              ),
                            ],
                          ),
                        )
                      : _commanders.isEmpty
                          ? _empty(context)
                          : RefreshIndicator(
                              onRefresh: () => _loadCommanders(),
                              color: AppTheme.purple,
                              child: ListView.builder(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 8, 16, 24),
                                itemCount: _commanders.length,
                                itemBuilder: (_, i) => FadeSlideIn(
                                  delay:
                                      Duration(milliseconds: 100 + i * 60),
                                  child:
                                      _commanderCard(context, _commanders[i]),
                                ),
                              ),
                            ),
                ),
              ],
            ),
          ),
          if (_bulkRunning)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.purple.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.purple),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            S.isAr
                                ? 'جاري استرجاع $_bulkScope ($_bulkDone/$_bulkTotal)'
                                : 'Recalling $_bulkScope ($_bulkDone/$_bulkTotal)',
                            style: TextStyle(
                              color: AppTheme.textColor(context),
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _bulkRunning = false),
                          child: Text(
                            S.cancel,
                            style: const TextStyle(
                                color: AppTheme.red, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _bulkTotal > 0 ? _bulkDone / _bulkTotal : null,
                      minHeight: 4,
                      backgroundColor: AppTheme.purple.withOpacity(0.15),
                      valueColor: const AlwaysStoppedAnimation(AppTheme.purple),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final busyCount = _commanders.where((c) => c.isBusy).length;
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
                  S.commanders,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textColor(context),
                    letterSpacing: -0.3,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  '$busyCount / ${_commanders.length} ${S.commanderBusy}',
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
            icon: Icons.refresh_rounded,
            onTap: _loading || _bulkRunning ? null : () => _loadCommanders(),
            size: 42,
          ),
        ],
      ),
    );
  }

  Widget _bulkRecallBar(BuildContext context) {
    final attackList = _recallableList(scope: 'attack');
    final smuggleList = _recallableList(scope: 'smuggle');
    final allList = _recallableList(scope: 'all');

    if (allList.isEmpty && !_bulkRunning) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: _bulkBtn(
              context,
              label: S.isAr ? 'استرجاع الكل' : 'Recall All',
              count: allList.length,
              color: AppTheme.red,
              onTap: _bulkRunning ? null : () => _bulkRecall(scope: 'all'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _bulkBtn(
              context,
              label: S.isAr ? 'تهريب فقط' : 'Smuggle only',
              count: smuggleList.length,
              color: AppTheme.orange,
              onTap: _bulkRunning
                  ? null
                  : () => _bulkRecall(scope: 'smuggle'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _bulkBtn(
              context,
              label: S.isAr ? 'هجوم فقط' : 'Attack only',
              count: attackList.length,
              color: AppTheme.blue,
              onTap: _bulkRunning ? null : () => _bulkRecall(scope: 'attack'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bulkBtn(
    BuildContext context, {
    required String label,
    required int count,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final disabled = count == 0 || onTap == null;
    return InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: disabled
              ? AppTheme.subTextColor(context).withOpacity(0.06)
              : color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: disabled
                ? AppTheme.subTextColor(context).withOpacity(0.15)
                : color.withOpacity(0.4),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: disabled ? AppTheme.subTextColor(context) : color,
                fontSize: 10.5,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: disabled
                    ? Colors.transparent
                    : color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: disabled
                      ? AppTheme.subTextColor(context)
                      : color,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.purple.withOpacity(0.12),
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.purple.withOpacity(0.3)),
            ),
            child: Icon(Icons.people_outline_rounded,
                size: 56, color: AppTheme.purple.withOpacity(0.7)),
          ),
          const SizedBox(height: 16),
          Text(
            S.noCommanders,
            style: TextStyle(
              color: AppTheme.subTextColor(context),
              fontSize: 14,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  Widget _commanderCard(BuildContext context, CommanderInfo cmd) {
    final movement = cmd.movement;
    final isBusy = cmd.isBusy;
    final isStationed = movement?.isStationed ?? false;
    final isReturning = movement?.isReturning ?? false;
    final accent = isBusy ? AppTheme.orange : AppTheme.green;
    final gradient =
        isBusy ? AppTheme.orangeGradient : AppTheme.successGradient;
    final canRecall = _isRecallable(cmd);
    final stationedOnly = _isStationedNonRecallable(cmd);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surface
            .withOpacity(AppTheme.isDark(context) ? 0.6 : 0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.25), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.12),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: gradient,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withOpacity(0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      '${cmd.lord.visibleIndex + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cmd.lord.displayName,
                        style: TextStyle(
                          color: AppTheme.textColor(context),
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: accent.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: accent.withOpacity(0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              isBusy ? S.commanderBusy : S.commanderFree,
                              style: TextStyle(
                                color: accent,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (isBusy && movement != null) ...[
            Container(
              margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.isDark(context)
                    ? Colors.white.withOpacity(0.04)
                    : Colors.black.withOpacity(0.03),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: accent.withOpacity(0.15)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: accent.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          isStationed
                              ? Icons.flag_rounded
                              : (isReturning
                                  ? Icons.undo_rounded
                                  : movement.type == 1
                                      ? Icons.shield_rounded
                                      : Icons.gavel_rounded),
                          color: accent,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          isStationed
                              ? (S.isAr
                                  ? 'متمركز في قلعة الحليف'
                                  : 'Stationed at ally')
                              : movement.actionLabel,
                          style: TextStyle(
                            color: AppTheme.textColor(context),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.place_rounded,
                          color: AppTheme.blue, size: 14),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${movement.targetPlayerName ?? "Unknown"} '
                          '(${movement.targetX}, ${movement.targetY})',
                          style: TextStyle(
                            color: AppTheme.subTextColor(context),
                            fontSize: 11.5,
                            decoration: TextDecoration.none,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.play_arrow_rounded,
                          size: 12, color: AppTheme.blue),
                      const SizedBox(width: 4),
                      Text(
                        '${S.isAr ? "بدأ" : "Started"}: ${movement.startedAtLabel}',
                        style: TextStyle(
                            color: AppTheme.subTextColor(context),
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            decoration: TextDecoration.none),
                      ),
                      const Spacer(),
                      Icon(
                        movement.isArrived
                            ? Icons.check_circle_rounded
                            : Icons.flag_rounded,
                        size: 12,
                        color: movement.isArrived
                            ? AppTheme.green
                            : AppTheme.orange,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isStationed
                            ? '${S.isAr ? "يعود" : "Returns"}: ${movement.stationReturnAtLabel ?? "..."}'
                            : (movement.isArrived
                                ? (S.isAr ? 'وصل' : 'Arrived')
                                : '${S.isAr ? "هيوصل" : "Arrives"}: ${movement.arrivalAtLabel}'),
                        style: TextStyle(
                            color: movement.isArrived
                                ? AppTheme.green
                                : AppTheme.orange,
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            decoration: TextDecoration.none),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.timer_rounded,
                          color: AppTheme.orange, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        isStationed
                            ? (S.isAr
                                ? 'الوقت المتبقي في الدعم'
                                : 'Station time remaining')
                            : S.timeRemaining,
                        style: TextStyle(
                          color: AppTheme.subTextColor(context),
                          fontSize: 11.5,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.blue.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          movement.timeLabel,
                          style: const TextStyle(
                            color: AppTheme.blue,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (canRecall)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: OutlinedButton.icon(
                    onPressed: _bulkRunning ? null : () => _recall(cmd),
                    icon: const Icon(Icons.undo_rounded,
                        color: AppTheme.red, size: 18),
                    label: Text(S.recall,
                        style: const TextStyle(
                            color: AppTheme.red,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.none)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                          color: AppTheme.red.withOpacity(0.5), width: 1.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      backgroundColor: AppTheme.red.withOpacity(0.08),
                    ),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        color: stationedOnly
                            ? AppTheme.orange
                            : AppTheme.subTextColor(context),
                        size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        stationedOnly
                            ? (S.isAr
                                ? 'القائد متمركز — لازم ترجعه من جوّه اللعبة'
                                : 'Commander stationed — recall from in-game')
                            : (isReturning
                                ? (S.isAr
                                    ? 'القائد في طريق العودة — لا يحتاج استرجاع'
                                    : 'Returning — no recall needed')
                                : (S.isAr
                                    ? 'هذا النوع من الحركات لا يمكن استرجاعه'
                                    : 'This movement type cannot be recalled')),
                        style: TextStyle(
                            color: stationedOnly
                                ? AppTheme.orange
                                : AppTheme.subTextColor(context),
                            fontSize: 10.5,
                            decoration: TextDecoration.none),
                      ),
                    ),
                  ],
                ),
              ),
          ] else
            const SizedBox(height: 14),
        ],
      ),
    );
  }
}