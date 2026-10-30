import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';
import 'attack_planner.dart';

const int kDesertRadiusMin = 5;
const int kDesertRadiusMax = 100;
const int kDesertRadiusStep = 5;
const int kDesertChunkSize = 13;
const int kDefaultTowerCooldownMinutes = 240;
const int kAttackPowerPerUnit = 10;

// ═══════════════════════════════════════════════════════════
class DesertTower {
  final int x, y, kid;
  final double distanceFromSource;
  final int sourceAreaId;
  final String sourceName;

  DateTime? lastSpyAt;
  int? lastSpyMid;
  DateTime? lastAttackAt;
  int? lastAttackMid;

  DesertTower({
    required this.x, required this.y, required this.kid,
    required this.distanceFromSource, required this.sourceAreaId,
    required this.sourceName,
    this.lastSpyAt, this.lastSpyMid,
    this.lastAttackAt, this.lastAttackMid,
  });

  DesertTower copyWith({
    DateTime? lastSpyAt, int? lastSpyMid,
    DateTime? lastAttackAt, int? lastAttackMid,
  }) => DesertTower(
        x: x, y: y, kid: kid,
        distanceFromSource: distanceFromSource,
        sourceAreaId: sourceAreaId,
        sourceName: sourceName,
        lastSpyAt: lastSpyAt ?? this.lastSpyAt,
        lastSpyMid: lastSpyMid ?? this.lastSpyMid,
        lastAttackAt: lastAttackAt ?? this.lastAttackAt,
        lastAttackMid: lastAttackMid ?? this.lastAttackMid,
      );

  bool get isSpied => lastSpyAt != null;
  bool get isSpyRecent {
    if (lastSpyAt == null) return false;
    return DateTime.now().difference(lastSpyAt!).inMinutes < 5;
  }
  bool get hasActiveAttack {
    if (lastAttackAt == null) return false;
    return DateTime.now().difference(lastAttackAt!).inMinutes < 30;
  }

  String get coordsLabel => '($x,$y)';
  String get key => '$x,$y,$kid';

  String get spyTimeLabel {
    if (lastSpyAt == null) return '';
    final t = lastSpyAt!;
    return '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}';
  }
}

// ═══════════════════════════════════════════════════════════
class DesertSpyResult {
  final bool success;
  final String? error;
  final int? movementId;
  final int? scoutCount;
  final int? scoutReportValue;

  DesertSpyResult._({
    required this.success, this.error, this.movementId,
    this.scoutCount, this.scoutReportValue,
  });

  factory DesertSpyResult.ok(int? mid, int? scouts, int? sr) =>
      DesertSpyResult._(success: true, movementId: mid,
          scoutCount: scouts, scoutReportValue: sr);
  factory DesertSpyResult.fail(String err) =>
      DesertSpyResult._(success: false, error: err);
}

class DesertAttackResult {
  final bool success;
  final String? error;
  final int? movementId;
  final DesertTower? target;
  final int totalUnits;

  DesertAttackResult._({
    required this.success, this.error, this.movementId,
    this.target, this.totalUnits = 0,
  });

  factory DesertAttackResult.ok(int mid, DesertTower t, int units) =>
      DesertAttackResult._(success: true, movementId: mid,
          target: t, totalUnits: units);
  factory DesertAttackResult.fail(String err) =>
      DesertAttackResult._(success: false, error: err);
}

// ═══════════════════════════════════════════════════════════
class DefenderWing {
  final int melee;
  final int ranged;
  final List<List<int>> units;

  const DefenderWing({
    required this.melee, required this.ranged, required this.units,
  });

  int get total => melee + ranged;
  static const empty = DefenderWing(melee: 0, ranged: 0, units: []);
}

class DefenderSummary {
  int leftMelee;
  int leftRanged;
  int middleMelee;
  int middleRanged;
  int rightMelee;
  int rightRanged;

  DefenderSummary({
    this.leftMelee = 0, this.leftRanged = 0,
    this.middleMelee = 0, this.middleRanged = 0,
    this.rightMelee = 0, this.rightRanged = 0,
  });

  bool get isEmpty =>
      leftMelee + leftRanged + middleMelee + middleRanged +
          rightMelee + rightRanged == 0;

  int get total =>
      leftMelee + leftRanged + middleMelee + middleRanged +
          rightMelee + rightRanged;

