// lib/main.dart
// UniTrack — Main Application Entry Point

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'firebase_options.dart';
import 'services/background_service.dart';
import 'services/firebase_globals.dart';
import 'services/stoppage_notification_service.dart';
import 'screens/splash_screen.dart';
import 'screens/login/login_screen.dart';
import 'screens/driver/driver_dash_screen.dart';
import 'screens/student/student_home_screen.dart' show StudentHomeScreen;
import 'screens/shared/map_screen.dart'
    show StudentMapScreen, TeacherMapScreen, MapScreenArgs;

@pragma('vm:entry-point')
void startCallback() {}

// ─────────────────────────────────────────────────────────────────────────────
// APP COLORS
// ─────────────────────────────────────────────────────────────────────────────

class AppColors {
  static const primary = Color(0xFF1B2CC1);
  static const primaryDark = Color(0xFF1222A0);
  static const primaryLight = Color(0xFF3D50D4);
  static const accent = Color(0xFF00C853);
  static const accentAmber = Color(0xFFFFC107);
  static const accentRed = Color(0xFFE53935);
  static const background = Color(0xFFFFFFFF);
  static const surface = Color(0xFFF5F6FF);
  static const surfaceCard = Color(0xFFFFFFFF);
  static const textPrimary = Color(0xFF0D1333);
  static const textSecondary = Color(0xFF6B7280);
  static const textDisabled = Color(0xFFB0B8D1);
  static const divider = Color(0xFFE8EAF6);
  static const shadow = Color(0x141B2CC1);
}

// ─────────────────────────────────────────────────────────────────────────────
// APP TEXT STYLES
// ─────────────────────────────────────────────────────────────────────────────

class AppTextStyles {
  static const String fontFamily = 'DM Sans';

  static const displayLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.5,
  );
  static const displayMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 26,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.3,
  );
  static const headlineLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static const headlineMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static const titleMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static const titleSmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static const bodyLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );
  static const bodyMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );
  static const bodySmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );
  static const labelLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.primary,
    letterSpacing: 0.4,
  );
  static const labelSmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
    letterSpacing: 0.5,
  );
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
          '/splash': (ctx) => const SplashScreen(),
          '/login': (ctx) => const LoginScreen(),
          '/driver/dashboard': (ctx) => const DriverDashScreen(),
          '/student/home': (ctx) => const StudentHomeScreen(),
        },
        onGenerateRoute: (settings) {
          switch (settings.name) {
            case '/student/map':
              final args = settings.arguments;
              final busId = args is MapScreenArgs
                  ? args.busId
                  : (args is String ? args : '');
              return MaterialPageRoute(
                builder: (_) => StudentMapScreen(busId: busId),
                settings: settings,
              );

            case '/teacher/map':
              final args = settings.arguments;
              final busId = args is MapScreenArgs
                  ? args.busId
                  : (args is String ? args : '');
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
        error: AppColors.accentRed,
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
          borderSide: const BorderSide(color: AppColors.accentRed, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accentRed, width: 2),
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
        selectedColor: AppColors.primary.withOpacity(0.12),
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
