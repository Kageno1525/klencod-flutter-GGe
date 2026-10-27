import 'package:flutter/material.dart';

class S {
  static Locale current = const Locale('ar');
  static bool get isAr => current.languageCode == 'ar';
  static String _(String key) => (_map[isAr ? 'ar' : 'en'] ?? {})[key] ?? key;

  // ═══ Getters ═══
  static String get appName        => _('appName');
  static String get login          => _('login');
  static String get username       => _('username');
  static String get password       => _('password');
  static String get logout         => _('logout');
  static String get connecting     => _('connecting');
  static String get loginSuccess   => _('loginSuccess');
  static String get loginFailed    => _('loginFailed');
  static String get mainTitle      => _('mainTitle');
  static String get transferTroops => _('transferTroops');
  static String get trainTroops    => _('trainTroops');
  static String get smuggleTroops  => _('smuggleTroops');
  static String get commanders     => _('commanders');
  static String get smuggleDesc    => _('smuggleDesc');
  static String get transferDesc   => _('transferDesc');
  static String get trainDesc      => _('trainDesc');
  static String get cmdDesc        => _('cmdDesc');
  static String get settings       => _('settings');
  static String get logoutConfirm  => _('logoutConfirm');
  static String get welcome        => _('welcome');
  static String get from           => _('from');
  static String get to             => _('to');
  static String get units          => _('units');
  static String get selectUnits    => _('selectUnits');
  static String get selectAll      => _('selectAll');
  static String get deselectAll    => _('deselectAll');
  static String get send           => _('send');
  static String get sending        => _('sending');
  static String get transferOk     => _('transferOk');
  static String get transferFail   => _('transferFail');
  static String get noUnitsSelected => _('noUnitsSelected');
  static String get loadingUnits   => _('loadingUnits');
  static String get loadUnits      => _('loadUnits');
  static String get offenseOnly    => _('offenseOnly');
  static String get defenseOnly    => _('defenseOnly');
  static String get allUnits       => _('allUnits');
  static String get total          => _('total');
  static String get available      => _('available');
  static String get amountToSend   => _('amountToSend');
  static String get sameCastleError => _('sameCastleError');
  static String get allianceMembers => _('allianceMembers');
  static String get peaceActive     => _('peaceActive');
  static String get noPeaceActive   => _('noPeaceActive');
  static String get peaceTime       => _('peaceTime');
  static String get distance        => _('distance');
  static String get clicks          => _('clicks');
  static String get selectMember    => _('selectMember');
  static String get memberCastle    => _('memberCastle');
  static String get loadingMembers  => _('loadingMembers');
  static String get noAllianceMembers => _('noAllianceMembers');
  static String get peaceOnly       => _('peaceOnly');
  static String get allMembers      => _('allMembers');
  static String get sendTo          => _('sendTo');
  static String get notInAlliance   => _('notInAlliance');
  static String get maxMovements    => _('maxMovements');
  static String get allLordsBusy    => _('allLordsBusy');
  static String get stationTime     => _('stationTime');
  static String get selectLord      => _('selectLord');
  static String get autoLord        => _('autoLord');
  static String get commanderBusy   => _('commanderBusy');
  static String get commanderFree   => _('commanderFree');
  static String get timeRemaining   => _('timeRemaining');
  static String get recall          => _('recall');
  static String get recallSuccess   => _('recallSuccess');
  static String get recallFail      => _('recallFail');
  static String get noCommanders    => _('noCommanders');
  static String get selectCastle   => _('selectCastle');
  static String get unitType       => _('unitType');
  static String get amount         => _('amount');
  static String get startTraining  => _('startTraining');
  static String get trainingOk     => _('trainingOk');
  static String get trainingFail   => _('trainingFail');
  static String get statsTitle              => _('statsTitle');
  static String get statsDesc               => _('statsDesc');
  static String get notificationsTitle      => _('notificationsTitle');
  static String get notificationsDesc       => _('notificationsDesc');
  static String get notificationsEnabled    => _('notificationsEnabled');
  static String get notificationsEnabledDesc => _('notificationsEnabledDesc');
  static String get soundAlert              => _('soundAlert');
  static String get soundAlertDesc          => _('soundAlertDesc');
  static String get noAlerts                => _('noAlerts');
  static String get noAlertsDesc            => _('noAlertsDesc');
  static String get noCastles               => _('noCastles');
  static String get delete                  => _('delete');
  static String get details                 => _('details');
  static String get deleteAll               => _('deleteAll');
  static String get deleteAlertConfirm      => _('deleteAlertConfirm');
  static String get allianceAttacks         => _('allianceAttacks');
  static String get allianceAttacksDesc     => _('allianceAttacksDesc');
  static String get attackerCastle          => _('attackerCastle');
  static String get targetCastle            => _('targetCastle');
  static String get attackingUnits          => _('attackingUnits');
  static String get defenseUnits            => _('defenseUnits');
  static String get defenseInfo             => _('defenseInfo');
  static String get defenseNotAvailable     => _('defenseNotAvailable');
  static String get defenseStat             => _('defenseStat');
  static String get perHour                 => _('perHour');
  static String get allianceMember          => _('allianceMember');
  static String get cancel   => _('cancel');
  static String get ok       => _('ok');
  static String get close    => _('close');
  static String get error    => _('error');
  static String get retry    => _('retry');
  static String get language => _('language');
  static String get none     => _('none');
  static String get refresh  => _('refresh');

