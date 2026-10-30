import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════
//  attack_planner.dart
//  مخطط الهجوم الذكي — موجة واحدة فقط (جناح يسار / أمام / جناح يمين)
//
//  القيود (من الهجوم اليدوي بتاعك):
//    • الجناح الواحد: أقصى 46 جندي، نوعين بس
//    • الأمام: أقصى 112 جندي، 6 أنواع
//    • wave واحدة
//  كل القيم دي قابلة للتعديل (PlannerConfig) وبتتخزن في SharedPreferences.
// ═══════════════════════════════════════════════════════════

class PlannerConfig {
  int flankCap; // أقصى عدد جنود في الجناح الواحد
  int middleCap; // أقصى عدد جنود في الأمام
  int flankSlots; // عدد أنواع الجنود في الجناح
  int middleSlots; // عدد أنواع الجنود في الأمام
  double margin; // الهدف: قوة الهجوم ÷ قوة الدفاع (مثلاً 1.6 = 60% زيادة)
  double minRatio; // أقل نسبة مقبولة — أقل منها الهجوم بيتلغي
  int minPerWing; // أقل عدد جنود يتبعت لأي جناح فيه مدافعين

  PlannerConfig({
    this.flankCap = 46,
    this.middleCap = 112,
    this.flankSlots = 2,
    this.middleSlots = 6,
    this.margin = 1.6,
    this.minRatio = 1.15,
    this.minPerWing = 8,
  });

  static const _key = 'desert_plan_cfg_v1';

  /// النسخة الحالية المستخدمة في كل الحسابات (sync).
  static PlannerConfig current = PlannerConfig();

  Map<String, dynamic> toJson() => {
        'flankCap': flankCap,
        'middleCap': middleCap,
        'flankSlots': flankSlots,
        'middleSlots': middleSlots,
        'margin': margin,
        'minRatio': minRatio,
        'minPerWing': minPerWing,
      };

  static PlannerConfig fromJson(Map<String, dynamic> j) {
    int i(String k, int d) => (j[k] as num?)?.toInt() ?? d;
    double f(String k, double d) => (j[k] as num?)?.toDouble() ?? d;
    return PlannerConfig(
      flankCap: i('flankCap', 46),
      middleCap: i('middleCap', 112),
      flankSlots: i('flankSlots', 2),
      middleSlots: i('middleSlots', 6),
      margin: f('margin', 1.6),
      minRatio: f('minRatio', 1.15),
      minPerWing: i('minPerWing', 8),
    );
  }

  static Future<PlannerConfig> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        current = fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {}
    return current;
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(toJson()));
    } catch (_) {}
  }

  /// السيرفر رجّع 313 (TOO_MANY_UNITS) → نخفض الحدود اللي اتعلمناها.
  Future<void> learnTooManyUnits({
    required int flankSent,
    required int middleSent,
  }) async {
    if (flankSent > 0) {
      flankCap = max(10, min(flankCap, (flankSent * 0.85).floor()));
    }
    if (middleSent > 0) {
      middleCap = max(20, min(middleCap, (middleSent * 0.85).floor()));
    }
    await save();
  }

  /// رجّع الحدود للقيم الافتراضية (46 / 112).
  static Future<void> reset() async {
    current = PlannerConfig();
    await current.save();
  }
}

// ═══════════════════════════════════════════════════════════
//  قوة الوحدة النسبية.
//  الافتراضي = 1.0 لكل الوحدات (يعني الحساب بالعدد) لأن الداتا اللي
//  جاية من السيرفر (dcl / bsd) فيها ID والعدد بس، من غير attack/defense.
//  لو عايز تضبط وحدة معينة: خزّن JSON في 'desert_unit_power_v1'
//  بالشكل {"9": 1.0, "675": 1.4} وهيتقرا تلقائي.
// ═══════════════════════════════════════════════════════════
class UnitPower {
  static Map<int, double> overrides = {};
  static const _key = 'desert_unit_power_v1';

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw) as Map;
      final out = <int, double>{};
      for (final e in m.entries) {
        final id = int.tryParse(e.key.toString());
        final v = (e.value as num?)?.toDouble();
        if (id != null && v != null && v > 0) out[id] = v;
      }
      overrides = out;
    } catch (_) {}
  }

  static double of(int id) => overrides[id] ?? 1.0;
}

