import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';

@pragma('vm:entry-point')
void ggeBackgroundCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_GgeTaskHandler());
}

final _callbackRef = ggeBackgroundCallback;

class _GgeTaskHandler extends TaskHandler {
  WebSocket? _ws;
  StreamSubscription? _sub;
  Timer? _pollTimer;
  Timer? _trainTimer;
  bool _connected = false;
  bool _loggedIn = false;
  String? _token;
  int? _mainCastleArea;

  // ═══ Anti-Ban Variables ═══
  DateTime _lastActionTime = DateTime.now();
  bool _isProcessing = false;

  static const String _url = 'wss://ep-live-mz-sa1-ae1-eg1-arab1-game.goodgamestudios.com/';
  static const String _gameServer = 'EmpireEx_34';

  void _log(String s) {
    debugPrint('[BG] $s');
    try {
      FlutterForegroundTask.sendDataToMain('LOG:$s');
    } catch (_) {}
  }

  Future<void> _saveStatus(String status) async {
    try {
      await FlutterForegroundTask.saveData(key: 'bg_status', value: status);
      await FlutterForegroundTask.saveData(key: 'bg_time', value: DateTime.now().toIso8601String());
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════
  //  Anti-Ban Throttle
  // ═══════════════════════════════════════════════════════
  Future<void> _throttle() async {
    final now = DateTime.now();
    final diff = now.difference(_lastActionTime).inMilliseconds;
    if (diff < 5500) { // 5.5 ثانية تأخير
      final wait = 5500 - diff + Random().nextInt(1500);
      await Future.delayed(Duration(milliseconds: wait));
    } else {
      await Future.delayed(Duration(milliseconds: Random().nextInt(1000)));
    }
    _lastActionTime = DateTime.now();
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _log('Service Started');
    await _saveStatus('STARTING');
    
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('login_token');
    _mainCastleArea = prefs.getInt('main_castle_area');

    _connect();
    _startAutoTrainTimer();
  }

  // ═══════════════════════════════════════════════════════
  //  Auto Train Logic (Background)
  // ═══════════════════════════════════════════════════════
  void _startAutoTrainTimer() {
    _trainTimer?.cancel();
    // كل 10 ثواني نشيك على الإعدادات
    _trainTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (!_loggedIn || _isProcessing) return;

      final prefs = await SharedPreferences.getInstance();
      final autoEnabled = prefs.getBool('auto_enabled') ?? false;
      if (!autoEnabled) return;

      // ✅ Anti-Ban: التأكد إن التطبيق في الخلفية (عشان ميعملش تعارض)
      final isAppForeground = prefs.getBool('is_app_foreground') ?? false;
      if (isAppForeground) return;

      // 1. التحقق من أقصى عدد
      final useMaxTotal = prefs.getBool('auto_use_max') ?? false;
      final maxTotal = int.tryParse(prefs.getString('auto_max_total') ?? '1000') ?? 1000;
      final totalTrained = prefs.getInt('auto_total_trained') ?? 0;
      
      if (useMaxTotal && totalTrained >= maxTotal) {
         await prefs.setBool('auto_enabled', false);
         _log('AutoTrain: Reached max total.');
         return;
      }

      // 2. التحقق من الوقت
      final triggerOnTime = prefs.getBool('auto_trigger_time') ?? false;
      final timeInterval = prefs.getInt('auto_time_interval') ?? 5;
      final timeUnit = prefs.getString('auto_time_unit') ?? 'minutes';
      final lastTrainStr = prefs.getString('auto_last_train_time');
      
      int intervalSeconds = timeInterval;
      if (timeUnit == 'minutes') intervalSeconds *= 60;
      if (timeUnit == 'hours') intervalSeconds *= 3600;

      bool timeTriggered = false;
      if (triggerOnTime) {
        if (lastTrainStr == null) {
          timeTriggered = true;
        } else {
          final lastTrain = DateTime.parse(lastTrainStr);
          if (DateTime.now().difference(lastTrain).inSeconds >= intervalSeconds) {
            timeTriggered = true;
          }
        }
      }

      // 3. اختيار الوحدة
      final selectedJson = prefs.getString('auto_selected_units');
      if (selectedJson == null) return;
      final Map<String, dynamic> selected = jsonDecode(selectedJson);
      if (selected.isEmpty) return;

      final List<int> validWods = selected.keys.map((e) => int.parse(e)).toList();
      final currentIndex = prefs.getInt('auto_rotation_index') ?? 0;
      final wodId = validWods[currentIndex % validWods.length];
      final amount = selected[wodId.toString()] as int;

      // 4. التحقق من الخانات
      final triggerOnSlot = prefs.getBool('auto_trigger_slot') ?? true;
      bool slotTriggered = false;
      
      if (triggerOnSlot) {
        slotTriggered = true; // نفترض إننا هنبعت، والسيرفر هيقولنا لو الخانات مليانة
      }

      if (timeTriggered || slotTriggered) {
        _isProcessing = true;
        _log('AutoTrain: Attempting WID=$wodId AMT=$amount');
        
        await _throttle(); // ✅ التأخير العشوائي قبل الإرسال

        _sendXt('bup', jsonEncode({
          'LID': 0, 'WID': wodId, 'AMT': amount,
          'PO': -1, 'PWR': 0, 'SK': 0, 'SID': 0, 'AID': _mainCastleArea ?? 1606327
        }));

        // تحديث البيانات فوراً عشان ميعملش سبام
        await prefs.setString('auto_last_train_time', DateTime.now().toIso8601String());
        await prefs.setInt('auto_total_trained', totalTrained + amount);
        await prefs.setInt('auto_rotation_index', currentIndex + 1);
        
        // هنخليها تخلص بعد شوية
        Future.delayed(const Duration(seconds: 3), () {
          _isProcessing = false;
        });
      }
    });
  }