  Map<String, dynamic> toJson() => {
        'lm': leftMelee, 'lr': leftRanged,
        'mm': middleMelee, 'mr': middleRanged,
        'rm': rightMelee, 'rr': rightRanged,
      };

  static DefenderSummary fromJson(Map<String, dynamic> j) => DefenderSummary(
        leftMelee: (j['lm'] as num?)?.toInt() ?? 0,
        leftRanged: (j['lr'] as num?)?.toInt() ?? 0,
        middleMelee: (j['mm'] as num?)?.toInt() ?? 0,
        middleRanged: (j['mr'] as num?)?.toInt() ?? 0,
        rightMelee: (j['rm'] as num?)?.toInt() ?? 0,
        rightRanged: (j['rr'] as num?)?.toInt() ?? 0,
      );
}

// ═══════════════════════════════════════════════════════════
class DesertSpyReport {
  final int messageId;
  final int targetX;
  final int targetY;
  final DefenderWing left;
  final DefenderWing middle;
  final DefenderWing right;
  final int defensiveStrength;
  final int availableAttacks;
  final int goldCampValue;
  final int scoutCount;
  final int scoutReportValue;
  final int wallLevel;
  final int gateLevel;
  final int moatLevel;
  final int rs;
  final DateTime fetchedAt;

  DesertSpyReport({
    required this.messageId,
    required this.targetX,
    required this.targetY,
    required this.left,
    required this.middle,
    required this.right,
    required this.defensiveStrength,
    required this.availableAttacks,
    required this.goldCampValue,
    required this.scoutCount,
    required this.scoutReportValue,
    required this.wallLevel,
    required this.gateLevel,
    required this.moatLevel,
    required this.rs,
    required this.fetchedAt,
  });

  bool get isDead => rs > 0 && rs < 100000;

  int get totalEnemyUnits => left.total + middle.total + right.total;
  int get totalEnemyMelee => left.melee + middle.melee + right.melee;
  int get totalEnemyRanged => left.ranged + middle.ranged + right.ranged;

  DefenderSummary toDefenderSummary() => DefenderSummary(
        leftMelee: left.melee, leftRanged: left.ranged,
        middleMelee: middle.melee, middleRanged: middle.ranged,
        rightMelee: right.melee, rightRanged: right.ranged,
      );

  bool matches(DesertTower t) => targetX == t.x && targetY == t.y;

  String get summaryLine =>
      'L: ${left.melee}M/${left.ranged}R · '
      'M: ${middle.melee}M/${middle.ranged}R · '
      'R: ${right.melee}M/${right.ranged}R';

  int get wallBonusPercent => wallLevel * 2 + gateLevel + moatLevel;
}

// ═══════════════════════════════════════════════════════════
class AttackViability {
  final bool likelyWin;
  final bool guaranteed;
  final int myUnitCount;
  final int enemyUnitCount;
  final int myStrength;
  final int enemyStrength;
  final String message;
  final String hint;
  final bool shortOfUnits; // ناقصك جنود (مش البرج اللي قوي)
  final bool overCap; // دفاع البرج أكبر من حد الجناح/الأمام

  AttackViability({
    required this.likelyWin,
    required this.guaranteed,
    required this.myUnitCount,
    required this.enemyUnitCount,
    required this.myStrength,
    required this.enemyStrength,
    required this.message,
    required this.hint,
    this.shortOfUnits = false,
    this.overCap = false,
  });
}

// ═══════════════════════════════════════════════════════════
class UnitSuggestion {
  final List<List<int>> left;
  final List<List<int>> middle;
  final List<List<int>> right;
  final String reason;

  UnitSuggestion({
    required this.left, required this.middle,
    required this.right, required this.reason,
  });

  int get totalUnits =>
      left.fold<int>(0, (s, e) => s + e[1]) +
      middle.fold<int>(0, (s, e) => s + e[1]) +
      right.fold<int>(0, (s, e) => s + e[1]);
}

// ═══════════════════════════════════════════════════════════
class DesertAttackSettings {
  int radiusTiles;
  String sortBy;
  int sourceAreaId;

  DesertAttackSettings({
    this.radiusTiles = 5,
    this.sortBy = 'distance',
    this.sourceAreaId = 0,
  });

  static const _kRadius = 'desert_radius_v2';
  static const _kSort = 'desert_sort_v2';
  static const _kSource = 'desert_source_v2';

