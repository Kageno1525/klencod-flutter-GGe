import 'dart:convert';
import '../gge_client.dart';
import '../models.dart';

class StatsService {
  final GgeClient conn;
  StatsService(this.conn);

  Future<List<CastleStats>> getAllCastleStats({
    Map<int, UnitCatalogEntry>? catalog,
  }) async {
    final resp = await conn.sendXtAndWait('dcl', '{"CD":1}', responseCmd: 'dcl');
    if (resp.resultCode != 0) {
      throw Exception('dcl: ${errorName(resp.resultCode)}');
    }
    final data = jsonDecode(resp.payload!) as Map<String, dynamic>;

    final pid = _asIntOrNull(data['PID']);
    if (pid != null && pid > 0) conn.cachedPlayerId = pid;

    final out = <CastleStats>[];
    for (final k in (data['C'] as List? ?? [])) {
      final kid = _asInt(k['KID']);
      for (final a in (k['AI'] as List? ?? [])) {
        final stats = _parseArea(a, kid, catalog);
        if (stats != null) out.add(stats);
      }
    }
    return out;
  }

  CastleStats? _parseArea(
    dynamic a,
    int kid,
    Map<int, UnitCatalogEntry>? catalog,
  ) {
    if (a is! Map) return null;
    final aid = _asInt(a['AID']);
    if (aid <= 0) return null;

    final gpa = a['gpa'] as Map<String, dynamic>?;

    List<CastleUnit> units(List? raw) {
      final out = <CastleUnit>[];
      for (final u in (raw ?? const [])) {
        if (u is! List || u.length < 2) continue;
        final id = _asInt(u[0]);
        final amt = _asInt(u[1]);
        if (id > 0 && amt > 0) {
          out.add(CastleUnit(wodId: id, amount: amt, info: catalog?[id]));
        }
      }
      return out;
    }

    return CastleStats(
      areaId: aid,
      kingdomId: kid,
      wood: _asInt(a['W']),
      stone: _asInt(a['S']),
      food: _asInt(a['F']),
      coal: _asInt(a['C']),
      oil: _asInt(a['O']),
      glass: _asInt(a['G']),
      iron: _asInt(a['I']),
      honey: _asInt(a['HONEY']),
      mead: _asInt(a['MEAD']),
      aqua: _asInt(a['A']),
      deltaWood: _asNum(gpa?['DW']) / 10,
      deltaStone: _asNum(gpa?['DS']) / 10,
      deltaFood: _asNum(gpa?['DF']) / 10,
      deltaCoal: _asNum(gpa?['DC']) / 10,
      deltaOil: _asNum(gpa?['DO']) / 10,
      deltaGlass: _asNum(gpa?['DG']) / 10,
      deltaIron: _asNum(gpa?['DI']) / 10,
      deltaHoney: _asNum(gpa?['DHONEY']) / 10,
      deltaMead: _asNum(gpa?['DMEAD']) / 10,
      deltaAqua: _asNum(gpa?['DA']) / 10,
      maxWood: _asInt(gpa?['MRF']),
      maxStone: _asInt(gpa?['MRS']),
      maxFood: _asInt(gpa?['MRF']),
      maxCoal: _asInt(gpa?['MRC']),
      maxOil: _asInt(gpa?['MRO']),
      maxGlass: _asInt(gpa?['MRG']),
      maxIron: _asInt(gpa?['MRI']),
      maxHoney: _asInt(gpa?['MRHONEY']),
      maxMead: _asInt(gpa?['MRMEAD']),
      maxAqua: _asInt(gpa?['MRA']),
      units: units(a['AC'] as List?),
      strongholdUnits: units(a['SHI'] as List?),
      hospitalUnits: units(a['HI'] as List?),
      travelingUnits: units(a['TU'] as List?),
      defense: _asInt(a['D']),
      marketCarriages: _asInt(a['MC']),
      hasBarracks: a['B'] == true,
      hasSiegeWorkshop: a['WS'] == true,
      hasDefenseWorkshop: a['DW'] == true,
      hasHospital: a['H'] == true,
    );
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

  static double _asNum(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }
}