// ═══════════════════════════════════════════════════════════
class PlanUnit {
  final int id;
  final int stock;
  final bool ranged;
  final bool defensive;
  const PlanUnit({
    required this.id,
    required this.stock,
    this.ranged = false,
    this.defensive = false,
  });

  /// الوحدات الدفاعية بتتحسب بنص قوتها عشان تتستخدم آخر حاجة.
  double get power => UnitPower.of(id) * (defensive ? 0.5 : 1.0);
}

class PlanDef {
  final int id; // 0 = مجهول (لما نعرف بس عدد melee/ranged)
  final int count;
  final bool ranged;
  const PlanDef({required this.id, required this.count, this.ranged = false});
}

class AttackPlan {
  final List<List<int>> left;
  final List<List<int>> middle;
  final List<List<int>> right;
  final bool viable; // الهجوم غالباً هينجح
  final bool guaranteed; // كل الأجنحة وصلت الهدف (margin)
  final bool shortOfUnits; // ناقصك جنود (مش البرج اللي قوي)
  final bool overCap; // دفاع البرج أكبر من حد الجناح/الأمام
  final String reason;
  final List<double> ratios; // L, M, R — النسبة بين قوة الهجوم والدفاع

  const AttackPlan({
    required this.left,
    required this.middle,
    required this.right,
    required this.viable,
    required this.guaranteed,
    required this.shortOfUnits,
    required this.overCap,
    required this.reason,
    required this.ratios,
  });

  static int _sum(List<List<int>> l) =>
      l.fold<int>(0, (s, e) => s + (e.length >= 2 ? e[1] : 0));

  int get leftTotal => _sum(left);
  int get middleTotal => _sum(middle);
  int get rightTotal => _sum(right);
  int get total => leftTotal + middleTotal + rightTotal;

  factory AttackPlan.empty(String reason, {bool short = false}) => AttackPlan(
        left: const [],
        middle: const [],
        right: const [],
        viable: false,
        guaranteed: false,
        shortOfUnits: short,
        overCap: false,
        reason: reason,
        ratios: const [0.0, 0.0, 0.0],
      );
}

// ═══════════════════════════════════════════════════════════
class AttackPlanner {
  AttackPlanner._();

