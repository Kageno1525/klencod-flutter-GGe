import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';
import 'desert_attack_service.dart';

class DesertAutoService {
  static final DesertAutoService instance = DesertAutoService._();
  DesertAutoService._();

  static const _kEnabled = 'desert_auto_enabled';
  static const _kSourceAreaId = 'desert_auto_source';
  static const _kMinOffensive = 'desert_auto_min_off';
  static const _kSafetyRatio = 'desert_auto_safety';
  static const _kLastScan = 'desert_auto_last_scan';
  static const _kLastReplenish = 'desert_auto_last_repl';

  /// ✅ الحالة الحية اللي بتظهر في الـ UI
  final ValueNotifier<String> statusNotifier = ValueNotifier('Idle');

  Timer? _timer;
  bool _running = false;
  bool _processing = false;
  DesertAttackService? _svc;
  GgeClient? _client;

  List<DesertTower> _towers = [];

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
    TrafficLog.add('ST', '[Desert-Auto] source set to $areaId');
  }

  Future<int> getSource() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kSourceAreaId) ?? 0;
  }

  bool get isRunning => _running;

  Future<void> start(GgeClient client, {int? sourceAreaId}) async {
    if (_running) {
      TrafficLog.add('ST', '[Desert-Auto] already running, skipping start');
      return;
    }
    _client = client;
    _svc = DesertAttackService(client);
    await _svc!.loadCooldowns();

    // ✅ سجّل القلعة المصدر
    if (sourceAreaId != null && sourceAreaId > 0) {
      await setSource(sourceAreaId);
    }

    _running = true;
    _processing = false;
    _setStatus('🚀 Started');

    // شغل الآن ثم كل 90 ثانية
    _tick();

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 90), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _processing = false;
    _setStatus('🛑 Stopped');
  }

  void _setStatus(String s) {
    statusNotifier.value = s;
    TrafficLog.add('ST', '[Desert-Auto] $s');
  }

  Future<void> _tick() async {
    if (!_running || _processing) return;
    if (!await isEnabled()) {
      _setStatus('⏸️ Disabled');
      return;
    }
    if (_client == null || _svc == null) return;

    _processing = true;
    _setStatus('⏱️ Checking...');

    try {
      await _maybeReplenish();
      if (!_running) return;

      await _maybeRescan();
      if (!_running) return;

      await _tryAttackTowers();

      if (_running && !statusNotifier.value.contains('❌')) {
        _setStatus('✅ Idle — next in 90s');
      }
    } catch (e) {
      _setStatus('❌ Error: $e');
    } finally {
      _processing = false;
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Auto-Replenish from main castle
  // ═══════════════════════════════════════════════════════
  Future<void> _maybeReplenish() async {
    if (_client == null) return;
    final p = await SharedPreferences.getInstance();

    final desertArea = p.getInt(_kSourceAreaId) ?? 0;
    if (desertArea == 0) {
      _setStatus('⚠️ Select a desert castle first');
      return;
    }

    // Cooldown 20 min (النقل بين الممالك بياخد 10-15 دقيقة)
    final lastStr = p.getString(_kLastReplenish);
    if (lastStr != null) {
      final last = DateTime.tryParse(lastStr);
      if (last != null) {
        final elapsed = DateTime.now().difference(last).inMinutes;
        if (elapsed < 20) {
          _setStatus('⏳ Transfer in transit (${elapsed}m ago)');
          return;
        }
      }
    }

    final minOff = p.getInt(_kMinOffensive) ?? 100;

    try {
      final castles = await _client!.getCastles();
      OwnedCastle? main;
      OwnedCastle? desert;

      for (final c in castles) {
        if (c.areaType == 1) main = c;
        if (c.areaId == desertArea) desert = c;
      }

      if (desert == null) {
        _setStatus('⚠️ Desert castle not found');
        return;
      }
      if (main == null) {
        _setStatus('⚠️ No main castle (areaType=1)');
        return;
      }
      if (main.areaId == desert.areaId) {
        _setStatus('⚠️ Main and desert are the same');
        return;
      }

      final catalog = await _client!.loadCatalog();
      final desertUnits = await _client!.getCastleUnits(
          desert.kingdomId, desert.areaId, catalog);

      final offCount = desertUnits
          .where((u) => u.isCombat && !u.isDefensive)
          .fold<int>(0, (s, u) => s + u.amount);

      if (offCount >= minOff) {
        _setStatus('✓ Units OK ($offCount ≥ $minOff)');
        return;
      }

      _setStatus('🔄 Need transfer: $offCount < $minOff');

      final mainUnits = await _client!.getCastleUnits(
          main.kingdomId, main.areaId, catalog);
      final offensiveMain = mainUnits
          .where((u) => u.isCombat && !u.isDefensive && u.amount > 0)
          .toList();

      if (offensiveMain.isEmpty) {
        _setStatus('❌ Main has no offensive units');
        return;
      }

      final toTransfer = <List<int>>[];
      for (final u in offensiveMain.take(10)) {
        toTransfer.add([u.wodId, u.amount]);
      }

      _setStatus('📤 Transferring ${toTransfer.length} types from main...');

      final result = await _client!.transfer(
        source: main,
        target: desert,
        units: toTransfer,
      );

      if (result.success) {
        await p.setString(
            _kLastReplenish, DateTime.now().toIso8601String());
        _setStatus('✅ Transfer queued (arrives in ~10-15m)');
      } else {
        _setStatus('❌ Transfer failed: ${result.error}');
      }
    } catch (e) {
      _setStatus('❌ Replenish error: $e');
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Rescan every 5 min
  // ═══════════════════════════════════════════════════════
  Future<void> _maybeRescan() async {
    if (_client == null || _svc == null) return;
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

    try {
      final castles = await _client!.getCastles();
      OwnedCastle? desert;
      for (final c in castles) {
        if (c.areaId == desertArea) desert = c;
      }
      if (desert == null) return;

      _setStatus('🔍 Scanning towers...');
      _towers = await _svc!.scanArea(source: desert, radiusTiles: 50);
      await p.setString(_kLastScan, DateTime.now().toIso8601String());
      _setStatus('✓ Found ${_towers.length} towers');
    } catch (e) {
      _setStatus('❌ Scan error: $e');
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Attack towers
  // ═══════════════════════════════════════════════════════
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
      final units = await _client!.getCastleUnits(
          desert.kingdomId, desert.areaId, catalog);
      final unlocked = _client!.getUnlockedForArea(desert.areaId);
      final sendable = units
          .where((u) => unlocked.contains(u.wodId) && u.amount > 0)
          .where((u) => u.isCombat)
          .toList();

      if (sendable.isEmpty) {
        _setStatus('⏳ Waiting for units in desert castle');
        return;
      }

      final cmds = await _client!.getCommanders();
      final freeLords = cmds.where((c) => !c.isBusy).toList();
      if (freeLords.isEmpty) {
        _setStatus('⏳ All lords busy');
        return;
      }

      final candidates = _towers
          .where((t) => !_svc!.isTowerInCooldown(t))
          .take(3)
          .toList();

      if (candidates.isEmpty) {
        _setStatus('⏳ No towers available (all in cooldown)');
        return;
      }

      for (final tower in candidates) {
        if (!_running) break;

        final cachedReport = _svc!.getCachedReport(tower);
        if (cachedReport == null ||
            DateTime.now().difference(cachedReport.fetchedAt).inMinutes > 10) {
          _setStatus('🔍 Spying ${tower.coordsLabel}...');
          await _spyAndFetch(tower, desert, catalog);
          await Future.delayed(const Duration(seconds: 30));
          continue;
        }

        final totalAvail =
            sendable.fold<int>(0, (s, u) => s + u.amount);
        final viable = _svc!.analyzeAttack(
          report: cachedReport,
          myUnitCount: totalAvail,
          myUnits: sendable.map((u) => [u.wodId, u.amount]).toList(),
        );

        if (!viable.likelyWin) {
          _setStatus(
              '⏭️ Skip ${tower.coordsLabel}: ${viable.hint}');
          continue;
        }

        final suggestion = _svc!.suggestCounter(
          available: sendable,
          defenders: cachedReport.toDefenderSummary(),
        );

        Lord lord;
        try {
          lord = freeLords.firstWhere((c) => c.lord.id != 0).lord;
        } catch (_) {
          lord = freeLords.first.lord;
        }

        _setStatus(
            '⚔️ Attacking ${tower.coordsLabel} (${suggestion.totalUnits} units)...');

        final result = await _svc!.attack(
          tower: tower,
          source: desert,
          lordId: lord.id,
          leftUnits: suggestion.left,
          middleUnits: suggestion.middle,
          rightUnits: suggestion.right,
        );

        if (result.success) {
          _setStatus('✅ Hit ${tower.coordsLabel}!');
          await Future.delayed(const Duration(seconds: 8));
          return; // برج واحد في كل tick عشان الأمان
        } else {
          _setStatus('❌ Attack failed: ${result.error}');
        }
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
    final spyRes = await _svc!.spy(tower: tower, source: desert);
    if (!spyRes.success) {
      _setStatus('❌ Spy failed: ${spyRes.error}');
      return;
    }
    _setStatus('⏳ Waiting for report...');
    await Future.delayed(const Duration(seconds: 25));
    final msgId = _svc!.latestSpyMessageId;
    if (msgId == null) {
      _setStatus('⚠️ No report received');
      return;
    }
    final report = await _svc!.fetchSpyReport(
      messageId: msgId,
      catalog: catalog,
    );
    if (report == null) {
      _setStatus('❌ Report parse failed');
    } else {
      _setStatus('✓ Report received');
    }
  }
}