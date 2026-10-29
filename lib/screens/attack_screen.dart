import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/services/attack_service.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

class AttackScreen extends StatefulWidget {
  final GgeClient client;
  const AttackScreen({super.key, required this.client});

  @override
  State<AttackScreen> createState() => _AttackScreenState();
}

class _AttackScreenState extends State<AttackScreen> {
  late final AttackService _svc;
  late AttackFilterSettings _settings;

  List<OwnedCastle> _castles = [];
  OwnedCastle? _source;
  List<NpcTarget> _targets = [];
  bool _scanning = false;
  bool _enriching = false;
  int _scanDone = 0, _scanTotal = 0;
  bool _loading = true;

  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _svc = AttackService(widget.client);
    _init();
  }

  Future<void> _init() async {
    _settings = await AttackFilterSettings.load();
    try {
      final castles = await widget.client.getCastles();
      final preferred = castles.where((c) =>
          c.areaType == 12 || c.areaType == 1).toList();
      if (!mounted) return;
      setState(() {
        _castles = preferred.isNotEmpty ? preferred : castles;
        if (_castles.isNotEmpty) {
          try {
            _source = _castles.firstWhere((c) => c.areaId == _settings.sourceAreaId);
          } catch (_) {
            try {
              _source = _castles.firstWhere((c) => c.kingdomId == 4);
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
    _startAutoRefresh();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!mounted || _scanning || _enriching) return;
      // refresh stale only
      final stale = _targets.where((t) => t.isEnriched && t.isStaleEnrichment).toList();
      if (stale.isEmpty) return;
      _enrichBatch(stale.take(10).toList());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    if (_source == null) {
      _snack('اختر قلعة مصدر أولاً', color: AppTheme.red);
      return;
    }
    if (_scanning) return;

    setState(() {
      _scanning = true;
      _targets = [];
      _scanDone = 0;
      _scanTotal = 0;
    });

    try {
      final found = await _svc.scanArea(
        source: _source!,
        radiusTiles: _settings.radiusTiles,
        onProgress: (d, t) {
          if (!mounted) return;
          setState(() { _scanDone = d; _scanTotal = t; });
        },
      );

      // Sort: level 6 first (they have GC)
      found.sort((a, b) {
        final lv = b.rawLevel.compareTo(a.rawLevel);
        if (lv != 0) return lv;
        return a.distanceFromSource.compareTo(b.distanceFromSource);
      });

      if (!mounted) return;
      setState(() {
        _targets = found;
        _scanning = false;
      });

      if (found.isEmpty) {
        _snack('مفيش أهداف في النطاق ده', color: AppTheme.orange);
        return;
      }

      _enrichBatch(found.take(20).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      _snack('$e', color: AppTheme.red);
    }
  }

  Future<void> _enrichBatch(List<NpcTarget> batch) async {
    if (_enriching || batch.isEmpty) return;
    setState(() => _enriching = true);

    for (final t in batch) {
      if (!mounted) break;
      try {
        final enriched = await _svc.enrich(t);
        if (!mounted) break;
        setState(() {
          final idx = _targets.indexWhere(
              (x) => x.areaId == t.areaId && x.x == t.x && x.y == t.y);
          if (idx >= 0) _targets[idx] = enriched;
        });
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: 800 + (DateTime.now().millisecond % 400)));
    }

    if (mounted) setState(() => _enriching = false);
  }

  // ✅ فلترة بـ UI level
  List<NpcTarget> get _filtered {
    var list = _targets
        .where((t) => _settings.visibleUiLevels.contains(t.uiLevel))
        .toList();
    if (_settings.minGC > 0) {
      list = list.where((t) => (t.goldCampValue ?? 0) >= _settings.minGC).toList();
    }
    if (_settings.onlyLegendary) {
      list = list.where((t) => t.isLegendary).toList();
    }

    switch (_settings.sortBy) {
      case 'gc':
        list.sort((a, b) {
          final g = (b.goldCampValue ?? 0).compareTo(a.goldCampValue ?? 0);
          if (g != 0) return g;
          final l = b.rawLevel.compareTo(a.rawLevel);
          if (l != 0) return l;
          return a.distanceFromSource.compareTo(b.distanceFromSource);
        });
        break;
      case 'level':
        list.sort((a, b) {
          final l = b.rawLevel.compareTo(a.rawLevel);
          if (l != 0) return l;
          return a.distanceFromSource.compareTo(b.distanceFromSource);
        });
        break;
      case 'distance':
        list.sort((a, b) => a.distanceFromSource.compareTo(b.distanceFromSource));
        break;
      case 'as':
        list.sort((a, b) {
          final asA = a.attacksRemaining ?? 999;
          final asB = b.attacksRemaining ?? 999;
          return asB.compareTo(asA);
        });
        break;
    }
    return list;
  }

  Future<void> _openAttackSheet(NpcTarget target) async {
    if (_source == null) {
      _snack('اختر قلعة مصدر', color: AppTheme.red);
      return;
    }

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AttackSheet(
        client: widget.client,
        source: _source!,
        target: target,
      ),
    );

    if (result == true && mounted) {
      setState(() {
        final idx = _targets.indexWhere(
            (x) => x.areaId == target.areaId && x.x == target.x && x.y == target.y);
        if (idx >= 0 && _targets[idx].attacksRemaining != null) {
          _targets[idx] = _targets[idx].copyWith(
            attacksRemaining: (_targets[idx].attacksRemaining! - 1).clamp(0, 9999),
          );
        }
      });
      try {
        final fresh = await _svc.enrich(target);
        if (mounted) {
          setState(() {
            final idx = _targets.indexWhere(
                (x) => x.areaId == target.areaId && x.x == target.x && x.y == target.y);
            if (idx >= 0) _targets[idx] = fresh;
          });
        }
      } catch (_) {}
    }
  }

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(decoration: TextDecoration.none)),
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
                  const Expanded(child: Center(child: CircularProgressIndicator(color: AppTheme.purple)))
                else ...[
                  _sourcePicker(context),
                  _filterBar(context),
                  if (_scanning || _enriching) _progressBar(context),
                  Expanded(
                    child: filtered.isEmpty
                        ? _emptyView(context)
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                            itemCount: filtered.length,
                            itemBuilder: (_, i) => FadeSlideIn(
                              delay: Duration(milliseconds: 30 + i * 30),
                              child: _targetCard(context, filtered[i]),
                            ),
                          ),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            left: 16, right: 16, bottom: 16,
            child: GradientButton(
              label: _scanning
                  ? 'جارٍ المسح ($_scanDone/$_scanTotal)'
                  : 'مسح المنطقة (${_settings.radiusTiles} tile)',
              icon: Icons.radar_rounded,
              gradient: AppTheme.cosmosGradient,
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
          AppIconBtn(icon: Icons.arrow_back_rounded,
              onTap: () => Navigator.pop(context), size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('هجوم على NPC', style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800,
                    color: AppTheme.textColor(context), letterSpacing: -0.3,
                    decoration: TextDecoration.none)),
                Text('${_targets.length} هدف · ${_filtered.length} ظاهر',
                    style: TextStyle(fontSize: 11,
                        color: AppTheme.subTextColor(context),
                        decoration: TextDecoration.none)),
              ],
            ),
          ),
          if (_enriching)
            const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.teal)),
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
            Container(width: 36, height: 36,
                decoration: BoxDecoration(color: AppTheme.teal.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.castle_rounded, color: AppTheme.teal, size: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<OwnedCastle>(
                  value: _source, isExpanded: true, isDense: true,
                  dropdownColor: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: AppTheme.textColor(context)),
                  items: _castles.map((c) => DropdownMenuItem(
                    value: c,
                    child: Text(c.fullLabel, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppTheme.textColor(context), fontSize: 12)),
                  )).toList(),
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
            _filterChip(context, icon: Icons.tune_rounded, label: 'فلترة',
                onTap: _openFilterSheet),
            const SizedBox(width: 8),
            _sortChip(context),
            const SizedBox(width: 8),
            _distanceChip(context),
            const SizedBox(width: 8),
            if (_settings.onlyLegendary)
              _activeChip(context, 'GC 75 فقط'),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(BuildContext context, {required IconData icon,
      required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.purple.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.purple.withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: AppTheme.purple, size: 14),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: AppTheme.purple, fontSize: 11,
              fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
        ]),
      ),
    );
  }

  Widget _sortChip(BuildContext context) {
    final labels = {'gc': 'Gold Camp', 'level': 'المستوى', 'distance': 'المسافة', 'as': 'هجمات متبقية'};
    return PopupMenuButton<String>(
      onSelected: (v) {
        setState(() { _settings.sortBy = v; _settings.save(); });
      },
      itemBuilder: (_) => labels.entries.map((e) => PopupMenuItem(
          value: e.key,
          child: Row(children: [
            if (_settings.sortBy == e.key)
              const Icon(Icons.check, size: 14, color: AppTheme.green),
            const SizedBox(width: 6),
            Text(e.value, style: TextStyle(color: AppTheme.textColor(context))),
          ]))).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.teal.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.teal.withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.sort_rounded, color: AppTheme.teal, size: 14),
          const SizedBox(width: 6),
          Text(labels[_settings.sortBy] ?? '', style: const TextStyle(
              color: AppTheme.teal, fontSize: 11, fontWeight: FontWeight.bold,
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
          Text('${_settings.radiusTiles} tile', style: const TextStyle(
              color: AppTheme.orange, fontSize: 11, fontWeight: FontWeight.bold,
              decoration: TextDecoration.none)),
        ]),
      ),
    );
  }

  Widget _activeChip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFFD4AF37), Color(0xFFFFD700)]),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: const TextStyle(color: Colors.black, fontSize: 11,
          fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
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
          backgroundColor: AppTheme.teal.withOpacity(0.1),
          valueColor: const AlwaysStoppedAnimation(AppTheme.teal),
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
            Container(padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                    color: AppTheme.teal.withOpacity(0.12),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.teal.withOpacity(0.3))),
                child: Icon(Icons.radar_rounded, size: 48,
                    color: AppTheme.teal.withOpacity(0.7))),
            const SizedBox(height: 16),
            Text('مفيش أهداف لسه', style: TextStyle(color: AppTheme.textColor(context),
                fontSize: 14, fontWeight: FontWeight.bold,
                decoration: TextDecoration.none)),
            const SizedBox(height: 4),
            Text('دوس "مسح المنطقة" عشان تبدأ', textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.subTextColor(context),
                    fontSize: 11, decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }

  Widget _targetCard(BuildContext context, NpcTarget t) {
    final legendary = t.isLegendary;
    final hasGold = t.hasGold;
    final borderColor = legendary
        ? const Color(0xFFD4AF37)
        : hasGold
            ? AppTheme.orange
            : AppTheme.subTextColor(context).withOpacity(0.2);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _openAttackSheet(t),
        child: Container(
          decoration: BoxDecoration(
            gradient: legendary
                ? const LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [Color(0x44D4AF37), Color(0x11FFD700)])
                : null,
            color: legendary ? null
                : (AppTheme.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.03)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: legendary ? 1.6 : 1.2),
            boxShadow: legendary
                ? [BoxShadow(color: const Color(0xFFD4AF37).withOpacity(0.3),
                    blurRadius: 18, offset: const Offset(0, 6))]
                : null,
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  gradient: legendary
                      ? const LinearGradient(colors: [Color(0xFFD4AF37), Color(0xFFFFD700)])
                      : null,
                  color: legendary ? null : AppTheme.teal.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  legendary ? Icons.emoji_events_rounded : Icons.local_fire_department_rounded,
                  color: legendary ? Colors.black : AppTheme.teal,
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
                        Text('(${t.x},${t.y})', style: TextStyle(
                            color: AppTheme.textColor(context),
                            fontWeight: FontWeight.bold, fontSize: 13,
                            decoration: TextDecoration.none)),
                        const SizedBox(width: 8),
                        _levelBadge(t.uiLevel),
                        // ✅ GC badge — only if has GC (>0)
                        if (t.isEnriched && hasGold) ...[
                          const SizedBox(width: 6),
                          _gcBadge(t.goldCampValue!, legendary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.straighten_rounded, size: 11,
                            color: AppTheme.subTextColor(context)),
                        const SizedBox(width: 3),
                        Text('${t.distanceFromSource.toStringAsFixed(0)} tile',
                            style: TextStyle(color: AppTheme.subTextColor(context),
                                fontSize: 10.5, decoration: TextDecoration.none)),
                        const SizedBox(width: 8),
                        if (t.isEnriched && t.attacksRemaining != null) ...[
                          const Icon(Icons.gavel_rounded, size: 11, color: AppTheme.red),
                          const SizedBox(width: 3),
                          Text('${t.attacksRemaining} هجمة',
                              style: const TextStyle(color: AppTheme.red,
                                  fontSize: 10.5, fontWeight: FontWeight.bold,
                                  decoration: TextDecoration.none)),
                        ] else if (!t.isEnriched) ...[
                          const Icon(Icons.hourglass_empty_rounded, size: 11,
                              color: AppTheme.subTextColor),
                          const SizedBox(width: 3),
                          Text('جارٍ الجلب...', style: TextStyle(
                              color: AppTheme.subTextColor(context).withOpacity(0.7),
                              fontSize: 10.5, decoration: TextDecoration.none)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppTheme.subTextColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _levelBadge(int lvl) {
    final color = lvl >= 80
        ? const Color(0xFFD4AF37)
        : lvl >= 70
            ? AppTheme.orange
            : lvl >= 60
                ? AppTheme.blue
                : lvl >= 50
                    ? AppTheme.teal
                    : AppTheme.subTextColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text('Lv $lvl', style: TextStyle(color: color, fontSize: 10,
          fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
    );
  }

  Widget _gcBadge(int gc, bool legendary) {
    final color = legendary ? const Color(0xFFD4AF37) : AppTheme.orange;
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
        Text('GC $gc', style: TextStyle(color: color, fontSize: 10,
            fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
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
        onChanged: () { setState(() {}); _settings.save(); },
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
          title: const Text('نطاق المسح', style: TextStyle(decoration: TextDecoration.none)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${temp.toInt()} tile', style: const TextStyle(fontSize: 22,
                fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
            Slider(value: temp, min: 20, max: 200, divisions: 18,
                activeColor: AppTheme.orange,
                onChanged: (v) => setSt(() => temp = v)),
            Text('اكبر نطاق = طلبات أكتر = خطر بان أعلى',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10.5,
                    color: AppTheme.subTextColor(ctx),
                    decoration: TextDecoration.none)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () {
                setState(() { _settings.radiusTiles = temp.toInt(); _settings.save(); });
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
//  Filter Sheet — UI levels 40-80
// ═══════════════════════════════════════════════════════════
class _FilterSheet extends StatefulWidget {
  final AttackFilterSettings settings;
  final VoidCallback onChanged;
  const _FilterSheet({required this.settings, required this.onChanged});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    const levels = [40, 50, 60, 70, 80];

    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
      decoration: const BoxDecoration(
        color: Color(0xFF0B0B14),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 44, height: 5, margin: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3))),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Icon(Icons.tune_rounded, color: AppTheme.teal, size: 20),
                const SizedBox(width: 8),
                const Text('فلترة', style: TextStyle(color: Colors.white,
                    fontSize: 16, fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none)),
                const Spacer(),
                TextButton(onPressed: () => Navigator.pop(context),
                    child: const Text('تم', style: TextStyle(color: AppTheme.teal))),
              ]),
            ),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('المستويات', style: TextStyle(color: Colors.white70,
                      fontWeight: FontWeight.bold, fontSize: 13,
                      decoration: TextDecoration.none)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: levels.map((lvl) {
                    final active = s.visibleUiLevels.contains(lvl);
                    final color = lvl == 80
                        ? const Color(0xFFD4AF37)
                        : lvl == 70
                            ? AppTheme.orange
                            : AppTheme.teal;
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          if (active) s.visibleUiLevels.remove(lvl);
                          else s.visibleUiLevels.add(lvl);
                        });
                        widget.onChanged();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: active ? color.withOpacity(0.25) : Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: active ? color : Colors.white24),
                        ),
                        child: Text('Lv $lvl', style: TextStyle(
                            color: active ? color : Colors.white70,
                            fontWeight: FontWeight.bold, fontSize: 12,
                            decoration: TextDecoration.none)),
                      ),
                    );
                  }).toList()),
                  const SizedBox(height: 20),
                  const Text('GC الأدنى', style: TextStyle(color: Colors.white70,
                      fontWeight: FontWeight.bold, fontSize: 13,
                      decoration: TextDecoration.none)),
                  const SizedBox(height: 8),
                  Row(children: [
                    _gcChip(s, 0, 'الكل'),
                    const SizedBox(width: 8),
                    _gcChip(s, 60, 'GC 60+'),
                    const SizedBox(width: 8),
                    _gcChip(s, 75, 'GC 75 (ذهبي)'),
                  ]),
                  const SizedBox(height: 20),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('GC 75 فقط', style: TextStyle(color: Colors.white,
                        fontSize: 13, fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none)),
                    subtitle: const Text('يظهر بس اللي عندهم GC=75 (لفل 80)',
                        style: TextStyle(color: Colors.white54, fontSize: 11,
                            decoration: TextDecoration.none)),
                    value: s.onlyLegendary,
                    activeColor: const Color(0xFFD4AF37),
                    onChanged: (v) { setState(() => s.onlyLegendary = v); widget.onChanged(); },
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gcChip(AttackFilterSettings s, int val, String label) {
    final active = s.minGC == val;
    final color = val == 75 ? const Color(0xFFD4AF37) : AppTheme.orange;
    return GestureDetector(
      onTap: () { setState(() => s.minGC = val); widget.onChanged(); },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.25) : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? color : Colors.white24),
        ),
        child: Text(label, style: TextStyle(
            color: active ? color : Colors.white70,
            fontWeight: FontWeight.bold, fontSize: 11,
            decoration: TextDecoration.none)),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  Attack Sheet
