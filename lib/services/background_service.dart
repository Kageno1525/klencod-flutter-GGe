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

// ═══════════════════════════════════════════════════════════
//  Desert Model Classes (local, لتجنب dependencies في الـ isolate)
// ═══════════════════════════════════════════════════════════
class _DesertTower {
  final int x, y, kid;
  final double distance;
  final int as; // ✅ جديد
  final int rs; // ✅ جديد

  _DesertTower({
    required this.x, required this.y, required this.kid,
    required this.distance,
    this.as = 0, this.rs = 0,
  });

  String get key => '$x,$y,$kid';
  String get coordsLabel => '($x,$y)';

  // ✅ برج مدمر (نفس منطق الواجهة)
  bool get isDead => rs > 0 && rs < 100000;
}

class _DefenderWing {
  final int melee, ranged;
  _DefenderWing({required this.melee, required this.ranged});
  int get total => melee + ranged;
}

class _DesertSpyReport {
  final int messageId;
  final int targetX, targetY;
  final _DefenderWing left, middle, right;
  final int defensiveStrength;
  final int rs;
  _DesertSpyReport({
    required this.messageId, required this.targetX, required this.targetY,
    required this.left, required this.middle, required this.right,
    required this.defensiveStrength, required this.rs,
  });
  bool get isDead => rs > 0 && rs < 100000;
  int get totalEnemyUnits => left.total + middle.total + right.total;
}

class _XtMsg {
  final String cmd;
  final int result;
  final String? payload;
  _XtMsg(this.cmd, this.result, this.payload);
}

class _BgArmy {
  final List<List<int>> left, middle, right;
  final int total;
  _BgArmy({required this.left, required this.middle, required this.right, required this.total});
}

// ✅ نتيجة محاولة الهجوم
enum _AttackResult { success, lordBusy, noUnits, tooManyUnits, failed }

// ═══════════════════════════════════════════════════════════
@pragma('vm:entry-point')
void ggeBackgroundCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_GgeTaskHandler());
}

final _callbackRef = ggeBackgroundCallback;

class _GgeTaskHandler extends TaskHandler {
  // ═══ WS ═══
  WebSocket? _ws;
  StreamSubscription? _sub;
  Timer? _pollTimer;
  Timer? _trainTimer;
  Timer? _desertTimer;
  bool _connected = false;
  bool _loggedIn = false;
  String? _token;
  int? _mainCastleArea;

  // ═══ Desert state ═══
  int? _sourceAreaId;
  int? _sourceX, _sourceY, _sourceKid;
  final Map<String, List<Completer<_XtMsg>>> _pending = {};
  int? _latestSpyMessageId;
  final List<_DesertTower> _towers = [];
  final Map<String, DateTime> _cooldowns = {};
  final Map<String, DateTime> _failedTowers = {};
  DateTime? _lastScanAt;
  bool _desertEnabled = false;
  int _radiusTiles = 5;
  int _maxAttacksDay = 0;
  int _maxAttacksSession = 0;
  int _breakEvery = 0;
  int _breakMinutes = 15;
  int _attacksToday = 0;
  int _attacksThisSession = 0;
  String _attacksDate = '';
  Set<int> _rangedUnitIds = {};
  bool _runningDesert = false;

  // ✅ Cap tracking (زي الواجهة)
  final Map<String, int> _lastSuccessCaps = {};
  final Map<String, int> _lastFailCaps = {};

  // ═══ Anti-ban ═══
  DateTime _lastActionTime = DateTime.now();
  bool _isProcessing = false;
  DateTime? _nextBreakAt;
  int _actionsSinceBreak = 0;

  // ═══ ثوابت الهجوم التلقائي ═══
  static const int _kMinUnitsToAttack = 30;
  static const int _kMaxRadius = 50;
  static const int _kRadiusStep = 5;
  static const int _kInterAttackDelaySec = 15;
  static const int _kTowerSuccessCooldownHours = 4;
  static const int _kTowerDeadCooldownHours = 4;
  static const int _kTowerFailCooldownMin = 30;
  static const int _kTower313CooldownMin = 5;

  // ✅ مفاتيح cap
  static const String _kCapStartKey = 'desert_auto_cap_start';
  static const String _kCapMinKey = 'desert_auto_cap_min';
  static const String _kCapMaxKey = 'desert_auto_cap_max';
  static const String _kCapsOkKey = 'desert_cap_ok_v3';
  static const String _kCapsFailKey = 'desert_cap_fail_v3';

  static const String _url = 'wss://ep-live-mz-sa1-ae1-eg1-arab1-game.goodgamestudios.com/';
  static const String _gameServer = 'EmpireEx_34';

  void _log(String s) {
    debugPrint('[BG] $s');
    try { FlutterForegroundTask.sendDataToMain('LOG:$s'); } catch (_) {}
  }

  Future<void> _saveStatus(String status, {String? extra}) async {
    try {
      await FlutterForegroundTask.saveData(key: 'bg_status', value: status);
      await FlutterForegroundTask.saveData(key: 'bg_time', value: DateTime.now().toIso8601String());
      await FlutterForegroundTask.saveData(key: 'bg_extra', value: extra ?? '');
    } catch (_) {}
  }

