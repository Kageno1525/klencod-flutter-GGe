import 'dart:async';
import 'dart:convert';
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

  // ═══════════ Prefs keys ═══════════
  static const _kEnabled = 'desert_auto_enabled';
  static const _kSourceAreaId = 'desert_auto_source';
  static const _kMinOffensive = 'desert_auto_min_off';
  static const _kLastReplenish = 'desert_auto_last_repl';
  static const _kCommanderIds = 'desert_auto_commander_ids';
  static const _kTransferUnitIds = 'desert_auto_transfer_unit_ids';
  static const _kFailedTowers = 'desert_auto_failed_towers';

  // ═══════════ Constants (نفس الخلفية) ═══════════
  static const int kMinUnitsToAttack = 30;
  static const int kTowerCooldownMin = 240;   // 4 ساعات (نجاح/مدمر)
  static const int kFailedCooldownMin = 240;  // 4 ساعات (فشل)
  static const int kInterAttackDelaySec = 15; // 15 ثانية
  static const int kMaxRadius = 50;
  static const int kRadiusStep = 5;

  // ═══════════ Caps (زي ما هي) ═══════════
  static const String kCapStartKey = 'desert_auto_cap_start';
  static const String kCapMinKey   = 'desert_auto_cap_min';
  static const String kCapMaxKey   = 'desert_auto_cap_max';
  static const int kDefaultCapStart = 204;
  static const int kDefaultCapMin   = 204;
  static const int kDefaultCapMax   = 204;

  static const _kCapsSuccessKey = 'desert_cap_ok_v3';
  static const _kCapsFailKey    = 'desert_cap_fail_v3';

  // ═══════════ Public state ═══════════
  final ValueNotifier<String> statusNotifier = ValueNotifier('Idle');
  final List<AutoStatusEntry> _history = [];
  List<AutoStatusEntry> get statusHistory => List.unmodifiable(_history);

  int attacksThisSession = 0;
  int towersScanned = 0;

  // ═══════════ Internal ═══════════
  bool _running = false;
  DesertAttackService? _svc;
  GgeClient? _client;
  List<DesertTower> _towers = [];
  List<DesertTower> get towers => List.unmodifiable(_towers);
  int _radiusTiles = 5;

  final Map<String, DateTime> _failedTowers = {};
  final Map<String, DateTime> _tempSkip = {};
  final Map<String, int> _lastSuccessCaps = {};
  final Map<String, int> _lastFailCaps = {};
  final Set<String> _attackingNow = {};

  Future<void>? _activeLoop;
  bool _scanInProgress = false;

  // ═══════════════════════════════════════════════════════
  //  Public API (used by screen)
  // ═══════════════════════════════════════════════════════
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

  void _setStatus(String s) {
    statusNotifier.value = s;
    _history.add(AutoStatusEntry(DateTime.now(), s));
    if (_history.length > 200) _history.removeAt(0);
    TrafficLog.add('ST', '[Desert-Auto] $s');
  }

  // ═══════════════════════════════════════════════════════
  //  Start / Stop
  // ═══════════════════════════════════════════════════════
  Future<void> start(GgeClient client, {int? sourceAreaId}) async {
    if (_running) return;

    if (_activeLoop != null) {
      try { await _activeLoop!.timeout(const Duration(seconds: 60)); } catch (_) {}
    }

    _attackingNow.clear();
    _tempSkip.clear();
    _scanInProgress = false;

    _client = client;
    _svc = DesertAttackService(client);
    await _svc!.loadCooldowns();
    await _loadFailedTowers();
    await _loadCaps();

    attacksThisSession = 0;
    towersScanned = 0;

    if (sourceAreaId != null && sourceAreaId > 0) {
      await setSource(sourceAreaId);
    }

    // ابدأ من الـ radius المحدد في الإعدادات، بس في حدود 5..50
    final settings = await DesertAttackSettings.load();
    _radiusTiles = settings.radiusTiles.clamp(5, kMaxRadius);

    _running = true;
    _setStatus('🚀 Started @ radius=$_radiusTiles');
    _activeLoop = _doTick().catchError((e) {
      TrafficLog.add('ER', '[Desert-Auto] fatal: $e');
      _running = false;
      _setStatus('❌ Fatal: $e');
    });
  }

  void stop() {
    _running = false;
    _setStatus('🛑 Stopped');
  }

  // ═══════════════════════════════════════════════════════
  //  MAIN LOOP
  // ═══════════════════════════════════════════════════════
  Future<void> _doTick() async {
    while (_running) {
      try {
        if (!await isEnabled()) {
          _setStatus('⏸️ Disabled');
          _running = false;
          return;
        }
        if (_client == null || _svc == null) {
          await Future.delayed(const Duration(seconds: 60));
          continue;
        }

        // ───── Desert castle ─────
        final prefs = await SharedPreferences.getInstance();
        final desertArea = prefs.getInt(_kSourceAreaId) ?? 0;
        if (desertArea == 0) {
          _setStatus('❌ No source area set');
          await Future.delayed(const Duration(seconds: 60));
          continue;
        }

        final castles = await _client!.getCastles();
        OwnedCastle? desert;
        for (final c in castles) {
          if (c.areaId == desertArea) { desert = c; break; }
        }
        if (desert == null) {
          _setStatus('❌ Desert castle $desertArea not found');
          await Future.delayed(const Duration(seconds: 60));
          continue;
        }

        // ───── Replenish (transfer every 20 min if < 30 units) ─────
        await _maybeReplenish(desert);
        if (!_running) return;

        // ───── Initial scan ─────
        if (_towers.isEmpty) {
          await _doScan(desert);
          if (_towers.isEmpty) {
            _setStatus('💤 No towers found @ $_radiusTiles, retry 60s');
            await Future.delayed(const Duration(seconds: 60));
            continue;
          }
        }

        // ───── Dead towers → 4h cooldown ─────
        for (final t in _towers) {
          if (t.isDead && !_svc!.isTowerInCooldown(t) && !_shouldSkipTower(t)) {
            await _svc!.markTowerAttacked(t, minutes: kTowerCooldownMin);
            _setStatus('💀 ${t.coordsLabel} rs=${t.rs} → 4h');
          }
        }

        // ───── Candidates ─────
        final candidates = _getCandidates();
        if (candidates.isEmpty) {
          await _handleEmptyCandidates(desert);
          continue;
        }

        // ───── Units check ─────
        final catalog = await _client!.loadCatalog();
        final freshUnits = await _client!
            .getCastleUnits(desert.kingdomId, desert.areaId, catalog);
        final sendable =
            freshUnits.where((u) => u.isCombat && u.amount > 0).toList();
        final totalUnits =
            sendable.fold<int>(0, (s, u) => s + u.amount);

        if (totalUnits < kMinUnitsToAttack) {
          _setStatus('💤 Low units $totalUnits < $kMinUnitsToAttack');
          await Future.delayed(const Duration(minutes: 2));
          continue;
        }

        // ───── Commanders check ─────
        final cmds = await _client!.getCommanders();
        var freeLords = cmds.where((c) => !c.isBusy).toList();
        final selectedCommanderIds = await getCommanderIds();
        if (selectedCommanderIds.isNotEmpty) {
          freeLords = freeLords
              .where((c) => selectedCommanderIds.contains(c.lord.id))
              .toList();
        }
        if (freeLords.isEmpty) {
          _setStatus('💤 No free commanders, wait 30s');
          await Future.delayed(const Duration(seconds: 30));
          continue;
        }

        // ───── Attack closest candidate ─────
        final tower = candidates.first;
        await _attackOne(tower, desert, sendable, freeLords);

        // ───── 15s between attacks ─────
        if (!_running) return;
        _setStatus('⏳ Wait ${kInterAttackDelaySec}s');
        await Future.delayed(const Duration(seconds: kInterAttackDelaySec));
      } catch (e) {
        _setStatus('❌ Loop error: $e');
        await Future.delayed(const Duration(seconds: 30));
      }
    }
    _setStatus('🛑 Stopped');
  }

  // ═══════════════════════════════════════════════════════
  //  Candidates
  // ═══════════════════════════════════════════════════════
  List<DesertTower> _getCandidates() {
    final now = DateTime.now();
    return _towers
        .where((t) => !t.isDead)
        .where((t) => !_svc!.isTowerInCooldown(t))
        .where((t) => !_shouldSkipTower(t))
        .where((t) {
          final skip = _tempSkip[t.key];
          if (skip == null) return true;
          if (skip.isBefore(now)) { _tempSkip.remove(t.key); return true; }
          return false;
        })
        .where((t) => !_attackingNow.contains(t.key))
        .toList()
      ..sort((a, b) => a.distanceFromSource.compareTo(b.distanceFromSource));
  }

  // ═══════════════════════════════════════════════════════
  //  Handle empty candidates → expand radius / wait cooldown
  // ═══════════════════════════════════════════════════════
  Future<void> _handleEmptyCandidates(OwnedCastle desert) async {
    // 1) في tempSkip قصير؟ استناه
    final tempWait = _soonestTempSkipRemaining();
    if (tempWait > Duration.zero && tempWait <= const Duration(seconds: 30)) {
      _setStatus('⏳ Lord busy, wait ${tempWait.inSeconds}s');
      await Future.delayed(tempWait + const Duration(milliseconds: 500));
      return;
    }

    // 2) وسّع الـ radius
    _radiusTiles += kRadiusStep;
    if (_radiusTiles > kMaxRadius) {
      _radiusTiles = kMaxRadius;
      final wait = _soonestCooldownRemaining();
      if (wait > Duration.zero) {
        _setStatus('⏳ Max radius, wait ${_fmtDuration(wait)}');
        await _waitForCooldown(desert);
        if (!_running) return;
      }
      _radiusTiles = 5;
    }

    // 3) rescan
    _setStatus('🔍 Rescan @ $_radiusTiles');
    await _doScan(desert);
    if (!_running) return;
    await Future.delayed(const Duration(seconds: kInterAttackDelaySec));
  }

  // ═══════════════════════════════════════════════════════
  //  Scan
  // ═══════════════════════════════════════════════════════
  Future<void> _doScan(OwnedCastle desert) async {
    if (_scanInProgress) return;
    _scanInProgress = true;
    try {
      _setStatus('🔍 Scanning @ radius=$_radiusTiles');
      final found = await _svc!.scanArea(
        source: desert,
        radiusTiles: _radiusTiles,
      );
      found.sort(
          (a, b) => a.distanceFromSource.compareTo(b.distanceFromSource));
      _towers = found;
      towersScanned = _towers.length;
      TrafficLog.add('ST',
          '[Desert-Auto] scan → ${found.length} towers (dead=${found.where((t) => t.isDead).length}) @ $_radiusTiles');
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Auto] scan error: $e');
      if (e.toString().contains('SCAN_COOLDOWN')) {
        await Future.delayed(const Duration(seconds: 12));
      }
    } finally {
      _scanInProgress = false;
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Attack one tower
  // ═══════════════════════════════════════════════════════
  Future<void> _attackOne(
    DesertTower tower,
    OwnedCastle desert,
    List<CastleUnit> sendable,
    List<CommanderInfo> freeLords,
  ) async {
    _attackingNow.add(tower.key);
    try {
      final p = await SharedPreferences.getInstance();
      final startCap = p.getInt(kCapStartKey) ?? kDefaultCapStart;
      final minCap   = p.getInt(kCapMinKey) ?? kDefaultCapMin;
      final maxCap   = p.getInt(kCapMaxKey) ?? kDefaultCapMax;
      final cap = _capFor(tower, startCap, minCap, maxCap);

      final suggestion = _svc!.suggestCounter(
        available: sendable,
        defenders: DefenderSummary(), // نفس الواجهة القديمة — أعمى
        maxTotal: cap,
      );

      if (suggestion.totalUnits <= 0) {
        _markTowerFailed(tower);
        _setStatus('⚠️ Empty army for ${tower.coordsLabel}');
        return;
      }

      Lord lord;
      try {
        lord = freeLords.firstWhere((c) => c.lord.id != 0).lord;
      } catch (_) {
        lord = freeLords.first.lord;
      }

      _setStatus(
          '⚔️ ${tower.coordsLabel} (${suggestion.totalUnits}/$cap)');

      final result = await _svc!.attack(
        tower: tower,
        source: desert,
        lordId: lord.id,
        leftUnits: suggestion.left,
        middleUnits: suggestion.middle,
        rightUnits: suggestion.right,
        markCooldownAfterSuccess: false, // نتحكم إحنا في الكولداون
      );

      // ✅ نجاح حقيقي: لازم يكون فيه MID فعلي
      if (result.success && (result.movementId ?? -1) > 0) {
        attacksThisSession++;
        _onSuccess(tower, suggestion.totalUnits);
        await _svc!.markTowerAttacked(tower, minutes: kTowerCooldownMin);
        _setStatus('✅ HIT ${tower.coordsLabel} (${suggestion.totalUnits})');
        TrafficLog.add('ST',
            '[Desert-Auto] ✅ HIT ${tower.coordsLabel} units=${suggestion.totalUnits} mid=${result.movementId}');
        return;
      }

      // ✅ result==0 بس مفيش MID → البرج ميت/مفيش معركة
      if (result.success && (result.movementId ?? -1) <= 0) {
        _markTowerFailed(tower);
        await _svc!.markTowerAttacked(tower, minutes: kTowerCooldownMin);
        _setStatus('💀 ${tower.coordsLabel} (no MID → dead)');
        return;
      }

      // ⏸ 218 = القائد مشغول → temp skip 30s
      if (result.error?.contains('218') == true) {
        _tempSkip[tower.key] =
            DateTime.now().add(const Duration(seconds: 30));
        _setStatus('⏸ ${tower.coordsLabel}: lord busy → 30s');
        return;
      }

      // 📉 313 = وحدات كتير
      if (result.error?.contains('313') == true) {
        _on313(tower, cap, minCap);
        if (cap <= minCap) {
          _markTowerFailed(tower);
          _setStatus('💀 ${tower.coordsLabel}: 313 at min cap');
        } else {
          final newCap = _capFor(tower, startCap, minCap, maxCap);
          _tempSkip[tower.key] =
              DateTime.now().add(const Duration(seconds: 60));
          _setStatus('📉 ${tower.coordsLabel}: 313 → cap=$newCap (60s)');
        }
        return;
      }

      // ❌ أي فشل آخر → 4 ساعات
      _markTowerFailed(tower);
      _setStatus('❌ ${tower.coordsLabel}: ${result.error}');
    } catch (e) {
      _markTowerFailed(tower);
      _setStatus('❌ Attack error: $e');
    } finally {
      _attackingNow.remove(tower.key);
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Replenish (transfer from main every 20 min if <30 units)
  // ═══════════════════════════════════════════════════════
  Future<void> _maybeReplenish(OwnedCastle desert) async {
    if (_client == null) return;
    final p = await SharedPreferences.getInstance();

    final lastStr = p.getString(_kLastReplenish);
    if (lastStr != null) {
      final last = DateTime.tryParse(lastStr);
      if (last != null && DateTime.now().difference(last).inMinutes < 20) {
        return;
      }
    }

    final minOff = p.getInt(_kMinOffensive) ?? kMinUnitsToAttack;

    try {
      final catalog = await _client!.loadCatalog();
      final desertUnits = await _client!
          .getCastleUnits(desert.kingdomId, desert.areaId, catalog);

      final offCount = desertUnits
          .where((u) => u.isCombat && !u.isDefensive && u.amount > 0)
          .fold<int>(0, (s, u) => s + u.amount);
      if (offCount >= minOff) return;

      _setStatus('🔄 Need transfer: $offCount < $minOff');

      final castles = await _client!.getCastles();
      OwnedCastle? main;
      for (final c in castles) {
        if (c.areaType == 1) { main = c; break; }
      }
      if (main == null || main.areaId == desert.areaId) return;

      final mainUnits = await _client!
          .getCastleUnits(main.kingdomId, main.areaId, catalog);

      final selectedIds = await getTransferUnitIds();
      var offensiveMain = mainUnits
          .where((u) => u.isCombat && !u.isDefensive && u.amount > 0)
          .toList();
      if (selectedIds.isNotEmpty) {
        offensiveMain = offensiveMain
            .where((u) => selectedIds.contains(u.wodId))
            .toList();
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
      final result =
          await _client!.transfer(source: main, target: desert, units: toTransfer);

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
  //  Cooldown helpers
  // ═══════════════════════════════════════════════════════
  Duration _soonestCooldownRemaining() {
    Duration min = Duration.zero;
    for (final t in _towers) {
      final rem = _svc!.towerCooldownRemaining(t);
      if (rem > Duration.zero && (min == Duration.zero || rem < min)) {
        min = rem;
      }
    }
    for (final d in _failedTowers.values) {
      final rem = d.difference(DateTime.now());
      if (rem > Duration.zero && (min == Duration.zero || rem < min)) {
        min = rem;
      }
    }
    return min;
  }

  Duration _soonestTempSkipRemaining() {
    Duration min = Duration.zero;
    for (final d in _tempSkip.values) {
      final rem = d.difference(DateTime.now());
      if (rem > Duration.zero && (min == Duration.zero || rem < min)) {
        min = rem;
      }
    }
    return min;
  }

  Future<void> _waitForCooldown(OwnedCastle desert) async {
    while (_running && await isEnabled()) {
      final wait = _soonestCooldownRemaining();
      if (wait <= Duration.zero) return;
      final chunk =
          wait > const Duration(minutes: 1) ? const Duration(minutes: 1) : wait;
      await Future.delayed(chunk);
      if (chunk >= const Duration(minutes: 1)) {
        await _maybeReplenish(desert);
      }
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Cap system (نفس الواجهة القديمة)
  // ═══════════════════════════════════════════════════════
  int _capFor(DesertTower t, int startCap, int minCap, int maxCap) {
    final s = _lastSuccessCaps[t.key];
    final f = _lastFailCaps[t.key];
    int cap;
    if (s == null && f == null) {
      cap = startCap;
    } else if (s == null) {
      cap = f! - 20;
    } else if (f == null) {
      cap = s + 15;
    } else {
      cap = s;
    }
    if (cap < minCap) cap = minCap;
    if (cap > maxCap) cap = maxCap;
    return cap;
  }

  void _onSuccess(DesertTower t, int used) {
    _lastSuccessCaps[t.key] = used;
    _saveCaps();
  }

  void _on313(DesertTower t, int attempted, int minCap) {
    _lastFailCaps[t.key] = attempted;
    _saveCaps();
  }

  // ═══════════════════════════════════════════════════════
  //  Failed towers persistence
  // ═══════════════════════════════════════════════════════
  bool _shouldSkipTower(DesertTower t) {
    final at = _failedTowers[t.key];
    if (at == null) return false;
    if (!at.isAfter(DateTime.now())) {
      _failedTowers.remove(t.key);
      _saveFailedTowers();
      return false;
    }
    return true;
  }

  void _markTowerFailed(DesertTower t) {
    _failedTowers[t.key] =
        DateTime.now().add(const Duration(minutes: kFailedCooldownMin));
    _saveFailedTowers();
    TrafficLog.add('ST',
        '[Desert-Auto] ⏸ ${t.coordsLabel} failed → ${kFailedCooldownMin}min');
  }

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
        if (dt != null && dt.isAfter(now)) _failedTowers[e.key] = dt;
      }
    } catch (_) {}
  }

  Future<void> _saveFailedTowers() async {
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final data = <String, String>{};
    for (final e in _failedTowers.entries) {
      if (e.value.isAfter(now)) data[e.key] = e.value.toIso8601String();
    }
    await p.setString(_kFailedTowers, jsonEncode(data));
  }

  // ═══════════════════════════════════════════════════════
  //  Caps persistence
  // ═══════════════════════════════════════════════════════
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

  // ═══════════════════════════════════════════════════════
  //  Utils
  // ═══════════════════════════════════════════════════════
  String _fmtDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }
}