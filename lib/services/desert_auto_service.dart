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

  static const int kMinUnitsToAttack = 30;
  static const int kFailedCooldownMin = 5;
  static const int kInterAttackDelaySec = 3;

  // ✅ الـ caps الديناميكية (زي JS مع تعلم)
  static const int kCapStart = 80;        // أول محاولة لكل برج
  static const int kCapMin = 30;          // أرضية
  static const int kCapMax = 260;         // سقف الـ JS الفعلي
  static const int kCapGrowStep = 15;     // زيادة على كل نجاح

  // ✅ مفاتيح حفظ الـ caps
  static const _kCapsSuccessKey = 'desert_cap_ok_v3';
  static const _kCapsFailKey = 'desert_cap_fail_v3';

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

  // ✅ خزائن الـ caps
  final Map<String, int> _lastSuccessCaps = {};
  final Map<String, int> _lastFailCaps = {};

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

  // ═══════════════════════════════════════════════════════════
  //  ✅ إدارة الـ caps (تحميل/حفظ/تصفير + منطق التعلم)
  // ═══════════════════════════════════════════════════════════
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
      TrafficLog.add('ST',
          '[Desert-Auto] 📚 loaded caps: ok=${_lastSuccessCaps.length} fail=${_lastFailCaps.length}');
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Auto] load caps error: $e');
    }
  }

  Future<void> _saveCaps() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCapsSuccessKey, jsonEncode(_lastSuccessCaps));
    await p.setString(_kCapsFailKey, jsonEncode(_lastFailCaps));
  }

  Future<void> resetCaps() async {
    _lastSuccessCaps.clear();
    _lastFailCaps.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(_kCapsSuccessKey);
    await p.remove(_kCapsFailKey);
    TrafficLog.add('ST', '[Desert-Auto] 🔄 caps reset');
  }

  /// ✅ السقف المتعلم لكل برج
  int _capFor(DesertTower t) {
    final s = _lastSuccessCaps[t.key];
    final f = _lastFailCaps[t.key];

    // لا نجاح ولا فشل → ابدأ آمن
    if (s == null && f == null) return kCapStart;

    // فشل بس (لسه ما نجحش) → انزل من اللي فشل
    if (s == null) {
      final next = f! - 20;
      return next < kCapMin ? kCapMin : (next > kCapMax ? kCapMax : next);
    }

    // نجاح بس (لسه ما فشلش) → كبّر
    if (f == null) {
      final next = s + kCapGrowStep;
      return next > kCapMax ? kCapMax : next;
    }

    // ✅ الاثنين موجودين → ثبّت على آخر سقف ناجح للأبد
    return s;
  }

  void _onSuccess(DesertTower t, int used) {
    _lastSuccessCaps[t.key] = used;
    _saveCaps();
  }

  void _on313(DesertTower t, int attempted) {
    _lastFailCaps[t.key] = attempted;
    // لو الـ cap وصل الحد الأدنى → البرج ده صعب، سيبه 24 ساعة
    if (attempted <= kCapMin) {
      _failedTowers[t.key] =
          DateTime.now().add(const Duration(hours: 24));
      _saveFailedTowers();
      TrafficLog.add('ST',
          '[Desert-Auto] 💀 ${t.coordsLabel} unusable at cap<=$kCapMin');
    }
    _saveCaps();
  }

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
    await _loadCaps();   // ← الجديد

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

  /// ✅ الأصل — نتخطى البرج لو مسجّل failed ولم يمضِ kFailedCooldownMin
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

  // ═══════════════════════════════════════════════════════════
  //  ⚔️ _tryAttackTowers — سقف متعلم + تعلم من 313/نجاح
  // ═══════════════════════════════════════════════════════════
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
      const int maxSpyAttempts = 20;

      while (_running && spyAttempts < maxSpyAttempts) {
        final freshUnits = await _client!.getCastleUnits(
            desert.kingdomId, desert.areaId, catalog);
        final sendable = freshUnits
            .where((u) => u.isCombat && u.amount > 0)
            .toList();
        final totalUnits =
            sendable.fold<int>(0, (s, u) => s + u.amount);

        if (totalUnits < kMinUnitsToAttack) {
          _setStatus('💤 Idle — units: $totalUnits (< $kMinUnitsToAttack)');
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
            .where((t) => !_svc!.isTower