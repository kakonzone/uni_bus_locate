// lib/widgets/stat_chip.dart
// UniTrack — ETA / Speed / Distance stat chip widget
// Used on Student Home, Teacher Home, and Live Map screens

import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';

// ─────────────────────────────────────────────
// Enum: which kind of stat this chip represents
// ─────────────────────────────────────────────
enum StatChipType {
  eta, // estimated time of arrival
  speed, // current bus speed (km/h)
  distance, // distance from user to bus (km / m)
  watching, // live watcher count (Teacher only)
  status, // bus active / idle / offline
}

// ─────────────────────────────────────────────
// Size variants — used in different contexts
// ─────────────────────────────────────────────
enum StatChipSize {
  compact, // inside BusCard list rows
  normal, // Student / Teacher home cards
  large, // Live Map bottom sheet
}

// ─────────────────────────────────────────────
// StatChip Widget
// ─────────────────────────────────────────────
class StatChip extends StatelessWidget {
  const StatChip({
    super.key,
    required this.type,
    required this.value,
    this.size = StatChipSize.normal,
    this.isLoading = false,
    this.isPulsing = false, // animates dot when bus is live
  });

  final StatChipType type;
  final String value; // pre-formatted string, e.g. "12 min", "34 km/h"
  final StatChipSize size;
  final bool isLoading;
  final bool isPulsing;

  // ── convenience constructors ──────────────────

  const StatChip.eta({
    Key? key,
    required String minutes,
    StatChipSize size = StatChipSize.normal,
    bool isLoading = false,
    bool isPulsing = false,
  }) : this(
         key: key,
         type: StatChipType.eta,
         value: minutes,
         size: size,
         isLoading: isLoading,
         isPulsing: isPulsing,
       );

  const StatChip.speed({
    Key? key,
    required String kmh,
    StatChipSize size = StatChipSize.normal,
    bool isLoading = false,
  }) : this(
         key: key,
         type: StatChipType.speed,
         value: kmh,
         size: size,
         isLoading: isLoading,
       );

  const StatChip.distance({
    Key? key,
    required String dist,
    StatChipSize size = StatChipSize.normal,
    bool isLoading = false,
  }) : this(
         key: key,
         type: StatChipType.distance,
         value: dist,
         size: size,
         isLoading: isLoading,
       );

  const StatChip.watching({
    Key? key,
    required String count,
    StatChipSize size = StatChipSize.normal,
  }) : this(key: key, type: StatChipType.watching, value: count, size: size);

  const StatChip.status({
    Key? key,
    required String label, // "Active", "Idle", "Offline"
    StatChipSize size = StatChipSize.normal,
    bool isPulsing = false,
  }) : this(
         key: key,
         type: StatChipType.status,
         value: label,
         size: size,
         isPulsing: isPulsing,
       );

  // ── build ─────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cfg = _ChipConfig.from(type, value);
    final dim = _ChipDimensions.from(size);

    return _ChipShell(
      config: cfg,
      dimensions: dim,
      isLoading: isLoading,
      isPulsing: isPulsing,
    );
  }
}

