import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════
//  Desert Model (local — same logic as UI)
// ═══════════════════════════════════════════════════════════
class _DesertTower {
  final int x, y, kid;
  final double distance;
  final int as; // attack strength
  final int rs; // defense strength (rs > 0 && rs < 100000 => dead)
  _DesertTower({
    required this.x, required this.y, required this.kid,
    required this.distance, this.as = 0, this.rs = 0,
  });
  String get key => '$x,$y,$kid';
  String get coordsLabel => '($x,$y)';
  bool get isDead => rs > 0 && rs < 100000;
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

enum _AttackResult { success, lordBusy, failed }

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

  final List<_DesertTower> _towers = [];
  final Map<String, DateTime> _cooldowns = {};   // 4h after success or dead
  final Map<String, DateTime> _failedTowers = {}; // 4h after failure
  final Map<String, DateTime> _tempSkip = {};     // 30s on 218 (lord busy)
  final Map<String, int> _successCaps = {};
  final Map<String, int> _failCaps = {};

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
  bool _runningDesert = false;

  // cap values (same keys as UI)
  int _capStart = 204, _capMin = 204, _capMax = 204;

  // ═══ Anti-ban ═══
  DateTime _lastActionTime = DateTime.now();
  bool _isProcessing = false;
  DateTime? _nextBreakAt;
  int _actionsSinceBreak = 0;

  static const String _url = 'wss://ep-live-mz-sa1-ae1-eg1-arab1-game.goodgamestudios.com/';
  static const String _gameServer = 'EmpireEx_34';
  static const int _maxRadius = 50;
  static const int _radiusStep = 5;
  static const int _interAttackDelaySec = 15;
  static const int _minUnitsToAttack = 30;
  static const int _towerCooldownMin = 240; // 4 hours

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

