import 'dart:convert';
import '../gge_client.dart';
import '../models.dart';

class CommandersService {
  final GgeClient conn;
  CommandersService(this.conn);

  Future<List<CommanderInfo>> getCommanders() async {
    final lordsResp =
        await conn.sendXtAndWait('gli', '{}', responseCmd: 'gli');
    if (lordsResp.resultCode != 0) return [];

    final decoded = jsonDecode(lordsResp.payload!) as Map<String, dynamic>;
    final lords = <Lord>[];

    // Regular commanders only — Baron removed per user request
    final commanders = (decoded['C'] as List?) ?? [];
    for (final l in commanders) {
      if (l is! Map) continue;
      lords.add(Lord(
        id: _asInt(l['ID']),
        visibleIndex: _asInt(l['VIS']),
        factionId: _asInt(l['FID']),
        name: l['N'] as String?,
      ));
    }

    final gamResp = await conn.sendXtAndWait('gam', '{}', responseCmd: 'gam');
    final movementsMap = <int, LordMovement>{};

    final myPid = conn.cachedPlayerId;
    final fetchedAt = DateTime.now();

    if (gamResp.resultCode == 0 && gamResp.payload != null) {
      final data = jsonDecode(gamResp.payload!) as Map<String, dynamic>;
      final ownersMap = <int, String>{};
      for (final o in (data['O'] as List? ?? [])) {
        ownersMap[_asInt(o['OID'])] = (o['N'] as String?) ?? 'Unknown';
      }

      for (final m in (data['M'] as List? ?? [])) {
        final mov = m['M'] as Map<String, dynamic>?;
        if (mov == null) continue;
        final tt = _asInt(mov['TT']);
        final pt = _asInt(mov['PT']);
        final movType = _asInt(mov['T']);

        // Show T=0 (attack) and T=1 (support/smuggle) always
        // Skip T=2/T=3 only when already arrived (completed)
        if ((movType == 2 || movType == 3) && tt <= pt) continue;

        final ta = mov['TA'] as List?;
        final sa = mov['SA'] as List?;
        if (ta == null || ta.length < 5) continue;
        if (sa == null || sa.length < 5) continue;

        final targetPid = _asInt(ta[4]);
        final sourcePid = _asInt(sa[4]);

        final isOutgoing = myPid != null && sourcePid == myPid;
        final isReturning =
            myPid != null && targetPid == myPid && movType == 2;
        if (!isOutgoing && !isReturning) continue;

        String targetName = (ta[10] as String?) ?? '';
        if (targetName.isEmpty) {
          targetName = ownersMap[targetPid] ?? 'Unknown';
        }

        final um = m['UM'] as Map<String, dynamic>?;
        int? lid = _asIntOrNull((um?['L'] as Map?)?['ID']);
        lid ??= _asIntOrNull(mov['LID']);
        lid ??= _asIntOrNull(m['LID']);

        if (lid != null && lid >= 0) {
          movementsMap[lid] = LordMovement(
            movementId: _asInt(mov['MID']),
            type: movType,
            totalTime: tt,
            paidTime: pt,
            targetX: _asInt(ta[1]),
            targetY: _asInt(ta[2]),
            targetKid: _asInt(mov['KID']),
            targetPlayerName: targetName,
            fetchedAt: fetchedAt,
          );
        }
      }
    }

    final result = <CommanderInfo>[];
    for (final lord in lords) {
      result.add(CommanderInfo(
        lord: lord,
        movement: movementsMap[lord.id],
      ));
    }

    result.sort(
        (a, b) => a.lord.visibleIndex.compareTo(b.lord.visibleIndex));
    return result;
  }

  Future<TransferResult> recall(int movementId) async {
    try {
      await Future.delayed(const Duration(seconds: 2));
      final resp = await conn.sendXtAndWait(
        'mcm',
        jsonEncode({'MID': movementId}),
        responseCmd: 'mcm',
        timeoutMs: 15000,
        isAction: true,
      );
      if (resp.resultCode != 0) {
        return TransferResult.fail(errorName(resp.resultCode));
      }
      return TransferResult.ok();
    } catch (e) {
      return TransferResult.fail('$e');
    }
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