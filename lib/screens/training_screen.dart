import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

// ═══════════════════════════════════════════════════════════
//  TrainingSlots — parsed from `spl` response
//  Each slot in QS has SI.RUT:
//    -1 = locked · 0 = free · >0 = busy (remaining seconds)
// ═══════════════════════════════════════════════════════════
class TrainingSlots {
  final int barracksFree;
  final int barracksBusy;
  final DateTime fetchedAt;

  TrainingSlots({
    required this.barracksFree,
    required this.barracksBusy,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  int get barracksTotal => barracksFree + barracksBusy;
  bool get hasBarracks => barracksTotal > 0;
  bool get isAllBusy => barracksTotal > 0 && barracksFree == 0;

  /// Defensive parser — tries multiple shapes for the `spl` response.
  factory TrainingSlots.fromSpl(Map<String, dynamic> data) {
    // Possible locations for the QS array
    dynamic qs = data['QS'];
    qs ??= (data['A'] is Map) ? (data['A'] as Map)['QS'] : null;
    qs ??= data['S'];

    if (qs is! List) {
      return TrainingSlots(barracksFree: 0, barracksBusy: 0);
    }

    int free = 0, busy = 0;
    for (final q in qs) {
      if (q is! Map) continue;
      // RUT can be in SI.RUT or directly in q['RUT']
      final si = q['SI'];
      final rut = (si is Map ? si['RUT'] : null) ?? q['RUT'];
      if (rut is num) {
        final r = rut.toInt();
        if (r == -1) continue; // locked slot
        if (r == 0) {
          free++;
        } else {
          busy++;
        }
      }
    }
    return TrainingSlots(barracksFree: free, barracksBusy: busy);
  }
}

// ═══════════════════════════════════════════════════════════
class TrainingScreen extends StatefulWidget {
  final GgeClient client;
  const TrainingScreen({super.key, required this.client});

  @override
  State<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<TrainingScreen> {
  List<OwnedCastle> _castles = [];
  Map<int, UnitCatalogEntry> _catalog = {};
  OwnedCastle? _castle;

  List<UnitCatalogEntry> _trainable = [];
  UnitCatalogEntry? _selectedUnit;
  final _amountCtrl = TextEditingController(text: '10');
  bool _training = false;

  /// 'basic' | 'advanced' | 'elite' | 'all'
  String _tierFilter = 'basic';
  static const int _maxPerBatch = 80;

  // ═══ Training slots state ═══
  TrainingSlots? _slots;
  bool _slotsLoading = false;
  DateTime? _lastSlotFetch;
  Timer? _slotsTimer;

  @override
  void initState() {
    super.initState();
    _loadAll();
    // ═══ Auto-refresh every 60s (safe per anti-ban rules) ═══
    _slotsTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _loadSlots(silent: true);
    });
  }

  @override
  void dispose() {
    _slotsTimer?.cancel();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    try {
      final castles = await widget.client.getCastles();
      final catalog = await widget.client.loadCatalog();
      if (!mounted) return;

      // Only Main Castle + Outpost can train
      final trainableCastles =
          castles.where((c) => c.areaType == 1 || c.areaType == 4).toList();

      setState(() {
        _castles = trainableCastles;
        _catalog = catalog;
        if (trainableCastles.isEmpty) {
          _castle = null;
        } else {
          _castle = trainableCastles.firstWhere(
            (c) => c.areaType == 1,
            orElse: () => trainableCastles.first,
          );
        }
        _trainable = catalog.values
            .where((e) => e.isTrainable)
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
        _selectedUnit = _filteredTrainable.isNotEmpty
            ? _filteredTrainable.first
            : null;
      });

      if (_castle != null) {
        unawaited(_loadSlots(force: true));
      }
    } catch (e) {
      _snack('$e', color: AppTheme.red);
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  Fetch training slots via `spl` (safe, read-only)
  // ═══════════════════════════════════════════════════════════
  Future<void> _loadSlots({bool silent = false, bool force = false}) async {
    if (_slotsLoading && !force) return;

    // Throttle: min 30s between fetches unless forced
    if (!force && _lastSlotFetch != null) {
      final diff = DateTime.now().difference(_lastSlotFetch!).inSeconds;
      if (diff < 30) return;
    }
    _lastSlotFetch = DateTime.now();

    if (!silent && mounted) {
      setState(() => _slotsLoading = true);
    }

    try {
      final resp = await widget.client.sendXtAndWait(
        'spl',
        jsonEncode({'LID': 0}),
        responseCmd: 'spl',
        timeoutMs: 8000,
        isAction: false,
      );

      if (!mounted) return;

      if (resp.payload == null || resp.payload!.isEmpty) {
        TrafficLog.add('ST', '[Slots] spl returned no payload');
        if (mounted) setState(() => _slotsLoading = false);
        return;
      }

      // Log raw for debugging (helps if response shape differs)
      TrafficLog.add('ST', '[Slots] spl RX: ${resp.payload}');

      final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
      final slots = TrainingSlots.fromSpl(data);
      if (!mounted) return;
      setState(() {
        _slots = slots;
        _slotsLoading = false;
      });
    } catch (e) {
      TrafficLog.add('ER', '[Slots] spl error: $e');
      if (mounted) setState(() => _slotsLoading = false);
    }
  }

  /// Detect tier from unit display name
  String _getUnitTier(UnitCatalogEntry u) {
    final name = u.displayName.toLowerCase();
    if (name.contains('veteran') ||
        name.contains('elite') ||
        name.contains('twohand') ||
        name.contains('knight') ||
        name.contains('cavalry')) {
      return 'elite';
    }
    if (name.contains('heavy') ||
        name.contains('halberd') ||
        name.contains('crossbow') ||
        name.contains('mace') ||
        name.contains('longbow')) {
      return 'advanced';
    }
    return 'basic';
  }

  List<UnitCatalogEntry> get _filteredTrainable {
    if (_tierFilter == 'all') return _trainable;
    return _trainable.where((u) => _getUnitTier(u) == _tierFilter).toList();
  }

  void _setTier(String tier) {
    setState(() {
      _tierFilter = tier;
      final filtered = _filteredTrainable;
      if (filtered.isEmpty) {
        _selectedUnit = null;
      } else {
        final stillVisible = filtered.any(
            (u) => u.wodId == (_selectedUnit?.wodId ?? -1));
        if (!stillVisible) _selectedUnit = filtered.first;
      }
    });
  }

  Future<void> _train() async {
    if (_castle == null || _selectedUnit == null) return;
    final amt = int.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amt <= 0) {
      _snack(S.error, color: AppTheme.red);
      return;
    }
    if (amt > _maxPerBatch) {
      _snack(
        S.isAr
            ? 'الحد الأقصى $_maxPerBatch في المرة الواحدة'
            : 'Max $_maxPerBatch per batch',
        color: AppTheme.orange,
      );
      return;
    }

    setState(() => _training = true);
    final result = await widget.client.trainUnits(
      areaId: _castle!.areaId,
      wodId: _selectedUnit!.wodId,
      amount: amt,
    );
    if (!mounted) return;
    setState(() => _training = false);

    if (result.success) {
      _snack('✓ ${S.trainingOk}', color: AppTheme.green);
      HapticFeedback.mediumImpact();
      // Refresh slots after training (server registers busy slot)
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) await _loadSlots(force: true);
    } else {
      _snack('${S.trainingFail}: ${result.error}', color: AppTheme.red);
    }
  }

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg,
            style: const TextStyle(decoration: TextDecoration.none)),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ));
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
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    children: [
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 100),
                        child: _castlePicker(context),
                      ),
                      const SizedBox(height: 14),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 160),
                        child: _slotsCard(context),
                      ),
                      const SizedBox(height: 14),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 220),
                        child: _tierFilterRow(context),
                      ),
                      const SizedBox(height: 14),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 280),
                        child: _unitPicker(context),
                      ),
                      const SizedBox(height: 14),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 340),
                        child: _amountInput(context),
                      ),
                      const SizedBox(height: 14),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 400),
                        child: _unitPreview(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: FadeSlideIn(
              delay: const Duration(milliseconds: 500),
              offset: const Offset(0, 0.2),
              child: GradientButton(
                label: S.startTraining,
                icon: Icons.play_arrow_rounded,
                gradient: AppTheme.successGradient,
                loading: _training,
                onPressed: _selectedUnit != null ? _train : null,
              ),
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
                  S.trainTroops,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textColor(context),
                    letterSpacing: -0.3,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  S.trainDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subTextColor(context),
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: AppTheme.successGradient,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.green.withOpacity(0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(Icons.military_tech_rounded,
                color: Colors.white, size: 22),
          ),
        ],
      ),
    );
  }

  Widget _castlePicker(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.blue.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.blue.withOpacity(0.3)),
            ),
            child: const Icon(Icons.castle_rounded,
                color: AppTheme.blue, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.selectCastle,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.subTextColor(context),
                    letterSpacing: 0.8,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 2),
                if (_castles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      S.isAr
                          ? 'لا توجد قلاع قابلة للتدريب'
                          : 'No trainable castles',
                      style: TextStyle(
                          color: AppTheme.subTextColor(context),
                          fontSize: 12,
                          decoration: TextDecoration.none),
                    ),
                  )
                else
                  DropdownButtonHideUnderline(
                    child: DropdownButton<OwnedCastle>(
                      value: _castle,
                      isExpanded: true,
                      isDense: true,
                      dropdownColor: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textColor(context),
                      ),
                      items: _castles
                          .map((c) => DropdownMenuItem(
                                value: c,
                                child: Text(c.fullLabel,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: AppTheme.textColor(context),
                                        fontSize: 13)),
                              ))
                          .toList(),
                      onChanged: (v) {
                        setState(() {
                          _castle = v;
                          _slots = null;
                          final filtered = _filteredTrainable;
                          _selectedUnit =
                              filtered.isNotEmpty ? filtered.first : null;
                        });
                        if (v != null) {
                          unawaited(_loadSlots(force: true));
                        }
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

  // ═══════════════════════════════════════════════════════════
  //  Slots card
  // ═══════════════════════════════════════════════════════════
  Widget _slotsCard(BuildContext context) {
    final slots = _slots;
    final loading = _slotsLoading;

    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppTheme.purple.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.meeting_room_rounded,
                    color: AppTheme.purple, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  S.isAr ? 'خانات التدريب' : 'Training slots',
                  style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.purple,
                  ),
                )
              else
                GestureDetector(
                  onTap: () => _loadSlots(force: true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: slots != null
                          ? (slots.isAllBusy
                              ? AppTheme.red.withOpacity(0.15)
                              : AppTheme.teal.withOpacity(0.15))
                          : AppTheme.subTextColor(context).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      slots != null
                          ? '${slots.barracksFree}/${slots.barracksTotal}'
                          : '--',
                      style: TextStyle(
                        color: slots != null
                            ? (slots.isAllBusy ? AppTheme.red : AppTheme.teal)
                            : AppTheme.subTextColor(context),
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (slots != null && slots.hasBarracks) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List.generate(slots.barracksTotal, (i) {
                final isFree = i < slots.barracksFree;
                return Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isFree
                        ? AppTheme.green.withOpacity(0.15)
                        : AppTheme.red.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isFree
                          ? AppTheme.green.withOpacity(0.5)
                          : AppTheme.red.withOpacity(0.5),
                      width: 1.4,
                    ),
                  ),
                  child: Icon(
                    isFree
                        ? Icons.check_circle_outline_rounded
                        : Icons.lock_clock_rounded,
                    color: isFree ? AppTheme.green : AppTheme.red,
                    size: 20,
                  ),
                );
              }),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _slotStat(context,
                    label: S.isAr ? 'فاضي' : 'Free',
                    value: slots.barracksFree,
                    color: AppTheme.green),
                const SizedBox(width: 8),
                _slotStat(context,
                    label: S.isAr ? 'مشغول' : 'Busy',
                    value: slots.barracksBusy,
                    color: AppTheme.red),
                const Spacer(),
                Icon(Icons.sync_rounded,
                    size: 12, color: AppTheme.subTextColor(context)),
                const SizedBox(width: 4),
                Text(
                  S.isAr ? 'كل دقيقة' : 'Every 60s',
                  style: TextStyle(
                    color: AppTheme.subTextColor(context),
                    fontSize: 9,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
            if (slots.isAllBusy) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: AppTheme.orange.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        color: AppTheme.orange, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        S.isAr
                            ? 'كل الخانات مشغولة — استنى تفضى أو استخدم VIP'
                            : 'All slots busy — wait or use VIP',
                        style: const TextStyle(
                            color: AppTheme.orange,
                            fontSize: 11,
                            decoration: TextDecoration.none),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ] else if (slots != null) ...[
            const SizedBox(height: 8),
            Text(
              S.isAr
                  ? 'مفيش باراكس في القلعة دي'
                  : 'No barracks in this castle',
              style: TextStyle(
                color: AppTheme.subTextColor(context),
                fontSize: 11,
                decoration: TextDecoration.none,
              ),
            ),
          ] else if (!loading) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    S.isAr
                        ? 'اضغط تحديث لعرض الخانات'
                        : 'Tap to load slots',
                    style: TextStyle(
                      color: AppTheme.subTextColor(context),
                      fontSize: 11,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _loadSlots(force: true),
                  icon: const Icon(Icons.refresh_rounded,
                      color: AppTheme.purple, size: 14),
                  label: Text(
                    S.isAr ? 'تحديث' : 'Refresh',
                    style: const TextStyle(
                      color: AppTheme.purple,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _slotStat(BuildContext context,
      {required String label, required int value, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            '$value $label',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tierFilterRow(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppTheme.purple.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.filter_alt_rounded,
                    color: AppTheme.purple, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  S.isAr ? 'مستوى الجنود' : 'Unit tier',
                  style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              Text(
                '${_filteredTrainable.length} ${S.isAr ? "متاح" : "available"}',
                style: TextStyle(
                    color: AppTheme.subTextColor(context),
                    fontSize: 10.5,
                    decoration: TextDecoration.none),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _tierChip(context, 'basic',
                  S.isAr ? 'أساسي' : 'Basic', AppTheme.teal),
              _tierChip(context, 'advanced',
                  S.isAr ? 'متقدم' : 'Advanced', AppTheme.orange),
              _tierChip(context, 'elite',
                  S.isAr ? 'نخبة' : 'Elite', AppTheme.red),
              _tierChip(context, 'all', S.isAr ? 'الكل' : 'All',
                  AppTheme.purple),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tierChip(
      BuildContext context, String key, String label, Color color) {
    final sel = _tierFilter == key;
    return GestureDetector(
      onTap: () => _setTier(key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: sel
              ? color.withOpacity(0.2)
              : Theme.of(context).colorScheme.surface.withOpacity(0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: sel
                ? color.withOpacity(0.6)
                : AppTheme.subTextColor(context).withOpacity(0.15),
            width: sel ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? color : AppTheme.subTextColor(context),
            fontSize: 11,
            fontWeight: sel ? FontWeight.bold : FontWeight.w500,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  Widget _unitPicker(BuildContext context) {
    final filtered = _filteredTrainable;

    if (filtered.isEmpty) {
      return AppTheme.glassCard(
        context: context,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Icon(Icons.inbox_rounded,
                  color: AppTheme.subTextColor(context), size: 32),
              const SizedBox(height: 8),
              Text(
                S.isAr
                    ? 'مفيش وحدات في المستوى ده'
                    : 'No units at this tier',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.subTextColor(context),
                    fontSize: 12,
                    decoration: TextDecoration.none),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () => _setTier('all'),
                icon: const Icon(Icons.refresh_rounded,
                    color: AppTheme.purple, size: 16),
                label: Text(
                  S.isAr ? 'اعرض كل الوحدات' : 'Show all units',
                  style: const TextStyle(
                      color: AppTheme.purple,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.none),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.teal.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.teal.withOpacity(0.3)),
            ),
            child: const Icon(Icons.gavel_rounded,
                color: AppTheme.teal, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.unitType,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.subTextColor(context),
                    letterSpacing: 0.8,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 2),
                DropdownButtonHideUnderline(
                  child: DropdownButton<UnitCatalogEntry>(
                    value: _selectedUnit,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textColor(context),
                    ),
                    items: filtered.map((u) {
                      return DropdownMenuItem(
                        value: u,
                        child: Row(
                          children: [
                            Icon(
                              u.role == 'ranged'
                                  ? Icons.gps_fixed_rounded
                                  : Icons.gavel_rounded,
                              size: 14,
                              color: u.role == 'ranged'
                                  ? AppTheme.teal
                                  : AppTheme.red,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                S.unitName(u.displayName),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.textColor(context)),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (v) => setState(() => _selectedUnit = v),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _amountInput(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.orange.withOpacity(0.3)),
            ),
            child: const Icon(Icons.numbers_rounded,
                color: AppTheme.orange, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      S.amount,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.subTextColor(context),
                        letterSpacing: 0.8,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '(${S.isAr ? "حد أقصى" : "max"} $_maxPerBatch)',
                      style: TextStyle(
                        fontSize: 9,
                        color:
                            AppTheme.subTextColor(context).withOpacity(0.7),
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _amountCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        style: TextStyle(
                          color: AppTheme.textColor(context),
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.none,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _stepBtn(
                      icon: Icons.keyboard_double_arrow_up_rounded,
                      color: AppTheme.green,
                      tooltip: S.isAr ? '80' : 'Max ($_maxPerBatch)',
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _amountCtrl.text = _maxPerBatch.toString();
                        setState(() {});
                      },
                    ),
                    const SizedBox(width: 6),
                    _stepBtn(
                      icon: Icons.keyboard_double_arrow_down_rounded,
                      color: AppTheme.red,
                      tooltip: S.isAr ? '1' : 'Min',
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _amountCtrl.text = '1';
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepBtn({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withOpacity(0.35)),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
        ),
      ),
    );
  }

  Widget _unitPreview(BuildContext context) {
    if (_selectedUnit == null) return const SizedBox.shrink();
    final u = _selectedUnit!;
    final isRanged = u.role == 'ranged';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: isRanged
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF00B894), Color(0xFF00D68F)],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFEC4899), Color(0xFFFF8E53)],
              ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: (isRanged ? AppTheme.green : AppTheme.pink)
                .withOpacity(0.35),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Icon(
              isRanged ? Icons.gps_fixed_rounded : Icons.gavel_rounded,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.unitName(u.displayName),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  u.isDefensive
                      ? S.defenseOnly
                      : (isRanged ? 'Ranged · Offense' : 'Melee · Offense'),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 11.5,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.22),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Text(
              'x${_amountCtrl.text}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}