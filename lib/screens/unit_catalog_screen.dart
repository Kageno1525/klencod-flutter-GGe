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

class UnitCatalogScreen extends StatefulWidget {
  final int? focusedWodId;
  const UnitCatalogScreen({super.key, this.focusedWodId});

  @override
  State<UnitCatalogScreen> createState() => _UnitCatalogScreenState();
}

class _UnitCatalogScreenState extends State<UnitCatalogScreen> {
  List<UnitCatalogEntry> _all = [];
  List<UnitCatalogEntry> _filtered = [];
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
    final list = map.values.toList()
      ..sort((a, b) => a.wodId.compareTo(b.wodId));
    if (!mounted) return;
    setState(() {
      _all = list;
      _loading = false;
      _applyFilters();
    });

    if (_focusId != null && list.isNotEmpty) {
      UnitCatalogEntry? target;
      try {
        target = list.firstWhere((u) => u.wodId == _focusId);
      } catch (_) {
        target = null;
      }
      if (target != null) {
        final t = target;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showDetail(t);
        });
      }
    }
  }

  void _applyFilters() {
    final q = _query.trim().toLowerCase();
    _filtered = _all.where((u) {
      if (_roleFilter != 'all' && u.role != _roleFilter) return false;
      if (_typeFilter != 'all') {
        final t = u.fightType;
        if (_typeFilter == 'offense' && t != 0) return false;
        if (_typeFilter == 'defense' && t != 1) return false;
        if (_typeFilter == 'mixed' && t != null) return false;
      }
      if (q.isEmpty) return true;
      return u.displayName.toLowerCase().contains(q) ||
          u.wodId.toString().contains(q) ||
          (u.type ?? '').toLowerCase().contains(q);
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
                          child: CircularProgressIndicator(color: AppTheme.purple),
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
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                              itemCount: _filtered.length,
                              itemBuilder: (_, i) => FadeSlideIn(
                                delay: Duration(milliseconds: 20 + (i % 10) * 30),
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
                  '${_filtered.length} / ${_all.length}',
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
          prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.purple),
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
          color: selected ? color.withOpacity(0.2) : Colors.white.withOpacity(0.04),
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

  Widget _unitCard(UnitCatalogEntry u) {
    final accent = u.fightType == 0
        ? AppTheme.red
        : u.fightType == 1
            ? AppTheme.teal
            : AppTheme.orange;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _showDetail(u),
        child: AppTheme.glassCard(
          context: context,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              UnitAvatar(info: u, size: 64),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      u.displayName,
                      style: TextStyle(
                        color: AppTheme.textColor(context),
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        decoration: TextDecoration.none,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      _pill(
                        u.role == 'ranged'
                            ? 'بعيد'
                            : u.role == 'melee'
                                ? 'قريب'
                                : '—',
                        u.role == 'ranged' ? AppTheme.teal : AppTheme.red,
                      ),
                      const SizedBox(width: 6),
                      _pill(
                        u.fightType == 0
                            ? 'هجومي'
                            : u.fightType == 1
                                ? 'دفاعي'
                                : 'مختلط',
                        accent,
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      'ATK ${u.rangedAttack + u.meleeAttack} · DEF ${u.rangedDefence + u.meleeDefence}',
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

  void _showDetail(UnitCatalogEntry u) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _UnitDetailSheet(unit: u),
    );
  }
}

class _UnitDetailSheet extends StatelessWidget {
  final UnitCatalogEntry unit;
  const _UnitDetailSheet({required this.unit});

  @override
  Widget build(BuildContext context) {
    final accent = unit.fightType == 0
        ? AppTheme.red
        : unit.fightType == 1
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
              Row(children: [
                Expanded(
                  child: Text(
                    unit.displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
              const SizedBox(height: 4),
              Text(
                '#${unit.wodId} · ${unit.type ?? "—"}',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: UnitAvatar(info: unit, size: 160),
              ),
              const SizedBox(height: 20),
              _row('هجوم عن بعد', unit.rangedAttack,
                  Icons.gps_fixed_rounded, AppTheme.teal),
              _row('هجوم قريب', unit.meleeAttack,
                  Icons.gavel_rounded, AppTheme.red),
              _row('دفاع عن بعد', unit.rangedDefence,
                  Icons.shield_rounded, AppTheme.blue),
              _row('دفاع قريب', unit.meleeDefence,
                  Icons.shield_moon_rounded, AppTheme.purple),
              _row('السرعة', unit.speed, Icons.speed_rounded, AppTheme.orange),
              _row('الغنيمة', unit.loot, Icons.savings_rounded, AppTheme.orange),
              _row('البأس', unit.might, Icons.star_rounded, AppTheme.purple),
              _row('استهلاك الطعام', unit.food,
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
                    unit.fightType == 0
                        ? Icons.gavel_rounded
                        : unit.fightType == 1
                            ? Icons.shield_rounded
                            : Icons.compare_arrows_rounded,
                    color: accent,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      unit.fightType == 0
                          ? 'وحدة هجومية — مناسبة للهجوم على NPC / أعداء'
                          : unit.fightType == 1
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