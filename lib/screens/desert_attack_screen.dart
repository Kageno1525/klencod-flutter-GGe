import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/services/desert_attack_service.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

const Color kDesertGold = Color(0xFFD4AF37);
const Color kDesertSand = Color(0xFFE8A317);
const Color kDesertDark = Color(0xFF8B5A2B);

Color _gcColor(int? gc) {
  if (gc == null || gc < 40) return Colors.grey;
  if (gc >= 75) return kDesertGold;
  if (gc >= 60) return kDesertSand;
  if (gc >= 50) return const Color(0xFFCD7F32); // bronze
  return kDesertDark;
}

class DesertAttackScreen extends StatefulWidget {
  final GgeClient client;
  const DesertAttackScreen({super.key, required this.client});

  @override
  State<DesertAttackScreen> createState() => _DesertAttackScreenState();
}

class _DesertAttackScreenState extends State<DesertAttackScreen> {
  late final DesertAttackService _svc;
  late DesertAttackSettings _settings;

  List<OwnedCastle> _castles = [];
  OwnedCastle? _source;
  List<DesertTower> _towers = [];
  bool _scanning = false;
  bool _enriching = false;
  int _scanDone = 0, _scanTotal = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _svc = DesertAttackService(widget.client);
    _init();
  }

  Future<void> _init() async {
    _settings = await DesertAttackSettings.load();
    try {
      final castles = await widget.client.getCastles();
      // نفضل قلاع KID=1 (الصحراء) أو 12 (external)
      final preferred = castles
          .where((c) => c.kingdomId == 1 || c.areaType == 12)
          .toList();
      if (!mounted) return;
      setState(() {
        _castles = preferred.isNotEmpty ? preferred : castles;
        if (_castles.isNotEmpty) {
          try {
            _source =
                _castles.firstWhere((c) => c.areaId == _settings.sourceAreaId);
          } catch (_) {
            try {
              _source = _castles.firstWhere((c) => c.kingdomId == 1);
            } catch (_) {
              _source = _castles.first;
            }
          }
          _settings.sourceAreaId = _source!.areaId;
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _scan() async {
    if (_source == null) {
      _snack('اختر قلعة مصدر أولاً', color: AppTheme.red);
      return;
    }
    if (_scanning) return;

    setState(() {
      _scanning = true;
      _towers = [];
      _scanDone = 0;
      _scanTotal = 0;
    });

    try {
      final found = await _svc.scanArea(
        source: _source!,
        radiusTiles: _settings.radiusTiles,
        onProgress: (d, t) {
          if (!mounted) return;
          setState(() => _scanDone = d);
          setState(() => _scanTotal = t);
        },
      );
      if (!mounted) return;
      setState(() {
        _towers = found;
        _scanning = false;
      });
      if (found.isEmpty) {
        _snack('مفيش أبراج صحراء في النطاق ده', color: AppTheme.orange);
        return;
      }
      _enrichBatch(found.take(30).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      _snack('$e', color: AppTheme.red);
    }
  }

  Future<void> _enrichBatch(List<DesertTower> batch) async {
    if (_enriching || batch.isEmpty) return;
    setState(() => _enriching = true);
    for (final t in batch) {
      if (!mounted) break;
      try {
        final enriched = await _svc.preview(t);
        if (!mounted) break;
        setState(() {
          final idx = _towers
              .indexWhere((x) => x.x == t.x && x.y == t.y);
          if (idx >= 0) _towers[idx] = enriched;
        });
      } catch (_) {}
      await Future.delayed(
          Duration(milliseconds: 800 + (DateTime.now().millisecond % 400)));
    }
    if (mounted) setState(() => _enriching = false);
  }

  List<DesertTower> get _filtered {
    var list = _towers.toList();
    if (_settings.minGC > 0) {
      list = list
          .where((t) => (t.goldCampValue ?? 0) >= _settings.minGC)
          .toList();
    }
    switch (_settings.sortBy) {
      case 'gc':
        list.sort((a, b) {
          final c = (b.goldCampValue ?? 0).compareTo(a.goldCampValue ?? 0);
          if (c != 0) return c;
          return a.distanceFromSource.compareTo(b.distanceFromSource);
        });
        break;
      case 'distance':
        list.sort((a, b) =>
            a.distanceFromSource.compareTo(b.distanceFromSource));
        break;
    }
    return list;
  }

  Future<void> _openTowerSheet(DesertTower tower) async {
    if (_source == null) {
      _snack('اختر قلعة مصدر', color: AppTheme.red);
      return;
    }
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DesertAttackSheet(
        client: widget.client,
        source: _source!,
        tower: tower,
        svc: _svc,
      ),
    );
    if (result == true && mounted) {
      try {
        final fresh = await _svc.preview(tower);
        if (mounted) {
          setState(() {
            final idx = _towers
                .indexWhere((x) => x.x == tower.x && x.y == tower.y);
            if (idx >= 0) _towers[idx] = fresh;
          });
        }
      } catch (_) {}
    }
  }

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg,
            style: const TextStyle(decoration: TextDecoration.none)),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      body: Stack(
        children: [
          AppTheme.background(context),
          SafeArea(
            child: Column(
              children: [
                _header(context),
                if (_loading)
                  const Expanded(
                    child: Center(
                      child: CircularProgressIndicator(color: AppTheme.orange),
                    ),
                  )
                else ...[
                  _sourcePicker(context),
                  _filterBar(context),
                  if (_scanning || _enriching) _progressBar(context),
                  Expanded(
                    child: filtered.isEmpty
                        ? _emptyView(context)
                        : ListView.builder(
                            padding:
                                const EdgeInsets.fromLTRB(16, 4, 16, 100),
                            itemCount: filtered.length,
                            itemBuilder: (_, i) => FadeSlideIn(
                              delay: Duration(milliseconds: 30 + i * 30),
                              child: _towerCard(context, filtered[i]),
                            ),
                          ),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: GradientButton(
              label: _scanning
                  ? 'جارٍ المسح ($_scanDone/$_scanTotal)'
                  : 'مسح الصحراء (${_settings.radiusTiles} tile)',
              icon: Icons.landscape_rounded,
              gradient: const LinearGradient(
                  colors: [kDesertSand, kDesertDark]),
              loading: _scanning,
              onPressed: _scanning ? null : _scan,
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          AppIconBtn(
            icon: Icons.arrow_back_rounded,
            onTap: () => Navigator.pop(context),
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('برج الصحراء',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textColor(context),
                        letterSpacing: -0.3,
                        decoration: TextDecoration.none)),
                Text('${_towers.length} برج · ${_filtered.length} ظاهر',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subTextColor(context),
                        decoration: TextDecoration.none)),
              ],
            ),
          ),
          if (_enriching)
            const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: kDesertSand),
            ),
        ],
      ),
    );
  }

  Widget _sourcePicker(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: AppTheme.glassCard(
        context: context,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: kDesertSand.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.castle_rounded,
                  color: kDesertSand, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<OwnedCastle>(
                  value: _source,
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textColor(context)),
                  items: _castles
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(c.fullLabel,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: AppTheme.textColor(context),
                                    fontSize: 12)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _source = v;
                      _settings.sourceAreaId = v.areaId;
                      _settings.save();
                    });
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _chip(context,
                icon: Icons.tune_rounded,
                label: 'فلترة GC',
                color: kDesertSand,
                onTap: _openFilterSheet),
            const SizedBox(width: 8),
            _sortChip(context),
            const SizedBox(width: 8),
            _distanceChip(context),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none)),
        ]),
      ),
    );
  }

  Widget _sortChip(BuildContext context) {
    final labels = {'gc': 'GC', 'distance': 'المسافة'};
    return PopupMenuButton<String>(
      onSelected: (v) {
        setState(() {
          _settings.sortBy = v;
          _settings.save();
        });
      },
      itemBuilder: (_) => labels.entries
          .map((e) => PopupMenuItem(
                value: e.key,
                child: Row(children: [
                  if (_settings.sortBy == e.key)
                    const Icon(Icons.check, size: 14, color: AppTheme.green),
                  const SizedBox(width: 6),
                  Text(e.value,
                      style: TextStyle(color: AppTheme.textColor(context))),
                ]),
              ))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: kDesertGold.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDesertGold.withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.sort_rounded, color: kDesertGold, size: 14),
          const SizedBox(width: 6),
          Text(labels[_settings.sortBy] ?? '',
              style: const TextStyle(
                  color: kDesertGold,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none)),
        ]),
      ),
    );
  }

  Widget _distanceChip(BuildContext context) {
    return GestureDetector(
      onTap: () => _openRadiusSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.orange.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.orange.withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.place_rounded, color: AppTheme.orange, size: 14),
          const SizedBox(width: 6),
          Text('${_settings.radiusTiles} tile',
              style: const TextStyle(
                  color: AppTheme.orange,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none)),
        ]),
      ),
    );
  }

  Widget _progressBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: _scanning && _scanTotal > 0 ? _scanDone / _scanTotal : null,
          minHeight: 4,
          backgroundColor: kDesertSand.withOpacity(0.1),
          valueColor: const AlwaysStoppedAnimation(kDesertSand),
        ),
      ),
    );
  }

  Widget _emptyView(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: kDesertSand.withOpacity(0.12),
                shape: BoxShape.circle,
                border: Border.all(color: kDesertSand.withOpacity(0.3)),
              ),
              child: Icon(Icons.landscape_rounded,
                  size: 48, color: kDesertSand.withOpacity(0.7)),
            ),
            const SizedBox(height: 16),
            Text('مفيش أبراج لسه',
                style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none)),
            const SizedBox(height: 4),
            Text('دوس "مسح الصحراء" عشان تبدأ',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.subTextColor(context),
                    fontSize: 11,
                    decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }

  Widget _towerCard(BuildContext context, DesertTower t) {
    final legendary = t.isLegendary;
    final borderColor = legendary
        ? kDesertGold
        : t.hasGold
            ? _gcColor(t.goldCampValue)
            : AppTheme.subTextColor(context).withOpacity(0.2);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _openTowerSheet(t),
        child: Container(
          decoration: BoxDecoration(
            gradient: legendary
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0x44D4AF37), Color(0x11FFD700)])
                : null,
            color: legendary
                ? null
                : (AppTheme.isDark(context)
                    ? Colors.white.withOpacity(0.04)
                    : Colors.black.withOpacity(0.03)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: borderColor, width: legendary ? 1.6 : 1.2),
            boxShadow: legendary
                ? [
                    BoxShadow(
                        color: kDesertGold.withOpacity(0.3),
                        blurRadius: 18,
                        offset: const Offset(0, 6))
                  ]
                : null,
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  gradient: legendary
                      ? const LinearGradient(
                          colors: [kDesertGold, Color(0xFFFFD700)])
                      : null,
                  color: legendary
                      ? null
                      : kDesertSand.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  legendary
                      ? Icons.emoji_events_rounded
                      : Icons.landscape_rounded,
                  color: legendary ? Colors.black : kDesertSand,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(t.coordsLabel,
                            style: TextStyle(
                                color: AppTheme.textColor(context),
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                decoration: TextDecoration.none)),
                        const SizedBox(width: 8),
                        if (t.goldCampValue != null)
                          _gcBadge(t.goldCampValue!, legendary),
                        if (t.isSpied) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                  color: Colors.green.withOpacity(0.5)),
                            ),
                            child: const Text('تجسس ✓',
                                style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    decoration: TextDecoration.none)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.straighten_rounded,
                            size: 11,
                            color: AppTheme.subTextColor(context)),
                        const SizedBox(width: 3),
                        Text(
                            '${t.distanceFromSource.toStringAsFixed(0)} tile',
                            style: TextStyle(
                                color: AppTheme.subTextColor(context),
                                fontSize: 10.5,
                                decoration: TextDecoration.none)),
                        if (t.goldCampValue == null) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.hourglass_empty_rounded,
                              size: 11,
                              color: AppTheme.subTextColor(context)),
                          const SizedBox(width: 3),
                          Text('جارٍ الجلب...',
                              style: TextStyle(
                                  color: AppTheme.subTextColor(context)
                                      .withOpacity(0.7),
                                  fontSize: 10.5,
                                  decoration: TextDecoration.none)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: AppTheme.subTextColor(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gcBadge(int gc, bool legendary) {
    final color = legendary ? kDesertGold : _gcColor(gc);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.star_rounded, color: color, size: 10),
        const SizedBox(width: 2),
        Text('GC $gc',
            style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none)),
      ]),
    );
  }

  void _openFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FilterSheet(
        settings: _settings,
        onChanged: () {
          setState(() {});
          _settings.save();
        },
      ),
    );
  }

  void _openRadiusSheet(BuildContext context) {
    double temp = _settings.radiusTiles.toDouble();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: Theme.of(ctx).colorScheme.surface,
          title: const Text('نطاق البحث',
              style: TextStyle(decoration: TextDecoration.none)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${temp.toInt()} tile',
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none)),
            Slider(
              value: temp,
              min: kDesertRadiusMin.toDouble(),
              max: kDesertRadiusMax.toDouble(),
              divisions:
                  (kDesertRadiusMax - kDesertRadiusMin) ~/ kDesertRadiusStep,
              activeColor: kDesertSand,
              label: '${temp.toInt()}',
              onChanged: (v) => setSt(() => temp =
                  (v / kDesertRadiusStep).round() * kDesertRadiusStep.toDouble()),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('$kDesertRadiusMin',
                  style: TextStyle(
                      fontSize: 10.5,
                      color: AppTheme.subTextColor(ctx),
                      decoration: TextDecoration.none)),
              Text('$kDesertRadiusMax',
                  style: TextStyle(
                      fontSize: 10.5,
                      color: AppTheme.subTextColor(ctx),
                      decoration: TextDecoration.none)),
            ]),
            const SizedBox(height: 6),
            Text('خطوة $kDesertRadiusStep · أكبر = بان أعلى',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.subTextColor(ctx),
                    decoration: TextDecoration.none)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _settings.radiusTiles = temp.toInt();
                  _settings.save();
                });
                Navigator.pop(ctx);
              },
              child: const Text('موافق'),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  Filter Sheet
