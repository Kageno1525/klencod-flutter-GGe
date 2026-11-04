import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';

enum EvacUnitFilter { all, offenseOnly, defenseOnly }

class AutoDefenseSettings {
  bool enabled;
  bool normalModeEnabled;
  bool saveModeEnabled;
  bool spyModeEnabled;
  int normalTriggerSeconds;
  int spyTriggerSeconds;
  int saveHours;
  int? preferredAllyPlayerId;
  List<int> unitPriority;
  bool skipNpcAttacks;
  EvacUnitFilter evacUnitFilter;

  AutoDefenseSettings({
    this.enabled = false,
    this.normalModeEnabled = false,
    this.saveModeEnabled = false,
    this.spyModeEnabled = false,
    this.normalTriggerSeconds = 60,
    this.spyTriggerSeconds = 20,
    this.saveHours = 12,
    this.preferredAllyPlayerId,
    List<int>? unitPriority,
    this.skipNpcAttacks = true,
    this.evacUnitFilter = EvacUnitFilter.all,
  }) : unitPriority = unitPriority ?? [];

  static const _kEnabled = 'ad_enabled';
  static const _kNormal = 'ad_normal';
  static const _kSave = 'ad_save';
  static const _kSpy = 'ad_spy';
  static const _kNormalTrigger = 'ad_normal_trigger';
  static const _kSpyTrigger = 'ad_spy_trigger';
  static const _kSaveHours = 'ad_save_hours';
  static const _kPrefAlly = 'ad_pref_ally';
  static const _kPriority = 'ad_priority';
  static const _kSkipNpc = 'ad_skip_npc';
  static const _kEvacFilter = 'ad_evac_filter';
  static const _kGlobalHours = 'ad_global_hours';

  int globalEvacHours = 12;

  static Future<AutoDefenseSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final s = AutoDefenseSettings(
      enabled: p.getBool(_kEnabled) ?? false,
      normalModeEnabled: p.getBool(_kNormal) ?? false,
      saveModeEnabled: p.getBool(_kSave) ?? false,
      spyModeEnabled: p.getBool(_kSpy) ?? false,
      normalTriggerSeconds: p.getInt(_kNormalTrigger) ?? 60,
      spyTriggerSeconds: p.getInt(_kSpyTrigger) ?? 20,
      saveHours: p.getInt(_kSaveHours) ?? 12,
      preferredAllyPlayerId: p.getInt(_kPrefAlly),
      unitPriority: (p.getStringList(_kPriority) ?? [])
          .map((s) => int.tryParse(s) ?? 0)
          .where((i) => i > 0)
          .toList(),
      skipNpcAttacks: p.getBool(_kSkipNpc) ?? true,
      evacUnitFilter: EvacUnitFilter.values[(p.getInt(_kEvacFilter) ?? 0)
          .clamp(0, EvacUnitFilter.values.length - 1)],
    );
    s.globalEvacHours = p.getInt(_kGlobalHours) ?? 12;
    return s;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, enabled);
    await p.setBool(_kNormal, normalModeEnabled);
    await p.setBool(_kSave, saveModeEnabled);
    await p.setBool(_kSpy, spyModeEnabled);
    await p.setInt(_kNormalTrigger, normalTriggerSeconds);
    await p.setInt(_kSpyTrigger, spyTriggerSeconds);
    await p.setInt(_kSaveHours, saveHours);
    if (preferredAllyPlayerId != null) {
      await p.setInt(_kPrefAlly, preferredAllyPlayerId!);
    } else {
      await p.remove(_kPrefAlly);
    }
    await p.setStringList(
        _kPriority, unitPriority.map((i) => i.toString()).toList());
    await p.setBool(_kSkipNpc, skipNpcAttacks);
    await p.setInt(_kEvacFilter, evacUnitFilter.index);
    await p.setInt(_kGlobalHours, globalEvacHours);
  }
}

class _PendingAttack {
  final int movementId;
  final int targetAreaId;
  final int kingdomId;
  final int targetX, targetY;
  final DateTime arrivalAt;
  final String attackerName;
  final String? attackerAlliance;
  final bool isNpc;

  _PendingAttack({
    required this.movementId,
    required this.targetAreaId,
    required this.kingdomId,
    required this.targetX,
    required this.targetY,
    required this.arrivalAt,
    required this.attackerName,
    required this.attackerAlliance,
    required this.isNpc,
  });

