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
    // ── 1. Validate units ────────────────────────────────────────
    final filtered = <List<int>>[];
    for (final u in units) {
      if (u.length >= 2 && u[1] > 0) filtered.add([u[0], u[1]]);
    }
    if (filtered.isEmpty) return TransferResult.fail('No units selected');

    // ── 2. Cross-kingdom guard (cds same-kingdom only) ───────────
    if (source.kingdomId != target.kingdomId) {
      return TransferResult.fail(
          'CROSS_KINGDOM: source KID=${source.kingdomId}, target KID=${target.kingdomId}');
    }

    // ── 3. Resolve lord ─────────────────────────────────────────
    // ✅ LID=0 = اللورد الرئيسي — يقدر يقود من أي قلعة في أي مملكة
    //    ده اللي بتستخدمه اللعبة نفسها في كل الحركات
    int lid = lordId ?? 0;
    if (lid < 0) lid = 0;

    // ═══════════════════════════════════════════════════════════════
    // ✅ الترتيب الصحيح (زي اللعبة بالظبط):
    //   1) jca — نروح لمملكة المصدر
    //   2) sdi — نحدد المصدر والهدف (إحداثيات)
    //   3) cds — نبعت الجنود
    // ═══════════════════════════════════════════════════════════════
    TrafficLog.add(
        'ST',
        '[SMUGGLE] src KID=${source.kingdomId} areaId=${source.areaId} '
        '(${source.x},${source.y}) → target (${target.x},${target.y}) '
        'KID=${target.kingdomId} LID=$lid WT=$stationTime units=$filtered');

    // ── 4. jca: switch to source kingdom ────────────────────────
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

    // ── 5. sdi: set source & target coords (fire-and-forget) ────
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
      // نكمل برضه — sdi مش حرج جداً لو السيرفر بيستخدم SID في cds
    }

    // ── 6. cds: send troops ─────────────────────────────────────
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

      // Lord-related errors — بس لو LID>0 (commander عادي)
      if ([219, 222, 256, 404].contains(resp.resultCode) && lid != 0) {
        return TransferResult.fail('LORD_UNAVAILABLE');
      }

      // 219 مع LID=0 = مشكلة مؤقتة في السيرفر
      if (resp.resultCode == 219) {
        return TransferResult.fail(
            'Main Lord rejected (LID=0) — retry in a moment');
      }

      // 181 = max movements
      if (resp.resultCode == 181) {
        return TransferResult.fail(
            'Max kingdom army movements reached (181)');
      }

      // 6 = commander not at source castle
      if (resp.resultCode == 6) {
        return TransferResult.fail(
            'Error 6: commander not available at source castle. '
            'Main Lord (LID=0) works from any castle.');
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
      case 181:
        return 'Max kingdom army movements reached';
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