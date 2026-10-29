import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';

const int kDesertRadiusMin = 5;
const int kDesertRadiusMax = 100;
const int kDesertRadiusStep = 5;
const int kDesertChunkSize = 13;

// ═══════════════════════════════════════════════════════════
//  DesertTower — هدف برج صحراء (type 2)
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
  String get spyTimeLabel {
    if (lastSpyAt == null) return '';
    final t = lastSpyAt!;
    return '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}';
  }
}

// ═══════════════════════════════════════════════════════════
//  SpyResult
// ═══════════════════════════════════════════════════════════
class DesertSpyResult {
  final bool success;
  final String? error;
  final int? movementId;
  final int? scoutCount;
  final int? scoutReportValue; // SR من الرد

  DesertSpyResult._({
    required this.success, this.error, this.movementId,
    this.scoutCount, this.scoutReportValue,
  });

  factory DesertSpyResult.ok(int? mid, int? scouts, int? sr) =>
      DesertSpyResult._(
          success: true, movementId: mid,
          scoutCount: scouts, scoutReportValue: sr);
  factory DesertSpyResult.fail(String err) =>
      DesertSpyResult._(success: false, error: err);
}

// ═══════════════════════════════════════════════════════════
//  AttackResult
// ═══════════════════════════════════════════════════════════
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
      DesertAttackResult._(
          success: true, movementId: mid, target: t, totalUnits: units);
  factory DesertAttackResult.fail(String err) =>
      DesertAttackResult._(success: false, error: err);
}

// ═══════════════════════════════════════════════════════════
//  DefenderSummary — إدخال يدوي من تقرير التجسس في اللعبة
// ═══════════════════════════════════════════════════════════
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

  int get total => leftMelee + leftRanged + middleMelee + middleRanged +
      rightMelee + rightRanged;
}

// ═══════════════════════════════════════════════════════════
//  UnitSuggestion
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
//  Settings
// ═══════════════════════════════════════════════════════════
class DesertAttackSettings {
  int radiusTiles;
  String sortBy;
  int sourceAreaId;

  DesertAttackSettings({
    this.radiusTiles = 50,
    this.sortBy = 'distance',
    this.sourceAreaId = 0,
  });

  static const _kRadius = 'desert_radius_v2';
  static const _kSort = 'desert_sort_v2';
  static const _kSource = 'desert_source_v2';