  int remainingSeconds() => arrivalAt.difference(DateTime.now()).inSeconds;
  bool get isPast => remainingSeconds() < -60;
}

class _CastleEvac {
  final int sourceAreaId;
  final List<int> evacuationMovementIds;
  final String targetAllyName;
  final DateTime createdAt;
  final bool spyMode;
  final int wtHours;
  bool recalled;
  DateTime? recallAt;

  _CastleEvac({
    required this.sourceAreaId,
    required this.evacuationMovementIds,
    required this.targetAllyName,
    required this.createdAt,
    required this.spyMode,
    required this.wtHours,
    this.recalled = false,
    this.recallAt,
  });
}

class AutoDefenseLogEntry {
  final DateTime at;
  final String message;
  final String? kind;
  AutoDefenseLogEntry(this.at, this.message, [this.kind]);
}

class _AllyPick {
  final String name;
  final int playerId;
  final AllyCastle castle;
  _AllyPick(this.name, this.playerId, this.castle);
}

/// ✅ Task واحد في Global Evac queue: قلعة + batch من 10 أنواع + ally
class _EvacTask {
  final OwnedCastle source;
  final _AllyPick ally;
  final List<List<int>> batch;
  final int wt;
  final int batchIndex;
  final int totalBatches;
  _EvacTask({
    required this.source,
    required this.ally,
    required this.batch,
    required this.wt,
    required this.batchIndex,
    required this.totalBatches,
  });
}

class AutoDefenseService {
  AutoDefenseService._();
  static final AutoDefenseService instance = AutoDefenseService._();

  static const int kMaxUnitTypes = 10;

  AutoDefenseSettings settings = AutoDefenseSettings();

  StreamSubscription<AttackAlert>? _sub;
  Timer? _tick;

  final Map<int, _PendingAttack> _pending = {};
  final Map<int, _CastleEvac> _evac = {};
  final Set<int> _evacuationInProgress = {};
  final Map<int, DateTime> _lastAttemptAt = {};
  static const _attemptCooldown = Duration(seconds: 30);

  List<CommanderInfo>? _commandersCache;
  DateTime? _commandersCacheAt;
  static const _commandersTtl = Duration(seconds: 3);

  int? _currentKingdomId;

  Future<bool> Function()? onBeforeEvac;

  bool _globalEvacRunning = false;
  bool _globalEvacCancelled = false;
  int _globalEvacCurrent = 0;
  int _globalEvacTotal = 0;
  String _globalEvacStatus = '';

  final List<AutoDefenseLogEntry> _log = [];
  final StreamController<List<AutoDefenseLogEntry>> _logCtrl =
      StreamController.broadcast();
  Stream<List<AutoDefenseLogEntry>> get logStream => _logCtrl.stream;
  List<AutoDefenseLogEntry> get log => List.unmodifiable(_log);

  bool _running = false;
  bool get isRunning => _running;

  Map<int, _PendingAttack> get pendingAttacks => Map.unmodifiable(_pending);
  Map<int, _CastleEvac> get activeEvacuations => Map.unmodifiable(_evac);

  bool get globalEvacRunning => _globalEvacRunning;
  int get globalEvacCurrent => _globalEvacCurrent;
  int get globalEvacTotal => _globalEvacTotal;
  String get globalEvacStatus => _globalEvacStatus;

  void _addLog(String msg, [String? kind]) {
    _log.insert(0, AutoDefenseLogEntry(DateTime.now(), msg, kind));
    if (_log.length > 300) _log.removeRange(300, _log.length);
    if (!_logCtrl.isClosed) _logCtrl.add(List.unmodifiable(_log));
    TrafficLog.add('ST', '[AutoDef] $msg');
  }

  Future<void> init() async {
    settings = await AutoDefenseSettings.load();
    if (settings.enabled && !_running) await start();
  }

  Future<void> reloadSettings() async {
    settings = await AutoDefenseSettings.load();
    if (settings.enabled && !_running) {
      await start();
    } else if (!settings.enabled && _running) {
      await stop();
    }
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _sub?.cancel();
    _sub = GgeClient().attackStream.listen(_onAttack);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _addLog('✅ Auto-defense started', 'info');
    _prefetch();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _sub?.cancel();
    _sub = null;
    _tick?.cancel();
    _tick = null;
    _addLog('⏹️ Auto-defense stopped', 'info');
  }

