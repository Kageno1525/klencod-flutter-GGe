import 'dart:convert';
import '../gge_client.dart';
import '../models.dart';

class CastleService {
  final GgeClient conn;
  CastleService(this.conn);

  Future<List<OwnedCastle>> getCastles() async {
    final resp = await conn.sendXtAndWait('gcl', '{}', responseCmd: 'gcl');
    if (resp.resultCode != 0) {
      throw Exception('gcl: ${errorName(resp.resultCode)}');
    }
    final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
    final out = <OwnedCastle>[];
    for (final kingdom in data['C'] as List) {
      final kid = _asInt(kingdom['KID']);
      for (final areaObj in kingdom['AI'] as List) {
        final ai = areaObj['AI'] as List;
        String name = '';
        if (ai.length > 10 && ai[10] is String) name = ai[10] as String;
        out.add(OwnedCastle(
          kingdomId: kid,
          areaType: _asInt(ai[0]),
          x: _asInt(ai[1]),
          y: _asInt(ai[2]),
          areaId: _asInt(ai[3]),
          name: name,
        ));
      }
    }
    return out;
  }

  Future<List<CastleUnit>> getCastleUnits(
    int kingdomId,
    int areaId,
    Map<int, UnitCatalogEntry> catalog,
  ) async {
    final resp = await conn.sendXtAndWait('dcl', '{"CD":1}', responseCmd: 'dcl');
    if (resp.resultCode != 0) {
      throw Exception('dcl: ${errorName(resp.resultCode)}');
    }
    final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
    for (final k in (data['C'] as List)) {
      if (_asInt(k['KID']) != kingdomId) continue;
      for (final a in (k['AI'] as List)) {
        if (_asInt(a['AID']) != areaId) continue;
        final ac = (a['AC'] as List?) ?? [];
        final out = <CastleUnit>[];
        for (final u in ac) {
          if (u is! List || u.length < 2) continue;
          final id = _asInt(u[0]);
          final amt = _asInt(u[1]);
          if (amt > 0) {
            out.add(CastleUnit(wodId: id, amount: amt, info: catalog[id]));
          }
        }
        return out;
      }
    }
    return [];
  }

  static int _asInt(dynamic v, [int def = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }
}