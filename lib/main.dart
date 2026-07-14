// lib/main.dart
// UniTrack — Main Application Entry Point

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'firebase_options.dart';
import 'services/background_service.dart';
import 'services/firebase_globals.dart';
import 'services/stoppage_notification_service.dart';
import 'services/student_background_service.dart';
import 'screens/splash_screen.dart';
import 'screens/login/login_screen.dart';
import 'screens/driver/driver_dash_screen.dart';
import 'screens/student/student_home_screen.dart' show StudentHomeScreen;
import 'screens/student/stoppage_timeline_screen.dart'
    show StoppageTimelineScreen;
import 'screens/shared/map_screen.dart'
    show StudentMapScreen, TeacherMapScreen, MapScreenArgs;
import 'theme/app_color.dart';
import 'theme/app_text_styles.dart';

@pragma('vm:entry-point')
void startCallback() {}

// ─────────────────────────────────────────────────────────────────────────────
// WATCHDOG INITIALIZATION
// ─────────────────────────────────────────────────────────────────────────────

Future<void> initWatchdog() async {
  if (!Platform.isAndroid) return;
  try {
    await AndroidAlarmManager.initialize();
    debugPrint('[Watchdog] AlarmManager initialized');
  } catch (e) {
    debugPrint('[Watchdog] Failed to initialize AlarmManager: $e');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PREF KEYS
// ─────────────────────────────────────────────────────────────────────────────

class PrefKeys {
  static const String isLoggedIn = 'is_logged_in';
  static const String userId = 'user_id';
  static const String userBatch = 'user_batch';
  static const String userRole = 'user_role';
  static const String userName = 'user_name';
  static const String selectedBusId = 'selected_bus_id';
  static const String trackMode = 'track_mode';
  static const String driverName = 'driver_name';
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final mapsImpl = GoogleMapsFlutterPlatform.instance;
  if (mapsImpl is GoogleMapsFlutterAndroid) {
    mapsImpl.initializeWithRenderer(AndroidMapRenderer.legacy);
  }

  // ── FIX 1: initForegroundTask এর পরেই setTaskHandler call করতে হবে ──────
  // এই লাইন ছাড়া app kill হলে background isolate কোনো GPS tracking করে না।
  BackgroundService.initForegroundTask();
  FlutterForegroundTask.setTaskHandler(UniTrackTaskHandler()); // ✅ ADDED

  // ── Initialize AlarmManager watchdog for OEM battery optimization workaround ──────
  await initWatchdog();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  globalDB = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL:
        'https://uni-bus-locate-default-rtdb.asia-southeast1.firebasedatabase.app',
  );

  globalDB.setPersistenceEnabled(true);
  globalDB.ref('buses').keepSynced(true);

  globalPrefs = await SharedPreferences.getInstance();

  // Initialize stoppage ETA notification service
  await stoppageNotificationService.init();

  // Initialize student background service
  StudentBackgroundService.initForegroundTask();

  runApp(const ProviderScope(child: UniTrackApp()));
}

// ─────────────────────────────────────────────────────────────────────────────
// APP
// ─────────────────────────────────────────────────────────────────────────────

class UniTrackApp extends StatelessWidget {
  const UniTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'UniTrack',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.light,
        theme: _buildLightTheme(),
        initialRoute: '/splash',
        routes: {
          '/': (ctx) => const SplashScreen(),
          '/splash': (ctx) => const SplashScreen(),
          '/login': (ctx) => const LoginScreen(),
          '/driver/dashboard': (ctx) => const DriverDashScreen(),
          '/student/home': (ctx) => const StudentHomeScreen(),
        },
        onGenerateRoute: (settings) {
          switch (settings.name) {
            case '/student/map':
              final args = settings.arguments;
              final String? busId = args is MapScreenArgs
                  ? args.busId
                  : (args is String ? args : null);
              return MaterialPageRoute(
                builder: (_) => StudentMapScreen(busId: busId),
                settings: settings,
              );

            case '/student/timeline':
              final args = settings.arguments as MapScreenArgs?;
              return MaterialPageRoute(
                builder: (_) => StoppageTimelineScreen(
                  busId: args?.busId ?? '',
                  busName: args?.busName ?? 'Bus',
                  route: args?.route ?? '',
                ),
                settings: settings,
              );

            case '/teacher/map':
              final args = settings.arguments;
              final String? busId = args is MapScreenArgs
                  ? args.busId
                  : (args is String ? args : null);
              return MaterialPageRoute(
                builder: (_) => TeacherMapScreen(busId: busId),
                settings: settings,
              );
          }

          return MaterialPageRoute(
            builder: (_) => Scaffold(
              body: Center(
                child: Text(
                  'No route defined for ${settings.name}',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  ThemeData _buildLightTheme() {
    return ThemeData(
      useMaterial3: true,
      fontFamily: AppTextStyles.fontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
        primary: AppColors.primary,
        onPrimary: Colors.white,
        secondary: AppColors.accent,
        onSecondary: Colors.white,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        error: AppColors.errorRed,
      ),
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppTextStyles.headlineMedium,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.textDisabled,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          minimumSize: const Size(double.infinity, 52),
          textStyle: const TextStyle(
            fontFamily: AppTextStyles.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: AppColors.primary, width: 1.5),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          minimumSize: const Size(double.infinity, 52),
          textStyle: const TextStyle(
            fontFamily: AppTextStyles.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          textStyle: const TextStyle(
            fontFamily: AppTextStyles.fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.divider, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.divider, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.errorRed, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.errorRed, width: 2),
        ),
        labelStyle: AppTextStyles.bodyMedium,
        hintStyle:
            AppTextStyles.bodyMedium.copyWith(color: AppColors.textDisabled),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.divider, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surface,
        selectedColor: AppColors.primary.withValues(alpha: 0.12),
        labelStyle: AppTextStyles.labelSmall,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.divider,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.textPrimary,
        contentTextStyle:
            AppTextStyles.bodyMedium.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.background,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textDisabled,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(
          fontFamily: AppTextStyles.fontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: AppTextStyles.fontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w400,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
      ),
    );
  }
}