// ═══════════════════════════════════════════════════════════
class _FilterSheet extends StatefulWidget {
  final DesertAttackSettings settings;
  final VoidCallback onChanged;
  const _FilterSheet({required this.settings, required this.onChanged});
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
      decoration: const BoxDecoration(
        color: Color(0xFF0B0B14),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44, height: 5,
              margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Icon(Icons.tune_rounded, color: kDesertSand, size: 20),
                const SizedBox(width: 8),
                const Text('فلترة GC',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none)),
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('تم',
                        style: TextStyle(color: kDesertSand))),
              ]),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('الحد الأدنى للـ GC',
                        style: TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            decoration: TextDecoration.none)),
                    const SizedBox(height: 8),
                    Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [0, 40, 50, 60, 75].map((val) {
                          final active = s.minGC == val;
                          final color = val == 75
                              ? kDesertGold
                              : val == 60
                                  ? kDesertSand
                                  : kDesertDark;
                          return GestureDetector(
                            onTap: () {
                              setState(() => s.minGC = val);
                              widget.onChanged();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: active
                                    ? color.withOpacity(0.25)
                                    : Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: active ? color : Colors.white24),
                              ),
                              child: Text(val == 0 ? 'الكل' : 'GC $val+',
                                  style: TextStyle(
                                      color:
                                          active ? color : Colors.white70,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                      decoration: TextDecoration.none)),
                            ),
                          );
                        }).toList()),
                  ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  Attack Sheet
