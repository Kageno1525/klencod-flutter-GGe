import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/services/desert_attack_service.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

const Color kDesertSand = Color(0xFFE8A317);
const Color kDesertDark = Color(0xFF8B5A2B);

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
          setState(() {
            _scanDone = d;
            _scanTotal = t;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _towers = found;
        _scanning = false;
      });
      if (found.isEmpty) {
        _snack('مفيش أبراج صحراء في النطاق ده', color: AppTheme.orange);
      } else {
        _snack('تم العثور على ${found.length} برج',
            color: AppTheme.green);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      _snack('$e', color: AppTheme.red);
    }
  }

  List<DesertTower> get _filtered {
    var list = _towers.toList();
    switch (_settings.sortBy) {
      case 'distance':
        list.sort(
            (a, b) => a.distanceFromSource.compareTo(b.distanceFromSource));
        break;
      case 'spy':
        // اللي اتجسس عليهم مؤخراً الأول
        list.sort((a, b) {
          if (a.lastSpyAt == null && b.lastSpyAt == null) {
            return a.distanceFromSource.compareTo(b.distanceFromSource);
          }
          if (a.lastSpyAt == null) return 1;
          if (b.lastSpyAt == null) return -1;
          return b.lastSpyAt!.compareTo(a.lastSpyAt!);
        });
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
        onSpySent: (mid) {
          // تحديث الكارت بعد التجسس
          if (!mounted) return;
          setState(() {
            final idx =
                _towers.indexWhere((x) => x.x == tower.x && x.y == tower.y);
            if (idx >= 0) {
              _towers[idx] = _towers[idx].copyWith(
                lastSpyAt: DateTime.now(),
                lastSpyMid: mid,
              );
            }
          });
        },
      ),
    );
    if (result == true && mounted) {
      // هجوم اتبعت — نحدّث الكارت
      setState(() {
        final idx =
            _towers.indexWhere((x) => x.x == tower.x && x.y == tower.y);
        if (idx >= 0) {
          _towers[idx] = _towers[idx].copyWith(
            lastAttackAt: DateTime.now(),
            lastAttackMid: -1,
          );
        }
      });
    }
  }

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg,
            style: const TextStyle(decoration: TextDecoration.none),
            maxLines: 3),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
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
                      child: CircularProgressIndicator(color: kDesertSand),
                    ),
                  )
                else ...[
                  _sourcePicker(context),
                  _filterBar(context),
                  if (_scanning) _progressBar(context),
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
              gradient:
                  const LinearGradient(colors: [kDesertSand, kDesertDark]),
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
                Text('${_towers.length} برج',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subTextColor(context),
                        decoration: TextDecoration.none)),
              ],
            ),
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
    final labels = {'distance': 'المسافة', 'spy': 'آخر تجسس'};
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          _chip(context,
              icon: Icons.sort_rounded,
              label: 'ترتيب: ${labels[_settings.sortBy] ?? ""}',
              color: kDesertSand,
              onTap: () => _openSortMenu(context)),
          const SizedBox(width: 8),
          _chip(context,
              icon: Icons.place_rounded,
              label: '${_settings.radiusTiles} tile',
              color: AppTheme.orange,
              onTap: () => _openRadiusSheet(context)),
        ],
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
    final spied = t.isSpied;
    final borderColor = spied
        ? kDesertGold
        : AppTheme.subTextColor(context).withOpacity(0.2);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _openTowerSheet(t),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.isDark(context)
                ? Colors.white.withOpacity(0.04)
                : Colors.black.withOpacity(0.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: spied ? 1.6 : 1.2),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: kDesertSand.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.landscape_rounded,
                    color: kDesertSand, size: 22),
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
                                fontSize: 15,
                                decoration: TextDecoration.none)),
                        const SizedBox(width: 8),
                        if (spied && t.isSpyRecent)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: Colors.green.withOpacity(0.6)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.visibility_rounded,
                                    size: 10, color: Colors.green),
                                const SizedBox(width: 3),
                                Text('تجسس ${t.spyTimeLabel}',
                                    style: const TextStyle(
                                        color: Colors.green,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        decoration: TextDecoration.none)),
                              ],
                            ),
                          )
                        else if (spied)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.grey.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('تجسس قديم',
                                style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 9,
                                    decoration: TextDecoration.none)),
                          ),
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

  void _openSortMenu(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
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
                margin: const EdgeInsets.only(top: 10, bottom: 12),
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3)),
              ),
              ListTile(
                leading: const Icon(Icons.place_rounded, color: kDesertSand),
                title: const Text('المسافة',
                    style: TextStyle(
                        color: Colors.white,
                        decoration: TextDecoration.none)),
                trailing: _settings.sortBy == 'distance'
                    ? const Icon(Icons.check, color: AppTheme.green)
                    : null,
                onTap: () => Navigator.pop(context, 'distance'),
              ),
              ListTile(
                leading:
                    const Icon(Icons.visibility_rounded, color: kDesertSand),
                title: const Text('آخر تجسس',
                    style: TextStyle(
                        color: Colors.white,
                        decoration: TextDecoration.none)),
                trailing: _settings.sortBy == 'spy'
                    ? const Icon(Icons.check, color: AppTheme.green)
                    : null,
                onTap: () => Navigator.pop(context, 'spy'),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      setState(() {
        _settings.sortBy = selected;
        _settings.save();
      });
    }
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
                  (v / kDesertRadiusStep).round() *
                      kDesertRadiusStep.toDouble()),
            ),
            Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
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

