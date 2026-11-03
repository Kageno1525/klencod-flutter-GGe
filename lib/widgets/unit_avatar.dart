import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models.dart';
import '../theme.dart';

// ═══════════════════════════════════════════════════════════
//  SPRITE DATA CLASSES & MAP (الـ 39 جندي)
// ═══════════════════════════════════════════════════════════
class SpritePart {
  final double srcX, srcY, srcW, srcH;
  final double x, y, scaleX, scaleY;
  const SpritePart({
    required this.srcX,
    required this.srcY,
    required this.srcW,
    required this.srcH,
    required this.x,
    required this.y,
    this.scaleX = 1,
    this.scaleY = 1,
  });
}

const Map<String, List<SpritePart>> unitSpriteData = {
  'Barracks_Unit_Archer': [
    SpritePart(srcX: 1, srcY: 175, srcW: 92, srcH: 132, x: -94, y: -132),
    SpritePart(srcX: 1, srcY: 1, srcW: 43, srcH: 42, x: -46.9, y: -0.25, scaleX: 1.46, scaleY: 1.46),
    SpritePart(srcX: 46, srcY: 1, srcW: 42, srcH: 44, x: -46.9, y: -0.25, scaleX: 1.46, scaleY: 1.46),
    SpritePart(srcX: 1, srcY: 47, srcW: 71, srcH: 126, x: -71, y: -126),
  ],
  'Barracks_Unit_Bowman': [
    SpritePart(srcX: 1, srcY: 157, srcW: 92, srcH: 124, x: -93, y: -124),
    SpritePart(srcX: 46, srcY: 283, srcW: 43, srcH: 43, x: -53.1, y: -0.55, scaleX: 1.74, scaleY: 1.74),
    SpritePart(srcX: 1, srcY: 283, srcW: 43, srcH: 45, x: -53.1, y: -0.55, scaleX: 1.74, scaleY: 1.74),
    SpritePart(srcX: 1, srcY: 1, srcW: 108, srcH: 154, x: -108, y: -154),
  ],
  'Barracks_Unit_Crossbowman': [
    SpritePart(srcX: 74, srcY: 1, srcW: 53, srcH: 126, x: -85, y: -120),
    SpritePart(srcX: 129, srcY: 50, srcW: 39, srcH: 46, x: -42.25, y: -54.55, scaleX: 1.3, scaleY: 1.3),
    SpritePart(srcX: 129, srcY: 1, srcW: 39, srcH: 47, x: -42.25, y: -54.55, scaleX: 1.3, scaleY: 1.3),
    SpritePart(srcX: 1, srcY: 1, srcW: 71, srcH: 126, x: -71, y: -114),
  ],
  'Barracks_Unit_Elitebowman': [
    SpritePart(srcX: 92, srcY: 1, srcW: 81, srcH: 125, x: -81, y: -125),
    SpritePart(srcX: 1, srcY: 135, srcW: 63, srcH: 62, x: -64.85, y: -53.95),
    SpritePart(srcX: 92, srcY: 128, srcW: 61, srcH: 65, x: -64.15, y: -56.75),
    SpritePart(srcX: 1, srcY: 1, srcW: 89, srcH: 132, x: -94, y: -132),
  ],
  'Barracks_Unit_Elitecrossbowman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 89, srcH: 128, x: -97, y: -118),
    SpritePart(srcX: 1, srcY: 131, srcW: 53, srcH: 120, x: -50.2, y: -103.4),
    SpritePart(srcX: 56, srcY: 135, srcW: 59, srcH: 114, x: -50.45, y: -99.05),
    SpritePart(srcX: 92, srcY: 1, srcW: 76, srcH: 132, x: -76, y: -120),
  ],
  'Barracks_Unit_Elitehalberd': [
    SpritePart(srcX: 127, srcY: 1, srcW: 81, srcH: 132, x: -82, y: -118),
    SpritePart(srcX: 1, srcY: 1, srcW: 39, srcH: 119, x: -32.2, y: -104.4),
    SpritePart(srcX: 42, srcY: 1, srcW: 36, srcH: 119, x: -35, y: -104.2),
    SpritePart(srcX: 80, srcY: 1, srcW: 45, srcH: 130, x: -40.3, y: -102.5),
  ],
  'Barracks_Unit_Elitekingscrossbowman': [
    SpritePart(srcX: 156, srcY: 1, srcW: 84, srcH: 127, x: -84, y: -116),
    SpritePart(srcX: 107, srcY: 1, srcW: 47, srcH: 122, x: -32.35, y: -59.95),
    SpritePart(srcX: 1, srcY: 1, srcW: 51, srcH: 118, x: -31.75, y: -58.15),
    SpritePart(srcX: 54, srcY: 1, srcW: 51, srcH: 122, x: -57, y: -121),
  ],
  'Barracks_Unit_Elitekingsmace': [
    SpritePart(srcX: 1, srcY: 1, srcW: 81, srcH: 123, x: -80, y: -123),
    SpritePart(srcX: 1, srcY: 126, srcW: 49, srcH: 128, x: -28, y: -64.1),
    SpritePart(srcX: 1, srcY: 260, srcW: 67, srcH: 132, x: -37, y: -65.9),
    SpritePart(srcX: 52, srcY: 126, srcW: 66, srcH: 132, x: -70, y: -132),
  ],
  'Barracks_Unit_Elitemace': [
    SpritePart(srcX: 1, srcY: 1, srcW: 93, srcH: 132, x: -93, y: -128),
    SpritePart(srcX: 63, srcY: 135, srcW: 58, srcH: 82, x: -50.45, y: -71.8),
    SpritePart(srcX: 96, srcY: 1, srcW: 57, srcH: 87, x: -51.5, y: -67.7),
    SpritePart(srcX: 1, srcY: 135, srcW: 60, srcH: 87, x: -60, y: -83),
  ],
  'Barracks_Unit_Elitespeerman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 95, srcH: 132, x: -98, y: -123),
    SpritePart(srcX: 98, srcY: 119, srcW: 64, srcH: 67, x: -55.75, y: -58.8),
    SpritePart(srcX: 1, srcY: 135, srcW: 55, srcH: 48, x: -55.45, y: -57.6),
    SpritePart(srcX: 98, srcY: 1, srcW: 64, srcH: 116, x: -64, y: -116),
  ],
  'Barracks_Unit_Elitetwohandedsword': [
    SpritePart(srcX: 1, srcY: 84, srcW: 63, srcH: 103, x: -74.15, y: -115.4),
    SpritePart(srcX: 42, srcY: 1, srcW: 37, srcH: 81, x: -58.05, y: -112.65, scaleX: 1.3, scaleY: 1.3),
    SpritePart(srcX: 1, srcY: 1, srcW: 39, srcH: 75, x: -54.7, y: -119, scaleX: 1.3, scaleY: 1.3),
    SpritePart(srcX: 1, srcY: 189, srcW: 89, srcH: 132, x: -90, y: -120),
  ],
  'Barracks_Unit_Halberd': [
    SpritePart(srcX: 1, srcY: 1, srcW: 82, srcH: 132, x: -82, y: -119),
    SpritePart(srcX: 85, srcY: 129, srcW: 36, srcH: 118, x: -32.8, y: -96.5),
    SpritePart(srcX: 1, srcY: 135, srcW: 35, srcH: 112, x: -33.45, y: -102),
    SpritePart(srcX: 85, srcY: 1, srcW: 40, srcH: 126, x: -40, y: -114),
  ],
  'Barracks_Unit_Heavycrossbowman': [
    SpritePart(srcX: 73, srcY: 1, srcW: 48, srcH: 124, x: -84, y: -119),
    SpritePart(srcX: 73, srcY: 127, srcW: 41, srcH: 95, x: -41.85, y: 0, scaleX: 1.29, scaleY: 1.29),
    SpritePart(srcX: 1, srcY: 135, srcW: 42, srcH: 90, x: -41.85, y: 0, scaleX: 1.29, scaleY: 1.29),
    SpritePart(srcX: 1, srcY: 1, srcW: 70, srcH: 132, x: -70, y: -122),
  ],
  'Barracks_Unit_Kingsbowman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 94, srcH: 132, x: -94, y: -132),
    SpritePart(srcX: 1, srcY: 179, srcW: 46, srcH: 38, x: -49.65, y: -19),
    SpritePart(srcX: 49, srcY: 135, srcW: 40, srcH: 42, x: -52.05, y: -21.3),
    SpritePart(srcX: 1, srcY: 135, srcW: 46, srcH: 42, x: -73, y: -43),
  ],
  'Barracks_Unit_Kingscrossbowman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 87, srcH: 132, x: -87, y: -122),
    SpritePart(srcX: 1, srcY: 188, srcW: 53, srcH: 51, x: -53.95, y: -42.05),
    SpritePart(srcX: 56, srcY: 188, srcW: 32, srcH: 48, x: -52.85, y: -44.8),
    SpritePart(srcX: 1, srcY: 135, srcW: 54, srcH: 51, x: -59, y: -51),
  ],
  'Barracks_Unit_Kingsmace': [
    SpritePart(srcX: 1, srcY: 1, srcW: 87, srcH: 132, x: -87, y: -132),
    SpritePart(srcX: 56, srcY: 135, srcW: 58, srcH: 68, x: -51.05, y: -60.1),
    SpritePart(srcX: 90, srcY: 1, srcW: 49, srcH: 78, x: -46.75, y: -69.05),
    SpritePart(srcX: 1, srcY: 135, srcW: 53, srcH: 78, x: -53, y: -78),
  ],
  'Barracks_Unit_Kingsspeerman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 93, srcH: 132, x: -93, y: -119),
    SpritePart(srcX: 1, srcY: 209, srcW: 58, srcH: 53, x: -35.45, y: -27.65, scaleX: 1.19, scaleY: 1.19),
    SpritePart(srcX: 1, srcY: 264, srcW: 55, srcH: 53, x: -33.95, y: -27.6, scaleX: 1.19, scaleY: 1.19),
    SpritePart(srcX: 1, srcY: 135, srcW: 70, srcH: 72, x: -70, y: -59),
  ],
  'Barracks_Unit_Longbowman': [
    SpritePart(srcX: 1, srcY: 227, srcW: 82, srcH: 132, x: -83, y: -132),
    SpritePart(srcX: 43, srcY: 1, srcW: 38, srcH: 95, x: -37.7, y: -0.1, scaleX: 1.34, scaleY: 1.34),
    SpritePart(srcX: 1, srcY: 1, srcW: 40, srcH: 90, x: -37.7, y: -0.1, scaleX: 1.34, scaleY: 1.34),
    SpritePart(srcX: 1, srcY: 98, srcW: 64, srcH: 127, x: -64, y: -127),
  ],
  'Eventunit_Unit_BerimondRewardRange': [
    SpritePart(srcX: 88, srcY: 1, srcW: 96, srcH: 125, x: -100, y: -125),
    SpritePart(srcX: 226, srcY: 1, srcW: 40, srcH: 92, x: -72.8, y: -122.84, scaleX: 1.34, scaleY: 1.34),
    SpritePart(srcX: 186, srcY: 1, srcW: 38, srcH: 95, x: -72.01, y: -126.18, scaleX: 1.34, scaleY: 1.34),
    SpritePart(srcX: 1, srcY: 1, srcW: 85, srcH: 126, x: -92, y: -126),
  ],
  'Eventunit_Unit_EliteBerimondRewardMelee': [
    SpritePart(srcX: 1, srcY: 1, srcW: 85, srcH: 130, x: -83, y: -119),
    SpritePart(srcX: 195, srcY: 41, srcW: 30, srcH: 38, x: -38.146, y: -45.2625, scaleX: 1.23, scaleY: 1.23),
    SpritePart(srcX: 195, srcY: 1, srcW: 31, srcH: 38, x: -38.469, y: -45.324, scaleX: 1.23, scaleY: 1.23),
    SpritePart(srcX: 88, srcY: 1, srcW: 105, srcH: 129, x: -103, y: -118),
  ],
  'Eventunit_Unit_EliteBerimondRewardRange': [
    SpritePart(srcX: 1, srcY: 1, srcW: 101, srcH: 126, x: -103, y: -126),
    SpritePart(srcX: 1, srcY: 258, srcW: 53, srcH: 92, x: -73.13, y: -123.49, scaleX: 1.34, scaleY: 1.34),
    SpritePart(srcX: 56, srcY: 258, srcW: 38, srcH: 95, x: -71.91, y: -126.43, scaleX: 1.34, scaleY: 1.34),
    SpritePart(srcX: 1, srcY: 129, srcW: 89, srcH: 127, x: -92, y: -127),
  ],
  'Eventunit_Unit_Eventcrossbowman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 86, srcH: 132, x: -88, y: -122),
    SpritePart(srcX: 89, srcY: 1, srcW: 50, srcH: 111, x: -58.05, y: -111.75),
    SpritePart(srcX: 1, srcY: 135, srcW: 59, srcH: 118, x: -59.45, y: -118.3),
    SpritePart(srcX: 62, srcY: 135, srcW: 59, srcH: 117, x: -59, y: -118),
  ],
  'Eventunit_Unit_Eventknight': [
    SpritePart(srcX: 49, srcY: 1, srcW: 84, srcH: 129, x: -84, y: -129),
    SpritePart(srcX: 192, srcY: 1, srcW: 55, srcH: 126, x: -55.1, y: -125.7),
    SpritePart(srcX: 1, srcY: 1, srcW: 46, srcH: 132, x: -46, y: -131.65),
    SpritePart(srcX: 135, srcY: 1, srcW: 55, srcH: 131, x: -55, y: -131),
  ],
  'Eventunit_Unit_Renegadepikeman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 25, srcH: 18, x: -47.065, y: -103.682, scaleX: 1.14, scaleY: 1.14),
    SpritePart(srcX: 28, srcY: 1, srcW: 43, srcH: 34, x: -47.489, y: -29.709, scaleX: 1.14, scaleY: 1.14),
    SpritePart(srcX: 1, srcY: 37, srcW: 98, srcH: 132, x: -97, y: -123),
  ],
  'Eventunit_Unit_Renegadespearthrower': [
    SpritePart(srcX: 87, srcY: 1, srcW: 29, srcH: 63, x: -36.73, y: -76.39, scaleX: 1.27, scaleY: 1.27),
    SpritePart(srcX: 87, srcY: 66, srcW: 17, srcH: 24, x: -34.2585, y: -26.29, scaleX: 1.27, scaleY: 1.27),
    SpritePart(srcX: 1, srcY: 1, srcW: 84, srcH: 132, x: -84, y: -123),
  ],
  'Eventunit_Unit_Saberslasher': [
    SpritePart(srcX: 1, srcY: 353, srcW: 99, srcH: 78, x: -103.75, y: -78.6),
    SpritePart(srcX: 1, srcY: 1, srcW: 162, srcH: 233, x: -163, y: -233),
    SpritePart(srcX: 1, srcY: 236, srcW: 102, srcH: 115, x: -106.85, y: -155.7),
    SpritePart(srcX: 105, srcY: 236, srcW: 83, srcH: 161, x: -102, y: -163),
  ],
  'Eventunit_Unit_SamuraiAttackerMelee': [
    SpritePart(srcX: 1, srcY: 337, srcW: 96, srcH: 128, x: -95.6, y: -126.7),
    SpritePart(srcX: 1, srcY: 212, srcW: 101, srcH: 123, x: -100.2, y: -121.05),
    SpritePart(srcX: 1, srcY: 135, srcW: 105, srcH: 75, x: -104.35, y: -73.05),
    SpritePart(srcX: 1, srcY: 1, srcW: 117, srcH: 132, x: -117, y: -130),
  ],
  'Eventunit_Unit_SamuraiDefenderRange': [
    SpritePart(srcX: 1, srcY: 382, srcW: 70, srcH: 74, x: -70.05, y: -74.3),
    SpritePart(srcX: 1, srcY: 130, srcW: 108, srcH: 132, x: -108, y: -132),
    SpritePart(srcX: 1, srcY: 264, srcW: 97, srcH: 116, x: -96.55, y: -115.75),
    SpritePart(srcX: 1, srcY: 1, srcW: 110, srcH: 127, x: -110, y: -127),
  ],
  'Eventunit_Unit_Slingshotmarksman': [
    SpritePart(srcX: 1, srcY: 134, srcW: 62, srcH: 85, x: -122.99, y: -129.48, scaleX: 1.49, scaleY: 1.49),
    SpritePart(srcX: 65, srcY: 134, srcW: 84, srcH: 62, x: -117.229, y: -90.489, scaleX: 1.49, scaleY: 1.49),
    SpritePart(srcX: 1, srcY: 1, srcW: 131, srcH: 131, x: -123, y: -129),
  ],
  'Eventunit_Unit_VeteranSaberslasher': [
    SpritePart(srcX: 1, srcY: 1, srcW: 444, srcH: 600, x: -450, y: -600),
    SpritePart(srcX: 306, srcY: 603, srcW: 242, srcH: 211, x: -242.5, y: -218.35),
    SpritePart(srcX: 306, srcY: 816, srcW: 245, srcH: 187, x: -303.55, y: -356.75),
    SpritePart(srcX: 1, srcY: 603, srcW: 303, srcH: 351, x: -303, y: -357),
  ],
  'Eventunit_Unit_VeteranSlingshotmarksman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 460, srcH: 490, x: -460, y: -486),
    SpritePart(srcX: 1, srcY: 493, srcW: 411, srcH: 117, x: -463.2, y: -113.8),
    SpritePart(srcX: 463, srcY: 463, srcW: 143, srcH: 118, x: -267.45, y: -458.2),
    SpritePart(srcX: 463, srcY: 1, srcW: 407, srcH: 460, x: -458, y: -456),
  ],
  'Barracks_Unit_Mace': [
    SpritePart(srcX: 1, srcY: 1, srcW: 87, srcH: 132, x: -87, y: -118),
    SpritePart(srcX: 41, srcY: 175, srcW: 27, srcH: 35, x: -38.222, y: -41.88, scaleX: 1.34, scaleY: 1.34),
    SpritePart(srcX: 41, srcY: 135, srcW: 27, srcH: 38, x: -38.021, y: -45.833, scaleX: 1.34, scaleY: 1.34),
    SpritePart(srcX: 1, srcY: 135, srcW: 38, srcH: 67, x: -38, y: -53),
  ],
  'Barracks_Unit_Speerman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 80, srcH: 132, x: -80, y: -123),
    SpritePart(srcX: 59, srcY: 193, srcW: 55, srcH: 44, x: -57.95, y: -61.1),
    SpritePart(srcX: 59, srcY: 135, srcW: 54, srcH: 56, x: -58.85, y: -55.7),
    SpritePart(srcX: 1, srcY: 135, srcW: 56, srcH: 61, x: -59, y: -61),
  ],
  'Barracks_Unit_Swordman': [
    SpritePart(srcX: 1, srcY: 1, srcW: 86, srcH: 132, x: -86, y: -115),
    SpritePart(srcX: 47, srcY: 198, srcW: 51, srcH: 44, x: -54.25, y: -37.4),
    SpritePart(srcX: 1, srcY: 198, srcW: 44, srcH: 51, x: -50.5, y: -40.45),
    SpritePart(srcX: 1, srcY: 135, srcW: 58, srcH: 61, x: -58, y: -43),
  ],
  'Barracks_Unit_Twohandedsword': [
    SpritePart(srcX: 160, srcY: 1, srcW: 82, srcH: 132, x: -82, y: -121),
    SpritePart(srcX: 52, srcY: 1, srcW: 52, srcH: 113, x: -55.7, y: -112.2),
    SpritePart(srcX: 1, srcY: 1, srcW: 49, srcH: 106, x: -52.4, y: -118.8),
    SpritePart(srcX: 106, srcY: 1, srcW: 52, srcH: 119, x: -56, y: -118),
  ],
  'Dworkshop_Unit_Dollmelee': [
    SpritePart(srcX: 1, srcY: 1, srcW: 117, srcH: 132, x: -58, y: -66),
    SpritePart(srcX: 62, srcY: 135, srcW: 59, srcH: 70, x: -16.1, y: -26.45),
    SpritePart(srcX: 62, srcY: 207, srcW: 59, srcH: 66, x: -16.1, y: -28.4),
    SpritePart(srcX: 1, srcY: 135, srcW: 59, srcH: 97, x: -16, y: -55),
  ],
  'Dworkshop_Unit_Dollrange': [
    SpritePart(srcX: 1, srcY: 1, srcW: 132, srcH: 117, x: -64.25, y: -56.8),
    SpritePart(srcX: 123, srcY: 120, srcW: 59, srcH: 71, x: -7.4, y: -33.65),
    SpritePart(srcX: 135, srcY: 1, srcW: 59, srcH: 67, x: -7.4, y: -31.35),
    SpritePart(srcX: 1, srcY: 120, srcW: 120, srcH: 98, x: -68, y: -60.55),
  ],
  'Dworkshop_Unit_Premiumdollrange': [
    SpritePart(srcX: 1, srcY: 1, srcW: 132, srcH: 130, x: -66, y: -65),
    SpritePart(srcX: 1, srcY: 265, srcW: 59, srcH: 71, x: -29.6, y: -35.45),
    SpritePart(srcX: 62, srcY: 265, srcW: 59, srcH: 67, x: -29.6, y: -33.45),
    SpritePart(srcX: 1, srcY: 133, srcW: 131, srcH: 130, x: -65, y: -65),
  ],
  'Eventunit_Unit_BerimondRewardMelee': [
    SpritePart(srcX: 1, srcY: 1, srcW: 103, srcH: 131, x: -103, y: -113),
    SpritePart(srcX: 77, srcY: 174, srcW: 30, srcH: 38, x: -40.9, y: -38.7375, scaleX: 1.25, scaleY: 1.25),
    SpritePart(srcX: 77, srcY: 134, srcW: 31, srcH: 38, x: -41.225, y: -38.8, scaleX: 1.25, scaleY: 1.25),
    SpritePart(srcX: 1, srcY: 134, srcW: 74, srcH: 132, x: -74, y: -114),
  ],
};

