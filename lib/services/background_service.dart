import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Top-level callback (required by flutter_foreground_task).
/// Runs in a separate isolate, only job is to keep app alive.
@pragma('vm:entry-point')
void ggeBackgroundCallback() {
  FlutterForegroundTask.setTaskHandler(_GgeTaskHandler());
}

class _GgeTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BackgroundService] started');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Heartbeat — main isolate handles real work
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[BackgroundService] destroyed');
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
    debugPrint('[BackgroundService] initialized');
  }

  static Future<bool> start() async {
    if (_running) return true;
    try {
      await init();

      // Ask user to disable battery optimization (critical for OEMs like Xiaomi)
      try {
        final ignoring =
            await FlutterForegroundTask.isIgnoringBatteryOptimizations;
        if (!ignoring) {
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
      } catch (e) {
        debugPrint('[BackgroundService] battery opt request failed: $e');
      }

      final service = await FlutterForegroundTask.startService(
        serviceId: 1001,
        notificationTitle: 'GGE Bot is active',
        notificationText: 'Watching for attacks in background...',
        callback: ggeBackgroundCallback,
      );

      _running = service != null;
      debugPrint('[BackgroundService] start → $_running');
      return _running;
    } catch (e) {
      debugPrint('[BackgroundService] start failed: $e');
      return false;
    }
  }

  static Future<void> stop() async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('[BackgroundService] stop failed: $e');
    }
    _running = false;
  }

  static Future<void> updateStatus(String text) async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'GGE Bot is active',
        notificationText: text,
      );
    } catch (_) {}
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