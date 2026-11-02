import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';
import 'background_service.dart';
import 'bedouin_service.dart';

class BedouinAutoStatusEntry {
  final DateTime at;
  final String message;
  BedouinAutoStatusEntry(this.at, this.message);
}

class BedouinAutoService {
  static final BedouinAutoService instance = BedouinAutoService._();
  BedouinAutoService._();

  // ═══ Keys ═══
  static const _kEnabled = 'bedouin_auto_enabled';
  static const _kSourceAreaId = 'bedouin_auto_source_area';
  static const _kSourceKid = 'bedouin_auto_source_kid';
  static const _kSourceX = 'bedouin_auto_source_x';
  static const _kSourceY = 'bedouin_auto_source_y';
  static const _kMinUnits = 'bedouin_auto_min_units';
  static const _kCommanderIds = 'bedouin_auto_commander_ids';
  static const _kWaves = 'bedouin_auto_waves';
  static const _kUseTools = 'bedouin_auto_use_tools';
  static const _kToolIdW1 = 'bedouin_auto_tool_id_w1';
  static const _kToolIdW2 = 'bedouin_auto_tool_id_w2';
  static const _kToolIdW3 = 'bedouin_auto_tool_id_w3';
  static const _kToolL = 'bedouin_auto_tool_l';
  static const _kToolR = 'bedouin_auto_tool_r';
  static const _kToolM = 'bedouin_auto_tool_m';
  static const _kMaxLevel = 'bedouin_auto_max_level';
  static const _kRadius = 'bedouin_radius_v1';
  static const _kDelayMin = 'bedouin_auto_delay_min';
  static const _kDelayMax = 'bedouin_auto_delay_max';
  static const _kMaxAttacksDay = 'bedouin_auto_max_attacks_day';
  static const _kAttacksToday = 'bedouin_auto_attacks_today';
  static const _kAttacksDate = 'bedouin_auto_attacks_date';
  static const _kFailedCamps = 'bedouin_auto_failed_camps';
  static const _kLastScan = 'bedouin_auto_last_scan';
  static const _kAttackPriority = 'bedouin_auto_attack_priority';

  static const int kDefMinUnits = 50;
  static const int kDefWaves = 3;
  static const int kDefToolIdW1 = 1;
  static const int kDefToolIdW2 = 164;
  static const int kDefToolIdW3 = 1;
  static const int kDefToolL = 20;
  static const int kDefToolR = 20;
  static const int kDefToolM = 30;
  static const int kDefMaxLevel = 20;
  static const int kDefDelayMin = 8;
  static const int kDefDelayMax = 15;
  static const int kDefMaxAttacksDay = 0;
  static const String kDefAttackPriority = 'distance';
  static const int kDefScanRadius = 30;

  static const int kCampsScanCacheMin = 5;
  static const int kFailedCampCooldownMin = 30;

  static const Set<int> kDefensiveWodIds = {1, 2, 3, 4, 5, 6, 7, 8};

  // ═══ State ═══
  final ValueNotifier<String> statusNotifier = ValueNotifier('Idle');
  final List<BedouinAutoStatusEntry> _history = [];
  List<BedouinAutoStatusEntry> get statusHistory => List.unmodifiable(_history);

  int attacksThisSession = 0;
  int campsScanned = 0;

  Timer? _timer;
  Timer? _syncTimer;
  bool _running = false;
  bool _inBackground = false;
  BedouinService? _svc;
  GgeClient? _client;

  List<BedouinCamp> _camps = [];
  List<BedouinCamp> get camps => List.unmodifiable(_camps);

  final Map<String, DateTime> _failedCamps = {};

  Future<void>? _activeTick;
  final Set<String> _attackedThisTick = {};

  int? _playerLevel;

  bool get isRunning => _running;
  bool get isInBackground => _inBackground;

