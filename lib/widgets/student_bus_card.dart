import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../models/bus_model.dart';
import '../models/bus_model_ui_ext.dart';
import '../theme/app_color.dart';
import '../theme/app_text_styles.dart';
import 'stat_chip.dart';

class StudentBusCard extends StatefulWidget {
  final BusModel bus;
  final double campusLat;
  final double campusLng;
  final VoidCallback? onTap;

  const StudentBusCard({
    super.key,
    required this.bus,
    required this.campusLat,
    required this.campusLng,
    required this.onTap,
  });

  @override
  State<StudentBusCard> createState() => _StudentBusCardState();
}

class _StudentBusCardState extends State<StudentBusCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleCtrl;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scaleAnim = Tween(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeIn),
    );
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bus = widget.bus;
    final distMeters = (bus.lat != 0.0 || bus.lng != 0.0)
        ? Geolocator.distanceBetween(
            bus.lat,
            bus.lng,
            widget.campusLat,
            widget.campusLng,
          )
        : double.infinity;
    final distKm = distMeters / 1000.0;
    final eta = bus.etaMinutes(widget.campusLat, widget.campusLng);
    final hasLocation = bus.lat != 0.0 && bus.lng != 0.0;

    return GestureDetector(
      onTapDown: widget.onTap != null ? (_) => _scaleCtrl.forward() : null,
      onTapUp: widget.onTap != null
          ? (_) {
              _scaleCtrl.reverse();
              widget.onTap?.call();
            }
          : null,
      onTapCancel: widget.onTap != null ? () => _scaleCtrl.reverse() : null,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: bus.active
                    ? AppColors.navy.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.04),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BusIconBadge(bus: bus),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  bus.name,
                                  style: const TextStyle(
                                    fontFamily: AppTextStyles.fontFamily,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                              StatChip(
                                type: StatChipType.status,
                                value: bus.movementStatusLabel,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.route_rounded,
                                  size: 12, color: AppColors.textMuted),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  bus.route,
                                  style: const TextStyle(
                                    fontFamily: AppTextStyles.fontFamily,
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (bus.driverName != null &&
                              bus.driverName!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                const Icon(Icons.person_outline_rounded,
                                    size: 12, color: AppColors.textMuted),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    bus.driverName!,
                                    style: const TextStyle(
                                      fontFamily: AppTextStyles.fontFamily,
                                      fontSize: 12,
                                      color: AppColors.textSecondary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (bus.active) ...[
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: AppColors.divider,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Row(
                    children: [
                      StatChip.speed(kmh: '${bus.speed.toStringAsFixed(0)} km/h'),
                      const SizedBox(width: 8),
                      if (hasLocation && distMeters.isFinite)
                        StatChip.distance(
                          dist: distKm < 1
                              ? '${distMeters.toStringAsFixed(0)} m'
                              : '${distKm.toStringAsFixed(1)} km',
                        ),
                      if (hasLocation && distMeters.isFinite)
                        const SizedBox(width: 8),
                      if (eta != null)
                        StatChip.eta(
                          minutes: eta < 1 ? 'Arriving' : '~$eta min',
                        ),
                      const Spacer(),
                      Row(
                        children: [
                          const Icon(Icons.visibility_rounded,
                              size: 13, color: AppColors.textMuted),
                          const SizedBox(width: 4),
                          Text(
                            '${bus.watchCount}',
                            style: const TextStyle(
                              fontFamily: AppTextStyles.fontFamily,
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.navy,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.map_rounded,
                                color: Colors.white, size: 13),
                            const SizedBox(width: 5),
                            Text(
                              bus.trackMode.isGpsDevice ? 'Device' : 'Track',
                              style: const TextStyle(
                                fontFamily: AppTextStyles.fontFamily,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.schedule_rounded,
                          size: 13, color: AppColors.textMuted),
                      const SizedBox(width: 5),
                      Text(
                        bus.lastUpdate != null
                            ? 'Last seen ${_timeAgo(bus.lastUpdate!)}'
                            : 'No recent activity',
                        style: const TextStyle(
                          fontFamily: AppTextStyles.fontFamily,
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('dd MMM').format(dt);
  }
}

class _BusIconBadge extends StatefulWidget {
  final BusModel bus;
  const _BusIconBadge({required this.bus});

  @override
  State<_BusIconBadge> createState() => _BusIconBadgeState();
}

class _BusIconBadgeState extends State<_BusIconBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.bus.active && widget.bus.speed > 2) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_BusIconBadge old) {
    super.didUpdateWidget(old);
    final shouldAnimate = widget.bus.active && widget.bus.speed > 2;
    if (shouldAnimate && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!shouldAnimate) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.bus.statusColor;
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, child) => Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: AppColors.navy.withValues(alpha: 0.08),
              border: Border.all(
                color: widget.bus.active
                    ? color.withValues(alpha: 0.25 + _ctrl.value * 0.25)
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: child,
          ),
          child: const Icon(
            Icons.directions_bus_rounded,
            color: AppColors.navy,
            size: 28,
          ),
        ),
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ],
    );
  }
}
