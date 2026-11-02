import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/models.dart';
import 'package:gge/services/bedouin_service.dart';
import 'package:gge/services/bedouin_auto_service.dart';
import 'package:gge/services/background_service.dart';
import 'package:gge/theme.dart';
import 'package:gge/widgets/animated_widgets.dart';

// ألوان البدو (أصفر + أزرق فاتح وغامق)
const Color kBedouinGold = Color(0xFFD4AF37);
const Color kBedouinBlue = Color(0xFF1E3A8A);
const Color kBedouinLightBlue = Color(0xFF3B82F6);

class BedouinScreen extends StatefulWidget {
  final GgeClient client;
  const BedouinScreen({super.key, required this.client});

  @override
  State<BedouinScreen> createState() => _BedouinScreenState();
}

class _BedouinScreenState extends State<BedouinScreen>
    with TickerProviderStateMixin {
  late final BedouinService _svc;
  late final BedouinAutoService _auto;
  late BedouinSettings _settings;
  late TabController _tabCtrl;

  List<OwnedCastle> _castles = [];
  OwnedCastle? _source;
  List<BedouinCamp> _camps = [];
  bool _scanning = false;
  int _scanDone = 0, _scanTotal = 0;
  bool _loading = true;

  List<CommanderInfo> _allCommanders = [];
  Set<int> _selectedCommanderIds = {};
  bool _loadingAutoData = false;

  // Auto settings
  bool _autoEnabled = false;
  int _minUnits = 50;
  int _delayMin = 8;
  int _delayMax = 15;
  int _maxLevel = 20;
  int _maxAttacksDay = 0;
  int _waves = 3;
  bool _useTools = true;
  int _toolIdW1 = 1;
  int _toolIdW2 = 164;
  int _toolIdW3 = 1;
  int _toolL = 20;
  int _toolR = 20;
  int _toolM = 30;
  String _attackPriority = 'distance';

  bool _bgRunning = false;
  String _bgStatusText = '';
  String _bgStatusExtra = '';

  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _svc = BedouinService(widget.client);
    _auto = BedouinAutoService.instance;
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() => setState(() {}));
    _init();
    _startStatusPolling();
  }

  Future<void> _init() async {
    _settings = await BedouinSettings.load();
    await _loadAutoSettings();
    await _auto.restoreState();

    try {
      final castles = await widget.client.getCastles();
      if (!mounted) return;
      setState(() {
        _castles = castles;
        if (castles.isNotEmpty) {
          try {
            _source = castles.firstWhere(
                (c) => c.areaId == _settings.sourceAreaId);
          } catch (_) {
            try {
              _source = castles.firstWhere((c) => c.areaType == 1);
            } catch (_) {
              _source = castles.first;
            }
          }
          _settings.sourceAreaId = _source!.areaId;
        }
        _loading = false;
        _autoEnabled = _auto.isRunning || _autoEnabled;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadAutoSettings() async {
    final enabled = await _auto.isEnabled();
    final minUnits = await _auto.getMinUnits();
    final delayMin = await _auto.getDelayMin();
    final delayMax = await _auto.getDelayMax();
    final maxLevel = await _auto.getMaxLevel();
    final maxAttacksDay = await _auto.getMaxAttacksDay();
    final waves = await _auto.getWaves();
    final useTools = await _auto.getUseTools();
    final toolIdW1 = await _auto.getToolIdWave1();
    final toolIdW2 = await _auto.getToolIdWave2();
    final toolIdW3 = await _auto.getToolIdWave3();
    final toolL = await _auto.getToolL();
    final toolR = await _auto.getToolR();
    final toolM = await _auto.getToolM();
    final commanders = await _auto.getCommanderIds();
    final priority = await _auto.getAttackPriority();

    if (!mounted) return;
    setState(() {
      _autoEnabled = enabled;
      _minUnits = minUnits;
      _delayMin = delayMin;
      _delayMax = delayMax;
      _maxLevel = maxLevel;
      _maxAttacksDay = maxAttacksDay;
      _waves = waves;
      _useTools = useTools;
      _toolIdW1 = toolIdW1;
      _toolIdW2 = toolIdW2;
      _toolIdW3 = toolIdW3;
      _toolL = toolL;
      _toolR = toolR;
      _toolM = toolM;
      _selectedCommanderIds = commanders.toSet();
      _attackPriority = priority;
    });
  }

  Future<void> _saveAttackPriority(String v) async {
    setState(() => _attackPriority = v);
    await _auto.setAttackPriority(v);
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      try {
        final bgRunning = await FlutterForegroundTask.isRunningService;
        final status = await FlutterForegroundTask.getData<String>(
                key: 'bg_status') ??
            '';
        final extra = await FlutterForegroundTask.getData<String>(
                key: 'bg_extra') ??
            '';
        if (!mounted) return;
        setState(() {
          _bgRunning = bgRunning;
          _bgStatusText = status;
          _bgStatusExtra = extra;
        });
      } catch (_) {
        if (mounted) setState(() => _bgRunning = false);
      }
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _tabCtrl.dispose();
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
      _camps = [];
      _scanDone = 0;
      _scanTotal = 0;
    });
    try {
      final found = await _svc.scanArea(
        source: _source!,
        radiusTiles: _settings.radiusTiles,
        maxLevel: _maxLevel,
        skipPlayerCamps: true,
        onProgress: (d, t) {
          if (!mounted) return;
          setState(() {
            _scanDone = d;
            _scanTotal = t;
          });
        },
      );
      if (!mounted) return;
      found.sort((a, b) =>
          a.distanceFromSource.compareTo(b.distanceFromSource));
      setState(() {
        _camps = found;
        _scanning = false;
      });
      _snack('تم العثور على ${found.length} معسكر بدو',
          color: found.isEmpty ? AppTheme.orange : AppTheme.green);
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      _snack('$e', color: AppTheme.red);
    }
  }

  void _snack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg,
            style: const TextStyle(decoration: TextDecoration.none),
            maxLines: 5),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ));
  }

  Future<void> _toggleAuto() async {
    if (_source == null) {
      _snack('اختر قلعة مصدر أولاً', color: AppTheme.red);
      return;
    }
    if (!_autoEnabled && _selectedCommanderIds.isEmpty) {
      _snack('اختر قواد أولاً (من الفلاتر تحت)',
          color: AppTheme.orange);
      return;
    }

    if (_autoEnabled) {
      await _auto.disable();
      if (mounted) {
        setState(() => _autoEnabled = false);
        _snack('⏸️ Auto متوقف', color: AppTheme.orange);
      }
      return;
    }

    await _auto.setSource(
      areaId: _source!.areaId,
      kid: _source!.kingdomId,
      x: _source!.x,
      y: _source!.y,
    );

    await _auto.setWaves(_waves);
    await _auto.setUseTools(_useTools);
    await _auto.setToolIds(w1: _toolIdW1, w2: _toolIdW2, w3: _toolIdW3);
    await _auto.setToolAmounts(l: _toolL, r: _toolR, m: _toolM);
    await _auto.setMaxLevel(_maxLevel);
    await _auto.setRadius(_settings.radiusTiles);

    await _auto.startFromUI(widget.client, sourceAreaId: _source!.areaId);

    if (mounted) {
      setState(() => _autoEnabled = true);
      final bgRunning = await FlutterForegroundTask.isRunningService;
      if (bgRunning) {
        _snack('✅ Auto شغال في الخلفية', color: AppTheme.green);
      } else {
        _snack('✅ Auto شغال في المقدمة', color: AppTheme.green);
      }
    }
  }

  Future<void> _loadAutoData() async {
    if (_loadingAutoData) return;
    setState(() => _loadingAutoData = true);
    try {
      final cmds = await widget.client.getCommanders();
      if (!mounted) return;
      setState(() {
        _allCommanders = cmds;
        _loadingAutoData = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingAutoData = false);
        _snack('Load error: $e', color: AppTheme.red);
      }
    }
  }

  Future<void> _openCommandersPicker() async {
    if (_allCommanders.isEmpty) await _loadAutoData();
    if (!mounted) return;

    final result = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MultiSelectSheet(
        title: 'اختر القواد',
        items: _allCommanders
            .map((c) => _SelectItem(
                  id: c.lord.id,
                  label: c.lord.id == 0
                      ? 'اللورد الرئيسي'
                      : c.lord.displayName,
                  subtitle: c.isBusy ? 'مشغول' : 'متاح',
                ))
            .toList(),
        selected: _selectedCommanderIds,
        allowEmpty: true,
        emptyMeansAll: false,
      ),
    );
    if (result == null) return;
    await _auto.setCommanderIds(result.toList());
    if (mounted) setState(() => _selectedCommanderIds = result);
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
                _tabBar(),
                if (_loading)
                  const Expanded(
                    child: Center(
                      child: CircularProgressIndicator(color: kBedouinGold),
                    ),
                  )
                else
                  Expanded(
                    child: _tabCtrl.index == 0 ? _manualTab() : _autoTab(),
                  ),
              ],
            ),
          ),
          if (_tabCtrl.index == 0 && _source != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: GradientButton(
                label: _scanning
                    ? 'جارٍ المسح ($_scanDone/$_scanTotal)'
                    : 'مسح معسكرات البدو (${_settings.radiusTiles} tile)',
                icon: Icons.castle_rounded,
                gradient: const LinearGradient(
                    colors: [kBedouinGold, kBedouinBlue]),
                loading: _scanning,
                onPressed: _scanning ? null : _scan,
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
                Text('معسكرات البدو',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textColor(context),
                        decoration: TextDecoration.none)),
                Text('${_camps.length} معسكر',
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

  Widget _tabBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          _tabBtn('يدوي', 0, Icons.touch_app_rounded),
          _tabBtn('تلقائي', 1, Icons.auto_awesome_rounded),
        ]),
      ),
    );
  }

  Widget _tabBtn(String label, int index, IconData icon) {
    final sel = _tabCtrl.index == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _tabCtrl.animateTo(index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            gradient: sel
                ? const LinearGradient(
                    colors: [kBedouinGold, kBedouinBlue])
                : null,
            color: sel ? null : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: sel ? Colors.white : AppTheme.subTextColor(context)),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      color: sel ? Colors.white : AppTheme.subTextColor(context),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      decoration: TextDecoration.none)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _manualTab() {
    final filtered = _camps.toList()
      ..sort((a, b) =>
          a.distanceFromSource.compareTo(b.distanceFromSource));

    return Column(
      children: [
        _sourcePicker(),
        _filterBar(),
        if (_scanning) _progressBar(),
        Expanded(
          child: filtered.isEmpty
              ? _emptyView()
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => FadeSlideIn(
                    delay: Duration(milliseconds: 30 + i * 30),
                    child: _campCard(filtered[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _autoTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _sourcePicker(),
        const SizedBox(height: 10),
        _bigStatusCard(),
        const SizedBox(height: 10),
        _autoControlsCard(),
        const SizedBox(height: 10),
        _autoSettingsCard(),
        const SizedBox(height: 10),
        _autoFilterCard(),
      ],
    );
  }

  Widget _bigStatusCard() {
    final effectivelyRunning = _autoEnabled && (_bgRunning || _auto.isRunning);
    final status = _auto.statusNotifier.value;

    Color c1, c2;
    IconData icon;
    String title;
    String subtitle;

    if (!_autoEnabled) {
      c1 = const Color(0xFF37474F);
      c2 = const Color(0xFF546E7A);
      icon = Icons.pause_rounded;
      title = 'Auto متوقف';
      subtitle = 'في انتظار التشغيل';
    } else if (_bgRunning && _bgStatusText == 'ONLINE') {
      c1 = const Color(0xFF16A34A);
      c2 = const Color(0xFF15803D);
      icon = Icons.bolt_rounded;
      title = '🔒 Auto في الخلفية ✓';
      subtitle = 'Background Service شغال · 24/7';
    } else if (_bgRunning) {
      c1 = const Color(0xFFF59E0B);
      c2 = const Color(0xFFB45309);
      icon = Icons.sync_rounded;
      title = '⏳ [BG] $_bgStatusText';
      subtitle = _bgStatusExtra.isNotEmpty ? _bgStatusExtra : 'جارٍ الاتصال...';
    } else if (_auto.isRunning) {
      c1 = const Color(0xFF2196F3);
      c2 = const Color(0xFF1565C0);
      icon = Icons.play_circle_rounded;
      title = '⚡ Auto في المقدمة ✓';
      subtitle = 'شغال فقط لما التطبيق مفتوح';
    } else {
      c1 = const Color(0xFFF59E0B);
      c2 = const Color(0xFFB45309);
      icon = Icons.warning_rounded;
      title = '⚠️ Auto مفعّل بس مش شغال';
      subtitle = 'شغّل Background Service';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c1, c2],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: c1.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.none)),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10.5,
                          decoration: TextDecoration.none),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(effectivelyRunning ? 'ON' : 'OFF',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.none)),
            ),
          ]),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('آخر status',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none)),
                const SizedBox(height: 4),
                Text(status,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _miniStat('معسكرات', _auto.campsScanned.toString())),
            Expanded(
                child: _miniStat('هجمات', _auto.attacksThisSession.toString())),
            Expanded(
                child: _miniStat('سجل', _auto.statusHistory.length.toString())),
          ]),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Column(children: [
      Text(value,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              decoration: TextDecoration.none)),
      Text(label,
          style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              decoration: TextDecoration.none)),
    ]);
  }

  Widget _autoControlsCard() {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(children: [
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _toggleAuto,
            icon: Icon(_autoEnabled
                ? Icons.stop_rounded
                : Icons.play_arrow_rounded),
            label: Text(_autoEnabled ? 'إيقاف Auto' : 'تشغيل Auto',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    decoration: TextDecoration.none)),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  _autoEnabled ? AppTheme.red : const Color(0xFF16A34A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 40,
          child: OutlinedButton.icon(
            onPressed: () async {
              await _auto.clearAllState();
              if (mounted) {
                _snack('🧹 تم مسح cooldowns', color: AppTheme.green);
              }
            },
            icon: const Icon(Icons.cleaning_services_rounded, size: 16),
            label: const Text('مسح الـ state',
                style: TextStyle(
                    fontSize: 12, decoration: TextDecoration.none)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.orange,
              side: const BorderSide(color: AppTheme.orange),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        if (!_autoEnabled && _selectedCommanderIds.isEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.5)),
            ),
            child: const Row(children: [
              Icon(Icons.warning_amber, color: Colors.orange, size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text('⚠️ محتاج تختار قواد أولاً',
                    style: TextStyle(
                        color: Colors.orange,
                        fontSize: 11,
                        decoration: TextDecoration.none)),
              ),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _autoSettingsCard() {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.settings_rounded, color: kBedouinGold, size: 18),
            const SizedBox(width: 8),
            Text('إعدادات الهجوم',
                style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    decoration: TextDecoration.none)),
          ]),
          const SizedBox(height: 12),

          // Attack Priority
          Text('أولوية الهجوم',
              style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.subTextColor(context),
                  decoration: TextDecoration.none)),
          const SizedBox(height: 6),
          Row(children: [
            _priorityChip('الأقرب', 'distance', Icons.place_rounded),
            const SizedBox(width: 8),
            _priorityChip('الأقل مستوى', 'level', Icons.trending_down_rounded),
            const SizedBox(width: 8),
            _priorityChip('الأقل جنود', 'troops', Icons.groups_rounded),
          ]),
          const SizedBox(height: 12),
          Divider(color: AppTheme.subTextColor(context).withOpacity(0.15)),
          const SizedBox(height: 8),

          // Waves
          Row(children: [
            Text('Waves:',
                style: TextStyle(
                    color: AppTheme.subTextColor(context),
                    fontSize: 12,
                    decoration: TextDecoration.none)),
            Expanded(
              child: Slider(
                value: _waves.toDouble(),
                min: 1, max: 3, divisions: 2,
                activeColor: kBedouinGold,
                label: '$_waves',
                onChanged: (v) async {
                  final w = v.round();
                  setState(() => _waves = w);
                  await _auto.setWaves(w);
                },
              ),
            ),
            Text('$_waves',
                style: const TextStyle(
                    color: kBedouinGold,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none)),
          ]),

          // Use Tools
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('استخدام الأدوات',
                style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textColor(context),
                    decoration: TextDecoration.none)),
            value: _useTools,
            activeColor: kBedouinGold,
            onChanged: (v) async {
              setState(() => _useTools = v);
              await _auto.setUseTools(v);
            },
          ),

          // Tool IDs per wave
          if (_useTools) ...[
            const SizedBox(height: 8),
            Text('أدوات كل موجة (WID)',
                style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subTextColor(context),
                    decoration: TextDecoration.none)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: _numberField('W1', '$_toolIdW1', _toolIdW1, (v) async {
                  setState(() => _toolIdW1 = v);
                  await _auto.setToolIds(w1: v);
                }),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _numberField('W2', '$_toolIdW2', _toolIdW2, (v) async {
                  setState(() => _toolIdW2 = v);
                  await _auto.setToolIds(w2: v);
                }),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _numberField('W3', '$_toolIdW3', _toolIdW3, (v) async {
                  setState(() => _toolIdW3 = v);
                  await _auto.setToolIds(w3: v);
                }),
              ),
            ]),
            const SizedBox(height: 8),
            Text('كميات الأدوات (L, M, R)',
                style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subTextColor(context),
                    decoration: TextDecoration.none)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: _numberField('L', '$_toolL', _toolL, (v) async {
                  setState(() => _toolL = v);
                  await _auto.setToolAmounts(l: v);
                }),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _numberField('M', '$_toolM', _toolM, (v) async {
                  setState(() => _toolM = v);
                  await _auto.setToolAmounts(m: v);
                }),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _numberField('R', '$_toolR', _toolR, (v) async {
                  setState(() => _toolR = v);
                  await _auto.setToolAmounts(r: v);
                }),
              ),
            ]),
          ],

          const SizedBox(height: 12),
          Divider(color: AppTheme.subTextColor(context).withOpacity(0.15)),
          const SizedBox(height: 8),

          // Delay
          Row(children: [
            Expanded(
              child: _numberField('تأخير أقل (s)', '$_delayMin', _delayMin,
                  (v) async {
                setState(() => _delayMin = v);
                await _auto.setDelay(min: v);
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _numberField('تأخير أكثر (s)', '$_delayMax', _delayMax,
                  (v) async {
                setState(() => _delayMax = v);
                await _auto.setDelay(max: v);
              }),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: _numberField('أقل وحدات', '$_minUnits', _minUnits,
                  (v) async {
                setState(() => _minUnits = v);
                await _auto.setMinUnits(v);
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _numberField('Max Lv', '$_maxLevel', _maxLevel,
                  (v) async {
                setState(() => _maxLevel = v);
                await _auto.setMaxLevel(v);
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _numberField('يومي', '0=∞', _maxAttacksDay, (v) async {
                setState(() => _maxAttacksDay = v);
                await _auto.setMaxAttacksDay(v);
              }),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _priorityChip(String label, String value, IconData icon) {
    final selected = _attackPriority == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => _saveAttackPriority(value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: selected
                ? kBedouinGold.withOpacity(0.2)
                : Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? kBedouinGold
                  : Colors.grey.withOpacity(0.2),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 18,
                  color: selected
                      ? kBedouinGold
                      : AppTheme.subTextColor(context)),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? kBedouinGold
                      : AppTheme.subTextColor(context),
                  fontSize: 10,
                  fontWeight:
                      selected ? FontWeight.bold : FontWeight.normal,
                  decoration: TextDecoration.none,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _autoFilterCard() {
    return AppTheme.glassCard(
      context: context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.tune_rounded, color: AppTheme.orange, size: 18),
            const SizedBox(width: 8),
            Text('فلتر القواد',
                style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    decoration: TextDecoration.none)),
          ]),
          const SizedBox(height: 10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.people_alt_rounded,
                color: kBedouinGold, size: 22),
            title: const Text('القواد المسموحين',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none)),
            subtitle: Text(
                _selectedCommanderIds.isEmpty
                    ? '⚠️ مفيش محدد — لازم تختار'
                    : '${_selectedCommanderIds.length} قائد مختار',
                style: TextStyle(
                    fontSize: 11,
                    color: _selectedCommanderIds.isEmpty
                        ? Colors.orange
                        : AppTheme.subTextColor(context),
                    decoration: TextDecoration.none)),
            trailing: const Icon(Icons.edit_rounded,
                color: kBedouinGold, size: 18),
            onTap: _openCommandersPicker,
          ),
        ],
      ),
    );
  }

  Widget _numberField(
    String label,
    String hint,
    int value,
    ValueChanged<int> onChanged,
  ) {
    return TextField(
      controller: TextEditingController(text: value.toString())
        ..selection =
            TextSelection.collapsed(offset: value.toString().length),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: TextStyle(
          color: AppTheme.textColor(context),
          fontSize: 13,
          fontWeight: FontWeight.bold),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(
            color: AppTheme.subTextColor(context), fontSize: 10),
        hintStyle: TextStyle(
            color: AppTheme.subTextColor(context).withOpacity(0.5),
            fontSize: 10),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: kBedouinGold.withOpacity(0.3))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: kBedouinGold)),
      ),
      onChanged: (s) {
        final v = int.tryParse(s) ?? 0;
        onChanged(v.clamp(0, 9999));
      },
    );
  }

  Widget _sourcePicker() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: AppTheme.glassCard(
        context: context,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: kBedouinGold.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.castle_rounded,
                  color: kBedouinGold, size: 18),
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
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() {
                      _source = v;
                      _settings.sourceAreaId = v.areaId;
                      _settings.save();
                    });
                    await _auto.setSource(
                      areaId: v.areaId,
                      kid: v.kingdomId,
                      x: v.x,
                      y: v.y,
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: _openRadiusDialog,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: kBedouinGold.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: kBedouinGold.withOpacity(0.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.place_rounded,
                    color: kBedouinGold, size: 14),
                const SizedBox(width: 6),
                Text('${_settings.radiusTiles} tile',
                    style: const TextStyle(
                        color: kBedouinGold,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none)),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: _scanning && _scanTotal > 0 ? _scanDone / _scanTotal : null,
          minHeight: 4,
          backgroundColor: kBedouinGold.withOpacity(0.1),
          valueColor: const AlwaysStoppedAnimation(kBedouinGold),
        ),
      ),
    );
  }

  Widget _emptyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: kBedouinGold.withOpacity(0.12),
                shape: BoxShape.circle,
                border: Border.all(color: kBedouinGold.withOpacity(0.3)),
              ),
              child: Icon(Icons.castle_rounded,
                  size: 48, color: kBedouinGold.withOpacity(0.7)),
            ),
            const SizedBox(height: 16),
            Text('مفيش معسكرات لسه',
                style: TextStyle(
                    color: AppTheme.textColor(context),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none)),
            const SizedBox(height: 4),
            Text('دوس "مسح" عشان تبدأ',
                style: TextStyle(
                    color: AppTheme.subTextColor(context),
                    fontSize: 11,
                    decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }

  Widget _campCard(BedouinCamp c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _openCampSheet(c),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.isDark(context)
                ? Colors.white.withOpacity(0.04)
                : Colors.black.withOpacity(0.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kBedouinGold, width: 1.3),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: kBedouinGold.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.castle_rounded,
                    color: kBedouinGold, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(c.coordsLabel,
                          style: TextStyle(
                              color: AppTheme.textColor(context),
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              decoration: TextDecoration.none)),
                      const SizedBox(width: 8),
                      _pill('Lv ${c.level}', kBedouinLightBlue),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      Text('جنود: ${c.totalTroops}',
                          style: TextStyle(
                              color: AppTheme.subTextColor(context),
                              fontSize: 10.5,
                              decoration: TextDecoration.none)),
                      const SizedBox(width: 8),
                      Icon(Icons.straighten_rounded,
                          size: 11,
                          color: AppTheme.subTextColor(context)),
                      const SizedBox(width: 2),
                      Text('${c.distanceFromSource.toStringAsFixed(0)}t',
                          style: TextStyle(
                              color: AppTheme.subTextColor(context),
                              fontSize: 10.5,
                              decoration: TextDecoration.none)),
                    ]),
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
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.6)),
        ),
        child: Text(text,
            style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none)),
      );

  Future<void> _openCampSheet(BedouinCamp c) async {
    final result = await showModalBottomSheet<BedouinAttackResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BedouinAttackSheet(
        client: widget.client,
        source: _source!,
        camp: c,
        svc: _svc,
        waves: _waves,
        useTools: _useTools,
        toolIdW1: _toolIdW1,
        toolIdW2: _toolIdW2,
        toolIdW3: _toolIdW3,
        toolL: _toolL,
        toolM: _toolM,
        toolR: _toolR,
      ),
    );
    if (result != null && result.success && mounted) {
      _snack(
        '✅ ${result.wavesSent} waves · ${result.totalUnits} وحدة'
        '${result.toolsUsed > 0 ? " · ${result.toolsUsed} أداة" : ""}',
        color: AppTheme.green,
      );
    }
  }

  void _openRadiusDialog() {
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
              min: 10, max: 100,
              divisions: 18,
              activeColor: kBedouinGold,
              label: '${temp.toInt()}',
              onChanged: (v) => setSt(
                  () => temp = (v / 5).round() * 5.0),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () async {
                setState(() {
                  _settings.radiusTiles = temp.toInt();
                });
                await _settings.save();
                await _auto.setRadius(temp.toInt());
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('موافق'),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
//  Multi-Select Sheet
// ═══════════════════════════════════════════════════

class _SelectItem {
  final int id;
  final String label;
  final String? subtitle;
  _SelectItem({required this.id, required this.label, this.subtitle});
}

class _MultiSelectSheet extends StatefulWidget {
  final String title;
  final List<_SelectItem> items;
  final Set<int> selected;
  final bool allowEmpty;
  final bool emptyMeansAll;

  const _MultiSelectSheet({
    required this.title,
    required this.items,
    required this.selected,
    this.allowEmpty = true,
    this.emptyMeansAll = false,
  });

  @override
  State<_MultiSelectSheet> createState() => _MultiSelectSheetState();
}

class _MultiSelectSheetState extends State<_MultiSelectSheet> {
  late Set<int> _sel;

  @override
  void initState() {
    super.initState();
    _sel = Set.from(widget.selected);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.8,
      decoration: const BoxDecoration(
        color: Color(0xFF0B0B14),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(children: [
          Container(
              width: 44, height: 5,
              margin: const EdgeInsets.only(top: 10, bottom: 12),
              decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(3))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Icon(Icons.checklist_rounded,
                  color: kBedouinGold, size: 20),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(widget.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.none))),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (_sel.length == widget.items.length) {
                      _sel.clear();
                    } else {
                      _sel = widget.items.map((e) => e.id).toSet();
                    }
                  });
                },
                child: Text(_sel.length == widget.items.length
                    ? 'إلغاء الكل'
                    : 'تحديد الكل',
                    style: const TextStyle(
                        color: kBedouinGold, fontSize: 11)),
              ),
            ]),
          ),
          const Divider(color: Colors.white12),
          Expanded(
            child: ListView.builder(
              itemCount: widget.items.length,
              itemBuilder: (_, i) {
                final it = widget.items[i];
                final sel = _sel.contains(it.id);
                return CheckboxListTile(
                  value: sel,
                  activeColor: kBedouinGold,
                  title: Text(it.label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          decoration: TextDecoration.none)),
                  subtitle: it.subtitle != null
                      ? Text(it.subtitle!,
                          style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 10,
                              decoration: TextDecoration.none))
                      : null,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _sel.add(it.id);
                      } else {
                        _sel.remove(it.id);
                      }
                    });
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: const Text('إلغاء'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, _sel),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: kBedouinGold,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: const Text('حفظ',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
//  Manual Attack Sheet
// ═══════════════════════════════════════════════════

class _BedouinAttackSheet extends StatefulWidget {
  final GgeClient client;
  final OwnedCastle source;
  final BedouinCamp camp;
  final BedouinService svc;
  final int waves;
  final bool useTools;
  final int toolIdW1;
  final int toolIdW2;
  final int toolIdW3;
  final int toolL;
  final int toolM;
  final int toolR;

  const _BedouinAttackSheet({
    required this.client,
    required this.source,
    required this.camp,
    required this.svc,
    required this.waves,
    required this.useTools,
    required this.toolIdW1,
    required this.toolIdW2,
    required this.toolIdW3,
    required this.toolL,
    required this.toolM,
    required this.toolR,
  });

  @override
  State<_BedouinAttackSheet> createState() => _BedouinAttackSheetState();
}

class _BedouinAttackSheetState extends State<_BedouinAttackSheet> {
  List<CastleUnit> _units = [];
  List<CommanderInfo> _commanders = [];
  Lord? _selectedLord;

  late int _waves;
  late bool _useTools;
  late int _toolIdW1;
  late int _toolIdW2;
  late int _toolIdW3;
  late int _toolL;
  late int _toolM;
  late int _toolR;

  bool _loading = true;
  bool _sending = false;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _waves = widget.waves;
    _useTools = widget.useTools;
    _toolIdW1 = widget.toolIdW1;
    _toolIdW2 = widget.toolIdW2;
    _toolIdW3 = widget.toolIdW3;
    _toolL = widget.toolL;
    _toolM = widget.toolM;
    _toolR = widget.toolR;
    _load();
  }

  Future<void> _load() async {
    try {
      final catalog = await widget.client.loadCatalog();
      final units = await widget.client.getCastleUnits(
          widget.source.kingdomId, widget.source.areaId, catalog);
      final sendable =
          units.where((u) => u.isCombat && u.amount > 0).toList();
      final cmds = await widget.client.getCommanders();

      if (!mounted) return;
      setState(() {
        _units = sendable;
        _commanders = cmds;
        final free = cmds.where((c) => !c.isBusy).toList();
        if (free.isNotEmpty) {
          try {
            _selectedLord =
                free.firstWhere((c) => c.lord.id != 0).lord;
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

  int get _totalUnits => _units.fold<int>(0, (s, u) => s + u.amount);

  Future<void> _attack() async {
    if (_selectedLord == null) {
      setState(() => _lastError = 'اختر قائد');
      return;
    }
    if (_units.isEmpty) {
      setState(() => _lastError = 'مفيش وحدات');
      return;
    }

    setState(() {
      _sending = true;
      _lastError = null;
    });

    final config = BedouinAttackConfig(
      waves: _waves,
      useTools: _useTools,
      toolIdWave1: _toolIdW1,
      toolIdWave2: _toolIdW2,
      toolIdWave3: _toolIdW3,
      toolL: _toolL,
      toolM: _toolM,
      toolR: _toolR,
    );

    final fallback = _commanders
        .where((c) => !c.isBusy)
        .map((c) => c.lord)
        .toList();

    final res = await widget.svc.attack(
      camp: widget.camp,
      source: widget.source,
      lordId: _selectedLord!.id,
      availableUnits: _units,
      allUnitsForTools: _units,
      config: config,
      fallbackLords: fallback,
    );

    if (!mounted) return;
    setState(() => _sending = false);

    if (res.success) {
      Navigator.pop(context, res);
    } else {
      setState(() => _lastError = res.error ?? 'فشل');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.camp;
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
            Container(
              width: 44, height: 5,
              margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(3))),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [kBedouinGold, kBedouinBlue]),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.castle_rounded,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Bedouin ${c.coordsLabel}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              decoration: TextDecoration.none)),
                      Text('Lv ${c.level} · ${c.totalTroops} troops · $_totalUnits وحدة',
                          style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              decoration: TextDecoration.none)),
                    ],
                  ),
                ),
                IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context)),
              ]),
            ),
            const Divider(),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: kBedouinGold))
                  : ListView(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      children: [
                        if (_lastError != null) _errorBanner(),
                        _lordSection(),
                        const SizedBox(height: 12),
                        _configCard(),
                      ],
                    ),
            ),
            SafeArea(
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
                        _sending ? 'جارٍ الإرسال...' : 'هجوم',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            decoration: TextDecoration.none)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kBedouinGold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
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

  Widget _errorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.red.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.red.withOpacity(0.5)),
      ),
      child: Row(children: [
        const Icon(Icons.error_outline, color: AppTheme.red, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(_lastError!,
              style: const TextStyle(
                  color: AppTheme.red,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none)),
        ),
      ]),
    );
  }

  Widget _configCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBedouinGold.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.settings_rounded, color: kBedouinGold, size: 16),
            SizedBox(width: 6),
            Text('⚙️ إعدادات الأمر',
                style: TextStyle(
                    color: kBedouinGold,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Waves:',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    decoration: TextDecoration.none)),
            Expanded(
              child: Slider(
                value: _waves.toDouble(),
                min: 1, max: 3, divisions: 2,
                activeColor: kBedouinGold,
                label: '$_waves',
                onChanged: (v) => setState(() => _waves = v.round()),
              ),
            ),
            Text('$_waves',
                style: const TextStyle(
                    color: kBedouinGold,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none)),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('استخدام الأدوات',
                style: TextStyle(
                    fontSize: 12, decoration: TextDecoration.none)),
            value: _useTools,
            activeColor: kBedouinGold,
            onChanged: (v) => setState(() => _useTools = v),
          ),
          if (_useTools) ...[
            const SizedBox(height: 8),
            const Text('Tool IDs per Wave:',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    decoration: TextDecoration.none)),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(child: _toolField('W1', _toolIdW1,
                  (v) => setState(() => _toolIdW1 = v))),
              const SizedBox(width: 6),
              Expanded(child: _toolField('W2', _toolIdW2,
                  (v) => setState(() => _toolIdW2 = v))),
              const SizedBox(width: 6),
              Expanded(child: _toolField('W3', _toolIdW3,
                  (v) => setState(() => _toolIdW3 = v))),
            ]),
            const SizedBox(height: 8),
            const Text('Tool Amounts (L, M, R):',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    decoration: TextDecoration.none)),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(child: _toolField('L', _toolL,
                  (v) => setState(() => _toolL = v))),
              const SizedBox(width: 6),
              Expanded(child: _toolField('M', _toolM,
                  (v) => setState(() => _toolM = v))),
              const SizedBox(width: 6),
              Expanded(child: _toolField('R', _toolR,
                  (v) => setState(() => _toolR = v))),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _toolField(String label, int val, ValueChanged<int> onCh) {
    return TextFormField(
      key: ValueKey('${label}_$val'),
      initialValue: val.toString(),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: TextAlign.center,
      style: const TextStyle(
          color: kBedouinGold,
          fontWeight: FontWeight.bold,
          fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:
            const TextStyle(color: Colors.white54, fontSize: 10),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: kBedouinGold),
        ),
      ),
      onChanged: (s) => onCh(int.tryParse(s) ?? 0),
    );
  }

  Widget _lordSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('القائد',
            style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none)),
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
}