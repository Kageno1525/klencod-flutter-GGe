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

  // ✅ مدد الفشل حسب السبب (بدل 240 دقيقة لكل حاجة)
  static const int kSpyFailMin = 10; // التجسس فشل / التقرير ماوصلش
  static const int kWeakArmyMin = 20; // جنودي مش كفاية دلوقتي
  static const int kGenericFailMin = 30; // أي خطأ تاني

  // ✅ أقل نسبة مسموحة لكل جناح (عدد المهاجمين ÷ عدد المدافعين)
  static const double kMinWingRatio = 1.05;

  // ✅ أقصى عدد أبراج في الـ tick الواحد (بدل 10)
  static const int kMaxTowersPerTick = 60;

  final ValueNotifier<String> statusNotifier = ValueNotifier('Idle');
  final List<AutoStatusEntry> _history = [];
  List<AutoStatusEntry> get statusHistory => List.unmodifiable(_history);

  int attacksThisSession = 0;
  int towersScanned = 0;

  Timer? _timer;
  Timer? _fastTimer;
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

  // ✅ تقارير التجسس اللي اتستخدمت قبل كده (عشان ماناخدش تقرير قديم بالغلط)
  final Set<int> _usedReportIds = {};

  // ✅ لو اتحط، الـ tick اللي بعد كده يشتغل بعد المدة دي بدل ما يستنى 30 ثانية
  Duration? _nextTickDelay;

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
    _usedReportIds.clear();
    _scanInProgress = false;
    _nextTickDelay = null;
    _fastTimer?.cancel();
    _fastTimer = null;

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
    _fastTimer?.cancel();
    _fastTimer = null;
    _nextTickDelay = null;
    _running = false;
    _setStatus('🛑 Stopped');
  }

  void _setStatus(String s) {
    statusNotifier.value = s;
    _history.add(AutoStatusEntry(DateTime.now(), s));
    if (_history.length > 200) _history.removeAt(0);
    TrafficLog.add('ST', '[Desert-Auto] $s');
  }

  // ✅✅✅ إصلاح: القيمة المخزنة هي "وقت انتهاء الحظر" مش وقت الفشل
  // (الكود القديم كان بيقارن غلط فالبرج كان بيفضل متحظر ~8 ساعات)
  bool _shouldSkipTower(DesertTower t) {
    final until = _failedTowers[t.key];
    if (until == null) return false;
    if (!DateTime.now().isBefore(until)) {
      _failedTowers.remove(t.key);
      _saveFailedTowers();
      return false;
    }
    return true;
  }

  void _markTowerFailed(DesertTower t, {int minutes = kFailedCooldownMin}) {
    _failedTowers[t.key] = DateTime.now().add(Duration(minutes: minutes));
    _saveFailedTowers();
    TrafficLog.add('ST',
        '[Desert-Auto] ⏸️ marked ${t.coordsLabel} failed ($minutes min)');
  }

  // ✅ tick مع قفل حقيقي + إعادة تشغيل سريعة لو لسه فيه شغل
  Future<void> _tick() async {
    if (!_running) return;
    if (_activeTick != null) return;
    _nextTickDelay = null;
    _activeTick = _doTick();
    try {
      await _activeTick;
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Auto] tick error: $e');
    } finally {
      _activeTick = null;
    }

    final delay = _nextTickDelay;
    _nextTickDelay = null;
    if (_running && delay != null) {
      _fastTimer?.cancel();
      _fastTimer = Timer(delay, () {
        if (_running) _tick();
      });
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

  // ═══════════════════════════════════════════════════════
  //  ✅ التحقق من الجيش قبل الإرسال — الهجمة الغلط ماتتبعتش
  //  بيرجع null لو الجيش كفاية، أو رسالة السبب لو لأ.
  // ═══════════════════════════════════════════════════════
  int _requiredFor(int enemy) {
    if (enemy <= 0) return 0;
    final scaled = (enemy * kMinWingRatio).round();
    return scaled > enemy ? scaled : enemy;
  }

  int _sumUnits(List<List<int>> l) =>
      l.fold<int>(0, (s, e) => e.length >= 2 ? s + e[1] : s);

  String? _validateArmy({
    required DesertSpyReport report,
    required List<List<int>> left,
    required List<List<int>> middle,
    required List<List<int>> right,
  }) {
    final lSent = _sumUnits(left);
    final mSent = _sumUnits(middle);
    final rSent = _sumUnits(right);

    final lReq = _requiredFor(report.left.total);
    final mReq = _requiredFor(report.middle.total);
    final rReq = _requiredFor(report.right.total);

    if (lSent < lReq) return 'يسار $lSent < $lReq';
    if (mSent < mReq) return 'أمام $mSent < $mReq';
    if (rSent < rReq) return 'يمين $rSent < $rReq';

    final total = lSent + mSent + rSent;
    if (total <= 0) return 'جيش فاضي';
    return null;
  }

  // ✅ بيحاول يبعت الهجمة بالقائد الأول، ولو مشغول (218) ينقل فورًا للي بعده
  // من غير ما يتجسس تاني ومن غير ما يحظر البرج.
  Future<DesertAttackResult> _attackWithLordFallback({
    required DesertTower tower,
    required OwnedCastle desert,
    required List<Lord> lords,
    required List<List<int>> left,
    required List<List<int>> middle,
    required List<List<int>> right,
  }) async {
    DesertAttackResult? last;
    for (final lord in lords.take(4)) {
      if (!_running) break;
      final res = await _svc!.attack(
        tower: tower,
        source: desert,
        lordId: lord.id,
        leftUnits: left,
        middleUnits: middle,
        rightUnits: right,
      );
      last = res;
      if (res.success) return res;
      final busy = res.error?.contains('218') ?? false;
      if (!busy) return res;
      TrafficLog.add('ST',
          '[Desert-Auto] 🔁 lord ${lord.id} busy (218) → next lord');
    }
    return last ?? DesertAttackResult.fail('NO_LORD');
  }

  // ✅✅✅ حلقة الهجوم: تجسس → تحقق → هجوم → فورًا البرج اللي بعده
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
      int towersTried = 0;

      while (_running && towersTried < kMaxTowersPerTick) {
        // ── جنودي الحاليين (fresh بعد كل هجمة) ──
        final freshUnits = await _client!.getCastleUnits(
            desert.kingdomId, desert.areaId, catalog);
        final sendable =
            freshUnits.where((u) => u.isCombat && u.amount > 0).toList();
        final totalUnits = sendable.fold<int>(0, (s, u) => s + u.amount);

        if (totalUnits < kMinUnitsToAttack) {
          _setStatus(
              '💤 Idle — units: $totalUnits (< $kMinUnitsToAttack)');
          return;
        }

        // ── القواد الفاضيين ──
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
          // ✅ لو لسه فيه أبراج، افحص تاني بعد 10 ثواني بدل 30
          _nextTickDelay = const Duration(seconds: 10);
          return;
        }

        // القواد غير الرئيسي الأول، والرئيسي آخر واحد
        final orderedLords = <Lord>[
          ...freeLords.where((c) => c.lord.id != 0).map((c) => c.lord),
          ...freeLords.where((c) => c.lord.id == 0).map((c) => c.lord),
        ];

        // ── اختيار البرج ──
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
        towersTried++;

        try {
          // ── تجسس ──
          _setStatus('🔍 Spying ${tower.coordsLabel}...');
          await _spyAndFetch(tower, desert, catalog);
          if (!_running) return;

          final report = _svc!.getCachedReport(tower);
          if (report == null ||
              !report.matches(tower) ||
              _usedReportIds.contains(report.messageId)) {
            _setStatus('❌ Spy failed for ${tower.coordsLabel}');
            _markTowerFailed(tower, minutes: kSpyFailMin);
            continue;
          }
          _usedReportIds.add(report.messageId);
          if (_usedReportIds.length > 300) {
            _usedReportIds.remove(_usedReportIds.first);
          }

          if (report.isDead) {
            _setStatus(
                '💀 ${tower.coordsLabel} dead (respawn in ${report.rs}s)');
            final mins = ((report.rs / 60).ceil() + 1).clamp(2, 240).toInt();
            _markTowerFailed(tower, minutes: mins);
            continue;
          }

          if (report.totalEnemyUnits <= 0) {
            _setStatus('⚠️ ${tower.coordsLabel} empty report');
            _markTowerFailed(tower, minutes: kSpyFailMin);
            continue;
          }

          // ── تقدير مبدئي ──
          final viable = _svc!.analyzeAttack(
            report: report,
            myUnitCount: totalUnits,
            myUnits: sendable.map((u) => [u.wodId, u.amount]).toList(),
          );
          if (!viable.likelyWin) {
            _setStatus('⏭️ Skip ${tower.coordsLabel}: ${viable.hint}');
            _markTowerFailed(tower, minutes: kWeakArmyMin);
            continue;
          }

          // ── توزيع الجيش ──
          final suggestion = _svc!.suggestCounter(
            available: sendable,
            defenders: report.toDefenderSummary(),
          );

          if (suggestion.totalUnits <= 0 ||
              (suggestion.left.isEmpty &&
                  suggestion.middle.isEmpty &&
                  suggestion.right.isEmpty)) {
            _setStatus('⚠️ Empty suggestion for ${tower.coordsLabel}');
            _markTowerFailed(tower, minutes: kWeakArmyMin);
            continue;
          }

          // ✅✅✅ الفحص الأهم: كل جناح لازم يكون أقوى من مدافعيه
          final problem = _validateArmy(
            report: report,
            left: suggestion.left,
            middle: suggestion.middle,
            right: suggestion.right,
          );
          if (problem != null) {
            _setStatus(
                '🛡️ Skip ${tower.coordsLabel}: الجيش مش كفاية ($problem)');
            _markTowerFailed(tower, minutes: kWeakArmyMin);
            continue;
          }

          // ── إرسال فوري ──
          _setStatus(
              '⚔️ Attacking ${tower.coordsLabel} (${suggestion.totalUnits})...');

          var result = await _attackWithLordFallback(
            tower: tower,
            desert: desert,
            lords: orderedLords,
            left: suggestion.left,
            middle: suggestion.middle,
            right: suggestion.right,
          );

          if (result.success) {
            attacksThisTick++;
            attacksThisSession++;
            _attackedThisTick.add(tower.key);
            TrafficLog.add('ST',
                '[Desert-Auto] ✅ HIT ${tower.coordsLabel} mid=${result.movementId} '
                '($attacksThisTick this tick, $attacksThisSession session)');
            _setStatus('✅ Hit ${tower.coordsLabel}! (#$attacksThisTick)');
            if (!_running) return;
            // ✅ من غير أي انتظار — على طول البرج اللي بعده
            continue;
          }

          final err = result.error ?? '';

          // ── 181: وصلنا أقصى عدد حركات — مفيش فايدة نكمل ──
          if (err.contains('181')) {
            _setStatus('⏸️ Max movements reached (181)');
            _nextTickDelay = const Duration(seconds: 20);
            return;
          }

          // ── 218: كل القواد اللي جربناهم مشغولين — البرج سليم ──
          if (err.contains('218')) {
            _setStatus('⏳ Lords busy — retry soon');
            _nextTickDelay = const Duration(seconds: 8);
            return;
          }

          // ── 313: تقليل الوحدات — بس لو لسه كفاية ──
          if (err.contains('313')) {
            TrafficLog.add('ST',
                '[Desert-Auto] ⚠️ 313 on ${tower.coordsLabel} — try reduced army');
            _setStatus('⚠️ 313 — retry with fewer units...');

            List<List<int>> reduce(List<List<int>> units, double f) {
              final out = <List<int>>[];
              for (final u in units) {
                if (u.length < 2) continue;
                final newAmt = (u[1] * f).round();
                if (newAmt > 0) out.add([u[0], newAmt]);
              }
              return out;
            }

            bool retried = false;
            for (final f in const [0.85, 0.7]) {
              final rl = reduce(suggestion.left, f);
              final rm = reduce(suggestion.middle, f);
              final rr = reduce(suggestion.right, f);

              // ✅ لو التقليل خلّى أي جناح أضعف من مدافعيه → مانبعتش
              final bad = _validateArmy(
                  report: report, left: rl, middle: rm, right: rr);
              if (bad != null) {
                TrafficLog.add('ST',
                    '[Desert-Auto] ⛔ reduced army ($f) too weak: $bad');
                break;
              }

              retried = true;
              final retryTotal = _sumUnits(rl) + _sumUnits(rm) + _sumUnits(rr);
              TrafficLog.add('ST',
                  '[Desert-Auto] 🔁 Retry ${tower.coordsLabel} x$f = $retryTotal units');
              result = await _attackWithLordFallback(
                tower: tower,
                desert: desert,
                lords: orderedLords,
                left: rl,
                middle: rm,
                right: rr,
              );
              if (result.success) {
                attacksThisTick++;
                attacksThisSession++;
                _attackedThisTick.add(tower.key);
                TrafficLog.add('ST',
                    '[Desert-Auto] ✅ HIT (retry) ${tower.coordsLabel} with $retryTotal units');
                _setStatus('✅ Hit ${tower.coordsLabel} (retry)');
                break;
              }
              if (!(result.error?.contains('313') ?? false)) break;
            }

            if (result.success) {
              if (!_running) return;
              continue;
            }

            _setStatus(retried
                ? '❌ ${tower.coordsLabel}: 313 (tower full)'
                : '❌ ${tower.coordsLabel}: 313 — الجيش المخفّض ضعيف');
            _markTowerFailed(tower, minutes: kGenericFailMin);
            continue;
          }

          // ── أي خطأ تاني ──
          TrafficLog.add(
              'ER', '[Desert-Auto] ❌ ${tower.coordsLabel}: $err');
          _setStatus('❌ ${tower.coordsLabel}: $err');
          _markTowerFailed(tower, minutes: kGenericFailMin);
          continue;
        } finally {
          _attackingNow.remove(tower.key);
        }
      }

      if (towersTried >= kMaxTowersPerTick) {
        _setStatus('🔁 Tried $towersTried towers, continuing...');
      }
      // ✅ لو لسه فيه شغل بعد الحلقة (عملنا هجمات) — كمّل بعد ثانية
      if (attacksThisTick > 0) {
        _nextTickDelay = const Duration(seconds: 1);
      }
    } catch (e) {
      _setStatus('❌ Attack loop error: $e');
    }
  }

  // ✅ تجسس + انتظار التقرير (بنفحص كل 250ms بدل 2 ثانية)
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
    const pollMs = 250;
    const maxPolls = 30000 ~/ pollMs; // 30 ثانية
    for (int i = 0; i < maxPolls; i++) {
      await Future.delayed(const Duration(milliseconds: pollMs));
      if (!_running) return;
      final candidate = _svc!.latestSpyMessageId;
      if (candidate == null) continue;
      // ✅ تقرير اتستخدم قبل كده؟ تجاهله وكمّل انتظار
      if (_usedReportIds.contains(candidate)) {
        _svc!.latestSpyMessageId = null;
        continue;
      }
      msgId = candidate;
      break;
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