  // ═══════════════════════════════════════════════════════
  //  Unit name translation — Smart Parser + Full Map
  // ═══════════════════════════════════════════════════════
  static String unitName(String? englishName) {
    if (englishName == null || englishName.isEmpty) {
      return isAr ? 'جندي مجهول' : 'Unknown unit';
    }
    if (!isAr) return englishName;

    // 1. Clean name
    final cleaned = englishName
        .replaceAll('Barracks_Unit_', '')
        .replaceAll('_', '')
        .trim();

    // 2. Exact match
    if (_unitAr.containsKey(cleaned)) return _unitAr[cleaned]!;

    // 3. Lowercase match
    final lower = cleaned.toLowerCase();
    if (_unitAr.containsKey(lower)) return _unitAr[lower]!;

    // 4. Typos (server-side spelling bugs)
    final fixed = lower
        .replaceAll('speerman', 'spearman')
        .replaceAll('swordman', 'swordsman')
        .replaceAll('halberdier', 'halberd')
        .replaceAll('crossbowmann', 'crossbowman');

    if (_unitAr.containsKey(fixed)) return _unitAr[fixed]!;

    // 5. Strip prefixes and rebuild
    String prefixAr = '';
    String base = fixed;
    
    final prefixes = <String, String>{
      'elite': 'نخبة',
      'veteran': 'محترف',
      'relic': 'أثري',
      'kings': 'ملكي',
      'royal': 'ملكي',
      'heavy': 'ثقيل',
      'imperial': 'إمبراطوري',
      'travelling': 'مسافر',
    };
    
    for (final entry in prefixes.entries) {
      if (base.startsWith(entry.key)) {
        prefixAr = '$prefixAr ${entry.value}';
        base = base.substring(entry.key.length);
      }
    }

    // 6. Try matching the base after prefix removal
    if (_unitAr.containsKey(base)) {
      return '${_unitAr[base]}$prefixAr'.trim();
    }

    // 7. Try keyword matching (last resort)
    if (base.contains('crossbow')) return 'قوس مستعرض$prefixAr'.trim();
    if (base.contains('longbow')) return 'قوس طويل$prefixAr'.trim();
    if (base.contains('shortbow')) return 'نشاب قصير$prefixAr'.trim();
    if (base.contains('bow')) return 'نشاب$prefixAr'.trim();
    if (base.contains('spear')) return 'رمح$prefixAr'.trim();
    if (base.contains('sword')) return 'سياف$prefixAr'.trim();
    if (base.contains('mace')) return 'صولجان$prefixAr'.trim();
    if (base.contains('halberd')) return 'هالبرد$prefixAr'.trim();
    if (base.contains('axe')) return 'فأس$prefixAr'.trim();
    if (base.contains('knight')) return 'فارس$prefixAr'.trim();
    if (base.contains('maiden')) return 'عذراء$prefixAr'.trim();
    if (base.contains('ranger')) return 'حارسة$prefixAr'.trim();
    if (base.contains('archer')) return 'رامي$prefixAr'.trim();

    // 8. Fallback
    return englishName;
  }

