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
    int lid = lordId ?? -1;
    if (lid == -1) {
      final cmds = await commanders.getCommanders();
      final free = cmds.where((c) => !c.isBusy).toList();
      if (free.isEmpty) return TransferResult.fail('ALL_LORDS_BUSY');
      lid = free.first.lord.id;
    }

    // ═══════════════════════════════════════════════════════════════
    // ✅ الإصلاح الأساسي:
    //   1) jca قبل cds — نضبط الـ current kingdom على مملكة المصدر
    //   2) شيلنا sdi تماماً — مش أمر حقيقي، السيرفر بيتجاهله
    //   3) لو jca فشل، منبعتش cds أصلاً
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
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      TrafficLog.add('ER', '[JCA] failed: $e');
      return TransferResult.fail('Kingdom switch failed: $e');
    }

    // ── 5. cds: send troops (throttle auto-applied via isAction) ─
    try {
      TrafficLog.add(
          'ST',
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

      TrafficLog.add(
          'ST',
          '[CDS-RESP] result=${resp.resultCode} '
          '(${_cdsErrorMessage(resp.resultCode)})');

      if (resp.resultCode == 0) return TransferResult.ok();

      if ([222, 256, 404, 219].contains(resp.resultCode)) {
        return TransferResult.fail('ALL_LORDS_BUSY');
      }

      if (resp.resultCode == 181) {
        return TransferResult.fail('Max kingdom army movements reached (181)');
      }

      if (resp.resultCode == 6) {
        return TransferResult.fail(
            'Invalid cds request (6): verify source kingdom context, '
            'lord availability at source castle, and target ally castle.');
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
        return 'Invalid request / kingdom or lord mismatch';
      case 7:
        return 'Target not in same kingdom';
      case 13:
        return 'Not enough troops';
      case 181:
        return 'Max kingdom army movements reached';
      case 219:
        return 'Target invalid or not reachable';
      case 222:
        return 'Lord busy';
      case 256:
        return 'Lord busy (garrisoned elsewhere)';
      case 404:
        return 'Not found';
      default:
        return 'Error $code';
    }
  }
}