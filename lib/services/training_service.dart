import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../gge_client.dart';
import '../models.dart';

// ═══════════════════════════════════════════════════════════
//  MODELS
// ═══════════════════════════════════════════════════════════

/// حالة خانة تدريب واحدة.
class SlotInfo {
  final int rut;
  final int units;
  final int? wodId;
  final DateTime fetchedAt;
  final bool isTraining;

  SlotInfo({
    required this.rut,
    required this.fetchedAt,
    this.isTraining = false,
    this.units = 0,
    this.wodId,
  });

  bool get isLocked => rut == -1;
  bool get isFree => rut == 0 && !isTraining;
  bool get isBusy => rut > 0 || isTraining;

  int get remainingSeconds {
    if (!isBusy) return 0;
    final elapsed = DateTime.now().difference(fetchedAt).inSeconds;
    return (rut - elapsed).clamp(0, 999999);
  }

  String get timeLabel {
    if (isLocked) return 'مقفول';
    if (isFree) return 'متاحة';
    final s = remainingSeconds;
    if (s <= 0) return 'خلص';
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }
}

/// نتيجة parse رد `spl`.
class SlotsResponse {
  final List<SlotInfo> slots;
  final int totalTime;
  SlotsResponse({required this.slots, required this.totalTime});
}

/// إعدادات التدريب التلقائي (نفس prefs keys المستخدمة في BG).
class AutoTrainSettings {
  bool enabled;
  bool triggerOnSlot;
  bool triggerOnTime;
  int timeInterval;
  String timeUnit;
  bool useMaxTotal;
  String maxTotal;
  Map<int, int> selectedAmounts;
  int rotationIndex;
  int totalTrained;

  AutoTrainSettings({
    this.enabled = false,
    this.triggerOnSlot = true,
    this.triggerOnTime = false,
    this.timeInterval = 5,
    this.timeUnit = 'minutes',
    this.useMaxTotal = false,
    this.maxTotal = '1000',
    Map<int, int>? selectedAmounts,
    this.rotationIndex = 0,
    this.totalTrained = 0,
  }) : selectedAmounts = selectedAmounts ?? {};

  static const _kEnabled = 'auto_enabled';
  static const _kTriggerSlot = 'auto_trigger_slot';
  static const _kTriggerTime = 'auto_trigger_time';
  static const _kTimeInterval = 'auto_time_interval';
  static const _kTimeUnit = 'auto_time_unit';
  static const _kUseMaxTotal = 'auto_use_max';
  static const _kMaxTotal = 'auto_max_total';
  static const _kSelected = 'auto_selected_units';
  static const _kRotation = 'auto_rotation_index';
  static const _kTotalTrained = 'auto_total_trained';
  static const _kLastTrainTime = 'auto_last_train_time';
  static const _kTrainArea = 'auto_train_area_id';

  static Future<AutoTrainSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final selected = <int, int>{};
    final raw = p.getString(_kSelected);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((k, v) {
          final id = int.tryParse(k);
          if (id != null && v is num) selected[id] = v.toInt();
        });
      } catch (_) {}
    }

    return AutoTrainSettings(
      enabled: p.getBool(_kEnabled) ?? false,
      triggerOnSlot: p.getBool(_kTriggerSlot) ?? true,
      triggerOnTime: p.getBool(_kTriggerTime) ?? false,
      timeInterval: p.getInt(_kTimeInterval) ?? 5,
      timeUnit: p.getString(_kTimeUnit) ?? 'minutes',
      useMaxTotal: p.getBool(_kUseMaxTotal) ?? false,
      maxTotal: p.getString(_kMaxTotal) ?? '1000',
      selectedAmounts: selected,
      rotationIndex: p.getInt(_kRotation) ?? 0,
      totalTrained: p.getInt(_kTotalTrained) ?? 0,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, enabled);
    await p.setBool(_kTriggerSlot, triggerOnSlot);
    await p.setBool(_kTriggerTime, triggerOnTime);
    await p.setInt(_kTimeInterval, timeInterval);
    await p.setString(_kTimeUnit, timeUnit);
    await p.setBool(_kUseMaxTotal, useMaxTotal);
    await p.setString(_kMaxTotal, maxTotal);
    await p.setString(
      _kSelected,
      jsonEncode(selectedAmounts.map((k, v) => MapEntry(k.toString(), v))),
    );
  }

  Future<void> saveSelection() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kSelected,
      jsonEncode(selectedAmounts.map((k, v) => MapEntry(k.toString(), v))),
    );
  }

  Future<void> saveRotation(int idx, int total) async {
    rotationIndex = idx;
    totalTrained = total;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kRotation, idx);
    await p.setInt(_kTotalTrained, total);
  }

  Future<void> markTrainTime() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLastTrainTime, DateTime.now().toIso8601String());
  }

  Future<void> setTrainArea(int areaId) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kTrainArea, areaId);
  }

  static Future<int?> getTrainArea() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getInt(_kTrainArea);
    if (v != null && v > 0) return v;
    return p.getInt('main_castle_area');
  }

  /// يفحص لو الوقت انتهى للتدريب التالي (بس لو triggerOnTime).
  Future<bool> isTimeTriggered() async {
    if (!triggerOnTime) return false;
    final p = await SharedPreferences.getInstance();
    final last = p.getString(_kLastTrainTime);
    if (last == null) return true;
    try {
      final dt = DateTime.parse(last);
      int sec = timeInterval;
      if (timeUnit == 'minutes') sec *= 60;
      if (timeUnit == 'hours') sec *= 3600;
      return DateTime.now().difference(dt).inSeconds >= sec;
    } catch (_) {
      return true;
    }
  }
}

