import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';
import 'samurai_service.dart' show SamuraiMath;

/// Type 27 = Bedouin Camp (NPC — owner = -1)
const Set<int> kBedouinCampTypes = {27};

class BedouinCamp {
  final int x, y, kid, type;
  final int level;
  final int troopsL, troopsR, troopsM;
  final int campId;
  final int ownerId;
  final double distanceFromSource;
  final int sourceAreaId;
  final String sourceName;
  DateTime? lastAttackAt;

  BedouinCamp({
    required this.x, required this.y, required this.kid, required this.type,
    required this.level,
    required this.troopsL, required this.troopsR, required this.troopsM,
    required this.campId,
    this.ownerId = -1,
    required this.distanceFromSource,
    required this.sourceAreaId, required this.sourceName,
    this.lastAttackAt,
  });

  int get totalTroops => troopsL + troopsR + troopsM;
  bool get isPlayerCamp => ownerId != -1;

  String get coordsLabel => '($x,$y)';
  String get key => '$x,$y,$kid';
  String get typeName => 'Bedouin';

  BedouinCamp copyWith({DateTime? lastAttackAt}) => BedouinCamp(
    x: x, y: y, kid: kid, type: type,
    level: level,
    troopsL: troopsL, troopsR: troopsR, troopsM: troopsM,
    campId: campId, ownerId: ownerId,
    distanceFromSource: distanceFromSource,
    sourceAreaId: sourceAreaId, sourceName: sourceName,
    lastAttackAt: lastAttackAt ?? this.lastAttackAt,
  );
}

class BedouinAttackConfig {
  final int waves;
  final bool useTools;
  final int toolIdWave1;
  final int toolIdWave2;
  final int toolIdWave3;
  final int toolL, toolM, toolR;

  const BedouinAttackConfig({
    this.waves = 3,
    this.useTools = true,
    this.toolIdWave1 = 1,
    this.toolIdWave2 = 164,
    this.toolIdWave3 = 1,
    this.toolL = 20, this.toolM = 30, this.toolR = 20,
  });

  BedouinAttackConfig copyWith({int? waves, bool? useTools}) =>
    BedouinAttackConfig(
      waves: waves ?? this.waves,
      useTools: useTools ?? this.useTools,
      toolIdWave1: toolIdWave1,
      toolIdWave2: toolIdWave2,
      toolIdWave3: toolIdWave3,
      toolL: toolL, toolM: toolM, toolR: toolR,
    );
}

class BedouinAttackResult {
  final bool success;
  final String? error;
  final int? movementId;
  final BedouinCamp? target;
  final int totalUnits;
  final int wavesSent;
  final int toolsUsed;

  BedouinAttackResult._({
    required this.success, this.error, this.movementId, this.target,
    this.totalUnits = 0, this.wavesSent = 0, this.toolsUsed = 0,
  });

  factory BedouinAttackResult.ok({
    required int mid, required BedouinCamp t,
    required int units, required int waves, required int tools,
  }) => BedouinAttackResult._(
    success: true, movementId: mid, target: t,
    totalUnits: units, wavesSent: waves, toolsUsed: tools,
  );

  factory BedouinAttackResult.fail(String err) =>
    BedouinAttackResult._(success: false, error: err);
}

class BedouinSettings {
  int radiusTiles;
  int sourceAreaId;

  BedouinSettings({this.radiusTiles = 30, this.sourceAreaId = 0});

  static const _kRadius = 'bedouin_radius_v1';
  static const _kSource = 'bedouin_source_v1';

  static Future<BedouinSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return BedouinSettings(
      radiusTiles: (p.getInt(_kRadius) ?? 30).clamp(10, 100),
      sourceAreaId: p.getInt(_kSource) ?? 0,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kRadius, radiusTiles);
    await p.setInt(_kSource, sourceAreaId);
  }
}

class BedouinService {
  final GgeClient conn;
  BedouinService(this.conn);

  int? _currentKid;
  DateTime? _lastJcaAt, _lastScanAt;
  static const _scanCooldown = Duration(seconds: 10);
  static const _chunkSize = 13;