  static Future<DesertAttackSettings> load() async {
    final p = await SharedPreferences.getInstance();
    int radius = p.getInt(_kRadius) ?? 5;
    if (radius < kDesertRadiusMin) radius = kDesertRadiusMin;
    if (radius > kDesertRadiusMax) radius = kDesertRadiusMax;
    return DesertAttackSettings(
      radiusTiles: radius,
      sortBy: p.getString(_kSort) ?? 'distance',
      sourceAreaId: p.getInt(_kSource) ?? 0,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kRadius, radiusTiles);
    await p.setString(_kSort, sortBy);
    await p.setInt(_kSource, sourceAreaId);
  }
}

// ═══════════════════════════════════════════════════════════
class DesertAttackService {
  final GgeClient conn;
  DesertAttackService(this.conn);

  int? _currentKid;
  DateTime? _lastJcaAt;
  DateTime? _lastScanAt;
  static const _scanCooldown = Duration(seconds: 30);

  int? latestSpyMessageId;
  DateTime? latestSpyMessageIdAt;

  final Map<String, DesertSpyReport> _reportCache = {};
  final Map<String, DateTime> _cooldowns = {};
  static const _kCooldowns = 'desert_cooldowns_v1';

  void captureSneReport(int messageId) {
    latestSpyMessageId = messageId;
    latestSpyMessageIdAt = DateTime.now();
    TrafficLog.add('ST',
        '[Desert] 📩 captured spy report msgId=$messageId');
  }

