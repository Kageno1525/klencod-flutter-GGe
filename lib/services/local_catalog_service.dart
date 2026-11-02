import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models.dart';
import '../gge_client.dart';

class LocalCatalogService {
  static Map<int, UnitCatalogEntry>? _cache;

  static Map<int, UnitCatalogEntry>? get cache => _cache;

  static Future<Map<int, UnitCatalogEntry>> load({bool force = false}) async {
    if (!force && _cache != null) return _cache!;

    final raw = await rootBundle.loadString('assets/data/units.json');
    final list = jsonDecode(raw) as List<dynamic>;
    final out = <int, UnitCatalogEntry>{};

    for (final item in list) {
      if (item is! Map) continue;
      final id = _i(item['ID']);
      if (id <= 0) continue;

      final ra = _i(item['Ranged Attack (هجوم عن بعد)']);
      final ma = _i(item['Melee Attack (هجوم قريب)']);
      final rd = _i(item['Ranged Defence (دفاع عن بعد)']);
      final md = _i(item['Melee Defence (دفاع قريب)']);
      final spd = _i(item['Speed (السرعة)']);
      final loot = _i(item['Loot (الغنيمة)']);
      final might = _i(item['Might (البأس)']);
      final food = _i(item['Food Consumption (استهلاك الطعام)']);

      final url = (item['Image URL'] ?? '').toString();
      final type = _typeFromUrl(url);
      final role = _roleFromStats(ra, ma);
      final fightType = _deriveFightType(ra, ma, rd, md);

      var name = (item['Name (الاسم)'] ?? '').toString().trim();
      name = name.replaceAll(RegExp(r'\s*\(Lvl\.\d+\)\s*$'), '').trim();

      out[id] = UnitCatalogEntry(
        wodId: id,
        type: type,
        role: role,
        name: name.isEmpty ? null : name,
        fightType: fightType,
        imageUrl: url.isEmpty ? null : url,
        rangedAttack: ra,
        meleeAttack: ma,
        rangedDefence: rd,
        meleeDefence: md,
        speed: spd,
        loot: loot,
        might: might,
        food: food,
      );
    }

    _cache = out;
    TrafficLog.add('ST', '[LocalCatalog] Loaded ${out.length} units from assets');
    return out;
  }

  static void clearCache() => _cache = null;

  static int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static String? _typeFromUrl(String url) {
    final m = RegExp(r'/([^/]+)--\d+\.webp$').firstMatch(url);
    return m?.group(1);
  }

  static String? _roleFromStats(int ra, int ma) {
    if (ra > 0 && ma == 0) return 'ranged';
    if (ma > 0 && ra == 0) return 'melee';
    if (ra > 0 && ma > 0) return 'melee';
    return null;
  }

  static int? _deriveFightType(int ra, int ma, int rd, int md) {
    final atk = ra > ma ? ra : ma;
    final def = rd > md ? rd : md;
    final total = atk + def;
    if (total == 0) return null;
    final ratio = atk / total;
    if (ratio >= 0.65) return 0;
    if (ratio <= 0.35) return 1;
    return null;
  }
}