  int? _playerLevel;
  int? get playerLevel => _playerLevel;

  /// ✅ يجب استدعاؤها من AutoService أو من scanArea (auto-fetch)
  void setPlayerLevel(int lvl) {
    if (lvl > 0) _playerLevel = lvl;
  }

  Future<void> _ensureKingdom(int kid) async {
    if (_currentKid == kid &&
        _lastJcaAt != null &&
        DateTime.now().difference(_lastJcaAt!).inMinutes < 5) return;
    try {
      final resp = await conn.sendXtAndWait(
        'jca',
        jsonEncode({'CID': -1, 'KID': kid}),
        responseCmd: 'jaa', timeoutMs: 8000, isAction: false,
      );
      _currentKid = kid;
      _lastJcaAt = DateTime.now();

      // ✅ Auto-fetch player level
      if (_playerLevel == null && resp.payload != null) {
        try {
          final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
          final gca = data['gca'] as Map?;
          final o = gca?['O'] as Map?;
          if (o != null) {
            final lvl = _asInt(o['L']);
            final ll = _asInt(o['LL']);
            if (lvl > 0) {
              _playerLevel = lvl + ll;
              TrafficLog.add('ST',
                  '[Bedouin] 👤 Player level: $_playerLevel');
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<List<BedouinCamp>> scanArea({
    required OwnedCastle source,
    required int radiusTiles,
    int maxLevel = 20,
    bool skipPlayerCamps = true,
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

    final startX = (minX ~/ _chunkSize) * _chunkSize;
    final endX = (maxX ~/ _chunkSize) * _chunkSize;
    final startY = (minY ~/ _chunkSize) * _chunkSize;
    final endY = (maxY ~/ _chunkSize) * _chunkSize;

    final chunks = <List<int>>[];
    for (int x = startX; x <= endX; x += _chunkSize) {
      for (int y = startY; y <= endY; y += _chunkSize) {
        chunks.add([
          x, y,
          (x + _chunkSize - 1).clamp(1, 1000),
          (y + _chunkSize - 1).clamp(1, 1000),
        ]);
      }
    }
    if (chunks.length > 40) chunks.removeRange(40, chunks.length);

    final found = <BedouinCamp>[];
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
              final type = _asInt(entry[0]);
              if (!kBedouinCampTypes.contains(type)) continue;

              final x = _asInt(entry[1]);
              final y = _asInt(entry[2]);
              final key = '$x,$y';
              if (seen.contains(key)) continue;

              final ownerId = _asInt(entry[3], -1);
              if (skipPlayerCamps && ownerId != -1) continue;

              int campId = 0;
              int encodedLevel = 0;
              int tL = 0, tR = 0, tM = 0;

              if (entry.length > 5) campId = _asInt(entry[5]);
              if (entry.length > 7) encodedLevel = _asInt(entry[7]);
              if (entry.length > 9) tL = _asInt(entry[9]);
              if (entry.length > 10) tR = _asInt(entry[10]);
              if (entry.length > 11) tM = _asInt(entry[11]);

              final totalTroops = tL + tR + tM;
              int level;
              if (encodedLevel < 0 && encodedLevel <= -100) {
                level = ((-encodedLevel) ~/ 100).clamp(1, 20);
              } else if (totalTroops > 0) {
                level = (totalTroops / 120).ceil().clamp(1, 20);
              } else {
                level = 1;
              }

              if (maxLevel > 0 && level > maxLevel) continue;

              seen.add(key);
              final dx = (x - cx).toDouble();
              final dy = (y - cy).toDouble();
              found.add(BedouinCamp(
                x: x, y: y, kid: source.kingdomId, type: type,
                level: level,
                troopsL: tL, troopsR: tR, troopsM: tM,
                campId: campId, ownerId: ownerId,
                distanceFromSource: sqrt(dx * dx + dy * dy),
                sourceAreaId: source.areaId,
                sourceName: source.displayName,
              ));
            }
          }
        }
      } catch (e) {
        TrafficLog.add('ER', '[Bedouin] chunk error: $e');
      }
      done++;
      onProgress?.call(done, chunks.length);
      if (done < chunks.length) {
        await Future.delayed(
            Duration(milliseconds: 800 + Random().nextInt(400)));
      }
    }

    TrafficLog.add('ST', '[Bedouin] Found ${found.length} camps');
    return found;
  }

  Future<BedouinAttackResult> attack({
    required BedouinCamp camp,
    required OwnedCastle source,
    required int lordId,
    required List<CastleUnit> availableUnits,
    required List<CastleUnit> allUnitsForTools,
    BedouinAttackConfig config = const BedouinAttackConfig(),
    List<Lord>? fallbackLords,
    int? playerLevel,
  }) async {
    if (config.waves < 1 || config.waves > 3) {
      return BedouinAttackResult.fail('INVALID_WAVES');
    }
    if (playerLevel != null && playerLevel > 0) {
      _playerLevel = playerLevel;
    }

    final lordsToTry = <int>[lordId];
    if (fallbackLords != null) {
      for (final l in fallbackLords) {
        if (l.id != lordId && l.id > 0 && !lordsToTry.contains(l.id)) {
          lordsToTry.add(l.id);
        }
      }
    }

    BedouinAttackResult? lastResult;
    for (final lid in lordsToTry) {
      TrafficLog.add('ST',
          '[Bedouin] ⚔️ Try Lord $lid on ${camp.coordsLabel}');

      final result = await _tryAttack(
        camp: camp, source: source, lordId: lid,
        availableUnits: availableUnits,
        allUnitsForTools: allUnitsForTools,
        config: config,
      );

      if (result.success) return result;
      lastResult = result;

      final err = result.error ?? '';
      final isLordIssue = err.contains('256') ||
          err.contains('218') ||
          err.contains('404');
      if (!isLordIssue) break;
    }

    return lastResult ?? BedouinAttackResult.fail('ALL_FAILED');
  }

  Future<BedouinAttackResult> _tryAttack({
    required BedouinCamp camp,
    required OwnedCastle source,
    required int lordId,
    required List<CastleUnit> availableUnits,
    required List<CastleUnit> allUnitsForTools,
    required BedouinAttackConfig config,
  }) async {
    final combat = availableUnits
        .where((u) => u.amount > 0 && _isOffensiveUnit(u))
        .toList();
    if (combat.isEmpty) {
      return BedouinAttackResult.fail('NO_OFFENSIVE_UNITS');
    }

    // ✅✅✅ FIX: نفس صيغة الساموراي (5 * level + 8)
    final lvl = _playerLevel ?? 1;
    final maxAttackers = SamuraiMath.maxAttackers(lvl);
    final flankCount = SamuraiMath.flankMax(lvl);
    final middleCount = SamuraiMath.middleMax(lvl);
    final toolCapL = SamuraiMath.toolCapFlank(lvl);
    final toolCapM = SamuraiMath.toolCapMiddle(lvl);

    TrafficLog.add('ST',
        '[Bedouin] 📐 Lvl=$lvl → max=$maxAttackers '
        '(L/R=$flankCount M=$middleCount) '
        'tools (L/R=$toolCapL M=$toolCapM)');

    final melee = combat.where((u) {
      if (u.info?.role == 'melee') return true;
      if (u.info?.role == 'ranged') return false;
      return u.wodId >= 9 && u.wodId <= 18;
    }).toList()..sort((a, b) => b.amount.compareTo(a.amount));

    final ranged = combat.where((u) {
      if (u.info?.role == 'ranged') return true;
      if (u.info?.role == 'melee') return false;
      return !(u.wodId >= 9 && u.wodId <= 18);
    }).toList()..sort((a, b) => b.amount.compareTo(a.amount));

    final perWaveUnits = maxAttackers;
    final totalAvailable = combat.fold<int>(0, (s, u) => s + u.amount);
    final maxWavesPossible =
        (totalAvailable / perWaveUnits).floor().clamp(1, config.waves);
    final actualWaves = min(config.waves, maxWavesPossible);

    if (actualWaves < config.waves) {
      TrafficLog.add('ST',
          '[Bedouin] ⚠️ Reducing waves ${config.waves} → $actualWaves '
          '(units: $totalAvailable / $perWaveUnits per wave)');
    }

    final remaining = <int, int>{};
    for (final u in combat) remaining[u.wodId] = u.amount;

    final wavesPayload = <Map<String, dynamic>>[];
    int totalSent = 0;
    int toolsUsed = 0;

    for (int w = 0; w < actualWaves; w++) {
      final isFirstWave = (w == 0);
      final flankPool = (isFirstWave || melee.isEmpty) ? ranged : melee;
      final middlePool = ranged.isNotEmpty ? ranged : melee;

      final lU = _fillFromPool(remaining, flankPool, flankCount, 2);
      final rU = _fillFromPool(remaining, flankPool, flankCount, 2);
      final mU = _fillFromPool(remaining, middlePool, middleCount, 6);

      final waveSum = _sum(lU) + _sum(rU) + _sum(mU);
      if (waveSum == 0) break;

      totalSent += waveSum;

      final waveToolId = _getToolIdForWave(w, config);
      final effectiveTool = _resolveTool(
          waveToolId, allUnitsForTools, config);

      List<List<int>> lT2, rT2, mT2;
      if (effectiveTool != null) {
        lT2 = _fillTools(effectiveTool, config.toolL, 2, toolCapL);
        rT2 = _fillTools(effectiveTool, config.toolR, 2, toolCapL);
        mT2 = _fillTools(effectiveTool, config.toolM, 3, toolCapM);
        toolsUsed += _sumTools(lT2) + _sumTools(rT2) + _sumTools(mT2);
      } else {
        lT2 = List.generate(2, (_) => [-1, 0]);
        rT2 = List.generate(2, (_) => [-1, 0]);
        mT2 = List.generate(3, (_) => [-1, 0]);
      }

      wavesPayload.add({
        'L': {'T': lT2, 'U': lU},
        'R': {'T': rT2, 'U': rU},
        'M': {'T': mT2, 'U': mU},
      });
    }

    if (wavesPayload.isEmpty) {
      return BedouinAttackResult.fail('NO_WAVES');
    }

    final usedIds = <int>{};
    for (final w in wavesPayload) {
      for (final wing in ['L', 'R', 'M']) {
        for (final u in (w[wing]['U'] as List)) {
          if ((u as List)[0] > 0) usedIds.add(u[0] as int);
        }
      }
    }
    if (usedIds.length > 10) {
      return BedouinAttackResult.fail('TOO_MANY_UNIT_TYPES');
    }

    try {
      await conn.sendXtAndWait(
        'adi',
        jsonEncode({
          'SX': source.x, 'SY': source.y,
          'TX': camp.x, 'TY': camp.y,
          'KID': camp.kid,
        }),
        responseCmd: 'adi', timeoutMs: 8000, isAction: false,
      );
    } catch (_) {}

    final payload = {
      'SX': source.x, 'SY': source.y,
      'TX': camp.x, 'TY': camp.y,
      'KID': camp.kid, 'LID': lordId,
      'WT': 0, 'HBW': -1, 'BPC': 0, 'ATT': 0, 'AV': 0,
      'LP': 0, 'FC': 0, 'PTT': 1, 'SD': 0, 'ICA': 0, 'CD': 99,
      'A': wavesPayload,
      'BKS': [],
      'AST': [-1, -1, -1],
      'RW': List.generate(8, (_) => [-1, 0]),
      'ASCT': 0,
    };

    await _ensureKingdom(camp.kid);

    try {
      final resp = await conn.sendXtAndWait(
        'cra', jsonEncode(payload),
        responseCmd: 'cra', timeoutMs: 25000, isAction: true,
      );

      if (resp.resultCode == 0) {
        int? mid;
        if (resp.payload != null) {
          try {
            mid = _extractMovementMid(
                jsonDecode(resp.payload!) as Map<String, dynamic>);
          } catch (_) {}
        }
        return BedouinAttackResult.ok(
          mid: mid ?? -1, t: camp,
          units: totalSent, waves: wavesPayload.length,
          tools: toolsUsed,
        );
      }

      final code = resp.resultCode;
      if (code == 91) return BedouinAttackResult.fail('UNIT_NOT_SENDABLE_91');
      if (code == 100) return BedouinAttackResult.fail('CRA_100');
      if (code == 218) return BedouinAttackResult.fail('LORD_BUSY_218');
      if (code == 181) return BedouinAttackResult.fail('MAX_MOVEMENTS_181');
      if (code == 256) return BedouinAttackResult.fail('CRA_256');
      if (code == 313) return BedouinAttackResult.fail('TOO_MANY_UNITS_313');
      return BedouinAttackResult.fail('CRA_$code');
    } catch (e) {
      return BedouinAttackResult.fail('$e');
    }
  }

  int _getToolIdForWave(int waveIndex, BedouinAttackConfig config) {
    switch (waveIndex) {
      case 0: return config.toolIdWave1;
      case 1: return config.toolIdWave2;
      case 2: return config.toolIdWave3;
      default: return config.toolIdWave1;
    }
  }

  int? _resolveTool(
      int preferredId, List<CastleUnit> tools, BedouinAttackConfig config) {
    if (!config.useTools) return null;
    final needed = config.toolL + config.toolM + config.toolR;
    if (needed <= 0) return null;

    final preferredCount = _toolAmountIn(tools, preferredId);
    if (preferredCount >= needed) return preferredId;

    final alternates = <int>[];
    if (preferredId != 1) alternates.add(1);
    if (preferredId != 164) alternates.add(164);
    if (preferredId != 30) alternates.add(30);

    for (final alt in alternates) {
      final altCount = _toolAmountIn(tools, alt);
      if (altCount >= needed) {
        TrafficLog.add('ST',
            '[Bedouin] 🔁 Fallback tool $alt (preferred $preferredId)');
        return alt;
      }
    }

    TrafficLog.add('ST',
        '[Bedouin] 🚫 No tools available → attacking without tools');
    return null;
  }

  int _toolAmountIn(List<CastleUnit> units, int wodId) {
    for (final u in units) {
      if (u.wodId == wodId) return u.amount;
    }
    return 0;
  }

  bool _isOffensiveUnit(CastleUnit u) {
    if (u.info?.fightType != null) {
      return u.info!.fightType == 0;
    }
    return u.info?.role == 'melee' || u.info?.role == 'ranged';
  }

  List<List<int>> _fillFromPool(
    Map<int, int> remaining, List<CastleUnit> pool, int maxTotal, int slots,
  ) {
    final out = <List<int>>[];
    int allocated = 0;
    for (final u in pool) {
      if (allocated >= maxTotal || out.length >= slots) break;
      final rem = remaining[u.wodId] ?? 0;
      if (rem <= 0) continue;
      final take = (maxTotal - allocated).clamp(0, rem);
      if (take <= 0) continue;
      out.add([u.wodId, take]);
      remaining[u.wodId] = rem - take;
      allocated += take;
    }
    while (out.length < slots) out.add([-1, 0]);
    return out;
  }

  List<List<int>> _fillTools(int toolId, int total, int slots, int cap) {
    if (toolId <= 0 || total <= 0) {
      return List.generate(slots, (_) => [-1, 0]);
    }
    final effective = total.clamp(0, cap);
    if (effective <= 0) return List.generate(slots, (_) => [-1, 0]);
    final out = List.generate(slots, (_) => [-1, 0]);
    out[0] = [toolId, effective];
    return out;
  }

  int _sum(List<List<int>> u) =>
      u.fold<int>(0, (s, e) => s + (e[0] > 0 ? e[1] : 0));
  int _sumTools(List<List<int>> u) =>
      u.fold<int>(0, (s, e) => s + (e[0] > 0 ? e[1] : 0));

  int? _extractMovementMid(Map<String, dynamic> data) {
    final m = (data['A'] as Map?)?['M'] as Map?;
    if (m != null) {
      final mid = _asIntOrNull(m['MID']);
      if (mid != null && mid > 0) return mid;
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