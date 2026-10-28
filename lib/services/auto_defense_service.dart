import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';

// ═══════════════════════════════════════════════════════════════
//  Settings
// ═══════════════════════════════════════════════════════════════
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

  static Future<AutoDefenseSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AutoDefenseSettings(
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
    );
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
  }
}

// ═══════════════════════════════════════════════════════════════
//  State models
// ═══════════════════════════════════════════════════════════════
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
  final int evacuationMovementId; // -1 لو مش عارفينه
  final String targetAllyName;
  final DateTime createdAt;
  final bool spyMode;
  bool recalled;
  DateTime? recallAt;

  _CastleEvac({
    required this.sourceAreaId,
    required this.evacuationMovementId,
    required this.targetAllyName,
    required this.createdAt,
    required this.spyMode,
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

// ═══════════════════════════════════════════════════════════════
//  Service
// ═══════════════════════════════════════════════════════════════
class AutoDefenseService {
  AutoDefenseService._();
  static final AutoDefenseService instance = AutoDefenseService._();

  AutoDefenseSettings settings = AutoDefenseSettings();

  StreamSubscription<AttackAlert>? _sub;
  Timer? _tick;

  final Map<int, _PendingAttack> _pending = {};
  final Map<int, _CastleEvac> _evac = {};

  // cooldown على المحاولات عشان ما نعملش spam لو فشلت
  final Map<int, DateTime> _lastAttemptAt = {};
  static const _attemptCooldown = Duration(seconds: 30);

  // cache للقواد
  List<CommanderInfo>? _commandersCache;
  DateTime? _commandersCacheAt;
  static const _commandersTtl = Duration(seconds: 30);

  final List<AutoDefenseLogEntry> _log = [];
  final StreamController<List<AutoDefenseLogEntry>> _logCtrl =
      StreamController.broadcast();
  Stream<List<AutoDefenseLogEntry>> get logStream => _logCtrl.stream;
  List<AutoDefenseLogEntry> get log => List.unmodifiable(_log);

  bool _running = false;
  bool get isRunning => _running;

  Map<int, _PendingAttack> get pendingAttacks => Map.unmodifiable(_pending);
  Map<int, _CastleEvac> get activeEvacuations => Map.unmodifiable(_evac);

  void _addLog(String msg, [String? kind]) {
    _log.insert(0, AutoDefenseLogEntry(DateTime.now(), msg, kind));
    if (_log.length > 100) _log.removeRange(100, _log.length);
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

  // ── Attack stream ──────────────────────────────────────────
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
        'ETA=${alert.arrivalAt.toIso8601String()} from=${alert.attackerName} '
        'npc=$isNpc');
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
    // playerID في GGE عادةً 6-8 أرقام. أقل من 100000 = على الأغلب NPC
    if (a.attackerId > 0 && a.attackerId < 100000) return true;
    return false;
  }

  // ── Tick ───────────────────────────────────────────────────
  void _onTick() {
    if (!_running || !settings.enabled) return;

    _pending.removeWhere((_, a) => a.isPast);

    // grouping per castle
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

      if (!alreadyEvacuated && remaining > 0 && remaining <= _triggerFor()) {
        // cooldown
        final lastTry = _lastAttemptAt[areaId];
        if (lastTry == null ||
            DateTime.now().difference(lastTry) >= _attemptCooldown) {
          _lastAttemptAt[areaId] = DateTime.now();
          _triggerEvacuation(nearest, attacks.length);
        }
      }
    }

    // Spy mode recall logic:
    // 1) لو الـ evacuation في spy mode
    // 2) كل الهجمات على نفس القلعة إما ضربت (remaining <= 0) أو اترفضت
    // 3) مفيش هجوم وشيك (<= 30s)
    for (final ev in _evac.values.toList()) {
      if (ev.recalled || !ev.spyMode) continue;
      final castleAttacks = _pending.values
          .where((a) => a.targetAreaId == ev.sourceAreaId)
          .toList();
      final allPassed = castleAttacks.every((a) => a.remainingSeconds() <= 0);
      final hasImminent = castleAttacks.any((a) {
        final r = a.remainingSeconds();
        return r > 0 && r <= 30;
      });
      if (allPassed && !hasImminent) {
        _recallEvacuation(ev, reason: 'all attacks cleared');
      }
    }
  }

  int _triggerFor() {
    if (settings.spyModeEnabled) return settings.spyTriggerSeconds;
    return settings.normalTriggerSeconds;
  }

  // ── Evacuation ─────────────────────────────────────────────
  Future<void> _triggerEvacuation(
      _PendingAttack attack, int totalAttacks) async {
    final areaId = attack.targetAreaId;
    final existing = _evac[areaId];
    if (existing != null && !existing.recalled) return;

    final isSpy = settings.spyModeEnabled;
    _addLog(
        '🚀 EVAC ${isSpy ? "SPY" : "NORMAL"} → castle area=$areaId '
        '(attack in ${attack.remainingSeconds()}s, total=$totalAttacks)',
        'evac');

    try {
      final client = GgeClient();

      // 1. Castle
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

      // 2. Units
      final catalog = await client.loadCatalog();
      final allUnits =
          await client.getCastleUnits(source.kingdomId, source.areaId, catalog);
      final unlocked = client.getUnlockedForArea(source.areaId);
      final sendable = allUnits
          .where((u) => unlocked.contains(u.wodId) && u.amount > 0)
          .toList();

      if (sendable.isEmpty) {
        _addLog('⚠️ No sendable units at castle $areaId', 'warn');
        return;
      }

      // 3. Offensive أولاً — استبعد الدفاعية
      final offensive =
          sendable.where((u) => u.isCombat && !u.isDefensive).toList();
      final pool = offensive.isNotEmpty ? offensive : sendable;

      // 4. ترتيب حسب الأولوية
      final ordered = _orderByPriority(pool);
      final toSend = ordered
          .take(10)
          .map((u) => <int>[u.wodId, u.amount])
          .toList();

      if (toSend.isEmpty) {
        _addLog('⚠️ No units after filter', 'warn');
        return;
      }

      // 5. Ally target
      final ally = await _pickAllyCastle(source);
      if (ally == null) {
        _addLog('⚠️ No allied castle available in same kingdom', 'warn');
        return;
      }

      // 6. Pick free lord
      final lordId = await _pickLordForEvac();
      if (lordId == null) {
        _addLog('⚠️ No free lord for evac', 'warn');
        return;
      }

      // 7. WT: Spy=1h, Normal/Save=saveHours (WT in HOURS)
      final wt = isSpy ? 1 : settings.saveHours;

      final totalUnits = toSend.fold<int>(0, (s, e) => s + e[1]);
      _addLog(
          '📤 Sending $totalUnits units (${toSend.length} types) '
          'from ${source.displayName} → ${ally.name} '
          '(WT=${wt}h, LID=$lordId)',
          'evac');

      final result = await client.sendToAlly(
        source: source,
        target: ally.castle,
        units: toSend,
        stationTime: wt,
        lordId: lordId,
      );

      if (!result.success) {
        _addLog('❌ Evac failed: ${result.error}', 'error');
        return;
      }

      final mid = result.movementId ?? -1;
      _evac[areaId] = _CastleEvac(
        sourceAreaId: areaId,
        evacuationMovementId: mid,
        targetAllyName: ally.name,
        createdAt: DateTime.now(),
        spyMode: isSpy,
      );

      _addLog(
          '✅ EVAC started MID=$mid (${isSpy ? "SPY" : "${wt}h save"})',
          'evac');
    } catch (e) {
      _addLog('❌ Evac exception: $e', 'error');
    }
  }

  List<CastleUnit> _orderByPriority(List<CastleUnit> units) {
    if (settings.unitPriority.isEmpty) {
      final copy = [...units];
      copy.sort((a, b) => b.amount.compareTo(a.amount));
      return copy;
    }
    final out = <CastleUnit>[];
    for (final wod in settings.unitPriority) {
      for (final u in units) {
        if (u.wodId == wod) {
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

  Future<_AllyPick?> _pickAllyCastle(OwnedCastle source) async {
    List<AllyMember>? members;
    try {
      members = GgeClient().cachedAllianceMembers;
      members ??= await GgeClient().getAllianceMembers();
    } catch (_) {
      return null;
    }
    if (members == null || members.isEmpty) return null;

    // Preferred first
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

    // Best: peace + closest (in same kingdom)
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

  Future<int?> _pickLordForEvac() async {
    try {
      var cmds = await _getCommanders();
      var free = cmds.where((c) => !c.isBusy).toList();
      if (free.isEmpty) {
        cmds = await _getCommanders(force: true);
        free = cmds.where((c) => !c.isBusy).toList();
        if (free.isEmpty) return null;
      }
      try {
        return free.firstWhere((c) => c.lord.id == 0).lord.id;
      } catch (_) {
        return free.first.lord.id;
      }
    } catch (_) {
      return 0;
    }
  }

  Future<void> _recallEvacuation(_CastleEvac ev, {String? reason}) async {
    if (ev.evacuationMovementId <= 0) {
      _addLog('⚠️ Cannot recall — no MID for area=${ev.sourceAreaId}',
          'warn');
      return;
    }
    try {
      final res = await GgeClient().recallMovement(ev.evacuationMovementId);
      if (res.success) {
        ev.recalled = true;
        ev.recallAt = DateTime.now();
        _addLog(
            '🔙 Recalled MID=${ev.evacuationMovementId}'
            '${reason != null ? " ($reason)" : ""}',
            'recall');
      } else {
        _addLog('⚠️ Recall failed: ${res.error}', 'warn');
      }
    } catch (e) {
      _addLog('❌ Recall exception: $e', 'error');
    }
  }

  Future<void> dispose() async {
    await stop();
    await _logCtrl.close();
  }
}