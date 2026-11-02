import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';

/// تدريب تلقائي — يستخدمه الـ Background فقط.
class AutoTrainService {
  AutoTrainService._();
  static final AutoTrainService instance = AutoTrainService._();

  // ✅ نفس القيم اللي في UI
  static const int _barracksMaxLevel = 20;
  static const int _absoluteMaxPerBatch = 80;

  GgeClient? _client;
  Timer? _timer;
  bool _running = false;
  bool _isProcessing = false;

  bool get isRunning => _running;

  Future<void> start(GgeClient client) async {
    if (_running) return;
    _client = client;
    _running = true;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _tick());
    TrafficLog.add('ST', '[AutoTrain] started');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    TrafficLog.add('ST', '[AutoTrain] stopped');
  }

  Future<void> _tick() async {
    if (!_running || _isProcessing || _client == null) return;
    _isProcessing = true;
    try {
      await _doTrain();
    } catch (e) {
      TrafficLog.add('ER', '[AutoTrain] error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ✅ max per batch ديناميكي من مستوى الثكنات
  int _maxPerBatchFor(int? level) {
    if (level == null || level <= 0) return _absoluteMaxPerBatch;
    return (level * 4).clamp(10, _absoluteMaxPerBatch);
  }

  Future<void> _doTrain() async {
    final prefs = await SharedPreferences.getInstance();

    // ── تشغيل/إيقاف ──
    final autoEnabled = prefs.getBool('auto_enabled') ?? false;
    if (!autoEnabled) return;

    // ── متدربش لو الـ UI شغال ──
    final isAppForeground = prefs.getBool('is_app_foreground') ?? false;
    if (isAppForeground) return;

    // ── حد أقصى ──
    final useMaxTotal = prefs.getBool('auto_use_max') ?? false;
    final maxTotal =
        int.tryParse(prefs.getString('auto_max_total') ?? '1000') ?? 1000;
    final totalTrained = prefs.getInt('auto_total_trained') ?? 0;
    if (useMaxTotal && totalTrained >= maxTotal) {
      await prefs.setBool('auto_enabled', false);
      TrafficLog.add('ST',
          '[AutoTrain] Reached max ($totalTrained/$maxTotal) → disabled');
      return;
    }

    // ── شروط ──
    final triggerOnTime = prefs.getBool('auto_trigger_time') ?? false;
    final triggerOnSlot = prefs.getBool('auto_trigger_slot') ?? true;

    bool timeTriggered = false;
    if (triggerOnTime) {
      final interval = prefs.getInt('auto_time_interval') ?? 5;
      final unit = prefs.getString('auto_time_unit') ?? 'minutes';
      final lastStr = prefs.getString('auto_last_train_time');
      int intervalSec = interval;
      if (unit == 'minutes') intervalSec *= 60;
      if (unit == 'hours') intervalSec *= 3600;
      if (lastStr == null) {
        timeTriggered = true;
      } else {
        final last = DateTime.parse(lastStr);
        if (DateTime.now().difference(last).inSeconds >= intervalSec) {
          timeTriggered = true;
        }
      }
    }

    if (!timeTriggered && !triggerOnSlot) return;

    // ✅✅✅ الحل: استخدم auto_train_area_id (اللي الـ UI بيحفظه)
    //    بدل main_castle_area الثابت
    final trainAreaId = prefs.getInt('auto_train_area_id') ??
        prefs.getInt('main_castle_area') ??
        0;

    if (trainAreaId <= 0) {
      TrafficLog.add('ER',
          '[AutoTrain] No area selected — open Training screen once');
      return;
    }

    // ── الوحدات ──
    final selectedJson = prefs.getString('auto_selected_units');
    if (selectedJson == null) return;
    final Map<String, dynamic> selected = jsonDecode(selectedJson);
    if (selected.isEmpty) return;

    final validWods = selected.keys.map((e) => int.parse(e)).toList();
    final currentIndex = prefs.getInt('auto_rotation_index') ?? 0;
    final wodId = validWods[currentIndex % validWods.length];
    final amount = selected[wodId.toString()] as int;
    if (amount <= 0) return;

    // ✅ احترم max per batch من مستوى الثكنات
    final barracksLevel = _client!.getBarracksLevel(trainAreaId);
    final maxB = _maxPerBatchFor(barracksLevel);
    final safeAmount = amount.clamp(1, maxB);

    TrafficLog.add('ST',
        '[AutoTrain] Send WID=$wodId AMT=$safeAmount (max=$maxB) area=$trainAreaId');

    final result = await _client!.trainUnits(
      areaId: trainAreaId,
      wodId: wodId,
      amount: safeAmount,
    );

    if (result.success) {
      await prefs.setString(
          'auto_last_train_time', DateTime.now().toIso8601String());
      await prefs.setInt('auto_total_trained', totalTrained + safeAmount);
      final nextIdx = (currentIndex + 1) % validWods.length;
      await prefs.setInt('auto_rotation_index', nextIdx);
      TrafficLog.add('ST',
          '[AutoTrain] ✅ WID=$wodId AMT=$safeAmount (total=${totalTrained + safeAmount})');
    } else {
      await prefs.setString(
          'auto_last_train_time', DateTime.now().toIso8601String());
      TrafficLog.add('ER', '[AutoTrain] ❌ WID=$wodId: ${result.error}');
    }
  }
}