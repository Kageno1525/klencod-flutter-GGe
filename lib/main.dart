import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gge/gge_client.dart';
import 'package:gge/l10n/strings.dart';
import 'package:gge/models.dart';
import 'package:gge/theme.dart';
import 'package:gge/screens/login_screen.dart';
import 'package:gge/services/notifications_service.dart';
import 'package:gge/services/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  bool dark = true;
  Locale locale = const Locale('ar');
  try {
    dark = await AppStorage.getDarkMode()
        .timeout(const Duration(seconds: 2), onTimeout: () => true);
    final lang = await AppStorage.getLanguageCode()
        .timeout(const Duration(seconds: 2), onTimeout: () => 'ar');
    locale = Locale(lang);
  } catch (_) {}
  S.current = locale;

  runApp(GgeApp(initialDark: dark));

  // ✅ Init + stop BG if user is logged out
  unawaited(BackgroundService.init().then((_) async {
    try {
      final loggedIn = await AppStorage.getLoggedIn();
      if (!loggedIn) {
        final isRunning = await FlutterForegroundTask.isRunningService;
        if (isRunning) {
          debugPrint('[Init] Logged out but BG running → stopping service');
          await BackgroundService.stop();
        }
      }
    } catch (e) {
      debugPrint('[Init] BG cleanup: $e');
    }
  }).catchError((e) {
    debugPrint('[Init] BackgroundService: $e');
  }));

  unawaited(NotificationsService.init().catchError((e) {
    debugPrint('[Init] NotificationsService: $e');
  }));

  try {
    FlutterForegroundTask.addTaskDataCallback((data) {
      if (data is String) {
        TrafficLog.add('ST', '[BG-IN] $data');
      }
    });
  } catch (e) {
    debugPrint('[Init] addTaskDataCallback: $e');
  }
}

class GgeApp extends StatefulWidget {
  final bool initialDark;
  const GgeApp({super.key, required this.initialDark});

  static GgeAppState of(BuildContext context) =>
      context.findAncestorStateOfType<GgeAppState>()!;

  @override
  State<GgeApp> createState() => GgeAppState();
}

class GgeAppState extends State<GgeApp> with WidgetsBindingObserver {
  late bool _isDark;
  late Locale _locale;

  bool get isDark => _isDark;
  Locale get locale => _locale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isDark = widget.initialDark;
    _locale = S.current;
    unawaited(_updateForegroundState(true));
    unawaited(_logBgWsStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ✅ FIX: نستنى الـ async كامل قبل أي إجراء
    unawaited(_handleLifecycleChange(state));
  }

  Future<void> _handleLifecycleChange(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      await _handleResume();
    } else if (state == AppLifecycleState.paused) {
      await _handlePause();
    }
  }

  Future<void> _handleResume() async {
    // 1) اكتب flag أول حاجة عشان BG يشوفه
    await _updateForegroundState(true);

    // 2) ابعت signal للـ BG
    try {
      FlutterForegroundTask.sendDataToTask('UI_RESUMED');
      TrafficLog.add('ST', '[Lifecycle] → BG: UI_RESUMED');
    } catch (_) {}

    // 3) استنى BG يعلن إنه ساب الاتصال (بحد أقصى 5 ثواني)
    final released = await _waitForBgRelease(const Duration(seconds: 5));
    TrafficLog.add('ST', '[Lifecycle] BG released=$released');

    // 4) دلوقتي بس نسمح للـ UI يعيد الاتصال
    GgeClient().onAppLifecycleChanged(AppLifecycleState.resumed);

    unawaited(_logBgWsStatus());
  }

  Future<void> _handlePause() async {
    // 1) اكتب flag أول حاجة
    await _updateForegroundState(false);

    // 2) ابعت signal
    try {
      FlutterForegroundTask.sendDataToTask('UI_PAUSED');
      TrafficLog.add('ST', '[Lifecycle] → BG: UI_PAUSED');
    } catch (_) {}

    // 3) خلي الـ client يقفل الـ WS
    GgeClient().onAppLifecycleChanged(AppLifecycleState.paused);
  }

  Future<bool> _waitForBgRelease(Duration timeout) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start) < timeout) {
      try {
        final status =
            await FlutterForegroundTask.getData<String>(key: 'bg_status');
        // ✅ الحالات اللي معناها BG مش ماسك الاتصال
        if (status == null ||
            status == 'never ran' ||
            status == 'NO_TOKEN' ||
            status == 'STOPPED' ||
            status == 'DESTROYED' ||
            status == 'RELEASED' ||
            status == 'CONNECT_FAILED' ||
            status == 'SESSION_CONFLICT' ||
            status == 'SUSPICIOUS_CLOSE') {
          return true;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<void> _updateForegroundState(bool isForeground) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_app_foreground', isForeground);
      TrafficLog.add('ST', '[Lifecycle] App Foreground: $isForeground');
    } catch (_) {}
  }

  Future<void> _logBgWsStatus() async {
    try {
      final info = await BackgroundService.readStatus();
      TrafficLog.add('ST',
          '[BG Status] ${info['status']} @ ${info['time']}');
    } catch (e) {
      TrafficLog.add('ER', '[BG Status] read failed: $e');
    }
  }

  Future<void> toggleTheme() async {
    setState(() => _isDark = !_isDark);
    await AppStorage.setDarkMode(_isDark);
  }

  Future<void> toggleLocale() async {
    final newCode = S.isAr ? 'en' : 'ar';
    S.current = Locale(newCode);
    await AppStorage.setLanguageCode(newCode);
    setState(() => _locale = S.current);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GGE Bot',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      locale: _locale,
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => Directionality(
        textDirection: S.isAr ? TextDirection.rtl : TextDirection.ltr,
        child: child!,
      ),
      home: const LoginScreen(),
    );
  }
}