// ═══════════════════════════════════════════════════════════
class _DesertAttackSheet extends StatefulWidget {
  final GgeClient client;
  final OwnedCastle source;
  final DesertTower tower;
  final DesertAttackService svc;

  const _DesertAttackSheet({
    required this.client,
    required this.source,
    required this.tower,
    required this.svc,
  });

  @override
  State<_DesertAttackSheet> createState() => _DesertAttackSheetState();
}

class _DesertAttackSheetState extends State<_DesertAttackSheet> {
  static const int _maxTypes = 10;

  List<CastleUnit> _units = [];
  List<CommanderInfo> _commanders = [];
  Lord? _selectedLord;

  // توزيع الوحدات على 3 أجنجة
  Map<int, int> _leftAmt = {};
  Map<int, int> _middleAmt = {};
  Map<int, int> _rightAmt = {};

  // الدفاعات اليدوية (من تقرير التجسس في اللعبة)
  final DefenderSummary _defenders = DefenderSummary();

  bool _loading = true;
  bool _sending = false;
  bool _spying = false;
  bool _recalling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final catalog = await widget.client.loadCatalog();
      final units = await widget.client.getCastleUnits(
          widget.source.kingdomId, widget.source.areaId, catalog);
      final unlocked = widget.client.getUnlockedForArea(widget.source.areaId);
      final sendable = units
          .where((u) => unlocked.contains(u.wodId) && u.amount > 0)
          .toList();
      final cmds = await widget.client.getCommanders();

