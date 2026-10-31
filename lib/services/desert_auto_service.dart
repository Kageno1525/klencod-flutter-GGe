import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';
import 'desert_attack_service.dart';

class AutoStatusEntry {
  final DateTime at;
  final String message;
  AutoStatusEntry(this.at, this.message);
}

class DesertAutoService {
  static final DesertAutoService instance = DesertAutoService._();
  DesertAutoService._();

  static const _kEnabled = 'desert_auto_enabled';
  static const _kSourceAreaId = 'desert_auto_source';
  static const _kMinOffensive = 'desert_auto_min_off';
  static const _kLastScan = 'desert_auto_last_scan';
  static const _kLastReplenish = 'desert_auto_last_repl';
  static const _kCommanderIds = 'desert_auto_commander_ids';
  static const _kTransferUnitIds = 'desert_auto_transfer_unit_ids';
  static const _kFailedTowers = 'desert_auto_failed_towers';

  // ═══ ثوابت الهجوم (مطابقة للخلفية) ═══
  static const int kMinUnitsToAttack = 30;
  static const int kSuccessCooldownH = 4;      // نجاح → 4 ساعات
  static const int kFailedCooldownH = 4;       // فشل/مدمر → 4 ساعات
  static const int k313CooldownMin = 5;        // 313 → 5 دقائق
  static const int k24hCooldownMin = 24 * 60;  // عند الوصول للحد الأدنى للـ cap
  static const int kInterAttackDelaySec = 15;  // + random(5) = 15-19 ثانية
  static const int kMaxRadius = 50;
  static const int kRadiusStep = 5;

  // ✅ مفاتيح الأرقام (204)
  static const String kCapStartKey = 'desert_auto_cap_start';
  static const String kCapMinKey = 'desert_auto_cap_min';
  static const String kCapMaxKey = 'desert_auto_cap_max';

  static const int kDefaultCapStart = 204;
  static const int kDefaultCapMin = 204;
  static const int kDefaultCapMax = 204;

  static const _kCapsSuccessKey = 'desert_cap_ok_v3';
  static const _kCapsFailKey = 'desert_cap_fail_v3';

  final ValueNotifier<String> statusNotifier = ValueNotifier('Idle');
  final List<AutoStatusEntry> _history = [];
  List<AutoStatusEntry> get statusHistory => List.unmodifiable(_history);

  int attacksThisSession = 0;
  int towersScanned = 0;
  int get currentRadius => _sessionRadius;

  Timer? _timer;
  StreamSubscription? _xtSub;
  bool _running = false;
  DesertAttackService? _svc;
  GgeClient? _client;
  List<DesertTower> _towers = [];
  List<DesertTower> get towers => List.unmodifiable(_towers);

  final Map<String, DateTime> _failedTowers = {};
  final Map<String, int> _lastSuccessCaps = {};
  final Map<String, int> _lastFailCaps = {};

  Future<void>? _activeTick;
  final Set<String> _attackingNow = {};
  final Set<String> _attackedThisTick = {};
  bool _scanInProgress = false;

  int _sessionRadius = 5;

