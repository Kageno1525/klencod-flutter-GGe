import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

// ═══════════════════════════════════════════
class InvItem {
  final int eid;
  final int type;
  final int rarity;
  final int extra1;
  final int extra2;
  final List<dynamic> stats;
  final int slot;
  final int level;
  final bool isGovernor;

  InvItem({
    required this.eid,
    required this.type,
    required this.rarity,
    required this.extra1,
    required this.extra2,
    required this.stats,
    required this.slot,
    required this.level,
    this.isGovernor = false,
  });

  String get typeName {
    switch (type) {
      case 1: return 'درع';
      case 2: return 'سلاح';
      case 3: return 'خوذة';
      case 4: return 'قطعة أثرية';
      case 5: return 'أخرى';
      case 6: return 'قائد';
      default: return 'نوع $type';
    }
  }

  String get rarityName {
    switch (rarity) {
      case 1: return 'عادي';
      case 2: return 'نادر';
      case 3: return 'ملحمي';
      case 4: return 'أسطوري';
      default: return 'مستوى $rarity';
    }
  }

  Color get rarityColor {
    switch (rarity) {
      case 1: return const Color(0xFF9E9E9E);
      case 2: return const Color(0xFF2196F3);
      case 3: return const Color(0xFF9C27B0);
      case 4: return const Color(0xFFFF9800);
      default: return Colors.grey;
    }
  }

  IconData get icon {
    switch (type) {
      case 1: return Icons.shield_rounded;
      case 2: return Icons.gavel_rounded;
      case 3: return Icons.sports_motorsports_rounded;
      case 4: return Icons.diamond_rounded;
      case 6: return Icons.person_rounded;
      default: return Icons.inventory_2_rounded;
    }
  }

  bool get isCommander => type == 6;
  bool get isEquipped => slot >= 0;
}

// ═══════════════════════════════════════════
class InventoryScreen extends StatefulWidget {
  final GgeClient client;
  const InventoryScreen({super.key, required this.client});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  bool _loading = true;
  bool _selling = false;
  String? _error;
  bool _disposed = false;

  List<InvItem> _items = [];
  int _soldCount = 0;
  int _failedCount = 0;
  int _totalGold = 0;
  String? _lastSeqResponse;
  final Set<int> _soldEids = {};
  final Map<int, int> _soldByType = {};
  final List<String> _log = [];

  final Set<int> _selectedRarities = {2};
  final Set<int> _selectedTypes = {1, 2, 3, 4, 5};

  List<InvItem> get _commons =>
      _items.where((i) => i.rarity == 1 && !i.isCommander).toList();
  List<InvItem> get _rares =>
      _items.where((i) => i.rarity == 2 && !i.isCommander).toList();
  List<InvItem> get _commanders =>
      _items.where((i) => i.isCommander).toList();
  List<InvItem> get _equipped =>
      _items.where((i) => i.isEquipped && !i.isCommander).toList();
  List<InvItem> get _governorItems =>
      _items.where((i) => i.isGovernor).toList();

  List<InvItem> get _targets => _items
      .where((i) =>
          !i.isCommander &&
          !i.isEquipped &&
          _selectedRarities.contains(i.rarity) &&
          (i.isGovernor || _selectedTypes.contains(i.type)))
      .toList();

