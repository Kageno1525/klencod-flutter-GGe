import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';

// ═══════════════════════════════════════════════════════════
//  Models
// ═══════════════════════════════════════════════════════════
class NpcTarget {
  final int x, y, kid;
  final int type; // 24 = camp, 25 = resource node
  final int areaId;
  final int rawLevel;
  final int sourceAreaId;
  final String sourceName;
  final double distanceFromSource;

  // from ssi enrichment
  int? goldCampValue; // GC
  int? attacksRemaining; // AS
  int? resourceAmount;
  DateTime? lastEnrichedAt;

  NpcTarget({
    required this.x,
    required this.y,
    required this.kid,
    required this.type,
    required this.areaId,
    required this.rawLevel,
    required this.sourceAreaId,
    required this.sourceName,
    required this.distanceFromSource,
    this.goldCampValue,
    this.attacksRemaining,
    this.resourceAmount,
    this.lastEnrichedAt,
  });

  NpcTarget copyWith({
    int? goldCampValue,
    int? attacksRemaining,
    int? resourceAmount,
    DateTime? lastEnrichedAt,
  }) =>
      NpcTarget(
        x: x,
        y: y,
        kid: kid,
        type: type,
        areaId: areaId,
        rawLevel: rawLevel,
        sourceAreaId: sourceAreaId,
        sourceName: sourceName,
        distanceFromSource: distanceFromSource,
        goldCampValue: goldCampValue ?? this.goldCampValue,
        attacksRemaining: attacksRemaining ?? this.attacksRemaining,
        resourceAmount: resourceAmount ?? this.resourceAmount,
        lastEnrichedAt: lastEnrichedAt ?? this.lastEnrichedAt,
      );

  bool get isEnriched => lastEnrichedAt != null;
  bool get isStaleEnrichment {
    if (lastEnrichedAt == null) return true;
    return DateTime.now().difference(lastEnrichedAt!).inMinutes >= 5;
  }

  bool get isLegendary => (goldCampValue ?? 0) >= 75;
  bool get isHighValue => (goldCampValue ?? 0) >= 60;

  String get typeLabel => type == 24 ? 'Camp' : 'Resource';
}

class NpcAttackResult {
  final bool success;
  final String? error;
  final int? movementId;
  final NpcTarget? target;
  final int totalUnits;

  NpcAttackResult._({
    required this.success,
    this.error,
    this.movementId,
    this.target,
    this.totalUnits = 0,
  });

  factory NpcAttackResult.ok(int mid, NpcTarget t, int units) =>
      NpcAttackResult._(success: true, movementId: mid, target: t, totalUnits: units);
  factory NpcAttackResult.fail(String err) =>
      NpcAttackResult._(success: false, error: err);
}

// ═══════════════════════════════════════════════════════════
//  Attack Filter Settings (persisted)
// ═══════════════════════════════════════════════════════════
class AttackFilterSettings {
  Set<int> visibleRawLevels;
  int minGC;
  int radiusTiles;
  String sortBy; // 'gc' | 'level' | 'distance' | 'as'
  bool onlyLegendary;
  int sourceAreaId;

  AttackFilterSettings({
    Set<int>? visibleRawLevels,
    this.minGC = 0,
    this.radiusTiles = 50,
    this.sortBy = 'gc',
    this.onlyLegendary = false,
    this.sourceAreaId = 0,
  }) : visibleRawLevels = visibleRawLevels ?? {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14};

  static const _kLevels = 'atk_levels';
  static const _kMinGC = 'atk_min_gc';
  static const _kRadius = 'atk_radius';
  static const _kSort = 'atk_sort';
  static const _kLegendary = 'atk_legendary';
  static const _kSource = 'atk_source';

  static Future<AttackFilterSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final lvl = p.getStringList(_kLevels);
    return AttackFilterSettings(
      visibleRawLevels: lvl == null
          ? null
          : lvl.map((s) => int.tryParse(s) ?? 0).where((i) => i > 0).toSet(),
      minGC: p.getInt(_kMinGC) ?? 0,
      radiusTiles: p.getInt(_kRadius) ?? 50,
      sortBy: p.getString(_kSort) ?? 'gc',
      onlyLegendary: p.getBool(_kLegendary) ?? false,
      sourceAreaId: p.getInt(_kSource) ?? 0,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kLevels, visibleRawLevels.map((i) => i.toString()).toList());
    await p.setInt(_kMinGC, minGC);
    await p.setInt(_kRadius, radiusTiles);
    await p.setString(_kSort, sortBy);
    await p.setBool(_kLegendary, onlyLegendary);
    await p.setInt(_kSource, sourceAreaId);
  }
}

