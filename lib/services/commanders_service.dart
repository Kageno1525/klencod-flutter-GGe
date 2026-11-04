import 'dart:convert';
import '../gge_client.dart';
import '../models.dart';

class CommandersService {
  final GgeClient conn;
  CommandersService(this.conn);

  Future<List<CommanderInfo>> getCommanders() async {
    // ── 1. Get lords list ──────────────────────────────────────
    final lordsResp =
        await conn.sendXtAndWait('gli', '{}', responseCmd: 'gli');
    if (lordsResp.resultCode != 0) return [];

    final decoded = jsonDecode(lordsResp.payload!) as Map<String, dynamic>;
    final lords = <Lord>[];
    final ourLids = <int>{};

    final commanders = (decoded['C'] as List?) ?? [];
    for (final l in commanders) {
      if (l is! Map) continue;
      final lord = Lord(
        id: _asInt(l['ID']),
        visibleIndex: _asInt(l['VIS']),
        factionId: _asInt(l['FID']),
        name: _asString(l['N']),
      );
      lords.add(lord);
      ourLids.add(lord.id);
    }

    // ── 2. Get movements ───────────────────────────────────────
    final gamResp =
        await conn.sendXtAndWait('gam', '{}', responseCmd: 'gam');
    final movementsMap = <int, LordMovement>{};

    final myPid = conn.cachedPlayerId;
    final fetchedAt = DateTime.now();

    if (gamResp.resultCode == 0 && gamResp.payload != null) {
      final data = jsonDecode(gamResp.payload!) as Map<String, dynamic>;

      final ownersMap = <int, String>{};
      for (final o in (data['O'] as List? ?? [])) {
        if (o is Map) {
          ownersMap[_asInt(o['OID'])] = _asString(o['N']) ?? 'Unknown';
        }
      }

      final rawMovements = data['M'] as List? ?? [];
      TrafficLog.add('ST',
          '[Cmd] gam → ${rawMovements.length} movements '
          '(myPid=$myPid, ourLids=${ourLids.toList()})');

      for (final m in rawMovements) {
        if (m is! Map) continue;
        final mov = m['M'] as Map<String, dynamic>?;
        if (mov == null) continue;

        final um = m['UM'] as Map<String, dynamic>?;

        // ── Extract LID ────────────────────────────────────────
        int? lid = _asIntOrNull((um?['L'] as Map?)?['ID']);
        lid ??= _asIntOrNull(mov['LID']);
        lid ??= _asIntOrNull(m['LID']);

        if (lid == null || !ourLids.contains(lid)) continue;

        final tt = _asIntOrNull(mov['TT']);
        final pt = _asIntOrNull(mov['PT']);
        final movType = _asInt(mov['T']);
        final twd = _asIntOrNull(um?['TWD']);
        final pwd = _asIntOrNull(um?['PWD']);
        final mid = _asInt(mov['MID']);

        final ta = mov['TA'] as List?;
        final sa = mov['SA'] as List?;

        // ── Phantom main lord check ────────────────────────────
        if (lid == 0 && sa != null && sa.length > 4 && myPid != null) {
          final sid = _asInt(sa[3]);
          final oid = _asInt(sa[4]);
          if (sid == oid && sid == myPid) {
            TrafficLog.add('ST',
                '[Cmd] MID=$mid LID=0 phantom (sid=$sid==oid==pid) - skip');
            continue;
          }
        }

        // ── Ownership check ────────────────────────────────────
        bool isOurs;
        if (myPid == null) {
          // مفيش player id → نعتمد على LID (بعد ما تأكدنا إنه من قوادنا فوق)
          isOurs = true;
          TrafficLog.add('ST',
              '[Cmd] MID=$mid LID=$lid - myPid null, LID fallback');
        } else if (sa != null &&
            sa.length > 4 &&
            ta != null &&
            ta.length > 4) {
          final sourcePid = _asInt(sa[4]);
          final targetPid = _asInt(ta[4]);
          final isOutgoing = sourcePid == myPid;
          final isReturning = targetPid == myPid && movType == 2;
          isOurs = isOutgoing || isReturning;
        } else {
          // SA/TA قصيرة → نستخدم LID
          isOurs = true;
          TrafficLog.add('ST',
              '[Cmd] MID=$mid LID=$lid - short SA/TA, LID fallback');
        }

        if (!isOurs) {
          TrafficLog.add('ST',
              '[Cmd] MID=$mid LID=$lid type=$movType - not ours, skip');
          continue;
        }

        // ── Done check (ينتبه للحالات الشاذة) ──────────────────
        bool isDone = false;

        if (tt != null && tt > 0 && pt != null && pt >= tt) {
          if (movType == 1) {
            // Support: مش DONE إلا لو TWD ≤ PWD (خلص وقت الدعم)
            if (twd != null && pwd != null) {
              isDone = twd <= pwd;
            } else {
              // مفيش TWD/PWD → نفترض لسه stationed (busy)
              isDone = false;
              TrafficLog.add('ST',
                  '[Cmd] MID=$mid support but TWD/PWD missing → assume busy');
            }
          } else {
            isDone = true;
          }
        }
        // لو TT=0 أو null → نعتبرها busy (منسيبش حركة محتملة)

        TrafficLog.add('ST',
            '[Cmd] MID=$mid LID=$lid type=$movType tt=$tt pt=$pt '
            'twd=$twd pwd=$pwd → ${isDone ? "DONE" : "BUSY"}');

        if (isDone) continue;

        // ── Build movement record ──────────────────────────────
        final targetX = ta != null && ta.length > 1 ? _asInt(ta[1]) : 0;
        final targetY = ta != null && ta.length > 2 ? _asInt(ta[2]) : 0;
        final targetPid = ta != null && ta.length > 4 ? _asInt(ta[4]) : 0;

        String targetName = ta != null && ta.length > 10
            ? (_asString(ta[10]) ?? '')
            : '';
        if (targetName.isEmpty) {
          targetName = ownersMap[targetPid] ?? 'Unknown';
        }

        movementsMap[lid] = LordMovement(
          movementId: mid,
          type: movType,
          totalTime: tt ?? 0,
          paidTime: pt ?? 0,
          targetX: targetX,
          targetY: targetY,
          targetKid: _asInt(mov['KID']),
          targetPlayerName: targetName,
          fetchedAt: fetchedAt,
          stationTotalSeconds: twd,
          stationPaidSeconds: pwd,
        );
      }
    } else {
      TrafficLog.add('ER',
          '[Cmd] gam FAILED: result=${gamResp.resultCode} '
          'payloadNull=${gamResp.payload == null}');
    }

    // ── 3. Build result ────────────────────────────────────────
    final result = <CommanderInfo>[];
    for (final lord in lords) {
      result.add(CommanderInfo(
        lord: lord,
        movement: movementsMap[lord.id],
      ));
    }

    // اللورد الرئيسي (LID=0) الأول
    result.sort((a, b) {
      if (a.lord.id == 0) return -1;
      if (b.lord.id == 0) return 1;
      return a.lord.visibleIndex.compareTo(b.lord.visibleIndex);
    });

    final busyCount = result.where((c) => c.isBusy).length;
    TrafficLog.add('ST',
        '[Cmd] Result: ${result.length} lords, $busyCount busy');

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

  static String? _asString(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    return v.toString();
  }
}