// ═══════════════════════════════════════════════════════════
//  WIDGET
// ═══════════════════════════════════════════════════════════
class UnitAvatar extends StatefulWidget {
  final UnitCatalogEntry? info;
  final double size;
  final VoidCallback? onLongPress;
  final Color? tint;

  const UnitAvatar({
    super.key,
    required this.info,
    this.size = 44,
    this.onLongPress,
    this.tint,
  });

  @override
  State<UnitAvatar> createState() => _UnitAvatarState();
}

class _UnitAvatarState extends State<UnitAvatar> {
  ui.Image? _image;
  List<SpritePart>? _parts;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(UnitAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.info?.imageUrl != oldWidget.info?.imageUrl) {
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.info?.imageUrl;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // استخراج اسم الفولدر من الرابط
    final match = RegExp(r'/([^/]+)/[^/]+--\d+\.(webp|png)$').firstMatch(url);
    final folderName = match?.group(1);

    if (folderName != null && unitSpriteData.containsKey(folderName)) {
      _parts = unitSpriteData[folderName];
      try {
        final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
        final completer = Completer<ui.Image>();
        stream.addListener(ImageStreamListener((info, _) {
          if (!completer.isCompleted) completer.complete(info.image);
        }, onError: (e, _) {
          if (!completer.isCompleted) completer.completeError(e);
        }));
        _image = await completer.future;
      } catch (e) {
        _parts = null;
      }
    }

    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.info?.imageUrl;
    final color = widget.tint ?? _defaultColor();

    Widget child;

    if (_loading) {
      child = Center(
        child: SizedBox(
          width: widget.size * 0.35,
          height: widget.size * 0.35,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
      );
    } else if (_image != null && _parts != null) {
      // الصورة اتجمعت بنجاح
      child = CustomPaint(
        painter: SpritePainter(_image!, _parts!),
        size: Size(widget.size, widget.size),
      );
    } else if (url == null || url.isEmpty) {
      child = _iconFallback(color);
    } else {
      // صورة عادية
      child = Padding(
        padding: EdgeInsets.all(widget.size * 0.06),
        child: Image.network(
          url,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _iconFallback(color),
        ),
      );
    }

    final content = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(widget.size * 0.22),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

    if (widget.onLongPress == null) return content;
    return GestureDetector(
      onLongPress: widget.onLongPress,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }

  Color _defaultColor() {
    if (widget.info?.role == 'ranged') return AppTheme.teal;
    if (widget.info?.role == 'melee') return AppTheme.red;
    return AppTheme.purple;
  }

  Widget _iconFallback(Color color) {
    final icon = widget.info?.role == 'ranged'
        ? Icons.gps_fixed_rounded
        : widget.info?.role == 'melee'
            ? Icons.gavel_rounded
            : Icons.shield_rounded;
    return Icon(icon, color: color, size: widget.size * 0.45);
  }
}

// ═══════════════════════════════════════════════════════════
//  PAINTER
// ═══════════════════════════════════════════════════════════
class SpritePainter extends CustomPainter {
  final ui.Image image;
  final List<SpritePart> parts;

  SpritePainter(this.image, this.parts);

  @override
  void paint(Canvas canvas, Size size) {
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;

    for (final p in parts) {
      final left = p.x;
      final top = p.y;
      final right = left + p.srcW * p.scaleX;
      final bottom = top + p.srcH * p.scaleY;
      if (left < minX) minX = left;
      if (top < minY) minY = top;
      if (right > maxX) maxX = right;
      if (bottom > maxY) maxY = bottom;
    }

    final totalW = maxX - minX;
    final totalH = maxY - minY;
    if (totalW <= 0 || totalH <= 0) return;

    final scale = math.min(size.width / totalW, size.height / totalH);

    canvas.save();
    // توسيط الصورة في المربع
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-(minX + maxX) / 2, -(minY + maxY) / 2);

    final paint = Paint()..filterQuality = FilterQuality.high;

    // رسم القطع فوق بعض
    for (final p in parts) {
      canvas.save();
      canvas.translate(p.x, p.y);
      canvas.scale(p.scaleX, p.scaleY);
      final srcRect = Rect.fromLTWH(p.srcX, p.srcY, p.srcW, p.srcH);
      final dstRect = Rect.fromLTWH(0, 0, p.srcW, p.srcH);
      canvas.drawImageRect(image, srcRect, dstRect, paint);
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SpritePainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.parts != parts;
  }
}