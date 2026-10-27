import 'dart:async';
import 'dart:convert';
import '../gge_client.dart';
import '../models.dart';
import 'commanders_service.dart';

class SmuggleService {
  final GgeClient conn;
  final CommandersService commanders;
  SmuggleService(this.conn, this.commanders);

  Future<TransferResult> sendToAlly({
    required OwnedCastle source,
    required AllyCastle target,
    required List<List<int>> units,
    int stationTime = 12,
    int? lordId,
  }) async {
    final filtered = <List<int>>[];
    for (final u in units) {
      if (u.length >= 2 && u[1] > 0) filtered.add([u[0], u[1]]);
    }
    if (filtered.isEmpty) return TransferResult.fail('No units selected');

    if (source.kingdomId != target.kingdomId) {
      return TransferResult.fail(
          'CROSS_KINGDOM: source KID=${source.kingdomId}, target KID=${target.kingdomId}');
    }

    // ✅ LID=0 = اللورد الرئيسي — يقدر يقود من أي قلعة في أي مملكة
    //    لكن لو هو مشغول، السيرفر هيرجع 218. الشاشة مسؤولة تتأكد إنه فاضي قبل الإرسال.
    int lid = lordId ?? 0;
    if (lid < 0) lid = 0;

    TrafficLog.add(
        'ST',
        '[SMUGGLE] src KID=${source.kingdomId} areaId=${source.areaId} '
        '(${source.x},${source.y}) → target (${target.x},${target.y}) '
        'KID=${target.kingdomId} LID=$lid WT=$stationTime units=$filtered');

    // ── 1. jca: switch to source kingdom ────────────────────────
    try {
      TrafficLog.add('ST', '[JCA] → KID=${source.kingdomId}');
      final jcaResp = await conn.sendXtAndWait(
        'jca',
        jsonEncode({'CID': -1, 'KID': source.kingdomId}),
        responseCmd: 'jaa',
        timeoutMs: 8000,
      );
      TrafficLog.add('ST', '[JCA-RESP] result=${jcaResp.resultCode}');

      if (jcaResp.resultCode != 0) {
        return TransferResult.fail(
            'Kingdom switch failed (jca code ${jcaResp.resultCode})');
      }
      await Future.delayed(const Duration(milliseconds: 600));
    } catch (e) {
      TrafficLog.add('ER', '[JCA] failed: $e');
      return TransferResult.fail('Kingdom switch failed: $e');
    }

    // ── 2. sdi: source & target coords (fire-and-forget) ────────
    try {
      TrafficLog.add('ST',
          '[SDI] SX=${source.x},SY=${source.y} → TX=${target.x},TY=${target.y}');
      conn.sendXt(
        'sdi',
        jsonEncode({
          'TX': target.x,
          'TY': target.y,
          'SX': source.x,
          'SY': source.y,
        }),
      );
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      TrafficLog.add('ER', '[SDI] failed: $e');
    }

    // ── 3. cds: send troops ─────────────────────────────────────
    try {
      TrafficLog.add('ST',
          '[CDS] SID=${source.areaId} TX=${target.x},TY=${target.y} '
          'LID=$lid WT=$stationTime A=$filtered');

      final resp = await conn.sendXtAndWait(
        'cds',
        jsonEncode({
          'SID': source.areaId,
          'TX': target.x,
          'TY': target.y,
          'LID': lid,
          'WT': stationTime,
          'HBW': -1,
          'BPC': 0,
          'PTT': 0,
          'SD': 0,
          'A': filtered,
        }),
        responseCmd: 'cds',
        timeoutMs: 25000,
        isAction: true,
      );

      TrafficLog.add('ST',
          '[CDS-RESP] result=${resp.resultCode} (${_cdsErrorMessage(resp.resultCode)})');

      if (resp.resultCode == 0) return TransferResult.ok();

      // ✅ 91: وحدة مش قابلة للإرسال من القلعة المصدر (Defensive/Non-sendable)
      //     معناها: wodId مش موجود في gpc.U[source.areaId]
      //     الشاشة مسؤولة تفلتر الوحدات دي قبل ما توصل هنا، لكن ده defense-in-depth
      if (resp.resultCode == 91) {
        return TransferResult.fail('UNIT_NOT_SENDABLE_91');
      }

      // ✅ 218: اللورد المختار مشغول أو مش متاح (شائع جداً مع LID=0)
      //     الحل: المستخدم يختار لورد فاضي أو يستنى رجوع اللورد الرئيسي
      if (resp.resultCode == 218) {
        return TransferResult.fail('LORD_BUSY_218');
      }

      // لورد unavailable (أي كود تاني من عيلة اللوردات) — لو LID ≠ 0
      if ([219, 222, 256, 404].contains(resp.resultCode) && lid != 0) {
        return TransferResult.fail('LORD_UNAVAILABLE');
      }

      // 219 لو LID=0 — يعني السيرفر رفض اللورد الرئيسي تحديداً
      if (resp.resultCode == 219) {
        return TransferResult.fail(
            'Main Lord rejected (LID=0) — retry in a moment');
      }

      if (resp.resultCode == 181) {
        return TransferResult.fail('Max kingdom army movements reached (181)');
      }

      if (resp.resultCode == 6) {
        return TransferResult.fail(
            'Error 6: commander not at source castle. Use Main Lord (LID=0)');
      }

      return TransferResult.fail(
          'cds error ${resp.resultCode}: ${_cdsErrorMessage(resp.resultCode)}');
    } catch (e) {
      TrafficLog.add('ER', '[CDS] exception: $e');
      return TransferResult.fail('$e');
    }
  }

  String _cdsErrorMessage(int code) {
    switch (code) {
      case 0:
        return 'OK';
      case 6:
        return 'Commander not available at source castle';
      case 7:
        return 'Target not in same kingdom';
      case 13:
        return 'Not enough troops';
      case 91:
        return 'Unit not sendable from this castle (Defensive)';
      case 181:
        return 'Max kingdom army movements reached';
      case 218:
        return 'Lord unavailable (busy)';
      case 219:
        return 'Invalid lord id';
      case 222:
        return 'Lord in movement';
      case 256:
        return 'Lord is used';
      case 404:
        return 'Lord needed';
      default:
        return 'Error $code';
    }
  }
}