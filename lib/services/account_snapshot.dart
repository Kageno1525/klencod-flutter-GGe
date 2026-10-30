import 'dart:convert';

// ═══════════════════════════════════════════════════════════
//  account_snapshot.dart
//  بيفكّ رد أمر dcl  (%xt%EmpireEx_34%dcl%1%{"CD":1}%)
//  ويطلّع لكل قلعة: الموارد + كل الجنود/الأدوات (AC) + قائمة TU.
//
//  ملاحظات:
//   • AC = [[wodId, amount], ...]  كل الوحدات والأدوات اللي في القلعة.
//   • الرد بيدّيك ID والعدد بس — مفيهوش (قوة الهجوم / الدفاع / رماية أو اشتباك).
//     دي بتيجي من كتالوج الوحدات (loadCatalog / CastleUnit.info.role).
//   • الموارد بتتسمّى بالترتيب: W خشب · S حجر · F أكل · C فحم · O زيت ·
//     G زجاج · A أكوامارين · I حديد · HONEY عسل · MEAD مشروب العسل · BEEF لحم.
//   • الـ outposts (زي قلعة الصحراء) مش بتظهر في dcl، بس القلاع الرئيسية.
// ═══════════════════════════════════════════════════════════

class AccountCastle {
  final int kid;
  final int areaId;
  final Map<String, double> resources;
  final List<List<int>> items; // AC
  final List<List<int>> tu; // TU

  const AccountCastle({
    required this.kid,
    required this.areaId,
    required this.resources,
    required this.items,
    required this.tu,
  });

  int get itemTypes => items.length;
  int get totalItems => items.fold<int>(0, (s, e) => s + e[1]);

  int countOf(int wodId) {
    int n = 0;
    for (final e in items) {
      if (e[0] == wodId) n += e[1];
    }
    return n;
  }

  Map<String, dynamic> toJson() => {
        'kid': kid,
        'areaId': areaId,
        'resources': resources,
        'items': items,
        'tu': tu,
      };

  static AccountCastle fromJson(Map<String, dynamic> j) => AccountCastle(
        kid: (j['kid'] as num?)?.toInt() ?? 0,
        areaId: (j['areaId'] as num?)?.toInt() ?? 0,
        resources: {
          for (final e in ((j['resources'] as Map?) ?? {}).entries)
            e.key.toString(): (e.value as num?)?.toDouble() ?? 0,
        },
        items: _pairs(j['items']),
        tu: _pairs(j['tu']),
      );

  static List<List<int>> _pairs(dynamic raw) {
    final out = <List<int>>[];
    if (raw is! List) return out;
    for (final e in raw) {
      if (e is! List || e.length < 2) continue;
      final id = (e[0] as num?)?.toInt();
      final amt = (e[1] as num?)?.toInt();
      if (id == null || amt == null) continue;
      out.add([id, amt]);
    }
    return out;
  }
}

class AccountSnapshot {
  final int playerId;
  final DateTime at;
  final List<AccountCastle> castles;

  const AccountSnapshot({
    required this.playerId,
    required this.at,
    required this.castles,
  });

  static const List<String> resourceKeys = [
    'W', 'S', 'F', 'C', 'O', 'G', 'A', 'I', 'HONEY', 'MEAD', 'BEEF',
  ];

  /// مجموع كل وحدة/أداة في كل القلاع.
  Map<int, int> totalItems() {
    final out = <int, int>{};
    for (final c in castles) {
      for (final e in c.items) {
        out[e[0]] = (out[e[0]] ?? 0) + e[1];
      }
    }
    return out;
  }

  AccountCastle? castleByArea(int areaId) {
    for (final c in castles) {
      if (c.areaId == areaId) return c;
    }
    return null;
  }

  String summaryLine() {
    final total = castles.fold<int>(0, (s, c) => s + c.totalItems);
    return '${castles.length} قلعة · ${totalItems().length} نوع وحدة/أداة · $total قطعة';
  }

  Map<String, dynamic> toJson() => {
        'playerId': playerId,
        'at': at.toIso8601String(),
        'castles': castles.map((c) => c.toJson()).toList(),
      };

  static AccountSnapshot? fromJsonString(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return AccountSnapshot(
        playerId: (j['playerId'] as num?)?.toInt() ?? 0,
        at: DateTime.tryParse(j['at']?.toString() ?? '') ?? DateTime.now(),
        castles: ((j['castles'] as List?) ?? [])
            .map((e) => AccountCastle.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  /// payload بتاع رد dcl: {"PID":..., "C":[{"KID":0,"AI":[{...}]}, ...]}
  static AccountSnapshot? parseDcl(String payload) {
    try {
      final data = jsonDecode(payload) as Map;
      final pid = (data['PID'] as num?)?.toInt() ?? 0;
      final kingdoms = data['C'] as List?;
      if (kingdoms == null) return null;

      final castles = <AccountCastle>[];
      for (final k in kingdoms) {
        if (k is! Map) continue;
        final kid = (k['KID'] as num?)?.toInt() ?? 0;
        final ai = k['AI'] as List?;
        if (ai == null) continue;
        for (final c in ai) {
          if (c is! Map) continue;
          final res = <String, double>{};
          for (final key in resourceKeys) {
            final v = c[key];
            if (v is num) res[key] = v.toDouble();
          }
          castles.add(AccountCastle(
            kid: kid,
            areaId: (c['AID'] as num?)?.toInt() ?? 0,
            resources: res,
            items: AccountCastle._pairs(c['AC']),
            tu: AccountCastle._pairs(c['TU']),
          ));
        }
      }
      return AccountSnapshot(playerId: pid, at: DateTime.now(), castles: castles);
    } catch (_) {
      return null;
    }
  }
}