  @override
  void initState() {
    super.initState();
    _loadInventory();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _logLine(String s) {
    if (_disposed) return;
    setState(() => _log.add(s));
  }

  // ═══════════════════════════════════════════
  Future<void> _loadInventory() async {
    setState(() {
      _loading = true;
      _error = null;
      _items.clear();
      _log.clear();
      _soldEids.clear();
      _soldByType.clear();
      _soldCount = 0;
      _failedCount = 0;
      _totalGold = 0;
      _lastSeqResponse = null;
    });

    try {
      String? ggmPayload;
      _logLine('📤 ggm (حكام)');
      try {
        final ggm = await widget.client.sendXtAndWait('ggm', '{}',
            responseCmd: 'ggm', timeoutMs: 15000);
        if (ggm.resultCode == 0 && ggm.payload != null) {
          ggmPayload = ggm.payload;
          _logLine('📥 ggm ok');
        } else {
          _logLine('⚠️ ggm rc=${ggm.resultCode}');
        }
      } catch (_) {
        _logLine('⚠️ ggm timeout (متجاهل)');
      }

      _logLine('📤 gei (قواد)');
      final gei = await widget.client.sendXtAndWait('gei', '{}',
          responseCmd: 'gei', timeoutMs: 25000);
      _logLine('📥 gei rc=${gei.resultCode}');
      if (gei.resultCode != 0 || gei.payload == null) {
        throw Exception('gei failed rc=${gei.resultCode}');
      }

      _parseGei(gei.payload!);
      if (ggmPayload != null) {
        _parseGgm(ggmPayload);
      }

      if (!mounted) return;
      setState(() => _loading = false);

      _logLine('✅ تم تحميل ${_items.length} عنصر');
      _logLine('  • عادي: ${_commons.length}');
      _logLine('  • نادر: ${_rares.length}');
      _logLine('  • قائد: ${_commanders.length}');
      _logLine('  • مجهز: ${_equipped.length}');
      _logLine('  • 🏛️ حكام: ${_governorItems.length}');
      _logLine('🎯 المطابق للفلاتر: ${_targets.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'فشل التحميل: $e';
      });
      _logLine('❌ $e');
    }
  }