  Future<void> _prefetch() async {
    try {
      await _getCommanders(force: true);
      _addLog('📋 Commanders cached', 'info');
    } catch (_) {}
    try {
      await GgeClient().getAllianceMembers();
      _addLog('👥 Alliance members cached', 'info');
    } catch (_) {}
  }

  Future<List<CommanderInfo>> _getCommanders({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _commandersCache != null &&
        _commandersCacheAt != null &&
        now.difference(_commandersCacheAt!) < _commandersTtl) {
      return _commandersCache!;
    }
    final cmds = await GgeClient().getCommanders();
    _commandersCache = cmds;
    _commandersCacheAt = now;
    return cmds;
  }

  Future<void> _ensureKingdom(int kingdomId, {bool force = false}) async {
    if (!force && _currentKingdomId == kingdomId) return;
    try {
      TrafficLog.add('ST', '[AutoDef] jca → KID=$kingdomId');
      await GgeClient().sendXtAndWait(
        'jca',
        jsonEncode({'CID': -1, 'KID': kingdomId}),
        responseCmd: 'jaa',
        timeoutMs: 8000,
      );
      await Future.delayed(const Duration(milliseconds: 800));
      _currentKingdomId = kingdomId;
      _commandersCache = null;
      _commandersCacheAt = null;
    } catch (e) {
      TrafficLog.add('ER', '[AutoDef] jca failed: $e');
    }
  }

  /// ✅ يختار lord فاضي واحد — بيرجع null لو مفيش
  Future<int?> _pickFreeLord() async {
    try {
      final cmds = await _getCommanders(force: true);
      if (cmds.isEmpty) return null;
      final free = cmds.where((c) => !c.isBusy).toList();
      if (free.isEmpty) return null;
      for (final c in free) {
        if (c.lord.id == 0) return 0;
      }
      free.sort((a, b) => a.lord.id.compareTo(b.lord.id));
      return free.first.lord.id;
    } catch (_) {
      return null;
    }
  }

  void _onAttack(AttackAlert alert) {
    if (!_running || !settings.enabled) return;
    if (alert.isCancelled) {
      _pending.remove(alert.movementId);
      return;
    }
    final isNpc = _isNpcAttack(alert);
    _pending[alert.movementId] = _PendingAttack(
      movementId: alert.movementId,
      targetAreaId: alert.targetAreaId,
      kingdomId: alert.kingdomId,
      targetX: alert.targetX,
      targetY: alert.targetY,
      arrivalAt: alert.arrivalAt,
      attackerName: alert.attackerName,
      attackerAlliance: alert.attackerAlliance,
      isNpc: isNpc,
    );
    TrafficLog.add('ST',
        '[AutoDef] Tracked mid=${alert.movementId} → area=${alert.targetAreaId} '
        'ETA=${alert.arrivalAt.toIso8601String()} from=${alert.attackerName}');
  }

  bool _isNpcAttack(AttackAlert a) {
    final n = a.attackerName.toLowerCase();
    if (n.contains('barbarian') ||
        n.contains('bandit') ||
        n.contains('rogue') ||
        n.contains('npc') ||
        n.contains('همجي') ||
        n.contains('منجم') ||
        n.contains('بربري')) {
      return true;
    }
    if (a.attackerId > 0 && a.attackerId < 100000) return true;
    return false;
  }

