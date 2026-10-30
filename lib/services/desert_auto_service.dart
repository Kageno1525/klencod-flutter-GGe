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

  static const _kEnabled = 'desert_auto_enabled';
  static const _kSourceAreaId = 'desert_auto_source';
  static const _kMinOffensive = 'desert_auto_min_off';
  static const _kLastScan = 'desert_auto_last_scan';
  static const _kLastReplenish = 'desert_auto_last_repl';
  static const _kCommanderIds = 'desert_auto_commander_ids';
  static const _kTransferUnitIds = 'desert_auto_transfer_unit_ids';
  static const _kFailedTowers = 'desert_auto_failed_towers';

  static const int kMinUnitsToAttack = 100;
  static const int kFailedCooldownMin = 240;

  final ValueNotifier<String> statusNotifier = ValueNotifier('Idle');
  final List<AutoStatusEntry> _history = [];
  List<AutoStatusEntry> get statusHistory => List.unmodifiable(_history);

  int attacksThisSession = 0;
  int towersScanned = 0;

  Timer? _timer;
  StreamSubscription? _xtSub;
  bool _running = false;
  DesertAttackService? _svc;
  GgeClient? _client;
  List<DesertTower> _towers = [];
  List<DesertTower> get towers => List.unmodifiable(_towers);

  final Map<String, DateTime> _failedTowers = {};

  // ✅ Locks
  Future<void>? _activeTick;
  final Set<String> _attackingNow = {};
  final Set<String> _attackedThisTick = {};
  bool _scanInProgress = false;

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
    await p.setStringList(
        _kCommanderIds, ids.map((e) => e.toString()).toList());
    TrafficLog.add('ST', '[Desert-Auto] commander filter: $ids');
  }

  Future<List<int>> getTransferUnitIds() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_kTransferUnitIds) ?? [];
    return raw.map((s) => int.tryParse(s) ?? 0).where((i) => i > 0).toList();
  }

  Future<void> setTransferUnitIds(List<int> ids) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        _kTransferUnitIds, ids.map((e) => e.toString()).toList());
    TrafficLog.add('ST', '[Desert-Auto] transfer filter: $ids');
  }

  bool get isRunning => _running;

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
      if (_failedTowers.isNotEmpty) {
        TrafficLog.add('ST',
            '[Desert-Auto] loaded ${_failedTowers.length} failed towers from disk');
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

  // ✅ start ينتظر أي tick قديمة قبل ما يبدأ
  Future<void> start(GgeClient client, {int? sourceAreaId}) async {
    if (_running) return;

    if (_activeTick != null) {
      TrafficLog.add('ST', '[Desert-Auto] ⏳ Waiting for old tick...');
      try {
        await _activeTick!.timeout(const Duration(seconds: 60));
      } catch (_) {
        TrafficLog.add('ER', '[Desert-Auto] Old tick timeout, forcing');
      }
    }

    _attackingNow.clear();
    _attackedThisTick.clear();
    _scanInProgress = false;

    _client = client;
    _svc = DesertAttackService(client);
    await _svc!.loadCooldowns();
    await _loadFailedTowers();

    attacksThisSession = 0;
    towersScanned = 0;

    _xtSub?.cancel();
    _xtSub = client.xtStream.listen((msg) {
      if (msg.command != 'sne' || msg.payload == null) return;
      try {
        final data = jsonDecode(msg.payload!) as Map<String, dynamic>;
        final msgs = data['MSG'] as List?;
        if (msgs == null) return;
        for (final m in msgs) {
          if (m is! List || m.length < 2) continue;
          final msgId = m[0] as int?;
          final type = m[1] as int?;
          if (msgId == null || type != 4) continue;
          _svc?.captureSneReport(msgId);
          TrafficLog.add('ST', '[Desert-Auto] 📩 captured sne msgId=$msgId');
        }
      } catch (e) {
        TrafficLog.add('ER', '[Desert-Auto] sne parse error: $e');
      }
    });

    if (sourceAreaId != null && sourceAreaId > 0) {
      await setSource(sourceAreaId);
    }

    _running = true;
    _setStatus('🚀 Started');
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

  bool _shouldSkipTower(DesertTower t, {int minutes = kFailedCooldownMin}) {
    final at = _failedTowers[t.key];
    if (at == null) return false;
    if (DateTime.now().difference(at).inMinutes >= minutes) {
      _failedTowers.remove(t.key);
      _saveFailedTowers();
      return false;
    }
    return true;
  }

  void _markTowerFailed(DesertTower t) {
    _failedTowers[t.key] =
        DateTime.now().add(Duration(minutes: kFailedCooldownMin));
    _saveFailedTowers();
    TrafficLog.add('ST',
        '[Desert-Auto] ⏸️ marked ${t.coordsLabel} failed ($kFailedCooldownMin min)');
  }

  // ✅ tick مع قفل حقيقي
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
      await _maybeRescan();
      if (!_running) return;
      await _tryAttackTowers();

      if (_running && statusNotifier.value == initialStatus) {
        _setStatus('💤 Idle  ·  ⏱ 30s');
      }
    } catch (e) {
      _setStatus('❌ Error: $e');
    }
  }

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
      final desertUnits = await _client!.getCastleUnits(
          desert.kingdomId, desert.areaId, catalog);

      final offCount = desertUnits
          .where((u) => u.isCombat && !u.isDefensive && u.amount > 0)
          .fold<int>(0, (s, u) => s + u.amount);
      if (offCount >= minOff) return;

      _setStatus('🔄 Need transfer: $offCount < $minOff');

      final mainUnits = await _client!.getCastleUnits(
          main.kingdomId, main.areaId, catalog);

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
      final result = await _client!.transfer(
        source: main,
        target: desert,
        units: toTransfer,
      );

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

  Future<void> _maybeRescan() async {
    if (_client == null || _svc == null) return;
    if (_scanInProgress) {
      TrafficLog.add('ST', '[Desert-Auto] ⏭️ Scan already running, skip');
      return;
    }

    final p = await SharedPreferences.getInstance();
    final lastStr = p.getString(_kLastScan);
    if (lastStr != null) {
      final last = DateTime.tryParse(lastStr);
      if (last != null &&
          DateTime.now().difference(last).inMinutes < 5 &&
          _towers.isNotEmpty) {
        return;
      }
    }

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

      final settings = await DesertAttackSettings.load();
      final radius = settings.radiusTiles;

      _setStatus('🔍 Scanning towers ($radius tile)...');
      _towers = await _svc!.scanArea(source: desert, radiusTiles: radius);
      towersScanned = _towers.length;
      await p.setString(_kLastScan, DateTime.now().toIso8601String());
      _setStatus('✓ Found ${_towers.length} towers @ $radius');
    } catch (e) {
      _setStatus('❌ Scan error: $e');
    } finally {
      _scanInProgress = false;
    }
  }

  // ✅✅✅ Retry على 313 + صبر 3 ثواني
  Future<void> _tryAttackTowers() async {
    if (_client == null || _svc == null) return;

    final p = await SharedPreferences.getInstance();
    final desertArea = p.getInt(_kSourceAreaId) ?? 0;
    if (desertArea == 0) return;

    try {
      final castles = await _client!.getCastles();
      OwnedCastle? desert;
      for (final c in castles) {
        if (c.areaId == desertArea) desert = c;
      }
      if (desert == null) return;

      final catalog = await _client!.loadCatalog();

      int attacksThisTick = 0;
      int spyAttempts = 0;
      const int maxSpyAttempts = 10;

      while (_running && spyAttempts < maxSpyAttempts) {
        final freshUnits = await _client!.getCastleUnits(
            desert.kingdomId, desert.areaId, catalog);
        final sendable = freshUnits
            .where((u) => u.isCombat && u.amount > 0)
            .toList();
        final totalUnits =
            sendable.fold<int>(0, (s, u) => s + u.amount);

        if (totalUnits < kMinUnitsToAttack) {
          _setStatus(
              '💤 Idle — units: $totalUnits (< $kMinUnitsToAttack)');
          return;
        }

        final cmds = await _client!.getCommanders();
        var freeLords = cmds.where((c) => !c.isBusy).toList();
        final selectedCommanderIds = await getCommanderIds();
        if (selectedCommanderIds.isNotEmpty) {
          freeLords = freeLords
              .where((c) => selectedCommanderIds.contains(c.lord.id))
              .toList();
        }
        if (freeLords.isEmpty) {
          _setStatus(selectedCommanderIds.isEmpty
              ? '💤 Idle — no free commanders'
              : '💤 Idle — no free selected commanders');
          return;
        }

        final candidates = _towers
            .where((t) => !_svc!.isTowerInCooldown(t))
            .where((t) => !_shouldSkipTower(t))
            .where((t) => !_attackedThisTick.contains(t.key))
            .where((t) => !_attackingNow.contains(t.key))
            .toList()
          ..sort((a, b) =>
              a.distanceFromSource.compareTo(b.distanceFromSource));

        if (candidates.isEmpty) {
          _setStatus('⏳ No candidate towers (all cooldown/failed)');
          return;
        }

        final tower = candidates.first;
        _attackingNow.add(tower.key);

        try {
          _setStatus('🔍 Spying ${tower.coordsLabel}...');
          spyAttempts++;
          await _spyAndFetch(tower, desert, catalog);
          if (!_running) return;

          final report = _svc!.getCachedReport(tower);
          if (report == null || !report.matches(tower)) {
            _setStatus('❌ Spy failed for ${tower.coordsLabel}');
            _markTowerFailed(tower);
            continue;
          }

          if (report.isDead) {
            _setStatus(
                '💀 ${tower.coordsLabel} dead (respawn in ${report.rs}s)');
            _markTowerFailed(tower);
            continue;
          }

          final viable = _svc!.analyzeAttack(
            report: report,
            myUnitCount: totalUnits,
            myUnits: sendable.map((u) => [u.wodId, u.amount]).toList(),
          );

          if (!viable.likelyWin) {
            _setStatus('⏭️ Skip ${tower.coordsLabel}: ${viable.hint}');
            _markTowerFailed(tower);
            continue;
          }

          final suggestion = _svc!.suggestCounter(
            available: sendable,
            defenders: report.toDefenderSummary(),
          );

          if (suggestion.totalUnits <= 0 ||
              (suggestion.left.isEmpty &&
                  suggestion.middle.isEmpty &&
                  suggestion.right.isEmpty)) {
            _setStatus('⚠️ Empty suggestion for ${tower.coordsLabel}');
            _markTowerFailed(tower);
            continue;
          }

          Lord lord;
          try {
            lord = freeLords.firstWhere((c) => c.lord.id != 0).lord;
          } catch (_) {
            lord = freeLords.first.lord;
          }

          _setStatus(
              '⚔️ Attacking ${tower.coordsLabel} (${suggestion.totalUnits})...');

          final result = await _svc!.attack(
            tower: tower,
            source: desert,
            lordId: lord.id,
            leftUnits: suggestion.left,
            middleUnits: suggestion.middle,
            rightUnits: suggestion.right,
          );

          if (result.success) {
            attacksThisTick++;
            attacksThisSession++;
            _attackedThisTick.add(tower.key);
            TrafficLog.add('ST',
                '[Desert-Auto] ✅ HIT ${tower.coordsLabel} mid=${result.movementId} '
                '($attacksThisTick this tick, $attacksThisSession session)');
            _setStatus('✅ Hit ${tower.coordsLabel}! (#$attacksThisTick)');
            _setStatus('⏱️ 3s before next tower...');
            await Future.delayed(const Duration(seconds: 3));
            if (!_running) return;
            continue;
          }

          // ✅✅✅ Retry on 313
          final is313 = result.error?.contains('313') ?? false;
          if (is313) {
            TrafficLog.add('ST',
                '[Desert-Auto] ⚠️ 313 on ${tower.coordsLabel} — retry with 60% units');
            _setStatus('⚠️ 313 — retry with fewer units...');

            List<List<int>> reduce(List<List<int>> units) {
              final out = <List<int>>[];
              for (final u in units) {
                if (u.length < 2) continue;
                final newAmt = (u[1] * 0.6).round();
                if (newAmt > 0) out.add([u[0], newAmt]);
              }
              return out;
            }

            final retryLeft = reduce(suggestion.left);
            final retryMiddle = reduce(suggestion.middle);
            final retryRight = reduce(suggestion.right);
            final retryTotal =
                retryLeft.fold<int>(0, (s, e) => s + e[1]) +
                    retryMiddle.fold<int>(0, (s, e) => s + e[1]) +
                    retryRight.fold<int>(0, (s, e) => s + e[1]);

            if (retryTotal > 0) {
              await Future.delayed(const Duration(seconds: 2));
              TrafficLog.add('ST',
                  '[Desert-Auto] 🔁 Retry ${tower.coordsLabel} with $retryTotal units');
              final retryResult = await _svc!.attack(
                tower: tower,
                source: desert,
                lordId: lord.id,
                leftUnits: retryLeft,
                middleUnits: retryMiddle,
                rightUnits: retryRight,
              );

              if (retryResult.success) {
                attacksThisTick++;
                attacksThisSession++;
                _attackedThisTick.add(tower.key);
                TrafficLog.add('ST',
                    '[Desert-Auto] ✅ HIT (retry) ${tower.coordsLabel} with $retryTotal units');
                _setStatus('✅ Hit ${tower.coordsLabel} (retry)');
                await Future.delayed(const Duration(seconds: 3));
                continue;
              } else {
                TrafficLog.add('ER',
                    '[Desert-Auto] ❌ retry failed: ${retryResult.error}');
              }
            }
            _setStatus('❌ ${tower.coordsLabel}: 313 (tower full)');
            _markTowerFailed(tower);
            continue;
          }

          TrafficLog.add('ER',
              '[Desert-Auto] ❌ ${tower.coordsLabel}: ${result.error}');
          _setStatus('❌ ${tower.coordsLabel}: ${result.error}');
          _markTowerFailed(tower);
          continue;
        } finally {
          _attackingNow.remove(tower.key);
        }
      }

      if (spyAttempts >= maxSpyAttempts) {
        _setStatus('🔁 Tried $spyAttempts towers, will continue next tick');
      }
    } catch (e) {
      _setStatus('❌ Attack loop error: $e');
    }
  }

  Future<void> _spyAndFetch(
    DesertTower tower,
    OwnedCastle desert,
    Map<int, UnitCatalogEntry> catalog,
  ) async {
    if (_svc == null) return;

    _svc!.latestSpyMessageId = null;
    _svc!.latestSpyMessageIdAt = null;

    final spyRes = await _svc!.spy(tower: tower, source: desert);
    if (!spyRes.success) {
      _setStatus('❌ Spy failed: ${spyRes.error}');
      return;
    }

    _setStatus('⏳ Waiting for report...');

    int? msgId;
    for (int i = 0; i < 15; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!_running) return;
      msgId = _svc!.latestSpyMessageId;
      if (msgId != null) break;
    }

    if (msgId == null) {
      _setStatus('⚠️ sne didn\'t arrive (30s timeout)');
      return;
    }

    _setStatus('📥 Fetching report msgId=$msgId...');
    final report = await _svc!.fetchSpyReport(
      messageId: msgId,
      tower: tower,
      catalog: catalog,
    );

    if (report == null) {
      _setStatus('❌ bsd parse failed');
    } else {
      _setStatus(
          '✓ Report: ${report.totalEnemyUnits} units, RS=${report.rs}');
    }
  }
}