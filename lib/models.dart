import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════
class OwnedCastle {
  final int kingdomId;
  final int areaType;
  final int x, y, areaId;
  final String name;

  OwnedCastle({
    required this.kingdomId,
    required this.areaType,
    required this.x,
    required this.y,
    required this.areaId,
    required this.name,
  });

  String get typeName => switch (areaType) {
        1 => 'Main Castle',
        4 => 'Outpost',
        12 => 'External Kingdom',
        10 => 'Resource Village',
        _ => 'Type $areaType',
      };

  String get kingdomName => switch (kingdomId) {
        0 => 'Great Empire',
        1 => 'Burning Sands',
        2 => 'Everwinter',
        3 => 'Fire Peaks',
        4 => 'Storm Islands',
        _ => 'K$kingdomId',
      };

  String get displayName => name.isNotEmpty ? name : '$typeName ($x,$y)';
  String get fullLabel => '$displayName · $kingdomName';
}

// ═══════════════════════════════════════════
class UnitCatalogEntry {
  final int wodId;
  final String? type;
  final String? role;
  final String? name;
  final int? fightType;

  UnitCatalogEntry({
    required this.wodId,
    this.type,
    this.role,
    this.name,
    this.fightType,
  });

  bool get isCombat => role == 'melee' || role == 'ranged';

  bool get isDefensive {
    final t = type ?? '';
    return t.contains('Def') ||
        t.contains('Militia') ||
        t.contains('Peasant') ||
        t.contains('Anti') ||
        t.contains('Wall') ||
        t.contains('Gate') ||
        t.contains('Moat');
  }

  bool get isTrainable => name == 'Barracks' && isCombat;

  String get displayName {
    final t = (type ?? '').replaceFirst('Barracks_Unit_', '');
    return t.isEmpty ? 'Unit #$wodId' : t;
  }
}

// ═══════════════════════════════════════════
class CastleUnit {
  final int wodId;
  final int amount;
  final UnitCatalogEntry? info;

  CastleUnit({required this.wodId, required this.amount, this.info});

  String get displayName => info?.type ?? 'Unit #$wodId';

  IconData get icon {
    if (info?.role == 'ranged') return Icons.gps_fixed;
    if (info?.role == 'melee') return Icons.gavel;
    return Icons.shield;
  }

  Color get roleColor {
    if (info?.role == 'ranged') return const Color(0xFF06B6D4);
    if (info?.role == 'melee') return const Color(0xFFEF4444);
    return const Color(0xFF90A4AE);
  }

  bool get isCombat => info?.isCombat == true;
  bool get isDefensive => info?.isDefensive == true;
}

// ═══════════════════════════════════════════
class Lord {
  final int id;
  final int visibleIndex;
  final int factionId;
  final String? name;
  final int level;

  Lord({
    required this.id,
    required this.visibleIndex,
    required this.factionId,
    this.name,
    this.level = 1,
  });

  String get displayName =>
      name?.isNotEmpty == true ? name! : 'Lord ${visibleIndex + 1}';
}

// ═══════════════════════════════════════════
class LordMovement {
  final int movementId;
  final int type;
  final int totalTime;
  final int paidTime;
  final int targetX;
  final int targetY;
  final int targetKid;
  final String? targetPlayerName;
  final String? targetAllianceName;

  LordMovement({
    required this.movementId,
    required this.type,
    required this.totalTime,
    required this.paidTime,
    required this.targetX,
    required this.targetY,
    required this.targetKid,
    this.targetPlayerName,
    this.targetAllianceName,
  });

  int get timeRemaining => totalTime - paidTime;

  String get timeLabel {
    if (timeRemaining <= 0) return 'Arrived';
    final h = timeRemaining ~/ 3600;
    final m = (timeRemaining % 3600) ~/ 60;
    final s = timeRemaining % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  String get actionLabel {
    switch (type) {
      case 0:
        return 'Attacking';
      case 1:
        return 'Supporting / Smuggling';
      case 2:
        return 'Returning';
      case 3:
        return 'Transporting';
      default:
        return 'Moving';
    }
  }
}

// ═══════════════════════════════════════════
class CommanderInfo {
  final Lord lord;
  final LordMovement? movement;

  CommanderInfo({required this.lord, this.movement});

