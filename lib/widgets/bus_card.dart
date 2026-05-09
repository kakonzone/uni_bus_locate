// lib/widgets/bus_card.dart
//
// UniTrack — University Bus Live Tracking System
// BusCard Widget — Reusable bus list card for Student & Teacher home screens
//
// Design: Navy Blue (#1B2CC1) primary, DM Sans font, delivery-app style
// Shows: bus name, route, driver, speed, distance, ETA, active status

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Model reference (matches models/bus_model.dart)
// ─────────────────────────────────────────────────────────────────────────────

/// Lightweight data class consumed by BusCard.
/// In the real app this comes from BusModel / Riverpod provider.
class BusCardData {
  final String busId;
  final String busName;
  final String route;
  final String driverName; // may be empty
  final bool isActive;
  final double speedKmh;
  final double distanceKm; // distance from user / campus gate
  final int etaMinutes; // -1 = unknown
  final int watchCount; // viewers (teacher sees this)
  final DateTime? lastUpdate;
  final String trackMode; // 'phone' | 'gps_device'

  const BusCardData({
    required this.busId,
    required this.busName,
    required this.route,
    this.driverName = '',
    required this.isActive,
    required this.speedKmh,
    required this.distanceKm,
    this.etaMinutes = -1,
    this.watchCount = 0,
    this.lastUpdate,
    this.trackMode = 'phone',
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Colour & style constants — single source of truth for the whole widget
// ─────────────────────────────────────────────────────────────────────────────

class _C {
  // Primary palette
  static const navy = Color(0xFF1B2CC1);
  static const navyLight = Color(0xFF3547D4);
  static const navyMuted = Color(0xFFE8EAFC);

  // Status colours
  static const activeGreen = Color(0xFF1DB954);
  static const activeGreenBg = Color(0xFFE6F9EE);
  static const inactiveGrey = Color(0xFF9E9E9E);
  static const inactiveGreyBg = Color(0xFFF5F5F5);
  static const warningAmber = Color(0xFFFF9800);

  // Surface
  static const cardBg = Colors.white;
  static const divider = Color(0xFFEEEEF5);

  // Text
  static const textPrimary = Color(0xFF111827);
  static const textSecondary = Color(0xFF6B7280);
  static const textMuted = Color(0xFFADB5BD);
}

// ─────────────────────────────────────────────────────────────────────────────
// Main BusCard widget
// ─────────────────────────────────────────────────────────────────────────────

class BusCard extends StatelessWidget {
  final BusCardData bus;

  /// Called when user taps the card — navigates to map screen
  final VoidCallback? onTap;

  /// Set to true for Teacher role (shows watchCount badge)
  final bool showWatchCount;

  /// Set to true to display a subtle "live pulse" ring animation
  final bool showLivePulse;

  const BusCard({
    super.key,
    required this.bus,
    this.onTap,
    this.showWatchCount = false,
    this.showLivePulse = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: _C.cardBg,
        borderRadius: BorderRadius.circular(16),
        elevation: 0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          splashColor: _C.navyMuted,
          highlightColor: _C.navyMuted.withOpacity(0.5),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: bus.isActive ? _C.navy.withOpacity(0.18) : _C.divider,
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: bus.isActive
                      ? _C.navy.withOpacity(0.07)
                      : Colors.black.withOpacity(0.03),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(),
                const Divider(color: _C.divider, height: 1, thickness: 1),
                _buildStatsRow(),
                if (bus.isActive) _buildLiveIndicatorBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header row: icon + name/route + status badge ──────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Bus icon container
          _BusIconBox(isActive: bus.isActive, trackMode: bus.trackMode),
          const SizedBox(width: 12),

          // Name + route + driver
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Bus name + watch count (teacher only)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        bus.busName,
                        style: const TextStyle(
                          fontFamily: 'DM Sans',
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: _C.textPrimary,
                          letterSpacing: -0.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (showWatchCount && bus.watchCount > 0)
                      _WatchCountChip(count: bus.watchCount),
                  ],
                ),
                const SizedBox(height: 3),
                // Route
                Row(
                  children: [
                    const Icon(
                      Icons.route_rounded,
                      size: 13,
                      color: _C.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        bus.route,
                        style: const TextStyle(
                          fontFamily: 'DM Sans',
                          fontSize: 12.5,
                          color: _C.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                // Driver name (optional)
                if (bus.driverName.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(
                        Icons.person_outline_rounded,
                        size: 13,
                        color: _C.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        bus.driverName,
                        style: const TextStyle(
                          fontFamily: 'DM Sans',
                          fontSize: 12,
                          color: _C.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Status badge
          _StatusBadge(
            isActive: bus.isActive,
            showPulse: showLivePulse && bus.isActive,
          ),
        ],
      ),
    );
  }

  // ── Stats row: Speed | Distance | ETA ─────────────────────────────────────

  Widget _buildStatsRow() {
    final etaLabel = bus.etaMinutes < 0
        ? '—'
        : bus.etaMinutes == 0
        ? 'Arrived'
        : '${bus.etaMinutes} min';

    final distLabel = bus.distanceKm < 1
        ? '${(bus.distanceKm * 1000).toStringAsFixed(0)} m'
        : '${bus.distanceKm.toStringAsFixed(1)} km';

    final speedLabel = bus.isActive
        ? '${bus.speedKmh.toStringAsFixed(0)} km/h'
        : '—';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _StatCell(
            icon: Icons.speed_rounded,
            label: 'Speed',
            value: speedLabel,
            iconColor: _C.navy,
          ),
          _VerticalDivider(),
          _StatCell(
            icon: Icons.social_distance_rounded,
            label: 'Distance',
            value: distLabel,
            iconColor: _C.navyLight,
          ),
          _VerticalDivider(),
          _StatCell(
            icon: Icons.schedule_rounded,
            label: 'ETA',
            value: etaLabel,
            iconColor: bus.etaMinutes >= 0 && bus.etaMinutes <= 5
                ? _C.activeGreen
                : _C.warningAmber,
          ),
          // Track mode pill
          const Spacer(),
          _TrackModePill(mode: bus.trackMode),
        ],
      ),
    );
  }

  // ── Live indicator bar at bottom (only when active) ────────────────────────

  Widget _buildLiveIndicatorBar() {
    final ago = _formatLastUpdate(bus.lastUpdate);
    return Container(
      decoration: BoxDecoration(
        color: _C.navyMuted,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: _C.activeGreen,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Live tracking active',
            style: const TextStyle(
              fontFamily: 'DM Sans',
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: _C.navy,
            ),
          ),
          const Spacer(),
          Text(
            'Updated $ago',
            style: const TextStyle(
              fontFamily: 'DM Sans',
              fontSize: 11,
              color: _C.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  String _formatLastUpdate(DateTime? dt) {
    if (dt == null) return 'just now';
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 10) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return DateFormat('hh:mm a').format(dt);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Animated bus icon with active/inactive state
class _BusIconBox extends StatelessWidget {
  final bool isActive;
  final String trackMode;

  const _BusIconBox({required this.isActive, required this.trackMode});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: isActive ? _C.navy : _C.inactiveGreyBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            Icons.directions_bus_rounded,
            color: isActive ? Colors.white : _C.inactiveGrey,
            size: 28,
          ),
        ),
        // GPS device indicator
        if (trackMode == 'gps_device')
          Positioned(
            right: -4,
            bottom: -4,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: _C.warningAmber,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: const Icon(Icons.gps_fixed, color: Colors.white, size: 10),
            ),
          ),
      ],
    );
  }
}

/// Active / Inactive status badge with optional pulse animation
class _StatusBadge extends StatefulWidget {
  final bool isActive;
  final bool showPulse;

  const _StatusBadge({required this.isActive, required this.showPulse});

  @override
  State<_StatusBadge> createState() => _StatusBadgeState();
}

class _StatusBadgeState extends State<_StatusBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    _scale = Tween<double>(
      begin: 1.0,
      end: 2.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _opacity = Tween<double>(
      begin: 0.6,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            // Pulse ring
            if (widget.showPulse)
              AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) => Transform.scale(
                  scale: _scale.value,
                  child: Opacity(
                    opacity: _opacity.value,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: _C.activeGreen,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
            // Dot
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: widget.isActive ? _C.activeGreen : _C.inactiveGrey,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: widget.isActive ? _C.activeGreenBg : _C.inactiveGreyBg,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            widget.isActive ? 'LIVE' : 'OFFLINE',
            style: TextStyle(
              fontFamily: 'DM Sans',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: widget.isActive ? _C.activeGreen : _C.inactiveGrey,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ],
    );
  }
}

/// Single stat cell: icon + label + value
class _StatCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color iconColor;

  const _StatCell({
    required this.icon,
    required this.label,
    required this.value,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: iconColor),
            const SizedBox(width: 3),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'DM Sans',
                fontSize: 11,
                color: _C.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'DM Sans',
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: _C.textPrimary,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }
}

/// Thin vertical divider between stat cells
class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      width: 1,
      height: 30,
      color: _C.divider,
    );
  }
}