// ═══════════════════════════════════════════════════════════
class _AttackSheet extends StatefulWidget {
  final GgeClient client;
  final OwnedCastle source;
  final NpcTarget target;
  const _AttackSheet({required this.client, required this.source, required this.target});

  @override
  State<_AttackSheet> createState() => _AttackSheetState();
}

class _AttackSheetState extends State<_AttackSheet> {
  static const int _maxTypes = 10;

  late final AttackService _svc;
  List<CastleUnit> _units = [];
  Map<int, TextEditingController> _amtCtrl = {};
  List<CommanderInfo> _commanders = [];
  Lord? _selectedLord;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _svc = AttackService(widget.client);
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
          _amtCtrl[u.wodId] = TextEditingController(text: '0');
        }
        _commanders = cmds;
        final free = cmds.where((c) => !c.isBusy).toList();
        if (free.isNotEmpty) {
          try {
            _selectedLord = free.firstWhere((c) => c.lord.id == 0).lord;
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

  @override
  void dispose() {
    for (final c in _amtCtrl.values) { c.dispose(); }
    super.dispose();
  }

  int get _selectedTypes => _units.where((u) {
    final a = int.tryParse(_amtCtrl[u.wodId]?.text ?? '0') ?? 0;
    return a > 0;
  }).length;

  int get _totalUnits => _units.fold<int>(0, (s, u) {
    return s + (int.tryParse(_amtCtrl[u.wodId]?.text ?? '0') ?? 0);
  });

  void _selectAll() {
    final offensive = _units.where((u) => u.isCombat && !u.isDefensive).toList();
    final defensive = _units.where((u) => u.isCombat && u.isDefensive).toList();
    final ordered = [...offensive, ...defensive];
    for (final c in _amtCtrl.values) { c.text = '0'; }
    for (final u in ordered.take(_maxTypes)) {
      _amtCtrl[u.wodId]?.text = u.amount.toString();
    }
    setState(() {});
  }

  void _clearAll() {
    for (final c in _amtCtrl.values) { c.text = '0'; }
    setState(() {});
  }

  Future<void> _send() async {
    if (_selectedLord == null) {
      _snack('اختر قائد', color: AppTheme.red);
      return;
    }
    final units = <List<int>>[];
    for (final u in _units) {
      final a = int.tryParse(_amtCtrl[u.wodId]?.text ?? '0') ?? 0;
      if (a > 0) units.add([u.wodId, a.clamp(0, u.amount)]);
    }
    if (units.isEmpty) {
      _snack('اختر وحدات', color: AppTheme.orange);
      return;
    }
    if (units.length > _maxTypes) {
      _snack('الحد الأقصى $_maxTypes أنواع', color: AppTheme.red);
      return;
    }

    setState(() => _sending = true);
    final result = await _svc.attack(
      target: widget.target,
      source: widget.source,
      units: units,
      lordId: _selectedLord!.id,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    if (result.success) {
      Navigator.pop(context, true);
    } else {
      String msg = result.error ?? 'فشل';
      if (msg.contains('UNIT_NOT_SENDABLE_91')) msg = 'وحدة مش قابلة للإرسال';
      else if (msg.contains('LORD_BUSY_218')) msg = 'القائد مشغول';
      else if (msg.contains('LORD_UNAVAILABLE')) msg = 'القائد غير متاح';
      else if (msg.contains('MAX_MOVEMENTS_181')) msg = 'وصلت للحد الأقصى للحركات';
      _snack(msg, color: AppTheme.red);
    }
  }

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(decoration: TextDecoration.none)),
        backgroundColor: color, behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.target;
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0B0B14),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(width: 44, height: 5, margin: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3))),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(children: [
                Container(width: 40, height: 40,
                    decoration: BoxDecoration(
                      gradient: t.isLegendary
                          ? const LinearGradient(colors: [Color(0xFFD4AF37), Color(0xFFFFD700)])
                          : AppTheme.dangerGradient,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.gavel_rounded, color: Colors.white, size: 20)),
                const SizedBox(width: 10),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('(${t.x},${t.y}) · Lv ${t.uiLevel}',
                        style: const TextStyle(color: Colors.white, fontSize: 15,
                            fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
                    if (t.isEnriched && t.hasGold)
                      Text('GC ${t.goldCampValue} · ${t.attacksRemaining ?? 0} هجمة',
                          style: const TextStyle(color: Colors.white70, fontSize: 11,
                              decoration: TextDecoration.none))
                    else if (t.isEnriched)
                      Text('${t.attacksRemaining ?? 0} هجمة',
                          style: const TextStyle(color: Colors.white70, fontSize: 11,
                              decoration: TextDecoration.none)),
                  ],
                )),
                IconButton(icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context)),
              ]),
            ),
            const Divider(),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: AppTheme.purple))
                  : ListView(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      children: [
                        _sectionLabel('القائد'),
                        const SizedBox(height: 8),
                        DropdownButtonHideUnderline(
                          child: DropdownButton<Lord>(
                            value: _selectedLord, isExpanded: true,
                            dropdownColor: Theme.of(context).colorScheme.surface,
                            items: _commanders.where((c) => !c.isBusy)
                                .map((c) => DropdownMenuItem(
                                  value: c.lord,
                                  child: Text(
                                      c.lord.id == 0 ? 'اللورد الرئيسي' : c.lord.displayName,
                                      style: const TextStyle(decoration: TextDecoration.none)),
                                )).toList(),
                            onChanged: (v) => setState(() => _selectedLord = v),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(children: [
                          _sectionLabel('الوحدات ($_selectedTypes/$_maxTypes · $_totalUnits)'),
                          const Spacer(),
                          TextButton(onPressed: _selectAll,
                              child: const Text('تحديد الكل', style: TextStyle(fontSize: 11))),
                          TextButton(onPressed: _clearAll,
                              child: const Text('مسح', style: TextStyle(fontSize: 11, color: AppTheme.red))),
                        ]),
                        const SizedBox(height: 4),
                        ..._units.map((u) => _unitRow(u)),
                      ],
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity, height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _sending || _loading ? null : _send,
                    icon: _sending
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.gavel_rounded),
                    label: Text(_sending ? 'جارٍ الإرسال...' : 'هجوم ($_totalUnits)',
                        style: const TextStyle(fontWeight: FontWeight.bold,
                            fontSize: 15, decoration: TextDecoration.none)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.red,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String s) => Text(s, style: const TextStyle(color: Colors.white70,
      fontSize: 12, fontWeight: FontWeight.bold, decoration: TextDecoration.none));

  Widget _unitRow(CastleUnit u) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: u.roleColor.withOpacity(0.2)),
      ),
      child: Row(children: [
        Icon(u.icon, color: u.roleColor, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.unitName(u.displayName), style: const TextStyle(color: Colors.white,
                fontSize: 12, fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
            Text('متاح: ${u.amount}', style: const TextStyle(color: Colors.white54,
                fontSize: 10, decoration: TextDecoration.none)),
          ],
        )),
        SizedBox(width: 70, height: 34, child: TextField(
          controller: _amtCtrl[u.wodId],
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 12,
              fontWeight: FontWeight.bold, decoration: TextDecoration.none),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            hintText: '0',
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Colors.white12),
            ),
          ),
          onChanged: (_) => setState(() {}),
        )),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: () { _amtCtrl[u.wodId]?.text = u.amount.toString(); setState(() {}); },
          child: Container(width: 30, height: 30,
              decoration: BoxDecoration(color: AppTheme.teal.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6)),
              child: const Icon(Icons.keyboard_double_arrow_up_rounded,
                  color: AppTheme.teal, size: 14)),
        ),
      ]),
    );
  }
}