import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';

/// تدريب تلقائي — يستخدمه الـ Background فقط.
/// المنطق منقول من `_GgeTaskHandler._startAutoTrainTimer` الأصلي بدون أي تغيير.
class AutoTrainService {
  AutoTrainService._();
  static final AutoTrainService instance = AutoTrainService._();

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

  Future<void> _doTrain() async {
    final prefs = await SharedPreferences.getInstance();

    // ── تشغيل/إيقاف من الإعدادات ──
    final autoEnabled = prefs.getBool('auto_enabled') ?? false;
    if (!autoEnabled) return;

    // ── حماية: متدربش لو الـ UI شغال في المقدمة ──
    final isAppForeground = prefs.getBool('is_app_foreground') ?? false;
    if (isAppForeground) return;

    // ── حد أقصى للعدد الكلي ──
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

    // ── شروط التشغيل ──
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

    // ── الوحدات المختارة من UI ──
    final selectedJson = prefs.getString('auto_selected_units');
    if (selectedJson == null) return;
    final Map<String, dynamic> selected = jsonDecode(selectedJson);
    if (selected.isEmpty) return;

    final validWods = selected.keys.map((e) => int.parse(e)).toList();
    final currentIndex = prefs.getInt('auto_rotation_index') ?? 0;
    final wodId = validWods[currentIndex % validWods.length];
    final amount = selected[wodId.toString()] as int;
    if (amount <= 0) return;

    // ── AID (نفس السلوك الأصلي: prefs أو 1606327) ──
    final mainCastleArea = prefs.getInt('main_castle_area') ?? 1606327;

    // ── إرسال ──
    TrafficLog.add(
        'ST', '[AutoTrain] Send WID=$wodId AMT=$amount area=$mainCastleArea');
    final result = await _client!.trainUnits(
      areaId: mainCastleArea,
      wodId: wodId,
      amount: amount,
    );

    if (result.success) {
      await prefs.setString(
          'auto_last_train_time', DateTime.now().toIso8601String());
      await prefs.setInt('auto_total_trained', totalTrained + amount);
      final nextIdx = (currentIndex + 1) % validWods.length;
      await prefs.setInt('auto_rotation_index', nextIdx);
      TrafficLog.add('ST',
          '[AutoTrain] ✅ WID=$wodId AMT=$amount (total=${totalTrained + amount})');
    } else {
      // نحدّث الوقت حتى لو فشل — عشان مايبعتش كل 10 ثواني
      await prefs.setString(
          'auto_last_train_time', DateTime.now().toIso8601String());
      TrafficLog.add('ER', '[AutoTrain] ❌ WID=$wodId: ${result.error}');
    }
  }
}