  void _onTick() {
    if (!_running || !settings.enabled) return;

    _pending.removeWhere((_, a) => a.isPast);

    final byCastle = <int, List<_PendingAttack>>{};
    for (final a in _pending.values) {
      if (a.remainingSeconds() < -60) continue;
      byCastle.putIfAbsent(a.targetAreaId, () => []).add(a);
    }

    for (final entry in byCastle.entries) {
      final areaId = entry.key;
      final attacks = entry.value;
      if (attacks.isEmpty) continue;

      attacks.sort((a, b) => a.arrivalAt.compareTo(b.arrivalAt));
      final nearest = attacks.first;
      final remaining = nearest.remainingSeconds();

      final ev = _evac[areaId];
      final alreadyEvacuated = ev != null && !ev.recalled;

      if (!alreadyEvacuated &&
          remaining > 0 &&
          remaining <= _triggerFor() &&
          !_evacuationInProgress.contains(areaId)) {
        final lastTry = _lastAttemptAt[areaId];
        final cooldown =
            remaining < 30 ? const Duration(seconds: 5) : _attemptCooldown;
        if (lastTry == null ||
            DateTime.now().difference(lastTry) >= cooldown) {
          _lastAttemptAt[areaId] = DateTime.now();
          _triggerEvacuation(nearest, attacks.length);
        }
      }
    }

    // Spy mode recall
    for (final ev in _evac.values.toList()) {
      if (ev.recalled || !ev.spyMode) continue;
      final castleAttacks = _pending.values
          .where((a) => a.targetAreaId == ev.sourceAreaId)
          .toList();
      final hasIncoming = castleAttacks.any((a) => a.remainingSeconds() > 0);
      if (hasIncoming) continue;
      final ageSeconds = DateTime.now().difference(ev.createdAt).inSeconds;
      if (ageSeconds < 3) continue;
      _recallEvacuation(ev, reason: 'all attacks arrived');
    }

    // Normal/Save mode recall
    for (final ev in _evac.values.toList()) {
      if (ev.recalled || ev.spyMode) continue;
      final castleAttacks = _pending.values
          .where((a) => a.targetAreaId == ev.sourceAreaId)
          .toList();
      final stillPending = castleAttacks.any((a) => a.remainingSeconds() > -60);
      if (stillPending) continue;
      final ageSeconds = DateTime.now().difference(ev.createdAt).inSeconds;
      if (ageSeconds >= ev.wtHours * 3600) {
        _recallEvacuation(ev, reason: 'save time elapsed');
      }
    }
  }

  int _triggerFor() {
    if (settings.spyModeEnabled) return settings.spyTriggerSeconds;
    return settings.normalTriggerSeconds;
  }

  bool _isSendableForEvac(CastleUnit u) {
    final info = u.info;
    if (info == null) return false;
    if (!u.isCombat) return false;
    final type = info.type ?? '';
    if (type.contains('Wall') ||
        type.contains('Gate') ||
        type.contains('Moat')) {
      return false;
    }
    return true;
  }

  List<CastleUnit> _applyUnitFilter(List<CastleUnit> units) {
    switch (settings.evacUnitFilter) {
      case EvacUnitFilter.all:
        return units;
      case EvacUnitFilter.offenseOnly:
        return units.where((u) => u.isCombat && !u.isDefensive).toList();
      case EvacUnitFilter.defenseOnly:
        return units.where((u) => u.isCombat && u.isDefensive).toList();
    }
  }

  List<CastleUnit> _orderedForEvac(List<CastleUnit> units) {
    if (settings.unitPriority.isNotEmpty) {
      final out = <CastleUnit>[];
      for (final wod in settings.unitPriority) {
        for (final u in units) {
          if (u.wodId == wod && !out.any((o) => o.wodId == wod)) {
            out.add(u);
            break;
          }
        }
      }
      for (final u in units) {
        if (!out.any((o) => o.wodId == u.wodId)) out.add(u);
      }
      return out;
    }
    final offensive =
        units.where((u) => u.isCombat && !u.isDefensive).toList();
    final defensive =
        units.where((u) => u.isCombat && u.isDefensive).toList();
    return [...offensive, ...defensive];
  }

  List<List<List<int>>> _splitIntoBatches(List<CastleUnit> ordered) {
    final batches = <List<List<int>>>[];
    for (int start = 0; start < ordered.length; start += kMaxUnitTypes) {
      final end = (start + kMaxUnitTypes).clamp(0, ordered.length);
      final slice = ordered.sublist(start, end);
      final batch = <List<int>>[];
      for (final u in slice) {
        if (u.amount > 0) batch.add([u.wodId, u.amount]);
      }
      if (batch.isNotEmpty) batches.add(batch);
    }
    return batches;
  }

  bool _isRetryableLordError(String err) {
    if (err.contains('218')) return true;
    if (err.contains('LORD_BUSY')) return true;
    if (err.contains('LORD_UNAVAILABLE')) return true;
    return false;
  }

