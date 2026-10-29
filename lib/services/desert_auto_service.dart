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

  final ValueNotifier<String> statusNotifier = ValueNotifier('Idle');

  Timer? _timer;
  StreamSubscription? _xtSub;
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
  }

  bool get isRunning => _running;

  Future<void> start(GgeClient client, {int? sourceAreaId}) async {
    if (_running) return;

    _client = client;
    _svc = DesertAttackService(client);
    await _svc!.loadCooldowns();

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
    _processing = false;
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
    const initialStatus = '⏱️ Checking...';
    _setStatus(initialStatus);

    try {
      await _maybeReplenish();
      if (!_running) return;
      await _maybeRescan();
      if (!_running) return;
      await _tryAttackTowers();

      if (_running) {
        final current = statusNotifier.value;
        if (current == initialStatus) {
          _setStatus('💤 Idle  ·  ⏱ 30s');
        } else if (!current.contains('❌')) {
          _setStatus('$current  ·  ⏱ 30s');
        }
      }
    } catch (e) {
      _setStatus('❌ Error: $e');
    } finally {
      _processing = false;
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
      if (last != null) {
        final elapsed = DateTime.now().difference(last).inMinutes;
        if (elapsed < 20) {
          _setStatus('🚚 Units in transit (${elapsed}m ago)');
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

      _setStatus('📤 Transferring ${toTransfer.length} types...');
      final result = await _client!.transfer(
        source: main,
        target: desert,
        units: toTransfer,
      );

      if (result.success) {
        await p.setString(
            _kLastReplenish, DateTime.now().toIso8601String());
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

      // ✅ نقرأ النطاق من الإعدادات المحفوظة (الافتراضي 5)
      final settings = await DesertAttackSettings.load();
      final radius = settings.radiusTiles;

      _setStatus('🔍 Scanning towers ($radius tile)...');
      _towers = await _svc!.scanArea(source: desert, radiusTiles: radius);
      await p.setString(_kLastScan, DateTime.now().toIso8601String());
      _setStatus('✓ Found ${_towers.length} towers @ $radius tile');
    } catch (e) {
      _setStatus('❌ Scan error: $e');
    }
  }

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

      final sendable = units
          .where((u) => u.isCombat && u.amount > 0)
          .toList();

      if (sendable.isEmpty) {
        _setStatus('⏳ No combat units in desert');
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
        _setStatus('⏳ All towers in cooldown');
        return;
      }

      for (final tower in candidates) {
        if (!_running) break;

        var report = _svc!.getCachedReport(tower);
        if (report == null ||
            DateTime.now().difference(report.fetchedAt).inMinutes > 10) {
          _setStatus('🔍 Spying ${tower.coordsLabel}...');
          await _spyAndFetch(tower, desert, catalog);
          if (!_running) return;
          report = _svc!.getCachedReport(tower);
          if (report == null || !report.matches(tower)) {
            TrafficLog.add('ER',
                '[Desert-Auto] ⚠️ report invalid for ${tower.coordsLabel} — skip');
            continue;
          }
        }

        final totalAvail =
            sendable.fold<int>(0, (s, u) => s + u.amount);
        final viable = _svc!.analyzeAttack(
          report: report,
          myUnitCount: totalAvail,
          myUnits: sendable.map((u) => [u.wodId, u.amount]).toList(),
        );

        if (!viable.likelyWin) {
          _setStatus('⏭️ Skip ${tower.coordsLabel}: ${viable.hint}');
          continue;
        }

        final suggestion = _svc!.suggestCounter(
          available: sendable,
          defenders: report.toDefenderSummary(),
        );

        if (suggestion.totalUnits <= 0) {
          TrafficLog.add('ER',
              '[Desert-Auto] ⚠️ empty suggestion for ${tower.coordsLabel}: ${suggestion.reason}');
          _setStatus('⚠️ Empty suggestion (check defenders)');
          continue;
        }

        if (suggestion.left.isEmpty &&
            suggestion.middle.isEmpty &&
            suggestion.right.isEmpty) {
          TrafficLog.add('ER',
              '[Desert-Auto] ⚠️ all wings empty for ${tower.coordsLabel}');
          continue;
        }

        Lord lord;
        try {
          lord = freeLords.firstWhere((c) => c.lord.id != 0).lord;
        } catch (_) {
          lord = freeLords.first.lord;
        }

        TrafficLog.add('ST',
            '[Desert-Auto] ⚔️ attacking ${tower.coordsLabel} '
            'L=${suggestion.left.length} M=${suggestion.middle.length} R=${suggestion.right.length} '
            'total=${suggestion.totalUnits} LID=${lord.id}');

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
          TrafficLog.add('ST',
              '[Desert-Auto] ✅ HIT ${tower.coordsLabel} mid=${result.movementId}');
          _setStatus('✅ Hit ${tower.coordsLabel}!');
          return;
        } else {
          TrafficLog.add('ER',
              '[Desert-Auto] ❌ attack ${tower.coordsLabel} failed: ${result.error}');
          _setStatus('❌ ${tower.coordsLabel}: ${result.error}');
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
      catalog: catalog,
    );

    if (report == null) {
      _setStatus('❌ bsd parse failed');
    } else {
      _setStatus('✓ Report: ${report.totalEnemyUnits} units');
    }
  }
}