const Color kDesertGold = Color(0xFFD4AF37);

// ═══════════════════════════════════════════════════════════
//  Attack Sheet
// ═══════════════════════════════════════════════════════════
class _DesertAttackSheet extends StatefulWidget {
  final GgeClient client;
  final OwnedCastle source;
  final DesertTower tower;
  final DesertAttackService svc;
  final void Function(int? mid) onSpySent;

  const _DesertAttackSheet({
    required this.client,
    required this.source,
    required this.tower,
    required this.svc,
    required this.onSpySent,
  });

  @override
  State<_DesertAttackSheet> createState() => _DesertAttackSheetState();
}

class _DesertAttackSheetState extends State<_DesertAttackSheet> {
  static const int _maxTypes = 10;

  List<CastleUnit> _units = [];
  List<CommanderInfo> _commanders = [];
  Lord? _selectedLord;

  Map<int, int> _leftAmt = {};
  Map<int, int> _middleAmt = {};
  Map<int, int> _rightAmt = {};

  final DefenderSummary _defenders = DefenderSummary();

  bool _loading = true;
  bool _sending = false;
  bool _spying = false;
  bool _recalling = false;

  // cooldown للتجسس (30 ثانية)
  DateTime? _lastSpyLocalAt;

  @override
  void initState() {
    super.initState();
    _lastSpyLocalAt = widget.tower.lastSpyAt;
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

  bool get _canSpy {
    if (_spying) return false;
    if (_lastSpyLocalAt == null) return true;
    return DateTime.now().difference(_lastSpyLocalAt!).inSeconds >= 30;
  }

  Future<void> _spy() async {
    if (!_canSpy) {
      final remaining =
          30 - DateTime.now().difference(_lastSpyLocalAt!).inSeconds;
      _snack('انتظر $remaining ثانية قبل تجسس جديد', color: AppTheme.orange);
      return;
    }
    setState(() => _spying = true);

    final res = await widget.svc.spy(
      tower: widget.tower,
      source: widget.source,
      scoutCount: 11,
    );

    if (!mounted) return;
    setState(() {
      _spying = false;
      if (res.success) _lastSpyLocalAt = DateTime.now();
    });

    if (res.success) {
      widget.onSpySent(res.movementId);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Theme.of(ctx).colorScheme.surface,
          title: const Row(children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 8),
            Text('تم إرسال الجواسيس',
                style: TextStyle(decoration: TextDecoration.none)),
          ]),
          content: Text(
            'الهدف: (${widget.tower.x},${widget.tower.y})\n'
            'MID: ${res.movementId ?? "?"}\n'
            'عدد الجواسيس: ${res.scoutCount ?? 11}\n\n'
            '⚠️ مهم: التقرير مش هيظهر هنا في التطبيق.\n'
            'افتح اللعبة → الرسائل ✉️ → تقارير\n'
            'هتلاقي تقرير التجسس على البرج ده.',
            style: const TextStyle(
                decoration: TextDecoration.none, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('فهمت'),
            ),
          ],
        ),
      );
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
            gradient: const LinearGradient(
                colors: [kDesertSand, kDesertDark]),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.landscape_rounded,
              color: Colors.white, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text('برج صحراء ${t.coordsLabel}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none)),
        ),
        IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: () => Navigator.pop(context)),
      ]),
    );
  }

  Widget _actionRow(DesertTower t) {
    final spyLabel = _spying
        ? 'جارٍ الإرسال...'
        : (_canSpy ? 'تجسس على ${t.coordsLabel}' : 'انتظر قبل تجسس جديد');
    return Row(children: [
      Expanded(
        flex: 2,
        child: OutlinedButton.icon(
          onPressed: _canSpy ? _spy : null,
          icon: _spying
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: kDesertSand))
              : const Icon(Icons.visibility_rounded, size: 18),
          label: Text(spyLabel,
              style: const TextStyle(
                  decoration: TextDecoration.none, fontSize: 12)),
          style: OutlinedButton.styleFrom(
            foregroundColor: kDesertSand,
            side: const BorderSide(color: kDesertSand),
            padding: const EdgeInsets.symmetric(vertical: 14),
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
                    decoration: TextDecoration.none, fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.red,
              side: const BorderSide(color: AppTheme.red),
              padding: const EdgeInsets.symmetric(vertical: 14),
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
            const Expanded(
              child: Text('دفاعات العدو (من تقرير التجسس في اللعبة)',
                  style: TextStyle(
                      color: kDesertSand,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.none)),
            ),
            TextButton(
              onPressed: _autoSuggest,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
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
                _sending ? 'جارٍ الإرسال...' : 'هجوم ($_grandTotal)',
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