import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import 'auto_train_service.dart';
import 'auto_defense_service.dart';
import 'desert_auto_service.dart';
import 'notifications_service.dart';

@pragma('vm:entry-point')
void ggeBackgroundCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_GgeTaskHandler());
}

final _callbackRef = ggeBackgroundCallback;

// ═══════════════════════════════════════════════════════════
//  Task Handler — Orchestrator فقط
//  بيشغّل: Login → Notifications → AutoTrain → AutoDefense → DesertAuto
// ═══════════════════════════════════════════════════════════
class _GgeTaskHandler extends TaskHandler {
  GgeClient? _client;
  Timer? _statusTimer;

  // ✅ NEW: log helper — يبعت للـ UI + debugPrint
  void _log(String s) {
    debugPrint('[BG] $s');
    try {
      FlutterForegroundTask.sendDataToMain('LOG:$s');
    } catch (_) {}
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _log('Service starting');
    await _saveStatus('STARTING');

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('login_token');
    if (token == null || token.isEmpty) {
      _log('No token available');
      await _saveStatus('NO_TOKEN');
      return;
    }

    // ── مزامنة desert source بين UI key و Auto key ──
    final desertSourceV2 = prefs.getInt('desert_source_v2') ?? 0;
    if (desertSourceV2 > 0 &&
        (prefs.getInt('desert_auto_source') ?? 0) == 0) {
      await prefs.setInt('desert_auto_source', desertSourceV2);
      _log('Synced desert_auto_source → $desertSourceV2');
    }

    // ── Init client ──
    _client = GgeClient();
    GgeClient.allowBackgroundReconnect = true;
    _client!.onAppLifecycleChanged(AppLifecycleState.paused);

    // ── Connect ──
    await _saveStatus('CONNECTING');
    try {
      await _client!.connect();
    } catch (e) {
      _log('Connect failed: $e');
      await _saveStatus('CONNECT_FAILED', extra: '$e');
      return;
    }

    // ── Login ──
    await _saveStatus('LOGGING_IN');
    try {
      await _client!.loginWithToken(token);
    } catch (e) {
      _log('Login failed: $e');
      await _saveStatus('LOGIN_FAILED', extra: '$e');
      return;
    }
    _log('Online');
    await _saveStatus('ONLINE');

    // ✅ NEW: نمسح أي conflict flag قديم — login نجح يبقى مفيش conflict
    await prefs.setBool('bg_session_conflict', false);

    // ✅ NEW: Session conflict handler
    // لما الـ client يكتشف إن حد تاني فتح الحساب، بنسجل flag للـ UI
    // ونوقف كل الخدمات عشان مفيش requests فاشلة
    _client!.onSessionConflict = () async {
      _log('⚠️ Session conflict detected — stopping all services');
      try {
        final p = await SharedPreferences.getInstance();
        await p.setBool('bg_session_conflict', true);
      } catch (_) {}
      await _saveStatus('SESSION_CONFLICT',
          extra: 'Account logged in elsewhere');

      try { AutoTrainService.instance.stop(); } catch (_) {}
      try { AutoDefenseService.instance.stop(); } catch (_) {}
      try { DesertAutoService.instance.stop(); } catch (_) {}
      try { NotificationsService.stopListening(); } catch (_) {}
    };

    // ── 1. Notifications (يستمع على نفس GgeClient) ──
    try {
      NotificationsService.startListening();
      _log('Notifications listening');
    } catch (e) {
      _log('Notifications error: $e');
    }

    // ── 2. Auto Train ──
    try {
      await AutoTrainService.instance.start(_client!);
      _log('AutoTrain started');
    } catch (e) {
      _log('AutoTrain error: $e');
    }

    // ── 3. Auto Defense (التهريب التلقائي) ──
    try {
      AutoDefenseService.instance.onBeforeEvac = () async {
        final p = await SharedPreferences.getInstance();
        // BG يهرب بس لو الـ app في الخلفية (الـ UI بيتصرف لو في المقدمة)
        return !(p.getBool('is_app_foreground') ?? false);
      };
      await AutoDefenseService.instance.init();
      _log('AutoDefense: '
          '${AutoDefenseService.instance.isRunning ? "running" : "idle"}');
    } catch (e) {
      _log('AutoDefense error: $e');
    }

    // ── 4. Desert Auto (هجوم الأبراج) ──
    try {
      _setupDesertCallbacks();
      await DesertAutoService.instance.start(_client!);
      _log('DesertAuto started');
    } catch (e) {
      _log('DesertAuto error: $e');
    }

    // ── Periodic status sync للـ UI poller ──
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _saveStatus(
        DesertAutoService.instance.isRunning ? 'RUNNING' : 'IDLE',
        extra: 'atk=${DesertAutoService.instance.attacksThisSession} · '
            'towers=${DesertAutoService.instance.towersScanned} · '
            'train=${AutoTrainService.instance.isRunning ? "ON" : "OFF"} · '
            'def=${AutoDefenseService.instance.isRunning ? "ON" : "OFF"}',
      );
    });
  }

  /// ✅ فرض الحدود اليومية/الجلسة + أولوية التهريب
  void _setupDesertCallbacks() {
    DesertAutoService.instance.onBeforeAttack = () async {
      final p = await SharedPreferences.getInstance();

      // (1) لو الـ UI شغال في المقدمة → سيبه للـ UI
      if (p.getBool('is_app_foreground') ?? false) return false;

      // (2) أولوية الدفاع: لو في تهريب نشط → بلاش هجوم
      if (AutoDefenseService.instance.activeEvacuations.isNotEmpty) {
        return false;
      }

      // (3) حد يومي
      final maxDay = p.getInt('desert_bg_max_attacks_day') ?? 0;
      if (maxDay > 0) {
        final now = DateTime.now();
        final today =
            '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final stored = p.getString('desert_bg_attacks_date') ?? '';
        if (stored != today) {
          await p.setInt('desert_bg_attacks_today', 0);
          await p.setString('desert_bg_attacks_date', today);
        }
        final count = p.getInt('desert_bg_attacks_today') ?? 0;
        if (count >= maxDay) return false;
      }

      // (4) حد جلسة
      final maxSess = p.getInt('desert_bg_max_attacks_session') ?? 0;
      if (maxSess > 0 &&
          DesertAutoService.instance.attacksThisSession >= maxSess) {
        return false;
      }
      return true;
    };

    DesertAutoService.instance.onAfterAttack = () async {
      final p = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final today =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final stored = p.getString('desert_bg_attacks_date') ?? '';
      if (stored != today) {
        await p.setString('desert_bg_attacks_date', today);
        await p.setInt('desert_bg_attacks_today', 1);
      } else {
        final cur = p.getInt('desert_bg_attacks_today') ?? 0;
        await p.setInt('desert_bg_attacks_today', cur + 1);
      }
    };
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _log('Service destroying');
    _statusTimer?.cancel();
    _statusTimer = null;

    try {
      AutoTrainService.instance.stop();
    } catch (_) {}
    try {
      AutoDefenseService.instance.stop();
    } catch (_) {}
    try {
      DesertAutoService.instance.stop();
    } catch (_) {}
    try {
      NotificationsService.stopListening();
    } catch (_) {}
    try {
      await _client?.dispose();
    } catch (_) {}
    _client = null;

    await _saveStatus('DESTROYED');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  void onReceiveData(Object data) {}
  @override
  void onNotificationButtonPressed(String id) {}
  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp('/');
  @override
  void onNotificationDismissed() {}

  Future<void> _saveStatus(String status, {String? extra}) async {
    try {
      await FlutterForegroundTask.saveData(key: 'bg_status', value: status);
      await FlutterForegroundTask.saveData(
          key: 'bg_time', value: DateTime.now().toIso8601String());
      await FlutterForegroundTask.saveData(key: 'bg_extra', value: extra ?? '');
    } catch (_) {}
  }
}