  Future<void> loadCooldowns() async {
    await PlannerConfig.load();
    await UnitPower.load();
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kCooldowns);
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      _cooldowns.clear();
      for (final e in data.entries) {
        final dt = DateTime.tryParse(e.value as String);
        if (dt != null && dt.isAfter(now)) {
          _cooldowns[e.key] = dt;
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCooldowns() async {
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final data = <String, String>{};
    for (final e in _cooldowns.entries) {
      if (e.value.isAfter(now)) {
        data[e.key] = e.value.toIso8601String();
      }
    }
    await p.setString(_kCooldowns, jsonEncode(data));
  }

  bool isTowerInCooldown(DesertTower tower) {
    final dt = _cooldowns[tower.key];
    if (dt == null) return false;
    if (dt.isBefore(DateTime.now())) {
      _cooldowns.remove(tower.key);
      return false;
    }
    return true;
  }

  Duration towerCooldownRemaining(DesertTower tower) {
    final dt = _cooldowns[tower.key];
    if (dt == null) return Duration.zero;
    final remaining = dt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<void> markTowerAttacked(DesertTower tower,
      {int minutes = kDefaultTowerCooldownMinutes}) async {
    _cooldowns[tower.key] = DateTime.now().add(Duration(minutes: minutes));
    await _saveCooldowns();
    TrafficLog.add('ST',
        '[Desert] ⏳ tower ${tower.coordsLabel} cooldown $minutes min');
  }

  // ═══════════════════════════════════════════════════════
  //  Planner helpers
  // ═══════════════════════════════════════════════════════
  static const String _kUnitMeta = 'desert_bg_unit_meta_v1';
  static const String _kSrcInfo = 'desert_src_info_v1';

  bool _isRangedUnit(CastleUnit u) {
    final r = u.info?.role;
    if (r == 'ranged') return true;
    if (r == 'melee') return false;
    return _isRangedWodId(u.wodId, const <int, UnitCatalogEntry>{});
  }

  List<List<PlanDef>> _defsFromReport(DesertSpyReport report) {
    List<PlanDef> wing(DefenderWing w) {
      final out = <PlanDef>[];
      for (final u in w.units) {
        if (u.length < 2 || u[0] <= 0 || u[1] <= 0) continue;
        out.add(PlanDef(
          id: u[0],
          count: u[1],
          ranged: _isRangedWodId(u[0], const <int, UnitCatalogEntry>{}),
        ));
      }
      if (out.isEmpty && w.total > 0) {
        if (w.melee > 0) out.add(PlanDef(id: 0, count: w.melee));
        if (w.ranged > 0) {
          out.add(PlanDef(id: 0, count: w.ranged, ranged: true));
        }
      }
      return out;
    }

    return [wing(report.left), wing(report.middle), wing(report.right)];
  }

  List<List<PlanDef>> _defsFromSummary(DefenderSummary d) {
    List<PlanDef> wing(int melee, int ranged) => [
          if (melee > 0) PlanDef(id: 0, count: melee),
          if (ranged > 0) PlanDef(id: 0, count: ranged, ranged: true),
        ];
    return [
      wing(d.leftMelee, d.leftRanged),
      wing(d.middleMelee, d.middleRanged),
      wing(d.rightMelee, d.rightRanged),
    ];
  }

  /// بيحفظ معلومات الوحدات (قتالية؟ دفاعية؟ رماية/اشتباك) عشان الخدمة
  /// اللي شغالة في الخلفية تستخدمها.
  Future<void> syncUnitMeta(List<CastleUnit> units) async {
    try {
      final p = await SharedPreferences.getInstance();
      Map<String, dynamic> cur = {};
      final raw = p.getString(_kUnitMeta);
      if (raw != null && raw.isNotEmpty) {
        cur = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
      for (final u in units) {
        cur['${u.wodId}'] = {
          'c': u.isCombat,
          'd': u.isDefensive,
          'r': (u.info?.role ?? '').toString(),
        };
      }
      await p.setString(_kUnitMeta, jsonEncode(cur));
    } catch (_) {}
  }

  Future<void> _saveSourceInfo(OwnedCastle source) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kSrcInfo,
        jsonEncode({
          'areaId': source.areaId,
          'x': source.x,
          'y': source.y,
          'kid': source.kingdomId,
        }),
      );
    } catch (_) {}
  }

  // ✅✅✅ التحليل بقى على أساس نفس المخطط اللي بيبني الهجوم
  AttackViability analyzeAttack({
    required DesertSpyReport report,
    required int myUnitCount,
    required List<List<int>> myUnits,
  }) {
    final stock = <PlanUnit>[];
    for (final e in myUnits) {
      if (e.length < 2 || e[0] <= 0 || e[1] <= 0) continue;
      stock.add(PlanUnit(
        id: e[0],
        stock: e[1],
        ranged: _isRangedWodId(e[0], const <int, UnitCatalogEntry>{}),
      ));
    }
    final plan = AttackPlanner.plan(
      stock: stock,
      defenders: _defsFromReport(report),
    );
    final enemyUnits = report.totalEnemyUnits;
    final planned = plan.total;

    String message;
    String hint;
    if (plan.guaranteed) {
      message = '✅ الهجوم مضمون';
      hint = 'هيتبعت $planned جندي · ${plan.reason}';
    } else if (plan.viable) {
      message = '⚠️ الهجوم ممكن ينجح';
      hint = 'هيتبعت $planned جندي (مدافعين: $enemyUnits) · ${plan.reason}';
    } else if (plan.overCap) {
      message = '🚫 البرج أقوى من حد الموجة الواحدة';
      hint = plan.reason;
    } else {
      message = '❌ وحداتك مش كفاية';
      hint = 'عندك: $myUnitCount · المدافعين: $enemyUnits · ${plan.reason}';
    }

    return AttackViability(
      likelyWin: plan.viable,
      guaranteed: plan.guaranteed,
      myUnitCount: myUnitCount,
      enemyUnitCount: enemyUnits,
      myStrength: planned,
      enemyStrength: report.defensiveStrength,
      message: message,
      hint: hint,
      shortOfUnits: plan.shortOfUnits,
      overCap: plan.overCap,
    );
  }

  Future<void> _ensureKingdom(int kid) async {
    if (_currentKid == kid &&
        _lastJcaAt != null &&
        DateTime.now().difference(_lastJcaAt!).inMinutes < 5) return;
    try {
      await conn.sendXtAndWait(
        'jca',
        jsonEncode({'CID': -1, 'KID': kid}),
        responseCmd: 'jaa', timeoutMs: 8000, isAction: false,
      );
      _currentKid = kid;
      _lastJcaAt = DateTime.now();
    } catch (e) {
      TrafficLog.add('ER', '[Desert] jca failed: $e');
    }
  }

  Future<List<DesertTower>> scanArea({
    required OwnedCastle source,
    required int radiusTiles,
    void Function(int done, int total)? onProgress,
  }) async {
    if (_lastScanAt != null &&
        DateTime.now().difference(_lastScanAt!) < _scanCooldown) {
      throw Exception('SCAN_COOLDOWN: انتظر قبل مسح جديد');
    }
    _lastScanAt = DateTime.now();
    await _saveSourceInfo(source);
    await _ensureKingdom(source.kingdomId);

    final cx = source.x, cy = source.y;
    final minX = (cx - radiusTiles).clamp(1, 1000);
    final maxX = (cx + radiusTiles).clamp(1, 1000);
    final minY = (cy - radiusTiles).clamp(1, 1000);
    final maxY = (cy + radiusTiles).clamp(1, 1000);

    final startX = (minX ~/ kDesertChunkSize) * kDesertChunkSize;
    final endX = (maxX ~/ kDesertChunkSize) * kDesertChunkSize;
    final startY = (minY ~/ kDesertChunkSize) * kDesertChunkSize;
    final endY = (maxY ~/ kDesertChunkSize) * kDesertChunkSize;

    final chunks = <List<int>>[];
    for (int x = startX; x <= endX; x += kDesertChunkSize) {
      for (int y = startY; y <= endY; y += kDesertChunkSize) {
        chunks.add([
          x, y,
          (x + kDesertChunkSize - 1).clamp(1, 1000),
          (y + kDesertChunkSize - 1).clamp(1, 1000),
        ]);
      }
    }
    if (chunks.length > 40) chunks.removeRange(40, chunks.length);

    final found = <DesertTower>[];
    final seen = <String>{};
    int done = 0;

    for (final chunk in chunks) {
      try {
        final resp = await conn.sendXtAndWait(
          'gaa',
          jsonEncode({
            'KID': source.kingdomId,
            'AX1': chunk[0], 'AY1': chunk[1],
            'AX2': chunk[2], 'AY2': chunk[3],
          }),
          responseCmd: 'gaa', timeoutMs: 15000, isAction: false,
        );

        if (resp.resultCode == 0 && resp.payload != null) {
          final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
          final ai = data['AI'] as List?;
          if (ai != null) {
            for (final entry in ai) {
              if (entry is! List || entry.length < 3) continue;
              if (_asInt(entry[0]) != 2) continue;
              final x = _asInt(entry[1]);
              final y = _asInt(entry[2]);
              final key = '$x,$y';
              if (seen.contains(key)) continue;
              seen.add(key);
              final dx = (x - cx).toDouble();
              final dy = (y - cy).toDouble();
              found.add(DesertTower(
                x: x, y: y, kid: source.kingdomId,
                distanceFromSource: sqrt(dx * dx + dy * dy),
                sourceAreaId: source.areaId,
                sourceName: source.displayName,
              ));
            }
          }
        }
      } catch (e) {
        TrafficLog.add('ER', '[Desert] gaa error: $e');
      }
      done++;
      onProgress?.call(done, chunks.length);
      if (done < chunks.length) {
        await Future.delayed(Duration(milliseconds: 800 + Random().nextInt(400)));
      }
    }
    TrafficLog.add('ST',
        '[Desert] Scan done: ${found.length} towers radius=$radiusTiles');
    return found;
  }

  Future<DesertSpyResult> spy({
    required DesertTower tower,
    required OwnedCastle source,
    int scoutCount = 11,
  }) async {
    await _ensureKingdom(tower.kid);
    try {
      final resp = await conn.sendXtAndWait(
        'csm',
        jsonEncode({
          'SID': source.areaId,
          'TX': tower.x, 'TY': tower.y,
          'SC': scoutCount, 'ST': 0, 'SE': 100,
          'HBW': -1, 'KID': tower.kid, 'PTT': 1, 'SD': 0,
        }),
        responseCmd: 'csm', timeoutMs: 25000, isAction: true,
        // ✅ فلترة: نتأكد إن الرد بتاع البرج ده
        predicate: (m) {
          if (m.payload == null) return true;
          try {
            final data = jsonDecode(m.payload!) as Map;
            final a = data['A'] as Map?;
            final inner = a?['M'] as Map?;
            final ta = inner?['TA'] as List?;
            if (ta == null || ta.length < 3) return true;
            final tx = int.tryParse(ta[1].toString());
            final ty = int.tryParse(ta[2].toString());
            return tx == tower.x && ty == tower.y;
          } catch (_) {
            return true;
          }
        },
      );
      if (resp.resultCode == 0 && resp.payload != null) {
        int? mid, scouts, sr;
        try {
          final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
          mid = _extractMovementMid(data);
          final s = data['S'] as Map?;
          if (s != null) {
            scouts = _asInt(s['SC']);
            sr = _asInt(s['SR']);
          }
        } catch (_) {}
        return DesertSpyResult.ok(mid, scouts, sr);
      }
      if (resp.resultCode == 218) return DesertSpyResult.fail('LORD_BUSY_218');
      return DesertSpyResult.fail('CSM ${resp.resultCode}');
    } catch (e) {
      return DesertSpyResult.fail('$e');
    }
  }

  Future<DesertSpyReport?> fetchSpyReport({
    required int messageId,
    required DesertTower tower,
    required Map<int, UnitCatalogEntry> catalog,
  }) async {
    try {
      conn.sendXt('mmr', jsonEncode({'MID': messageId}));
      await Future.delayed(const Duration(milliseconds: 300));

      final resp = await conn.sendXtAndWait(
        'bsd', jsonEncode({'MID': messageId}),
        responseCmd: 'bsd', timeoutMs: 15000, isAction: false,
      );

      if (resp.resultCode != 0 || resp.payload == null) {
        TrafficLog.add('ER', '[Desert] bsd failed result=${resp.resultCode}');
        return null;
      }

      final report = _parseBsd(resp.payload!, messageId, catalog, tower);
      if (report != null) {
        _reportCache[tower.key] = report;
        TrafficLog.add('ST',
            '[Desert] ✓ report: ${report.summaryLine} '
            'AS=${report.defensiveStrength} units=${report.totalEnemyUnits} '
            'RS=${report.rs} ${report.isDead ? "💀" : "✅"}');
      }
      return report;
    } catch (e) {
      TrafficLog.add('ER', '[Desert] fetchSpyReport error: $e');
      return null;
    }
  }

  DesertSpyReport? getCachedReport(DesertTower tower) =>
      _reportCache[tower.key];

  DesertSpyReport? _parseBsd(
    String payload,
    int messageId,
    Map<int, UnitCatalogEntry> catalog,
    DesertTower tower,
  ) {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final s = data['S'] as List?;
      if (s == null || s.length < 3) {
        TrafficLog.add('ER',
            '[Desert] bsd missing S array for ${tower.coordsLabel}');
        return null;
      }

      DefenderWing parseWing(dynamic wingData) {
        int melee = 0, ranged = 0;
        final units = <List<int>>[];
        if (wingData is List) {
          for (final u in wingData) {
            if (u is! List || u.length < 2) continue;
            final wodId = _asInt(u[0]);
            final amount = _asInt(u[1]);
            if (wodId <= 0 || amount <= 0) continue;
            units.add([wodId, amount]);
            if (_isRangedWodId(wodId, catalog)) {
              ranged += amount;
            } else {
              melee += amount;
            }
          }
        }
        return DefenderWing(melee: melee, ranged: ranged, units: units);
      }

      int wall = 0, gate = 0, moat = 0;
      final e = data['E'] as List?;
      if (e != null) {
        for (final eff in e) {
          if (eff is! List || eff.length < 2) continue;
          final effId = _asInt(eff[0]);
          final effParams = eff[1];
          if (effParams is List && effParams.isNotEmpty) {
            final lvl = (effParams[0] as num?)?.toInt() ?? 0;
            if (effId == 7) wall = lvl;
            if (effId == 8) gate = lvl;
            if (effId == 10) moat = lvl;
          }
        }
      }

      final so = data['SO'] as Map?;
      final ai = (data['AI'] as Map?) ?? (so?['AI'] as Map?);
      int tx = _asInt(ai?['X']);
      int ty = _asInt(ai?['Y']);
      if (tx <= 0 || ty <= 0) {
        tx = tower.x;
        ty = tower.y;
      }

      return DesertSpyReport(
        messageId: messageId,
        targetX: tx, targetY: ty,
        left: parseWing(s[0]),
        middle: parseWing(s[1]),
        right: parseWing(s[2]),
        defensiveStrength: _asInt(data['AS']),
        availableAttacks: _asInt(data['AS']),
        goldCampValue: _asInt(data['GC']),
        scoutCount: _asInt(data['SC']),
        scoutReportValue: _asInt(data['SR']),
        wallLevel: wall, gateLevel: gate, moatLevel: moat,
        rs: _asInt(data['RS']),
        fetchedAt: DateTime.now(),
      );
    } catch (e) {
      TrafficLog.add('ER', '[Desert] parse bsd error: $e');
      return null;
    }
  }