// ═══════════════════════════════════════════════════════════
//  Attack Service
// ═══════════════════════════════════════════════════════════
class AttackService {
  final GgeClient conn;
  AttackService(this.conn);

  // Track current kingdom to skip unnecessary jca calls
  int? _currentKid;
  DateTime? _lastJcaAt;

  // Scan cache to prevent spam
  DateTime? _lastScanAt;
  static const _scanCooldown = Duration(seconds: 30);

  Future<void> _ensureKingdom(int kid) async {
    if (_currentKid == kid &&
        _lastJcaAt != null &&
        DateTime.now().difference(_lastJcaAt!).inMinutes < 5) {
      return;
    }
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
      TrafficLog.add('ER', '[Attack] jca failed: $e');
    }
  }

  /// مسح منطقة حول القلعة المصدر
  Future<List<NpcTarget>> scanArea({
    required OwnedCastle source,
    required int radiusTiles,
    void Function(int done, int total)? onProgress,
  }) async {
    if (_lastScanAt != null &&
        DateTime.now().difference(_lastScanAt!) < _scanCooldown) {
      throw Exception('SCAN_COOLDOWN: انتظر قليلاً قبل مسح جديد');
    }
    _lastScanAt = DateTime.now();

    await _ensureKingdom(source.kingdomId);

    final cx = source.x;
    final cy = source.y;
    final minX = (cx - radiusTiles).clamp(1, 1000);
    final maxX = (cx + radiusTiles).clamp(1, 1000);
    final minY = (cy - radiusTiles).clamp(1, 1000);
    final maxY = (cy + radiusTiles).clamp(1, 1000);

    final chunks = <List<int>>[];
    for (int x = minX; x <= maxX; x += 12) {
      for (int y = minY; y <= maxY; y += 12) {
        final x2 = (x + 11).clamp(1, 1000);
        final y2 = (y + 11).clamp(1, 1000);
        chunks.add([x, y, x2, y2]);
      }
    }

    // Hard cap — ban protection
    if (chunks.length > 40) {
      chunks.removeRange(40, chunks.length);
      TrafficLog.add('ST', '[Attack] Scan capped to 40 chunks (ban protection)');
    }

    final found = <NpcTarget>[];
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
              if (entry is! List || entry.length < 4) continue;
              final type = _asInt(entry[0]);
              if (type != 24 && type != 25) continue;

              final x = _asInt(entry[1]);
              final y = _asInt(entry[2]);
              final areaId = _asInt(entry[3]);
              final rawLevel = _asInt(entry.length > 5 ? entry[5] : 0);

              final key = '$x,$y,$areaId';
              if (seen.contains(key)) continue;
              seen.add(key);

              final dx = (x - cx).toDouble();
              final dy = (y - cy).toDouble();
              final dist = sqrt(dx * dx + dy * dy);

              found.add(NpcTarget(
                x: x, y: y, kid: source.kingdomId,
                type: type, areaId: areaId, rawLevel: rawLevel,
                sourceAreaId: source.areaId,
                sourceName: source.displayName,
                distanceFromSource: dist,
              ));
            }
          }
        }
      } catch (e) {
        TrafficLog.add('ER', '[Attack] gaa chunk error: $e');
      }

      done++;
      onProgress?.call(done, chunks.length);

      if (done < chunks.length) {
        // Ban protection: 800-1200ms
        await Future.delayed(Duration(milliseconds: 800 + Random().nextInt(400)));
      }
    }

    TrafficLog.add('ST', '[Attack] Scan done: ${found.length} targets from ${chunks.length} chunks');
    return found;
  }

  /// جلب تفاصيل هدف (GC + AS)
  Future<NpcTarget> enrich(NpcTarget target) async {
    await _ensureKingdom(target.kid);

    try {
      final resp = await conn.sendXtAndWait(
        'ssi',
        jsonEncode({'TX': target.x, 'TY': target.y, 'KID': target.kid}),
        responseCmd: 'ssi',
        timeoutMs: 10000,
        isAction: false,
      );

      if (resp.resultCode != 0 || resp.payload == null) return target;

      final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
      final gc = _asInt(data['GC']);
      final as = _asInt(data['AS']);

      final gaa = data['gaa'] as Map?;
      final ai = gaa?['AI'] as List?;
      int? resourceAmt;
      if (ai != null && ai.isNotEmpty && ai[0] is List) {
        final first = ai[0] as List;
        if (first.length >= 8) {
          final r = _asInt(first[7]);
          if (r > 0) resourceAmt = r;
        }
      }

      return target.copyWith(
        goldCampValue: gc,
        attacksRemaining: as,
        resourceAmount: resourceAmt,
        lastEnrichedAt: DateTime.now(),
      );
    } catch (e) {
      TrafficLog.add('ER', '[Attack] ssi error: $e');
      return target;
    }
  }

  /// هجوم على هدف NPC
  Future<NpcAttackResult> attack({
    required NpcTarget target,
    required OwnedCastle source,
    required List<List<int>> units,
    required int lordId,
  }) async {
    if (units.isEmpty) return NpcAttackResult.fail('NO_UNITS');
    if (units.length > 10) return NpcAttackResult.fail('TOO_MANY_UNIT_TYPES');

    if (source.kingdomId != target.kid) {
      return NpcAttackResult.fail('CROSS_KINGDOM: المصدر والهدف في مملكتين مختلفتين');
    }

    // jca
    await _ensureKingdom(target.kid);

    // adi preview
    try {
      await conn.sendXtAndWait(
        'adi',
        jsonEncode({
          'SX': source.x, 'SY': source.y,
          'TX': target.x, 'TY': target.y,
          'KID': target.kid,
        }),
        responseCmd: 'adi',
        timeoutMs: 10000,
        isAction: false,
      );
    } catch (e) {
      TrafficLog.add('ST', '[Attack] adi skipped: $e');
    }

    // cra execute
    try {
      final payload = _buildCraPayload(
        sx: source.x, sy: source.y,
        tx: target.x, ty: target.y,
        kid: target.kid, lid: lordId, units: units,
      );

      TrafficLog.add('ST', '[CRA] → (${target.x},${target.y}) units=${units.length} types');

      final resp = await conn.sendXtAndWait(
        'cra',
        jsonEncode(payload),
        responseCmd: 'cra',
        timeoutMs: 25000,
        isAction: true,
      );

      TrafficLog.add('ST', '[CRA-RESP] result=${resp.resultCode}');

      if (resp.resultCode == 0) {
        final mid = _extractMid(resp.payload);
        final total = units.fold<int>(0, (s, e) => s + e[1]);
        return NpcAttackResult.ok(mid ?? -1, target, total);
      }

      // error mapping
      if (resp.resultCode == 91) return NpcAttackResult.fail('UNIT_NOT_SENDABLE_91');
      if (resp.resultCode == 218) return NpcAttackResult.fail('LORD_BUSY_218');
      if (resp.resultCode == 181) return NpcAttackResult.fail('MAX_MOVEMENTS_181');
      if ([219, 222, 256, 404].contains(resp.resultCode)) {
        return NpcAttackResult.fail('LORD_UNAVAILABLE');
      }

      return NpcAttackResult.fail('CRA error ${resp.resultCode}: ${errorName(resp.resultCode)}');
    } catch (e) {
      TrafficLog.add('ER', '[CRA] exception: $e');
      return NpcAttackResult.fail('$e');
    }
  }

  Map<String, dynamic> _buildCraPayload({
    required int sx, sy, tx, ty, kid, lid,
    required List<List<int>> units,
  }) {
    List<List<int>> fillSlots(List<List<int>> u, int count) {
      final r = <List<int>>[];
      for (int i = 0; i < count; i++) {
        if (i < u.length) r.add(u[i]);
        else r.add([-1, 0]);
      }
      return r;
    }

    // ✅ التوزيع: M أولاً (6 slots) — الأسلم هجومياً
    // ثم L (2 slots)، ثم R (2 slots)
    final m = units.take(6).toList();
    final l = units.skip(6).take(2).toList();
    final r = units.skip(8).take(2).toList();

    return {
      'SX': sx, 'SY': sy, 'TX': tx, 'TY': ty, 'KID': kid,
      'LID': lid, 'WT': 0, 'HBW': -1, 'BPC': 0, 'ATT': 0, 'AV': 0,
      'LP': 0, 'FC': 0, 'PTT': 0, 'SD': 0, 'ICA': 0, 'CD': 99,
      'A': [{
        'L': {'T': [[-1, 0], [-1, 0]], 'U': fillSlots(l, 2)},
        'R': {'T': [[-1, 0], [-1, 0]], 'U': fillSlots(r, 2)},
        'M': {'T': [[-1, 0], [-1, 0], [-1, 0]], 'U': fillSlots(m, 6)},
      }],
      'BKS': [],
      'AST': [-1, -1, -1],
      'RW': List.generate(8, (_) => [-1, 0]),
      'ASCT': 0,
    };
  }

  int? _extractMid(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      // cra response structure varies — try common paths
      final a = data['A'] as Map?;
      final m = a?['M'] as Map?;
      final mid = m?['MID'] ?? data['MID'] ?? (a?['M'] as Map?)?['MID'];
      if (mid is int) return mid;
      if (mid is num) return mid.toInt();
      if (mid is String) return int.tryParse(mid);
    } catch (_) {}
    return null;
  }

  static int _asInt(dynamic v, [int def = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }
}