// ═══════════════════════════════════════════════════════════
//  BackgroundService static class — **بدون أي تغيير عن الأصلي**
// ═══════════════════════════════════════════════════════════
class BackgroundService {
  BackgroundService._();
  static bool _initialized = false;
  static bool _running = false;
  static bool get isRunning => _running;

  static Future<void> init() async {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'gge_bot_service',
        channelName: 'GGE Bot',
        channelDescription: 'Keeps GGE Bot connected & trains',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  static Future<bool> start() async {
    if (_running) return true;
    try {
      await init();
      unawaited(FlutterForegroundTask.isIgnoringBatteryOptimizations
          .then((ignoring) async {
        if (!ignoring) {
          try {
            await FlutterForegroundTask.requestIgnoreBatteryOptimization();
          } catch (_) {}
        }
      }).catchError((_) {}));
      await FlutterForegroundTask.startService(
        serviceId: 1001,
        notificationTitle: 'GGE Bot is active',
        notificationText: 'Watching for attacks & training...',
        callback: _callbackRef,
      );
      await Future.delayed(const Duration(milliseconds: 500));
      _running = await FlutterForegroundTask.isRunningService;
      GgeClient.allowBackgroundReconnect = _running;
      return _running;
    } catch (e) {
      return false;
    }
  }

  static Future<void> stop() async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
    _running = false;
    GgeClient.allowBackgroundReconnect = false;
  }

  static Future<Map<String, dynamic>> readStatus() async {
    try {
      final status =
          await FlutterForegroundTask.getData<String>(key: 'bg_status');
      final time =
          await FlutterForegroundTask.getData<String>(key: 'bg_time');
      final extra =
          await FlutterForegroundTask.getData<String>(key: 'bg_extra');
      return {
        'status': status ?? 'never ran',
        'time': time ?? '?',
        'extra': extra ?? '',
      };
    } catch (e) {
      return {'status': 'read error: $e', 'time': '?', 'extra': ''};
    }
  }
}