    // Kick the desert loop shortly after connect
    Future.delayed(const Duration(seconds: 8), () {
      if (_desertEnabled && _loggedIn && !_runningDesert) _desertTick();
    });
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
  //  Load / Persist state
  // ═══════════════════════════════════════════════════════
  Future<void> _loadDesertState() async {
    final prefs = await SharedPreferences.getInstance();
    _desertEnabled = prefs.getBool('desert_auto_enabled') ?? false;
    _radiusTiles = prefs.getInt('desert_radius_v2') ?? 5;
    if (_radiusTiles < 5) _radiusTiles = 5;
    if (_radiusTiles > _maxRadius) _radiusTiles = _maxRadius;
    _sourceAreaId = prefs.getInt('desert_source_v2') ?? 0;
    _maxAttacksDay = prefs.getInt('desert_bg_max_attacks_day') ?? 0;
    _maxAttacksSession = prefs.getInt('desert_bg_max_attacks_session') ?? 0;
    _breakEvery = prefs.getInt('desert_bg_break_every') ?? 0;
    _breakMinutes = prefs.getInt('desert_bg_break_minutes') ?? 15;
    _attacksToday = prefs.getInt('desert_bg_attacks_today') ?? 0;
    _attacksDate = prefs.getString('desert_bg_attacks_date') ?? '';
    _attacksThisSession = 0;

    _capStart = prefs.getInt('desert_auto_cap_start') ?? 204;
    _capMin = prefs.getInt('desert_auto_cap_min') ?? 204;
    _capMax = prefs.getInt('desert_auto_cap_max') ?? 204;

    final today = _todayStr();
    if (_attacksDate != today) {
      _attacksToday = 0;
      _attacksDate = today;
      await prefs.setInt('desert_bg_attacks_today', 0);
      await prefs.setString('desert_bg_attacks_date', today);
    }

    // cooldowns
    final cdJson = prefs.getString('desert_cooldowns_v1');
    if (cdJson != null && cdJson.isNotEmpty) {
      try {
        final data = jsonDecode(cdJson) as Map;
        final now = DateTime.now();
        for (final e in data.entries) {
          final dt = DateTime.tryParse(e.value.toString());
          if (dt != null && dt.isAfter(now)) _cooldowns[e.key] = dt;
        }
      } catch (_) {}
    }

    // failed towers
    final ftJson = prefs.getString('desert_auto_failed_towers');
    if (ftJson != null && ftJson.isNotEmpty) {
      try {
        final data = jsonDecode(ftJson) as Map;
        final now = DateTime.now();
        for (final e in data.entries) {
          final dt = DateTime.tryParse(e.value.toString());
          if (dt != null && dt.isAfter(now)) _failedTowers[e.key] = dt;
        }
      } catch (_) {}
    }

    // caps
    final rawS = prefs.getString('desert_cap_ok_v3');
    if (rawS != null && rawS.isNotEmpty) {
      try {
        final data = jsonDecode(rawS) as Map;
        _successCaps.clear();
        for (final e in data.entries) {
          _successCaps[e.key] = (e.value as num).toInt();
        }
      } catch (_) {}
    }
    final rawF = prefs.getString('desert_cap_fail_v3');
    if (rawF != null && rawF.isNotEmpty) {
      try {
        final data = jsonDecode(rawF) as Map;
        _failCaps.clear();
        for (final e in data.entries) {
          _failCaps[e.key] = (e.value as num).toInt();
        }
      } catch (_) {}
    }

    _log('Desert loaded: enabled=$_desertEnabled radius=$_radiusTiles '
        'srcArea=$_sourceAreaId caps=$_capStart/$_capMin/$_capMax '
        'attacksToday=$_attacksToday/$_maxAttacksDay');
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

    await prefs.setString('desert_cap_ok_v3', jsonEncode(_successCaps));
    await prefs.setString('desert_cap_fail_v3', jsonEncode(_failCaps));
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
    }
  }

  // ═══════════════════════════════════════════════════════
  //  XT request / response
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
      _sub = _ws!.listen(
        (data) => _onMessage(data.toString()),
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
        // Trigger desert loop after login
        Future.delayed(const Duration(seconds: 5), () {
          if (_desertEnabled && _loggedIn && !_runningDesert) _desertTick();
        });
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

    if (text.startsWith('%xt%')) _dispatchToPending(text);
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
  //  Auto-train (unchanged)
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
  //  Desert loop scheduler — safety net every 2 min
  // ═══════════════════════════════════════════════════════
  void _scheduleNextDesertTick() {
    _desertTimer = Timer(const Duration(minutes: 2), () async {
      if (!_runningDesert && _desertEnabled && _loggedIn) {
        await _desertTick();
      }
      _scheduleNextDesertTick();
    });
  }

  // ═══════════════════════════════════════════════════════
  //  MAIN DESERT LOOP
  // ═══════════════════════════════════════════════════════
  Future<void> _desertTick() async {
    if (_runningDesert) return;
    if (!_loggedIn || !_desertEnabled) return;
    if (_sourceAreaId == null || _sourceAreaId == 0) {
      _log('Desert: no source area');
      return;
    }

    _runningDesert = true;
    try {
      // Daily reset
      final today = _todayStr();
      if (_attacksDate != today) {
        _attacksToday = 0;
        _attacksDate = today;
        await _persistDesertState();
      }

      // Resolve source position
      final kid = await _ensureKingdom();
      if (kid == null) {
        _log('Desert: jca failed, retry next tick');
        return;
      }

      // Initial scan
      if (_towers.isEmpty) {
        await _scanTowers(kid);
      }
      if (_towers.isEmpty) return;

      _radiusTiles = _radiusTiles.clamp(5, _maxRadius);

      int loops = 0;
      while (_desertEnabled && _loggedIn) {
        loops++;

        // Hard limits
        if (_maxAttacksDay > 0 && _attacksToday >= _maxAttacksDay) {
          await _saveStatus('LIMIT_REACHED', extra: 'يومي: $_attacksToday/$_maxAttacksDay');
          return;
        }
        if (_maxAttacksSession > 0 && _attacksThisSession >= _maxAttacksSession) {
          await _saveStatus('SESSION_LIMIT', extra: 'جلسة: $_attacksThisSession/$_maxAttacksSession');
          return;
        }

        // 1. Dead towers → 4h cooldown
        for (final t in _towers) {
          if (t.isDead && !_isTowerCooling(t) && !_isTowerFailed(t)) {
            _cooldowns[t.key] = DateTime.now().add(const Duration(minutes: _towerCooldownMin));
            _log('💀 dead ${t.coordsLabel} rs=${t.rs} → 4h');
          }
        }

        // 2. Available candidates
        final available = _towers.where((t) =>
            !t.isDead &&
            !_isTowerCooling(t) &&
            !_isTowerFailed(t) &&
            !_isTempSkipped(t)).toList()
          ..sort((a, b) => a.distance.compareTo(b.distance));

        // 3. Nothing available → wait or expand
        if (available.isEmpty) {
          await _persistDesertState();

          final tempMs = _soonestTempSkipMs();
          if (tempMs > 0 && tempMs <= 30000) {
            _log('All towers temp-skipped, wait ${tempMs}ms');
            await _saveStatus('WAIT_LORD', extra: '${(tempMs / 1000).ceil()}s');
            await Future.delayed(Duration(milliseconds: tempMs + 500));
            continue;
          }

          // Expand radius
          _radiusTiles += _radiusStep;
          if (_radiusTiles > _maxRadius) {
            _radiusTiles = _maxRadius;
            final waitMs = _timeUntilNextCooldownExpiry();
            if (waitMs > 0) {
              await _saveStatus('MAX_RADIUS', extra: 'انتظار ${(waitMs / 60000).ceil()} دقيقة');
              await _waitForCooldownExpiry();
              if (!_desertEnabled || !_loggedIn) return;
            }
            _radiusTiles = 5;
          }

          await _saveStatus('RESCAN', extra: 'radius=$_radiusTiles');
          _log('Rescanning at radius=$_radiusTiles');
          final newKid = await _ensureKingdom();
          if (newKid != null) {
            await _scanTowers(newKid);
          }
          await Future.delayed(const Duration(seconds: _interAttackDelaySec));
          continue;
        }

        // 4. Check units
        final units = await _fetchUnits();
        final totalUnits = units.values.fold<int>(0, (s, v) => s + v);
        if (totalUnits < _minUnitsToAttack) {
          await _saveStatus('LOW_UNITS', extra: '$totalUnits/$_minUnitsToAttack');
          _log('Low units ($totalUnits), wait 2min');
          await Future.delayed(const Duration(minutes: 2));
          continue;
        }

        // 5. Attack the closest
        final tower = available.first;
        await _saveStatus('ATTACKING', extra: tower.coordsLabel);
        _log('▶ Attacking ${tower.coordsLabel} (${available.length} left in current radius)');

        final cap = _capForTower(tower);
        final army = _buildArmy(units, cap);
        if (army == null || army.total == 0) {
          _log('Army build failed, mark ${tower.coordsLabel} failed');
          _markTowerFailed(tower);
          await _persistDesertState();
          await Future.delayed(const Duration(seconds: _interAttackDelaySec));
          continue;
        }

        final result = await _sendAttack(tower, army);

        switch (result) {
          case _AttackResult.success:
            _attacksToday++;
            _attacksThisSession++;
            _markTowerAttacked(tower);
            _successCaps[tower.key] = army.total;
            await _persistDesertState();
            await _saveStatus('HIT ${tower.coordsLabel}',
                extra: 'يومي: $_attacksToday/$_maxAttacksDay · جلسة: $_attacksThisSession/$_maxAttacksSession');
            _log('✅ HIT ${tower.coordsLabel} units=${army.total}');
            break;

          case _AttackResult.lordBusy:
            // Temp skip 30s, no 4h cooldown
            _tempSkip[tower.key] = DateTime.now().add(const Duration(seconds: 30));
            _failCaps[tower.key] = army.total;
            await _saveStatus('LORD_BUSY', extra: tower.coordsLabel);
            _log('⏸ ${tower.coordsLabel}: lord busy, temp-skip 30s');
            break;

          case _AttackResult.failed:
            // Check if it was a 313 (too many units)
            // We detect via _lastAttackError in _sendAttack
            if (_lastAttackErr313) {
              _failCaps[tower.key] = army.total;
              final nextCap = _capForTower(tower);
              if (army.total <= _capMin) {
                _failedTowers[tower.key] = DateTime.now().add(const Duration(hours: 24));
                _log('💀 ${tower.coordsLabel}: cap min hit, 24h');
              } else {
                _log('📉 ${tower.coordsLabel}: 313, cap→$nextCap');
              }
            } else {
              _markTowerFailed(tower);
            }
            await _persistDesertState();
            await _saveStatus('FAILED', extra: tower.coordsLabel);
            break;
        }

        // 6. Wait 15s between attacks
        await Future.delayed(const Duration(seconds: _interAttackDelaySec));
      }
    } catch (e) {
      _log('Desert loop fatal: $e');
      await _saveStatus('ERROR', extra: '$e');
    } finally {
      _runningDesert = false;
    }
  }

  bool _lastAttackErr313 = false;

  Future<_AttackResult> _sendAttack(_DesertTower tower, _BgArmy army) async {
    _lastAttackErr313 = false;
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
        // Verify a real movement was created (avoid "no battle" being counted as success)
        if (resp.payload != null) {
          try {
            final data = jsonDecode(resp.payload!) as Map;
            final a = data['A'] as Map?;
            final m = a?['M'] as Map?;
            final mid = int.tryParse((m?['MID'] ?? '').toString()) ?? 0;
            if (mid > 0) return _AttackResult.success;
          } catch (_) {}
        }
        // result==0 but no MID → tower was dead / no battle
        _log('No MID in cra response → tower is dead');
        return _AttackResult.failed;
      }
      if (resp.result == 313) {
        _lastAttackErr313 = true;
        return _AttackResult.failed;
      }
      if (resp.result == 218) return _AttackResult.lordBusy;
      return _AttackResult.failed;
    } catch (e) {
      _log('Attack error: $e');
      return _AttackResult.failed;
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Helpers
  // ═══════════════════════════════════════════════════════
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

  bool _isTempSkipped(_DesertTower t) {
    final dt = _tempSkip[t.key];
    if (dt == null) return false;
    if (dt.isBefore(DateTime.now())) { _tempSkip.remove(t.key); return false; }
    return true;
  }

  void _markTowerAttacked(_DesertTower t) {
    _cooldowns[t.key] = DateTime.now().add(const Duration(minutes: _towerCooldownMin));
  }

  void _markTowerFailed(_DesertTower t) {
    _failedTowers[t.key] = DateTime.now().add(const Duration(minutes: _towerCooldownMin));
  }

  int _timeUntilNextCooldownExpiry() {
    DateTime? earliest;
    for (final d in [..._cooldowns.values, ..._failedTowers.values]) {
      if (earliest == null || d.isBefore(earliest)) earliest = d;
    }
    if (earliest == null) return 0;
    final diff = earliest.difference(DateTime.now()).inMilliseconds;
    return diff > 0 ? diff : 0;
  }

  int _soonestTempSkipMs() {
    DateTime? earliest;
    for (final d in _tempSkip.values) {
      if (earliest == null || d.isBefore(earliest)) earliest = d;
    }
    if (earliest == null) return 0;
    final diff = earliest.difference(DateTime.now()).inMilliseconds;
    return diff > 0 ? diff : 0;
  }

  Future<void> _waitForCooldownExpiry() async {
    while (_desertEnabled && _loggedIn) {
      final waitMs = _timeUntilNextCooldownExpiry();
      if (waitMs <= 0) return;
      final chunkMs = waitMs > 60000 ? 60000 : waitMs;
      await Future.delayed(Duration(milliseconds: chunkMs));
    }
  }

  int _capForTower(_DesertTower t) {
    final s = _successCaps[t.key];
    final f = _failCaps[t.key];
    int cap;
    if (s == null && f == null) {
      cap = _capStart;
    } else if (s == null) {
      cap = f! - 20;
    } else if (f == null) {
      cap = s + 15;
    } else {
      cap = s;
    }
    if (cap < _capMin) cap = _capMin;
    if (cap > _capMax) cap = _capMax;
    return cap;
  }

  // ═══════════════════════════════════════════════════════
  //  Ensure kingdom + get source position
  // ═══════════════════════════════════════════════════════
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
            final returnedArea = int.tryParse(a[3].toString()) ?? 0;
            if (_sourceAreaId != null && _sourceAreaId != 0 &&
                returnedArea != 0 && returnedArea != _sourceAreaId) {
              _log('⚠ jca returned area $returnedArea but source is $_sourceAreaId');
            }
            _sourceKid = 1;
            return 1;
          }
        }
      }
    } catch (e) { _log('jca: $e'); }
    return null;
  }

  // ═══════════════════════════════════════════════════════
  //  Scan
  // ═══════════════════════════════════════════════════════
  Future<void> _scanTowers(int kid) async {
    if (_sourceX == null || _sourceY == null) return;
    _lastScanAt = DateTime.now();
    _towers.clear();

    final cx = _sourceX!, cy = _sourceY!;
    const chunkSize = 13;

    final minX = (cx - _radiusTiles).clamp(1, 1000);
    final maxX = (cx + _radiusTiles).clamp(1, 1000);
    final minY = (cy - _radiusTiles).clamp(1, 1000);
    final maxY = (cy + _radiusTiles).clamp(1, 1000);
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

    _log('Scan ${chunks.length} chunks @ radius=$_radiusTiles');
    await _saveStatus('SCANNING', extra: 'radius=$_radiusTiles · 0/${chunks.length}');

    final seen = <String>{};
    int done = 0;
    for (final chunk in chunks) {
      try {
        final resp = await _sendXtAndWaitAsync(
          'gaa',
          jsonEncode({'KID': kid, 'AX1': chunk[0], 'AY1': chunk[1], 'AX2': chunk[2], 'AY2': chunk[3]}),
          responseCmd: 'gaa', timeoutMs: 15000, isAction: false,
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
              if (x <= 0 || y <= 0) continue;
              final key = '$x,$y';
              if (seen.contains(key)) continue;
              seen.add(key);

              // ✅ read as + rs (same as UI)
              final asVal = entry.length > 3 ? (int.tryParse(entry[3].toString()) ?? 0) : 0;
              final rsVal = entry.length > 5 ? (int.tryParse(entry[5].toString()) ?? 0) : 0;

              final dx = (x - cx).toDouble();
              final dy = (y - cy).toDouble();
              _towers.add(_DesertTower(
                x: x, y: y, kid: kid,
                distance: sqrt(dx * dx + dy * dy),
                as: asVal, rs: rsVal,
              ));
            }
          }
        }
      } catch (e) { _log('Scan chunk: $e'); }
      done++;
      await Future.delayed(Duration(milliseconds: 800 + Random().nextInt(400)));
      await _saveStatus('SCANNING', extra: 'radius=$_radiusTiles · $done/${chunks.length} · ${_towers.length} towers');
    }
    _log('Scan done: ${_towers.length} towers (dead=${_towers.where((t) => t.isDead).length})');
    await _saveStatus('SCAN_DONE', extra: '${_towers.length} towers');
  }

  // ═══════════════════════════════════════════════════════
  //  Fetch units
  // ═══════════════════════════════════════════════════════
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

  // ═══════════════════════════════════════════════════════
  //  Build army — 20% left / 60% middle / 20% right (same as UI)
  // ═══════════════════════════════════════════════════════
  _BgArmy? _buildArmy(Map<int, int> available, int cap) {
    if (cap <= 0) return null;
    final flankMax = (cap * 0.2).round();
    final middleMax = cap - 2 * flankMax;

    final sorted = available.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final remaining = Map<int, int>.from(available);

    List<List<int>> alloc(int max, {int maxSlots = 2}) {
      final out = <List<int>>[];
      int got = 0;
      for (final e in sorted) {
        if (got >= max || out.length >= maxSlots) break;
        final rem = remaining[e.key] ?? 0;
        if (rem <= 0) continue;
        final need = max - got;
        final take = need < rem ? need : rem;
        if (take <= 0) continue;
        out.add([e.key, take]);
        remaining[e.key] = rem - take;
        got += take;
      }
      return out;
    }

    final left = alloc(flankMax);
    final middle = alloc(middleMax, maxSlots: 6);
    final right = alloc(flankMax);
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
}

// ═══════════════════════════════════════════════════════════
//  BackgroundService static class (unchanged)
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
      return _running;
    } catch (e) {
      return false;
    }
  }

  static Future<void> stop() async {
    if (!_running) return;
    try { await FlutterForegroundTask.stopService(); } catch (_) {}
    _running = false;
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