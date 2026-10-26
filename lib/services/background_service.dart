import 'dart:async';                                 // ═══ NEW: needed for unawaited ═══
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../gge_client.dart';

@pragma('vm:entry-point')
void ggeBackgroundCallback() {
  FlutterForegroundTask.setTaskHandler(_GgeTaskHandler());
}

class _GgeTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BackgroundService] started');
    TrafficLog.add('ST', '[BG] service started');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[BackgroundService] destroyed');
    TrafficLog.add('ST', '[BG] service destroyed');
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

      // Request battery exemption — DON'T await (dialog can block)
      unawaited(
        FlutterForegroundTask.isIgnoringBatteryOptimizations
            .then((ignoring) async {
          if (!ignoring) {
            try {
              await FlutterForegroundTask
                  .requestIgnoreBatteryOptimization();
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