  /// defenders = [left, middle, right]
  static AttackPlan plan({
    required List<PlanUnit> stock,
    required List<List<PlanDef>> defenders,
    PlannerConfig? config,
    int maxTypes = 10,
  }) {
    final cfg = config ?? PlannerConfig.current;
    final caps = <int>[cfg.flankCap, cfg.middleCap, cfg.flankCap];
    final slots = <int>[cfg.flankSlots, cfg.middleSlots, cfg.flankSlots];
    const names = ['L', 'M', 'R'];

    final usable = stock.where((u) => u.stock > 0 && u.power > 0).toList();
    if (usable.isEmpty) {
      return AttackPlan.empty('لا توجد وحدات قتالية', short: true);
    }

    // ── قوة الدفاع لكل جناح
    final defCount = List<int>.filled(3, 0);
    final defPower = List<double>.filled(3, 0);
    for (int w = 0; w < 3; w++) {
      if (w >= defenders.length) continue;
      for (final d in defenders[w]) {
        if (d.count <= 0) continue;
        defCount[w] += d.count;
        defPower[w] += d.count * UnitPower.of(d.id);
      }
    }
    if (defCount[0] + defCount[1] + defCount[2] == 0) {
      return AttackPlan.empty('⚠️ الدفاعات صفر — تخطي');
    }

    // ── المطلوب لكل جناح (قوة الدفاع × margin)
    final need = List<double>.generate(3, (w) {
      if (defCount[w] == 0) return 0.0;
      return max(defPower[w] * cfg.margin, cfg.minPerWing.toDouble());
    });

    // ── ترتيب الوحدات: الأقوى الأول، وعند التساوي الأكتر مخزون
    final sorted = [...usable]..sort((a, b) {
        final c = b.power.compareTo(a.power);
        return c != 0 ? c : b.stock.compareTo(a.stock);
      });
    final remaining = <int, int>{for (final u in sorted) u.id: u.stock};
    final usedTypes = <int>{};

    // الجناح الأكبر احتياجاً ياخد الأول
    final order = [0, 1, 2]..sort((a, b) => need[b].compareTo(need[a]));

    final wingUnits = <List<List<int>>>[[], [], []];
    final wingPower = List<double>.filled(3, 0);

    for (final w in order) {
      if (need[w] <= 0) continue;
      double needLeft = need[w];
      int capLeft = caps[w];
      for (final u in sorted) {
        if (needLeft <= 0.0001 || capLeft <= 0) break;
        if (wingUnits[w].length >= slots[w]) break;
        final rem = remaining[u.id] ?? 0;
        if (rem <= 0) continue;
        if (!usedTypes.contains(u.id) && usedTypes.length >= maxTypes) continue;
        final per = u.power;
        final want = max(1, (needLeft / per - 1e-9).ceil());
        final take = min(want, min(rem, capLeft));
        if (take <= 0) continue;
        wingUnits[w].add([u.id, take]);
        remaining[u.id] = rem - take;
        capLeft -= take;
        needLeft -= take * per;
        wingPower[w] += take * per;
        usedTypes.add(u.id);
      }
    }

    // ── التقييم
    final topPower = sorted.first.power;
    bool viable = true;
    bool guaranteed = true;
    bool overCap = false;
    bool short = false;
    final ratios = List<double>.filled(3, 0);

    for (int w = 0; w < 3; w++) {
      if (defCount[w] == 0) {
        ratios[w] = 0;
        continue;
      }
      final r = defPower[w] <= 0 ? 999.0 : wingPower[w] / defPower[w];
      ratios[w] = r;
      if (r < cfg.minRatio) {
        viable = false;
        // أقصى قوة ممكنة بحد الجناح (بأقوى وحدة) — لو أقل من المطلوب يبقى البرج أكبر من الحد
        final bestByCap = caps[w] * topPower;
        if (bestByCap < defPower[w] * cfg.minRatio) {
          overCap = true;
        } else {
          short = true;
        }
      }
      if (r < cfg.margin * 0.98) guaranteed = false;
    }

    final lT = wingUnits[0].fold<int>(0, (s, e) => s + e[1]);
    final mT = wingUnits[1].fold<int>(0, (s, e) => s + e[1]);
    final rT = wingUnits[2].fold<int>(0, (s, e) => s + e[1]);
    final total = lT + mT + rT;

    final ratioTxt = [
      for (int w = 0; w < 3; w++)
        if (defCount[w] > 0) '${names[w]} ${ratios[w].toStringAsFixed(2)}x',
    ].join(' · ');

    String reason;
    if (viable) {
      reason = 'ذكي: $total (L:$lT · M:$mT · R:$rT) — $ratioTxt';
    } else if (overCap) {
      reason = '🚫 دفاع البرج أكبر من حد الجناح/الأمام — $ratioTxt';
    } else {
      reason = '❌ وحداتك مش كفاية — $ratioTxt';
    }

    return AttackPlan(
      left: wingUnits[0],
      middle: wingUnits[1],
      right: wingUnits[2],
      viable: viable,
      guaranteed: viable && guaranteed,
      shortOfUnits: !viable && short && !overCap,
      overCap: !viable && overCap,
      reason: reason,
      ratios: ratios,
    );
  }
}