  bool _isRangedWodId(int wodId, Map<int, UnitCatalogEntry> catalog) {
    final entry = catalog[wodId];
    if (entry != null) {
      final n = entry.displayName.toLowerCase();
      if (n.contains('bow') || n.contains('archer') ||
          n.contains('crossbow') || n.contains('slinger') ||
          n.contains('mangonel') || n.contains('trebuchet') ||
          n.contains('ballista') || n.contains('ranged') ||
          n.contains('قوس') || n.contains('نابل') ||
          n.contains('رامي') || n.contains('منجنيق') ||
          n.contains('عرادة') || n.contains('قاذف')) {
        return true;
      }
    }
    const knownRanged = {
      603, 604, 605, 606, 611, 612, 613, 614, 615, 616, 617, 618, 619,
      620, 621, 622, 623, 624, 625, 626, 627, 628, 629, 630, 631, 632,
      633, 634, 635, 636, 637, 638, 639, 675, 676, 677, 678, 679, 680,
    };
    return knownRanged.contains(wodId);
  }

  static String _defKey(DesertTower t) => 'desert_def_${t.x}_${t.y}_${t.kid}';

  Future<DefenderSummary?> loadCachedDefenders(DesertTower tower) async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_defKey(tower));
    if (s == null || s.isEmpty) return null;
    try {
      return DefenderSummary.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCachedDefenders(
      DesertTower tower, DefenderSummary def) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_defKey(tower), jsonEncode(def.toJson()));
  }

  Future<DesertAttackResult> attack({
    required DesertTower tower,
    required OwnedCastle source,
    required int lordId,
    required List<List<int>> leftUnits,
    required List<List<int>> middleUnits,
    required List<List<int>> rightUnits,
    bool markCooldownAfterSuccess = true,
  }) async {
    final flat = [...leftUnits, ...middleUnits, ...rightUnits]
        .where((u) => u.length >= 2 && u[0] > 0 && u[1] > 0)
        .toList();
    if (flat.isEmpty) return DesertAttackResult.fail('NO_UNITS');

    final uniqueIds = <int>{};
    for (final u in flat) uniqueIds.add(u[0]);
    if (uniqueIds.length > 10) {
      return DesertAttackResult.fail(
          'TOO_MANY_UNIT_TYPES (${uniqueIds.length})');
    }

    await _ensureKingdom(tower.kid);
    try {
      // ✅ WT: 0، PTT: 1 (الريشة)
      final payload = {
        'SX': source.x, 'SY': source.y,
        'TX': tower.x, 'TY': tower.y,
        'KID': tower.kid, 'LID': lordId,
        'WT': 0, 'HBW': -1, 'BPC': 0, 'ATT': 0, 'AV': 0,
        'LP': 0, 'FC': 0, 'PTT': 1, 'SD': 0, 'ICA': 0, 'CD': 99,
        'A': [{
          'L': {'T': List.generate(2, (_) => [-1, 0]),
                'U': _fillUnits(leftUnits, 2)},
          'R': {'T': List.generate(2, (_) => [-1, 0]),
                'U': _fillUnits(rightUnits, 2)},
          'M': {'T': List.generate(3, (_) => [-1, 0]),
                'U': _fillUnits(middleUnits, 6)},
        }],
        'BKS': [], 'AST': [-1, -1, -1],
        'RW': List.generate(8, (_) => [-1, 0]),
        'ASCT': 0,
      };
      final total = flat.fold<int>(0, (s, e) => s + e[1]);
      TrafficLog.add('ST',
          '[Desert-Attack] cra → (${tower.x},${tower.y}) '
          'total=$total types=${uniqueIds.length} LID=$lordId PREMIUM=ON');

      final resp = await conn.sendXtAndWait(
        'cra', jsonEncode(payload),
        responseCmd: 'cra', timeoutMs: 25000, isAction: true,
        // ✅ فلترة: نتأكد إن الرد بتاع هجمتنا (بمطابقة TA)
        predicate: (m) {
          if (m.payload == null) return true;
          try {
            final data = jsonDecode(m.payload!) as Map;
            final aam = data['AAM'] as Map?;
            final inner = aam?['M'] as Map?;
            final ta = inner?['TA'] as List?;
            if (ta == null || ta.length < 3) return true;
            final tx = int.tryParse(ta[1].toString());
            final ty = int.tryParse(ta[2].toString());
            return tx == tower.x && ty == tower.y;
          } catch (_) {
            return true;
          }
        },
      );

      TrafficLog.add('ST', '[Desert-Attack] resp result=${resp.resultCode}');

      if (resp.resultCode == 0) {
        if (markCooldownAfterSuccess) {
          await markTowerAttacked(tower);
        }
        int? mid;
        if (resp.payload != null) {
          try {
            mid = _extractMovementMid(
                jsonDecode(resp.payload!) as Map<String, dynamic>);
          } catch (_) {}
        }
        return DesertAttackResult.ok(mid ?? -1, tower, total);
      }
      if (resp.resultCode == 91) return DesertAttackResult.fail('UNIT_NOT_SENDABLE_91');
      if (resp.resultCode == 218) return DesertAttackResult.fail('LORD_BUSY_218');
      if (resp.resultCode == 181) return DesertAttackResult.fail('MAX_MOVEMENTS_181');
      if (resp.resultCode == 100) return DesertAttackResult.fail('CRA_100');
      // ✅ 313 = TOO_MANY_UNITS
      if (resp.resultCode == 313) {
        int sum(List<List<int>> l) =>
            l.fold<int>(0, (s, e) => s + (e.length >= 2 ? e[1] : 0));
        await PlannerConfig.current.learnTooManyUnits(
          flankSent: max(sum(leftUnits), sum(rightUnits)),
          middleSent: sum(middleUnits),
        );
        TrafficLog.add('ST',
            '[Desert-Attack] 313 → caps now flank=${PlannerConfig.current.flankCap} '
            'middle=${PlannerConfig.current.middleCap}');
        return DesertAttackResult.fail('TOO_MANY_UNITS_313');
      }
      return DesertAttackResult.fail('CRA ${resp.resultCode}');
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Attack] exception: $e');
      return DesertAttackResult.fail('$e');
    }
  }

  Future<bool> recall(int mid) async {
    try {
      final resp = await conn.sendXtAndWait(
        'mcm', jsonEncode({'MID': mid}),
        responseCmd: 'mcm', timeoutMs: 15000, isAction: true,
      );
      return resp.resultCode == 0;
    } catch (_) {
      return false;
    }
  }

  // ✅✅✅ التوزيع الذكي: موجة واحدة، جناح 46/2 أنواع، أمام 112/6 أنواع
  UnitSuggestion suggestCounter({
    required List<CastleUnit> available,
    required DefenderSummary defenders,
    int maxTypes = 10,
    DesertSpyReport? report,
  }) {
    final stock = <PlanUnit>[];
    for (final u in available) {
      if (!u.isCombat || u.amount <= 0) continue;
      stock.add(PlanUnit(
        id: u.wodId,
        stock: u.amount,
        ranged: _isRangedUnit(u),
        defensive: u.isDefensive,
      ));
    }

    if (stock.isEmpty) {
      return UnitSuggestion(
        left: [], middle: [], right: [],
        reason: 'لا توجد وحدات قتالية',
      );
    }

    final defs = report != null
        ? _defsFromReport(report)
        : _defsFromSummary(defenders);

    final plan = AttackPlanner.plan(
      stock: stock,
      defenders: defs,
      maxTypes: maxTypes,
    );

    if (plan.total <= 0) {
      return UnitSuggestion(
        left: [], middle: [], right: [],
        reason: plan.reason,
      );
    }

    return UnitSuggestion(
      left: plan.left,
      middle: plan.middle,
      right: plan.right,
      reason: plan.reason,
    );
  }

  List<List<int>> _fillUnits(List<List<int>> units, int count) {
    final valid = units
        .where((u) => u.length >= 2 && u[0] > 0 && u[1] > 0)
        .toList();
    final r = <List<int>>[];
    for (int i = 0; i < count; i++) {
      if (i < valid.length) {
        r.add([valid[i][0], valid[i][1]]);
      } else {
        r.add([-1, 0]);
      }
    }
    return r;
  }

  int? _extractMovementMid(Map<String, dynamic> data) {
    final a = data['A'];
    if (a is Map) {
      final m = a['M'];
      if (m is Map) {
        final mid = _asIntOrNull(m['MID']);
        if (mid != null && mid > 0) return mid;
      }
    }
    return _asIntOrNull(data['MID']);
  }

  static int _asInt(dynamic v, [int def = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }

  static int? _asIntOrNull(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}