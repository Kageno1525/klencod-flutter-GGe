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

  static StreamSubscription<AttackAlert>? _sub;
  static GgeClient? _subscribedClient;

  static final List<AttackAlert> _history = [];
  static final StreamController<List<AttackAlert>> _listCtrl =
      StreamController.broadcast();
  static Stream<List<AttackAlert>> get historyStream => _listCtrl.stream;
  static List<AttackAlert> get history => List.unmodifiable(_history);

  static bool _soundEnabled = true;
  static bool _enabled = true;
  static bool get soundEnabled => _soundEnabled;
  static bool get enabled => _enabled;

  /// Safe init — never hangs, never throws.
  static Future<void> init() async {
    try {
      // Load prefs
      try {
        final prefs = await SharedPreferences.getInstance()
            .timeout(const Duration(seconds: 2));
        _soundEnabled = prefs.getBool(_soundKey) ?? true;
        _enabled = prefs.getBool(_enabledKey) ?? true;
      } catch (e) {
        debugPrint('[Notifications] prefs load failed: $e');
      }

      // Initialize plugin
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const init = InitializationSettings(android: androidInit);
      await _plugin.initialize(init).timeout(const Duration(seconds: 3));
      debugPrint('[Notifications] plugin initialized');

      // Create channel
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      if (android != null) {
        try {
          await android
              .createNotificationChannel(const AndroidNotificationChannel(
                _channelId,
                'Attack Alerts',
                description: 'Notifications when someone attacks you',
                importance: Importance.max,
                playSound: true,
                enableVibration: true,
              ))
              .timeout(const Duration(seconds: 2));
          debugPrint('[Notifications] channel created');
        } catch (e) {
          debugPrint('[Notifications] channel create failed: $e');
        }

        // Request permission WITHOUT blocking main thread
        // This shows a dialog — we don't await it in the call chain
        unawaited(
          android
              .requestNotificationsPermission()
              .timeout(const Duration(seconds: 5),
                  onTimeout: () => false)
              .catchError((e) {
            debugPrint('[Notifications] permission request failed: $e');
            return false;
          }),
        );
      }
    } catch (e) {
      debugPrint('[Notifications] init error: $e');
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

    _history.insert(0, alert);
    if (_history.length > 100) {
      _history.removeRange(100, _history.length);
    }
    if (!_listCtrl.isClosed) _listCtrl.add(List.unmodifiable(_history));

    if (!_soundEnabled) return;

    final unitsLine = alert.units.isEmpty
        ? 'Movement detected'
        : alert.units
            .map((u) => '${u.displayName}: ${u.amount}')
            .take(3)
            .join(' · ');

    final bigText = '${alert.remainingLabel} · ${alert.kingdomName}\n'
        'From: ${alert.attackerName}'
        '${alert.attackerAlly != null ? " [${alert.attackerAlly}]" : ""}\n'
        'Total units: ${alert.totalUnits}\n$unitsLine';

    try {
      await _plugin.show(
        alert.movementId,
        '⚔️ Attack from ${alert.attackerName}',
        '${alert.remainingLabel} remaining · '
            '${alert.totalUnits > 0 ? "${alert.totalUnits} units" : ""}\n'
            '$unitsLine',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Attack Alerts',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            styleInformation: BigTextStyleInformation(bigText),
          ),
        ),
        payload: '${alert.movementId}',
      );
    } catch (e) {
      debugPrint('[Notifications] show failed: $e');
    }
  }

  static Future<void> dispose() async {
    stopListening();
    await _listCtrl.close();
  }
}