// ─────────────────────────────────────────────
// Internal: visual config resolved from type
// ─────────────────────────────────────────────
class _ChipConfig {
  const _ChipConfig({
    required this.icon,
    required this.label,
    required this.value,
    required this.bgColor,
    required this.iconColor,
    required this.textColor,
    required this.borderColor,
    this.dotColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color bgColor;
  final Color iconColor;
  final Color textColor;
  final Color borderColor;
  final Color? dotColor;

  factory _ChipConfig.from(StatChipType type, String value) {
    switch (type) {
      case StatChipType.eta:
        return _ChipConfig(
          icon: Icons.schedule_rounded,
          label: 'ETA',
          value: value,
          bgColor: const Color(0xFFEEF0FD),
          iconColor: const Color(0xFF1B2CC1),
          textColor: const Color(0xFF1B2CC1),
          borderColor: const Color(0xFFCDD1F5),
          dotColor: const Color(0xFF1B2CC1),
        );

      case StatChipType.speed:
        return _ChipConfig(
          icon: Icons.speed_rounded,
          label: 'Speed',
          value: value,
          bgColor: const Color(0xFFF0FBF4),
          iconColor: const Color(0xFF1A8C4E),
          textColor: const Color(0xFF1A6B3C),
          borderColor: const Color(0xFFB6E8CC),
        );

      case StatChipType.distance:
        return _ChipConfig(
          icon: Icons.social_distance_rounded,
          label: 'Distance',
          value: value,
          bgColor: const Color(0xFFFFF8EE),
          iconColor: const Color(0xFFD97706),
          textColor: const Color(0xFF92400E),
          borderColor: const Color(0xFFFFDDA0),
        );

      case StatChipType.watching:
        return _ChipConfig(
          icon: Icons.visibility_rounded,
          label: 'Watching',
          value: value,
          bgColor: const Color(0xFFF5F0FD),
          iconColor: const Color(0xFF7C3AED),
          textColor: const Color(0xFF5B21B6),
          borderColor: const Color(0xFFDDD6FE),
        );

      case StatChipType.status:
        final isActive = value.toLowerCase() == 'active';
        final isIdle = value.toLowerCase() == 'idle';
        if (isActive) {
          return _ChipConfig(
            icon: Icons.circle,
            label: '',
            value: value,
            bgColor: const Color(0xFFF0FBF4),
            iconColor: const Color(0xFF16A34A),
            textColor: const Color(0xFF166534),
            borderColor: const Color(0xFFB6E8CC),
            dotColor: const Color(0xFF16A34A),
          );
        } else if (isIdle) {
          return _ChipConfig(
            icon: Icons.circle,
            label: '',
            value: value,
            bgColor: const Color(0xFFFFF8EE),
            iconColor: const Color(0xFFD97706),
            textColor: const Color(0xFF92400E),
            borderColor: const Color(0xFFFFDDA0),
            dotColor: const Color(0xFFD97706),
          );
        } else {
          // Offline
          return _ChipConfig(
            icon: Icons.circle,
            label: '',
            value: value,
            bgColor: const Color(0xFFF5F5F5),
            iconColor: const Color(0xFF9CA3AF),
            textColor: const Color(0xFF6B7280),
            borderColor: const Color(0xFFE5E7EB),
          );
        }
    }
  }
}

// ─────────────────────────────────────────────
// Internal: size-dependent dimensions
// ─────────────────────────────────────────────
class _ChipDimensions {
  const _ChipDimensions({
    required this.iconSize,
    required this.labelSize,
    required this.valueSize,
    required this.hPad,
    required this.vPad,
    required this.gap,
    required this.radius,
    required this.dotSize,
  });

  final double iconSize;
  final double labelSize;
  final double valueSize;
  final double hPad;
  final double vPad;
  final double gap;
  final double radius;
  final double dotSize;

  factory _ChipDimensions.from(StatChipSize size) {
    switch (size) {
      case StatChipSize.compact:
        return const _ChipDimensions(
          iconSize: 12,
          labelSize: 9,
          valueSize: 11,
          hPad: 8,
          vPad: 5,
          gap: 4,
          radius: 8,
          dotSize: 5,
        );
      case StatChipSize.normal:
        return const _ChipDimensions(
          iconSize: 15,
          labelSize: 10,
          valueSize: 13,
          hPad: 12,
          vPad: 8,
          gap: 6,
          radius: 12,
          dotSize: 6,
        );
      case StatChipSize.large:
        return const _ChipDimensions(
          iconSize: 20,
          labelSize: 11,
          valueSize: 16,
          hPad: 16,
          vPad: 12,
          gap: 8,
          radius: 16,
          dotSize: 8,
        );
    }
  }
}

// ─────────────────────────────────────────────
// Internal: the actual chip shell
// ─────────────────────────────────────────────
class _ChipShell extends StatelessWidget {
  const _ChipShell({
    required this.config,
    required this.dimensions,
    required this.isLoading,
    required this.isPulsing,
  });

  final _ChipConfig config;
  final _ChipDimensions dimensions;
  final bool isLoading;
  final bool isPulsing;

  @override
  Widget build(BuildContext context) {
    final d = dimensions;
    final c = config;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: d.hPad, vertical: d.vPad),
      decoration: BoxDecoration(
        color: c.bgColor,
        borderRadius: BorderRadius.circular(d.radius),
        border: Border.all(color: c.borderColor, width: 1),
      ),
      child: isLoading ? _buildSkeleton(d) : _buildContent(c, d),
    );
  }