  bool get isBusy => movement != null;
}

// ═══════════════════════════════════════════
class XtMessage {
  final String command;
  final int roomId;
  final int resultCode;
  final String? payload;
  final String raw;

  XtMessage(this.command, this.roomId, this.resultCode, this.payload, this.raw);
}

// ═══════════════════════════════════════════
class AllyCastle {
  final int kingdomId;
  final int areaId;
  final int x, y;
  final int areaType;

  AllyCastle({
    required this.kingdomId,
    required this.areaId,
    required this.x,
    required this.y,
    required this.areaType,
  });

  String get kingdomName => switch (kingdomId) {
        0 => 'Great Empire',
        1 => 'Burning Sands',
        2 => 'Everwinter',
        3 => 'Fire Peaks',
        4 => 'Storm Islands',
        _ => 'K$kingdomId',
      };

  String get typeName => switch (areaType) {
        1 => 'Main',
        4 => 'Outpost',
        12 => 'External',
        10 => 'Village',
        _ => 'T$areaType',
      };

  String get displayLabel => '$typeName · $kingdomName ($x,$y)';
}

// ═══════════════════════════════════════════
class AllyMember {
  final int playerId;
  final String name;
  final int level;
  final int peaceTimeSeconds;
  final List<AllyCastle> castles;

  AllyMember({
    required this.playerId,
    required this.name,
    required this.level,
    required this.peaceTimeSeconds,
    required this.castles,
  });

  bool get hasPeace => peaceTimeSeconds > 0;

  String get peaceLabel {
    if (!hasPeace) return 'No peace';
    final s = peaceTimeSeconds;
    final d = s ~/ 86400;
    final h = (s % 86400) ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (d > 0) return '${d}d ${h}h';
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  double closestDistance(int refKid, int refX, int refY) {
    if (castles.isEmpty) return double.infinity;
    double best = double.infinity;
    for (final c in castles) {
      if (c.kingdomId != refKid) continue;
      final dx = (c.x - refX).toDouble();
      final dy = (c.y - refY).toDouble();
      final d = (dx * dx + dy * dy);
      if (d < best) best = d;
    }
    return best == double.infinity ? double.infinity : _sqrt(best);
  }

  static double _sqrt(double x) {
    if (x <= 0) return 0;
    double g = x / 2;
    for (int i = 0; i < 15; i++) {
      g = (g + x / g) / 2;
    }
    return g;
  }

  AllyCastle? castleIn(int kingdomId) {
    try {
      return castles.firstWhere((c) => c.kingdomId == kingdomId);
    } catch (_) {
      return null;
    }
  }
}

// ═══════════════════════════════════════════
//  GGE errors
// ═══════════════════════════════════════════
const Map<int, String> ggeErrors = {
  0: 'Success',
  1: 'General error',
  2: 'Invalid parameter',
  5: 'Invalid object',
  27: 'Account is banned',
  50: 'Wrong mode',
  55: 'Not enough resources',
  88: 'Too much units',
  93: 'Exceeds max count',
  95: 'Cooling down',
  101: 'Missing units',
  108: 'Unknown movement',
  114: 'Alliance not found',
  120: 'Level too low',
  121: 'Travel time too long',
  148: 'Already transferring',
  175: 'Invalid kingdom',
  178: 'Kingdom not available',
  180: 'Max kingdom goods movements',
  181: 'Max kingdom army movements',
  182: 'Kingdom movements not available',
  203: 'Invalid area',
  212: 'Castle has movements',
  219: 'Invalid lord id',
  222: 'Lord in movement',
  233: 'Target not owned',
  256: 'Lord is used',
  404: 'Lord needed',
  409: 'Invalid login token',
  414: 'Minuteskip blocked',
  453: 'Retry wait',
};

String errorName(int code) => ggeErrors[code] ?? 'Error $code';

// ═══════════════════════════════════════════
class AppStorage {
  static const _kUser = 'username';
  static const _kPass = 'password';
  static const _kToken = 'login_token';
  static const _kDark = 'darkMode';
  static const _kLang = 'languageCode';
  static const _kLoggedIn = 'is_logged_in';

  static Future<String?> getUsername() async =>
      (await SharedPreferences.getInstance()).getString(_kUser);
  static Future<void> setUsername(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kUser, v);

  static Future<String?> getPassword() async =>
      (await SharedPreferences.getInstance()).getString(_kPass);
  static Future<void> setPassword(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kPass, v);