  static const Map<String, String> _unitAr = {
    // ═══ CORE BARRACKS · MELEE ═══
    'Maceman': 'صولجان', 'maceman': 'صولجان', 'Mace': 'صولجان', 'mace': 'صولجان',
    'Swordsman': 'سياف', 'swordsman': 'سياف', 'Swordman': 'سياف', 'swordman': 'سياف',
    'Spearman': 'رمح', 'spearman': 'رمح', 'Speerman': 'رمح', 'speerman': 'رمح',
    'Halberdier': 'هالبرد', 'halberdier': 'هالبرد', 'Halberd': 'هالبرد', 'halberd': 'هالبرد',
    'Axeman': 'فأس', 'axeman': 'فأس', 'Axe': 'فأس', 'axe': 'فأس',
    'Pikeman': 'رمح طويل', 'pikeman': 'رمح طويل',
    'TwoHandedSwordWarrior': 'سياف بيدين', 'twohandedswordwarrior': 'سياف بيدين',
    'TwoHandedSwordsman': 'سياف بيدين', 'twohandedswordsman': 'سياف بيدين',
    'TwoHandedSword': 'سياف بيدين', 'twohandedsword': 'سياف بيدين',

    // ═══ CORE BARRACKS · RANGED ═══
    'Bowman': 'نشاب', 'bowman': 'نشاب',
    'Crossbowman': 'قوس مستعرض', 'crossbowman': 'قوس مستعرض',
    'Longbowman': 'قوس طويل', 'longbowman': 'قوس طويل',
    'Archer': 'رامي', 'archer': 'رامي',
    'Shortbowman': 'نشاب قصير', 'shortbowman': 'نشاب قصير',
    'CavalryArcher': 'فارس رامي', 'cavalryarcher': 'فارس رامي',

    // ═══ HEAVY VARIANTS ═══
    'HeavyCrossbowman': 'قوس مستعرض ثقيل', 'heavycrossbowman': 'قوس مستعرض ثقيل',
    'HeavySpearman': 'رمح ثقيل', 'heavyspearman': 'رمح ثقيل',
    'HeavySwordsman': 'سياف ثقيل', 'heavyswordsman': 'سياف ثقيل',
    'HeavyHalberdier': 'هالبرد ثقيل', 'heavyhalberdier': 'هالبرد ثقيل',
    'HeavyMaceman': 'صولجان ثقيل', 'heavymaceman': 'صولجان ثقيل',
    'HeavyAxeman': 'فأس ثقيل', 'heavyaxeman': 'فأس ثقيل',
    'HeavyLongbowman': 'قوس طويل ثقيل', 'heavylongbowman': 'قوس طويل ثقيل',
    'HeavyArcher': 'رامي ثقيل', 'heavyarcher': 'رامي ثقيل',

    // ═══ DEFENSE ═══
    'Militia': 'ميليشيا', 'militia': 'ميليشيا',
    'ArmedCitizen': 'مواطن مسلح', 'armedcitizen': 'مواطن مسلح',
    'Peasant': 'فلاح', 'peasant': 'فلاح',
    'WallArcher': 'رامي سور', 'wallarcher': 'رامي سور',
    'WallCrossbowman': 'قوس سور', 'wallcrossbowman': 'قوس سور',
    'WallSpearman': 'رمح سور', 'wallspearman': 'رمح سور',
    'WallSwordsman': 'سياف سور', 'wallswordsman': 'سياف سور',
    'WallMaceman': 'صولجان سور', 'wallmaceman': 'صولجان سور',
    'WallSpadesman': 'مهندس سور', 'wallspadesman': 'مهندس سور',
    'WallHalberdier': 'هالبرد سور', 'wallhalberdier': 'هالبرد سور',
    'MoatDefender': 'مدافع خندق', 'moatdefender': 'مدافع خندق',
    'MoatSpearman': 'رمح خندق', 'moatspearman': 'رمح خندق',
    'MoatCrossbowman': 'قوس خندق', 'moatcrossbowman': 'قوس خندق',
    'MoatArcher': 'رامي خندق', 'moatarcher': 'رامي خندق',
    'GateDefender': 'مدافع بوابة', 'gatedefender': 'مدافع بوابة',
    'GateSpearman': 'رمح بوابة', 'gatespearman': 'رمح بوابة',
    'GateSwordsman': 'سياف بوابة', 'gateswordsman': 'سياف بوابة',
    'GateSpadesman': 'مهندس بوابة', 'gatespadesman': 'مهندس بوابة',
    'GateCrossbowman': 'قوس بوابة', 'gatecrossbowman': 'قوس بوابة',
    'GateArcher': 'رامي بوابة', 'gatearcher': 'رامي بوابة',

    // ═══ RELIC ═══
    'RelicAxeman': 'فأس أثري', 'relicaxeman': 'فأس أثري',
    'RelicShortbowman': 'نشاب قصير أثري', 'relicshortbowman': 'نشاب قصير أثري',
    'RelicHammerman': 'مطرقة أثرية', 'relichammerman': 'مطرقة أثرية',
    'RelicLongbowman': 'قوس طويل أثري', 'reliclongbowman': 'قوس طويل أثري',
    'RelicSpearman': 'رمح أثري', 'relicspearman': 'رمح أثري',
    'RelicMaceman': 'صولجان أثري', 'relicmaceman': 'صولجان أثري',

    // ═══ ROYAL ═══
    'RoyalKnight': 'فارس ملكي', 'royalknight': 'فارس ملكي',
    'RoyalCrossbowman': 'قوس ملكي', 'royalcrossbowman': 'قوس ملكي',
    'RoyalSentinel': 'حارس ملكي', 'royalsentinel': 'حارس ملكي',
    'RoyalScout': 'مستكشف ملكي', 'royalscout': 'مستكشف ملكي',
    'RoyalBowman': 'نشاب ملكي', 'royalbowman': 'نشاب ملكي',
    'RoyalSpearman': 'رمح ملكي', 'royalspearman': 'رمح ملكي',

    // ═══ KINGS (specific server prefix) ═══
    'KingsCrossbowman': 'قوس ملكي', 'kingscrossbowman': 'قوس ملكي',
    'KingsMace': 'صولجان ملكي', 'kingsmace': 'صولجان ملكي',
    'KingsMaceman': 'صولجان ملكي', 'kingsmaceman': 'صولجان ملكي',
    'KingsKnight': 'فارس ملكي', 'kingsknight': 'فارس ملكي',

    // ═══ ELITE ═══
    'EliteKnight': 'فارس نخبة', 'eliteknight': 'فارس نخبة',
    'EliteCrossbowman': 'قوس نخبة', 'elitecrossbowman': 'قوس نخبة',
    'EliteBowman': 'نشاب نخبة', 'elitebowman': 'نشاب نخبة',
    'EliteHalberd': 'هالبرد نخبة', 'elitehalberd': 'هالبرد نخبة',
    'EliteHalberdier': 'هالبرد نخبة', 'elitehalberdier': 'هالبرد نخبة',
    'EliteSpearman': 'رمح نخبة', 'elitespearman': 'رمح نخبة',
    'EliteSpeerman': 'رمح نخبة', 'elitespeerman': 'رمح نخبة',
    'EliteSwordsman': 'سياف نخبة', 'eliteswordsman': 'سياف نخبة',
    'EliteSwordman': 'سياف نخبة', 'eliteswordman': 'سياف نخبة',
    'EliteMace': 'صولجان نخبة', 'elitemace': 'صولجان نخبة',
    'EliteMaceman': 'صولجان نخبة', 'elitemaceman': 'صولجان نخبة',
    'EliteTwoHandedSword': 'سياف بيدين نخبة', 'elitetwohandedsword': 'سياف بيدين نخبة',
    'EliteTwoHandedSwordsman': 'سياف بيدين نخبة', 'elitetwohandedswordsman': 'سياف بيدين نخبة',
    'EliteHeavyCrossbowman': 'قوس ثقيل نخبة', 'eliteheavycrossbowman': 'قوس ثقيل نخبة',
    'EliteKingsCrossbowman': 'قوس ملكي نخبة', 'elitekingscrossbowman': 'قوس ملكي نخبة',
    'EliteKingsMace': 'صولجان ملكي نخبة', 'elitekingsmace': 'صولجان ملكي نخبة',
    'EliteHeavyHalberdier': 'هالبرد ثقيل نخبة', 'eliteheavyhalberdier': 'هالبرد ثقيل نخبة',

    // ═══ TRAVELLING ═══
    'TravellingKnight': 'فارس مسافر', 'travellingknight': 'فارس مسافر',
    'TravellingCrossbowman': 'قوس مسافر', 'travellingcrossbowman': 'قوس مسافر',

    // ═══ IMPERIAL ═══
    'ImperialKnight': 'فارس إمبراطوري', 'imperialknight': 'فارس إمبراطوري',
    'ImperialMarksman': 'قناص إمبراطوري', 'imperialmarksman': 'قناص إمبراطوري',
    'ImperialGuardsman': 'حارس إمبراطوري', 'imperialguardsman': 'حارس إمبراطوري',
    'ImperialBowman': 'نشاب إمبراطوري', 'imperialbowman': 'نشاب إمبراطوري',
    'ImperialSpearman': 'رمح إمبراطوري', 'imperialspearman': 'رمح إمبراطوري',
    'ImperialSwordsman': 'سياف إمبراطوري', 'imperialswordsman': 'سياف إمبراطوري',

    // ═══ KHAN / NOMAD EVENT ═══
    'KhanGuards': 'حراس الخان', 'khanguards': 'حراس الخان',
    'SaberCleaver': 'قطاع السيف', 'sabercleaver': 'قطاع السيف',
    'Slingshot': 'مقذاف', 'slingshot': 'مقذاف',
    'VeteranSaberCleaver': 'قطاع السيف محترف', 'veteransabercleaver': 'قطاع السيف محترف',
    'VeteranSlingshot': 'مقذاف محترف', 'veteranslingshot': 'مقذاف محترف',
    'RenegadeLancer': 'رماح مارق', 'renegadelancer': 'رماح مارق',
    'RenegadeSpearThrower': 'رامي رماح مارق', 'renegadespearthrower': 'رامي رماح مارق',

    // ═══ SAMURAI EVENT ═══
    'RenegadeSaiWarrior': 'محارب ساي مارق', 'renegadesaiwarrior': 'محارب ساي مارق',
    'RenegadeKunaiThrower': 'رامي كوناي مارق', 'renegadekunaithrower': 'رامي كوناي مارق',
    'RenegadeKatanaWarrior': 'محارب كاتانا مارق', 'renegadekatanawarrior': 'محارب كاتانا مارق',
    'RenegadeBowMaster': 'سيد القوس مارق', 'renegadebowmaster': 'سيد القوس مارق',

    // ═══ SHADOW MERCENARIES ═══
    'ShadowMaceman': 'صولجان الظل', 'shadowmaceman': 'صولجان الظل',
    'ShadowCrossbowman': 'قوس الظل', 'shadowcrossbowman': 'قوس الظل',
    'ShadowRogue': 'مارق الظل', 'shadowrogue': 'مارق الظل',
    'ShadowFelon': 'مجرم الظل', 'shadowfelon': 'مجرم الظل',
    'ShadowScoundrel': 'وغد الظل', 'shadowscoundrel': 'وغد الظل',
    'ShadowWretch': 'خسيس الظل', 'shadowwretch': 'خسيس الظل',
    'DemonShadow': 'ظل شيطاني', 'demonshadow': 'ظل شيطاني',
    'DeathlyShadow': 'ظل مميت', 'deathlyshadow': 'ظل مميت',

    // ═══ HORROR (Fire Peaks) ═══
    'DemonHorror': 'رعب شيطاني', 'demonhorror': 'رعب شيطاني',
    'DeathlyHorror': 'رعب مميت', 'deathlyhorror': 'رعب مميت',
    'VeteranDemonHorror': 'رعب شيطاني محترف', 'veterandemonhorror': 'رعب شيطاني محترف',
    'VeteranDeathlyHorror': 'رعب مميت محترف', 'veterandeathlyhorror': 'رعب مميت محترف',

    // ═══ STORM ISLANDS ═══
    'RenegadeStoneSmasher': 'ساحق الحجر مارق', 'renegadestonesmasher': 'ساحق الحجر مارق',
    'RenegadeSharkToothWarrior': 'محارب سن القرش مارق', 'renegadesharktoothwarrior': 'محارب سن القرش مارق',
    'RenegadeSailRipper': 'ممزق الشراع مارق', 'renegadesailripper': 'ممزق الشراع مارق',
    'RenegadeSwashbuckler': 'مبارز مارق', 'renegadeswashbuckler': 'مبارز مارق',

    // ═══ EVERWINTER GLACIER ═══
    'RenegadeNorsemanWarrior': 'محارب نورسمان مارق', 'renegadenorsemanwarrior': 'محارب نورسمان مارق',
    'RenegadeNorsemanBowman': 'نشاب نورسمان مارق', 'renegadenorsemanbowman': 'نشاب نورسمان مارق',
    'Barbarian': 'بربري', 'barbarian': 'بربري',
    'Wolfhound': 'كلب ذئب', 'wolfhound': 'كلب ذئب',

    // ═══ BURNING SANDS ═══
    'RenegadeSaberWarrior': 'محارب سيف مارق', 'renegadesaberwarrior': 'محارب سيف مارق',
    'RenegadeDesertBowman': 'نشاب صحراوي مارق', 'renegadedesertbowman': 'نشاب صحراوي مارق',
    'RenegadeCultistWarrior': 'محارب طائفي مارق', 'renegadecultistwarrior': 'محارب طائفي مارق',
    'RenegadeCultistBowman': 'نشاب طائفي مارق', 'renegadecultistbowman': 'نشاب طائفي مارق',
    'FlameBearer': 'حامل الشعلة', 'flamebearer': 'حامل الشعلة',
    'VeteranFlameBearer': 'حامل الشعلة محترف', 'veteranflamebearer': 'حامل الشعلة محترف',
    'CompositeBowman': 'نشاب مركب', 'compositebowman': 'نشاب مركب',
    'VeteranCompositeBowman': 'نشاب مركب محترف', 'veterancompositebowman': 'نشاب مركب محترف',

    // ═══ BERIMOND ═══
    'Marksman': 'قناص', 'marksman': 'قناص',
    'MuscleMan': 'رجل العضلات', 'muscleman': 'رجل العضلات',
    'LionWarrior': 'محارب الأسد', 'lionwarrior': 'محارب الأسد',
    'BearWarrior': 'محارب الدب', 'bearwarrior': 'محارب الدب',
    'LionBowman': 'نشاب الأسد', 'lionbowman': 'نشاب الأسد',
    'BearBowman': 'نشاب الدب', 'bearbowman': 'نشاب الدب',

    // ═══ SOVEREIGN (Hall of Legends) ═══
    'ShieldMaiden': 'عذراء الدرع', 'shieldmaiden': 'عذراء الدرع',
    'ValkyrieRanger': 'فارسة فالكيري', 'valkyrieranger': 'فارسة فالكيري',
    'ProtectorOfTheNorth': 'حامي الشمال', 'protectorofthenorth': 'حامي الشمال',
    'ValkyrieSniper': 'قناصة فالكيري', 'valkyriesniper': 'قناصة فالكيري',

    // ═══ SOVEREIGN EVENT EDITIONS ═══
    'ForsakenMaiden': 'عذراء مهجورة', 'forsakenmaiden': 'عذراء مهجورة',
    'ForlornRanger': 'حارسة منبوذة', 'forlornranger': 'حارسة منبوذة',
    'CandyCaneProtector': 'حامي عصا الحلوى', 'candycaneprotector': 'حامي عصا الحلوى',
    'JollyGingerbreadSniper': 'قناص الزنجبيل المرح', 'jollygingerbreadsniper': 'قناص الزنجبيل المرح',
    'EasterChampioness': 'بطلة الفصح', 'easterchampioness': 'بطلة الفصح',
    'ValkyrieHuntress': 'صيادة فالكيري', 'valkyriehuntress': 'صيادة فالكيري',
    'GuardianOfSpring': 'حامي الربيع', 'guardianofspring': 'حامي الربيع',
    'CelestialMarksman': 'قناص سماوي', 'celestialmarksman': 'قناص سماوي',
    'FruitPirate': 'قرصان الفواكه', 'fruitpirate': 'قرصان الفواكه',
    'SummerHuntress': 'صيادة الصيف', 'summerhuntress': 'صيادة الصيف',
    'FruitBreaker': 'كاسر الفواكه', 'fruitbreaker': 'كاسر الفواكه',
    'SummerMarksman': 'قناص الصيف', 'summermarksman': 'قناص الصيف',
    'SteinSmasher': 'ساحق الكوب', 'steinsmasher': 'ساحق الكوب',
    'CaskMarksmann': 'قناص البرميل', 'caskmarksmann': 'قناص البرميل',
    'PretzelGuardian': 'حامي البريتزل', 'pretzelguardian': 'حامي البريتزل',
    'BavarianBrewer': 'صانع جعة بافاري', 'bavarianbrewer': 'صانع جعة بافاري',
    'GlacialAmazonWarrior': 'محاربة أمازونية جليدية', 'glacialamazonwarrior': 'محاربة أمازونية جليدية',
    'GlacialAmazonArcher': 'رامية أمازونية جليدية', 'glacialamazonarcher': 'رامية أمازونية جليدية',
    'GlacialAmazonGuardian': 'حامية أمازونية جليدية', 'glacialamazonguardian': 'حامية أمازونية جليدية',
    'GlacialAmazonHuntress': 'صيادة أمازونية جليدية', 'glacialamazonhuntress': 'صيادة أمازونية جليدية',
    'ChristmasWarrior': 'محارب الكريسماس', 'christmaswarrior': 'محارب الكريسماس',
    'ChristmasArcher': 'رامي الكريسماس', 'christmasarcher': 'رامي الكريسماس',
    'ChristmasGuardian': 'حامي الكريسماس', 'christmasguardian': 'حامي الكريسماس',
    'ChristmasHuntress': 'صيادة الكريسماس', 'christmashuntress': 'صيادة الكريسماس', // ✅ تم إصلاح المسافة هنا

    // ═══ GLORY TITLE UNITS ═══
    'Berserker': 'بيرسيركر', 'berserker': 'بيرسيركر',
    'FlameBreathBerserker': 'بيرسيركر نَفَس اللهب', 'flamebreathberserker': 'بيرسيركر نَفَس اللهب',
    'SpearWoman': 'امرأة الرمح', 'spearwoman': 'امرأة الرمح',
    'GingerBreadMaiden': 'عذراء الزنجبيل', 'gingerbreadmaiden': 'عذراء الزنجبيل',
    'GingerbreadMaiden': 'عذراء الزنجبيل',

    // ═══ MASTER (Outer Realms) ═══
    'MasterSwordsman': 'سياف أستاذ', 'masterswordsman': 'سياف أستاذ',
    'MasterArcher': 'رامي أستاذ', 'masterarcher': 'رامي أستاذ',

    // ═══ SPRING / FOREST ═══
    'ForestWarrior': 'محارب الغابة', 'forestwarrior': 'محارب الغابة',
    'ForestHunter': 'صياد الغابة', 'foresthunter': 'صياد الغابة',
    'ForestGuardian': 'حامي الغابة', 'forestguardian': 'حامي الغابة',
    'ForestBowman': 'نشاب الغابة', 'forestbowman': 'نشاب الغابة',
    'SpringHuntress': 'صيادة الربيع', 'springhuntress': 'صيادة الربيع',
    'SpringFootsoldier': 'جندي ربيع', 'springfootsoldier': 'جندي ربيع',
    'ShamrockHuntsman': 'صياد البرسيم', 'shamrockhuntsman': 'صياد البرسيم',
    'ShamrockAssassin': 'سفاح البرسيم', 'shamrockassassin': 'سفاح البرسيم',

    // ═══ HALLOWEEN ═══
    'PumpkinButcher': 'جزار اليقطين', 'pumpkinbutcher': 'جزار اليقطين',
    'RavenChomper': 'قاطع الغراب', 'ravenchomper': 'قاطع الغراب',
    'SkeletonWarrior': 'محارب هيكلي', 'skeletonwarrior': 'محارب هيكلي',
    'SkeletonBowman': 'نشاب هيكلي', 'skeletonbowman': 'نشاب هيكلي',
    'SkeletalScytheman': 'حاصد هيكلي', 'skeletalscytheman': 'حاصد هيكلي',
    'SkeletalHunter': 'صياد هيكلي', 'skeletalhunter': 'صياد هيكلي',
    'Bonerattler': 'مقلق العظام', 'bonerattler': 'مقلق العظام',
    'FireWitch': 'ساحرة النار', 'firewitch': 'ساحرة النار',

    // ═══ WINTER ═══
    'GnomadWarrior': 'محارب جوال', 'gnomadwarrior': 'محارب جوال',
    'GnomadArcher': 'رامي جوال', 'gnomadarcher': 'رامي جوال',
    'GingerbreadBrawler': 'مشاجر الزنجبيل', 'gingerbreadbrawler': 'مشاجر الزنجبيل',
    'GingerbreadSniper': 'قناص الزنجبيل', 'gingerbreadsniper': 'قناص الزنجبيل',

    // ═══ COWS OF TERROR ═══
    'CowBerdier': 'بقرة هالبرد', 'cowberdier': 'بقرة هالبرد',
    'LongbowOx': 'ثور قوس طويل', 'longbowox': 'ثور قوس طويل',

    // ═══ MARAUDER EVENT ═══
    'Marauder': 'سالب', 'marauder': 'سالب',
    'Pyromaniac': 'مهووس بالنار', 'pyromaniac': 'مهووس بالنار',
    'VeteranMarauder': 'سالب محترف', 'veteranmarauder': 'سالب محترف',
    'VeteranPyromaniac': 'مهووس بالنار محترف', 'veteranpyromaniac': 'مهووس بالنار محترف',

    // ═══ ICE CHAMPION ═══
    'MasterFrostBowman': 'نشاب الصقيع الأستاذ', 'masterfrostbowman': 'نشاب الصقيع الأستاذ',
    'FrostBowman': 'نشاب الصقيع', 'frostbowman': 'نشاب الصقيع',
    'MasterBoneHuntress': 'صيادة العظام الأستاذة', 'masterbonehuntress': 'صيادة العظام الأستاذة',
    'BoneHuntress': 'صيادة العظام', 'bonehuntress': 'صيادة العظام',

    // ═══ THORN KING ═══
    'DemonSlayer': 'قاتل الشياطين', 'demonslayer': 'قاتل الشياطين',
    'Assassin': 'سفاح', 'assassin': 'سفاح',

    // ═══ UNDERWORLD ═══
    'RenegadeCaveSmasher': 'ساحق الكهف مارق', 'renegadecavesmasher': 'ساحق الكهف مارق',
    'RenegadeCaveHunter': 'صياد الكهف مارق', 'renegadecavehunter': 'صياد الكهف مارق',

    // ═══ BEEF / DRAGON (Removed the duplicate here) ═══
    'GlasswingArcher': 'رامي الجناح الزجاجي', 'glasswingarcher': 'رامي الجناح الزجاجي',
    'ScaleboundGuardian': 'حامي الحراشف', 'scaleboundguardian': 'حامي الحراشف',
    'ScaleshardMarksman': 'قناص شظايا الحراشف', 'scaleshardmarksman': 'قناص شظايا الحراشف',

    // ═══ SIEGE TOOLS ═══
    'Ladder': 'سلم', 'ladder': 'سلم',
    'SiegeTower': 'برج حصار', 'siegetower': 'برج حصار',
    'BatteringRam': 'كبش حصار', 'batteringram': 'كبش حصار',
    'Catapult': 'منجنيق', 'catapult': 'منجنيق',
    'Mantlet': 'متراس', 'mantlet': 'متراس',
    'IronMantlet': 'متراس حديدي', 'ironmantlet': 'متراس حديدي',
    'FireArrow': 'سهم ناري', 'firearrow': 'سهم ناري',
    'Wall': 'سور', 'wall': 'سور',
    'Gate': 'بوابة', 'gate': 'بوابة',
    'Moat': 'خندق', 'moat': 'خندق',
  };

