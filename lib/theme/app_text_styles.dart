// lib/theme/app_text_styles.dart

import 'package:flutter/material.dart';

import './app_color.dart';

const _font = 'DM Sans';

class AppTextStyles {
  AppTextStyles._();

  /// Single source of truth for the app font family.
  static const String fontFamily = _font;

  // ── Display / headline (main.dart theme) ───────────
  static const TextStyle displayLarge = TextStyle(
    fontFamily: _font,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.5,
  );

  static const TextStyle displayMedium = TextStyle(
    fontFamily: _font,
    fontSize: 26,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.3,
  );

  static const TextStyle headlineLarge = TextStyle(
    fontFamily: _font,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle headlineMedium = TextStyle(
    fontFamily: _font,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle titleMedium = TextStyle(
    fontFamily: _font,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle titleSmall = TextStyle(
    fontFamily: _font,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontFamily: _font,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontFamily: _font,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );

  static const TextStyle bodySmall = TextStyle(
    fontFamily: _font,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );

  static const TextStyle labelLarge = TextStyle(
    fontFamily: _font,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.primary,
    letterSpacing: 0.4,
  );

  static const TextStyle labelMedium = TextStyle(
    fontFamily: _font,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: AppColors.textMid,
    letterSpacing: 0.2,
  );

  static const TextStyle labelSmall = TextStyle(
    fontFamily: _font,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
    letterSpacing: 0.5,
  );

  // ── Screen-specific helpers ────────────────────────
  static const TextStyle heading = TextStyle(
    fontFamily: _font,
    fontSize: 26,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.5,
  );

  static const TextStyle title = TextStyle(
    fontFamily: _font,
    fontSize: 15,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontFamily: _font,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.5,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: _font,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AppColors.textMuted,
  );

  static const TextStyle label = TextStyle(
    fontFamily: _font,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle buttonText = TextStyle(
    fontFamily: _font,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: Colors.white,
    letterSpacing: 0.1,
  );
}
