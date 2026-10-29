import 'dart:async';
import 'dart:convert';
import 'dart:math';
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

  bool get isRunning => _running;

  Future<void> start(GgeClient client) async {
    if (_running) return;
    _client = client;
    _svc = DesertAttackService(client);
    await _svc!.loadCooldowns();
    _running = true;
    TrafficLog.add('ST', '[Desert-Auto] 🚀 started');

    _timer?.cancel();
    // كل 90 ثانية
    _timer = Timer.periodic(const Duration(seconds: 90), (_) => _tick());
    _tick(); // شغل الآن
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    TrafficLog.add('ST', '[Desert-Auto] 🛑 stopped');
  }

  Future<void> _tick() async {
    if (!_running || _processing) return;
    if (!await isEnabled()) return;
    if (_client == null || _svc == null) return;

    _processing = true;
    try {
      // 1. Auto-replenish (كل 5 دقائق)
      await _maybeReplenish();

      // 2. Rescan كل 5 دقائق
      await _maybeRescan();

      // 3. جرب أبراج جاهزة
      await _tryAttackTowers();
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Auto] tick error: $e');
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
    final lastStr = p.getString(_kLastReplenish);
    if (lastStr != null) {
      final last = DateTime.tryParse(lastStr);
      if (last != null &&
          DateTime.now().difference(last).inMinutes < 5) {
        return;
      }
    }

    final desertArea = p.getInt(_kSourceAreaId) ?? 0;
    if (desertArea == 0) return;
    final minOff = p.getInt(_kMinOffensive) ?? 100;

    try {
      final castles = await _client!.getCastles();
      // Main castle = areaType 1
      OwnedCastle? main;
      OwnedCastle? desert;
      for (final c in castles) {
        if (c.areaType == 1) main = c;
        if (c.areaId == desertArea) desert = c;
      }
      if (main == null || desert == null) return;

      final catalog = await _client!.loadCatalog();
      final desertUnits = await _client!.getCastleUnits(
          desert.kingdomId, desert.areaId, catalog);

      final offCount = desertUnits
          .where((u) => u.isCombat && !u.isDefensive)
          .fold<int>(0, (s, u) => s + u.amount);
      if (offCount >= minOff) return;

      TrafficLog.add('ST',
          '[Desert-Auto] 🔄 replenish needed: $offCount < $minOff');

      // Transfer from main
      final mainUnits = await _client!.getCastleUnits(
          main.kingdomId, main.areaId, catalog);
      final toTransfer = <List<int>>[];
      for (final u in mainUnits.where((u) => u.isCombat && !u.isDefensive)) {
        if (u.amount > 0 && toTransfer.length < 10) {
          toTransfer.add([u.wodId, u.amount]);
        }
      }
      if (toTransfer.isEmpty) return;

      final result = await _client!.transfer(
        source: main,
        target: desert,
        units: toTransfer,
      );
      if (result.success) {
        TrafficLog.add('ST', '[Desert-Auto] ✅ replenished from main');
        await p.setString(_kLastReplenish, DateTime.now().toIso8601String());
      } else {
        TrafficLog.add('ER',
            '[Desert-Auto] replenish failed: ${result.error}');
      }
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Auto] replenish error: $e');
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Rescan (every 5 min)
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

      _towers = await _svc!.scanArea(
        source: desert,
        radiusTiles: 50,
      );
      await p.setString(_kLastScan, DateTime.now().toIso8601String());
      TrafficLog.add('ST', '[Desert-Auto] scanned ${_towers.length} towers');
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Auto] rescan error: $e');
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Attack towers
  // ═══════════════════════════════════════════════════════
  Future<void> _tryAttackTowers() async {
    if (_client == null || _svc == null) return;

    final p = await SharedPreferences.getInstance();
    final desertArea = p.getInt(_kSourceAreaId) ?? 0;
    final safety = (p.getInt(_kSafetyRatio) ?? 200) / 100.0;

    if (desertArea == 0) return;

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
      TrafficLog.add('ST', '[Desert-Auto] no combat units available');
      return;
    }

    final cmds = await _client!.getCommanders();
    final freeLords = cmds.where((c) => !c.isBusy).toList();
    if (freeLords.isEmpty) {
      TrafficLog.add('ST', '[Desert-Auto] no free lords');
      return;
    }

    // جرب أول 3 أبراج جاهزة
    final candidates = _towers
        .where((t) => !_svc!.isTowerInCooldown(t))
        .take(3)
        .toList();

    for (final tower in candidates) {
      if (!_running) break;

      // لو مفيش spy حديث → تجسس
      final cachedReport = _svc!.getCachedReport(tower);
      if (cachedReport == null ||
          DateTime.now().difference(cachedReport.fetchedAt).inMinutes > 10) {
        await _spyAndFetch(tower, desert, catalog);
        await Future.delayed(const Duration(seconds: 30));
        continue;
      }

      // تحليل الهجوم
      final viable = _svc!.analyzeAttack(
        report: cachedReport,
        myUnitCount: sendable.fold<int>(0, (s, u) => s + u.amount),
        myUnits: sendable.map((u) => [u.wodId, u.amount]).toList(),
      );

      if (!viable.likelyWin) {
        TrafficLog.add('ST',
            '[Desert-Auto] ⏭️ skip ${tower.coordsLabel}: ${viable.hint}');
        continue;
      }

      // هو هينجح → اعمل التوزيع
      final suggestion = _svc!.suggestCounter(
        available: sendable,
        defenders: cachedReport.toDefenderSummary(),
      );

      // اختر لورد فاضي
      Lord lord;
      try {
        lord = freeLords.firstWhere((c) => c.lord.id != 0).lord;
      } catch (_) {
        lord = freeLords.first.lord;
      }

      final result = await _svc!.attack(
        tower: tower,
        source: desert,
        lordId: lord.id,
        leftUnits: suggestion.left,
        middleUnits: suggestion.middle,
        rightUnits: suggestion.right,
      );

      if (result.success) {
        TrafficLog.add('ST',
            '[Desert-Auto] ⚔️ HIT ${tower.coordsLabel} (${suggestion.totalUnits} units)');
        await Future.delayed(const Duration(seconds: 8));
      } else {
        TrafficLog.add('ER',
            '[Desert-Auto] attack failed ${tower.coordsLabel}: ${result.error}');
      }
    }
  }

  Future<void> _spyAndFetch(
    DesertTower tower,
    OwnedCastle desert,
    Map<int, UnitCatalogEntry> catalog,
  ) async {
    if (_svc == null) return;
    TrafficLog.add('ST',
        '[Desert-Auto] 🔍 spying ${tower.coordsLabel}...');
    final spyRes = await _svc!.spy(tower: tower, source: desert);
    if (!spyRes.success) {
      TrafficLog.add('ER', '[Desert-Auto] spy failed: ${spyRes.error}');
      return;
    }
    // استنى الـ sne يجي
    await Future.delayed(const Duration(seconds: 25));
    final msgId = _svc!.latestSpyMessageId;
    if (msgId == null) {
      TrafficLog.add('ST', '[Desert-Auto] no sne received yet');
      return;
    }
    final report = await _svc!.fetchSpyReport(
      messageId: msgId,
      catalog: catalog,
    );
    if (report == null) {
      TrafficLog.add('ER', '[Desert-Auto] bsd fetch failed');
    }
  }
}