// lib/screens/splash_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_providers.dart';
import 'login/login_screen.dart';
// ✅ FIXED: DriverModeScreen → DriverDashScreen
import 'driver/driver_dash_screen.dart';
import 'student/student_home_screen.dart' show StudentHomeScreen;
import '../models/user_model.dart';
import '../theme/app_color.dart';
import '../theme/app_text_styles.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SplashScreen
// ─────────────────────────────────────────────────────────────────────────────

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _taglineOpacity;
  late final Animation<Offset> _taglineSlide;
  late final Animation<double> _dotOpacity;

  // ── splash colors from canonical theme ─────────────────────────────────────
  static const _primary = AppColors.navy;
  static const _accent = AppColors.accent;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _ctrl.forward();
    Future.delayed(const Duration(milliseconds: 2600), _navigate);
  }

  void _setupAnimations() {
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack),
      ),
    );

    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );

    _taglineOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.4, 0.8, curve: Curves.easeOut),
      ),
    );

    _taglineSlide = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.4, 0.8, curve: Curves.easeOut),
    ));

    _dotOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.75, 1.0, curve: Curves.easeIn),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ── Navigation logic ──────────────────────────────────────────────────────
  Future<void> _navigate() async {
    if (!mounted) return;

    final authState = ref.read(authProvider);

    if (authState.status == AuthStatus.initial) {
      Future.delayed(const Duration(milliseconds: 300), _navigate);
      return;
    }

    switch (authState.status) {
      case AuthStatus.unauthenticated:
        _push(const LoginScreen());
        break;
      case AuthStatus.authenticated:
        _push(const LoginScreen());
        break;
      case AuthStatus.roleSelected:
        final role = authState.role;
        if (role == UserRole.driver) {
          // ✅ FIXED: DriverModeScreen → DriverDashScreen
          _push(const DriverDashScreen());
        } else if (role == UserRole.student) {
          _push(const StudentHomeScreen());
        } else {
          _push(const LoginScreen());
        }
        break;
      default:
        Future.delayed(const Duration(milliseconds: 300), _navigate);
        break;
    }
  }

  void _push(Widget screen) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, animation, __) => screen,
        transitionDuration: const Duration(milliseconds: 500),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOut,
          ),
          child: child,
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _primary,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _BackgroundPattern()),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: _ctrl,
                    builder: (_, __) => Opacity(
                      opacity: _logoOpacity.value,
                      child: Transform.scale(
                        scale: _logoScale.value,
                        child: _LogoMark(primary: _primary, accent: _accent),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  AnimatedBuilder(
                    animation: _ctrl,
                    builder: (_, __) => Opacity(
                      opacity: _logoOpacity.value,
                      child: const Text(
                        'UniTrack',
                        style: TextStyle(
                          fontFamily: AppTextStyles.fontFamily,
                          fontSize: 38,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: -1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  AnimatedBuilder(
                    animation: _ctrl,
                    builder: (_, __) => Opacity(
                      opacity: _taglineOpacity.value,
                      child: SlideTransition(
                        position: _taglineSlide,
                        child: const Text(
                          'University Bus Live Tracking',
                          style: TextStyle(
                            fontFamily: AppTextStyles.fontFamily,
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            color: Colors.white70,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) => Opacity(
                  opacity: _dotOpacity.value,
                  child: const Column(
                    children: [
                      _LoadingDots(),
                      SizedBox(height: 16),
                      Text(
                        'v1.0.0',
                        style: TextStyle(
                          fontFamily: AppTextStyles.fontFamily,
                          fontSize: 12,
                          color: Colors.white38,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Logo Mark
// ─────────────────────────────────────────────────────────────────────────────

class _LogoMark extends StatelessWidget {
  final Color primary;
  final Color accent;
  const _LogoMark({required this.primary, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Center(
        child: CustomPaint(
          size: const Size(52, 52),
          painter: _BusPainter(primary: primary, accent: accent),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bus Painter
// ─────────────────────────────────────────────────────────────────────────────

class _BusPainter extends CustomPainter {
  final Color primary;
  final Color accent;
  const _BusPainter({required this.primary, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = primary;
    final windowPaint = Paint()..color = Colors.white;
    final greenPaint = Paint()..color = accent;

    // Bus body
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, size.height * 0.12, size.width, size.height * 0.62),
        const Radius.circular(6),
      ),
      paint,
    );

    // Windshield
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * 0.08,
          size.height * 0.18,
          size.width * 0.84,
          size.height * 0.22,
        ),
        const Radius.circular(4),
      ),
      windowPaint,
    );

    // Left window
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * 0.06,
          size.height * 0.47,
          size.width * 0.37,
          size.height * 0.18,
        ),
        const Radius.circular(3),
      ),
      windowPaint,
    );

    // Right window
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * 0.57,
          size.height * 0.47,
          size.width * 0.37,
          size.height * 0.18,
        ),
        const Radius.circular(3),
      ),
      windowPaint,
    );

    // Left wheel
    canvas.drawCircle(Offset(size.width * 0.23, size.height * 0.84),
        size.width * 0.12, paint);
    canvas.drawCircle(Offset(size.width * 0.23, size.height * 0.84),
        size.width * 0.065, windowPaint);

    // Right wheel
    canvas.drawCircle(Offset(size.width * 0.77, size.height * 0.84),
        size.width * 0.12, paint);
    canvas.drawCircle(Offset(size.width * 0.77, size.height * 0.84),
        size.width * 0.065, windowPaint);

    // Live ping dot
    canvas.drawCircle(Offset(size.width * 0.88, size.height * 0.06),
        size.width * 0.09, greenPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Loading Dots
// ─────────────────────────────────────────────────────────────────────────────

class _LoadingDots extends StatefulWidget {
  const _LoadingDots();

  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final start = i * 0.2;
        final end = (start + 0.4).clamp(0.0, 1.0);
        final anim = Tween<double>(begin: 0.3, end: 1.0).animate(
          CurvedAnimation(
            parent: _ctrl,
            curve: Interval(start, end, curve: Curves.easeInOut),
          ),
        );
        return AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => Opacity(
            opacity: anim.value,
            child: Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Background Pattern
// ─────────────────────────────────────────────────────────────────────────────

class _BackgroundPattern extends StatelessWidget {
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _PatternPainter());
}

class _PatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final circlePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (var i = 1; i <= 8; i++) {
      canvas.drawCircle(
        Offset(size.width * 0.95, size.height * 0.95),
        i * size.width * 0.18,
        circlePaint,
      );
    }

    final dotPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..style = PaintingStyle.fill;

    for (var row = 0; row < 6; row++) {
      for (var col = 0; col < 4; col++) {
        canvas.drawCircle(
          Offset(28.0 + col * 36, 40.0 + row * 36),
          2.5,
          dotPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
