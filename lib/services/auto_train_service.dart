import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';
import 'training_service.dart';

/// تدريب تلقائي — يستخدمه الـ Background فقط.
/// يستخدم `TrainingService` عشان يضمن فلترة الباراكس + الوحدات.
class AutoTrainService {
  AutoTrainService._();
  static final AutoTrainService instance = AutoTrainService._();

  GgeClient? _client;
  TrainingService? _svc;
  Timer? _timer;
  bool _running = false;
  bool _isProcessing = false;

  bool get isRunning => _running;

  Future<void> start(GgeClient client) async {
    if (_running) return;
    _client = client;
    _svc = TrainingService(client);
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
    if (!_running || _isProcessing || _client == null || _svc == null) return;
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

    // ── تشغيل/إيقاف ──
    final autoEnabled = prefs.getBool('auto_enabled') ?? false;
    if (!autoEnabled) return;

    // ── متدربش لو الـ UI شغال ──
    final isAppForeground = prefs.getBool('is_app_foreground') ?? false;
    if (isAppForeground) return;

    // ── تحميل الإعدادات من prefs ──
    final settings = await AutoTrainSettings.load();

    // ── حد أقصى للعدد الكلي ──
    if (settings.useMaxTotal) {
      final max = int.tryParse(settings.maxTotal) ?? 0;
      if (settings.totalTrained >= max) {
        await prefs.setBool('auto_enabled', false);
        TrafficLog.add('ST',
            '[AutoTrain] Reached max (${settings.totalTrained}/$max) → disabled');
        return;
      }
    }

    // ── لازم يكون فيه وحدات مختارة ──
    if (settings.selectedAmounts.isEmpty) return;

    // ── شروط التشغيل ──
    bool shouldTrain = false;

    // 1) خانة فاضية — نفحص spl الفعلية مش الإعداد بس
    if (settings.triggerOnSlot) {
      final slotsResp = await _svc!.loadSlots();
      if (slotsResp != null && slotsResp.slots.any((s) => s.isFree)) {
        shouldTrain = true;
        TrafficLog.add('ST', '[AutoTrain] Free slot detected');
      }
    }

    // 2) حسب الوقت
    if (!shouldTrain && await settings.isTimeTriggered()) {
      shouldTrain = true;
      TrafficLog.add('ST', '[AutoTrain] Time trigger fired');
    }

    if (!shouldTrain) return;

    // ── القلعة الحالية ──
    final areaId = await AutoTrainSettings.getTrainArea();
    if (areaId == null || areaId <= 0) {
      TrafficLog.add('ER',
          '[AutoTrain] No area selected — open Training screen once');
      return;
    }

    final castles = await _client!.getCastles();
    OwnedCastle? castle;
    for (final c in castles) {
      if (c.areaId == areaId) {
        castle = c;
        break;
      }
    }
    if (castle == null) {
      TrafficLog.add('ER', '[AutoTrain] Castle $areaId not found');
      return;
    }

    // ── تأكد من مستوى الثكنات (jca) ──
    await _svc!.fetchBarracksLevel(castle);

    // ── الكتالوج ──
    final catalog = await _client!.loadCatalog();

    // ── تنفيذ (TrainingService بيتولى كل الفلترة) ──
    final result = await _svc!.executeAutoTrain(
      castle: castle,
      settings: settings,
      catalog: catalog,
    );

    // ── معالجة النتيجة ──
    if (result.success) {
      await settings.saveRotation(
        result.nextIndex!,
        settings.totalTrained + result.amount!,
      );
      await settings.markTrainTime();
      TrafficLog.add('ST',
          '[AutoTrain] ✅ WID=${result.wodId} AMT=${result.amount} '
          '(total=${settings.totalTrained})');
    } else if (result.skipped) {
      TrafficLog.add('ST', '[AutoTrain] ⏭ ${result.error}');
    } else {
      // نحدّث الوقت حتى لو فشل — عشان مايبعتش كل 10 ثواني
      await settings.markTrainTime();
      TrafficLog.add('ER', '[AutoTrain] ❌ ${result.error}');
    }
  }
}