  String _todayStr() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  // ═══════════════════════════════════════════════════════
  //  Lifecycle
  // ═══════════════════════════════════════════════════════
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _log('Service Started');
    await _saveStatus('STARTING');

    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('login_token');
    _mainCastleArea = prefs.getInt('main_castle_area');
    await _loadDesertState();

    _connect();
    _startAutoTrainTimer();
    _scheduleNextDesertTick();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _pollTimer?.cancel();
    _trainTimer?.cancel();
    _desertTimer?.cancel();
    await _persistDesertState();
    await _sub?.cancel();
    try { await _ws?.close(); } catch (_) {}
    _ws = null;
    _connected = false;
    _loggedIn = false;
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

  // ═══════════════════════════════════════════════════════
  //  Desert state persistence
  // ═══════════════════════════════════════════════════════
  Future<void> _loadDesertState() async {
    final prefs = await SharedPreferences.getInstance();
    _desertEnabled = prefs.getBool('desert_auto_enabled') ?? false;
    _radiusTiles = prefs.getInt('desert_radius_v2') ?? 5;
    _sourceAreaId = prefs.getInt('desert_source_v2') ?? 0;
    _maxAttacksDay = prefs.getInt('desert_bg_max_attacks_day') ?? 0;
    _maxAttacksSession = prefs.getInt('desert_bg_max_attacks_session') ?? 0;
    _breakEvery = prefs.getInt('desert_bg_break_every') ?? 0;
    _breakMinutes = prefs.getInt('desert_bg_break_minutes') ?? 15;
    _attacksToday = prefs.getInt('desert_bg_attacks_today') ?? 0;
    _attacksDate = prefs.getString('desert_bg_attacks_date') ?? '';
    _attacksThisSession = 0;

    final today = _todayStr();
    if (_attacksDate != today) {
      _attacksToday = 0;
      _attacksDate = today;
      await prefs.setInt('desert_bg_attacks_today', 0);
      await prefs.setString('desert_bg_attacks_date', today);
    }

    final catalogJson = prefs.getString('desert_bg_catalog_json');
    if (catalogJson != null && catalogJson.isNotEmpty) {
      try {
        final data = jsonDecode(catalogJson) as Map;
        _rangedUnitIds.clear();
        for (final e in data.entries) {
          final id = int.tryParse(e.key);
          if (id != null && e.value is Map) {
            final name = (e.value as Map)['displayName']?.toString() ?? '';
            if (_looksRanged(name)) _rangedUnitIds.add(id);
          }
        }
      } catch (e) { _log('catalog load: $e'); }
    }

    final cdJson = prefs.getString('desert_cooldowns_v1');
    if (cdJson != null && cdJson.isNotEmpty) {
      try {
        final data = jsonDecode(cdJson) as Map;
        final now = DateTime.now();
        _cooldowns.clear();
        for (final e in data.entries) {
          final dt = DateTime.tryParse(e.value.toString());
          if (dt != null && dt.isAfter(now)) _cooldowns[e.key] = dt;
        }
      } catch (_) {}
    }

    final ftJson = prefs.getString('desert_auto_failed_towers');
    if (ftJson != null && ftJson.isNotEmpty) {
      try {
        final data = jsonDecode(ftJson) as Map;
        final now = DateTime.now();
        _failedTowers.clear();
        for (final e in data.entries) {
          final dt = DateTime.tryParse(e.value.toString());
          if (dt != null && dt.isAfter(now)) _failedTowers[e.key] = dt;
        }
      } catch (_) {}
    }

    await _loadCaps();

    _log('Desert loaded: enabled=$_desertEnabled radius=$_radiusTiles srcArea=$_sourceAreaId '
         'attacksToday=$_attacksToday/$_maxAttacksDay session=$_maxAttacksSession '
         'caps=${_lastSuccessCaps.length}/ok ${_lastFailCaps.length}/fail');
  }

  Future<void> _persistDesertState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('desert_bg_attacks_today', _attacksToday);
    await prefs.setString('desert_bg_attacks_date', _attacksDate);

    final now = DateTime.now();
    final cdData = <String, String>{};
    for (final e in _cooldowns.entries) {
      if (e.value.isAfter(now)) cdData[e.key] = e.value.toIso8601String();
    }
    await prefs.setString('desert_cooldowns_v1', jsonEncode(cdData));

