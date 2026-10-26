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

    try {
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
      if (resp.resultCode == 0) return TransferResult.ok();
      if ([222, 256, 404].contains(resp.resultCode)) {
        return TransferResult.fail('ALL_LORDS_BUSY');
      }
      return TransferResult.fail(errorName(resp.resultCode));
    } catch (e) {
      return TransferResult.fail('$e');
    }
  }
}