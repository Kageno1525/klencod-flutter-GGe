import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

class SmuggleScreen extends StatefulWidget {
  final GgeClient client;
  const SmuggleScreen({super.key, required this.client});

  @override
  State<SmuggleScreen> createState() => _SmuggleScreenState();
}

class _SmuggleScreenState extends State<SmuggleScreen> {
  List<OwnedCastle> _castles = [];
  Map<int, UnitCatalogEntry> _catalog = {};
  List<AllyMember> _members = [];
  List<CommanderInfo> _commanders = [];

  OwnedCastle? _source;
  AllyMember? _target;
  AllyCastle? _targetCastle;
  Lord? _selectedLord;

  List<CastleUnit> _units = [];
  final Map<int, TextEditingController> _amtCtrl = {};
  final _timeCtrl = TextEditingController(text: '12');

  bool _loadingUnits = false;
  bool _loadingMembers = false;
  bool _loadingCommanders = false;
  bool _sending = false;

  String _filter = 'all';
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    try {
      final castles = await widget.client.getCastles();
      final catalog = await widget.client.loadCatalog();
      if (!mounted) return;
      setState(() {
        _castles = castles;
        _catalog = catalog;
        if (castles.isNotEmpty) {
          _source = castles.firstWhere(
            (c) => c.areaType == 1,
            orElse: () => castles.first,
          );
        }
      });
      await _loadMembers();
      await _loadCommanders();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadCommanders() async {
    setState(() => _loadingCommanders = true);
    try {
      final cmds = await widget.client.getCommanders();
      if (!mounted) return;
      setState(() {
        _commanders = cmds;
        _loadingCommanders = false;
        final free = _commanders.where((c) => !c.isBusy).toList();
        if (_selectedLord == null && free.isNotEmpty) {
          _selectedLord = free.first.lord;
        } else if (_selectedLord != null) {
          final current = _commanders.firstWhere(
            (c) => c.lord.id == _selectedLord!.id,
            orElse: () => CommanderInfo(lord: _selectedLord!),
          );
          if (current.isBusy) _selectedLord = null;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loadingCommanders = false);
    }
  }

  Future<void> _loadMembers() async {
    setState(() {
      _loadingMembers = true;
      _error = null;
    });
    try {
      final members = await widget.client.getAllianceMembers();
      if (!mounted) return;
      setState(() {
        _members = members;
        _loadingMembers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMembers = false;
        if (e.toString().contains('not_in_alliance')) {
          _error = S.notInAlliance;
        } else {
          _error = e.toString().replaceFirst('Exception: ', '');
        }
      });
    }
  }

  Future<void> _loadUnits() async {
    if (_source == null) return;
    setState(() {
      _loadingUnits = true;
      _units = [];
      for (final c in _amtCtrl.values) c.dispose();
      _amtCtrl.clear();
    });
    try {
      final units = await widget.client
          .getCastleUnits(_source!.kingdomId, _source!.areaId, _catalog);
      if (!mounted) return;
      setState(() {
        _units = units;
        for (final u in units) {
          _amtCtrl[u.wodId] = TextEditingController(text: '0');
        }
        _loadingUnits = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingUnits = false);
      _snack('$e', color: AppTheme.red);
    }
  }

  List<AllyMember> get _filteredMembers {
    if (_filter == 'peace') {
      return _members.where((m) => m.hasPeace).toList();
    }
    return _members;
  }

  List<CastleUnit> get _filteredUnits {
    switch (_filter) {
      case 'offense':
        return _units.where((u) => u.isCombat && !u.isDefensive).toList();
      case 'defense':
        return _units.where((u) => u.isCombat && u.isDefensive).toList();
      default:
        return _units.where((u) => u.isCombat).toList();
    }
  }

  int get _totalSelected {
    int t = 0;
    for (final u in _units) {
      final a = int.tryParse(_amtCtrl[u.wodId]?.text ?? '0') ?? 0;
      if (a > 0) t += a;
    }
    return t;
  }

  void _selectAllUnits() {
    for (final u in _filteredUnits) {
      _amtCtrl[u.wodId]?.text = u.amount.toString();
    }
    setState(() {});
  }

  void _clearAllUnits() {
    for (final c in _amtCtrl.values) c.text = '0';
    setState(() {});
  }

  Future<void> _send() async {
    if (_source == null) {
      _snack('Select source', color: AppTheme.red);
      return;
    }
    if (_target == null || _targetCastle == null) {
      _snack('Select target', color: AppTheme.red);
      return;
    }
    if (_selectedLord == null) {
      _snack(S.allLordsBusy, color: AppTheme.red);
      return;
    }

    if (_targetCastle!.kingdomId != _source!.kingdomId) {
      _snack(
        S.isAr
            ? '⚠️ الهدف في KID ${_targetCastle!.kingdomId} والمصدر في KID ${_source!.kingdomId}. cds لا يدعم عبر الممالك.'
            : '⚠️ Cross-kingdom: target KID=${_targetCastle!.kingdomId}, source KID=${_source!.kingdomId}. cds does not support.',
        color: AppTheme.orange,
      );
      return;
    }

    final toSend = <List<int>>[];
    for (final u in _units) {
      final a = int.tryParse(_amtCtrl[u.wodId]?.text ?? '0') ?? 0;
      if (a > 0) toSend.add([u.wodId, a.clamp(0, u.amount)]);
    }

    if (toSend.isEmpty) {
      _snack(S.noUnitsSelected, color: AppTheme.orange);
      return;
    }

    final stationTime = int.tryParse(_timeCtrl.text) ?? 12;

    setState(() => _sending = true);
    final result = await widget.client.sendToAlly(
      source: _source!,
      target: _targetCastle!,
      units: toSend,
      stationTime: stationTime,
      lordId: _selectedLord!.id,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    if (result.success) {
      _snack('✓ ${S.transferOk}', color: AppTheme.green);
      HapticFeedback.mediumImpact();

      setState(() {
        final sentMap = <int, int>{};
        for (var item in toSend) sentMap[item[0]] = item[1];

        for (int i = 0; i < _units.length; i++) {
          if (sentMap.containsKey(_units[i].wodId)) {
            _units[i] = CastleUnit(
              wodId: _units[i].wodId,
              amount: _units[i].amount - sentMap[_units[i].wodId]!,
              info: _units[i].info,
            );
          }
        }
        _units.removeWhere((u) => u.amount <= 0);
        _clearAllUnits();
      });

      _loadCommanders();
    } else {
      String errMsg = result.error ?? 'Unknown';
      if (errMsg == 'ALL_LORDS_BUSY') {
        errMsg = S.allLordsBusy;
      } else if (errMsg.contains('Max kingdom army movements')) {
        errMsg = S.maxMovements;
      }
      _snack('${S.transferFail}: $errMsg', color: AppTheme.red);
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

  void _openLog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _TrafficLogSheet(),
    );
  }

  @override
  void dispose() {
    for (final c in _amtCtrl.values) c.dispose();
    _timeCtrl.dispose();
    super.dispose();
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
                _header(context),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    child: Column(
                      children: [
                        if (_error != null)
                          _errorCard(context)
                        else if (_loadingMembers)
                          _loadingCard(context)
                        else ...[
                          FadeSlideIn(
                            delay: const Duration(milliseconds: 100),
                            child: _sourcePicker(context),
                          ),
                          const SizedBox(height: 14),
                          FadeSlideIn(
                            delay: const Duration(milliseconds: 200),
                            child: _membersSection(context),
                          ),
                          if (_target != null && _targetCastle != null) ...[
                            const SizedBox(height: 14),
                            FadeSlideIn(
                              delay: const Duration(milliseconds: 300),
                              child: _lordPicker(context),
                            ),
                            const SizedBox(height: 14),
                            FadeSlideIn(
                              delay: const Duration(milliseconds: 400),
                              child: _timePicker(context),
                            ),
                            const SizedBox(height: 14),
                            FadeSlideIn(
                              delay: const Duration(milliseconds: 500),
                              child: _unitsSection(context),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_targetCastle != null && _units.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: FadeSlideIn(
                delay: const Duration(milliseconds: 600),
                offset: const Offset(0, 0.2),
                child: GradientButton(
                  label: '${S.send} ($_totalSelected)',
                  icon: Icons.local_shipping_rounded,
                  gradient: AppTheme.cosmosGradient,
                  loading: _sending,
                  onPressed: _send,
                ),
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
                Text(
                  S.smuggleTroops,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textColor(context),
                    letterSpacing: -0.3,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  '${_members.length} ${S.allianceMembers}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subTextColor(context),
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          AppIconBtn(
            icon: Icons.terminal_rounded,
            onTap: _openLog,
            color: AppTheme.orange,
            size: 42,
          ),
          const SizedBox(width: 8),
          AppIconBtn(
            icon: Icons.refresh_rounded,
            onTap: _loadingMembers
                ? null
                : () async {
                    await _loadMembers();
                    await _loadCommanders();
                  },
            size: 42,
          ),
        ],
      ),
    );
  }

  Widget _errorCard(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.red.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.red.withOpacity(0.3)),
            ),
            child: const Icon(Icons.error_outline_rounded,
                color: AppTheme.red, size: 36),
          ),
          const SizedBox(height: 16),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppTheme.textColor(context),
                fontSize: 13,
                height: 1.5,
                decoration: TextDecoration.none),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: _loadMembers,
                icon: const Icon(Icons.refresh_rounded,
                    color: AppTheme.purple, size: 16),
                label: Text(S.retry,
                    style: const TextStyle(
                        color: AppTheme.purple,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none)),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: _openLog,
                icon: const Icon(Icons.terminal_rounded,
                    color: AppTheme.orange, size: 16),
                label: Text('Log',
                    style: TextStyle(
                        color: AppTheme.orange,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _loadingCard(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const CircularProgressIndicator(color: AppTheme.purple),
          const SizedBox(height: 16),
          Text(S.loadingMembers,
              style: TextStyle(
                  color: AppTheme.subTextColor(context),
                  decoration: TextDecoration.none)),
        ],
      ),
    );
  }

  Widget _sourcePicker(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.teal.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.teal.withOpacity(0.3)),
            ),
            child: const Icon(Icons.castle_rounded,
                color: AppTheme.teal, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.from,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.subTextColor(context),
                    letterSpacing: 0.8,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 2),
                DropdownButtonHideUnderline(
                  child: DropdownButton<OwnedCastle>(
                    value: _source,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textColor(context),
                    ),
                    items: _castles
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(c.fullLabel,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: AppTheme.textColor(context),
                                      fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (v) {
                      setState(() {
                        _source = v;
                        _units = [];
                        for (final c in _amtCtrl.values) c.dispose();
                        _amtCtrl.clear();
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _lordPicker(BuildContext context) {
    final freeLords =
        _commanders.where((c) => !c.isBusy).map((c) => c.lord).toList();
    if (_selectedLord != null &&
        !freeLords.any((l) => l.id == _selectedLord!.id)) {
      _selectedLord = null;
    }

    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: _loadingCommanders
          ? const Center(
              child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppTheme.purple),
              ),
            )
          : Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppTheme.orange.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: AppTheme.orange.withOpacity(0.3)),
                  ),
                  child: const Icon(Icons.person_rounded,
                      color: AppTheme.orange, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        S.selectLord,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.subTextColor(context),
                          letterSpacing: 0.8,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(height: 2),
                      DropdownButtonHideUnderline(
                        child: DropdownButton<Lord>(
                          value: _selectedLord,
                          isExpanded: true,
                          isDense: true,
                          dropdownColor:
                              Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(14),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textColor(context),
                          ),
                          items: [
                            DropdownMenuItem<Lord>(
                              value: null,
                              child: Text(S.autoLord,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textColor(context))),
                            ),
                            ...freeLords.map((l) => DropdownMenuItem(
                                  value: l,
                                  child: Text(l.displayName,
                                      style: TextStyle(
                                          fontSize: 13,
                                          color:
                                              AppTheme.textColor(context))),
                                )),
                          ],
                          onChanged: (v) =>
                              setState(() => _selectedLord = v),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _timePicker(BuildContext context) {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.blue.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.blue.withOpacity(0.3)),
            ),
            child: const Icon(Icons.timer_rounded,
                color: AppTheme.blue, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.stationTime,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.subTextColor(context),
                    letterSpacing: 0.8,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 2),
                TextField(
                  controller: _timeCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 6),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _membersSection(BuildContext context) {
    final filtered = _filteredMembers;

    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppTheme.purple.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.group_rounded,
                    color: AppTheme.purple, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  S.allianceMembers,
                  style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              _smallChip(context, 'all', S.allMembers),
              const SizedBox(width: 6),
              _smallChip(context, 'peace', S.peaceOnly),
            ],
          ),
          const SizedBox(height: 12),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Text(
                  S.noAllianceMembers,
                  style: TextStyle(
                      color: AppTheme.subTextColor(context),
                      decoration: TextDecoration.none),
                ),
              ),
            )
          else
            ...filtered.map((m) => _memberTile(context, m)),
        ],
      ),
    );
  }

  Widget _smallChip(BuildContext context, String key, String label) {
    final sel = _filter == key;
    return GestureDetector(
      onTap: () => setState(() => _filter = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          gradient: sel ? AppTheme.primaryGradient : null,
          color: sel
              ? null
              : Theme.of(context).colorScheme.surface.withOpacity(0.6),
          borderRadius: BorderRadius.circular(10),
          border: sel
              ? null
              : Border.all(
                  color: AppTheme.subTextColor(context).withOpacity(0.1)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? Colors.white : AppTheme.subTextColor(context),
            fontSize: 10.5,
            fontWeight: sel ? FontWeight.bold : FontWeight.w500,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // ✅ التعديل الوحيد في هذا الملف:
  //    - تحذير لو الهدف مش في نفس KID المصدر
  //    - اختيار قلعة الهدف من نفس KID المصدر لو موجودة
  // ═══════════════════════════════════════════════════════════
  Widget _memberTile(BuildContext context, AllyMember m) {
    final selected = _target?.playerId == m.playerId;
    final hasPeace = m.hasPeace;

    String distanceLabel = '';
    if (_source != null) {
      final d = m.closestDistance(_source!.kingdomId, _source!.x, _source!.y);
      distanceLabel = d == double.infinity
          ? 'Diff. kingdom'
          : '${d.toStringAsFixed(0)} ${S.clicks}';
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _target = m;
          // ✅ نفضّل قلعة نفس KID المصدر
          final sameKingdomCastle = m.castleIn(_source?.kingdomId ?? 0);
          _targetCastle = sameKingdomCastle ??
              (m.castles.isNotEmpty ? m.castles.first : null);
          _units = [];
          for (final c in _amtCtrl.values) c.dispose();
          _amtCtrl.clear();
        });
        if (_targetCastle != null) {
          // ✅ تحذير واضح لو الهدف مش في نفس KID
          if (_targetCastle!.kingdomId != _source?.kingdomId) {
            _snack(
              S.isAr
                  ? '⚠️ ${m.name} ليس لديه قلعة في خريطتك (KID ${_source?.kingdomId}). cds لا يدعم عبر الممالك.'
                  : '⚠️ ${m.name} has no castle in your kingdom (KID ${_source?.kingdomId}). cds is same-kingdom only.',
              color: AppTheme.orange,
            );
          }
          _loadUnits();
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: selected ? AppTheme.primaryGradient : null,
          color: selected
              ? null
              : (AppTheme.isDark(context)
                  ? Colors.white.withOpacity(0.03)
                  : Colors.black.withOpacity(0.02)),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : (hasPeace
                    ? AppTheme.green.withOpacity(0.3)
                    : AppTheme.subTextColor(context).withOpacity(0.1)),
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: hasPeace
                    ? (selected
                        ? Colors.white.withOpacity(0.22)
                        : AppTheme.green.withOpacity(0.18))
                    : (selected
                        ? Colors.white.withOpacity(0.12)
                        : AppTheme.subTextColor(context).withOpacity(0.08)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                hasPeace
                    ? Icons.shield_moon_rounded
                    : Icons.shield_outlined,
                color: selected
                    ? Colors.white
                    : (hasPeace
                        ? AppTheme.green
                        : AppTheme.subTextColor(context)),
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
                      Flexible(
                        child: Text(
                          m.name,
                          style: TextStyle(
                            color: selected
                                ? Colors.white
                                : AppTheme.textColor(context),
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                            decoration: TextDecoration.none,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: selected
                              ? Colors.white.withOpacity(0.2)
                              : AppTheme.subTextColor(context)
                                  .withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Lv ${m.level}',
                          style: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : AppTheme.subTextColor(context),
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              decoration: TextDecoration.none),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (hasPeace) ...[
                        Icon(Icons.verified_user_rounded,
                            size: 11,
                            color: selected ? Colors.white : AppTheme.green),
                        const SizedBox(width: 3),
                        Text(
                          '${S.peaceActive} · ${m.peaceLabel}',
                          style: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : AppTheme.green,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.none),
                        ),
                      ] else
                        Text(
                          S.noPeaceActive,
                          style: TextStyle(
                              color: selected
                                  ? Colors.white70
                                  : AppTheme.subTextColor(context),
                              fontSize: 10,
                              decoration: TextDecoration.none),
                        ),
                      const SizedBox(width: 10),
                      if (distanceLabel.isNotEmpty) ...[
                        Icon(Icons.place_rounded,
                            size: 11,
                            color: selected
                                ? Colors.white70
                                : AppTheme.subTextColor(context)),
                        const SizedBox(width: 3),
                        Text(
                          distanceLabel,
                          style: TextStyle(
                              color: selected
                                  ? Colors.white70
                                  : AppTheme.subTextColor(context),
                              fontSize: 10,
                              decoration: TextDecoration.none),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle_rounded,
                  color: Colors.white, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _unitsSection(BuildContext context) {
    if (_loadingUnits) {
      return AppTheme.glassCard(
        context: context,
        padding: const EdgeInsets.all(24),
        child: const Center(
            child: CircularProgressIndicator(color: AppTheme.purple)),
      );
    }
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppTheme.teal.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.groups_rounded,
                    color: AppTheme.teal, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${S.sendTo} ${_target?.name ?? ""}',
                      style: TextStyle(
                        color: AppTheme.textColor(context),
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        decoration: TextDecoration.none,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '→ ${_targetCastle!.displayLabel}',
                      style: TextStyle(
                          color: AppTheme.subTextColor(context),
                          fontSize: 10.5,
                          decoration: TextDecoration.none),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _unitChip(context, 'all', S.allUnits),
              const SizedBox(width: 6),
              _unitChip(context, 'offense', S.offenseOnly),
              const SizedBox(width: 6),
              _unitChip(context, 'defense', S.defenseOnly),
              const Spacer(),
              InkWell(
                onTap: _selectAllUnits,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppTheme.teal.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.done_all_rounded,
                      color: AppTheme.teal, size: 16),
                ),
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: _clearAllUnits,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppTheme.subTextColor(context).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.clear_all_rounded,
                      color: AppTheme.subTextColor(context), size: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ..._filteredUnits.map((u) => _unitRow(context, u)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.purple.withOpacity(0.3),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                const Icon(Icons.calculate_rounded,
                    color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(
                  S.total,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      decoration: TextDecoration.none),
                ),
                const Spacer(),
                Text(
                  '$_totalSelected',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
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

  Widget _unitChip(BuildContext context, String key, String label) {
    final sel = _filter == key;
    return GestureDetector(
      onTap: () => setState(() => _filter = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          gradient: sel ? AppTheme.secondaryGradient : null,
          color: sel
              ? null
              : Theme.of(context).colorScheme.surface.withOpacity(0.6),
          borderRadius: BorderRadius.circular(10),
          border: sel
              ? null
              : Border.all(
                  color: AppTheme.subTextColor(context).withOpacity(0.1)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? Colors.white : AppTheme.subTextColor(context),
            fontSize: 10.5,
            fontWeight: sel ? FontWeight.bold : FontWeight.w500,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  Widget _unitRow(BuildContext context, CastleUnit u) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surface
            .withOpacity(AppTheme.isDark(context) ? 0.5 : 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: u.roleColor.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: u.roleColor.withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: u.roleColor.withOpacity(0.4)),
            ),
            child: Icon(u.icon, color: u.roleColor, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.unitName(u.displayName),   // ✅ Arabic
                  style: TextStyle(
                      color: AppTheme.textColor(context),
                      fontWeight: FontWeight.bold