  // ═══════════════════════════════════════════════════════
  //  WebSocket & Login Logic
  // ═══════════════════════════════════════════════════════
  Future<void> _connect() async {
    try {
      _log('Connecting WS...');
      await _saveStatus('CONNECTING');
      _ws = await WebSocket.connect(_url).timeout(const Duration(seconds: 20));
      _connected = true;
      _log('WS Connected');
      
      _ws!.add('<msg t="sys"><body action="verChk" r="0"><ver v="166" /></body></msg>');

      _sub = _ws!.listen((data) {
        _onMessage(data.toString());
      }, onDone: () {
        _connected = false;
        _loggedIn = false;
        _scheduleReconnect();
      }, onError: (e) {
        _connected = false;
        _loggedIn = false;
        _scheduleReconnect();
      });
    } catch (e) {
      _log('Connect Error: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    Future.delayed(const Duration(seconds: 10), () {
      if (!_connected) _connect();
    });
  }

  void _sendXt(String cmd, String payload) {
    if (!_connected) return;
    final msg = '%xt%$_gameServer%$cmd%1%$payload%';
    try { _ws?.add(msg); } catch (_) {}
  }

  void _sendSys(String xml) {
    if (!_connected) return;
    try { _ws?.add(xml); } catch (_) {}
  }

