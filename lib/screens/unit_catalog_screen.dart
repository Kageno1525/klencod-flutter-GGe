import 'package:flutter/material.dart';
import 'package:gge/models.dart';
import 'package:gge/services/local_catalog_service.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';
import 'package:gge/widgets/unit_avatar.dart';

void openUnitCatalog(BuildContext context, UnitCatalogEntry? info) {
  if (info == null) return;
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => UnitCatalogScreen(focusedWodId: info.wodId),
    ),
  );
}

/// Wraps a list of `UnitCatalogEntry` that share the same display name
/// (i.e. same unit at different levels).
class _UnitGroup {
  final String displayName;
  final List<UnitCatalogEntry> entries;

  _UnitGroup({required this.displayName, required this.entries});

  UnitCatalogEntry get baseEntry => entries.first;
  int get count => entries.length;
  bool get hasMultipleLevels => entries.length > 1;

  int get minLevel => entries.map((e) => e.level).reduce((a, b) => a < b ? a : b);
  int get maxLevel => entries.map((e) => e.level).reduce((a, b) => a > b ? a : b);

  String get levelRangeLabel {
    if (count == 1) return 'Lvl ${baseEntry.level}';
    if (minLevel == maxLevel) return 'Lvl $minLevel';
    return 'Lvl $minLevel-$maxLevel';
  }
}

class UnitCatalogScreen extends StatefulWidget {
  final int? focusedWodId;
  const UnitCatalogScreen({super.key, this.focusedWodId});

  @override
  State<UnitCatalogScreen> createState() => _UnitCatalogScreenState();
}

class _UnitCatalogScreenState extends State<UnitCatalogScreen> {
  List<_UnitGroup> _groups = [];
  List<_UnitGroup> _filtered = [];
  bool _loading = true;
  String _query = '';
  String _roleFilter = 'all';
  String _typeFilter = 'all';
  int? _focusId;

  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _focusId = widget.focusedWodId;
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final map = await LocalCatalogService.load();

    // Group by display name
    final rawGroups = <String, List<UnitCatalogEntry>>{};
    for (final u in map.values) {
      rawGroups.putIfAbsent(u.displayName, () => []).add(u);
    }