    final ftData = <String, String>{};
    for (final e in _failedTowers.entries) {
      if (e.value.isAfter(now)) ftData[e.key] = e.value.toIso8601String();
    }
    await prefs.setString('desert_auto_failed_towers', jsonEncode(ftData));
  }

  Future<void> _loadCaps() async {
    final p = await SharedPreferences.getInstance();
    try {
      final rawS = p.getString(_kCapsOkKey);
      if (rawS != null && rawS.isNotEmpty) {
        final data = jsonDecode(rawS) as Map;
        _lastSuccessCaps.clear();
        for (final e in data.entries) {
          _lastSuccessCaps[e.key] = (e.value as num).toInt();
        }
      }
      final rawF = p.getString(_kCapsFailKey);
      if (rawF != null && rawF.isNotEmpty) {
        final data = jsonDecode(rawF) as Map;
        _lastFailCaps.clear();
        for (final e in data.entries) {
          _lastFailCaps[e.key] = (e.value as num).toInt();
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCaps() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCapsOkKey, jsonEncode(_lastSuccessCaps));
    await p.setString(_kCapsFailKey, jsonEncode(_lastFailCaps));
  }

  bool _looksRanged(String name) {
    final n = name.toLowerCase();
    return n.contains('bow') || n.contains('archer') || n.contains('crossbow') ||
        n.contains('slinger') || n.contains('mangonel') || n.contains('trebuchet') ||
        n.contains('ballista') || n.contains('ranged') ||
        n.contains('قوس') || n.contains('نابل') || n.contains('رامي') ||
        n.contains('منجنيق') || n.contains('عرادة') || n.contains('قاذف');
  }

  // ═══════════════════════════════════════════════════════
  //  Anti-ban throttle
  // ═══════════════════════════════════════════════════════
  Future<void> _throttle({bool isAction = true}) async {
    if (!isAction) {
      await Future.delayed(Duration(milliseconds: 500 + Random().nextInt(700)));
      return;
    }

    if (_nextBreakAt != null) {
      final now = DateTime.now();
      if (now.isBefore(_nextBreakAt!)) {
        final wait = _nextBreakAt!.difference(now).inMilliseconds;
        if (wait > 0 && wait < 3600000) {
          _log('Break ${_nextBreakAt!.difference(now).inMinutes} min');
          await _saveStatus('ON_BREAK', extra: '${_nextBreakAt!.difference(now).inMinutes} min');
          await Future.delayed(Duration(milliseconds: wait));
        }
      }
      _nextBreakAt = null;
      _actionsSinceBreak = 0;
      await _saveStatus('ONLINE');
    }

    final now = DateTime.now();
    final diff = now.difference(_lastActionTime).inMilliseconds;
    if (diff < 5500) {
      final wait = 5500 - diff + Random().nextInt(1500);
      await Future.delayed(Duration(milliseconds: wait));
    } else {
      await Future.delayed(Duration(milliseconds: Random().nextInt(1000)));
    }
    _lastActionTime = DateTime.now();
    _actionsSinceBreak++;

    if (_breakEvery > 0 && _actionsSinceBreak >= _breakEvery) {
      _nextBreakAt = DateTime.now().add(Duration(minutes: _breakMinutes));
      _log('Break scheduled: $_breakMinutes min after $_actionsSinceBreak actions');
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Request-Response
  // ═══════════════════════════════════════════════════════
  Future<_XtMsg> _sendXtAndWaitAsync(
    String cmd,
    String payload, {
    required String responseCmd,
    int timeoutMs = 30000,
    bool isAction = false,
  }) async {
    final completer = Completer<_XtMsg>();
    _pending.putIfAbsent(responseCmd, () => []).add(completer);
    final timer = Timer(Duration(milliseconds: timeoutMs), () {
      if (!completer.isCompleted) {
        _pending[responseCmd]?.remove(completer);
        completer.completeError(TimeoutException('Timeout: $responseCmd'));
      }
    });
    await _throttle(isAction: isAction);
    _sendXt(cmd, payload);
    try {
      final resp = await completer.future;
      timer.cancel();
      return resp;
    } catch (e) {
      timer.cancel();
      rethrow;
    }
  }

  void _dispatchToPending(String raw) {
    final xt = _parseXt(raw);
    if (xt == null) return;
    final list = _pending[xt.cmd];
    if (list == null || list.isEmpty) return;
    final completer = list.removeAt(0);
    if (!completer.isCompleted) completer.complete(xt);
  }

  _XtMsg? _parseXt(String raw) {
    final trimmed = raw.replaceAll(RegExp(r'^%+|%+$'), '');
    final parts = trimmed.split('%');
    if (parts.length < 2 || parts[0] != 'xt') return null;
    int offset = 1;
    if (parts.length > 1 && parts[1].startsWith('EmpireEx_')) offset = 2;
    if (parts.length <= offset) return null;
    final cmd = parts[offset];
    final result = parts.length > offset + 2 ? (int.tryParse(parts[offset + 2]) ?? -1) : -1;
    final payload = parts.length > offset + 3 ? parts.sublist(offset + 3).join('%') : null;
    return _XtMsg(cmd, result, payload);
  }

  // ═══════════════════════════════════════════════════════
  //  WS
  // ═══════════════════════════════════════════════════════
  Future<void> _connect() async {
    try {
      _log('Connecting...');
      await _saveStatus('CONNECTING');
      _ws = await WebSocket.connect(_url).timeout(const Duration(seconds: 20));
      _connected = true;
      _log('WS Connected');
      _ws!.add('<msg t="sys"><body action="verChk" r="0"><ver v="166" /></body></msg>');
      _sub = _ws!.listen((data) => _onMessage(data.toString()),
        onDone: () { _connected = false; _loggedIn = false; _scheduleReconnect(); },
        onError: (_) { _connected = false; _loggedIn = false; _scheduleReconnect(); },
      );
    } catch (e) {
      _log('Connect error: $e');
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
    try { _ws?.add('%xt%$_gameServer%$cmd%1%$payload%'); } catch (_) {}
  }

  void _sendSys(String xml) {
    if (!_connected) return;
    try { _ws?.add(xml); } catch (_) {}
  }

  Future<void> _onMessage(String text) async {
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
        _log('Login OK');
        await _saveStatus('ONLINE');
        _runInit();
      } else {
        _log('Login FAILED');
        await _saveStatus('LOGIN_FAILED');
      }
    } else if (text.contains('bup%1%0%')) {
      _log('BUP OK');
    } else if (text.contains('bup%1%87%') || text.contains('bup%1%88%')) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('auto_last_train_time', DateTime.now().toIso8601String());
    }

    if (text.startsWith('%xt%')) {
      _dispatchToPending(text);
    }

    if (text.startsWith('%xt%') && text.contains('%sne%')) {
      try {
        final xt = _parseXt(text);
        if (xt?.payload != null) {
          final data = jsonDecode(xt!.payload!) as Map;
          final msgs = data['MSG'] as List?;
          if (msgs != null) {
            for (final m in msgs) {
              if (m is List && m.length >= 2) {
                final msgId = m[0] as int?;
                final type = m[1] as int?;
                if (msgId != null && type == 4) {
                  _latestSpyMessageId = msgId;
                  _log('Captured spy msgId=$msgId');
                }
              }
            }
          }
        }
      } catch (e) { _log('sne: $e'); }
    }
  }

  void _doLogin() {
    if (_token == null) { _log('No token'); return; }
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

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_loggedIn) _sendXt('pin', '<RoundHouseKick>');
    });
  }

  // ═══════════════════════════════════════════════════════
  //  Auto-train
  // ═══════════════════════════════════════════════════════
  void _startAutoTrainTimer() {
    _trainTimer?.cancel();
    _trainTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (!_loggedIn || _isProcessing) return;
      final prefs = await SharedPreferences.getInstance();
      final autoEnabled = prefs.getBool('auto_enabled') ?? false;
      if (!autoEnabled) return;
      final isAppForeground = prefs.getBool('is_app_foreground') ?? false;
      if (isAppForeground) return;

      final useMaxTotal = prefs.getBool('auto_use_max') ?? false;
      final maxTotal = int.tryParse(prefs.getString('auto_max_total') ?? '1000') ?? 1000;
      final totalTrained = prefs.getInt('auto_total_trained') ?? 0;
      if (useMaxTotal && totalTrained >= maxTotal) {
        await prefs.setBool('auto_enabled', false);
        return;
      }

      final triggerOnTime = prefs.getBool('auto_trigger_time') ?? false;
      final timeInterval = prefs.getInt('auto_time_interval') ?? 5;
      final timeUnit = prefs.getString('auto_time_unit') ?? 'minutes';
      final lastTrainStr = prefs.getString('auto_last_train_time');
      int intervalSeconds = timeInterval;
      if (timeUnit == 'minutes') intervalSeconds *= 60;
      if (timeUnit == 'hours') intervalSeconds *= 3600;
      bool timeTriggered = false;
      if (triggerOnTime) {
        if (lastTrainStr == null) timeTriggered = true;
        else {
          final last = DateTime.parse(lastTrainStr);
          if (DateTime.now().difference(last).inSeconds >= intervalSeconds) timeTriggered = true;
        }
      }

      final selectedJson = prefs.getString('auto_selected_units');
      if (selectedJson == null) return;
      final Map<String, dynamic> selected = jsonDecode(selectedJson);
      if (selected.isEmpty) return;
      final List<int> validWods = selected.keys.map((e) => int.parse(e)).toList();
      final currentIndex = prefs.getInt('auto_rotation_index') ?? 0;
      final wodId = validWods[currentIndex % validWods.length];
      final amount = selected[wodId.toString()] as int;
      final triggerOnSlot = prefs.getBool('auto_trigger_slot') ?? true;

      if (timeTriggered || triggerOnSlot) {
        _isProcessing = true;
        _log('AutoTrain WID=$wodId AMT=$amount');
        await _throttle();
        _sendXt('bup', jsonEncode({
          'LID': 0, 'WID': wodId, 'AMT': amount,
          'PO': -1, 'PWR': 0, 'SK': 0, 'SID': 0, 'AID': _mainCastleArea ?? 1606327,
        }));
        await prefs.setString('auto_last_train_time', DateTime.now().toIso8601String());
        await prefs.setInt('auto_total_trained', totalTrained + amount);
        await prefs.setInt('auto_rotation_index', currentIndex + 1);
        Future.delayed(const Duration(seconds: 3), () => _isProcessing = false);
      }
    });
  }

  // ═══════════════════════════════════════════════════════
  //  Desert loop — كل 30 ثانية
  // ═══════════════════════════════════════════════════════
  void _scheduleNextDesertTick() {
    const seconds = 30;
    _desertTimer = Timer(const Duration(seconds: seconds), () async {
      if (!_runningDesert && _loggedIn && _desertEnabled) {
        await _desertTick();
      }
      _scheduleNextDesertTick();
    });
  }

  Future<void> _desertTick() async {
    if (!_loggedIn || !_desertEnabled) return;
    if (_sourceAreaId == null || _sourceAreaId == 0) return;

    final today = _todayStr();
    if (_attacksDate != today) {
      _attacksToday = 0;
      _attacksDate = today;
      await _persistDesertState();
    }

    if (_maxAttacksDay > 0 && _attacksToday >= _maxAttacksDay) {
      await _saveStatus('LIMIT_REACHED', extra: 'يومي: $_attacksToday/$_maxAttacksDay');
      return;
    }
    if (_maxAttacksSession > 0 && _attacksThisSession >= _maxAttacksSession) {
      await _saveStatus('SESSION_LIMIT', extra: 'جلسة: $_attacksThisSession/$_maxAttacksSession');
      return;
    }

    _runningDesert = true;
    try {
      final kid = await _ensureKingdom();
      if (kid == null) {
        _log('Desert: jca failed');
        await _saveStatus('JCA_FAILED');
        return;
      }

      if (_towers.isEmpty) {
        await _scanTowersAt(kid, _radiusTiles);
      }

      final needsRescan = _lastScanAt == null ||
          DateTime.now().difference(_lastScanAt!).inMinutes >= 5;
      if (needsRescan && _towers.isNotEmpty) {
        await _scanTowersAt(kid, _kMaxRadius);
      }

      if (_towers.isEmpty) {
        await _saveStatus('NO_TOWERS');
        return;
      }

      int currentRadius = _radiusTiles;

      while (_runningDesert) {
        // 1. علّم الأبراج المدمرة بـ 4 ساعات
        final now = DateTime.now();
        bool changed = false;
        for (final t in _towers) {
          if (t.isDead && !_isTowerCooling(t)) {
            _cooldowns[t.key] = now.add(Duration(hours: _kTowerDeadCooldownHours));
            changed = true;
            _log('💀 ${t.coordsLabel} dead (rs=${t.rs}) → ${_kTowerDeadCooldownHours}h');
          }
        }
        if (changed) await _persistDesertState();

        // 2. فلترة الأبراج الجاهزة
        _towers.sort((a, b) => a.distance.compareTo(b.distance));
        final ready = _towers
            .where((t) => !_isTowerCooling(t) && !_isTowerFailed(t))
            .toList();

        if (ready.isEmpty) {
          if (currentRadius < _kMaxRadius) {
            currentRadius = min(currentRadius + _kRadiusStep, _kMaxRadius);
            await _saveStatus('RADIUS_UP', extra: '$currentRadius tiles');
            await _scanTowersAt(kid, currentRadius);
            continue;
          }
          await _saveStatus('ALL_COOLDOWN', extra: 'R=$_kMaxRadius');
          break;
        }

        await _saveStatus('READY', extra: '${ready.length} towers');

        // 3. اهجم على كل الأبراج الجاهزة
        bool stopTick = false;

        for (final tower in ready) {
          if (!_runningDesert) { stopTick = true; break; }
          if (_maxAttacksDay > 0 && _attacksToday >= _maxAttacksDay) { stopTick = true; break; }
          if (_maxAttacksSession > 0 && _attacksThisSession >= _maxAttacksSession) { stopTick = true; break; }

          await _saveStatus('ATTACKING', extra: tower.coordsLabel);
          final result = await _tryAttackTowerDirect(tower);

          if (result == _AttackResult.success) {
            _markTowerAttacked(tower);
            _attacksToday++;
            _attacksThisSession++;
            await _persistDesertState();
            await _saveStatus('ATTACK_HIT',
                extra: 'يومي: $_attacksToday/$_maxAttacksDay · جلسة: $_attacksThisSession/$_maxAttacksSession');
            _log('✅ ${tower.coordsLabel} → ${_kTowerSuccessCooldownHours}h cooldown');

            final delaySec = _kInterAttackDelaySec + Random().nextInt(5);
            _log('⏳ waiting ${delaySec}s before next attack');
            await Future.delayed(Duration(seconds: delaySec));

          } else if (result == _AttackResult.lordBusy) {
            await _saveStatus('WAITING_COMMANDER');
            _log('⏸️ Lord busy — will retry next tick');
            stopTick = true;
            break;

          } else if (result == _AttackResult.noUnits) {
            await _saveStatus('WAITING_UNITS');
            _log('⏸️ Not enough units — will retry next tick');
            stopTick = true;
            break;

          } else if (result == _AttackResult.tooManyUnits) {
            await _on313(tower);
            _markTowerFailed(tower, minutes: _kTower313CooldownMin);
            await Future.delayed(const Duration(seconds: 3));

          } else {
            _markTowerFailed(tower, minutes: _kTowerFailCooldownMin);
            _log('❌ ${tower.coordsLabel} failed → ${_kTowerFailCooldownMin}min');
          }
        }

        if (stopTick) break;

        // 4. خلّصنا الـ ready → كبّر radius وامسح تاني
        if (currentRadius < _kMaxRadius) {
          currentRadius = min(currentRadius + _kRadiusStep, _kMaxRadius);
          await _saveStatus('RADIUS_UP', extra: '$currentRadius tiles');
          await _scanTowersAt(kid, currentRadius);
          continue;
        }

        await _saveStatus('MAX_RADIUS_DONE', extra: '${_towers.length} towers');
        break;
      }

      await _persistDesertState();
    } catch (e) {
      _log('Desert tick error: $e');
      await _saveStatus('ERROR', extra: '$e');
    } finally {
      _runningDesert = false;
    }
  }

  Future<int?> _ensureKingdom() async {
    try {
      final resp = await _sendXtAndWaitAsync(
        'jca',
        jsonEncode({'CID': -1, 'KID': 1}),
        responseCmd: 'jaa',
        timeoutMs: 8000,
        isAction: false,
      );
      if (resp.result == 0 && resp.payload != null) {
        final data = jsonDecode(resp.payload!) as Map;
        final gca = data['gca'] as Map?;
        if (gca != null) {
          final a = gca['A'] as List?;
          if (a != null && a.length > 3) {
            _sourceX = int.tryParse(a[1].toString());
            _sourceY = int.tryParse(a[2].toString());
            _sourceKid = 1;
            return 1;
          }
        }
      }
    } catch (e) { _log('jca: $e'); }
    return null;
  }

  bool _isTowerCooling(_DesertTower t) {
    final dt = _cooldowns[t.key];
    if (dt == null) return false;
    if (dt.isBefore(DateTime.now())) { _cooldowns.remove(t.key); return false; }
    return true;
  }

  bool _isTowerFailed(_DesertTower t) {
    final dt = _failedTowers[t.key];
    if (dt == null) return false;
    if (dt.isBefore(DateTime.now())) { _failedTowers.remove(t.key); return false; }
    return true;
  }

  void _markTowerFailed(_DesertTower t, {int minutes = _kTowerFailCooldownMin}) {
    _failedTowers[t.key] = DateTime.now().add(Duration(minutes: minutes));
    _persistDesertState();
  }

  void _markTowerAttacked(_DesertTower t) {
    _cooldowns[t.key] = DateTime.now().add(Duration(hours: _kTowerSuccessCooldownHours));
    _persistDesertState();
  }

  // ═══════════════════════════════════════════════════════
  //  Cap management
  // ═══════════════════════════════════════════════════════
  Future<int> _capFor(_DesertTower t) async {
    final p = await SharedPreferences.getInstance();
    final start = p.getInt(_kCapStartKey) ?? 204;
    final minC = p.getInt(_kCapMinKey) ?? 204;
    final maxC = p.getInt(_kCapMaxKey) ?? 204;

    final s = _lastSuccessCaps[t.key];
    final f = _lastFailCaps[t.key];

    if (s == null && f == null) return start;
    if (s == null) {
      final next = f! - 20;
      return next < minC ? minC : (next > maxC ? maxC : next);
    }
    if (f == null) {
      final next = s + 15;
      return next > maxC ? maxC : next;
    }
    return s.clamp(minC, maxC);
  }

  Future<void> _onSuccess(_DesertTower t, int used) async {
    _lastSuccessCaps[t.key] = used;
    await _saveCaps();
  }

  Future<void> _on313(_DesertTower t) async {
    final cap = await _capFor(t);
    _lastFailCaps[t.key] = cap;
    await _saveCaps();
    _log('📉 ${t.coordsLabel} cap fail at $cap');
  }

  // ═══════════════════════════════════════════════════════
  //  Scan (merge + update)
  // ═══════════════════════════════════════════════════════
  Future<void> _scanTowersAt(int kid, int radius) async {
    if (_sourceX == null || _sourceY == null) return;
    _lastScanAt = DateTime.now();

    final cx = _sourceX!, cy = _sourceY!;
    const chunkSize = 13;

    final minX = (cx - radius).clamp(1, 1000);
    final maxX = (cx + radius).clamp(1, 1000);
    final minY = (cy - radius).clamp(1, 1000);
    final maxY = (cy + radius).clamp(1, 1000);
    final startX = (minX ~/ chunkSize) * chunkSize;
    final endX = (maxX ~/ chunkSize) * chunkSize;
    final startY = (minY ~/ chunkSize) * chunkSize;
    final endY = (maxY ~/ chunkSize) * chunkSize;

    final chunks = <List<int>>[];
    for (int x = startX; x <= endX; x += chunkSize) {
      for (int y = startY; y <= endY; y += chunkSize) {
        chunks.add([x, y, (x + chunkSize - 1).clamp(1, 1000), (y + chunkSize - 1).clamp(1, 1000)]);
      }
    }
    if (chunks.length > 40) chunks.removeRange(40, chunks.length);

    _log('Scan ${chunks.length} chunks @ r=$radius');
    await _saveStatus('SCANNING', extra: '0/${chunks.length}');

    int done = 0;
    int added = 0;
    for (final chunk in chunks) {
      try {
        final resp = await _sendXtAndWaitAsync(
          'gaa',
          jsonEncode({'KID': kid, 'AX1': chunk[0], 'AY1': chunk[1], 'AX2': chunk[2], 'AY2': chunk[3]}),
          responseCmd: 'gaa',
          timeoutMs: 15000,
          isAction: false,
        );
        if (resp.result == 0 && resp.payload != null) {
          final data = jsonDecode(resp.payload!) as Map;
          final ai = data['AI'] as List?;
          if (ai != null) {
            for (final entry in ai) {
              if (entry is! List || entry.length < 3) continue;
              if (int.tryParse(entry[0].toString()) != 2) continue;
              final x = int.tryParse(entry[1].toString()) ?? 0;
              final y = int.tryParse(entry[2].toString()) ?? 0;

              final asVal = entry.length > 3 ? (int.tryParse(entry[3].toString()) ?? 0) : 0;
              final rsVal = entry.length > 5 ? (int.tryParse(entry[5].toString()) ?? 0) : 0;

              final dx = (x - cx).toDouble();
              final dy = (y - cy).toDouble();
              final dist = sqrt(dx * dx + dy * dy);

              final idx = _towers.indexWhere((t) => t.x == x && t.y == y && t.kid == kid);
              if (idx >= 0) {
                _towers[idx] = _DesertTower(
                  x: x, y: y, kid: kid, distance: dist,
                  as: asVal, rs: rsVal,
                );
              } else {
                _towers.add(_DesertTower(
                  x: x, y: y, kid: kid, distance: dist,
                  as: asVal, rs: rsVal,
                ));
                added++;
              }
            }
          }
        }
      } catch (e) { _log('Scan chunk: $e'); }
      done++;
      await Future.delayed(Duration(milliseconds: 800 + Random().nextInt(400)));
      await _saveStatus('SCANNING', extra: '$done/${chunks.length} · ${_towers.length} towers');
    }
    _log('Scan r=$radius done: +$added new, total ${_towers.length}');
    await _saveStatus('SCAN_DONE', extra: '${_towers.length} towers (+$added @ r=$radius)');
  }

  // ═══════════════════════════════════════════════════════
  //  Attack
  // ═══════════════════════════════════════════════════════
  Future<_AttackResult> _tryAttackTowerDirect(_DesertTower tower) async {
    final units = await _fetchUnits();
    if (units.isEmpty) return _AttackResult.noUnits;

    final totalUnits = units.values.fold<int>(0, (s, v) => s + v);
    if (totalUnits < _kMinUnitsToAttack) return _AttackResult.noUnits;

    final cap = await _capFor(tower);
    final army = _buildArmyFromCap(units, cap);
    if (army == null || army.total <= 0) return _AttackResult.noUnits;

    try {
      final payload = {
        'SX': _sourceX, 'SY': _sourceY,
        'TX': tower.x, 'TY': tower.y,
        'KID': tower.kid, 'LID': 0,
        'WT': 0, 'HBW': -1, 'BPC': 0, 'ATT': 0, 'AV': 0,
        'LP': 0, 'FC': 0, 'PTT': 1, 'SD': 0, 'ICA': 0, 'CD': 99,
        'A': [{
          'L': {'T': [[-1, 0], [-1, 0]], 'U': _fill(army.left, 2)},
          'R': {'T': [[-1, 0], [-1, 0]], 'U': _fill(army.right, 2)},
          'M': {'T': [[-1, 0], [-1, 0], [-1, 0]], 'U': _fill(army.middle, 6)},
        }],
        'BKS': [], 'AST': [-1, -1, -1],
        'RW': List.generate(8, (_) => [-1, 0]),
        'ASCT': 0,
      };
      final resp = await _sendXtAndWaitAsync(
        'cra', jsonEncode(payload),
        responseCmd: 'cra', timeoutMs: 25000, isAction: true,
      );
      if (resp.result == 0) {
        await _onSuccess(tower, army.total);
        _log('✅ HIT ${tower.coordsLabel} (${army.total} units, cap=$cap)');
        return _AttackResult.success;
      }
      if (resp.result == 218) {
        _log('Lord busy 218');
        return _AttackResult.lordBusy;
      }
      if (resp.result == 313) {
        _log('Too many units 313 at cap=$cap');
        return _AttackResult.tooManyUnits;
      }
      _log('Attack ${tower.coordsLabel} failed: ${resp.result}');
      return _AttackResult.failed;
    } catch (e) {
      _log('Attack error ${tower.coordsLabel}: $e');
      return _AttackResult.failed;
    }
  }

  Future<Map<int, int>> _fetchUnits() async {
    try {
      final resp = await _sendXtAndWaitAsync(
        'gui', '{}',
        responseCmd: 'gui', timeoutMs: 10000, isAction: false,
      );
      if (resp.result == 0 && resp.payload != null) {
        final data = jsonDecode(resp.payload!) as Map;
        final i = data['I'] as List?;
        final units = <int, int>{};
        if (i != null) {
          for (final u in i) {
            if (u is List && u.length >= 2) {
              final id = int.tryParse(u[0].toString()) ?? 0;
              final amt = int.tryParse(u[1].toString()) ?? 0;
              if (id > 0 && amt > 0) units[id] = amt;
            }
          }
        }
        return units;
      }
    } catch (e) { _log('gui: $e'); }
    return {};
  }

  _BgArmy? _buildArmyFromCap(Map<int, int> available, int cap) {
    if (available.isEmpty || cap <= 0) return null;

    final flankMax = (cap * 0.2).round();
    final middleMax = cap - 2 * flankMax;

    final melee = <MapEntry<int, int>>[];
    final ranged = <MapEntry<int, int>>[];
    for (final e in available.entries) {
      if (_rangedUnitIds.contains(e.key)) {
        ranged.add(e);
      } else {
        melee.add(e);
      }
    }
    melee.sort((a, b) => b.value.compareTo(a.value));
    ranged.sort((a, b) => b.value.compareTo(a.value));

    final remaining = Map<int, int>.from(available);

    List<List<int>> alloc(int maxUnits, int maxSlots) {
      if (maxUnits <= 0 || maxSlots <= 0) return [];
      final out = <List<int>>[];
      final meleeTarget = (maxUnits * 0.5).round();
      final rangedTarget = maxUnits - meleeTarget;
      final meleeSlots = (maxSlots + 1) ~/ 2;
      final rangedSlots = maxSlots - meleeSlots;

      int meleeGot = 0, rangedGot = 0;
      int meleeUsed = 0, rangedUsed = 0;

      for (final e in melee) {
        if (meleeGot >= meleeTarget || meleeUsed >= meleeSlots) break;
        final rem = remaining[e.key] ?? 0;
        if (rem <= 0) continue;
        final take = (meleeTarget - meleeGot) < rem ? (meleeTarget - meleeGot) : rem;
        if (take <= 0) continue;
        out.add([e.key, take]);
        remaining[e.key] = rem - take;
        meleeGot += take;
        meleeUsed++;
      }

      for (final e in ranged) {
        if (rangedGot >= rangedTarget || rangedUsed >= rangedSlots) break;
        final rem = remaining[e.key] ?? 0;
        if (rem <= 0) continue;
        final take = (rangedTarget - rangedGot) < rem ? (rangedTarget - rangedGot) : rem;
        if (take <= 0) continue;
        out.add([e.key, take]);
        remaining[e.key] = rem - take;
        rangedGot += take;
        rangedUsed++;
      }

      return out;
    }

    final left = alloc(flankMax, 2);
    final middle = alloc(middleMax, 6);
    final right = alloc(flankMax, 2);

    Set<int> allTypes() => {
      ...left.map((e) => e[0]),
      ...middle.map((e) => e[0]),
      ...right.map((e) => e[0]),
    };
    while (allTypes().length > 10 && middle.isNotEmpty) middle.removeLast();
    while (allTypes().length > 10 && right.isNotEmpty) right.removeLast();
    while (allTypes().length > 10 && left.isNotEmpty) left.removeLast();

    final total = left.fold<int>(0, (s, e) => s + e[1]) +
        middle.fold<int>(0, (s, e) => s + e[1]) +
        right.fold<int>(0, (s, e) => s + e[1]);
    if (total == 0) return null;
    return _BgArmy(left: left, middle: middle, right: right, total: total);
  }

  List<List<int>> _fill(List<List<int>> units, int count) {
    final r = <List<int>>[];
    for (int i = 0; i < count; i++) {
      if (i < units.length && units[i][0] > 0 && units[i][1] > 0) {
        r.add([units[i][0], units[i][1]]);
      } else {
        r.add([-1, 0]);
      }
    }
    return r;
  }

  // ═══════════════════════════════════════════════════════
  //  Legacy spy flow (مش مستخدم — للرجوع لاحقاً)
  // ═══════════════════════════════════════════════════════
  Future<_DesertSpyReport?> _spyAndFetch(_DesertTower tower) async {
    _latestSpyMessageId = null;
    try {
      final resp = await _sendXtAndWaitAsync(
        'csm',
        jsonEncode({
          'SID': _sourceAreaId,
          'TX': tower.x, 'TY': tower.y,
          'SC': 11, 'ST': 0, 'SE': 100,
          'HBW': -1, 'KID': tower.kid, 'PTT': 1, 'SD': 0,
        }),
        responseCmd: 'csm',
        timeoutMs: 25000,
        isAction: true,
      );
      if (resp.result != 0) { _log('Spy failed: ${resp.result}'); return null; }
    } catch (e) { _log('Spy: $e'); return null; }

    int? msgId;
    for (int i = 0; i < 15; i++) {
      await Future.delayed(const Duration(seconds: 2));
      msgId = _latestSpyMessageId;
      if (msgId != null) break;
    }
    if (msgId == null) { _log('No sne'); return null; }

    try {
      _sendXt('mmr', jsonEncode({'MID': msgId}));
      await Future.delayed(const Duration(milliseconds: 300));
      final bsd = await _sendXtAndWaitAsync(
        'bsd', jsonEncode({'MID': msgId}),
        responseCmd: 'bsd', timeoutMs: 15000, isAction: false,
      );
      if (bsd.result != 0 || bsd.payload == null) { _log('bsd failed: ${bsd.result}'); return null; }
      return _parseBsd(bsd.payload!, msgId, tower);
    } catch (e) { _log('bsd: $e'); return null; }
  }

  _DesertSpyReport? _parseBsd(String payload, int messageId, _DesertTower tower) {
    try {
      final data = jsonDecode(payload) as Map;
      final s = data['S'] as List?;
      if (s == null || s.length < 3) return null;

      _DefenderWing parseWing(dynamic w) {
        int melee = 0, ranged = 0;
        if (w is List) {
          for (final u in w) {
            if (u is! List || u.length < 2) continue;
            final id = int.tryParse(u[0].toString()) ?? 0;
            final amt = int.tryParse(u[1].toString()) ?? 0;
            if (id <= 0 || amt <= 0) continue;
            if (_rangedUnitIds.contains(id)) ranged += amt;
            else melee += amt;
          }
        }
        return _DefenderWing(melee: melee, ranged: ranged);
      }

      return _DesertSpyReport(
        messageId: messageId,
        targetX: tower.x, targetY: tower.y,
        left: parseWing(s[0]),
        middle: parseWing(s[1]),
        right: parseWing(s[2]),
        defensiveStrength: int.tryParse(data['AS']?.toString() ?? '') ?? 0,
        rs: int.tryParse(data['RS']?.toString() ?? '') ?? 0,
      );
    } catch (e) { _log('parseBsd: $e'); return null; }
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
      final extra = await FlutterForegroundTask.getData<String>(key: 'bg_extra');
      return {'status': status ?? 'never ran', 'time': time ?? '?', 'extra': extra ?? ''};
    } catch (e) {
      return {'status': 'read error: $e', 'time': '?', 'extra': ''};
    }
  }
}