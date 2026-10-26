import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../gge_client.dart';

@pragma('vm:entry-point')
void ggeBackgroundCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_GgeTaskHandler());
}

// ═══ keep reference so release tree-shaking can't strip callback ═══
final _callbackRef = ggeBackgroundCallback;

class _GgeTaskHandler extends TaskHandler {
  WebSocket? _ws;
  StreamSubscription? _sub;
  int _msgCount = 0;
  bool _connected = false;

  static const String _url =
      'wss://ep-live-mz-sa1-ae1-eg1-arab1-game.goodgamestudios.com/';

  void _log(String s) {
    debugPrint('[BG WS] $s');
    try {
      FlutterForegroundTask.sendDataToMain('LOG:$s');
    } catch (_) {}
  }

  Future<void> _save(String s) async {
    try {
      await FlutterForegroundTask.saveData(key: 'bg_status', value: s);
      await FlutterForegroundTask.saveData(
          key: 'bg_time', value: DateTime.now().toIso8601String());
      await FlutterForegroundTask.saveData(key: 'bg_msgs', value: _msgCount);
    } catch (e) {
      debugPrint('[BG WS] save error: $e');
    }
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _log('onStart');
    await _save('STARTING');
    _connect();
  }

  Future<void> _connect() async {
    try {
      _log('connecting...');
      await _save('CONNECTING');

      final ws = await WebSocket.connect(_url)
          .timeout(const Duration(seconds: 20));

      _ws = ws;
      _connected = true;
      _log('CONNECTED');
      await _save('CONNECTED');

      ws.add(
          '<msg t="sys"><body action="verChk" r="0"><ver v="166" /></body></msg>');

      _sub = ws.listen(
        (data) {
          _msgCount++;
          final text = data.toString();
          final short =
              text.length > 80 ? '${text.substring(0, 80)}...' : text;
          _log('RX[$_msgCount]: $short');
          _save('MSG_$_msgCount');
        },
        onDone: () {
          _log('disconnected');
          _connected = false;
          _save('DISCONNECTED');
        },
        onError: (e) {
          _log('error: $e');
          _connected = false;
          _save('ERROR: $e');
        },
      );
    } catch (e) {
      _log('connect failed: $e');
      _connected = false;
      await _save('CONNECT_FAILED: $e');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _log('heartbeat connected=$_connected msgs=$_msgCount');
    _save('HEARTBEAT_$_msgCount');
  }

  // ═══ FIX: 2 params required by v11 ═══
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _sub?.cancel();
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _connected = false;
    _log('destroyed (timeout=$isTimeout)');
    await _save('DESTROYED');
  }

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {}
}

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
        channelDescription: 'Keeps GGE Bot connected',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        showWhen: false,
        enableVibration: false,
        playSound: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
    TrafficLog.add('ST', '[BG] plugin initialized');
  }

  static Future<bool> start() async {
    if (_running) return true;
    try {
      await init();

      unawaited(
        FlutterForegroundTask.isIgnoringBatteryOptimizations
            .then((ignoring) async {
          if (!ignoring) {
            try {
              await FlutterForegroundTask.requestIgnoreBatteryOptimization();
            } catch (_) {}
          }
        }).catchError((_) {}),
      );

      // ═══ FIX: don't inspect result — check actual state ═══
      await FlutterForegroundTask.startService(
        serviceId: 1001,
        notificationTitle: 'GGE Bot is active',
        notificationText: 'Watching for attacks...',
        callback: _callbackRef,
      );

      // Give service a moment to boot
      await Future.delayed(const Duration(milliseconds: 500));

      _running = await FlutterForegroundTask.isRunningService;
      GgeClient.allowBackgroundReconnect = _running;
      TrafficLog.add('ST', '[BG] start → running=$_running');
      return _running;
    } catch (e) {
      TrafficLog.add('ER', '[BG] start failed: $e');
      return false;
    }
  }

  static Future<void> stop() async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      TrafficLog.add('ER', '[BG] stop failed: $e');
    }
    _running = false;
    GgeClient.allowBackgroundReconnect = false;
    TrafficLog.add('ST', '[BG] stopped');
  }

  static Future<bool> isBatteryOptimized() async {
    try {
      final ignoring =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      return !ignoring;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestBatteryOptimizationExemption() async {
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> readStatus() async {
    try {
      final status =
          await FlutterForegroundTask.getData<String>(key: 'bg_status');
      final time =
          await FlutterForegroundTask.getData<String>(key: 'bg_time');
      final msgs = await FlutterForegroundTask.getData<int>(key: 'bg_msgs');
      return {
        'status': status ?? 'never ran',
        'time': time ?? '?',
        'msgs': msgs ?? 0,
      };
    } catch (e) {
      return {'status': 'read error: $e', 'time': '?', 'msgs': 0};
    }
  }
}