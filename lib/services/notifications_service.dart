import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';

class NotificationsService {
  NotificationsService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'gge_attacks';
  static const _soundKey = 'notif_sound_enabled';
  static const _enabledKey = 'notif_enabled';
  static const _permissionAskedKey = 'notif_permission_asked';

  static StreamSubscription<AttackAlert>? _sub;
  static GgeClient? _subscribedClient;

  static final List<AttackAlert> _history = [];
  static final StreamController<List<AttackAlert>> _listCtrl =
      StreamController.broadcast();
  static Stream<List<AttackAlert>> get historyStream => _listCtrl.stream;
  static List<AttackAlert> get history => List.unmodifiable(_history);

  static bool _soundEnabled = true;
  static bool _enabled = true;
  static bool _permissionGranted = false;
  static bool _ready = false;

  static bool get soundEnabled => _soundEnabled;
  static bool get enabled => _enabled;
  static bool get permissionGranted => _permissionGranted;
  static bool get ready => _ready;

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 2));
      _soundEnabled = prefs.getBool(_soundKey) ?? true;
      _enabled = prefs.getBool(_enabledKey) ?? true;
    } catch (e) {
      debugPrint('[Notifications] prefs load failed: $e');
    }

    try {
      const androidInit =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const init = InitializationSettings(android: androidInit);
      await _plugin.initialize(init).timeout(const Duration(seconds: 3));

      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      if (android != null) {
        await android
            .createNotificationChannel(const AndroidNotificationChannel(
              _channelId,
              'Attack Alerts',
              description: 'Incoming attacks notifications',
              importance: Importance.max,
              playSound: true,
              enableVibration: true,
            ))
            .timeout(const Duration(seconds: 2));

        _permissionGranted =
            await android.areNotificationsEnabled() ?? false;
        debugPrint('[Notifications] permission granted: $_permissionGranted');
      }
      _ready = true;
    } catch (e) {
      debugPrint('[Notifications] init error: $e');
    }
  }

  static Future<bool> requestPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return false;

      final granted = await android
          .requestNotificationsPermission()
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      _permissionGranted = granted ?? false;

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_permissionAskedKey, true);
      } catch (_) {}

      debugPrint('[Notifications] permission result: $_permissionGranted');
      return _permissionGranted;
    } catch (e) {
      debugPrint('[Notifications] requestPermission failed: $e');
      return false;
    }
  }

  static Future<bool> hasAskedBefore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_permissionAskedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> checkPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return false;
      _permissionGranted =
          await android.areNotificationsEnabled() ?? false;
      return _permissionGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setSound(bool v) async {
    _soundEnabled = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_soundKey, v);
    } catch (_) {}
  }

  static Future<void> setEnabled(bool v) async {
    _enabled = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, v);
    } catch (_) {}
  }

  static void startListening() {
    final client = GgeClient();
    if (identical(_subscribedClient, client) && _sub != null) return;
    _sub?.cancel();
    _subscribedClient = client;
    _sub = client.attackStream.listen(_onAttack);
  }

  static void stopListening() {
    _sub?.cancel();
    _sub = null;
    _subscribedClient = null;
  }

  static void clearHistory() {
    _history.clear();
    if (!_listCtrl.isClosed) _listCtrl.add([]);
  }

  static Future<void> _onAttack(AttackAlert alert) async {
    if (!_enabled) return;
    if (!_ready) {
      debugPrint('[Notifications] plugin not ready — skipping');
      return;
    }

    _history.insert(0, alert);
    if (_history.length > 100) {
      _history.removeRange(100, _history.length);
    }
    if (!_listCtrl.isClosed) _listCtrl.add(List.unmodifiable(_history));

    final unitsLine = alert.units.isEmpty
        ? 'Movement detected'
        : alert.units
            .map((u) => '${u.displayName}: ${u.amount}')
            .take(3)
            .join(' · ');

    final bigText = '${alert.remainingLabel} · ${alert.kingdomName}\n'
        'From: ${alert.attackerName}'
        '${alert.attackerAlliance != null ? " [${alert.attackerAlliance}]" : ""}\n'
        'Total units: ${alert.totalUnits}\n$unitsLine';

    try {
      await _plugin.show(
        alert.movementId,
        '⚔️ Attack from ${alert.attackerName}',
        '${alert.remainingLabel} · '
            '${alert.totalUnits > 0 ? "${alert.totalUnits} units" : "movement"}',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Attack Alerts',
            importance: Importance.max,
            priority: Priority.high,
            playSound: _soundEnabled,
            enableVibration: _soundEnabled,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            styleInformation: BigTextStyleInformation(bigText),
            fullScreenIntent: false,
            autoCancel: true,
          ),
        ),
        payload: '${alert.movementId}',
      );
      debugPrint('[Notifications] shown for mid=${alert.movementId}');
    } catch (e) {
      debugPrint('[Notifications] show failed: $e');
    }
  }

  static Future<void> dispose() async {
    stopListening();
    await _listCtrl.close();
  }
}