      if (!mounted) return;
      setState(() {
        _units = sendable;
        for (final u in sendable) {
          _leftAmt[u.wodId] = 0;
          _middleAmt[u.wodId] = 0;
          _rightAmt[u.wodId] = 0;
        }
        _commanders = cmds;
        final free = cmds.where((c) => !c.isBusy).toList();
        if (free.isNotEmpty) {
          try {
            _selectedLord = free.firstWhere((c) => c.lord.id != 0).lord;
          } catch (_) {
            _selectedLord = free.first.lord;
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _leftTotal => _leftAmt.values.fold(0, (s, e) => s + e);
  int get _middleTotal => _middleAmt.values.fold(0, (s, e) => s + e);
  int get _rightTotal => _rightAmt.values.fold(0, (s, e) => s + e);
  int get _grandTotal => _leftTotal + _middleTotal + _rightTotal;

  int get _selectedTypes {
    final set = <int>{};
    for (final e in _leftAmt.entries) if (e.value > 0) set.add(e.key);
    for (final e in _middleAmt.entries) if (e.value > 0) set.add(e.key);
    for (final e in _rightAmt.entries) if (e.value > 0) set.add(e.key);
    return set.length;
  }

  void _clearAll() {
    for (final k in _leftAmt.keys) _leftAmt[k] = 0;
    for (final k in _middleAmt.keys) _middleAmt[k] = 0;
    for (final k in _rightAmt.keys) _rightAmt[k] = 0;
    setState(() {});
  }

  void _autoSuggest() {
    if (_defenders.isEmpty) {
      _snack('ادخل الدفاعات اليدوية الأول (من تقرير التجسس في اللعبة)',
          color: AppTheme.orange);
      return;
    }
    final suggestion = widget.svc.suggestCounter(
      available: _units,
      defenders: _defenders,
      maxTypes: _maxTypes,
    );
    _clearAll();
    for (final u in suggestion.left) {
      if (u[0] > 0) _leftAmt[u[0]] = u[1];
    }
    for (final u in suggestion.middle) {
      if (u[0] > 0) _middleAmt[u[0]] = u[1];
    }
    for (final u in suggestion.right) {
      if (u[0] > 0) _rightAmt[u[0]] = u[1];
    }
    setState(() {});
    _snack(suggestion.reason, color: kDesertSand);
  }

  Future<void> _spy() async {
    if (_spying) return;
    setState(() => _spying = true);
    final res = await widget.svc.spy(
      tower: widget.tower,
      source: widget.source,
      scoutCount: 11,
    );
    if (!mounted) return;
    setState(() => _spying = false);
    if (res.success) {
      _snack(
          'تم إرسال الجواسيس ✓ (MID=${res.movementId ?? "?"})\n'
          'افتح تقرير التجسس في اللعبة بعد دقيقة',
          color: AppTheme.green);
    } else {
      _snack(res.error ?? 'فشل التجسس', color: AppTheme.red);
    }
  }

  Future<void> _attack() async {
    if (_selectedLord == null) {
      _snack('اختر قائد', color: AppTheme.red);
      return;
    }
    if (_grandTotal == 0) {
      _snack('اختر وحدات', color: AppTheme.orange);
      return;
    }
    if (_selectedTypes > _maxTypes) {
      _snack('الحد الأقصى $_maxTypes أنواع', color: AppTheme.red);
      return;
    }

    final leftUnits = <List<int>>[];
    final middleUnits = <List<int>>[];
    final rightUnits = <List<int>>[];
    for (final u in _units) {
      final l = _leftAmt[u.wodId] ?? 0;
      final m = _middleAmt[u.wodId] ?? 0;
      final r = _rightAmt[u.wodId] ?? 0;
      final total = l + m + r;
      if (total <= 0) continue;
      final available = u.amount;
      final sum = total > available ? available : total;
      if (l > 0) leftUnits.add([u.wodId, (l * sum ~/ total).clamp(0, l)]);
      if (m > 0) middleUnits.add([u.wodId, (m * sum ~/ total).clamp(0, m)]);
      if (r > 0) rightUnits.add([u.wodId, (r * sum ~/ total).clamp(0, r)]);
    }

    setState(() => _sending = true);
    final res = await widget.svc.attack(
      tower: widget.tower,
      source: widget.source,
      lordId: _selectedLord!.id,
      leftUnits: leftUnits,
      middleUnits: middleUnits,
      rightUnits: rightUnits,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (res.success) {
      Navigator.pop(context, true);
    } else {
      _snack(res.error ?? 'فشل الهجوم', color: AppTheme.red);
    }
  }

  Future<void> _recall() async {
    final mid = widget.tower.lastAttackMid;
    if (mid == null || mid <= 0) {
      _snack('مفيش هجوم نشط للانسحاب', color: AppTheme.orange);
      return;
    }
    setState(() => _recalling = true);
    final ok = await widget.svc.recall(mid);
    if (!mounted) return;
    setState(() => _recalling = false);
    if (ok) {
      _snack('تم الانسحاب ✓', color: AppTheme.green);
      Navigator.pop(context, true);
    } else {
      _snack('فشل الانسحاب', color: AppTheme.red);
    }
  }

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg,
            style: const TextStyle(decoration: TextDecoration.none)),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tower;
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.98,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0B0B14),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            _handle(),
            _headerWidget(t),
            const Divider(),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: kDesertSand))
                  : ListView(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      children: [
                        _actionRow(t),
                        const SizedBox(height: 16),
                        _defendersSection(),
                        const SizedBox(height: 16),
                        _lordSection(),
                        const SizedBox(height: 16),
                        _unitsSection(),
                        const SizedBox(height: 16),
                        _summarySection(),
                      ],
                    ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _handle() => Container(
        width: 44, height: 5,
        margin: const EdgeInsets.only(top: 10),
        decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.2),
            borderRadius: BorderRadius.circular(3)),
      );

