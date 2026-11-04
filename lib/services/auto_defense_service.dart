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

class AutoDefenseService {
  AutoDefenseService._();
  static final AutoDefenseService instance = AutoDefenseService._();

  static const int kMaxUnitTypes = 10;
  static const int _maxLordRetries = 4;

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
  static const _commandersTtl = Duration(seconds: 30);

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
    if (_log.length > 200) _log.removeRange(200, _log.length);
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
      await _getCommanders();
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
      await Future.delayed(const Duration(milliseconds: 600));
      _currentKingdomId = kingdomId;
      _commandersCache = null;
      _commandersCacheAt = null;
    } catch (e) {
      TrafficLog.add('ER', '[AutoDef] jca failed: $e');
    }
  }

  /// ✅ يختار lord فاضي — بيستبعد اللي فشلوا قبل كده
  /// بيرجع list مرتبة: LID=0 أول، بعدين أصغر IDs
  Future<List<int>> _getFreeLordIds({Set<int> exclude = const {}}) async {
    try {
      final cmds = await _getCommanders(force: true);
      if (cmds.isEmpty) {
        _addLog('📋 getCommanders returned empty', 'warn');
        return [];
      }
      final free = cmds
          .where((c) => !c.isBusy && !exclude.contains(c.lord.id))
          .toList();

      TrafficLog.add('ST',
          '[AutoDef] Commanders: ${cmds.length} total, '
          '${cmds.where((c) => !c.isBusy).length} free, '
          '${free.length} usable (excluded: $exclude)');

      if (free.isEmpty) {
        final details = cmds
            .take(6)
            .map((c) => 'LID=${c.lord.id}${c.isBusy ? "(busy)" : "(free)"}')
            .join(', ');
        TrafficLog.add('ST', '[AutoDef] First 6: $details');
        return [];
      }

      // نفضل LID=0، بعدين نصعد
      free.sort((a, b) {
        if (a.lord.id == 0) return -1;
        if (b.lord.id == 0) return 1;
        return a.lord.id.compareTo(b.lord.id);
      });
      return free.map((c) => c.lord.id).toList();
    } catch (e) {
      TrafficLog.add('ER', '[AutoDef] _getFreeLordIds failed: $e');
      return [];
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

  List<List<int>> _buildBatch(List<CastleUnit> ordered) {
    final batch = <List<int>>[];
    for (final u in ordered.take(kMaxUnitTypes)) {
      if (u.amount > 0) batch.add([u.wodId, u.amount]);
    }
    return batch;
  }

  /// ✅ خطأ لورد مش صالح للقلعة دي → المفروض نجرب لورد تاني
  bool _isRetryableLordError(String err) {
    if (err.contains('92')) return true;
    if (err.contains('218')) return true;
    if (err.contains('219')) return true;
    if (err.contains('222')) return true;
    if (err.contains('256')) return true;
    if (err.contains('404')) return true;
    if (err.contains('LORD_BUSY')) return true;
    if (err.contains('LORD_UNAVAILABLE')) return true;
    return false;
  }

  /// ✅ إرسال batch واحد مع retry على lords
  Future<({bool ok, int? mid, String? error})> _sendWithLordRetry({
    required GgeClient client,
    required OwnedCastle source,
    required AllyCastle target,
    required List<List<int>> batch,
    required int stationTime,
    required int castleNo,
    required int totalCastles,
    required String castleName,
  }) async {
    final tried = <int>{};
    String? lastError;

    for (int attempt = 0; attempt < _maxLordRetries; attempt++) {
      if (_globalEvacRunning && _globalEvacCancelled) {
        return (ok: false, mid: null, error: 'CANCELLED');
      }

      final freeIds = await _getFreeLordIds(exclude: tried);
      if (freeIds.isEmpty) {
        _addLog(
            '⚠️ [$castleNo/$totalCastles] $castleName: no more free lords '
            '(tried: $tried)', 'warn');
        return (ok: false, mid: null, error: 'NO_FREE_LORD');
      }

      final lordId = freeIds.first;
      tried.add(lordId);

      _addLog(
          '📤 [$castleNo/$totalCastles] $castleName: LID=$lordId '
          '(attempt ${attempt + 1}/$_maxLordRetries)', 'evac');

      final result = await client.sendToAlly(
        source: source,
        target: target,
        units: batch,
        stationTime: stationTime,
        lordId: lordId,
      );

      if (result.success) {
        _addLog(
            '✅ [$castleNo/$totalCastles] $castleName: LID=$lordId, '
            'MID=${result.movementId}', 'evac');
        return (ok: true, mid: result.movementId, error: null);
      }

      lastError = result.error ?? 'unknown';
      _addLog(
          '⚠️ [$castleNo/$totalCastles] $castleName: LID=$lordId rejected '
          '($lastError)', 'warn');

      if (!_isRetryableLordError(lastError)) {
        // مش مشكلة lord — نوقف المحاولات
        return (ok: false, mid: null, error: lastError);
      }

      await Future.delayed(const Duration(milliseconds: 800));
    }

    _addLog(
        '❌ [$castleNo/$totalCastles] $castleName: all $_maxLordRetries '
        'attempts failed (last: $lastError)', 'error');
    return (ok: false, mid: null, error: lastError);
  }

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
      if (filtered.isEmpty) {
        _addLog(
            '⚠️ No units after type filter (${settings.evacUnitFilter.name})',
            'warn');
        return;
      }

      final ordered = _orderedForEvac(filtered);
      final batch = _buildBatch(ordered);
      if (batch.isEmpty) {
        _addLog('⚠️ Empty batch at $areaId', 'warn');
        return;
      }

      if (ordered.length > kMaxUnitTypes) {
        _addLog(
            '⚠️ $areaId: ${ordered.length} types, only first $kMaxUnitTypes '
            'sent (exactly like manual)',
            'warn');
      }

      final ally = await _pickAllyCastle(source);
      if (ally == null) {
        _addLog('⚠️ No allied castle in same kingdom for area=$areaId', 'warn');
        return;
      }

      final wt = isSpy ? 1 : settings.saveHours;
      final totalUnits = batch.fold<int>(0, (s, e) => s + e[1]);
      _addLog(
          '📦 area=$areaId: ${batch.length} types, $totalUnits units → ${ally.name}',
          'evac');

      final sendResult = await _sendWithLordRetry(
        client: client,
        source: source,
        target: ally.castle,
        batch: batch,
        stationTime: wt,
        castleNo: 0,
        totalCastles: 0,
        castleName: 'area=$areaId',
      );

      if (sendResult.ok) {
        _evac[areaId] = _CastleEvac(
          sourceAreaId: areaId,
          evacuationMovementIds: [
            if (sendResult.mid != null) sendResult.mid!
          ],
          targetAllyName: ally.name,
          createdAt: DateTime.now(),
          spyMode: isSpy,
          wtHours: wt,
        );
        _addLog('✅ EVAC area=$areaId complete', 'evac');
      } else {
        _addLog('❌ EVAC area=$areaId failed: ${sendResult.error}', 'error');
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

  Future<void> evacuateAllCastles() async {
    if (_globalEvacRunning) return;
    _globalEvacRunning = true;
    _globalEvacCancelled = false;
    _globalEvacCurrent = 0;
    _globalEvacTotal = 0;
    _globalEvacStatus = '';

    try {
      final client = GgeClient();
      final allCastles = await client.getCastles();
      final targets = allCastles
          .where((c) =>
              c.areaType == 1 || c.areaType == 4 || c.areaType == 12)
          .toList();

      _globalEvacTotal = targets.length;
      _addLog('🌍 Global evac: ${targets.length} castles', 'evac');

      int successCastles = 0;
      int failedCastles = 0;

      for (int i = 0; i < targets.length; i++) {
        if (_globalEvacCancelled) {
          _addLog('⏹️ Global evac cancelled at ${i + 1}/${targets.length}',
              'warn');
          break;
        }

        _globalEvacCurrent = i + 1;
        _globalEvacStatus = targets[i].displayName;

        final ok = await _evacuateCastleStandalone(
          targets[i],
          castleNo: i + 1,
          totalCastles: targets.length,
        );
        if (ok) {
          successCastles++;
        } else {
          failedCastles++;
        }

        if (i < targets.length - 1 && !_globalEvacCancelled) {
          await Future.delayed(const Duration(seconds: 3));
        }
      }

      if (!_globalEvacCancelled) {
        _addLog(
            '✅ Global evac done — $successCastles success, $failedCastles failed',
            'evac');
      }
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
  }

  Future<bool> _evacuateCastleStandalone(
    OwnedCastle source, {
    required int castleNo,
    required int totalCastles,
  }) async {
    final areaId = source.areaId;
    if (_evacuationInProgress.contains(areaId)) {
      _addLog('⏭️ [$castleNo/$totalCastles] ${source.displayName}: busy, skip',
          'warn');
      return false;
    }
    _evacuationInProgress.add(areaId);

    try {
      final client = GgeClient();
      await _ensureKingdom(source.kingdomId, force: true);

      final catalog = await client.loadCatalog();
      final allUnits =
          await client.getCastleUnits(source.kingdomId, source.areaId, catalog);

      final sendable = allUnits.where(_isSendableForEvac).toList();
      if (sendable.isEmpty) {
        _addLog(
            '⚠️ [$castleNo/$totalCastles] ${source.displayName}: no sendable units',
            'warn');
        return false;
      }

      final filtered = _applyUnitFilter(sendable);
      if (filtered.isEmpty) {
        _addLog(
            '⚠️ [$castleNo/$totalCastles] ${source.displayName}: no units after filter',
            'warn');
        return false;
      }

      final ordered = _orderedForEvac(filtered);
      final batch = _buildBatch(ordered);
      if (batch.isEmpty) return false;

      if (ordered.length > kMaxUnitTypes) {
        _addLog(
            '⚠️ [$castleNo/$totalCastles] ${source.displayName}: '
            '${ordered.length} types, only first $kMaxUnitTypes sent (like manual)',
            'warn');
      }

      final ally = await _pickAllyCastle(source);
      if (ally == null) {
        _addLog(
            '⚠️ [$castleNo/$totalCastles] ${source.displayName}: no allied castle',
            'warn');
        return false;
      }

      final wt = settings.globalEvacHours;
      final totalUnits = batch.fold<int>(0, (s, e) => s + e[1]);
      _addLog(
          '📦 [$castleNo/$totalCastles] ${source.displayName}: '
          '${batch.length} types, $totalUnits units → ${ally.name}',
          'evac');

      final sendResult = await _sendWithLordRetry(
        client: client,
        source: source,
        target: ally.castle,
        batch: batch,
        stationTime: wt,
        castleNo: castleNo,
        totalCastles: totalCastles,
        castleName: source.displayName,
      );

      if (sendResult.ok) {
        _evac[areaId] = _CastleEvac(
          sourceAreaId: areaId,
          evacuationMovementIds: [
            if (sendResult.mid != null) sendResult.mid!
          ],
          targetAllyName: ally.name,
          createdAt: DateTime.now(),
          spyMode: false,
          wtHours: wt,
        );
        return true;
      }

      _addLog(
          '❌ [$castleNo/$totalCastles] ${source.displayName}: '
          '${sendResult.error}', 'error');
      return false;
    } catch (e) {
      _addLog(
          '❌ [$castleNo/$totalCastles] ${source.displayName}: exception $e',
          'error');
      return false;
    } finally {
      _evacuationInProgress.remove(areaId);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _logCtrl.close();
  }
}