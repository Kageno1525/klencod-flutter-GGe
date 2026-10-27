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

    int lid = lordId ?? -1;
    if (lid == -1) {
      final cmds = await commanders.getCommanders();
      final free = cmds.where((c) => !c.isBusy).toList();
      if (free.isEmpty) return TransferResult.fail('ALL_LORDS_BUSY');
      lid = free.first.lord.id;
    }

    // ══════════════════════════════════════════════════════════════
    // ✅ الإصلاح: `sdi` قبل `cds`
    // cds مفيهوش KID، فالسيرفر بيعتمد على الـ current kingdom (غالباً 0).
    // sdi بيقول للسيرفر: "المصدر عند (SX,SY)، الهدف عند (TX,TY)"،
    // فالسيرفر بيلاقي المصدر في مملكته، ويعرف إن الهدف في نفس المملكة.
    // ══════════════════════════════════════════════════════════════
    TrafficLog.add('ST',
        '[SDI] SX=${source.x},SY=${source.y} → TX=${target.x},TY=${target.y} '
        '(srcKID=${source.kingdomId}, tgtKID=${target.kingdomId})');

    _logSdiResponse();

    try {
      conn.sendXt('sdi', jsonEncode({
        'TX': target.x,
        'TY': target.y,
        'SX': source.x,
        'SY': source.y,
      }));
      await Future.delayed(const Duration(milliseconds: 400));
    } catch (e) {
      TrafficLog.add('ER', '[SDI] send failed: $e');
    }

    try {
      TrafficLog.add('ST',
          '[CDS] SID=${source.areaId} TX=${target.x},TY=${target.y} '
          'LID=$lid WT=$stationTime units=${filtered.length}');

      final resp = await conn.sendXtAndWait(
        'cds',
        jsonEncode({
          'SID': source.areaId,
          'TX': target.x, 'TY': target.y,
          'LID': lid, 'WT': stationTime,
          'HBW': -1, 'BPC': 0, 'PTT': 0, 'SD': 0,
          'A': filtered,
        }),
        responseCmd: 'cds',
        timeoutMs: 25000,
        isAction: true,
      );

      TrafficLog.add('ST',
          '[CDS-RESP] result=${resp.resultCode} (${errorName(resp.resultCode)})');

      if (resp.resultCode == 0) return TransferResult.ok();
      if ([222, 256, 404, 219].contains(resp.resultCode)) {
        return TransferResult.fail('ALL_LORDS_BUSY');
      }
      return TransferResult.fail(
          '${errorName(resp.resultCode)} (code ${resp.resultCode})');
    } catch (e) {
      return TransferResult.fail('$e');
    }
  }

  void _logSdiResponse() {
    StreamSubscription? sub;
    Timer? timer;
    sub = conn.rawStream.listen((m) {
      if (m.contains('%sdi%')) {
        TrafficLog.add('ST',
            '[SDI-RESP] ${m.length > 140 ? '${m.substring(0, 140)}…' : m}');
        sub?.cancel();
        timer?.cancel();
      }
    });
    timer = Timer(const Duration(milliseconds: 2500), () {
      sub?.cancel();
    });
  }
}