  // ── skeleton shimmer while data loads ────────
  Widget _buildSkeleton(_ChipDimensions d) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SkeletonBox(
          width: d.iconSize,
          height: d.iconSize,
          radius: d.iconSize / 2,
        ),
        SizedBox(width: d.gap),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SkeletonBox(width: 28, height: d.labelSize),
            SizedBox(height: 3),
            _SkeletonBox(width: 40, height: d.valueSize),
          ],
        ),
      ],
    );
  }

  // ── real content ──────────────────────────────
  Widget _buildContent(_ChipConfig c, _ChipDimensions d) {
    final isStatus = config.label.isEmpty; // status chip has no label

    if (isStatus) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          isPulsing
              ? _PulsingDot(color: c.iconColor, size: d.dotSize)
              : Container(
                  width: d.dotSize,
                  height: d.dotSize,
                  decoration: BoxDecoration(
                    color: c.iconColor,
                    shape: BoxShape.circle,
                  ),
                ),
          SizedBox(width: d.gap),
          Text(
            c.value,
            style: TextStyle(
              fontFamily: AppTextStyles.fontFamily,
              fontSize: d.valueSize,
              fontWeight: FontWeight.w600,
              color: c.textColor,
              letterSpacing: 0.1,
            ),
          ),
        ],
      );
    }

    // standard chip: icon + label + value stacked
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(c.icon, size: d.iconSize, color: c.iconColor),
        SizedBox(width: d.gap),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              c.label.toUpperCase(),
              style: TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: d.labelSize,
                fontWeight: FontWeight.w500,
                color: c.textColor.withValues(alpha: 0.65),
                letterSpacing: 0.6,
                height: 1,
              ),
            ),
            SizedBox(height: 2),
            Text(
              c.value,
              style: TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: d.valueSize,
                fontWeight: FontWeight.w700,
                color: c.textColor,
                letterSpacing: 0.1,
                height: 1.1,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// Skeleton shimmer box
// ─────────────────────────────────────────────
class _SkeletonBox extends StatefulWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    this.radius = 4,
  });

  final double width;
  final double height;
  final double radius;

  @override
  State<_SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<_SkeletonBox>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.3,
      end: 0.7,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: _anim.value),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Pulsing live dot (for active bus / live ETA)
// ─────────────────────────────────────────────
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: false);

    _scale = Tween<double>(
      begin: 1.0,
      end: 2.2,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _opacity = Tween<double>(
      begin: 0.7,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 2.5,
      height: s * 2.5,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ripple ring
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Transform.scale(
              scale: _scale.value,
              child: Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: _opacity.value),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          // solid core dot
          Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// StatChipRow — convenience row for grouping chips
// ─────────────────────────────────────────────
class StatChipRow extends StatelessWidget {
  const StatChipRow({
    super.key,
    required this.chips,
    this.spacing = 8,
    this.scrollable = false,
  });

  final List<StatChip> chips;
  final double spacing;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final row =
        chips.expand((chip) => [chip, SizedBox(width: spacing)]).toList()
          ..removeLast();

    if (scrollable) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(mainAxisSize: MainAxisSize.min, children: row),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: row);
  }
}