  // ═══════════════════════════════════════════════════════════
  // AUTO DEFENSE — evac on attack (time-critical)
  // ═══════════════════════════════════════════════════════════
  Future<void> _triggerEvacuation(
      _PendingAttack attack, int totalAttacks) async {
    final areaId = attack.targetAreaId;
    final existing = _evac[areaId];
    if (existing != null && !existing.recalled) return;
    if (_evacuationInProgress.contains(areaId)) return;

    if (onBeforeEvac != null && !await onBeforeEvac!()) {
      _addLog('⏸️ Evac blocked by callback', 'warn');
      return;
    }

    _evacuationInProgress.add(areaId);

    final isSpy = settings.spyModeEnabled;
    _addLog(
        '🚀 EVAC ${isSpy ? "SPY" : "NORMAL"} → area=$areaId '
        '(attack in ${attack.remainingSeconds()}s)',
        'evac');

    try {
      final client = GgeClient();
      final allCastles = await client.getCastles();
      OwnedCastle? source;
      for (final c in allCastles) {
        if (c.areaId == areaId) {
          source = c;
          break;
        }
      }
      if (source == null) {
        _addLog('⚠️ Castle area=$areaId not found', 'warn');
        return;
      }

      await _ensureKingdom(source.kingdomId);

      final catalog = await client.loadCatalog();
      final allUnits =
          await client.getCastleUnits(source.kingdomId, source.areaId, catalog);

      final sendable = allUnits.where(_isSendableForEvac).toList();
      if (sendable.isEmpty) {
        _addLog('⚠️ No sendable units at $areaId', 'warn');
        return;
      }

      final filtered = _applyUnitFilter(sendable);
      if (filtered.isEmpty) return;

      final ordered = _orderedForEvac(filtered);
      final batches = _splitIntoBatches(ordered);
      if (batches.isEmpty) return;

      _addLog(
          '📦 $areaId: ${ordered.length} types → ${batches.length} batch(es)',
          'evac');

      final ally = await _pickAllyCastle(source);
      if (ally == null) {
        _addLog('⚠️ No allied castle in same kingdom', 'warn');
        return;
      }

      final wt = isSpy ? 1 : settings.saveHours;
      final listMids = <int>[];

      // ⏰ Deadline: 5s before attack arrives
      final deadline = attack.arrivalAt.subtract(const Duration(seconds: 5));

      for (int b = 0; b < batches.length; b++) {
        if (DateTime.now().isAfter(deadline)) {
          _addLog(
              '⏰ Attack imminent — stopping at batch ${b + 1}/${batches.length}',
              'warn');
          break;
        }

        final batch = batches[b];
        final totalUnits = batch.fold<int>(0, (s, e) => s + e[1]);

        bool batchSent = false;
        int attempts = 0;
        while (!batchSent &&
            attempts < 5 &&
            DateTime.now().isBefore(deadline)) {
          attempts++;
          final lordId = await _pickFreeLord();
          if (lordId == null) {
            _addLog(
                '⏳ Batch ${b + 1}: no free lord (attempt $attempts) — wait 3s',
                'warn');
            await Future.delayed(const Duration(seconds: 3));
            continue;
          }

          _addLog(
              '📤 Batch ${b + 1}/${batches.length}: ${batch.length} types, '
              '$totalUnits units, LID=$lordId',
              'evac');

          final result = await client.sendToAlly(
            source: source,
            target: ally.castle,
            units: batch,
            stationTime: wt,
            lordId: lordId,
          );

          if (result.success) {
            if (result.movementId != null) listMids.add(result.movementId!);
            batchSent = true;
            _addLog('✅ Batch ${b + 1} MID=${result.movementId}', 'evac');
          } else {
            final err = result.error ?? '';
            if (_isRetryableLordError(err)) {
              _addLog(
                  '⚠️ LID=$lordId rejected ($err) — try another', 'warn');
              await Future.delayed(const Duration(seconds: 1));
            } else {
              _addLog('❌ Batch ${b + 1} failed: $err — stop', 'error');
              break;
            }
          }
        }

        if (!batchSent) {
          _addLog(
              '⏹️ Stopping after batch ${b + 1}/${batches.length} — could not send',
              'warn');
          break;
        }

        if (b < batches.length - 1 && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      if (listMids.isNotEmpty) {
        _evac[areaId] = _CastleEvac(
          sourceAreaId: areaId,
          evacuationMovementIds: listMids,
          targetAllyName: ally.name,
          createdAt: DateTime.now(),
          spyMode: isSpy,
          wtHours: wt,
        );
        _addLog(
            '✅ EVAC area=$areaId: ${listMids.length}/${batches.length} batches sent',
            'evac');
      }
    } catch (e) {
      _addLog('❌ EVAC area=$areaId exception: $e', 'error');
    } finally {
      _evacuationInProgress.remove(areaId);
    }
  }

  Future<_AllyPick?> _pickAllyCastle(OwnedCastle source) async {
    List<AllyMember>? members;
    try {
      members = GgeClient().cachedAllianceMembers;
      members ??= await GgeClient().getAllianceMembers();
    } catch (_) {
      return null;
    }
    if (members == null || members.isEmpty) return null;

    if (settings.preferredAllyPlayerId != null) {
      for (final m in members) {
        if (m.playerId == settings.preferredAllyPlayerId) {
          final c = m.castleIn(source.kingdomId);
          if (c != null && c.areaId != source.areaId) {
            return _AllyPick(m.name, m.playerId, c);
          }
        }
      }
    }

    final candidates = <(AllyMember, AllyCastle, int)>[];
    for (final m in members) {
      for (final c in m.castles) {
        if (c.kingdomId != source.kingdomId) continue;
        if (c.areaId == source.areaId) continue;
        final dx = c.x - source.x;
        final dy = c.y - source.y;
        candidates.add((m, c, dx * dx + dy * dy));
      }
    }
    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      if (a.$1.hasPeace && !b.$1.hasPeace) return -1;
      if (!a.$1.hasPeace && b.$1.hasPeace) return 1;
      return a.$3.compareTo(b.$3);
    });

    final best = candidates.first;
    return _AllyPick(best.$1.name, best.$1.playerId, best.$2);
  }