  Widget _headerWidget(DesertTower t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            gradient: t.isLegendary
                ? const LinearGradient(
                    colors: [kDesertGold, Color(0xFFFFD700)])
                : const LinearGradient(colors: [kDesertSand, kDesertDark]),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.landscape_rounded,
              color: Colors.white, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('برج صحراء ${t.coordsLabel}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.none)),
              if (t.goldCampValue != null)
                Text('GC: ${t.goldCampValue}',
                    style: TextStyle(
                        color: _gcColor(t.goldCampValue),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none)),
            ],
          ),
        ),
        IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: () => Navigator.pop(context)),
      ]),
    );
  }

  Widget _actionRow(DesertTower t) {
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _spying ? null : _spy,
          icon: _spying
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: kDesertSand))
              : const Icon(Icons.visibility_rounded, size: 18),
          label: Text(_spying ? 'جارٍ الإرسال...' : 'تجسس',
              style: const TextStyle(
                  decoration: TextDecoration.none, fontSize: 13)),
          style: OutlinedButton.styleFrom(
            foregroundColor: kDesertSand,
            side: const BorderSide(color: kDesertSand),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      if (t.hasActiveAttack) ...[
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _recalling ? null : _recall,
            icon: _recalling
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.red))
                : const Icon(Icons.replay_rounded, size: 18),
            label: Text(_recalling ? '...' : 'انسحاب',
                style: const TextStyle(
                    decoration: TextDecoration.none, fontSize: 13)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.red,
              side: const BorderSide(color: AppTheme.red),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ],
    ]);
  }

  Widget _defendersSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDesertSand.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.security_rounded,
                color: kDesertSand, size: 18),
            const SizedBox(width: 6),
            const Text('دفاعات العدو (من تقرير التجسس)',
                style: TextStyle(
                    color: kDesertSand,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none)),
            const Spacer(),
            TextButton(
              onPressed: _autoSuggest,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('توزيع ذكي 🎯',
                  style: TextStyle(
                      color: kDesertGold,
                      fontSize: 11,
                      fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 8),
          _defenderRow('الجناح اليسار', _defenders.leftMelee,
              _defenders.leftRanged, (m, r) {
            setState(() {
              _defenders.leftMelee = m;
              _defenders.leftRanged = r;
            });
          }),
          const SizedBox(height: 6),
          _defenderRow('الأمام', _defenders.middleMelee,
              _defenders.middleRanged, (m, r) {
            setState(() {
              _defenders.middleMelee = m;
              _defenders.middleRanged = r;
            });
          }),
          const SizedBox(height: 6),
          _defenderRow('الجناح اليمين', _defenders.rightMelee,
              _defenders.rightRanged, (m, r) {
            setState(() {
              _defenders.rightMelee = m;
              _defenders.rightRanged = r;
            });
          }),
        ],
      ),
    );
  }

  Widget _defenderRow(String label, int melee, int ranged,
      void Function(int melee, int ranged) onChange) {
    return Row(children: [
      SizedBox(
          width: 90,
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  decoration: TextDecoration.none))),
      Expanded(
        child: TextFormField(
          initialValue: melee.toString(),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            labelText: 'melee',
            labelStyle:
                const TextStyle(color: Colors.white54, fontSize: 10),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Colors.white24)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: kDesertSand)),
          ),
          onChanged: (v) => onChange(int.tryParse(v) ?? 0, ranged),
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: TextFormField(
          initialValue: ranged.toString(),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            labelText: 'ranged',
            labelStyle:
                const TextStyle(color: Colors.white54, fontSize: 10),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Colors.white24)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: kDesertGold)),
          ),
          onChanged: (v) => onChange(melee, int.tryParse(v) ?? 0),
        ),
      ),
    ]);
  }

  Widget _lordSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('القائد'),
        const SizedBox(height: 6),
        DropdownButtonHideUnderline(
          child: DropdownButton<Lord>(
            value: _selectedLord,
            isExpanded: true,
            dropdownColor: Theme.of(context).colorScheme.surface,
            items: _commanders
                .where((c) => !c.isBusy)
                .map((c) => DropdownMenuItem(
                      value: c.lord,
                      child: Text(
                          c.lord.id == 0
                              ? 'اللورد الرئيسي'
                              : c.lord.displayName,
                          style: const TextStyle(
                              decoration: TextDecoration.none,
                              fontSize: 13)),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _selectedLord = v),
          ),
        ),
      ],
    );
  }

  Widget _unitsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _sectionLabel(
              'الوحدات ($_selectedTypes/$_maxTypes · $_grandTotal)'),
          const Spacer(),
          TextButton(
              onPressed: _clearAll,
              child: const Text('مسح',
                  style:
                      TextStyle(fontSize: 11, color: AppTheme.red))),
        ]),
        const SizedBox(height: 4),
        ..._units.map((u) => _unitRow(u)),
      ],
    );
  }

  Widget _unitRow(CastleUnit u) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: u.roleColor.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(u.icon, color: u.roleColor, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(u.displayName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.none)),
            ),
            Text('متاح: ${u.amount}',
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    decoration: TextDecoration.none)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            _wingField('L', _leftAmt[u.wodId] ?? 0, u.amount, (v) {
              setState(() => _leftAmt[u.wodId] = v);
            }, kDesertSand),
            const SizedBox(width: 6),
            _wingField('M', _middleAmt[u.wodId] ?? 0, u.amount, (v) {
              setState(() => _middleAmt[u.wodId] = v);
            }, kDesertGold),
            const SizedBox(width: 6),
            _wingField('R', _rightAmt[u.wodId] ?? 0, u.amount, (v) {
              setState(() => _rightAmt[u.wodId] = v);
            }, kDesertSand),
          ]),
        ],
      ),
    );
  }

  Widget _wingField(String label, int value, int max,
      ValueChanged<int> onChange, Color color) {
    return Expanded(
      child: SizedBox(
        height: 34,
        child: TextFormField(
          initialValue: value.toString(),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.center,
          style: TextStyle(
              color: value > 0 ? color : Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: label,
            hintStyle:
                const TextStyle(color: Colors.white30, fontSize: 10),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:
                    BorderSide(color: value > 0 ? color : Colors.white12)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: color)),
          ),
          onChanged: (v) {
            final n = int.tryParse(v) ?? 0;
            onChange(n.clamp(0, max));
          },
        ),
      ),
    );
  }

  Widget _summarySection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        _summaryItem('يسار', _leftTotal, kDesertSand),
        _summaryItem('أمام', _middleTotal, kDesertGold),
        _summaryItem('يمين', _rightTotal, kDesertSand),
        _summaryItem('إجمالي', _grandTotal, Colors.white),
      ]),
    );
  }

  Widget _summaryItem(String label, int value, Color color) {
    return Expanded(
      child: Column(children: [
        Text(label,
            style: const TextStyle(
                color: Colors.white54,
                fontSize: 10,
                decoration: TextDecoration.none)),
        const SizedBox(height: 2),
        Text(value.toString(),
            style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none)),
      ]),
    );
  }

  Widget _sectionLabel(String s) => Text(s,
      style: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          decoration: TextDecoration.none));

  Widget _footer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _sending || _loading ? null : _attack,
            icon: _sending
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.gavel_rounded),
            label: Text(
                _sending
                    ? 'جارٍ الإرسال...'
                    : 'هجوم ($_grandTotal)',
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    decoration: TextDecoration.none)),
            style: ElevatedButton.styleFrom(
              backgroundColor: kDesertSand,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ),
    );
  }
}