/// Track mode pill — shows 'GPS Device' or 'Phone GPS'
class _TrackModePill extends StatelessWidget {
  final String mode;

  const _TrackModePill({required this.mode});

  @override
  Widget build(BuildContext context) {
    final isDevice = mode == 'gps_device';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: isDevice ? _C.warningAmber.withOpacity(0.12) : _C.navyMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDevice
              ? _C.warningAmber.withOpacity(0.4)
              : _C.navy.withOpacity(0.15),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDevice ? Icons.gps_fixed : Icons.smartphone_rounded,
            size: 11,
            color: isDevice ? _C.warningAmber : _C.navy,
          ),
          const SizedBox(width: 4),
          Text(
            isDevice ? 'HW GPS' : 'Phone',
            style: TextStyle(
              fontFamily: 'DM Sans',
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: isDevice ? _C.warningAmber : _C.navy,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Watch count badge shown only to Teacher role
class _WatchCountChip extends StatelessWidget {
  final int count;

  const _WatchCountChip({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _C.navyMuted,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.remove_red_eye_outlined, size: 11, color: _C.navy),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: const TextStyle(
              fontFamily: 'DM Sans',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _C.navy,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BusCardShimmer — loading skeleton shown while Firebase data loads
// ─────────────────────────────────────────────────────────────────────────────

class BusCardShimmer extends StatefulWidget {
  const BusCardShimmer({super.key});

  @override
  State<BusCardShimmer> createState() => _BusCardShimmerState();
}

class _BusCardShimmerState extends State<BusCardShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _box(double w, double h, {BorderRadius? radius}) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Opacity(
        opacity: _anim.value,
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: const Color(0xFFE8EAF6),
            borderRadius: radius ?? BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _C.divider),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _box(52, 52, radius: BorderRadius.circular(14)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _box(120, 14),
                      const SizedBox(height: 8),
                      _box(180, 11),
                    ],
                  ),
                ),
                _box(48, 24, radius: BorderRadius.circular(20)),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: _C.divider, height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                _box(50, 32),
                const SizedBox(width: 28),
                _box(50, 32),
                const SizedBox(width: 28),
                _box(50, 32),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Usage Example (reference only — not compiled)
// ─────────────────────────────────────────────────────────────────────────────
//
// BusCard(
//   bus: BusCardData(
//     busId: 'bus_01',
//     busName: 'Campus Shuttle A',
//     route: 'Gate 1 → CSE Block → Library → Hall',
//     driverName: 'Karim Hossain',
//     isActive: true,
//     speedKmh: 34.5,
//     distanceKm: 1.2,
//     etaMinutes: 4,
//     watchCount: 12,
//     lastUpdate: DateTime.now().subtract(const Duration(seconds: 8)),
//     trackMode: 'phone',
//   ),
//   onTap: () => context.push('/map/bus_01'),
//   showWatchCount: true,   // set true for Teacher role
//   showLivePulse: true,
// ),
//
// // Loading state:
// BusCardShimmer(),
