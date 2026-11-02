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
import 'samurai_auto_service.dart';
import 'bedouin_auto_service.dart';
import 'notifications_service.dart';

@pragma('vm:entry-point')
void ggeBackgroundCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_GgeTaskHandler());
}

final _callbackRef = ggeBackgroundCallback;

// ═══════════════════════════════════════════════════════════
//  Task Handler — Orchestrator
// ═══════════════════════════════════════════════════════════
class _GgeTaskHandler extends TaskHandler {
  GgeClient? _client;
  Timer? _statusTimer;
  Timer? _presenceTimer;
  bool _running = false;
  String? _token;

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
    _token = prefs.getString('login_token');
    if (_token == null || _token!.isEmpty) {
      _log('No token available');
      await _saveStatus('NO_TOKEN');
      return;
    }

    // ✅ UI شغال → BG يستنى بس يكتب ONLINE
    final isFg = prefs.getBool('is_app_foreground') ?? false;
    if (isFg) {
      _log('App is in foreground — BG ready');
      await _saveStatus('ONLINE');
      _watchPresence();
      return;
    }

    // UI مقفول → يبدأ كامل
    await _startAll();
    _watchPresence();
  }

  void _watchPresence() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_token == null) return;

      final p = await SharedPreferences.getInstance();
      final fg = p.getBool('is_app_foreground') ?? false;

      if (fg && _running) {
        _log('Presence: UI opened → pausing');
        _presenceTimer?.cancel();
        _presenceTimer = null;
        await _pauseAll();
        _watchPresence();
        return;
      }

      if (!fg && !_running) {
        await Future.delayed(const Duration(seconds: 2));
        final fg2 = (await SharedPreferences.getInstance())
                .getBool('is_app_foreground') ??
            false;
        if (fg2) return;

        _log('Presence: UI closed → starting');
        _presenceTimer?.cancel();
        _presenceTimer = null;
        await _startAll();
        _watchPresence();
      }
    });
  }

  Future<void> _startAll() async {
    if (_running) return;
    if (_token == null) return;
    _running = true;

    final prefs = await SharedPreferences.getInstance();

    final desertSourceV2 = prefs.getInt('desert_source_v2') ?? 0;
    if (desertSourceV2 > 0 &&
        (prefs.getInt('desert_auto_source') ?? 0) == 0) {
      await prefs.setInt('desert_auto_source', desertSourceV2);
    }

    _client = GgeClient();
    GgeClient.allowBackgroundReconnect = true;
    _client!.onAppLifecycleChanged(AppLifecycleState.paused);

    await _saveStatus('CONNECTING');
    try {
      await _client!.connect();
      await _client!.loginWithToken(_token!);
    } catch (e) {
      _log('Connect/login failed: $e');
      await _saveStatus('CONNECT_FAILED', extra: '$e');
      _running = false;
      try {
        await _client?.dispose();
      } catch (_) {}
      _client = null;
      return;
    }

    await prefs.setBool('bg_session_conflict', false);
    _log('Online');
    await _saveStatus('ONLINE');

    _client!.onSessionConflict = () async {
      _log('Session conflict — stopping');
      try {
        await prefs.setBool('bg_session_conflict', true);
      } catch (_) {}
      await _saveStatus('SESSION_CONFLICT');
      await _pauseAll();
    };

    try {
      NotificationsService.startListening();
      _log('Notifications listening');
    } catch (e) {
      _log('Notifications error: $e');
    }

    try {
      await AutoTrainService.instance.start(_client!);
      _log('AutoTrain started');
    } catch (e) {
      _log('AutoTrain error: $e');
    }

    try {
      AutoDefenseService.instance.onBeforeEvac = () async {
        final pp = await SharedPreferences.getInstance();
        return !(pp.getBool('is_app_foreground') ?? false);
      };
      await AutoDefenseService.instance.init();
      _log('AutoDefense: '
          '${AutoDefenseService.instance.isRunning ? "running" : "idle"}');
    } catch (e) {
      _log('AutoDefense error: $e');
    }

    try {
      _setupDesertCallbacks();
      await DesertAutoService.instance.start(_client!);
      _log('DesertAuto started');
    } catch (e) {
      _log('DesertAuto error: $e');
    }

    try {
      await _syncSamuraiState(initial: true);
    } catch (e) {
      _log('SamuraiAuto error: $e');
    }

    try {
      await _syncBedouinState(initial: true);
    } catch (e) {
      _log('BedouinAuto error: $e');
    }

    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      _saveStatus(
        DesertAutoService.instance.isRunning ? 'RUNNING' : 'ONLINE',
        extra: 'atk=${DesertAutoService.instance.attacksThisSession} · '
            'towers=${DesertAutoService.instance.towersScanned} · '
            'train=${AutoTrainService.instance.isRunning ? "ON" : "OFF"} · '
            'def=${AutoDefenseService.instance.isRunning ? "ON" : "OFF"} · '
            'sam=${SamuraiAutoService.instance.isRunning ? "ON" : "OFF"} · '
            'bed=${BedouinAutoService.instance.isRunning ? "ON" : "OFF"}',
      );
      if (_running) {
        await _syncSamuraiState();
        await _syncBedouinState();
      }
    });
  }

  Future<void> _syncSamuraiState({bool initial = false}) async {
    if (_client == null) return;
    try {
      final enabled = await SamuraiAutoService.instance.isEnabled();
      final running = SamuraiAutoService.instance.isRunning;

      if (enabled && !running) {
        _log('SamuraiAuto: starting${initial ? " (initial)" : " (sync)"}');
        await SamuraiAutoService.instance.startInBackground(_client!);
      } else if (!enabled && running) {
        _log('SamuraiAuto: stopping (disabled)');
        SamuraiAutoService.instance.stop();
      }
    } catch (e) {
      _log('SamuraiAuto sync error: $e');
    }
  }

  Future<void> _syncBedouinState({bool initial = false}) async {
    if (_client == null) return;
    try {
      final enabled = await BedouinAutoService.instance.isEnabled();
      final running = BedouinAutoService.instance.isRunning;

      if (enabled && !running) {
        _log('BedouinAuto: starting${initial ? " (initial)" : " (sync)"}');
        await BedouinAutoService.instance.startInBackground(_client!);
      } else if (!enabled && running) {
        _log('BedouinAuto: stopping (disabled)');
        BedouinAutoService.instance.stop();
      }
    } catch (e) {
      _log('BedouinAuto sync error: $e');
    }
  }

  Future<void> _pauseAll() async {
    _log('Pausing all');
    _running = false;
    _statusTimer?.cancel();
    _statusTimer = null;

    try { AutoTrainService.instance.stop(); } catch (_) {}
    try { AutoDefenseService.instance.stop(); } catch (_) {}
    try { DesertAutoService.instance.stop(); } catch (_) {}
    try { SamuraiAutoService.instance.stop(); } catch (_) {}
    try { BedouinAutoService.instance.stop(); } catch (_) {}
    try { NotificationsService.stopListening(); } catch (_) {}

    try {
      await _client?.dispose();
    } catch (_) {}
    _client = null;

    await _saveStatus('ONLINE');
  }

  void _setupDesertCallbacks() {
    DesertAutoService.instance.onBeforeAttack = () async {
      final p = await SharedPreferences.getInstance();

      if (p.getBool('is_app_foreground') ?? false) return false;

      if (AutoDefenseService.instance.activeEvacuations.isNotEmpty) {
        return false;
      }

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
  void onReceiveData(Object data) {
    if (data is String) {
      if (data == 'UI_RESUMED') {
        _log('Signal: UI_RESUMED');
        if (_running) {
          _pauseAll();
          _watchPresence();
        }
      } else if (data == 'UI_PAUSED') {
        _log('Signal: UI_PAUSED');
        if (!_running && _token != null) {
          Future.delayed(const Duration(seconds: 2), () async {
            final fg = (await SharedPreferences.getInstance())
                    .getBool('is_app_foreground') ??
                false;
            if (!fg && !_running) {
              await _startAll();
              _watchPresence();
            }
          });
        }
      }
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _log('Destroying');
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _statusTimer?.cancel();
    _statusTimer = null;

    try { AutoTrainService.instance.stop(); } catch (_) {}
    try { AutoDefenseService.instance.stop(); } catch (_) {}
    try { DesertAutoService.instance.stop(); } catch (_) {}
    try { SamuraiAutoService.instance.stop(); } catch (_) {}
    try { BedouinAutoService.instance.stop(); } catch (_) {}
    try { NotificationsService.stopListening(); } catch (_) {}
    try { await _client?.dispose(); } catch (_) {}
    _client = null;
    _running = false;

    await _saveStatus('DESTROYED');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}
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
//  BackgroundService static class
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