  static const Map<String, Map<String, String>> _map = {
    'ar': {
      'appName': 'GGE Bot', 'login': 'تسجيل الدخول', 'username': 'اسم المستخدم',
      'password': 'كلمة المرور', 'logout': 'تسجيل الخروج', 'connecting': 'جاري الاتصال...',
      'loginSuccess': 'تم الدخول بنجاح', 'loginFailed': 'فشل تسجيل الدخول',
      'mainTitle': 'لوحة التحكم', 'welcome': 'مرحباً بك', 'transferTroops': 'تحويل الجنود',
      'trainTroops': 'تدريب الجنود', 'smuggleTroops': 'تهريب الجنود', 'commanders': 'القواد',
      'transferDesc': 'نقل بين قلاعك', 'trainDesc': 'صناعة جنود جديدة', 'smuggleDesc': 'إرسال لأعضاء التحالف',
      'cmdDesc': 'إدارة حالة القواد', 'settings': 'الإعدادات', 'logoutConfirm': 'هل تريد تسجيل الخروج؟',
      'from': 'من', 'to': 'إلى', 'units': 'الجنود', 'selectUnits': 'اختر الجنود', 'selectAll': 'تحديد الكل',
      'deselectAll': 'إلغاء التحديد', 'send': 'إرسال', 'sending': 'جاري الإرسال...',
      'transferOk': 'تم التحويل بنجاح', 'transferFail': 'فشل التحويل', 'noUnitsSelected': 'لم تختر أي جنود',
      'loadingUnits': 'جاري تحميل الجنود...', 'loadUnits': 'تحميل الجنود', 'offenseOnly': 'هجومية',
      'defenseOnly': 'دفاعية', 'allUnits': 'الكل', 'total': 'الإجمالي', 'available': 'متاح',
      'amountToSend': 'الكمية', 'sameCastleError': 'لا يمكن التحويل لنفس القلعة', 'allianceMembers': 'أعضاء التحالف',
      'peaceActive': 'محمي', 'noPeaceActive': 'بدون حماية', 'peaceTime': 'وقت الحماية', 'distance': 'المسافة',
      'clicks': 'خانة', 'selectMember': 'اختر العضو', 'memberCastle': 'قلعة العضو',
      'loadingMembers': 'جاري تحميل الأعضاء...', 'noAllianceMembers': 'لا يوجد أعضاء بحماية',
      'peaceOnly': 'المحميون فقط', 'allMembers': 'كل الأعضاء', 'sendTo': 'إرسال إلى',
      'notInAlliance': 'أنت لست في تحالف، أو تعذر جلب بيانات التحالف.', 'maxMovements': 'وصلت للحد الأقصى من تحركات الجيوش.',
      'allLordsBusy': 'كل القادة مشغولين.', 'stationTime': 'وقت البقاء (ساعات)', 'selectLord': 'اختر القائد',
      'autoLord': 'اختيار تلقائي', 'commanderBusy': 'مشغول', 'commanderFree': 'متاح', 'timeRemaining': 'الوقت المتبقي',
      'recall': 'انسحاب', 'recallSuccess': 'تم إرسال أمر الانسحاب', 'recallFail': 'فشل الانسحاب',
      'noCommanders': 'لا يوجد قواد متاحين', 'selectCastle': 'اختر القلعة', 'unitType': 'نوع الجندي',
      'amount': 'الكمية', 'startTraining': 'ابدأ التدريب', 'trainingOk': 'بدأ التدريب', 'trainingFail': 'فشل التدريب',
      'cancel': 'إلغاء', 'ok': 'موافق', 'close': 'إغلاق', 'error': 'خطأ', 'retry': 'إعادة المحاولة',
      'language': 'اللغة', 'none': 'لا شيء', 'refresh': 'تحديث', 'statsTitle': 'الإحصائيات',
      'statsDesc': 'موارد، جنود، إنتاج', 'notificationsTitle': 'الإشعارات', 'notificationsDesc': 'تنبيهات الهجمات',
      'notificationsEnabled': 'تفعيل الإشعارات', 'notificationsEnabledDesc': 'استقبال إشعارات عند الهجوم',
      'soundAlert': 'صوت التنبيه', 'soundAlertDesc': 'تشغيل صوت عند وصول هجوم', 'noAlerts': 'مفيش تنبيهات',
      'noAlertsDesc': 'مفيش هجمات لحد دلوقتي — كل حاجة تمام', 'noCastles': 'مفيش قلاع', 'delete': 'حذف',
      'details': 'تفاصيل', 'deleteAll': 'حذف الكل', 'deleteAlertConfirm': 'متأكد إنك عايز تحذف الإشعار ده؟',
      'allianceAttacks': 'هجمات أعضاء التحالف', 'allianceAttacksDesc': 'تنبيه لما حد من تحالفك يتهجم عليه',
      'attackerCastle': 'قلعة المهاجم', 'targetCastle': 'القلعة المستهدفة', 'attackingUnits': 'الجنود المهاجمة',
      'defenseUnits': 'جنود الدفاع', 'defenseInfo': 'تفاصيل الدفاع',
      'defenseNotAvailable': 'افتح صفحة الإحصائيات الأول عشان تشوف تفاصيل الدفاع', 'defenseStat': 'قوة الدفاع',
      'perHour': 'ساعة', 'allianceMember': 'عضو تحالف',
    },
    'en': {
      'appName': 'GGE Bot', 'login': 'Login', 'username': 'Username', 'password': 'Password',
      'logout': 'Logout', 'connecting': 'Connecting...', 'loginSuccess': 'Login successful',
      'loginFailed': 'Login failed', 'mainTitle': 'Dashboard', 'welcome': 'Welcome back',
      'transferTroops': 'Transfer Troops', 'trainTroops': 'Train Troops', 'smuggleTroops': 'Smuggle Troops',
      'commanders': 'Commanders', 'transferDesc': 'Move between your castles', 'trainDesc': 'Create new units',
      'smuggleDesc': 'Send to peace-protected allies', 'cmdDesc': 'Manage commander status',
      'settings': 'Settings', 'logoutConfirm': 'Log out?', 'from': 'From', 'to': 'To', 'units': 'Units',
      'selectUnits': 'Select units', 'selectAll': 'Select All', 'deselectAll': 'Deselect All', 'send': 'Send',
      'sending': 'Sending...', 'transferOk': 'Transfer successful', 'transferFail': 'Transfer failed',
      'noUnitsSelected': 'No units selected', 'loadingUnits': 'Loading units...', 'loadUnits': 'Load Units',
      'offenseOnly': 'Offense', 'defenseOnly': 'Defense', 'allUnits': 'All', 'total': 'Total',
      'available': 'Available', 'amountToSend': 'Amount', 'sameCastleError': 'Cannot transfer to the same castle',
      'allianceMembers': 'Alliance Members', 'peaceActive': 'Protected', 'noPeaceActive': 'No peace',
      'peaceTime': 'Peace time', 'distance': 'Distance', 'clicks': 'clicks', 'selectMember': 'Select member',
      'memberCastle': 'Member castle', 'loadingMembers': 'Loading members...',
      'noAllianceMembers': 'No protected members', 'peaceOnly': 'Protected only', 'allMembers': 'All members',
      'sendTo': 'Send to', 'notInAlliance': 'You are not in an alliance, or could not fetch alliance data.',
      'maxMovements': 'Max kingdom army movements exceeded.', 'allLordsBusy': 'All lords are currently busy.',
      'stationTime': 'Station Time (Hours)', 'selectLord': 'Select Commander', 'autoLord': 'Auto Select',
      'commanderBusy': 'Busy', 'commanderFree': 'Available', 'timeRemaining': 'Time Remaining',
      'recall': 'Recall', 'recallSuccess': 'Recall command sent', 'recallFail': 'Recall failed',
      'noCommanders': 'No commanders found', 'selectCastle': 'Select castle', 'unitType': 'Unit type',
      'amount': 'Amount', 'startTraining': 'Start Training', 'trainingOk': 'Training started',
      'trainingFail': 'Training failed', 'cancel': 'Cancel', 'ok': 'OK', 'close': 'Close', 'error': 'Error',
      'retry': 'Retry', 'language': 'Language', 'none': 'None', 'refresh': 'Refresh', 'statsTitle': 'Statistics',
      'statsDesc': 'Resources, units, production', 'notificationsTitle': 'Notifications',
      'notificationsDesc': 'Attack alerts', 'notificationsEnabled': 'Enable notifications',
      'notificationsEnabledDesc': 'Receive alerts when attacked', 'soundAlert': 'Sound alerts',
      'soundAlertDesc': 'Play sound when attack arrives', 'noAlerts': 'No alerts', 'noAlertsDesc': 'No attacks yet',
      'noCastles': 'No castles', 'delete': 'Delete', 'details': 'Details', 'deleteAll': 'Delete All',
      'deleteAlertConfirm': 'Delete this alert?', 'allianceAttacks': 'Alliance attacks',
      'allianceAttacksDesc': 'Alert when an ally is attacked', 'attackerCastle': 'Attacker castle',
      'targetCastle': 'Target castle', 'attackingUnits': 'Attacking units', 'defenseUnits': 'Defending units',
      'defenseInfo': 'Defense info', 'defenseNotAvailable': 'Open Statistics page first to see defense info',
      'defenseStat': 'Defense stat', 'perHour': 'h', 'allianceMember': 'Alliance member',
    },
  };
}