  void _onMessage(String text) {
    if (text.contains('apiOK')) {
      _sendSys('<msg t="sys"><body action="login" r="0"><login z="$_gameServer"><nick><![CDATA[]]></nick><pword><![CDATA[undefined%en%0]]></pword></login></body></msg>');
    } else if (text.contains('joinOK')) {
      _sendSys('<msg t="sys"><body action="roundTrip" r="1"></body></msg>');
      final rand = Random().nextDouble() * 9e307;
      _sendXt('vck', 'undefined%web-html5%<RoundHouseKick>%${rand.toStringAsExponential(16)}');
    } else if (text.startsWith('%xt%') && text.contains('%vck%')) {
      _doLogin();
    } else if (text.startsWith('%xt%') && text.contains('%lli%')) {
      if (text.contains('%lli%1%0%')) {
        _loggedIn = true;
        _log('Login Successful');
        _saveStatus('ONLINE');
        _runInit();
      } else {
        _log('Login Failed: $text');
        _saveStatus('LOGIN_FAILED');
      }
    } else if (text.startsWith('%xt%') && text.contains('%jaa%')) {
      try {
        final parts = text.split('%');
        final payload = parts.length > 4 ? parts.sublist(4).join('%') : '';
        final data = jsonDecode(payload);
        final gca = data['gca'] as Map?;
        if (gca != null) {
          final a = gca['A'] as List?;
          if (a != null && a.length > 3) {
            _mainCastleArea = int.tryParse(a[3].toString());
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt('main_castle_area', _mainCastleArea ?? 0);
          }
        }
      } catch (_) {}
    } else if (text.contains('bup%1%0%')) {
      _log('BUP SUCCESS!');
    } else if (text.contains('bup%1%87%') || text.contains('bup%1%88%')) {
      _log('BUP FAILED (Missing building or full slots). Backing off.');
      final prefs = await SharedPreferences.getInstance();
      // لو فشل، بنأخر التدريب الجاي دقيقة عشان ميعملش سبام
      await prefs.setString('auto_last_train_time', DateTime.now().toIso8601String());
    }
  }

  void _doLogin() {
    if (_token == null) {
      _log('No token available for login');
      return;
    }
    
    _sendXt('lli', jsonEncode({
      'CONM': 350, 'RTM': 57, 'ID': 0, 'PL': 1,
      'NOM': 'User', 'LT': _token, 'LANG': 'en', 'DID': '0',
      'AID': '17254677223212351', 'KID': '', 'REF': 'https://empire.goodgamestudios.com',
      'GCI': '', 'SID': 9, 'PLFID': 1,
    }));
  }

  void _runInit() {
    _sendXt('nch', '');
    Future.delayed(const Duration(seconds: 1), () => _sendXt('gbl', '{}'));
    Future.delayed(const Duration(seconds: 2), () => _sendXt('jca', '{"CID":-1,"KID":0}'));
    Future.delayed(const Duration(seconds: 3), () => _sendXt('sli', '{}'));
    Future.delayed(const Duration(seconds: 4), () => _sendXt('gie', '{}'));
    Future.delayed(const Duration(seconds: 5), () => _sendXt('asc', '{}'));
    Future.delayed(const Duration(seconds: 6), () => _sendXt('sie', '{}'));
    Future.delayed(const Duration(seconds: 7), () => _sendXt('ffi', '{"FIDS":[1]}'));
    
    // ✅ Pin كل 60 ثانية فقط للحفاظ على الاتصال ومنع البان
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_loggedIn) _sendXt('pin', '<RoundHouseKick>');
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _pollTimer?.cancel();
    _trainTimer?.cancel();
    await _sub?.cancel();
    try { await _ws?.close(); } catch (_) {}
    _ws = null;
    _connected = false;
    _loggedIn = false;
    await _saveStatus('DESTROYED');
  }

  @override
  void onReceiveData(Object data) {}
  @override
  void onNotificationButtonPressed(String id) {}
  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp('/');
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
        channelDescription: 'Keeps GGE Bot connected & trains',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
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
      unawaited(FlutterForegroundTask.isIgnoringBatteryOptimizations.then((ignoring) async {
        if (!ignoring) {
          try { await FlutterForegroundTask.requestIgnoreBatteryOptimization(); } catch (_) {}
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
    try { await FlutterForegroundTask.stopService(); } catch (_) {}
    _running = false;
    GgeClient.allowBackgroundReconnect = false;
  }

  static Future<Map<String, dynamic>> readStatus() async {
    try {
      final status = await FlutterForegroundTask.getData<String>(key: 'bg_status');
      final time = await FlutterForegroundTask.getData<String>(key: 'bg_time');
      return {'status': status ?? 'never ran', 'time': time ?? '?'};
    } catch (e) {
      return {'status': 'read error: $e', 'time': '?'};
    }
  }
}