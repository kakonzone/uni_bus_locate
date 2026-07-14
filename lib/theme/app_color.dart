// lib/theme/app_color.dart

import 'package:flutter/material.dart';

/// Centralized color palette for UniTrack.
///
/// Canonical navy: `0xFF1B2CC1` (previously also seen as `0xFF1222A0`,
/// `0xFF1323A8`, `0xFF3547D4`, `0xFF1221A0`, `0xFF1220A0` in local copies).
class AppColors {
  AppColors._();

  // ── Brand ──────────────────────────────────────────
  static const Color navy = Color(0xFF1B2CC1);
  static const Color navyDark = Color(0xFF1221A3);
  static const Color navyLight = Color(0xFF2D3FD4);
  static const Color navySurface = Color(0xFFE8EAFC);
  static const Color navySurfaceAlt = Color(0xFFEEF0FD);
  static const Color navyMuted = Color(0xFFE8EAFB);
  static const Color navyGlow = Color(0xFFE8EAFB);
  static const Color tickerNavy = Color(0xFF0E1B8C);

  /// Aliases used by theme / login / main (map to navy family).
  static const Color primary = navy;
  static const Color primaryDark = Color(0xFF1222A0);
  static const Color primaryLight = Color(0xFF3D50D4);

  // ── Status ─────────────────────────────────────────
  static const Color green = Color(0xFF22C55E);
  static const Color activeGreen = Color(0xFF18C761);
  static const Color activeGreenBg = Color(0xFFDCFCE7);
  static const Color greenBg = activeGreenBg;
  static const Color greenLight = Color(0xFFDCFCE7);
  static const Color redBg = Color(0xFFFEF2F2);
  static const Color amber = Color(0xFFF59E0B);
  static const Color amberSoft = Color(0xFFFFF8E1);
  static const Color warningAmber = Color(0xFFFF9800);
  static const Color red = Color(0xFFEF4444);
  static const Color errorRed = Color(0xFFE53935);
  static const Color error = errorRed;
  static const Color accentAmber = Color(0xFFFFC107);

  // ── Accent (login/splash legacy) ───────────────────
  static const Color accent = Color(0xFF00C853);

  // ── Surface ────────────────────────────────────────
  static const Color pageBg = Color(0xFFF8F9FF);
  static const Color cardBg = Color(0xFFFFFFFF);
  static const Color surfaceCard = cardBg;
  static const Color navyBg = Color(0xFFE8EAFB);
  static const Color surface = Color(0xFFF4F6FF);
  static const Color background = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFDFE1F5);

  // ── Text ───────────────────────────────────────────
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textDark = Color(0xFF0D1333);
  static const Color headingGray = Color(0xFF111827);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color labelGray = Color(0xFF6B7280);
  static const Color textMid = Color(0xFF4A5180);
  static const Color textMuted = Color(0xFF94A3B8);
  static const Color textLight = Color(0xFF9AA0C4);
  static const Color textDisabled = Color(0xFFB0B8D1);
  static const Color inactiveGrey = Color(0xFF9CA3AF);
  static const Color inactiveGreyBg = Color(0xFFF3F4F6);

  // ── Map / route ────────────────────────────────────
  static const Color routeLine = Color(0xFF1B2CC1);
  static const Color routeTrailTraveled = Color(0xFFB0BEC5);
  static const Color trailLine = Color(0xFF90CAF9);
  static const Color userDot = Color(0xFF2196F3);
  static const Color chipDivider = Color(0xFFEEEEF5);

  // ── Stat chip accents ──────────────────────────────
  static const Color statPurple = Color(0xFF8B5CF6);
  static const Color statTeal = Color(0xFF059669);

  // ── Additional colors ──────────────────────────────
  static const Color navySoft = navySurface;
  static const Color greenDark = Color(0xFF14532D);
  static const Color redDark = Color(0xFF7F1D1D);

  // ── Misc ───────────────────────────────────────────
  static const Color divider = Color(0xFFE2E8F0);
  static const Color shadow = Color(0x22000000);
  static const Color shadowPrimary = Color(0x141B2CC1);
}
