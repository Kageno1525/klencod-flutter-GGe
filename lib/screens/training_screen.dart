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
class SlotInfo {
  final int rut;
  final DateTime fetchedAt;
  final bool isTraining;
  final int units;
  final int? wodId;

  SlotInfo({
    required this.rut,
    required this.fetchedAt,
    this.isTraining = false,
    this.units = 0,
    this.wodId,
  });

  bool get isLocked => rut == -1;
  bool get isFree => rut == 0 && !isTraining;
  bool get isBusy => rut > 0 || isTraining;

  int get remainingSeconds {
    if (!isBusy) return 0;
    final elapsed = DateTime.now().difference(fetchedAt).inSeconds;
    return (rut - elapsed).clamp(0, 999999);
  }

  String get timeLabel {
    if (isLocked) return 'مقفول';
    if (isFree) return 'فاضي';
    final s = remainingSeconds;
    if (s <= 0) return 'خلص';
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
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
  static const int _maxPerBatch = 80;

  // ═══ DICTIONARY: EXACT NAMES ALLOWED PER LEVEL ═══
  static const Map<int, List<String>> _levelUnits = {
    1: ['mace', 'maceman', 'spear', 'spearman'],
    2: ['bow', 'bowman', 'crossbow', 'crossbowman'],
    3: ['sword', 'swordsman', 'archer'],
    4: ['twohandedsword', 'twohandedswordsman', 'halberd', 'halberdier'],
    5: ['heavycrossbow', 'heavycrossbowman', 'longbow', 'longbowman'],
    6: ['veteranhalberd', 'veteranhalberdier', 'veterantwohandedsword', 'veterantwohandedswordsman', 'veteranlongbow', 'veteranlongbowman', 'veteranheavycrossbow', 'veteranheavycrossbowman'],
    7: ['relicaxe', 'relicaxeman'],
    9: ['relicshortbow', 'relicshortbowman'],
    11: ['relichammer', 'relichammerman'],
    13: ['reliclongbow', 'reliclongbowman'],
    14: ['shieldmaiden', 'protectorofthenorth'],
    15: ['valkyrieranger', 'valkyriesniper'],
    16: ['glasswingarcher'],
    17: ['flamebreathberserker'],
    19: ['scaleboundguardian'],
    20: ['scaleshardmarksman'],
  };

  List<OwnedCastle> _castles = [];
  Map<int, UnitCatalogEntry> _catalog = {};
  OwnedCastle? _castle;

  List<UnitCatalogEntry> _trainable = [];
  UnitCatalogEntry? _selectedUnit;
  final _amountCtrl = TextEditingController(text: '10');
  bool _training = false;

  List<SlotInfo>? _slots;
  bool _slotsLoading = false;
  DateTime? _lastSlotFetch;
  Timer? _slotsTimer;
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _loadAll();
    _slotsTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _loadSlots(silent: true);
    });
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _slots != null && _slots!.any((s) => s.isBusy)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _slotsTimer?.cancel();
    _tickTimer?.cancel();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    try {
      final castles = await widget.client.getCastles();
      final catalog = await widget.client.loadCatalog();
      if (!mounted) return;

      final trainableCastles = castles.where((c) => c.areaType == 1 || c.areaType == 4).toList();

      setState(() {
        _castles = trainableCastles;
        _catalog = catalog;
        if (trainableCastles.isEmpty) {
          _castle = null;
        } else {
          _castle = trainableCastles.firstWhere((c) => c.areaType == 1, orElse: () => trainableCastles.first);
        }
        _trainable = catalog.values.where((e) => e.isTrainable).toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
        
        // تحديث الوحدة المختارة بناءً على الفلتر الجديد
        final filtered = _filteredTrainable;
        _selectedUnit = filtered.isNotEmpty ? filtered.first : null;
      });

      if (_castle != null) {
        unawaited(_loadSlots(force: true));
        if (widget.client.getBarracksLevel(_castle!.areaId) == null) {
          unawaited(_fetchBarracksLevel());
        }
      }
    } catch (e) {
      _snack('$e', color: AppTheme.red);
    }
  }

  Future<void> _fetchBarracksLevel() async {
    if (_castle == null) return;
    try {
      await widget.client.sendXtAndWait(
        'jca',
        jsonEncode({'CID': _castle!.areaId, 'KID': _castle!.kingdomId}),
        responseCmd: 'jaa',
        timeoutMs: 8000,
        isAction: false,
      );
      if (mounted) setState(() {
        final filtered = _filteredTrainable;
        _selectedUnit = filtered.isNotEmpty ? filtered.first : null;
      });
    } catch (e) {
      TrafficLog.add('ER', 'jca fetch error: $e');
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
        if (mounted) setState(() => _slotsLoading = false);
        return;
      }

      final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
      final spl = data['spl'] ?? data;
      final ps = spl['PS'] as Map?;
      final qs = spl['QS'] as List?;
      
      final now = DateTime.now();
      final parsedSlots = <SlotInfo>[];

      // 1. الخانة اللي بتتصنع حالياً
      if (ps != null && ps.isNotEmpty) {
        final rct = ps['RCT'] as num? ?? 0;
        final tua = ps['TUA'] as num? ?? 0;
        final wid = ps['WID'] as num? ?? 0;
        parsedSlots.add(SlotInfo(rut: rct.toInt(), fetchedAt: now, isTraining: true, units: tua.toInt(), wodId: wid.toInt()));
      }

      // 2. باقي الخانات
      if (qs != null) {
        for (final q in qs) {
          if (q is! Map) continue;
          final si = q['SI'];
          final rut = (si is Map ? si['RUT'] : null) ?? q['RUT'];
          if (rut is num) {
            parsedSlots.add(SlotInfo(rut: rut.toInt(), fetchedAt: now));
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _slots = parsedSlots;
        _slotsLoading = false;
      });
    } catch (e) {
      TrafficLog.add('ER', '[Slots] spl error: $e');
      if (mounted) setState(() => _slotsLoading = false);
    }
  }

  // ═══ ULTIMATE STRICT FILTER (Exact Match) ═══
  List<UnitCatalogEntry> get _filteredTrainable {
    final level = widget.client.getBarracksLevel(_castle?.areaId ?? 0) ?? 1;
    
    final allowedKeys = <String>{};
    for (int i = 1; i <= level; i++) {
      if (_levelUnits.containsKey(i)) {
        allowedKeys.addAll(_levelUnits[i]!);
      }
    }
    
    if (allowedKeys.isEmpty) return [];

    return _trainable.where((u) {
      // تنظيف الاسم
      final clean = u.displayName.toLowerCase()
          .replaceAll('barracks_unit_', '')
          .replaceAll('barracks', '')
          .replaceAll('_', '')
          .replaceAll(' ', '')
          .trim();
      
      // مطابقة دقيقة جداً
      return allowedKeys.contains(clean);
    }).toList();
  }

  Future<void> _train() async {
    if (_castle == null || _selectedUnit == null) return;
    final amt = int.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amt <= 0) { _snack(S.error, color: AppTheme.red); return; }
    if (amt > _maxPerBatch) { _snack(S.isAr ? 'الحد الأقصى $_maxPerBatch' : 'Max $_maxPerBatch', color: AppTheme.orange); return; }

    setState(() => _training = true);
    final result = await widget.client.trainUnits(areaId: _castle!.areaId, wodId: _selectedUnit!.wodId, amount: amt);

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

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(decoration: TextDecoration.none)),
      backgroundColor: color, behavior: SnackBarBehavior.floating,
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
                      FadeSlideIn(delay: const Duration(milliseconds: 100), child: _castlePicker(context)),
                      const SizedBox(height: 14),
                      FadeSlideIn(delay: const Duration(milliseconds: 160), child: _slotsCard(context)),
                      const SizedBox(height: 14),
                      FadeSlideIn(delay: const Duration(milliseconds: 280), child: _unitPicker(context)),
                      const SizedBox(height: 14),
                      FadeSlideIn(delay: const Duration(milliseconds: 340), child: _amountInput(context)),
                      const SizedBox(height: 14),
                      FadeSlideIn(delay: const Duration(milliseconds: 400), child: _unitPreview(context)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 16, right: 16, bottom: 16,
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
          AppIconBtn(icon: Icons.arrow_back_rounded, onTap: () => Navigator.pop(context), size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.trainTroops, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.textColor(context), letterSpacing: -0.3, decoration: TextDecoration.none)),
                Text(S.trainDesc, style: TextStyle(fontSize: 11, color: AppTheme.subTextColor(context), decoration: TextDecoration.none)),
              ],
            ),
          ),
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(gradient: AppTheme.successGradient, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: AppTheme.green.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 6))]),
            child: const Icon(Icons.military_tech_rounded, color: Colors.white, size: 22),
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
          Container(width: 42, height: 42, decoration: BoxDecoration(color: AppTheme.blue.withOpacity(0.15), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.blue.withOpacity(0.3))), child: const Icon(Icons.castle_rounded, color: AppTheme.blue, size: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(S.selectCastle, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.subTextColor(context), letterSpacing: 0.8, decoration: TextDecoration.none)),
                    const Spacer(),
                    if (_castle != null && widget.client.getBarracksLevel(_castle!.areaId) != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: AppTheme.teal.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                        child: Text('الباراكس لفل ${widget.client.getBarracksLevel(_castle!.areaId)}', style: const TextStyle(color: AppTheme.teal, fontSize: 9, fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                if (_castles.isEmpty)
                  Text(S.isAr ? 'لا توجد قلاع' : 'No castles', style: TextStyle(color: AppTheme.subTextColor(context), fontSize: 12, decoration: TextDecoration.none))
                else
                  DropdownButtonHideUnderline(
                    child: DropdownButton<OwnedCastle>(
                      value: _castle, isExpanded: true, isDense: true, dropdownColor: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(14), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textColor(context)),
                      items: _castles.map((c) => DropdownMenuItem(value: c, child: Text(c.fullLabel, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.textColor(context), fontSize: 13)))).toList(),
                      onChanged: (v) {
                        setState(() { _castle = v; _slots = null; _selectedUnit = null; });
                        if (v != null) {
                          unawaited(_loadSlots(force: true));
                          if (widget.client.getBarracksLevel(v.areaId) == null) {
                            unawaited(_fetchBarracksLevel());
                          } else {
                            setState(() { _selectedUnit = _filteredTrainable.isNotEmpty ? _filteredTrainable.first : null; });
                          }
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

  Widget _slotsCard(BuildContext context) {
    final slots = _slots;
    final loading = _slotsLoading;

    int freeCount = slots?.where((s) => s.isFree).length ?? 0;
    int busyCount = slots?.where((s) => s.isBusy).length ?? 0;
    int totalAvailable = freeCount + busyCount;

    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 32, height: 32, decoration: BoxDecoration(color: AppTheme.purple.withOpacity(0.15), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.meeting_room_rounded, color: AppTheme.purple, size: 18)),
              const SizedBox(width: 10),
              Expanded(child: Text(S.isAr ? 'خانات التدريب' : 'Training slots', style: TextStyle(color: AppTheme.textColor(context), fontWeight: FontWeight.bold, fontSize: 13, decoration: TextDecoration.none))),
              if (loading) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.purple))
              else GestureDetector(
                onTap: () => _loadSlots(force: true),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: totalAvailable > 0 && freeCount == 0 ? AppTheme.red.withOpacity(0.15) : AppTheme.teal.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                  child: Text('$freeCount/$totalAvailable', style: TextStyle(color: totalAvailable > 0 && freeCount == 0 ? AppTheme.red : AppTheme.teal, fontWeight: FontWeight.bold, fontSize: 11, decoration: TextDecoration.none)),
                ),
              ),
            ],
          ),
          if (slots != null && slots.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: slots.map((s) {
                final isFree = s.isFree;
                final isBusy = s.isBusy;
                final isLocked = s.isLocked;
                Color c = isFree ? AppTheme.green : (isBusy ? AppTheme.orange : AppTheme.subTextColor(context));

                return Container(
                  width: 70,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: c.withOpacity(0.4), width: 1.2),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isFree ? Icons.check_circle_outline_rounded : (isBusy ? Icons.hourglass_top_rounded : Icons.lock_rounded), color: c, size: 16),
                      const SizedBox(height: 4),
                      Text(s.timeLabel, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
                      if (s.isTraining && s.wodId != null) ...[
                        const SizedBox(height: 2),
                        Text(_catalog[s.wodId]?.displayName != null ? S.unitName(_catalog[s.wodId]!.displayName) : 'شغال', style: TextStyle(color: c, fontSize: 8, decoration: TextDecoration.none), overflow: TextOverflow.ellipsis),
                        Text('${s.units} جندي', style: TextStyle(color: c, fontSize: 8, decoration: TextDecoration.none)),
                      ],
                    ],
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _slotStat(context, label: 'فاضي', value: freeCount, color: AppTheme.green),
                const SizedBox(width: 8),
                _slotStat(context, label: 'مشغول', value: busyCount, color: AppTheme.orange),
                const Spacer(),
                Icon(Icons.sync_rounded, size: 12, color: AppTheme.subTextColor(context)),
                const SizedBox(width: 4),
                Text('تحديث مباشر', style: TextStyle(color: AppTheme.subTextColor(context), fontSize: 9, decoration: TextDecoration.none)),
              ],
            ),
          ] else if (!loading) ...[
            const SizedBox(height: 8),
            Text('لا توجد بيانات', style: TextStyle(color: AppTheme.subTextColor(context), fontSize: 11, decoration: TextDecoration.none)),
          ],
        ],
      ),
    );
  }

  Widget _slotStat(BuildContext context, {required String label, required int value, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('$value $label', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
        ],
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
              Icon(Icons.inbox_rounded, color: AppTheme.subTextColor(context), size: 32),
              const SizedBox(height: 8),
              Text('لا توجد وحدات متاحة في هذا المستوى', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.subTextColor(context), fontSize: 12, decoration: TextDecoration.none)),
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
          Container(width: 42, height: 42, decoration: BoxDecoration(color: AppTheme.teal.withOpacity(0.15), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.teal.withOpacity(0.3))), child: const Icon(Icons.gavel_rounded, color: AppTheme.teal, size: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.unitType, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.subTextColor(context), letterSpacing: 0.8, decoration: TextDecoration.none)),
                const SizedBox(height: 2),
                DropdownButtonHideUnderline(
                  child: DropdownButton<UnitCatalogEntry>(
                    // التأكد من إن القيمة الحالية موجودة في القائمة المفلترة
                    value: filtered.contains(_selectedUnit) ? _selectedUnit : filtered.first,
                    isExpanded: true, isDense: true, dropdownColor: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(14), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textColor(context)),
                    items: filtered.map((u) {
                      return DropdownMenuItem(
                        value: u,
                        child: Row(
                          children: [
                            Icon(u.role == 'ranged' ? Icons.gps_fixed_rounded : Icons.gavel_rounded, size: 14, color: u.role == 'ranged' ? AppTheme.teal : AppTheme.red),
                            const SizedBox(width: 6),
                            Expanded(child: Text(S.unitName(u.displayName), overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: AppTheme.textColor(context)))),
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
          Container(width: 42, height: 42, decoration: BoxDecoration(color: AppTheme.orange.withOpacity(0.15), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.orange.withOpacity(0.3))), child: const Icon(Icons.numbers_rounded, color: AppTheme.orange, size: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(S.amount, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.subTextColor(context), letterSpacing: 0.8, decoration: TextDecoration.none)),
                    const SizedBox(width: 6),
                    Text('(حد أقصى $_maxPerBatch)', style: TextStyle(fontSize: 9, color: AppTheme.subTextColor(context).withOpacity(0.7), decoration: TextDecoration.none)),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _amountCtrl, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(color: AppTheme.textColor(context), fontSize: 18, fontWeight: FontWeight.bold, decoration: TextDecoration.none),
                        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 6), border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _stepBtn(icon: Icons.keyboard_double_arrow_up_rounded, color: AppTheme.green, tooltip: '80', onTap: () { HapticFeedback.lightImpact(); _amountCtrl.text = _maxPerBatch.toString(); setState(() {}); }),
                    const SizedBox(width: 6),
                    _stepBtn(icon: Icons.keyboard_double_arrow_down_rounded, color: AppTheme.red, tooltip: '1', onTap: () { HapticFeedback.lightImpact(); _amountCtrl.text = '1'; setState(() {}); }),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepBtn({required IconData icon, required Color color, required String tooltip, required VoidCallback onTap}) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap, borderRadius: BorderRadius.circular(10),
          child: Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.35))), child: Icon(icon, color: color, size: 22)),
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
        gradient: isRanged ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF00B894), Color(0xFF00D68F)]) : const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFEC4899), Color(0xFFFF8E53)]),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: (isRanged ? AppTheme.green : AppTheme.pink).withOpacity(0.35), blurRadius: 22, offset: const Offset(0, 10))],
      ),
      child: Row(
        children: [
          Container(width: 64, height: 64, decoration: BoxDecoration(color: Colors.white.withOpacity(0.22), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white.withOpacity(0.2))), child: Icon(isRanged ? Icons.gps_fixed_rounded : Icons.gavel_rounded, color: Colors.white, size: 32)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.unitName(u.displayName), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16, decoration: TextDecoration.none)),
                const SizedBox(height: 4),
                Text(isRanged ? 'Ranged · Offense' : 'Melee · Offense', style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 11.5, decoration: TextDecoration.none)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.22), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white.withOpacity(0.2))),
            child: Text('x${_amountCtrl.text}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13, decoration: TextDecoration.none)),
          ),
        ],
      ),
    );
  }
}