/// نتيجة تنفيذ محاولة تدريب واحدة.
class AutoTrainResult {
  final bool success;
  final bool skipped;
  final String? error;
  final int? wodId;
  final int? amount;
  final int? nextIndex;

  AutoTrainResult._({
    this.success = false,
    this.skipped = false,
    this.error,
    this.wodId,
    this.amount,
    this.nextIndex,
  });

  factory AutoTrainResult.ok({
    required int wodId,
    required int amount,
    required int nextIndex,
  }) =>
      AutoTrainResult._(
        success: true,
        wodId: wodId,
        amount: amount,
        nextIndex: nextIndex,
      );

  factory AutoTrainResult.skip(String reason) =>
      AutoTrainResult._(skipped: true, error: reason);

  factory AutoTrainResult.fail(String error) =>
      AutoTrainResult._(error: error);
}

// ═══════════════════════════════════════════════════════════
//  SERVICE
// ═══════════════════════════════════════════════════════════

class TrainingService {
  final GgeClient conn;
  TrainingService(this.conn);

  static const int kBarracksMaxLevel = 20;
  static const int kAbsoluteMaxPerBatch = 80;

  // ─── Train (الأمر الأساسي) ──────────────────────────────────
  Future<TransferResult> train({
    required int areaId,
    required int wodId,
    required int amount,
    int lordId = 0,
  }) async {
    try {
      final resp = await conn.sendXtAndWait(
        'bup',
        jsonEncode({
          'LID': lordId,
          'WID': wodId,
          'AMT': amount,
          'PO': -1,
          'PWR': 0,
          'SK': 0,
          'SID': 0,
          'AID': areaId,
        }),
        responseCmd: 'bup',
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

  // ─── Load Slots (parse spl response) ────────────────────────
  Future<SlotsResponse?> loadSlots() async {
    try {
      final resp = await conn.sendXtAndWait(
        'spl',
        jsonEncode({'LID': 0}),
        responseCmd: 'spl',
        timeoutMs: 8000,
        isAction: false,
      );
      if (resp.payload == null || resp.payload!.isEmpty) return null;

      final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
      final spl = data['spl'] ?? data;
      final ps = spl['PS'] as Map?;
      final qs = spl['QS'] as List?;
      final tct = (spl['TCT'] as num?)?.toInt() ?? 0;

      TrafficLog.add('ST',
          '[Slots] PS=${ps?.isNotEmpty == true ? ps : "empty"} TCT=$tct QS=${qs?.length ?? 0}');

      final now = DateTime.now();
      final slots = <SlotInfo>[];

      // PS = slot التدريب النشط (منفصل)
      if (ps != null && ps.isNotEmpty) {
        final rct = (ps['RCT'] as num?)?.toInt() ?? tct;
        final tua = (ps['TUA'] as num?)?.toInt() ?? 0;
        final wid = (ps['WID'] as num?)?.toInt();
        slots.add(SlotInfo(
          rut: rct,
          fetchedAt: now,
          isTraining: true,
          wodId: wid,
          units: tua,
        ));
        TrafficLog.add(
            'ST', '[Slots] PS active: RCT=${rct}s WID=$wid TUA=$tua');
      }

      // QS = الـ 5 خانات (queue/locked/free)
      if (qs != null) {
        for (final q in qs) {
          if (q is! Map) continue;
          final si = q['SI'];
          final rut = (si is Map ? si['RUT'] : null) ?? q['RUT'];
          if (rut is! num) continue;
          slots.add(SlotInfo(
            rut: rut.toInt(),
            fetchedAt: now,
            wodId: (q['WID'] as num?)?.toInt(),
            units: (q['TUA'] as num?)?.toInt() ?? 0,
          ));
        }
      }

      // Fallback: PS فاضي لكن TCT > 0 → علّم أول خانة متاحة كتدريب نشط
      if ((ps == null || ps.isEmpty) && tct > 0) {
        final freeIdx = slots.indexWhere((s) => s.rut == 0);
        if (freeIdx >= 0) {
          final old = slots[freeIdx];
          slots[freeIdx] = SlotInfo(
            rut: tct,
            fetchedAt: now,
            isTraining: true,
            wodId: old.wodId,
            units: old.units,
          );
          TrafficLog.add('ST',
              '[Slots] PS empty but TCT=$tct → marked slot $freeIdx as training');
        }
      }

      return SlotsResponse(slots: slots, totalTime: tct);
    } catch (e) {
      TrafficLog.add('ER', '[Slots] spl error: $e');
      return null;
    }
  }

  // ─── Fetch Barracks Level (jca) ─────────────────────────────
  Future<void> fetchBarracksLevel(OwnedCastle castle) async {
    try {
      await conn.sendXtAndWait(
        'jca',
        jsonEncode({'CID': -1, 'KID': castle.kingdomId}),
        responseCmd: 'jaa',
        timeoutMs: 8000,
        isAction: false,
      );
    } catch (e) {
      TrafficLog.add('ER', 'jca fetch error: $e');
    }
  }

  int? getBarracksLevel(int areaId) => conn.getBarracksLevel(areaId);

  // ─── Max per batch (from barracks) ──────────────────────────
  int getMaxPerBatch(int areaId) {
    final lvl = conn.getBarracksLevel(areaId);
    if (lvl == null || lvl <= 0) return kAbsoluteMaxPerBatch;
    return (lvl * 4).clamp(10, kAbsoluteMaxPerBatch);
  }

  // ─── Trainable Units (per castle) ───────────────────────────
  List<UnitCatalogEntry> getTrainableUnits({
    required OwnedCastle castle,
    required Map<int, UnitCatalogEntry> catalog,
  }) {
    final perArea = conn.getUnlockedForArea(castle.areaId);
    if (perArea.isEmpty) {
      TrafficLog.add('ER',
          '[Train] No unlocked units for area=${castle.areaId} — gpc missing?');
      return [];
    }
    return catalog.values
        .where((u) => u.isTrainable && perArea.contains(u.wodId))
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  // ─── Auto Train — Single Attempt ────────────────────────────
  Future<AutoTrainResult> executeAutoTrain({
    required OwnedCastle castle,
    required AutoTrainSettings settings,
    required Map<int, UnitCatalogEntry> catalog,
  }) async {
    if (settings.selectedAmounts.isEmpty) {
      return AutoTrainResult.skip('No units selected');
    }

    final trainable = getTrainableUnits(castle: castle, catalog: catalog);
    if (trainable.isEmpty) {
      return AutoTrainResult.skip(
          'No trainable units at ${castle.displayName}');
    }

    final trainableIds = trainable.map((u) => u.wodId).toSet();
    final validWods = settings.selectedAmounts.keys
        .where((id) => trainableIds.contains(id))
        .toList();

    if (validWods.isEmpty) {
      return AutoTrainResult.skip('Selected units not available here');
    }

    final idx = settings.rotationIndex % validWods.length;
    final wodId = validWods[idx];
    final amount = settings.selectedAmounts[wodId] ?? 10;
    if (amount <= 0) {
      return AutoTrainResult.skip('Amount is 0 for WID=$wodId');
    }

    final maxB = getMaxPerBatch(castle.areaId);
    final safeAmount = amount.clamp(1, maxB);

    final result = await train(
      areaId: castle.areaId,
      wodId: wodId,
      amount: safeAmount,
    );

    if (result.success) {
      return AutoTrainResult.ok(
        wodId: wodId,
        amount: safeAmount,
        nextIndex: (idx + 1) % validWods.length,
      );
    }
    return AutoTrainResult.fail(result.error ?? 'unknown error');
  }
}