  static Future<String?> getToken() async =>
      (await SharedPreferences.getInstance()).getString(_kToken);
  static Future<void> setToken(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kToken, v);

  static Future<bool> getDarkMode() async =>
      (await SharedPreferences.getInstance()).getBool(_kDark) ?? true;
  static Future<void> setDarkMode(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kDark, v);

  static Future<String> getLanguageCode() async =>
      (await SharedPreferences.getInstance()).getString(_kLang) ?? 'ar';
  static Future<void> setLanguageCode(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kLang, v);

  static Future<bool> getLoggedIn() async =>
      (await SharedPreferences.getInstance()).getBool(_kLoggedIn) ?? false;
  static Future<void> setLoggedIn(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kLoggedIn, v);

  static Future<void> clearCredentials() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kUser);
    await p.remove(_kPass);
    await p.remove(_kToken);
    await p.remove(_kLoggedIn);
  }
}

// ═══════════════════════════════════════════════════════════
//  ═══ NEW: Stats + Attack models ═══
// ═══════════════════════════════════════════════════════════
class CastleStats {
  final int areaId;
  final int kingdomId;
  final String? name;
  final int wood, stone, food, coal, oil, glass, iron, honey, mead, aqua;
  final double deltaWood, deltaStone, deltaFood, deltaCoal, deltaOil,
      deltaGlass, deltaIron, deltaHoney, deltaMead, deltaAqua;
  final int maxWood, maxStone, maxFood, maxCoal, maxOil, maxGlass,
      maxIron, maxHoney, maxMead, maxAqua;
  final List<CastleUnit> units;
  final List<CastleUnit> strongholdUnits;
  final List<CastleUnit> hospitalUnits;
  final List<CastleUnit> travelingUnits;
  final int defense;
  final int marketCarriages;
  final bool hasBarracks, hasSiegeWorkshop, hasDefenseWorkshop, hasHospital;

  CastleStats({
    required this.areaId,
    required this.kingdomId,
    this.name,
    required this.wood, required this.stone, required this.food,
    required this.coal, required this.oil, required this.glass,
    required this.iron, required this.honey, required this.mead,
    required this.aqua,
    required this.deltaWood, required this.deltaStone, required this.deltaFood,
    required this.deltaCoal, required this.deltaOil, required this.deltaGlass,
    required this.deltaIron, required this.deltaHoney, required this.deltaMead,
    required this.deltaAqua,
    required this.maxWood, required this.maxStone, required this.maxFood,
    required this.maxCoal, required this.maxOil, required this.maxGlass,
    required this.maxIron, required this.maxHoney, required this.maxMead,
    required this.maxAqua,
    required this.units,
    required this.strongholdUnits,
    required this.hospitalUnits,
    required this.travelingUnits,
    required this.defense,
    required this.marketCarriages,
    required this.hasBarracks,
    required this.hasSiegeWorkshop,
    required this.hasDefenseWorkshop,
    required this.hasHospital,
  });
}

class AttackUnit {
  final int wodId;
  final int amount;
  final String position;
  final String? name;

  AttackUnit({
    required this.wodId,
    required this.amount,
    required this.position,
    this.name,
  });

  String get displayName => name ?? 'Unit #$wodId';
}

class AttackAlert {
  final int movementId;
  final int attackerId;
  final String attackerName;
  final String? attackerAlliance;
  final int targetX, targetY;
  final int kingdomId;
  final int totalTime;
  final int paidTime;
  final List<AttackUnit> units;
  final DateTime receivedAt;

  AttackAlert({
    required this.movementId,
    required this.attackerId,
    required this.attackerName,
    this.attackerAlliance,
    required this.targetX,
    required this.targetY,
    required this.kingdomId,
    required this.totalTime,
    required this.paidTime,
    required this.units,
    required this.receivedAt,
  });

  int get remainingSeconds => (totalTime - paidTime).clamp(0, 999999);
  int get totalUnits => units.fold(0, (s, u) => s + u.amount);

  String get remainingLabel {
    final s = remainingSeconds;
    if (s <= 0) return 'Arrived';
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }

  String get kingdomName => switch (kingdomId) {
        0 => 'Great Empire',
        1 => 'Burning Sands',
        2 => 'Everwinter',
        3 => 'Fire Peaks',
        4 => 'Storm Islands',
        _ => 'K$kingdomId',
      };
}