  void _parseGei(String payload) {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final items = data['I'] as List? ?? [];
      final parsed = <InvItem>[];

      for (final raw in items) {
        if (raw is! List || raw.isEmpty) continue;
        try {
          final eid = (raw[0] as num?)?.toInt() ?? 0;
          if (eid <= 0) continue;

          final type = raw.length > 1 ? ((raw[1] as num?)?.toInt() ?? 0) : 0;
          final rarity =
              raw.length > 2 ? ((raw[2] as num?)?.toInt() ?? 0) : 0;
          final extra1 =
              raw.length > 3 ? ((raw[3] as num?)?.toInt() ?? 0) : 0;
          final extra2 =
              raw.length > 4 ? ((raw[4] as num?)?.toInt() ?? 0) : 0;
          final stats = (raw.length > 5 && raw[5] is List)
              ? raw[5] as List
              : <dynamic>[];
          final slot =
              raw.length > 6 ? ((raw[6] as num?)?.toInt() ?? -1) : -1;
          final level =
              raw.length > 7 ? ((raw[7] as num?)?.toInt() ?? -1) : -1;

          parsed.add(InvItem(
            eid: eid,
            type: type,
            rarity: rarity,
            extra1: extra1,
            extra2: extra2,
            stats: stats,
            slot: slot,
            level: level,
            isGovernor: false,
          ));
        } catch (_) {}
      }

      _items.addAll(parsed);
    } catch (e) {
      _logLine('❌ parse gei: $e');
    }
  }

  void _parseGgm(String payload) {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final rgem = data['RGEM'] as List? ?? [];
      int govCount = 0;

      for (final raw in rgem) {
        if (raw is! List || raw.length < 5) continue;
        try {
          final eid = (raw[0] as num?)?.toInt() ?? 0;
          if (eid <= 0) continue;

          final rawType = (raw[1] as num?)?.toInt() ?? 0;
          final rawRarity = (raw[2] as num?)?.toInt() ?? 0;
          final value =
              raw.length > 3 ? ((raw[3] as num?)?.toInt() ?? 0) : 0;
          final stats = raw[4] is List ? raw[4] as List : <dynamic>[];
          final equipFlag =
              raw.length > 5 ? ((raw[5] as num?)?.toInt() ?? 0) : 0;

          int rarity;
          if (rawRarity >= 7) {
            rarity = 4;
          } else if (rawRarity == 6) {
            rarity = 3;
          } else if (rawRarity == 5) {
            rarity = 2;
          } else if (rawRarity >= 1 && rawRarity <= 4) {
            rarity = rawRarity;
          } else {
            rarity = 2;
          }

          final type = _guessGovType(stats, rawType);
          final slot = equipFlag == 0 ? -1 : 1;

          _items.add(InvItem(
            eid: eid,
            type: type,
            rarity: rarity,
            extra1: 0,
            extra2: 0,
            stats: stats,
            slot: slot,
            level: value,
            isGovernor: true,
          ));
          govCount++;
        } catch (_) {}
      }

      if (govCount > 0) {
        _logLine('🏛️ $govCount عنصر من الحكام');
      }
    } catch (e) {
      _logLine('❌ parse ggm: $e');
    }
  }

  int _guessGovType(List stats, int rawType) {
    bool hasArtifact = false;
    bool hasCombatStat = false;

    for (final s in stats) {
      if (s is! List || s.isEmpty) continue;
      final id = (s[0] as num?)?.toInt() ?? 0;
      if (id >= 10000) hasArtifact = true;
      if (id >= 300 && id < 400) hasCombatStat = true;
    }

    if (hasArtifact) return 4;
    if (hasCombatStat) return 2;
    if (rawType >= 1 && rawType <= 6) return rawType;
    return 5;
  }

  // ═══════════════════════════════════════════
  // البيع
  // ═══════════════════════════════════════════
  Future<void> _confirmAndSell() async {
    final targets = _targets;
    if (targets.isEmpty) {
      _showSnack('لا يوجد عناصر مطابقة للفلاتر المحددة');
      return;
    }

    final byType = <int, int>{};
    final byRarity = <int, int>{};
    int govCount = 0;
    for (final i in targets) {
      byType[i.type] = (byType[i.type] ?? 0) + 1;
      byRarity[i.rarity] = (byRarity[i.rarity] ?? 0) + 1;
      if (i.isGovernor) govCount++;
    }
    final typeSummary = byType.entries
        .map((e) => '  • ${_typeLabel(e.key)}: ${e.value}')
        .join('\n');
    final raritySummary = byRarity.entries
        .map((e) => '  • ${_rarityLabel(e.key)}: ${e.value}')
        .join('\n');

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('تأكيد البيع',
            style: TextStyle(decoration: TextDecoration.none)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'إجمالي: ${targets.length} عنصر${govCount > 0 ? " (منهم $govCount 🏛️ حكام)" : ""}\n\n'
                '📦 بالنوع:\n$typeSummary\n\n'
                '⭐ بالندرة:\n$raritySummary',
                style: const TextStyle(
                    decoration: TextDecoration.none, height: 1.5),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.teal.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.teal.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_rounded,
                        color: AppTheme.teal, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'العناصر المجهزة (${_equipped.length}) مش هتتباع',
                        style: const TextStyle(
                            color: AppTheme.teal,
                            fontSize: 11,
                            decoration: TextDecoration.none),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '⏱️ سيتم إرسال طلب كل 3 ثواني لتجنب الحظر.',
                style: TextStyle(
                    color: Colors.orange,
                    fontSize: 11,
                    height: 1.5,
                    decoration: TextDecoration.none),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: const Text('بيع الكل',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;
    await _sellAll(targets);
  }

  Future<void> _sellAll(List<InvItem> targets) async {
    setState(() {
      _selling = true;
      _soldCount = 0;
      _failedCount = 0;
      _totalGold = 0;
      _soldByType.clear();
    });

    _logLine('━━━━━━━━━━━━━━━━');
    _logLine('🚀 بدء البيع: ${targets.length} عنصر');

    for (var i = 0; i < targets.length; i++) {
      if (_disposed || !mounted) break;
      final item = targets[i];
      final ok = await _sellOne(item);
      if (ok) {
        _soldCount++;
        _soldEids.add(item.eid);
        _soldByType[item.type] = (_soldByType[item.type] ?? 0) + 1;
      } else {
        _failedCount++;
      }

      if (i < targets.length - 1) {
        _logLine('⏱️ انتظار 3s...');
        await Future.delayed(const Duration(seconds: 3));
      }
      if (mounted) setState(() {});
    }

    if (!mounted) return;
    setState(() => _selling = false);

    _logLine('━━━━━━━━━━━━━━━━');
    _logLine('📊 التقرير النهائي');
    _logLine('  • إجمالي: ${targets.length}');
    _logLine('  • ✅ تم بيع: $_soldCount');
    if (_failedCount > 0) _logLine('  • ❌ فشل: $_failedCount');
    if (_soldByType.isNotEmpty) {
      for (final e in _soldByType.entries) {
        _logLine('     - ${_typeLabel(e.key)}: ${e.value}');
      }
    }
    if (_totalGold > 0) {
      _logLine('  • 💰 الذهب: $_totalGold');
    }
    _logLine('━━━━━━━━━━━━━━━━');

    _showSnack(
        'تم بيع $_soldCount عنصر${_failedCount > 0 ? " (فشل $_failedCount)" : ""}');
  }

  // ✅ NEW: try multiple commands for governor items + full logging
  Future<bool> _sellOne(InvItem item) async {
    // ✅ Governor items need a different command
    final commands = item.isGovernor
        ? const ['sgm', 'sgv', 'seq']
        : const ['seq'];

    for (final cmd in commands) {
      try {
        final resp = await widget.client.sendXtAndWait(
          cmd,
          jsonEncode({
            'EID': item.eid,
            'LID': -1,
            'EX': 0,
            'LFID': -1,
          }),
          responseCmd: cmd,
          timeoutMs: 15000,
          isAction: false,
        );

        if (_disposed) return false;

        final tag = item.isGovernor ? '🏛️' : '✅';
        if (resp.resultCode == 0) {
          _logLine(
              '$tag #${item.eid} (${item.typeName}/${item.rarityName}) → $cmd OK');
          if (resp.payload != null && resp.payload!.isNotEmpty) {
            _lastSeqResponse = resp.payload;
            _tryExtractGold(resp.payload!);
          }
          return true;
        } else {
          _logLine(
              '❌ $cmd #${item.eid} rc=${resp.resultCode} payload=${resp.payload ?? "null"}');
          // Try next command only for "generic" errors (1, 5, or unknown command)
          // Item-level errors (91, 100, etc.) are terminal
          if (resp.resultCode != 1 && resp.resultCode != 5) {
            if (cmd != commands.last) continue;
            return false;
          }
        }
      } catch (e) {
        _logLine('⚠️ $cmd timeout/error #${item.eid}: $e');
        if (cmd == commands.last) return false;
      }
    }
    return false;
  }

  void _tryExtractGold(String payload) {
    try {
      final data = jsonDecode(payload);
      if (data is! Map) return;
      for (final key in const [
        'G', 'GOLD', 'Gold', 'gold',
        'C', 'Coins', 'coins',
        'M', 'Money', 'money',
      ]) {
        final v = data[key];
        if (v is num) {
          _totalGold += v.toInt();
          return;
        }
      }
    } catch (_) {}
  }

  String _typeLabel(int t) {
    switch (t) {
      case 1: return 'دروع';
      case 2: return 'أسلحة';
      case 3: return 'خوذات';
      case 4: return 'قطع أثرية';
      case 5: return 'أخرى';
      case 6: return 'قواد';
      default: return 'نوع $t';
    }
  }

  String _rarityLabel(int r) {
    switch (r) {
      case 1: return 'عادي';
      case 2: return 'نادر';
      case 3: return 'ملحمي';
      case 4: return 'أسطوري';
      default: return 'مستوى $r';
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ═══════════════════════════════════════════
  // الواجهة
  // ═══════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selling,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selling) {
          _showSnack('جاري البيع، استنى لما يخلص');
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            AppTheme.background(context),
            SafeArea(
              child: Column(
                children: [
                  _header(),
                  Expanded(child: _body()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF7B1FA2), Color(0xFFBA68C8)],
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7B1FA2).withOpacity(0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(Icons.inventory_2_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'المخزن / البيع',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textColor(context),
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  _selling
                      ? 'جاري البيع... $_soldCount/${_targets.length}'
                      : (_loading
                          ? 'جاري التحميل...'
                          : 'الكل: ${_items.length} · مستهدف: ${_targets.length} · مجهز: ${_equipped.length}'),
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subTextColor(context),
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          AppIconBtn(
            icon: Icons.refresh_rounded,
            onTap: (_loading || _selling) ? null : _loadInventory,
            size: 40,
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppTheme.purple),
            const SizedBox(height: 16),
            Text(
              'جاري جلب المخزن (قواد + حكام)...',
              style: TextStyle(
                color: AppTheme.subTextColor(context),
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: AppTheme.red, size: 56),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.textColor(context),
                    decoration: TextDecoration.none,
                  )),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadInventory,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _summaryCard(),
        const SizedBox(height: 14),
        _filtersCard(),
        const SizedBox(height: 14),
        _actionCard(),
        const SizedBox(height: 14),
        if (_commons.isNotEmpty)
          _section('🟢 عناصر عادية (${_commons.length})', _commons),
        if (_rares.isNotEmpty)
          _section('🔵 عناصر نادرة (${_rares.length})', _rares),
        if (_equipped.isNotEmpty)
          _section('🔒 عناصر مجهزة (${_equipped.length})', _equipped),
        if (_commanders.isNotEmpty)
          _section('🟣 قواد (${_commanders.length})', _commanders),
        if (_items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                'المخزن فاضي',
                style: TextStyle(
                  color: AppTheme.subTextColor(context),
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        const SizedBox(height: 14),
        _logCard(),
      ],
    );
  }

  Widget _summaryCard() {
    final stats = [
      ('عادي', _commons.length, const Color(0xFF9E9E9E)),
      ('نادر', _rares.length, const Color(0xFF2196F3)),
      ('قائد', _commanders.length, const Color(0xFF9C27B0)),
      ('🏛️ حكام', _governorItems.length, AppTheme.orange),
    ];
    return AppTheme.glassCard(
      context: context,
      child: Row(
        children: stats
            .map((s) => Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${s.$2}',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: s.$3,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      Text(
                        s.$1,
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.subTextColor(context),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _filtersCard() {
    return AppTheme.glassCard(
      context: context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.filter_alt_rounded, size: 18),
              const SizedBox(width: 6),
              Text(
                'فلترة العناصر المستهدفة',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: AppTheme.textColor(context),
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _filterLabel('⭐ الندرة'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _rarityChip(1, 'عادي', const Color(0xFF9E9E9E)),
              _rarityChip(2, 'نادر', const Color(0xFF2196F3)),
              _rarityChip(3, 'ملحمي', const Color(0xFF9C27B0)),
              _rarityChip(4, 'أسطوري', const Color(0xFFFF9800)),
            ],
          ),
          const SizedBox(height: 14),
          _filterLabel('📦 النوع'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _typeChip(1, 'درع', Icons.shield_rounded),
              _typeChip(2, 'سلاح', Icons.gavel_rounded),
              _typeChip(3, 'خوذة', Icons.sports_motorsports_rounded),
              _typeChip(4, 'قطعة أثرية', Icons.diamond_rounded),
              _typeChip(5, 'أخرى', Icons.inventory_2_rounded),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton.icon(
                onPressed: (_selling)
                    ? null
                    : () => setState(() {
                          _selectedRarities.clear();
                          _selectedRarities.add(2);
                          _selectedTypes.clear();
                          _selectedTypes.addAll({1, 2, 3, 4, 5});
                        }),
                icon: const Icon(Icons.restart_alt_rounded, size: 16),
                label: const Text('افتراضي (نادر)',
                    style: TextStyle(fontSize: 11)),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: (_selling)
                    ? null
                    : () => setState(() {
                          _selectedRarities.clear();
                          _selectedTypes.clear();
                        }),
                icon: const Icon(Icons.clear_all_rounded, size: 16),
                label: const Text('مسح الكل',
                    style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterLabel(String s) => Text(
        s,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppTheme.subTextColor(context),
          decoration: TextDecoration.none,
        ),
      );

  Widget _rarityChip(int r, String label, Color color) {
    final selected = _selectedRarities.contains(r);
    return GestureDetector(
      onTap: _selling
          ? null
          : () => setState(() {
                if (selected) {
                  _selectedRarities.remove(r);
                } else {
                  _selectedRarities.add(r);
                }
              }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.25) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : color.withOpacity(0.3),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked,
              size: 14,
              color: selected ? color : color.withOpacity(0.6),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: selected ? color : AppTheme.textColor(context),
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeChip(int t, String label, IconData icon) {
    final selected = _selectedTypes.contains(t);
    const color = AppTheme.purple;
    return GestureDetector(
      onTap: _selling
          ? null
          : () => setState(() {
                if (selected) {
                  _selectedTypes.remove(t);
                } else {
                  _selectedTypes.add(t);
                }
              }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.25) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : color.withOpacity(0.3),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14,
                color: selected ? color : color.withOpacity(0.6)),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: selected ? color : AppTheme.textColor(context),
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionCard() {
    final count = _targets.length;
    final canSell = count > 0 && !_selling;
    final noFilter = _selectedRarities.isEmpty || _selectedTypes.isEmpty;

    return AppTheme.glassCard(
      context: context,
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.auto_delete_rounded,
                  color: canSell ? AppTheme.green : Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  noFilter
                      ? '⚠️ اختر فلتر واحد على الأقل'
                      : (count > 0
                          ? 'جاهز للبيع: $count عنصر'
                          : 'لا يوجد عناصر مطابقة للفلاتر'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: noFilter
                        ? AppTheme.orange
                        : AppTheme.textColor(context),
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
          if (_selling) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _targets.isEmpty ? 0 : _soldCount / _targets.length,
              backgroundColor: Colors.grey.withOpacity(0.2),
              color: AppTheme.green,
            ),
            const SizedBox(height: 6),
            Text(
              '$_soldCount / ${_targets.length}',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.subTextColor(context),
                decoration: TextDecoration.none,
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: canSell ? _confirmAndSell : null,
              icon: _selling
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sell_rounded),
              label: Text(_selling
                  ? 'جاري البيع...'
                  : 'بيع المحدد ($count)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.teal.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.teal.withOpacity(0.2)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded,
                    color: AppTheme.teal, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '🏛️ يشمل الحكام والقواد · ⏱️ 3s بين كل عنصر',
                    style: TextStyle(
                      color: AppTheme.teal,
                      fontSize: 10,
                      decoration: TextDecoration.none,
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

  Widget _section(String title, List<InvItem> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppTheme.textColor(context),
              decoration: TextDecoration.none,
            ),
          ),
        ),
        AppTheme.glassCard(
          context: context,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: items.map((it) => _itemTile(it)).toList(),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _itemTile(InvItem item) {
    final sold = _soldEids.contains(item.eid);
    final equipped = item.isEquipped;
    final selectedForSell = _selectedRarities.contains(item.rarity) &&
        (item.isGovernor || _selectedTypes.contains(item.type)) &&
        !item.isCommander &&
        !equipped;

    Color borderColor = item.rarityColor.withOpacity(0.4);
    double borderWidth = 1;
    if (equipped) {
      borderColor = AppTheme.orange;
      borderWidth = 2;
    } else if (selectedForSell) {
      borderColor = item.rarityColor;
      borderWidth = 2;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: item.rarityColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: borderColor,
                width: borderWidth,
              ),
            ),
            child: Icon(item.icon, size: 18, color: item.rarityColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.typeName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: AppTheme.textColor(context),
                          decoration: TextDecoration.none,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (item.isGovernor) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppTheme.orange.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: AppTheme.orange.withOpacity(0.5)),
                        ),
                        child: const Text(
                          '🏛️ حكام',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.orange,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  '${item.rarityName} · #${item.eid}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.subTextColor(context),
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          if (sold)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.green.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.green.withOpacity(0.5)),
              ),
              child: const Text('تم البيع',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.green,
                    decoration: TextDecoration.none,
                  )),
            )
          else if (equipped)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: AppTheme.orange.withOpacity(0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.lock_rounded,
                      size: 10, color: AppTheme.orange),
                  SizedBox(width: 3),
                  Text('مجهز',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.orange,
                        decoration: TextDecoration.none,
                      )),
                ],
              ),
            )
          else if (selectedForSell)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.green.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: AppTheme.green.withOpacity(0.5)),
              ),
              child: const Text('مستهدف',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.green,
                    decoration: TextDecoration.none,
                  )),
            ),
        ],
      ),
    );
  }

  Widget _logCard() {
    return AppTheme.glassCard(
      context: context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal_rounded, size: 16),
              const SizedBox(width: 6),
              Text(
                'سجل العمليات',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textColor(context),
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SingleChildScrollView(
              child: Text(
                _log.isEmpty ? '(لا يوجد سجل)' : _log.join('\n'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.white70,
                  height: 1.4,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}