  static Future<DesertAttackSettings> load() async {
    final p = await SharedPreferences.getInstance();
    int radius = p.getInt(_kRadius) ?? 50;
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
//  Service
// ═══════════════════════════════════════════════════════════
class DesertAttackService {
  final GgeClient conn;
  DesertAttackService(this.conn);

  int? _currentKid;
  DateTime? _lastJcaAt;
  DateTime? _lastScanAt;
  static const _scanCooldown = Duration(seconds: 30);

  Future<void> _ensureKingdom(int kid) async {
    if (_currentKid == kid &&
        _lastJcaAt != null &&
        DateTime.now().difference(_lastJcaAt!).inMinutes < 5) return;
    try {
      await conn.sendXtAndWait(
        'jca',
        jsonEncode({'CID': -1, 'KID': kid}),
        responseCmd: 'jaa',
        timeoutMs: 8000,
        isAction: false,
      );
      _currentKid = kid;
      _lastJcaAt = DateTime.now();
    } catch (e) {
      TrafficLog.add('ER', '[Desert] jca failed: $e');
    }
  }

  /// يمسح المنطقة ويرجع أبراج الصحراء (type 2) — مفيش ssi بعد المسح
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

    if (chunks.length > 40) {
      chunks.removeRange(40, chunks.length);
      TrafficLog.add('ST', '[Desert] Scan capped to 40 chunks');
    }

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
          responseCmd: 'gaa',
          timeoutMs: 15000,
          isAction: false,
        );

        if (resp.resultCode == 0 && resp.payload != null) {
          final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
          final ai = data['AI'] as List?;
          if (ai != null) {
            for (final entry in ai) {
              if (entry is! List || entry.length < 3) continue;
              final type = _asInt(entry[0]);
              if (type != 2) continue; // أبراج صحراء فقط

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
        TrafficLog.add('ER', '[Desert] gaa chunk error: $e');
      }
      done++;
      onProgress?.call(done, chunks.length);
      if (done < chunks.length) {
        await Future.delayed(Duration(milliseconds: 800 + Random().nextInt(400)));
      }
    }

    TrafficLog.add('ST',
        '[Desert] Scan done: ${found.length} towers from ${chunks.length} chunks');
    return found;
  }

  /// csm — إرسال جواسيس
  Future<DesertSpyResult> spy({
    required DesertTower tower,
    required OwnedCastle source,
    int scoutCount = 11,
  }) async {
    await _ensureKingdom(tower.kid);
    try {
      final payload = {
        'SID': source.areaId,
        'TX': tower.x, 'TY': tower.y,
        'SC': scoutCount,
        'ST': 0, 'SE': 100,
        'HBW': -1,
        'KID': tower.kid,
        'PTT': 1, 'SD': 0,
      };
      TrafficLog.add('ST',
          '[Desert-Spy] csm → (${tower.x},${tower.y}) scouts=$scoutCount');

      final resp = await conn.sendXtAndWait(
        'csm', jsonEncode(payload),
        responseCmd: 'csm',
        timeoutMs: 25000,
        isAction: true,
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
        } catch (e) {
          TrafficLog.add('ER', '[Desert-Spy] parse error: $e');
        }
        TrafficLog.add('ST',
            '[Desert-Spy] ✓ sent MID=$mid scouts=$scouts SR=$sr — '
            'التقرير هيظهر في اللعبة → الرسائل ✉️ → تقارير');
        return DesertSpyResult.ok(mid, scouts, sr);
      }
      if (resp.resultCode == 218) return DesertSpyResult.fail('LORD_BUSY_218');
      if (resp.resultCode == 181) return DesertSpyResult.fail('MAX_MOVEMENTS_181');
      if (resp.resultCode == 91) return DesertSpyResult.fail('UNIT_NOT_SENDABLE_91');
      TrafficLog.add('ER', '[Desert-Spy] csm error ${resp.resultCode}');
      return DesertSpyResult.fail('CSM ${resp.resultCode}');
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Spy] exception: $e');
      return DesertSpyResult.fail('$e');
    }
  }

  /// cra — الهجوم الكامل مع 3 أجنجة
  Future<DesertAttackResult> attack({
    required DesertTower tower,
    required OwnedCastle source,
    required int lordId,
    required List<List<int>> leftUnits,
    required List<List<int>> middleUnits,
    required List<List<int>> rightUnits,
  }) async {
    final all = [...leftUnits, ...middleUnits, ...rightUnits]
        .where((u) => u.length >= 2 && u[1] > 0)
        .toList();
    if (all.isEmpty) return DesertAttackResult.fail('NO_UNITS');
    if (all.length > 10) return DesertAttackResult.fail('TOO_MANY_UNIT_TYPES');

    await _ensureKingdom(tower.kid);
    try {
      final payload = {
        'SX': source.x, 'SY': source.y,
        'TX': tower.x, 'TY': tower.y,
        'KID': tower.kid,
        'LID': lordId,
        'WT': 0, 'HBW': -1, 'BPC': 0, 'ATT': 0, 'AV': 0,
        'LP': 0, 'FC': 0, 'PTT': 1, 'SD': 0, 'ICA': 0, 'CD': 99,
        'A': [{
          'L': {
            'T': List.generate(2, (_) => [-1, 0]),
            'U': _fillUnits(leftUnits, 2),
          },
          'R': {
            'T': List.generate(2, (_) => [-1, 0]),
            'U': _fillUnits(rightUnits, 2),
          },
          'M': {
            'T': List.generate(6, (_) => [-1, 0]),
            'U': _fillUnits(middleUnits, 6),
          },
        }],
        'BKS': [],
        'AST': [-1, -1, -1],
        'RW': List.generate(8, (_) => [-1, 0]),
        'ASCT': 0,
      };

      final total = all.fold<int>(0, (s, e) => s + e[1]);
      TrafficLog.add('ST',
          '[Desert-Attack] cra → (${tower.x},${tower.y}) '
          'L=${leftUnits.length} M=${middleUnits.length} R=${rightUnits.length} '
          'total=$total LID=$lordId');

      final resp = await conn.sendXtAndWait(
        'cra', jsonEncode(payload),
        responseCmd: 'cra',
        timeoutMs: 25000,
        isAction: true,
      );

      TrafficLog.add('ST',
          '[Desert-Attack] cra resp result=${resp.resultCode}');

      if (resp.resultCode == 0) {
        int? mid;
        if (resp.payload != null) {
          try {
            final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
            mid = _extractMovementMid(data);
          } catch (_) {}
        }
        return DesertAttackResult.ok(mid ?? -1, tower, total);
      }
      if (resp.resultCode == 91) {
        return DesertAttackResult.fail('UNIT_NOT_SENDABLE_91');
      }
      if (resp.resultCode == 218) {
        return DesertAttackResult.fail('LORD_BUSY_218');
      }
      if (resp.resultCode == 181) {
        return DesertAttackResult.fail('MAX_MOVEMENTS_181');
      }
      if (resp.resultCode == 100) {
        return DesertAttackResult.fail('CRA_100: جرب جيش أكبر');
      }
      return DesertAttackResult.fail('CRA ${resp.resultCode}');
    } catch (e) {
      TrafficLog.add('ER', '[Desert-Attack] exception: $e');
      return DesertAttackResult.fail('$e');
    }
  }

  /// mcm — انسحاب
  Future<bool> recall(int mid) async {
    try {
      TrafficLog.add('ST', '[Desert] mcm MID=$mid');
      final resp = await conn.sendXtAndWait(
        'mcm', jsonEncode({'MID': mid}),
        responseCmd: 'mcm',
        timeoutMs: 15000,
        isAction: true,
      );
      TrafficLog.add('ST', '[Desert] mcm resp result=${resp.resultCode}');
      return resp.resultCode == 0;
    } catch (e) {
      TrafficLog.add('ER', '[Desert] mcm error: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════
  //  Smart counter suggestion
  // ═══════════════════════════════════════════════════════
  UnitSuggestion suggestCounter({
    required List<CastleUnit> available,
    required DefenderSummary defenders,
    int maxTypes = 10,
  }) {
    // melee وحدات: wodId أصغر (سيوف، رماح، فؤوس...) — 601-620
    // ranged وحدات: wodId أكبر (أقواس، مناجيق...) — 621+
    final playerMelee = available
        .where((u) => u.isCombat && u.wodId >= 601 && u.wodId <= 620)
        .toList();
    final playerRanged = available
        .where((u) => u.isCombat && u.wodId >= 621)
        .toList();

    // fallback لو مش عارفين نصنف
    final meleeAvail = playerMelee.isNotEmpty
        ? playerMelee
        : available.where((u) => u.isCombat).toList();
    final rangedAvail = playerRanged.isNotEmpty
        ? playerRanged
        : available.where((u) => u.isCombat).toList();

    List<List<int>> pick(List<CastleUnit> pool, int maxSlots) {
      final result = <List<int>>[];
      for (final u in pool.take(maxSlots)) {
        if (u.amount > 0) result.add([u.wodId, u.amount]);
      }
      return result;
    }

    // القاعدة:
    // دفاع ranged → هجوم melee (يوصل بسرعة ويضرب)
    // دفاع melee → هجوم ranged (يضرب من بعيد بدون خسائر)
    final leftPool =
        defenders.leftRanged > defenders.leftMelee ? meleeAvail : rangedAvail;
    final middlePool = defenders.middleRanged > defenders.middleMelee
        ? meleeAvail
        : rangedAvail;
    final rightPool =
        defenders.rightRanged > defenders.rightMelee ? meleeAvail : rangedAvail;

    final left = pick(leftPool, 2);
    final middle = pick(middlePool, 6);
    final right = pick(rightPool, 2);

    final all = [...left, ...middle, ...right];
    if (all.length > maxTypes) {
      final excess = all.length - maxTypes;
      final newMiddle = middle.take((6 - excess).clamp(0, 6)).toList();
      return UnitSuggestion(
        left: left, middle: newMiddle, right: right,
        reason: 'توزيع ذكي (تم تقليص M للحد الأقصى)',
      );
    }

    return UnitSuggestion(
      left: left, middle: middle, right: right,
      reason: 'توزيع ذكي: L=${left.length} M=${middle.length} R=${right.length}',
    );
  }

  // ═══════════════════════════════════════════════════════
  //  helpers
  // ═══════════════════════════════════════════════════════
  List<List<int>> _fillUnits(List<List<int>> units, int count) {
    final result = <List<int>>[];
    for (int i = 0; i < count; i++) {
      if (i < units.length && units[i].length >= 2 && units[i][1] > 0) {
        result.add([units[i][0], units[i][1]]);
      } else {
        result.add([-1, 0]);
      }
    }
    return result;
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
    final direct = _asIntOrNull(data['MID']);
    if (direct != null && direct > 0) return direct;
    return null;
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