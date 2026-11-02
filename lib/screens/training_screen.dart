import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/services/training_service.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';
import 'package:gge/widgets/unit_avatar.dart';
import 'package:gge/screens/unit_catalog_screen.dart';

class TrainingScreen extends StatefulWidget {
  final GgeClient client;
  const TrainingScreen({super.key, required this.client});

  @override
  State<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<TrainingScreen> {
  static const int _barracksMaxLevel = 20;
  static const int _absoluteMaxPerBatch = 80;

  late final TrainingService _svc;
  late AutoTrainSettings _autoSettings;

  bool _isAutoMode = false;
  bool _training = false;
  bool _slotsLoading = false;
  bool _isAutoSending = false;
  bool _initialized = false;

  List<OwnedCastle> _castles = [];
  Map<int, UnitCatalogEntry> _catalog = {};
  OwnedCastle? _castle;

  List<UnitCatalogEntry> _trainable = [];
  UnitCatalogEntry? _selectedUnit;
  final _amountCtrl = TextEditingController(text: '10');
  final _maxTotalCtrl = TextEditingController(text: '1000');

  List<SlotInfo>? _slots;
  int _totalTime = 0;
  DateTime? _lastSlotFetch;

  final Map<int, TextEditingController> _autoAmountCtrls = {};
  final TextEditingController _timeCtrl = TextEditingController(text: '5');

  Timer? _slotsTimer;
  Timer? _tickTimer;
  Timer? _autoTimer;

  DateTime _lastActionTime = DateTime.now();

  int get _maxPerBatch {
    if (_castle == null) return _absoluteMaxPerBatch;
    return _svc.getMaxPerBatch(_castle!.areaId);
  }

  int? get _currentBarracksLevel {
    if (_castle == null) return null;
    return _svc.getBarracksLevel(_castle!.areaId);
  }

  bool get _autoEnabled => _autoSettings.enabled;
  bool get _triggerOnSlot => _autoSettings.triggerOnSlot;
  bool get _triggerOnTime => _autoSettings.triggerOnTime;
  bool get _useMaxTotal => _autoSettings.useMaxTotal;

  @override
  void initState() {
    super.initState();
    _svc = TrainingService(widget.client);
    _autoSettings = AutoTrainSettings();
    _bootstrap();

    _slotsTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted && _initialized) _loadSlots(silent: true);
    });

    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final hasBusy = _slots?.any((s) => s.isBusy) ?? false;
      if (hasBusy || _totalTime > 0) setState(() {});
    });

    _startAutoLoop();
  }

  @override
  void dispose() {
    _slotsTimer?.cancel();
    _tickTimer?.cancel();
    _autoTimer?.cancel();
    _amountCtrl.dispose();
    _maxTotalCtrl.dispose();
    _timeCtrl.dispose();
    for (var c in _autoAmountCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final auto = await AutoTrainSettings.load();
      final castles = await widget.client.getCastles();
      final catalog = await widget.client.loadCatalog();
      if (!mounted) return;

      final trainableCastles = castles
          .where((c) =>
              c.areaType == 1 || c.areaType == 4 || c.areaType == 12)
          .toList();

      OwnedCastle? castle;
      if (trainableCastles.isNotEmpty) {
        castle = trainableCastles.firstWhere(
          (c) => c.areaType == 1,
          orElse: () => trainableCastles.first,
        );
      }

      setState(() {
        _autoSettings = auto;
        _castles = trainableCastles;
        _catalog = catalog;
        _castle = castle;
        _initialized = true;
        _syncAutoControllers();
        _refreshTrainable();
      });

      if (castle != null) {
        await _autoSettings.setTrainArea(castle.areaId);
        await _svc.fetchBarracksLevel(castle);
        if (!mounted) return;
        setState(() {});
        await _loadSlots(force: true);
      }
    } catch (e) {
      _snack('$e', color: AppTheme.red);
    }
  }

  void _syncAutoControllers() {
    _maxTotalCtrl.text = _autoSettings.maxTotal;
    _timeCtrl.text = _autoSettings.timeInterval.toString();
    for (final e in _autoSettings.selectedAmounts.entries) {
      _autoAmountCtrls[e.key]?.dispose();
      _autoAmountCtrls[e.key] =
          TextEditingController(text: e.value.toString());
    }
    final ids = _autoSettings.selectedAmounts.keys.toSet();
    for (final id in _autoAmountCtrls.keys.toList()) {
      if (!ids.contains(id)) {
        _autoAmountCtrls[id]?.dispose();
        _autoAmountCtrls.remove(id);
      }
    }
  }

  void _refreshTrainable() {
    if (_castle == null) {
      _trainable = [];
      _selectedUnit = null;
      return;
    }
    _trainable =
        _svc.getTrainableUnits(castle: _castle!, catalog: _catalog);
    if (_selectedUnit != null &&
        !_trainable.any((u) => u.wodId == _selectedUnit!.wodId)) {
      _selectedUnit = _trainable.isNotEmpty ? _trainable.first : null;
    } else if (_selectedUnit == null && _trainable.isNotEmpty) {
      _selectedUnit = _trainable.first;
    }
  }

  Future<void> _loadSlots({bool silent = false, bool force = false}) async {
    if (_slotsLoading && !force) return;
    if (!force && _lastSlotFetch != null) {
      final diff = DateTime.now().difference(_lastSlotFetch!).inSeconds;
      if (diff < 30) return;
    }
    _lastSlotFetch = DateTime.now();
    if (!silent && mounted) setState(() => _slotsLoading = true);

    final resp = await _svc.loadSlots();
    if (!mounted) return;

    if (resp == null) {
      setState(() => _slotsLoading = false);
      return;
    }

    setState(() {
      _slots = resp.slots;
      _totalTime = resp.totalTime;
      _slotsLoading = false;
    });
  }

  Future<void> _onCastleChanged(OwnedCastle v) async {
    setState(() {
      _castle = v;
      _slots = null;
      _selectedUnit = null;
      _autoSettings.rotationIndex = 0;
    });

    await _autoSettings.setTrainArea(v.areaId);
    await _svc.fetchBarracksLevel(v);
    if (!mounted) return;

    setState(() => _refreshTrainable());

    final amt = int.tryParse(_amountCtrl.text) ?? 10;
    if (amt > _maxPerBatch) _amountCtrl.text = _maxPerBatch.toString();

    await _loadSlots(force: true);
  }

  Future<void> _trainManual() async {
    if (_castle == null || _selectedUnit == null) return;
    final amt = int.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amt <= 0) {
      _snack(S.error, color: AppTheme.red);
      return;
    }
    if (amt > _maxPerBatch) {
      _snack(
          S.isAr
              ? 'الحد الأقصى ${_maxPerBatch} بناءً على مستوى الثكنات'
              : 'Max $_maxPerBatch for barracks level',
          color: AppTheme.orange);
      return;
    }

    setState(() => _training = true);
    await _throttle();
    final result = await _svc.train(
      areaId: _castle!.areaId,
      wodId: _selectedUnit!.wodId,
      amount: amt,
    );

    if (!mounted) return;
    setState(() => _training = false);

    if (result.success) {
      _snack('✓ ${S.trainingOk}', color: AppTheme.green);
      HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) await _loadSlots(force: true);
    } else {
      _snack('${S.trainingFail}: ${result.error}', color: AppTheme.red);
    }
  }

  void _startAutoLoop() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!mounted || !_isAutoMode || !_autoEnabled || _isAutoSending) return;
      if (_castle == null || _autoSettings.selectedAmounts.isEmpty) return;

      if (_useMaxTotal) {
        final max = int.tryParse(_autoSettings.maxTotal) ?? 0;
        if (_autoSettings.totalTrained >= max) {
          setState(() => _autoSettings.enabled = false);
          await _autoSettings.save();
          _snack('تم الوصول للحد الأقصى', color: AppTheme.orange);
          return;
        }
      }

      bool shouldTrain = false;
      if (_triggerOnSlot && (_slots?.any((s) => s.isFree) ?? false)) {
        shouldTrain = true;
      }
      if (!shouldTrain && await _autoSettings.isTimeTriggered()) {
        shouldTrain = true;
      }
      if (!shouldTrain) return;

      await _executeAuto();
    });
  }

  Future<void> _executeAuto() async {
    _isAutoSending = true;
    try {
      await _throttle();
      final result = await _svc.executeAutoTrain(
        castle: _castle!,
        settings: _autoSettings,
        catalog: _catalog,
      );

      if (result.success) {
        await _autoSettings.saveRotation(
          result.nextIndex!,
          _autoSettings.totalTrained + result.amount!,
        );
        await _autoSettings.markTrainTime();
        if (mounted) setState(() {});
        TrafficLog.add('ST',
            '[AutoTrain] ✅ WID=${result.wodId} AMT=${result.amount}');
        await _loadSlots(force: true);
      } else if (result.skipped) {
        TrafficLog.add('ST', '[AutoTrain] ⏭ ${result.error}');
      } else {
        TrafficLog.add('ER', '[AutoTrain] ❌ ${result.error}');
        await _autoSettings.markTrainTime();
      }
    } finally {
      await Future.delayed(const Duration(seconds: 3));
      _isAutoSending = false;
    }
  }

  Future<void> _throttle() async {
    final now = DateTime.now();
    final diff = now.difference(_lastActionTime).inMilliseconds;
    if (diff < 5500) {
      final wait = 5500 - diff + Random().nextInt(1500);
      await Future.delayed(Duration(milliseconds: wait));
    } else {
      await Future.delayed(Duration(milliseconds: Random().nextInt(1000)));
    }
    _lastActionTime = DateTime.now();
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
                  child: !_initialized
                      ? const Center(
                          child: CircularProgressIndicator(
                              color: AppTheme.purple))
                      : ListView(
                          padding:
                              const EdgeInsets.fromLTRB(16, 8, 16, 100),
                          children: [
                            FadeSlideIn(
                                delay:
                                    const Duration(milliseconds: 100),
                                child: _castlePicker(context)),
                            const SizedBox(height: 14),
                            FadeSlideIn(
                                delay:
                                    const Duration(milliseconds: 160),
                                child: _slotsCard(context)),
                            const SizedBox(height: 14),
                            FadeSlideIn(
                                delay:
                                    const Duration(milliseconds: 200),
                                child: _modeToggle(context)),
                            const SizedBox(height: 14),
                            if (!_isAutoMode) ...[
                              FadeSlideIn(
                                  delay: const Duration(milliseconds: 280),
                                  child: _unitPickerManual(context)),
                              const SizedBox(height: 14),
                              FadeSlideIn(
                                  delay: const Duration(milliseconds: 340),
                                  child: _amountInputManual(context)),
                              const SizedBox(height: 14),
                              FadeSlideIn(
                                  delay: const Duration(milliseconds: 400),
                                  child: _unitPreviewManual(context)),
                            ] else ...[
                              FadeSlideIn(
                                  delay: const Duration(milliseconds: 280),
                                  child: _autoTrainPanel(context)),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
          if (!_isAutoMode && _initialized)
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
                  onPressed:
                      _selectedUnit != null ? _trainManual : null,
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
              size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.trainTroops,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textColor(context),
                        letterSpacing: -0.3,
                        decoration: TextDecoration.none)),
                Text(S.trainDesc,
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subTextColor(context),
                        decoration: TextDecoration.none)),
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
                      offset: const Offset(0, 6))
                ]),
            child: const Icon(Icons.military_tech_rounded,
                color: Colors.white, size: 22),
          ),
        ],
      ),
    );
  }

  Widget _castlePicker(BuildContext context) {
    final lvl = _currentBarracksLevel;
    final unlockedCount = _trainable.length;

    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                      color: AppTheme.blue.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppTheme.blue.withOpacity(0.3))),
                  child: const Icon(Icons.castle_rounded,
                      color: AppTheme.blue, size: 20)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(S.selectCastle,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.subTextColor(context),
                            letterSpacing: 0.8,
                            decoration: TextDecoration.none)),
                    const SizedBox(height: 2),
                    if (_castles.isEmpty)
                      Text(S.isAr ? 'لا توجد قلاع' : 'No castles',
                          style: TextStyle(
                              color: AppTheme.subTextColor(context),
                              fontSize: 12,
                              decoration: TextDecoration.none))
                    else
                      DropdownButtonHideUnderline(
                        child: DropdownButton<OwnedCastle>(
                          value: _castle,
                          isExpanded: true,
                          isDense: true,
                          dropdownColor:
                              Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(14),
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textColor(context)),
                          items: _castles.map((c) {
                            final l = _svc.getBarracksLevel(c.areaId);
                            final lbl = l != null ? ' · Lv $l' : '';
                            return DropdownMenuItem(
                                value: c,
                                child: Text('${c.fullLabel}$lbl',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color:
                                            AppTheme.textColor(context),
                                        fontSize: 13)));
                          }).toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            unawaited(_onCastleChanged(v));
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _chip(
                context,
                icon: Icons.military_tech_rounded,
                label:
                    lvl != null ? 'الثكنات: Lv $lvl/$_barracksMaxLevel' : 'الثكنات: ?',
                color: lvl != null && lvl >= _barracksMaxLevel
                    ? AppTheme.orange
                    : (lvl != null
                        ? AppTheme.teal
                        : AppTheme.subTextColor(context)),
              ),
              _chip(
                context,
                icon: Icons.groups_rounded,
                label: unlockedCount > 0
                    ? 'وحدات: $unlockedCount'
                    : 'وحدات: غير معروفة',
                color: unlockedCount > 0
                    ? AppTheme.purple
                    : AppTheme.orange,
              ),
              _chip(
                context,
                icon: Icons.format_list_numbered_rounded,
                label: 'Max: $_maxPerBatch',
                color: AppTheme.blue,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _slotsCard(BuildContext context) {
    final slots = _slots;
    final loading = _slotsLoading;

    SlotInfo? mainSlot;
    List<SlotInfo> queue = [];
    if (slots != null && slots.isNotEmpty) {
      final tIdx = slots.indexWhere((s) => s.isTraining);
      if (tIdx >= 0) {
        mainSlot = slots[tIdx];
        queue = slots.where((s) => !s.isTraining).toList();
      } else {
        final fIdx = slots.indexWhere((s) => s.isFree);
        final mIdx = fIdx >= 0 ? fIdx : 0;
        mainSlot = slots[mIdx];
        for (int i = 0; i < slots.length; i++) {
          if (i != mIdx) queue.add(slots[i]);
        }
      }
    }

    final free = slots?.where((s) => s.isFree).length ?? 0;
    final busy = slots?.where((s) => s.isBusy).length ?? 0;
    final locked = slots?.where((s) => s.isLocked).length ?? 0;

    final elapsed = _lastSlotFetch == null
        ? 0
        : DateTime.now().difference(_lastSlotFetch!).inSeconds;
    final liveTotal = (_totalTime - elapsed).clamp(0, 999999);

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
                      borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.meeting_room_rounded,
                      color: AppTheme.purple, size: 18)),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(
                      S.isAr ? 'خانات التدريب' : 'Training slots',
                      style: TextStyle(
                          color: AppTheme.textColor(context),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          decoration: TextDecoration.none))),
              if (loading)
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.purple))
              else
                GestureDetector(
                  onTap: () => _loadSlots(force: true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: AppTheme.teal.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8)),
                    child: const Text('تحديث',
                        style: TextStyle(
                            color: AppTheme.teal,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                            decoration: TextDecoration.none)),
                  ),
                ),
            ],
          ),
          if (slots != null && slots.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _chip(context,
                  icon: Icons.check_circle_outline_rounded,
                  label: S.isAr ? '$free متاحة' : '$free free',
                  color: AppTheme.green),
              _chip(context,
                  icon: Icons.hourglass_top_rounded,
                  label: S.isAr ? '$busy مشغولة' : '$busy busy',
                  color: AppTheme.orange),
              _chip(context,
                  icon: Icons.lock_rounded,
                  label: S.isAr ? '$locked مقفولة' : '$locked locked',
                  color: AppTheme.subTextColor(context)),
            ]),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (mainSlot != null)
                  Expanded(
                      flex: 2,
                      child: _slotBox(context, mainSlot, isMain: true)),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: queue
                        .map((s) => SizedBox(
                              width: (MediaQuery.of(context).size.width -
                                      100) /
                                  5,
                              child: _slotBox(context, s),
                            ))
                        .toList(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: AppTheme.blue.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.timer_rounded,
                      size: 16, color: AppTheme.blue),
                  const SizedBox(width: 6),
                  Text(
                    'الوقت الإجمالي: ${_fmt(liveTotal)}',
                    style: const TextStyle(
                        color: AppTheme.blue,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none),
                  ),
                ],
              ),
            ),
          ] else if (!loading) ...[
            const SizedBox(height: 8),
            Text('جاري تحميل الخانات...',
                style: TextStyle(
                    color: AppTheme.subTextColor(context),
                    fontSize: 11,
                    decoration: TextDecoration.none)),
          ],
        ],
      ),
    );
  }

  Widget _slotBox(BuildContext context, SlotInfo s, {bool isMain = false}) {
    Color c;
    IconData icon;
    String label;

    if (s.isLocked) {
      c = AppTheme.subTextColor(context);
      icon = Icons.lock_rounded;
      label = 'مقفولة';
    } else if (s.isBusy) {
      c = AppTheme.orange;
      icon = Icons.hourglass_top_rounded;
      label = 'مشغولة';
    } else {
      c = AppTheme.green;
      icon = Icons.check_circle_rounded;
      label = 'متاحة';
    }

    String unitName = '';
    if (s.isBusy && s.wodId != null) {
      final e = _catalog[s.wodId];
      if (e != null) unitName = e.displayName; // ✅ استخدمنا الاسم العربي
    }

    return Container(
      padding:
          EdgeInsets.symmetric(vertical: isMain ? 10 : 6, horizontal: 4),
      decoration: BoxDecoration(
        color: c.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: c.withOpacity(0.55), width: isMain ? 2 : 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: c, size: isMain ? 26 : 20),
          SizedBox(height: isMain ? 6 : 4),
          Text(label,
              style: TextStyle(
                  color: c,
                  fontSize: isMain ? 12 : 10,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          if (s.isBusy) ...[
            const SizedBox(height: 2),
            Text(s.timeLabel,
                style: TextStyle(
                    color: c,
                    fontSize: isMain ? 11 : 9,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            if (isMain && unitName.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(unitName,
                  style: TextStyle(
                      color: c.withOpacity(0.9),
                      fontSize: 10,
                      decoration: TextDecoration.none),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              Text('${s.units} جندي',
                  style: TextStyle(
                      color: c,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.none),
                  textAlign: TextAlign.center),
            ],
          ],
        ],
      ),
    );
  }

  Widget _modeToggle(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _isAutoMode = false),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: !_isAutoMode
                    ? AppTheme.teal.withOpacity(0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: !_isAutoMode
                        ? AppTheme.teal
                        : Colors.grey.withOpacity(0.3)),
              ),
              child: Center(
                  child: Text('تدريب يدوي',
                      style: TextStyle(
                          color: !_isAutoMode
                              ? AppTheme.teal
                              : AppTheme.subTextColor(context),
                          fontWeight: FontWeight.bold))),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _isAutoMode = true),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: _isAutoMode
                    ? AppTheme.purple.withOpacity(0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: _isAutoMode
                        ? AppTheme.purple
                        : Colors.grey.withOpacity(0.3)),
              ),
              child: Center(
                  child: Text('تدريب تلقائي',
                      style: TextStyle(
                          color: _isAutoMode
                              ? AppTheme.purple
                              : AppTheme.subTextColor(context),
                          fontWeight: FontWeight.bold))),
            ),
          ),
        ),
      ],
    );
  }

  Widget _unitPickerManual(BuildContext context) {
    if (_trainable.isEmpty) {
      return AppTheme.glassCard(
        context: context,
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          const Icon(Icons.info_outline_rounded,
              color: AppTheme.orange, size: 32),
          const SizedBox(height: 10),
          Text(
              S.isAr
                  ? 'لا توجد وحدات متاحة في هذه القلعة'
                  : 'No units in this castle',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppTheme.textColor(context),
                  fontSize: 13,
                  decoration: TextDecoration.none)),
        ]),
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
                  border: Border.all(
                      color: AppTheme.teal.withOpacity(0.3))),
              child: const Icon(Icons.gavel_rounded,
                  color: AppTheme.teal, size: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.unitType,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.subTextColor(context),
                        letterSpacing: 0.8,
                        decoration: TextDecoration.none)),
                const SizedBox(height: 2),
                DropdownButtonHideUnderline(
                  child: DropdownButton<UnitCatalogEntry>(
                    value: _trainable.contains(_selectedUnit)
                        ? _selectedUnit
                        : _trainable.first,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor:
                        Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    items: _trainable.map((u) {
                      return DropdownMenuItem(
                        value: u,
                        child: Row(children: [
                          UnitAvatar(
                            info: u,
                            size: 28,
                            onLongPress: () => openUnitCatalog(context, u),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(u.displayName, // ✅ اسم عربي
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textColor(
                                          context)))),
                        ]),
                      );
                    }).toList(),
                    onChanged: (v) =>
                        setState(() => _selectedUnit = v),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _amountInputManual(BuildContext context) {
    final maxB = _maxPerBatch;
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
                  border: Border.all(
                      color: AppTheme.orange.withOpacity(0.3))),
              child: const Icon(Icons.numbers_rounded,
                  color: AppTheme.orange, size: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(S.amount,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.subTextColor(context),
                          letterSpacing: 0.8,
                          decoration: TextDecoration.none)),
                  const SizedBox(width: 6),
                  Text('(حد أقصى $maxB)',
                      style: TextStyle(
                          fontSize: 9,
                          color: AppTheme.subTextColor(context)
                              .withOpacity(0.7),
                          decoration: TextDecoration.none)),
                ]),
                const SizedBox(height: 2),
                Row(children: [
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
                          decoration: TextDecoration.none),
                      decoration: const InputDecoration(
                          isDense: true,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 6),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _stepBtn(
                      icon: Icons.keyboard_double_arrow_up_rounded,
                      color: AppTheme.green,
                      tooltip: '$maxB',
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _amountCtrl.text = maxB.toString();
                        setState(() {});
                      }),
                  const SizedBox(width: 6),
                  _stepBtn(
                      icon: Icons.keyboard_double_arrow_down_rounded,
                      color: AppTheme.red,
                      tooltip: '1',
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _amountCtrl.text = '1';
                        setState(() {});
                      }),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _unitPreviewManual(BuildContext context) {
    if (_selectedUnit == null) return const SizedBox.shrink();
    final u = _selectedUnit!;
    final isRanged = u.role == 'ranged';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: isRanged
            ? const LinearGradient(
                colors: [Color(0xFF00B894), Color(0xFF00D68F)])
            : const LinearGradient(
                colors: [Color(0xFFEC4899), Color(0xFFFF8E53)]),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: (isRanged ? AppTheme.green : AppTheme.pink)
                  .withOpacity(0.35),
              blurRadius: 22,
              offset: const Offset(0, 10))
        ],
      ),
      child: Row(children: [
        UnitAvatar(
          info: u,
          size: 80,
          onLongPress: () => openUnitCatalog(context, u),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(u.displayName, // ✅ اسم عربي
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      decoration: TextDecoration.none)),
              const SizedBox(height: 4),
              Text(isRanged ? 'Ranged · Offense' : 'Melee · Offense',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.85),
                      fontSize: 11.5,
                      decoration: TextDecoration.none)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.22),
              borderRadius: BorderRadius.circular(10)),
          child: Text('x${_amountCtrl.text}',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  decoration: TextDecoration.none)),
        ),
      ]),
    );
  }

  Widget _autoTrainPanel(BuildContext context) {
    final maxB = _maxPerBatch;

    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.autorenew_rounded,
                color: AppTheme.purple, size: 20),
            const SizedBox(width: 8),
            Text('التدريب التلقائي',
                style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    decoration: TextDecoration.none)),
            const Spacer(),
            Switch(
              value: _autoEnabled,
              onChanged: (v) async {
                setState(() {
                  _autoSettings.enabled = v;
                  if (v && !_triggerOnSlot && !_triggerOnTime) {
                    _autoSettings.triggerOnSlot = true;
                  }
                });
                if (v && _castle != null) {
                  await _autoSettings.setTrainArea(_castle!.areaId);
                }
                await _autoSettings.save();
              },
              activeColor: AppTheme.purple,
            ),
          ]),
          const Divider(),
          Text('شروط التشغيل:',
              style: TextStyle(
                  color: AppTheme.subTextColor(context),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none)),
          CheckboxListTile(
            title: Text('عند توفر خانة فارغة',
                style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontSize: 13,
                    decoration: TextDecoration.none)),
            value: _triggerOnSlot,
            activeColor: AppTheme.purple,
            onChanged: (v) async {
              setState(() => _autoSettings.triggerOnSlot = v ?? true);
              await _autoSettings.save();
            },
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          CheckboxListTile(
            title: Text('حسب الوقت',
                style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontSize: 13,
                    decoration: TextDecoration.none)),
            value: _triggerOnTime,
            activeColor: AppTheme.purple,
            onChanged: (v) async {
              setState(() => _autoSettings.triggerOnTime = v ?? false);
              await _autoSettings.save();
            },
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          if (_triggerOnTime)
            Padding(
              padding: const EdgeInsets.only(right: 32, bottom: 10),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _timeCtrl,
                    keyboardType: TextInputType.number,
                    style:
                        TextStyle(color: AppTheme.textColor(context)),
                    decoration: const InputDecoration(
                        isDense: true, hintText: 'الوقت'),
                    onChanged: (v) async {
                      _autoSettings.timeInterval =
                          int.tryParse(v) ?? 5;
                      await _autoSettings.save();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                DropdownButton<String>(
                  value: _autoSettings.timeUnit,
                  dropdownColor:
                      Theme.of(context).colorScheme.surface,
                  items: const [
                    DropdownMenuItem(value: 'seconds', child: Text('ثواني')),
                    DropdownMenuItem(value: 'minutes', child: Text('دقائق')),
                    DropdownMenuItem(value: 'hours', child: Text('ساعات')),
                  ],
                  onChanged: (v) async {
                    setState(() =>
                        _autoSettings.timeUnit = v ?? 'minutes');
                    await _autoSettings.save();
                  },
                ),
              ]),
            ),
          const Divider(),
          CheckboxListTile(
            title: Text('تحديد أقصى عدد للتدريب',
                style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontSize: 13,
                    decoration: TextDecoration.none)),
            value: _useMaxTotal,
            activeColor: AppTheme.purple,
            onChanged: (v) async {
              setState(() => _autoSettings.useMaxTotal = v ?? false);
              await _autoSettings.save();
            },
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          if (_useMaxTotal) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _maxTotalCtrl,
                    keyboardType: TextInputType.number,
                    style:
                        TextStyle(color: AppTheme.textColor(context)),
                    decoration: const InputDecoration(
                        isDense: true, hintText: 'أقصى عدد'),
                    onChanged: (v) async {
                      _autoSettings.maxTotal = v;
                      await _autoSettings.save();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Text('تم تدريب: ${_autoSettings.totalTrained}',
                    style: TextStyle(
                        color: AppTheme.subTextColor(context),
                        fontSize: 12,
                        decoration: TextDecoration.none)),
              ]),
            ),
            const SizedBox(height: 10),
          ],
          const Divider(),
          Text('الوحدات المطلوبة:',
              style: TextStyle(
                  color: AppTheme.subTextColor(context),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none)),
          const SizedBox(height: 8),
          if (_trainable.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(
                  S.isAr
                      ? 'لا توجد وحدات متاحة في هذه القلعة'
                      : 'No units available here',
                  style: TextStyle(
                      color: AppTheme.orange,
                      fontSize: 12,
                      decoration: TextDecoration.none),
                ),
              ),
            )
          else
            ..._trainable.map((u) {
              final isSelected =
                  _autoSettings.selectedAmounts.containsKey(u.wodId);
              if (!_autoAmountCtrls.containsKey(u.wodId)) {
                _autoAmountCtrls[u.wodId] =
                    TextEditingController(text: '10');
              }
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.purple.withOpacity(0.1)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: isSelected
                          ? AppTheme.purple.withOpacity(0.5)
                          : Colors.grey.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Checkbox(
                        value: isSelected,
                        activeColor: AppTheme.purple,
                        onChanged: (v) async {
                          setState(() {
                            if (v == true) {
                              _autoSettings.selectedAmounts[u.wodId] =
                                  int.tryParse(
                                          _autoAmountCtrls[u.wodId]!
                                              .text) ??
                                      10;
                            } else {
                              _autoSettings.selectedAmounts
                                  .remove(u.wodId);
                            }
                          });
                          await _autoSettings.saveSelection();
                        },
                      ),
                      UnitAvatar(
                        info: u,
                        size: 36,
                        onLongPress: () => openUnitCatalog(context, u),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(u.displayName, // ✅ اسم عربي
                            style: TextStyle(
                                color: AppTheme.textColor(context),
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                decoration: TextDecoration.none)),
                      ),
                    ]),
                    if (isSelected)
                      Padding(
                        padding:
                            const EdgeInsets.only(top: 8, right: 40),
                        child: Row(children: [
                          Expanded(
                            child: SizedBox(
                              height: 40,
                              child: TextField(
                                controller: _autoAmountCtrls[u.wodId],
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly
                                ],
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: AppTheme.textColor(context),
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding:
                                      const EdgeInsets.symmetric(
                                          vertical: 8),
                                  filled: true,
                                  fillColor: AppTheme.isDark(context)
                                      ? Colors.black26
                                      : Colors.grey.shade200,
                                  border: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      borderSide: BorderSide.none),
                                ),
                                onChanged: (v) async {
                                  _autoSettings.selectedAmounts[u.wodId] =
                                      int.tryParse(v) ?? 10;
                                  await _autoSettings.saveSelection();
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () async {
                              _autoAmountCtrls[u.wodId]!.text =
                                  maxB.toString();
                              _autoSettings.selectedAmounts[u.wodId] =
                                  maxB;
                              await _autoSettings.saveSelection();
                              setState(() {});
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                  color:
                                      AppTheme.green.withOpacity(0.2),
                                  borderRadius:
                                      BorderRadius.circular(8),
                                  border: Border.all(
                                      color: AppTheme.green
                                          .withOpacity(0.4))),
                              child: Text('$maxB',
                                  style: const TextStyle(
                                      color: AppTheme.green,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: () async {
                              _autoAmountCtrls[u.wodId]!.text = '0';
                              _autoSettings.selectedAmounts[u.wodId] = 0;
                              await _autoSettings.saveSelection();
                              setState(() {});
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                  color:
                                      AppTheme.red.withOpacity(0.2),
                                  borderRadius:
                                      BorderRadius.circular(8),
                                  border: Border.all(
                                      color: AppTheme.red
                                          .withOpacity(0.4))),
                              child: const Icon(Icons.refresh_rounded,
                                  color: AppTheme.red, size: 18),
                            ),
                          ),
                        ]),
                      ),
                  ],
                ),
              );
            }),
          if (_autoEnabled && _autoSettings.selectedAmounts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                  'اختر وحدة واحدة على الأقل للتدريب التلقائي.',
                  style: TextStyle(
                      color: AppTheme.red,
                      fontSize: 12,
                      decoration: TextDecoration.none)),
            ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required IconData icon,
      required String label,
      required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none)),
      ]),
    );
  }

  Widget _stepBtn(
      {required IconData icon,
      required Color color,
      required String tooltip,
      required VoidCallback onTap}) {
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
                  border: Border.all(color: color.withOpacity(0.35))),
              child: Icon(icon, color: color, size: 22)),
        ),
      ),
    );
  }

  String _fmt(int totalSeconds) {
    if (totalSeconds <= 0) return '0s';
    final d = totalSeconds ~/ 86400;
    final h = (totalSeconds % 86400) ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (d > 0) return '${d}d ${h}h';
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}