  Future<void> _recallEvacuation(_CastleEvac ev, {String? reason}) async {
    if (ev.evacuationMovementIds.isEmpty) return;
    int successCount = 0;
    for (final mid in ev.evacuationMovementIds) {
      try {
        final res = await GgeClient().recallMovement(mid);
        if (res.success) successCount++;
      } catch (_) {}
      await Future.delayed(
          Duration(milliseconds: 5500 + Random().nextInt(1500)));
    }
    if (successCount > 0) {
      ev.recalled = true;
      ev.recallAt = DateTime.now();
      _addLog(
          '🔙 Recalled $successCount/${ev.evacuationMovementIds.length}'
          '${reason != null ? " ($reason)" : ""}',
          'recall');
    }
  }

  // ═══════════════════════════════════════════════════════════
  // GLOBAL EVAC — QUEUE-BASED (empties ALL troops eventually)
  // ═══════════════════════════════════════════════════════════
  Future<void> evacuateAllCastles() async {
    if (_globalEvacRunning) return;
    _globalEvacRunning = true;
    _globalEvacCancelled = false;
    _globalEvacCurrent = 0;
    _globalEvacTotal = 0;
    _globalEvacStatus = 'Preparing...';

    try {
      final client = GgeClient();
      final allCastles = await client.getCastles();
      final targets = allCastles
          .where((c) =>
              c.areaType == 1 || c.areaType == 4 || c.areaType == 12)
          .toList();

      // ── 1. Build task queue (castle + batch + ally) ─────────
      final tasks = <_EvacTask>[];
      final alliesByArea = <int, _AllyPick>{};

      for (int i = 0; i < targets.length; i++) {
        if (_globalEvacCancelled) break;
        final castle = targets[i];
        _globalEvacStatus = 'Preparing ${i + 1}/${targets.length}: '
            '${castle.displayName}';

        await _ensureKingdom(castle.kingdomId, force: true);

        final catalog = await client.loadCatalog();
        final units =
            await client.getCastleUnits(castle.kingdomId, castle.areaId, catalog);

        final sendable = units.where(_isSendableForEvac).toList();
        if (sendable.isEmpty) {
          _addLog('⏭️ ${castle.displayName}: no sendable units', 'warn');
          continue;
        }

        final filtered = _applyUnitFilter(sendable);
        if (filtered.isEmpty) continue;

        final ordered = _orderedForEvac(filtered);
        final batches = _splitIntoBatches(ordered);
        if (batches.isEmpty) continue;

        final ally = await _pickAllyCastle(castle);
        if (ally == null) {
          _addLog(
              '⏭️ ${castle.displayName}: no allied castle in same kingdom',
              'warn');
          continue;
        }
        alliesByArea[castle.areaId] = ally;

        for (int b = 0; b < batches.length; b++) {
          tasks.add(_EvacTask(
            source: castle,
            ally: ally,
            batch: batches[b],
            wt: settings.globalEvacHours,
            batchIndex: b + 1,
            totalBatches: batches.length,
          ));
        }

        _addLog(
            '📦 ${castle.displayName}: ${ordered.length} types → ${batches.length} batch(es) queued',
            'evac');
      }

      if (tasks.isEmpty) {
        _addLog('⏭️ No tasks to send', 'warn');
        return;
      }

      _globalEvacTotal = tasks.length;
      _addLog(
          '🌍 Queue ready: ${tasks.length} batches across ${alliesByArea.length} castles',
          'evac');

      // ── 2. Process queue ─────────────────────────────────────
      final midsByArea = <int, List<int>>{};
      int success = 0;
      int failed = 0;
      int waitCycles = 0;
      const maxWaitCycles = 60; // 60 * 20s = 20 minutes without any progress

      while (tasks.isNotEmpty && !_globalEvacCancelled) {
        final task = tasks.first;
        _globalEvacStatus =
            '${task.source.displayName} (${task.batchIndex}/${task.totalBatches}) '
            '— ${_globalEvacCurrent + 1}/${_globalEvacTotal}';

        // Make sure we're in the right kingdom (cheap if already)
        await _ensureKingdom(task.source.kingdomId);

        final lordId = await _pickFreeLord();
        if (lordId == null) {
          waitCycles++;
          _addLog(
              '⏳ No free lord — ${tasks.length} batches left, waiting (cycle $waitCycles/$maxWaitCycles)',
              'warn');
          await Future.delayed(const Duration(seconds: 20));

          if (waitCycles >= maxWaitCycles) {
            _addLog(
                '⏹️ Gave up after 20 min without a free lord — ${tasks.length} batches remain',
                'warn');
            break;
          }
          continue;
        }

        waitCycles = 0;

        final totalUnits = task.batch.fold<int>(0, (s, e) => s + e[1]);
        _addLog(
            '📤 ${task.source.displayName} batch ${task.batchIndex}/${task.totalBatches}: '
            '${task.batch.length} types, $totalUnits units, LID=$lordId → ${task.ally.name}',
            'evac');

        final result = await client.sendToAlly(
          source: task.source,
          target: task.ally.castle,
          units: task.batch,
          stationTime: task.wt,
          lordId: lordId,
        );

        if (result.success) {
          if (result.movementId != null) {
            midsByArea.putIfAbsent(task.source.areaId, () => []).add(
                result.movementId!);
          }
          success++;
          _globalEvacCurrent++;
          _addLog(
              '✅ MID=${result.movementId} (${success}/${_globalEvacTotal})',
              'evac');
          tasks.removeAt(0);
          await Future.delayed(const Duration(seconds: 3));
        } else {
          final err = result.error ?? '';
          if (_isRetryableLordError(err)) {
            _addLog('⚠️ LID=$lordId rejected ($err) — try another', 'warn');
            await Future.delayed(const Duration(seconds: 2));
          } else {
            failed++;
            _globalEvacCurrent++;
            _addLog('❌ Batch failed: $err — skip', 'error');
            tasks.removeAt(0);
          }
        }
      }

      // ── 3. Store evac records per castle ──────────────────────
      for (final entry in midsByArea.entries) {
        final ally = alliesByArea[entry.key];
        if (ally == null) continue;
        _evac[entry.key] = _CastleEvac(
          sourceAreaId: entry.key,
          evacuationMovementIds: entry.value,
          targetAllyName: ally.name,
          createdAt: DateTime.now(),
          spyMode: false,
          wtHours: settings.globalEvacHours,
        );
      }

      _addLog(
          '🏁 Global evac done — $success sent, $failed failed, ${tasks.length} remaining',
          'evac');
    } catch (e) {
      _addLog('❌ Global evac exception: $e', 'error');
    } finally {
      _globalEvacRunning = false;
      _globalEvacCancelled = false;
      _globalEvacStatus = '';
    }
  }

  void stopGlobalEvac() {
    _globalEvacCancelled = true;
    _addLog('⏹️ Global evac cancel requested', 'warn');
  }

  Future<void> dispose() async {
    await stop();
    await _logCtrl.close();
  }
}