// lib/widgets/bottom_nav.dart
// UniTrack — Bottom Navigation Bar
// Used by Student and Teacher screens (Driver has its own dashboard nav)
// Supports: Student (Home + Map) | Teacher (Home + Map + Stats)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_color.dart';
import '../theme/app_text_styles.dart';

// ─────────────────────────────────────────────
// Nav item definition
// ─────────────────────────────────────────────
class _NavItem {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
  final IconData icon;
  final IconData activeIcon;
  final String label;
}

// ─────────────────────────────────────────────
// Role-based nav configs
// ─────────────────────────────────────────────
const _studentItems = [
  _NavItem(
    icon: Icons.directions_bus_outlined,
    activeIcon: Icons.directions_bus_rounded,
    label: 'Buses',
  ),
  _NavItem(
    icon: Icons.map_outlined,
    activeIcon: Icons.map_rounded,
    label: 'Live Map',
  ),
];

const _teacherItems = [
  _NavItem(
    icon: Icons.dashboard_outlined,
    activeIcon: Icons.dashboard_rounded,
    label: 'Overview',
  ),
  _NavItem(
    icon: Icons.map_outlined,
    activeIcon: Icons.map_rounded,
    label: 'Live Map',
  ),
  _NavItem(
    icon: Icons.bar_chart_outlined,
    activeIcon: Icons.bar_chart_rounded,
    label: 'Stats',
  ),
];

// ─────────────────────────────────────────────
// UniTrackBottomNav
// ─────────────────────────────────────────────
class UniTrackBottomNav extends StatelessWidget {
  const UniTrackBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.isTeacher = false,
    this.hasLiveActivity = false, // shows pulsing dot on Live Map tab
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool isTeacher;

  /// When true, shows a live indicator dot on the Map tab
  final bool hasLiveActivity;

  @override
  Widget build(BuildContext context) {
    final items = isTeacher ? _teacherItems : _studentItems;
    final mapTabIndex = 1; // always index 1

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, -1),
          ),
        ],
        border: Border(
          top: BorderSide(
            color: AppColors.navy.withValues(alpha: 0.10),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: List.generate(items.length, (index) {
              final item = items[index];
              final isActive = index == currentIndex;
              final isMapTab = index == mapTabIndex;
              final showDot = isMapTab && hasLiveActivity && !isActive;

              return Expanded(
                child: _NavTile(
                  item: item,
                  isActive: isActive,
                  showLiveDot: showDot,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onTap(index);
                  },
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Individual nav tile with animated indicator
// ─────────────────────────────────────────────
class _NavTile extends StatefulWidget {
  const _NavTile({
    required this.item,
    required this.isActive,
    required this.onTap,
    this.showLiveDot = false,
  });

  final _NavItem item;
  final bool isActive;
  final VoidCallback onTap;
  final bool showLiveDot;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _iconScale;
  late Animation<double> _pillWidth;
  late Animation<double> _pillOpacity;

  static const _primary = AppColors.navy;
  static const _inactive = AppColors.inactiveGrey;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _iconScale = Tween<double>(
      begin: 1.0,
      end: 1.18,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _pillWidth = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _pillOpacity = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeIn));

    if (widget.isActive) _ctrl.value = 1.0;
  }

  @override
  void didUpdateWidget(_NavTile old) {
    super.didUpdateWidget(old);
    if (widget.isActive != old.isActive) {
      if (widget.isActive) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final color = Color.lerp(_inactive, _primary, _ctrl.value)!;

          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── icon + live dot stack ──────────────
              Stack(
                clipBehavior: Clip.none,
                children: [
                  // animated pill background
                  Center(
                    child: FadeTransition(
                      opacity: _pillOpacity,
                      child: SizeTransition(
                        sizeFactor: _pillWidth,
                        axis: Axis.horizontal,
                        child: Container(
                          width: 48,
                          height: 32,
                          decoration: BoxDecoration(
                            color: _primary.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // icon
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      child: Transform.scale(
                        scale: _iconScale.value,
                        child: Icon(
                          widget.isActive
                              ? widget.item.activeIcon
                              : widget.item.icon,
                          size: 22,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                  // live activity dot (pulsing)
                  if (widget.showLiveDot)
                    Positioned(top: 2, right: 10, child: _LiveDot()),
                ],
              ),

              const SizedBox(height: 2),

              // ── label ──────────────────────────────
              Text(
                widget.item.label,
                style: TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 10.5,
                  fontWeight:
                      widget.isActive ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Pulsing live dot shown on Map tab when buses
// are actively broadcasting location
// ─────────────────────────────────────────────
class _LiveDot extends StatefulWidget {
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _scale = Tween<double>(
      begin: 1.0,
      end: 2.4,
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
    return SizedBox(
      width: 12,
      height: 12,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Transform.scale(
              scale: _scale.value,
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: AppColors.activeGreen.withValues(alpha: _opacity.value),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: AppColors.activeGreen,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Driver Bottom Nav (minimal — 2 tabs only)
// Used inside Driver Dashboard
// ─────────────────────────────────────────────
class DriverBottomNav extends StatelessWidget {
  const DriverBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.isTripActive = false,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool isTripActive;

  static const _driverItems = [
    _NavItem(
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
      label: 'Dashboard',
    ),
    _NavItem(
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings_rounded,
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
        border: Border(
          top: BorderSide(
            color: AppColors.navy.withValues(alpha: 0.10),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              // ── Dashboard tab ──
              Expanded(
                child: _NavTile(
                  item: _driverItems[0],
                  isActive: currentIndex == 0,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onTap(0);
                  },
                ),
              ),

              // ── Trip status pill (center) ──
              _TripStatusPill(isActive: isTripActive),

              // ── Settings tab ──
              Expanded(
                child: _NavTile(
                  item: _driverItems[1],
                  isActive: currentIndex == 1,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onTap(1);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Trip status pill — center of Driver nav bar
// Shows "LIVE" when trip is active
// ─────────────────────────────────────────────
class _TripStatusPill extends StatefulWidget {
  const _TripStatusPill({required this.isActive});
  final bool isActive;

  @override
  State<_TripStatusPill> createState() => _TripStatusPillState();
}

class _TripStatusPillState extends State<_TripStatusPill>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _fade = Tween<double>(
      begin: 0.6,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: widget.isActive
              ? AppColors.activeGreen
              : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          boxShadow: widget.isActive
              ? [
                  BoxShadow(
                    color: AppColors.activeGreen.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : [],
        ),
        child: widget.isActive
            ? AnimatedBuilder(
                animation: _fade,
                builder: (_, __) => Opacity(
                  opacity: _fade.value,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fiber_manual_record,
                        size: 8,
                        color: Colors.white,
                      ),
                      SizedBox(width: 5),
                      Text(
                        'LIVE',
                        style: TextStyle(
                          fontFamily: AppTextStyles.fontFamily,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : const Text(
                'OFF DUTY',
                style: TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                  letterSpacing: 0.8,
                ),
              ),
      ),
    );
  }
}