  // ═══ Config ═══
  Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? false;

  Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
    TrafficLog.add('ST', '[Bedouin-Auto] enabled=$v');
  }

  Future<void> setSource({
    required int areaId, required int kid,
    required int x, required int y,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kSourceAreaId, areaId);
    await p.setInt(_kSourceKid, kid);
    await p.setInt(_kSourceX, x);
    await p.setInt(_kSourceY, y);
    TrafficLog.add('ST',
        '[Bedouin-Auto] source: area=$areaId kid=$kid ($x,$y)');
  }

  Future<int> getMinUnits() async =>
      (await SharedPreferences.getInstance()).getInt(_kMinUnits) ??
      kDefMinUnits;

  Future<void> setMinUnits(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kMinUnits, v);
  }

  Future<List<int>> getCommanderIds() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_kCommanderIds) ?? [];
    return raw.map((s) => int.tryParse(s) ?? 0).where((i) => i > 0).toList();
  }

  Future<void> setCommanderIds(List<int> ids) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        _kCommanderIds, ids.map((e) => e.toString()).toList());
    TrafficLog.add('ST', '[Bedouin-Auto] cmds: $ids');
  }

  // ─── Waves ───
  Future<int> getWaves() async =>
      ((await SharedPreferences.getInstance()).getInt(_kWaves) ?? kDefWaves)
          .clamp(1, 3);

  Future<void> setWaves(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kWaves, v.clamp(1, 3));
  }

  // ─── Tools ───
  Future<bool> getUseTools() async =>
      (await SharedPreferences.getInstance()).getBool(_kUseTools) ?? true;

  Future<void> setUseTools(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kUseTools, v);
  }

  Future<int> getToolIdWave1() async =>
      (await SharedPreferences.getInstance()).getInt(_kToolIdW1) ??
      kDefToolIdW1;

  Future<int> getToolIdWave2() async =>
      (await SharedPreferences.getInstance()).getInt(_kToolIdW2) ??
      kDefToolIdW2;

  Future<int> getToolIdWave3() async =>
      (await SharedPreferences.getInstance()).getInt(_kToolIdW3) ??
      kDefToolIdW3;

  Future<void> setToolIds({int? w1, int? w2, int? w3}) async {
    final p = await SharedPreferences.getInstance();
    if (w1 != null) await p.setInt(_kToolIdW1, w1);
    if (w2 != null) await p.setInt(_kToolIdW2, w2);
    if (w3 != null) await p.setInt(_kToolIdW3, w3);
  }

  Future<int> getToolL() async =>
      (await SharedPreferences.getInstance()).getInt(_kToolL) ?? kDefToolL;

  Future<int> getToolR() async =>
      (await SharedPreferences.getInstance()).getInt(_kToolR) ?? kDefToolR;

  Future<int> getToolM() async =>
      (await SharedPreferences.getInstance()).getInt(_kToolM) ?? kDefToolM;

  Future<void> setToolAmounts({int? l, int? r, int? m}) async {
    final p = await SharedPreferences.getInstance();
    if (l != null) await p.setInt(_kToolL, l);
    if (r != null) await p.setInt(_kToolR, r);
    if (m != null) await p.setInt(_kToolM, m);
  }

  // ─── Priority ───
  Future<String> getAttackPriority() async =>
      (await SharedPreferences.getInstance()).getString(_kAttackPriority) ??
      kDefAttackPriority;

  Future<void> setAttackPriority(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAttackPriority, v);
    TrafficLog.add('ST', '[Bedouin-Auto] attack priority: $v');
  }

  // ─── Limits ───
  Future<int> getMaxLevel() async =>
      (await SharedPreferences.getInstance()).getInt(_kMaxLevel) ??
      kDefMaxLevel;

  Future<void> setMaxLevel(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kMaxLevel, v.clamp(1, 20));
  }

  Future<int> getRadius() async =>
      (await SharedPreferences.getInstance()).getInt(_kRadius) ??
      kDefScanRadius;

  Future<void> setRadius(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kRadius, v.clamp(5, 100));
  }

  Future<int> getDelayMin() async =>
      (await SharedPreferences.getInstance()).getInt(_kDelayMin) ??
      kDefDelayMin;

  Future<int> getDelayMax() async =>
      (await SharedPreferences.getInstance()).getInt(_kDelayMax) ??
      kDefDelayMax;

  Future<void> setDelay({int? min, int? max}) async {
    final p = await SharedPreferences.getInstance();
    if (min != null) await p.setInt(_kDelayMin, min.clamp(5, 120));
    if (max != null) await p.setInt(_kDelayMax, max.clamp(5, 120));
  }

  Future<int> getMaxAttacksDay() async =>
      (await SharedPreferences.getInstance()).getInt(_kMaxAttacksDay) ??
      kDefMaxAttacksDay;

  Future<void> setMaxAttacksDay(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kMaxAttacksDay, v.clamp(0, 9999));
  }

  Future<int> getAttacksToday() async {
    final p = await SharedPreferences.getInstance();
    final today = _todayStr();
    final savedDate = p.getString(_kAttacksDate) ?? '';
    if (savedDate != today) {
      await p.setInt(_kAttacksToday, 0);
      await p.setString(_kAttacksDate, today);
      return 0;
    }
    return p.getInt(_kAttacksToday) ?? 0;
  }

  String _todayStr() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  // ═══ Start / Stop ═══
  Future<void> startFromUI(GgeClient client, {int? sourceAreaId}) async {
    _inBackground = false;
    await setEnabled(true);

    if (sourceAreaId != null && sourceAreaId > 0) {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kSourceAreaId, sourceAreaId);
      TrafficLog.add('ST',
          '[Bedouin-Auto] Source saved: $sourceAreaId');
    }

    final bgRunning = await FlutterForegroundTask.isRunningService;
    if (!bgRunning) {
      TrafficLog.add('ST',
          '[Bedouin-Auto] Starting background service...');
      final ok = await BackgroundService.start();
      if (!ok) {
        await setEnabled(false);
        _setStatus('❌ Failed to start background');
        return;
      }
      await Future.delayed(const Duration(seconds: 2));
    }

    await _startCore(client);
  }

  Future<void> startInBackground(GgeClient client) async {
    _inBackground = true;
    await _startCore(client);
  }

  Future<void> _startCore(GgeClient client) async {
    if (_running) return;

    _running = true;
    _client = client;
    _svc ??= BedouinService(client);
    attacksThisSession = 0;
    campsScanned = 0;

    TrafficLog.add('ST',
        '[Bedouin-Auto] 🚀 Started (${_inBackground ? "BG" : "UI"})');
    _setStatus(_inBackground ? '🚀 Started (BG)' : '🚀 Started (UI)');

    if (!_inBackground) {
      _syncTimer?.cancel();
      _syncTimer = Timer.periodic(
          const Duration(seconds: 5), (_) => _syncBackgroundStatus());
    }

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  Future<void> disable() async {
    await setEnabled(false);
    await stop();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _running = false;
    _inBackground = false;

    TrafficLog.add('ST', '[Bedouin-Auto] 🛑 Stopped');
    _setStatus('🛑 Stopped');
  }

  Future<void> restoreState() async {
    final enabled = await isEnabled();
    if (!enabled) {
      _running = false;
      _setStatus('Idle');
      return;
    }

    final bgRunning = await FlutterForegroundTask.isRunningService;
    _running = bgRunning;

    if (bgRunning) {
      _setStatus('🚀 Active (background)');
      _syncTimer?.cancel();
      _syncTimer = Timer.periodic(
          const Duration(seconds: 5), (_) => _syncBackgroundStatus());
    } else {
      _setStatus('⏸️ Paused (background off)');
    }
  }

  Future<void> _syncBackgroundStatus() async {
    if (!_running) return;
    try {
      final status =
          await FlutterForegroundTask.getData<String>(key: 'bg_status');
      final extra =
          await FlutterForegroundTask.getData<String>(key: 'bg_extra');
      if (status == null) return;
      final display = (extra != null && extra.isNotEmpty)
          ? '$status · $extra'
          : status;
      if (statusNotifier.value != display) {
        statusNotifier.value = display;
      }
    } catch (_) {}
  }

  void _setStatus(String s) {
    statusNotifier.value = s;
    _history.add(BedouinAutoStatusEntry(DateTime.now(), s));
    if (_history.length > 200) _history.removeAt(0);
    TrafficLog.add('ST', '[Bedouin-Auto] $s');
  }

  // ═══ Persistence ═══
  Future<void> _loadFailedCamps() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kFailedCamps);
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      _failedCamps.clear();
      for (final e in data.entries) {
        final dt = DateTime.tryParse(e.value as String);
        if (dt != null && dt.isAfter(now)) _failedCamps[e.key] = dt;
      }
    } catch (_) {}
  }

  Future<void> _saveFailedCamps() async {
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final data = <String, String>{};
    for (final e in _failedCamps.entries) {
      if (e.value.isAfter(now)) data[e.key] = e.value.toIso8601String();
    }
    await p.setString(_kFailedCamps, jsonEncode(data));
  }

  Future<void> clearAllState() async {
    _failedCamps.clear();
    _attackedThisTick.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(_kFailedCamps);
    await p.remove(_kLastScan);
    TrafficLog.add('ST', '[Bedouin-Auto] 🧹 State cleared');
    _setStatus('🧹 State cleared');
  }

  // ═══ Player Level ═══
  Future<void> _ensurePlayerLevel() async {
    if (_playerLevel != null && _playerLevel! > 0) return;
    if (_client == null) return;
    try {
      final resp = await _client!.sendXtAndWait(
        'jca', jsonEncode({'CID': -1, 'KID': 0}),
        responseCmd: 'jaa', timeoutMs: 8000, isAction: false,
      );
      if (resp.payload != null) {
        final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
        final gca = data['gca'] as Map?;
        final o = gca?['O'] as Map?;
        if (o != null) {
          final lvl = _asInt(o['L']);
          final ll = _asInt(o['LL']);
          _playerLevel = lvl + ll;
          TrafficLog.add('ST',
              '[Bedouin-Auto] 👤 Player level: $_playerLevel');
        }
      }
    } catch (e) {
      TrafficLog.add('ER', '[Bedouin-Auto] playerLevel error: $e');
    }
  }

  // ═══ Tick ═══
  Future<void> _tick() async {
    if (!_running) return;

    final prefs = await SharedPreferences.getInstance();
    final isFg = prefs.getBool('is_app_foreground') ?? true;

    if (_inBackground) {
      if (isFg) return;
    } else {
      if (!isFg) {
        await _syncBackgroundStatus();
        return;
      }
    }

    if (!await isEnabled()) return;

    if (_client == null || _svc == null) {
      _client ??= GgeClient();
      _svc ??= BedouinService(_client!);
      await _loadFailedCamps();
    }

    if (_activeTick != null) return;
    _activeTick = _doTick();
    try {
      await _activeTick;
    } catch (e) {
      TrafficLog.add('ER', '[Bedouin-Auto] tick error: $e');
    } finally {
      _activeTick = null;
    }
  }

  Future<void> _doTick() async {
    if (_client == null || _svc == null) return;

    const initialStatus = '⏱️ Checking...';
    _setStatus(initialStatus);
    _attackedThisTick.clear();

    try {
      await _ensurePlayerLevel();
      await _maybeRescan();
      if (!_running) return;
      await _tryAttackCamps();

      if (_running && statusNotifier.value == initialStatus) {
        _setStatus('💤 Idle · ⏱ 30s');
      }
    } catch (e) {
      _setStatus('❌ Error: $e');
    }
  }

  // ═══ Scan ═══
  Future<void> _maybeRescan() async {
    if (_client == null || _svc == null) return;

    final p = await SharedPreferences.getInstance();
    final lastStr = p.getString(_kLastScan);
    if (lastStr != null) {
      final last = DateTime.tryParse(lastStr);
      if (last != null &&
          DateTime.now().difference(last).inMinutes < kCampsScanCacheMin &&
          _camps.isNotEmpty) {
        return;
      }
    }

    final srcArea = p.getInt(_kSourceAreaId) ?? 0;
    if (srcArea == 0) {
      _setStatus('❌ No source area');
      return;
    }

    try {
      final castles = await _client!.getCastles();
      OwnedCastle? source;
      for (final c in castles) {
        if (c.areaId == srcArea) source = c;
      }
      if (source == null) {
        _setStatus('❌ Source castle not found');
        return;
      }

      final maxLevel = p.getInt(_kMaxLevel) ?? kDefMaxLevel;
      final radius = p.getInt(_kRadius) ?? kDefScanRadius;

      _setStatus('🔍 Scanning camps...');
      _camps = await _svc!.scanArea(
        source: source,
        radiusTiles: radius,
        maxLevel: maxLevel,
        skipPlayerCamps: true,
        onProgress: (d, t) {
          if (_running) {
            _setStatus('🔍 Scanning $d/$t · ${_camps.length}');
          }
        },
      );
      campsScanned = _camps.length;
      await p.setString(_kLastScan, DateTime.now().toIso8601String());
      _setStatus('✓ Found ${_camps.length} camps');
    } catch (e) {
      _setStatus('❌ Scan error: $e');
    }
  }

  // ═══ Attack Loop ═══
  Future<void> _tryAttackCamps() async {
    if (_client == null || _svc == null) return;

    const int safetyMaxAttacks = 100;
    const int maxFailStreak = 10;

    final p = await SharedPreferences.getInstance();
    final srcArea = p.getInt(_kSourceAreaId) ?? 0;
    if (srcArea == 0) return;

    final minUnits = p.getInt(_kMinUnits) ?? kDefMinUnits;
    final maxAttacksDay = p.getInt(_kMaxAttacksDay) ?? kDefMaxAttacksDay;
    final selectedCmds = await getCommanderIds();
    final attackPriority = await getAttackPriority();
    final waves = await getWaves();
    final useTools = await getUseTools();
    final toolIdW1 = await getToolIdWave1();
    final toolIdW2 = await getToolIdWave2();
    final toolIdW3 = await getToolIdWave3();
    final toolL = await getToolL();
    final toolM = await getToolM();
    final toolR = await getToolR();
    final delayMin = await getDelayMin();
    final delayMax = await getDelayMax();

    final attacksToday = await getAttacksToday();
    if (maxAttacksDay > 0 && attacksToday >= maxAttacksDay) {
      _setStatus('🛑 Daily limit ($attacksToday/$maxAttacksDay)');
      return;
    }

    try {
      int attacksThisTick = 0;
      int failStreak = 0;

      List<BedouinCamp> buildPool() {
        final now = DateTime.now();
        final list = _camps
            .where((c) => !c.isPlayerCamp)
            .where((c) {
              final fail = _failedCamps[c.key];
              return fail == null || !fail.isAfter(now);
            })
            .toList();

        switch (attackPriority) {
          case 'level':
            list.sort((a, b) => a.level.compareTo(b.level));
            break;
          case 'troops':
            list.sort((a, b) => a.totalTroops.compareTo(b.totalTroops));
            break;
          case 'distance':
          default:
            list.sort((a, b) =>
                a.distanceFromSource.compareTo(b.distanceFromSource));
        }
        return list;
      }

      var pool = buildPool();
      TrafficLog.add('ST',
          '[Bedouin-Auto] 🎯 Pool: ${pool.length}/${_camps.length} (priority=$attackPriority)');
      if (pool.isEmpty) {
        _setStatus('⏳ All camps blocked — clear state or wait');
        return;
      }

      while (_running && attacksThisTick < safetyMaxAttacks) {
        final castles = await _client!.getCastles();
        OwnedCastle? source;
        for (final c in castles) {
          if (c.areaId == srcArea) source = c;
        }
        if (source == null) {
          _setStatus('❌ Source castle not found');
          return;
        }

        final catalog = await _client!.loadCatalog();
        final freshUnits = await _client!.getCastleUnits(
            source.kingdomId, source.areaId, catalog);
        final sendable = freshUnits
            .where((u) => _isOffensiveUnit(u) && u.amount > 0)
            .toList();
        final totalUnits =
            sendable.fold<int>(0, (s, u) => s + u.amount);

        if (totalUnits < minUnits) {
          _setStatus('💤 Idle — units: $totalUnits (< $minUnits)');
          if (attacksThisTick > 0) {
            TrafficLog.add('ST',
                '[Bedouin-Auto] ✅ Done $attacksThisTick attacks — units ran out');
          }
          return;
        }

        final cmds = await _client!.getCommanders();
        var freeLords = cmds.where((c) => !c.isBusy).toList();
        if (selectedCmds.isNotEmpty) {
          freeLords = freeLords
              .where((c) => selectedCmds.contains(c.lord.id))
              .toList();
        }
        if (freeLords.isEmpty) {
          _setStatus('💤 Idle — no free commanders');
          if (attacksThisTick > 0) {
            TrafficLog.add('ST',
                '[Bedouin-Auto] ✅ Done $attacksThisTick attacks — all lords busy');
          }
          return;
        }

        if (pool.isEmpty) {
          pool = buildPool();
          if (pool.isEmpty) {
            _setStatus('⏳ All camps blocked — waiting next cycle');
            if (attacksThisTick > 0) {
              TrafficLog.add('ST',
                  '[Bedouin-Auto] ✅ Done $attacksThisTick attacks — no targets');
            }
            return;
          }
          TrafficLog.add('ST',
              '[Bedouin-Auto] 🔄 New round: ${pool.length} camps');
        }

        final camp = pool.removeAt(0);

        final config = BedouinAttackConfig(
          waves: waves,
          useTools: useTools,
          toolIdWave1: toolIdW1,
          toolIdWave2: toolIdW2,
          toolIdWave3: toolIdW3,
          toolL: toolL,
          toolM: toolM,
          toolR: toolR,
        );

        bool attacked = false;
        for (final lordInfo in freeLords) {
          _setStatus('⚔️ ${camp.coordsLabel} · L${lordInfo.lord.id} '
              '(#${attacksThisTick + 1})');

          final result = await _svc!.attack(
            camp: camp,
            source: source,
            lordId: lordInfo.lord.id,
            fallbackLords: null,
            availableUnits: sendable,
            allUnitsForTools: freshUnits,
            config: config,
          );

          if (result.success) {
            attacksThisTick++;
            attacksThisSession++;
            await _incrementAttacksToday();
            failStreak = 0;
            TrafficLog.add('ST',
                '[Bedouin-Auto] ✅ HIT ${camp.coordsLabel} '
                'units=${result.totalUnits} tools=${result.toolsUsed} '
                '(#${attacksThisTick})');
            _setStatus('✅ Hit ${camp.coordsLabel}! (#$attacksThisTick)');

            final gapMs = (delayMin * 1000) +
                Random().nextInt(max(1, (delayMax - delayMin) * 1000));
            TrafficLog.add('ST',
                '[Bedouin-Auto] ⏱ gap ${gapMs}ms');
            await Future.delayed(Duration(milliseconds: gapMs));
            if (!_running) return;
            attacked = true;
            break;
          }

          final err = result.error ?? '';

          if (err.contains('256') ||
              err.contains('218') ||
              err.contains('LORD_BUSY')) {
            continue;
          }

          if (err.contains('CRA_6') || err.contains('TARGET_REJECTED')) {
            _failedCamps[camp.key] =
                DateTime.now().add(const Duration(hours: 2));
            await _saveFailedCamps();
            TrafficLog.add('ER',
                '[Bedouin-Auto] ⛔ ${camp.coordsLabel}: $err (2h)');
            break;
          }

          if (err.contains('313')) {
            _failedCamps[camp.key] = DateTime.now()
                .add(Duration(minutes: kFailedCampCooldownMin));
            await _saveFailedCamps();
            TrafficLog.add('ER',
                '[Bedouin-Auto] ⛔ ${camp.coordsLabel}: 313 (30m)');
            break;
          }

          TrafficLog.add('ER',
              '[Bedouin-Auto] ❌ ${camp.coordsLabel}: $err (will retry)');
          break;
        }

        if (!attacked) {
          failStreak++;
          TrafficLog.add('ST',
              '[Bedouin-Auto] ⚠️ fail streak: $failStreak/$maxFailStreak');
          if (failStreak >= maxFailStreak) {
            _setStatus('🛑 Too many failures — waiting next cycle');
            return;
          }
          await Future.delayed(const Duration(seconds: 3));
        }
      }

      if (attacksThisTick >= safetyMaxAttacks) {
        TrafficLog.add('ST',
            '[Bedouin-Auto] ⚠️ Safety limit ($safetyMaxAttacks) reached');
      }
    } catch (e) {
      _setStatus('❌ Attack loop error: $e');
    }
  }

  bool _isOffensiveUnit(CastleUnit u) {
    if (kDefensiveWodIds.contains(u.wodId)) return false;
    if (u.info?.fightType != null) return u.info!.fightType == 0;
    return u.info?.role == 'melee' || u.info?.role == 'ranged';
  }

  Future<void> _incrementAttacksToday() async {
    final p = await SharedPreferences.getInstance();
    final today = _todayStr();
    final savedDate = p.getString(_kAttacksDate) ?? '';
    if (savedDate != today) {
      await p.setInt(_kAttacksToday, 1);
      await p.setString(_kAttacksDate, today);
    } else {
      final current = p.getInt(_kAttacksToday) ?? 0;
      await p.setInt(_kAttacksToday, current + 1);
    }
  }

  static int _asInt(dynamic v, [int def = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }
}