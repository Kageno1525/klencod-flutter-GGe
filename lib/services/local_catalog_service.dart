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

      // ✅ يدعم الشكلين (مفاتيح بسيطة أو مع لاحقة عربية)
      final ra = _readStat(item, 'Ranged Attack', 'Ranged Attack (هجوم عن بعد)');
      final ma = _readStat(item, 'Melee Attack', 'Melee Attack (هجوم قريب)');
      final rd = _readStat(item, 'Ranged Defence', 'Ranged Defence (دفاع عن بعد)');
      final md = _readStat(item, 'Melee Defence', 'Melee Defence (دفاع قريب)');
      final spd = _readStat(item, 'Speed', 'Speed (السرعة)');
      final loot = _readStat(item, 'Loot', 'Loot (الغنيمة)');
      final might = _readStat(item, 'Might', 'Might (البأس)');
      final food = _readStat(item, 'Food', 'Food Consumption (استهلاك الطعام)');

      final url = (item['Image URL'] ?? '').toString();
      final type = _typeFromUrl(url);
      final role = _roleFromStats(ra, ma);
      final fightType = _deriveFightType(ra, ma, rd, md);

      // ✅ يدعم مفتاح الاسم بالعربي أو الإنجليزي
      final rawName =
          (item['Name (الاسم)'] ?? item['Name'] ?? '').toString().trim();
      final level = _extractLevel(rawName, item['Level']);
      final cleanName = rawName
          .replaceAll(RegExp(r'\s*\(Lvl\.\d+\)\s*$'), '')
          .trim();

      out[id] = UnitCatalogEntry(
        wodId: id,
        level: level,
        type: type,
        role: role,
        name: cleanName.isEmpty ? null : cleanName,
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
    TrafficLog.add('ST',
        '[LocalCatalog] Loaded ${out.length} units from assets');

    // ✅ سطر تشخيصي: بيطبع أول جندي مع الإحصائيات
    if (out.isNotEmpty) {
      final first = out.values.first;
      TrafficLog.add('ST',
          '[LocalCatalog] Sample: ${first.displayName} Lv${first.level} '
          'RA=${first.rangedAttack} MA=${first.meleeAttack} '
          'RD=${first.rangedDefence} MD=${first.meleeDefence}');
    }

    return out;
  }

  static void clearCache() => _cache = null;

  static int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  /// ✅ يقرأ قيمة stat بمفتاح إنجليزي بسيط أو عربي
  static int _readStat(Map item, String keyEn, [String? keyAr]) {
    if (item.containsKey(keyEn)) return _i(item[keyEn]);
    if (keyAr != null && item.containsKey(keyAr)) return _i(item[keyAr]);
    return 0;
  }

  static int _extractLevel(String rawName, dynamic levelField) {
    final m = RegExp(r'\(Lvl\.(\d+)\)\s*$').firstMatch(rawName);
    if (m != null) return int.tryParse(m.group(1)!) ?? 0;
    return _i(levelField);
  }

  static String? _typeFromUrl(String url) {
    final m = RegExp(r'/([^/]+)--\d+\.(webp|png)$').firstMatch(url);
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