    final groups = rawGroups.values.map((entries) {
      entries.sort((a, b) {
        final byLevel = a.level.compareTo(b.level);
        if (byLevel != 0) return byLevel;
        return a.wodId.compareTo(b.wodId);
      });
      return _UnitGroup(
        displayName: entries.first.displayName,
        entries: entries,
      );
    }).toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
      _applyFilters();
    });

    // If focusedWodId is set, open the group details at that specific level
    if (_focusId != null && _groups.isNotEmpty) {
      _UnitGroup? targetGroup;
      int targetIdx = 0;
      for (final g in _groups) {
        final idx = g.entries.indexWhere((e) => e.wodId == _focusId);
        if (idx >= 0) {
          targetGroup = g;
          targetIdx = idx;
          break;
        }
      }
      if (targetGroup != null) {
        final tg = targetGroup;
        final ti = targetIdx;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showDetail(tg, initialIndex: ti);
        });
      }
    }
  }

  void _applyFilters() {
    final q = _query.trim().toLowerCase();
    _filtered = _groups.where((g) {
      if (_roleFilter != 'all') {
        if (!g.entries.any((e) => e.role == _roleFilter)) return false;
      }
      if (_typeFilter != 'all') {
        bool typeMatch = false;
        for (final e in g.entries) {
          final t = e.fightType;
          if (_typeFilter == 'offense' && t == 0) {
            typeMatch = true;
            break;
          }
          if (_typeFilter == 'defense' && t == 1) {
            typeMatch = true;
            break;
          }
          if (_typeFilter == 'mixed' && t == null) {
            typeMatch = true;
            break;
          }
        }
        if (!typeMatch) return false;
      }
      if (q.isEmpty) return true;
      if (g.displayName.toLowerCase().contains(q)) return true;
      for (final e in g.entries) {
        if (e.wodId.toString().contains(q)) return true;
        if ((e.type ?? '').toLowerCase().contains(q)) return true;
      }
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          AppTheme.background(context),
          SafeArea(
            child: Column(
              children: [
                _header(),
                _searchBar(),
                _filterRow(),
                const SizedBox(height: 4),
                Expanded(
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(
                              color: AppTheme.purple),
                        )
                      : _filtered.isEmpty
                          ? Center(
                              child: Text(
                                'لا نتائج',
                                style: TextStyle(
                                  color: AppTheme.subTextColor(context),
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 8, 16, 24),
                              itemCount: _filtered.length,
                              itemBuilder: (_, i) => FadeSlideIn(
                                delay: Duration(
                                    milliseconds: 20 + (i % 10) * 30),
                                child: _unitCard(_filtered[i]),
                              ),
                            ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
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
                Text(
                  'كاتلوج الجنود',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textColor(context),
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  '${_filtered.length} / ${_groups.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subTextColor(context),
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() {
          _query = v;
          _applyFilters();
        }),
        style: TextStyle(color: AppTheme.textColor(context)),
        decoration: InputDecoration(
          hintText: 'ابحث بالاسم أو الرقم...',
          prefixIcon:
              const Icon(Icons.search_rounded, color: AppTheme.purple),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() {
                      _query = '';
                      _applyFilters();
                    });
                  },
                ),
        ),
      ),
    );
  }

  Widget _filterRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          _chip('الكل', 'all', _roleFilter, (v) {
            setState(() {
              _roleFilter = v;
              _applyFilters();
            });
          }),
          const SizedBox(width: 6),
          _chip('قريب', 'melee', _roleFilter, (v) {
            setState(() {
              _roleFilter = v;
              _applyFilters();
            });
          }),
          const SizedBox(width: 6),
          _chip('بعيد', 'ranged', _roleFilter, (v) {
            setState(() {
              _roleFilter = v;
              _applyFilters();
            });
          }),
          const SizedBox(width: 12),
          Container(
            width: 1,
            height: 20,
            color: AppTheme.subTextColor(context).withOpacity(0.2),
          ),
          const SizedBox(width: 12),
          _chip('هجومي', 'offense', _typeFilter, (v) {
            setState(() {
              _typeFilter = v;
              _applyFilters();
            });
          }, color: AppTheme.red),
          const SizedBox(width: 6),
          _chip('دفاعي', 'defense', _typeFilter, (v) {
            setState(() {
              _typeFilter = v;
              _applyFilters();
            });
          }, color: AppTheme.teal),
          const SizedBox(width: 6),
          _chip('مختلط', 'mixed', _typeFilter, (v) {
            setState(() {
              _typeFilter = v;
              _applyFilters();
            });
          }, color: AppTheme.orange),
        ],
      ),
    );
  }

  Widget _chip(
    String label,
    String value,
    String current,
    ValueChanged<String> onTap, {
    Color color = AppTheme.purple,
  }) {
    final selected = current == value;
    return GestureDetector(
      onTap: () => onTap(selected ? 'all' : value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? color.withOpacity(0.2)
              : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : Colors.grey.withOpacity(0.2),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? color : AppTheme.subTextColor(context),
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  Widget _unitCard(_UnitGroup g) {
    final base = g.baseEntry;
    final accent = base.fightType == 0
        ? AppTheme.red
        : base.fightType == 1
            ? AppTheme.teal
            : AppTheme.orange;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _showDetail(g),
        child: AppTheme.glassCard(
          context: context,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              UnitAvatar(info: base, size: 64),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            g.displayName,
                            style: TextStyle(
                              color: AppTheme.textColor(context),
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              decoration: TextDecoration.none,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (g.hasMultipleLevels) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.blue.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: AppTheme.blue.withOpacity(0.4)),
                            ),
                            child: Text(
                              g.levelRangeLabel,
                              style: const TextStyle(
                                color: AppTheme.blue,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      _pill(
                        base.role == 'ranged'
                            ? 'بعيد'
                            : base.role == 'melee'
                                ? 'قريب'
                                : '—',
                        base.role == 'ranged' ? AppTheme.teal : AppTheme.red,
                      ),
                      const SizedBox(width: 6),
                      _pill(
                        base.fightType == 0
                            ? 'هجومي'
                            : base.fightType == 1
                                ? 'دفاعي'
                                : 'مختلط',
                        accent,
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      'ATK ${base.rangedAttack + base.meleeAttack} · DEF ${base.rangedDefence + base.meleeDefence}',
                      style: TextStyle(
                        color: AppTheme.subTextColor(context),
                        fontSize: 10.5,
                        decoration: TextDecoration.none,
                      ),
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

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.18),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            decoration: TextDecoration.none,
          ),
        ),
      );

  void _showDetail(_UnitGroup group, {int initialIndex = 0}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _UnitDetailSheet(
        group: group,
        initialIndex: initialIndex,
      ),
    );
  }
}

// ═══════════════════════════════════════════
//  Detail Sheet (with level selector)
// ═══════════════════════════════════════════
class _UnitDetailSheet extends StatefulWidget {
  final _UnitGroup group;
  final int initialIndex;
  const _UnitDetailSheet({required this.group, this.initialIndex = 0});

  @override
  State<_UnitDetailSheet> createState() => _UnitDetailSheetState();
}

class _UnitDetailSheetState extends State<_UnitDetailSheet> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex =
        widget.initialIndex.clamp(0, widget.group.entries.length - 1);
  }

  UnitCatalogEntry get _current => widget.group.entries[_currentIndex];
  bool get _hasMultiple => widget.group.entries.length > 1;
  bool get _canPrev => _currentIndex > 0;
  bool get _canNext => _currentIndex < widget.group.entries.length - 1;

  void _goPrev() {
    if (_canPrev) setState(() => _currentIndex--);
  }

  void _goNext() {
    if (_canNext) setState(() => _currentIndex++);
  }

  @override
  Widget build(BuildContext context) {
    final u = _current;
    final accent = u.fightType == 0
        ? AppTheme.red
        : u.fightType == 1
            ? AppTheme.teal
            : AppTheme.orange;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0B0B14),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              // ✅ Level selector (arrows)
              if (_hasMultiple)
                _buildLevelSelector()
              else
                const SizedBox.shrink(),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(
                    u.displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
              const SizedBox(height: 4),
              Text(
                '#${u.wodId} · ${u.type ?? "—"}',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: UnitAvatar(info: u, size: 160),
              ),
              const SizedBox(height: 20),
              _row('هجوم عن بعد', u.rangedAttack,
                  Icons.gps_fixed_rounded, AppTheme.teal),
              _row('هجوم قريب', u.meleeAttack,
                  Icons.gavel_rounded, AppTheme.red),
              _row('دفاع عن بعد', u.rangedDefence,
                  Icons.shield_rounded, AppTheme.blue),
              _row('دفاع قريب', u.meleeDefence,
                  Icons.shield_moon_rounded, AppTheme.purple),
              _row('السرعة', u.speed, Icons.speed_rounded, AppTheme.orange),
              _row('الغنيمة', u.loot, Icons.savings_rounded, AppTheme.orange),
              _row('البأس', u.might, Icons.star_rounded, AppTheme.purple),
              _row('استهلاك الطعام', u.food,
                  Icons.restaurant_rounded, AppTheme.orange),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withOpacity(0.4)),
                ),
                child: Row(children: [
                  Icon(
                    u.fightType == 0
                        ? Icons.gavel_rounded
                        : u.fightType == 1
                            ? Icons.shield_rounded
                            : Icons.compare_arrows_rounded,
                    color: accent,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      u.fightType == 0
                          ? 'وحدة هجومية — مناسبة للهجوم على NPC / أعداء'
                          : u.fightType == 1
                              ? 'وحدة دفاعية — مناسبة للدفاع عن القلاع'
                              : 'وحدة مختلطة — تصلح للهجوم والدفاع',
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLevelSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          _navBtn(
            icon: Icons.arrow_back_rounded,
            enabled: _canPrev,
            onTap: _goPrev,
          ),
          Expanded(
            child: Center(
              child: Column(
                children: [
                  Text(
                    'المستوى ${_current.level}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  Text(
                    '${_currentIndex + 1} / ${widget.group.entries.length}',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _navBtn(
            icon: Icons.arrow_forward_rounded,
            enabled: _canNext,
            onTap: _goNext,
          ),
        ],
      ),
    );
  }

  Widget _navBtn({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: enabled
              ? Colors.white.withOpacity(0.1)
              : Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: enabled
                ? Colors.white.withOpacity(0.2)
                : Colors.white.withOpacity(0.05),
          ),
        ),
        child: Icon(
          icon,
          color: enabled ? Colors.white : Colors.white24,
          size: 20,
        ),
      ),
    );
  }

  Widget _row(String label, int value, IconData icon, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12.5,
              decoration: TextDecoration.none,
            ),
          ),
        ),
        Text(
          '$value',
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.none,
          ),
        ),
      ]),
    );
  }
}