  Future<bool> isEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kEnabled) ?? false;
  }

  Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
    TrafficLog.add('ST', '[Desert-Auto] enabled=$v');
  }

  Future<void> setSource(int areaId) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kSourceAreaId, areaId);
  }

  Future<List<int>> getCommanderIds() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_kCommanderIds) ?? [];
    return raw.map((s) => int.tryParse(s) ?? 0).where((i) => i >= 0).toList();
  }

  Future<void> setCommanderIds(List<int> ids) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kCommanderIds, ids.map((e) => e.toString()).toList());
    TrafficLog.add('ST', '[Desert-Auto] commander filter: $ids');
  }

  Future<List<int>> getTransferUnitIds() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_kTransferUnitIds) ?? [];
    return raw.map((s) => int.tryParse(s) ?? 0).where((i) => i > 0).toList();
  }

  Future<void> setTransferUnitIds(List<int> ids) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kTransferUnitIds, ids.map((e) => e.toString()).toList());
    TrafficLog.add('ST', '[Desert-Auto] transfer filter: $ids');
  }

  bool get isRunning => _running;

  // ═══════════════════════════════════════════════════════
  //  Persistence
  // ═══════════════════════════════════════════════════════
  Future<void> _loadFailedTowers() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kFailedTowers);
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      _failedTowers.clear();
      for (final e in data.entries) {
        final dt = DateTime.tryParse(e.value as String);
        if (dt != null && dt.isAfter(now)) {
          _failedTowers[e.key] = dt;
        }
      }
    } catch (_) {}
  }

  Future<void> _saveFailedTowers() async {
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final data = <String, String>{};
    for (final e in _failedTowers.entries) {
      if (e.value.isAfter(now)) {
        data[e.key] = e.value.toIso8601String();
      }
    }
    await p.setString(_kFailedTowers, jsonEncode(data));
  }

  Future<void> _loadCaps() async {
    final p = await SharedPreferences.getInstance();
    try {
      final rawS = p.getString(_kCapsSuccessKey);
      if (rawS != null) {
        final data = jsonDecode(rawS) as Map<String, dynamic>;
        _lastSuccessCaps.clear();
        for (final e in data.entries) {
          _lastSuccessCaps[e.key] = (e.value as num).toInt();
        }
      }
      final rawF = p.getString(_kCapsFailKey);
      if (rawF != null) {
        final data = jsonDecode(rawF) as Map<String, dynamic>;
        _lastFailCaps.clear();
        for (final e in data.entries) {
          _lastFailCaps[e.key] = (e.value as num).toInt();
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCaps() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCapsSuccessKey, jsonEncode(_lastSuccessCaps));
    await p.setString(_kCapsFailKey, jsonEncode(_lastFailCaps));
  }

  int _capFor(DesertTower t, int startCap, int minCap, int maxCap) {
    final s = _lastSuccessCaps[t.key];
    final f = _lastFailCaps[t.key];

    if (s == null && f == null) return startCap;

    if (s == null) {
      final next = f! - 20;
      return next < minCap ? minCap : (next > maxCap ? maxCap : next);
    }

    if (f == null) {
      final next = s + 15;
      return next > maxCap ? maxCap : next;
    }

    return s;
  }

  void _onSuccess(DesertTower t, int used) {
    _lastSuccessCaps[t.key] = used;
    _saveCaps();
  }

  void _on313(DesertTower t, int attempted, int minCap) {
    _lastFailCaps[t.key] = attempted;
    // ✅ لو وصلنا الحد الأدنى، البرج غير قابل للهجوم → 24 ساعة
    if (attempted <= minCap) {
      _failedTowers[t.key] = DateTime.now().add(Duration(minutes: k24hCooldownMin));
      TrafficLog.add('ST', '[Desert-Auto] 💀 ${t.coordsLabel} unusable at cap<=$minCap (24h)');
    } else {
      // ✅ لسه نقدر ننقص cap → 5 دقائق قبل المحاولة
      _failedTowers[t.key] = DateTime.now().add(Duration(minutes: k313CooldownMin));
    }
    _saveFailedTowers();
    _saveCaps();
  }

  // ═══════════════════════════════════════════════════════
  //  Start / Stop
  // ═══════════════════════════════════════════════════════
  Future<void> start(GgeClient client, {int? sourceAreaId}) async {
    if (_running) return;

    if (_activeTick != null) {
      TrafficLog.add('ST', '[Desert-Auto] ⏳ Waiting for old tick...');
      try {
        await _activeTick!.timeout(const Duration(seconds: 60));
      } catch (_) {}
    }

    _attackingNow.clear();
    _attackedThisTick.clear();
    _scanInProgress = false;

    _client = client;
    _svc = DesertAttackService(client);
    await _svc!.loadCooldowns();
    await _loadFailedTowers();
    await _loadCaps();

    attacksThisSession = 0;
    towersScanned = 0;

    // ✅ reset radius to user setting
    try {
      final settings = await DesertAttackSettings.load();
      _sessionRadius = settings.radiusTiles.clamp(kRadiusStep, kMaxRadius);
    } catch (_) {
      _sessionRadius = 5;
    }

    _xtSub?.cancel();

    if (sourceAreaId != null && sourceAreaId > 0) {
      await setSource(sourceAreaId);
    }

    _running = true;
    _setStatus('🚀 Started @ R=$_sessionRadius');
    _tick();

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  void stop() {
    _xtSub?.cancel();
    _xtSub = null;
    _timer?.cancel();
    _timer = null;
    _running = false;
    _setStatus('🛑 Stopped');
  }

  void _setStatus(String s) {
    statusNotifier.value = s;
    _history.add(AutoStatusEntry(DateTime.now(), s));
    if (_history.length > 200) _history.removeAt(0);
    TrafficLog.add('ST', '[Desert-Auto] $s');
  }

  bool _shouldSkipTower(DesertTower t) {
    final at = _failedTowers[t.key];
    if (at == null) return false;
    if (at.isBefore(DateTime.now())) {
      _failedTowers.remove(t.key);
      _saveFailedTowers();
      return false;
    }
    return true;
  }

  void _markTowerCooldown(DesertTower t, {required int minutes}) {
    _failedTowers[t.key] = DateTime.now().add(Duration(minutes: minutes));
    _saveFailedTowers();
  }

  // ═══════════════════════════════════════════════════════
  //  Tick
  // ═══════════════════════════════════════════════════════
  Future<void> _tick() async {
    if (!_running) return;
    if (_activeTick != null) return;
    _activeTick = _doTick();
    try {
      await _activeTick;
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Auto] tick error: $e');
    } finally {
      _activeTick = null;
    }
  }

  Future<void> _doTick() async {
    if (!await isEnabled()) {
      _setStatus('⏸️ Disabled');
      return;
    }
    if (_client == null || _svc == null) return;

    const initialStatus = '⏱️ Checking...';
    _setStatus(initialStatus);
    _attackedThisTick.clear();

    try {
      await _maybeReplenish();
      if (!_running) return;
      await _tryAttackTowers();

      if (_running && statusNotifier.value == initialStatus) {
        _setStatus('💤 Idle  ·  ⏱ 30s');
      }
    } catch (e) {
      _setStatus('❌ Error: $e');
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Replenish (زي القديم)
  // ═══════════════════════════════════════════════════════
  Future<void> _maybeReplenish() async {
    if (_client == null) return;
    final p = await SharedPreferences.getInstance();
    final desertArea = p.getInt(_kSourceAreaId) ?? 0;
    if (desertArea == 0) return;

    final lastStr = p.getString(_kLastReplenish);
    if (lastStr != null) {
      final last = DateTime.tryParse(lastStr);
      if (last != null && DateTime.now().difference(last).inMinutes < 20) {
        return;
      }
    }

    final minOff = p.getInt(_kMinOffensive) ?? kMinUnitsToAttack;

    try {
      final castles = await _client!.getCastles();
      OwnedCastle? main;
      OwnedCastle? desert;
      for (final c in castles) {
        if (c.areaType == 1) main = c;
        if (c.areaId == desertArea) desert = c;
      }
      if (desert == null || main == null) return;
      if (main.areaId == desert.areaId) return;

      final catalog = await _client!.loadCatalog();
      final desertUnits = await _client!.getCastleUnits(desert.kingdomId, desert.areaId, catalog);

      final offCount = desertUnits
          .where((u) => u.isCombat && !u.isDefensive && u.amount > 0)
          .fold<int>(0, (s, u) => s + u.amount);
      if (offCount >= minOff) return;

      _setStatus('🔄 Need transfer: $offCount < $minOff');

      final mainUnits = await _client!.getCastleUnits(main.kingdomId, main.areaId, catalog);

      final selectedIds = await getTransferUnitIds();
      var offensiveMain = mainUnits.where((u) => u.isCombat && !u.isDefensive && u.amount > 0).toList();
      if (selectedIds.isNotEmpty) {
        offensiveMain = offensiveMain.where((u) => selectedIds.contains(u.wodId)).toList();
      }
      if (offensiveMain.isEmpty) {
        _setStatus('❌ Main has no selected offensive units');
        return;
      }

      final toTransfer = <List<int>>[];
      for (final u in offensiveMain.take(10)) {
        toTransfer.add([u.wodId, u.amount]);
      }

      _setStatus('📤 Transferring ${toTransfer.length} types...');
      final result = await _client!.transfer(source: main, target: desert, units: toTransfer);

      if (result.success) {
        await p.setString(_kLastReplenish, DateTime.now().toIso8601String());
        _setStatus('✅ Transfer queued (~10-15m)');
      } else {
        _setStatus('❌ Transfer failed: ${result.error}');
      }
    } catch (e) {
      _setStatus('❌ Replenish error: $e');
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Rescan (merge, لا يستبدل)
  // ═══════════════════════════════════════════════════════
  Future<void> _rescanAt(int radius) async {
    if (_client == null || _svc == null) return;
    if (_scanInProgress) return;

    final p = await SharedPreferences.getInstance();
    final desertArea = p.getInt(_kSourceAreaId) ?? 0;
    if (desertArea == 0) return;

    _scanInProgress = true;
    try {
      final castles = await _client!.getCastles();
      OwnedCastle? desert;
      for (final c in castles) {
        if (c.areaId == desertArea) desert = c;
      }
      if (desert == null) return;

      _setStatus('🔍 Scan @ R=$radius...');
      final newTowers = await _svc!.scanArea(source: desert, radiusTiles: radius);

      // ✅ merge
      int added = 0;
      for (final t in newTowers) {
        final idx = _towers.indexWhere((e) => e.x == t.x && e.y == t.y && e.kid == t.kid);
        if (idx >= 0) {
          _towers[idx] = t;
        } else {
          _towers.add(t);
          added++;
        }
      }

      towersScanned = _towers.length;
      await p.setString(_kLastScan, DateTime.now().toIso8601String());
      _setStatus('✓ ${_towers.length} towers (+$added) @ R=$radius');
    } catch (e) {
      rethrow;
    } finally {
      _scanInProgress = false;
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Attack loop (مطابق للخلفية)
  // ═══════════════════════════════════════════════════════
  Future<void> _tryAttackTowers() async {
    if (_client == null || _svc == null) return;

    final p = await SharedPreferences.getInstance();
    final desertArea = p.getInt(_kSourceAreaId) ?? 0;
    if (desertArea == 0) return;

    final startCap = p.getInt(kCapStartKey) ?? kDefaultCapStart;
    final minCap = p.getInt(kCapMinKey) ?? kDefaultCapMin;
    final maxCap = p.getInt(kCapMaxKey) ?? kDefaultCapMax;

    try {
      final castles = await _client!.getCastles();
      OwnedCastle? desert;
      for (final c in castles) {
        if (c.areaId == desertArea) desert = c;
      }
      if (desert == null) return;

      final catalog = await _client!.loadCatalog();

      // ═══ 1. Scan أولي / دوري ═══
      final lastScanStr = p.getString(_kLastScan);
      final lastScan = lastScanStr != null ? DateTime.tryParse(lastScanStr) : null;
      final needsScan = _towers.isEmpty ||
          (lastScan != null && DateTime.now().difference(lastScan).inMinutes >= 5);

      if (needsScan) {
        try {
          await _rescanAt(_sessionRadius);
        } catch (e) {
          if (e.toString().contains('SCAN_COOLDOWN')) {
            _setStatus('⏱ Scan cooldown, wait...');
            return;
          }
          _setStatus('❌ Scan: $e');
          return;
        }
      }

      int attempts = 0;
      const int maxAttempts = 50;

      // ═══ 2. Attack loop مع Radius expansion ═══
      while (_running && attempts < maxAttempts) {
        final ready = _towers
            .where((t) => !_shouldSkipTower(t))
            .where((t) => !_attackedThisTick.contains(t.key))
            .where((t) => !_attackingNow.contains(t.key))
            .toList()
          ..sort((a, b) => a.distanceFromSource.compareTo(b.distanceFromSource));

        if (ready.isEmpty) {
          // ✅ مفيش جاهز → كبّر radius
          if (_sessionRadius < kMaxRadius) {
            final newRadius = min(_sessionRadius + kRadiusStep, kMaxRadius);
            try {
              await _rescanAt(newRadius);
              _sessionRadius = newRadius;
              _setStatus('📡 Expanded to R=$newRadius');
              continue;
            } catch (e) {
              if (e.toString().contains('SCAN_COOLDOWN')) {
                _setStatus('⏱ Scan cd, retry next tick');
                return;
              }
              _setStatus('❌ Scan: $e');
              return;
            }
          }
          _setStatus('💤 All cooldown (R=$kMaxRadius)');
          return;
        }

        // ═══ جلب وحدات ═══
        final freshUnits = await _client!.getCastleUnits(desert.kingdomId, desert.areaId, catalog);
        final sendable = freshUnits.where((u) => u.isCombat && u.amount > 0).toList();
        final totalUnits = sendable.fold<int>(0, (s, u) => s + u.amount);

        if (totalUnits < kMinUnitsToAttack) {
          _setStatus('💤 Units: $totalUnits (< $kMinUnitsToAttack)');
          return;
        }

        // ═══ قائد ═══
        final cmds = await _client!.getCommanders();
        var freeLords = cmds.where((c) => !c.isBusy).toList();
        final selectedCommanderIds = await getCommanderIds();
        if (selectedCommanderIds.isNotEmpty) {
          freeLords = freeLords.where((c) => selectedCommanderIds.contains(c.lord.id)).toList();
        }
        if (freeLords.isEmpty) {
          _setStatus('💤 No free commanders');
          return;
        }

        final tower = ready.first;
        _attackingNow.add(tower.key);
        attempts++;

        try {
          final cap = _capFor(tower, startCap, minCap, maxCap);
          final suggestion = _svc!.suggestCounter(
            available: sendable,
            defenders: DefenderSummary(),
            maxTotal: cap,
          );

          if (suggestion.totalUnits <= 0) {
            _markTowerCooldown(tower, minutes: kFailedCooldownH * 60);
            _attackedThisTick.add(tower.key);
            continue;
          }

          Lord lord;
          try {
            lord = freeLords.firstWhere((c) => c.lord.id != 0).lord;
          } catch (_) {
            lord = freeLords.first.lord;
          }

          _setStatus('⚔️ ${tower.coordsLabel} (${suggestion.totalUnits}/cap=$cap)');

          final result = await _svc!.attack(
            tower: tower,
            source: desert,
            lordId: lord.id,
            leftUnits: suggestion.left,
            middleUnits: suggestion.middle,
            rightUnits: suggestion.right,
            markCooldownAfterSuccess: false, // ✅ إحنا بنحط cooldown
          );

          if (result.success) {
            _markTowerCooldown(tower, minutes: kSuccessCooldownH * 60); // 4h
            _onSuccess(tower, suggestion.totalUnits);
            attacksThisSession++;
            _attackedThisTick.add(tower.key);
            TrafficLog.add('ST', '[Desert-Auto] ✅ HIT ${tower.coordsLabel} units=${suggestion.totalUnits}');
            _setStatus('✅ Hit ${tower.coordsLabel} → ${kSuccessCooldownH}h');

            final delaySec = kInterAttackDelaySec + Random().nextInt(5); // 15-19s
            TrafficLog.add('ST', '[Desert-Auto] ⏳ wait ${delaySec}s');
            await Future.delayed(Duration(seconds: delaySec));

            if (!_running) return;
            continue;
          }

          final err = result.error ?? '';

          if (err.contains('313')) {
            _on313(tower, cap, minCap);
            _attackedThisTick.add(tower.key);
            final newCap = _capFor(tower, startCap, minCap, maxCap);
            _setStatus('📉 ${tower.coordsLabel}: cap→$newCap');
            await Future.delayed(const Duration(seconds: 3));
            continue;
          }

          if (err.contains('218') || err.contains('181')) {
            _setStatus('⏸️ $err — next tick');
            return;
          }

          if (err.contains('NO_UNITS')) {
            _setStatus('⏸️ No units');
            return;
          }

          // ✅ فشل عادي = احتمال برج مدمر → 4 ساعات
          _markTowerCooldown(tower, minutes: kFailedCooldownH * 60);
          _attackedThisTick.add(tower.key);
          TrafficLog.add('ER', '[Desert-Auto] ❌ ${tower.coordsLabel}: $err → ${kFailedCooldownH}h (dead?)');
          _setStatus('❌ ${tower.coordsLabel}: ${err.substring(0, min(20, err.length))}');
          continue;

        } finally {
          _attackingNow.remove(tower.key);
        }
      }
    } catch (e) {
      _setStatus('❌ Attack loop error: $e');
    }
  }
}