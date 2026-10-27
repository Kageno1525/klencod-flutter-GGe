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
    // ═══════════════════════════════════════════════════════════
    // dcl بـ CD:1 بيرجع كل القلاع (بيانات كبيرة ~50KB)
    // isAction=true عشان نطبق throttle قبل cds
    // ═══════════════════════════════════════════════════════════
    TrafficLog.add(
        'ST', '[DCL] Requesting units: KID=$kingdomId areaId=$areaId');
    final resp = await conn.sendXtAndWait(
      'dcl',
      '{"CD":1}',
      responseCmd: 'dcl',
      timeoutMs: 15000,
    );
    if (resp.resultCode != 0) {
      throw Exception('dcl: ${errorName(resp.resultCode)}');
    }
    if (resp.payload == null || resp.payload!.isEmpty) {
      TrafficLog.add('ER', '[DCL] empty payload');
      return [];
    }
    final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
    final castles = (data['C'] as List?) ?? [];

    for (final k in castles) {
      if (k is! Map) continue;
      final kKid = _asInt(k['KID']);
      if (kKid != kingdomId) continue;

      final ais = (k['AI'] as List?) ?? [];
      for (final a in ais) {
        if (a is! Map) continue;
        final aAid = _asInt(a['AID']);
        if (aAid != areaId) continue;

        // ── الوحدات في القلعة الحالية ─────────────────────
        // AC = Army Current (الجيش الفعلي) ✅
        // TU = Training Units (بيتدربوا حالياً)
        // SHI = Stuck Units In (محاصرة)
        // HI = Hospitalized (في المستشفى)
        // مش بنجمعهم — العايزين AC بس للتهريب
        final ac = (a['AC'] as List?) ?? [];
        final out = <CastleUnit>[];
        final seen = <int>{};

        for (final u in ac) {
          if (u is! List || u.length < 2) continue;
          final id = _asInt(u[0]);
          final amt = _asInt(u[1]);
          if (id <= 0 || amt <= 0) continue;

          // لو نفس الوحدة متكررة (نادر بس ممكن)، نجمعهم
          if (seen.contains(id)) {
            final existing = out.firstWhere((x) => x.wodId == id);
            final idx = out.indexOf(existing);
            out[idx] = CastleUnit(
              wodId: id,
              amount: existing.amount + amt,
              info: catalog[id],
            );
          } else {
            seen.add(id);
            out.add(CastleUnit(wodId: id, amount: amt, info: catalog[id]));
          }
        }

        TrafficLog.add(
            'ST', '[DCL] Found ${out.length} unit types at areaId=$areaId');
        return out;
      }
    }

    TrafficLog.add('ER',
        '[DCL] Castle not found: KID=$kingdomId areaId=$areaId (searched ${castles.length} kingdoms)');
    return [];
  }

  static int _asInt(dynamic v, [int def = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }
}