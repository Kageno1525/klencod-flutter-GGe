import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';  // for TrafficLog

@pragma('vm:entry-point')
void ggeBackgroundCallback() {
  FlutterForegroundTask.setTaskHandler(_GgeTaskHandler());
}

class _GgeTaskHandler extends TaskHandler {
  WebSocket? _ws;
  StreamSubscription? _sub;
  int _msgCount = 0;
  bool _connected = false;

  static const String _url =
      'wss://ep-live-mz-sa1-ae1-eg1-arab1-game.goodgamestudios.com/';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BG WS] onStart');
    await _save('STARTING');
    _connect();
  }

  Future<void> _save(String s) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('bg_ws_status', s);
      await p.setString('bg_ws_time', DateTime.now().toIso8601String());
      await p.setInt('bg_ws_msgs', _msgCount);
    } catch (_) {}
  }

  Future<void> _connect() async {
    try {
      debugPrint('[BG WS] connecting...');
      await _save('CONNECTING');

      final ws = await WebSocket.connect(_url)
          .timeout(const Duration(seconds: 20));

      _ws = ws;
      _connected = true;
      debugPrint('[BG WS] CONNECTED ✓');
      await _save('CONNECTED');

      // Send verChk — same as main app
      ws.add(
          '<msg t="sys"><body action="verChk" r="0"><ver v="166" /></body></msg>');

      _sub = ws.listen(
        (data) {
          _msgCount++;
          final text = data.toString();
          if (text.length < 80) {
            debugPrint('[BG WS] RX: $text');
          } else {
            debugPrint('[BG WS] RX: ${text.substring(0, 80)}...');
          }
          _save('MSG_$_msgCount');
        },
        onDone: () {
          debugPrint('[BG WS] disconnected');
          _connected = false;
          _save('DISCONNECTED');
        },
        onError: (e) {
          debugPrint('[BG WS] error: $e');
          _connected = false;
          _save('ERROR: $e');
        },
      );
    } catch (e) {
      debugPrint('[BG WS] connect failed: $e');
      _connected = false;
      await _save('CONNECT_FAILED: $e');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    debugPrint('[BG WS] heartbeat (connected=$_connected, msgs=$_msgCount)');
    _save('HEARTBEAT_$_msgCount');
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _sub?.cancel();
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _connected = false;
    debugPrint('[BG WS] destroyed');
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
        channelDescription: 'Keeps GGE Bot connected in the background',
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

      final service = await FlutterForegroundTask.startService(
        serviceId: 1001,
        notificationTitle: 'GGE Bot is active',
        notificationText: 'Watching for attacks in background...',
        callback: ggeBackgroundCallback,
      );

      _running = service != null;
      GgeClient.allowBackgroundReconnect = _running;
      TrafficLog.add('ST', '[BG] start → $_running');
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
}