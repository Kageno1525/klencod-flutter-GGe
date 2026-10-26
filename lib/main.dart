import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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

  unawaited(NotificationsService.init().catchError((e) {
    debugPrint('[Init] NotificationsService: $e');
  }));
  unawaited(BackgroundService.init().catchError((e) {
    debugPrint('[Init] BackgroundService: $e');
  }));
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
    unawaited(_logBgWsStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    GgeClient().onAppLifecycleChanged(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(_logBgWsStatus());
    }
  }

  Future<void> _logBgWsStatus() async {
    try {
      final p = await SharedPreferences.getInstance();
      final status = p.getString('bg_ws_status');
      final time = p.getString('bg_ws_time');
      final msgs = p.getInt('bg_ws_msgs');
      if (status != null) {
        TrafficLog.add('ST',
            '[BG Status] $status @ ${time ?? "?"} (msgs=${msgs ?? 0})');
      } else {
        TrafficLog.add('ST', '[BG Status] never ran');
      }
    } catch (_) {}
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