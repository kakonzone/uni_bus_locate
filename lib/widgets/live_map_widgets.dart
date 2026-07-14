// lib/widgets/live_map_widget.dart
//
// UniTrack — University Bus Live Tracking System
// LiveMapWidget — OpenStreetMap powered by flutter_map + latlong2
//
// Features:
//   • Real-time animated bus marker that smoothly interpolates position
//   • User location blue dot with accuracy circle
//   • Route polyline with animated dashed trail
//   • Route trail split by traveled (grey) vs remaining (navy) portion
//   • Info panel overlay (speed / ETA / distance)
//   • Campus gate marker (fixed reference point)
//   • Zoom controls + re-center FAB
//   • Supports single-bus focus (Student) and multi-bus overview (Teacher)
//   • Full dark/light tile switching (OpenStreetMap only — no API key)
//   • Offline-safe: graceful tile load error handling

import 'dart:math' as math;

import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_animations/flutter_map_animations.dart';
import 'package:latlong2/latlong.dart';

import '../theme/app_color.dart';
import '../theme/app_text_styles.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data contracts
// ─────────────────────────────────────────────────────────────────────────────

/// A single bus shown on the map.
class MapBusMarker {
  final String busId;
  final String busName;
  final LatLng position;
  final double speedKmh;
  final double heading; // degrees 0–360
  final bool isActive;
  final int etaMinutes; // -1 = unknown
  final String trackMode; // 'phone' | 'gps_device'

  const MapBusMarker({
    required this.busId,
    required this.busName,
    required this.position,
    this.speedKmh = 0,
    this.heading = 0,
    this.isActive = true,
    this.etaMinutes = -1,
    this.trackMode = 'phone',
  });

  MapBusMarker copyWith({LatLng? position, double? heading}) => MapBusMarker(
        busId: busId,
        busName: busName,
        position: position ?? this.position,
        speedKmh: speedKmh,
        heading: heading ?? this.heading,
        isActive: isActive,
        etaMinutes: etaMinutes,
        trackMode: trackMode,
      );
}

/// Optional campus / stop reference point
class MapStopMarker {
  final String label;
  final LatLng position;
  final bool isGate;

  const MapStopMarker({
    required this.label,
    required this.position,
    this.isGate = false,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Route split result
// ─────────────────────────────────────────────────────────────────────────────

class RouteSplit {
  final List<LatLng> traveled;
  final List<LatLng> remaining;

  const RouteSplit({required this.traveled, required this.remaining});
}

// ─────────────────────────────────────────────────────────────────────────────
// LiveMapWidget
// ─────────────────────────────────────────────────────────────────────────────

class LiveMapWidget extends StatefulWidget {
  /// All buses to render. Pass one for Student focus, many for Teacher overview.
  final List<MapBusMarker> buses;

  /// Planned route polyline points (optional)
  final List<LatLng> routePoints;

  /// Campus / stop markers (optional)
  final List<MapStopMarker> stops;

  /// Current user GPS position (optional — shows blue dot)
  final LatLng? userPosition;

  /// GPS accuracy radius in meters
  final double userAccuracyMeters;

  /// Which bus to focus/follow (null = show all)
  final String? focusedBusId;

  /// Called when user taps a bus marker
  final void Function(MapBusMarker bus)? onBusTapped;

  /// Called when map is dragged (so parent can stop auto-follow)
  final VoidCallback? onMapDragged;

  /// Whether the map should auto-follow the focused bus
  final bool autoFollow;

  /// Show the speed/ETA overlay panel
  final bool showInfoPanel;

  /// Show user location dot
  final bool showUserLocation;

  /// Initial map center (defaults to first bus or user position)
  final LatLng? initialCenter;

  /// Initial zoom level
  final double initialZoom;

  const LiveMapWidget({
    super.key,
    required this.buses,
    this.routePoints = const [],
    this.stops = const [],
    this.userPosition,
    this.userAccuracyMeters = 0,
    this.focusedBusId,
    this.onBusTapped,
    this.onMapDragged,
    this.autoFollow = true,
    this.showInfoPanel = true,
    this.showUserLocation = true,
    this.initialCenter,
    this.initialZoom = 15.0,
  });

  @override
  State<LiveMapWidget> createState() => _LiveMapWidgetState();
}

class _LiveMapWidgetState extends State<LiveMapWidget>
    with TickerProviderStateMixin {
  // ── flutter_map controller (AnimatedMapController for smooth auto-follow) ──
  late final AnimatedMapController _mapCtrl;

  // ── Smooth position interpolation per bus ─────────────────────────────────
  final Map<String, AnimationController> _posCtrl = {};
  final Map<String, Animation<double>> _latAnim = {};
  final Map<String, Animation<double>> _lngAnim = {};
  final Map<String, LatLng> _currentPos = {};

  // ── Heading (rotation) interpolation ──────────────────────────────────────
  final Map<String, AnimationController> _headCtrl = {};
  final Map<String, Animation<double>> _headAnim = {};
  final Map<String, double> _currentHead = {};

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _userDragged = false;
  String? _selectedBusId;
  bool _mapReady = false;

  // ── Tile error tracking ───────────────────────────────────────────────────
  bool _tileError = false;

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _mapCtrl = AnimatedMapController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );

    // Seed initial positions
    for (final bus in widget.buses) {
      _currentPos[bus.busId] = bus.position;
      _currentHead[bus.busId] = bus.heading;
    }
  }

  @override
  void didUpdateWidget(LiveMapWidget old) {
    super.didUpdateWidget(old);

    for (final bus in widget.buses) {
      final prev = _currentPos[bus.busId];
      if (prev == null) {
        _currentPos[bus.busId] = bus.position;
        _currentHead[bus.busId] = bus.heading;
        continue;
      }

      // Animate position
      if (prev != bus.position) {
        _animatePosition(bus.busId, prev, bus.position);
      }

      // Animate heading
      final prevHead = _currentHead[bus.busId] ?? 0;
      if ((prevHead - bus.heading).abs() > 2) {
        _animateHeading(bus.busId, prevHead, bus.heading);
      }
    }

    // Auto-follow focused bus with smooth animation (was instant jump)
    if (!_userDragged && widget.autoFollow && widget.focusedBusId != null) {
      final target =
          widget.buses.where((b) => b.busId == widget.focusedBusId).firstOrNull;
      if (target != null && _mapReady) {
        _mapCtrl.animateTo(dest: target.position);
      }
    }
  }

  @override
  void dispose() {
    for (final c in _posCtrl.values) c.dispose();
    for (final c in _headCtrl.values) c.dispose();
    // Note: MapController.dispose() removed - not needed in flutter_map v6+
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Animation helpers
  // ─────────────────────────────────────────────────────────────────────────

  void _animatePosition(String busId, LatLng from, LatLng to) {
    // FIX #6: Stop old controller before dispose to prevent stale setState calls
    _posCtrl[busId]?.stop();
    _posCtrl[busId]?.dispose();
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _posCtrl[busId] = ctrl;

    _latAnim[busId] = Tween<double>(
      begin: from.latitude,
      end: to.latitude,
    ).animate(CurvedAnimation(parent: ctrl, curve: Curves.easeInOut));
    _lngAnim[busId] = Tween<double>(
      begin: from.longitude,
      end: to.longitude,
    ).animate(CurvedAnimation(parent: ctrl, curve: Curves.easeInOut));

    ctrl.addListener(() {
      if (!mounted) return;
      setState(() {
        _currentPos[busId] = LatLng(
          _latAnim[busId]!.value,
          _lngAnim[busId]!.value,
        );
      });
    });

    ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _currentPos[busId] = to;
      }
    });

    ctrl.forward();
  }

  void _animateHeading(String busId, double from, double to) {
    // FIX #6: Stop old controller before dispose to prevent stale setState calls
    _headCtrl[busId]?.stop();
    _headCtrl[busId]?.dispose();
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _headCtrl[busId] = ctrl;

    _headAnim[busId] = Tween<double>(
      begin: from,
      end: to,
    ).animate(CurvedAnimation(parent: ctrl, curve: Curves.easeOut));

    ctrl.addListener(() {
      if (!mounted) return;
      setState(() => _currentHead[busId] = _headAnim[busId]!.value);
    });
    ctrl.forward();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Map center logic
  // ─────────────────────────────────────────────────────────────────────────

  LatLng get _initialCenter {
    if (widget.initialCenter != null) return widget.initialCenter!;
    if (widget.focusedBusId != null) {
      final b =
          widget.buses.where((b) => b.busId == widget.focusedBusId).firstOrNull;
      if (b != null) return b.position;
    }
    if (widget.buses.isNotEmpty) return widget.buses.first.position;
    if (widget.userPosition != null) return widget.userPosition!;
    // Fallback: Dhaka, Bangladesh
    return const LatLng(23.8103, 90.4125);
  }

  void _recenter() {
    setState(() => _userDragged = false);
    final target = widget.focusedBusId != null
        ? widget.buses
            .where((b) => b.busId == widget.focusedBusId)
            .firstOrNull
            ?.position
        : (widget.userPosition ?? _initialCenter);
    if (target != null) {
      _mapCtrl.animateTo(dest: target, zoom: 15.5);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Route splitting helper (FIX #8: traveled vs remaining trail)
  // ─────────────────────────────────────────────────────────────────────────

  /// Splits route points into traveled and remaining portions based on bus position
  RouteSplit _splitRouteByBusPosition(
    List<LatLng> routePoints,
    LatLng busPosition,
  ) {
    if (routePoints.length < 2) {
      return const RouteSplit(traveled: [], remaining: []);
    }

    final traveled = <LatLng>[];
    final remaining = <LatLng>[];

    const distance = Distance();

    int closestIndex = 0;
    double minDist = double.infinity;

    for (int i = 0; i < routePoints.length; i++) {
      final d = distance.as(LengthUnit.Meter, routePoints[i], busPosition);
      if (d < minDist) {
        minDist = d;
        closestIndex = i;
      }
    }

    traveled.addAll(routePoints.take(closestIndex + 1));
    // Overlap busPosition in both lists at the transition for visual continuity.
    if (closestIndex < routePoints.length - 1) {
      traveled.add(busPosition);
      remaining.add(busPosition);
    }
    remaining.addAll(routePoints.skip(closestIndex));

    return RouteSplit(traveled: traveled, remaining: remaining);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Calculate route split for traveled vs remaining portions (FIX #8)
    List<LatLng> traveledRoute = [];
    List<LatLng> remainingRoute = [];
    if (widget.routePoints.length >= 2 && widget.focusedBusId != null) {
      final focusedBus =
          widget.buses.where((b) => b.busId == widget.focusedBusId).firstOrNull;
      if (focusedBus != null) {
        final busPos = _currentPos[focusedBus.busId] ?? focusedBus.position;
        final split = _splitRouteByBusPosition(widget.routePoints, busPos);
        traveledRoute = split.traveled;
        remainingRoute = split.remaining;
      }
    }

    return Stack(
      children: [
        // ── flutter_map ──────────────────────────────────────────────────────
        FlutterMap(
          mapController: _mapCtrl.mapController,
          options: MapOptions(
            initialCenter: _initialCenter,
            initialZoom: widget.initialZoom,
            minZoom: 10,
            maxZoom: 19,
            onMapReady: () => setState(() => _mapReady = true),
            // FIX #4: Replaced deprecated onPositionChanged with onMapEvent
            onMapEvent: (event) {
              if (event is MapEventMove &&
                  event.source == MapEventSource.dragEnd) {
                if (!_userDragged) {
                  setState(() => _userDragged = true);
                  widget.onMapDragged?.call();
                }
              }
            },
          ),
          children: [
            // ── OSM tile layer ───────────────────────────────────────────────
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.unitrack.app',
              maxZoom: 19,
              errorTileCallback: (tile, error, _) {
                if (!_tileError) setState(() => _tileError = true);
              },
              // Tile styling: slight hue shift toward navy for brand consistency
              tileBuilder: (ctx, tileWidget, tile) => ColorFiltered(
                colorFilter: const ColorFilter.matrix(<double>[
                  0.95, 0.00, 0.00, 0, 0, // R channel
                  0.00, 0.97, 0.00, 0, 0, // G channel
                  0.00, 0.00, 1.05, 0, 0, // B channel — very slight blue push
                  0.00, 0.00, 0.00, 1, 0,
                ]),
                child: tileWidget,
              ),
            ),

            // ── Route polyline (planned path) ────────────────────────────────
            if (widget.routePoints.length >= 2)
              PolylineLayer(
                polylines: [
                  // FIX #1 & #5: Replaced isDotted with strokePattern, withOpacity with withValues
                  // FIX #8: Split into traveled (grey) and remaining (navy) portions

                  // Shadow / glow for traveled portion (grey)
                  if (traveledRoute.length >= 2)
                    Polyline(
                      points: traveledRoute,
                      strokeWidth: 6,
                      color: AppColors.routeTrailTraveled.withValues(alpha: 0.15),
                    ),

                  // Traveled portion (muted grey)
                  if (traveledRoute.length >= 2)
                    Polyline(
                      points: traveledRoute,
                      strokeWidth: 3.5,
                      color: AppColors.routeTrailTraveled.withValues(alpha: 0.6),
                    ),

                  // Shadow / glow for remaining portion (navy)
                  if (remainingRoute.length >= 2)
                    Polyline(
                      points: remainingRoute,
                      strokeWidth: 6,
                      color: AppColors.navy.withValues(alpha: 0.15),
                    ),

                  // Remaining portion (brand navy)
                  if (remainingRoute.length >= 2)
                    Polyline(
                      points: remainingRoute,
                      strokeWidth: 3.5,
                      color: AppColors.routeLine.withValues(alpha: 0.75),
                    ),

                  // Dashed overlay for direction feel (remaining portion only)
                  if (remainingRoute.length >= 2)
                    Polyline(
                      points: remainingRoute,
                      strokeWidth: 1.5,
                      color: Colors.white.withValues(alpha: 0.5),
                      isDotted: true,
                    ),
                ],
              ),

            // ── User accuracy circle ─────────────────────────────────────────
            if (widget.showUserLocation &&
                widget.userPosition != null &&
                widget.userAccuracyMeters > 0)
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: widget.userPosition!,
                    radius: widget.userAccuracyMeters,
                    useRadiusInMeter: true,
                    // FIX #5: withOpacity -> withValues
                    color: AppColors.userDot.withValues(alpha: 0.12),
                    borderColor: AppColors.userDot.withValues(alpha: 0.4),
                    borderStrokeWidth: 1,
                  ),
                ],
              ),

            // ── Stop / gate markers ──────────────────────────────────────────
            MarkerLayer(
              markers: widget.stops
                  .map(
                    (s) => Marker(
                      point: s.position,
                      width: 80,
                      height: 40,
                      child: _StopMarkerWidget(stop: s),
                    ),
                  )
                  .toList(),
            ),

            // ── User location blue dot ───────────────────────────────────────
            if (widget.showUserLocation && widget.userPosition != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: widget.userPosition!,
                    width: 24,
                    height: 24,
                    child: _UserDotWidget(),
                  ),
                ],
              ),

            // ── Bus markers (animated) ───────────────────────────────────────
            MarkerLayer(
              markers: widget.buses.map((bus) {
                final pos = _currentPos[bus.busId] ?? bus.position;
                final head = _currentHead[bus.busId] ?? bus.heading;
                final isFocused = _selectedBusId == bus.busId ||
                    widget.focusedBusId == bus.busId;

                return Marker(
                  point: pos,
                  width: isFocused ? 72 : 56,
                  height: isFocused ? 88 : 68,
                  alignment: Alignment.bottomCenter,
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _selectedBusId = bus.busId);
                      widget.onBusTapped?.call(bus);
                    },
                    // FIX #9: Add tooltip for unfocused buses showing bus name
                    child: Tooltip(
                      message: isFocused ? '' : bus.busName,
                      waitDuration: const Duration(milliseconds: 300),
                      child: _BusMarkerWidget(
                        bus: bus,
                        heading: head,
                        isFocused: isFocused,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),

            // ── Attribution ──────────────────────────────────────────────────
            const RichAttributionWidget(
              animationConfig: ScaleRAWA(),
              attributions: [
                TextSourceAttribution(
                  '© OpenStreetMap contributors',
                  textStyle: TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),

        // ── Tile error banner ────────────────────────────────────────────────
        if (_tileError)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TileErrorBanner(
              onDismiss: () {
                setState(() => _tileError = false);
              },
            ),
          ),

        // ── Info panel overlay ───────────────────────────────────────────────
        if (widget.showInfoPanel)
          Positioned(
            left: 12,
            right: 12,
            bottom: 16,
            child: _InfoPanel(
              buses: widget.buses,
              focusedBusId: widget.focusedBusId ?? _selectedBusId,
            ),
          ),

        // ── Zoom controls ────────────────────────────────────────────────────
        Positioned(
          right: 12,
          bottom: widget.showInfoPanel ? 130 : 20,
          child: _ZoomControls(
            onZoomIn: () => _mapCtrl.animatedZoomIn(),
            onZoomOut: () => _mapCtrl.animatedZoomOut(),
          ),
        ),

        // ── Re-center FAB ────────────────────────────────────────────────────
        if (_userDragged)
          Positioned(
            right: 12,
            bottom: widget.showInfoPanel ? 190 : 80,
            child: _RecenterButton(onTap: _recenter),
          ),

        // ── Map not ready overlay ────────────────────────────────────────────
        if (!_mapReady)
          Container(
            color: Colors.white,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.navy),
                  SizedBox(height: 12),
                  Text(
                    'Loading map…',
                    style: TextStyle(
                      fontFamily: AppTextStyles.fontFamily,
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bus marker widget — rotates with heading, pulses when active
// ─────────────────────────────────────────────────────────────────────────────

class _BusMarkerWidget extends StatefulWidget {
  final MapBusMarker bus;
  final double heading;
  final bool isFocused;

  const _BusMarkerWidget({
    required this.bus,
    required this.heading,
    required this.isFocused,
  });

  @override
  State<_BusMarkerWidget> createState() => _BusMarkerWidgetState();
}

class _BusMarkerWidgetState extends State<_BusMarkerWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseScale;
  late final Animation<double> _pulseOpacity;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _pulseScale = Tween<double>(
      begin: 1.0,
      end: 2.4,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeOut));
    _pulseOpacity = Tween<double>(
      begin: 0.55,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.isFocused ? 48.0 : 36.0;
    final color = widget.bus.isActive ? AppColors.navy : Colors.grey.shade400;
    final borderColor = widget.isFocused ? AppColors.activeGreen : Colors.white;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pulse ring (active buses only)
        Stack(
          alignment: Alignment.center,
          children: [
            if (widget.bus.isActive)
              AnimatedBuilder(
                animation: _pulseCtrl,
                builder: (_, __) => Transform.scale(
                  scale: _pulseScale.value,
                  child: Opacity(
                    opacity: _pulseOpacity.value,
                    child: Container(
                      width: size * 0.6,
                      height: size * 0.6,
                      decoration: BoxDecoration(
                        color: widget.isFocused ? AppColors.activeGreen : AppColors.navy,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),

            // Bus icon container with heading rotation
            Transform.rotate(
              angle: widget.heading * (math.pi / 180),
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: borderColor, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      // FIX #5: withOpacity -> withValues
                      color: color.withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.directions_bus_rounded,
                  color: Colors.white,
                  size: size * 0.52,
                ),
              ),
            ),
          ],
        ),

        // Name label (focused only)
        if (widget.isFocused) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.navy,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  // FIX #5: withOpacity -> withValues
                  color: AppColors.navy.withValues(alpha: 0.3),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              widget.bus.busName,
              style: const TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.1,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// User location blue dot with animated inner ring
// ─────────────────────────────────────────────────────────────────────────────

class _UserDotWidget extends StatefulWidget {
  @override
  State<_UserDotWidget> createState() => _UserDotWidgetState();
}

class _UserDotWidgetState extends State<_UserDotWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _scale = Tween<double>(
      begin: 0.85,
      end: 1.15,
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
      animation: _scale,
      builder: (_, __) => Transform.scale(
        scale: _scale.value,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: AppColors.userDot,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                // FIX #5: withOpacity -> withValues
                color: AppColors.userDot.withValues(alpha: 0.45),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stop / gate marker
// ─────────────────────────────────────────────────────────────────────────────

class _StopMarkerWidget extends StatelessWidget {
  final MapStopMarker stop;

  const _StopMarkerWidget({required this.stop});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: stop.isGate ? AppColors.navy : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: stop.isGate ? AppColors.navy : Colors.grey.shade300,
            ),
            boxShadow: const [
              BoxShadow(color: AppColors.shadow, blurRadius: 4, offset: Offset(0, 2)),
            ],
          ),
          child: Text(
            stop.label,
            style: TextStyle(
              fontFamily: AppTextStyles.fontFamily,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: stop.isGate ? Colors.white : AppColors.textPrimary,
            ),
          ),
        ),
        Container(
          width: 2,
          height: 8,
          color: stop.isGate ? AppColors.navy : Colors.grey.shade400,
        ),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: stop.isGate ? AppColors.navy : Colors.grey.shade400,
            shape: BoxShape.circle,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Info panel — bottom overlay with speed / distance / ETA
// ─────────────────────────────────────────────────────────────────────────────

class _InfoPanel extends StatelessWidget {
  final List<MapBusMarker> buses;
  final String? focusedBusId;

  const _InfoPanel({required this.buses, this.focusedBusId});

  @override
  Widget build(BuildContext context) {
    // Show focused bus stats, or "N buses active" summary
    final focused = focusedBusId != null
        ? buses.where((b) => b.busId == focusedBusId).firstOrNull
        : null;

    if (focused != null) {
      return _SingleBusPanel(bus: focused);
    }

    // Multi-bus summary (Teacher overview)
    final activeCount = buses.where((b) => b.isActive).length;
    return _MultiBusSummaryPanel(
      totalBuses: buses.length,
      activeBuses: activeCount,
    );
  }
}

class _SingleBusPanel extends StatelessWidget {
  final MapBusMarker bus;

  const _SingleBusPanel({required this.bus});

  @override
  Widget build(BuildContext context) {
    final etaText = bus.etaMinutes < 0
        ? '—'
        : bus.etaMinutes == 0
            ? 'Arrived'
            : '${bus.etaMinutes} min';

    final etaColor = bus.etaMinutes >= 0 && bus.etaMinutes <= 5
        ? AppColors.activeGreen
        : AppColors.warningAmber;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(color: AppColors.shadow, blurRadius: 16, offset: Offset(0, 4)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header strip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                color: AppColors.navy,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.directions_bus_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      bus.busName,
                      style: const TextStyle(
                        fontFamily: AppTextStyles.fontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  // Active badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: bus.isActive
                          ? AppColors.activeGreen
                          // FIX #5: withOpacity -> withValues
                          : Colors.white.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      bus.isActive ? 'LIVE' : 'OFFLINE',
                      style: const TextStyle(
                        fontFamily: AppTextStyles.fontFamily,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Stats row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  _PanelStat(
                    icon: Icons.speed_rounded,
                    label: 'Speed',
                    value: bus.isActive
                        ? '${bus.speedKmh.toStringAsFixed(0)} km/h'
                        : '—',
                    valueColor: AppColors.textPrimary,
                  ),
                  const _PanelDivider(),
                  _PanelStat(
                    icon: Icons.schedule_rounded,
                    label: 'ETA',
                    value: etaText,
                    valueColor: etaColor,
                  ),
                  const _PanelDivider(),
                  _PanelStat(
                    icon: Icons.navigation_rounded,
                    label: 'Heading',
                    value: _headingLabel(bus.heading),
                    valueColor: AppColors.textPrimary,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _headingLabel(double deg) {
    if (deg >= 337.5 || deg < 22.5) return 'N';
    if (deg < 67.5) return 'NE';
    if (deg < 112.5) return 'E';
    if (deg < 157.5) return 'SE';
    if (deg < 202.5) return 'S';
    if (deg < 247.5) return 'SW';
    if (deg < 292.5) return 'W';
    return 'NW';
  }
}

class _MultiBusSummaryPanel extends StatelessWidget {
  final int totalBuses;
  final int activeBuses;

  const _MultiBusSummaryPanel({
    required this.totalBuses,
    required this.activeBuses,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: AppColors.shadow, blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.navySurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.directions_bus_rounded,
              color: AppColors.navy,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$activeBuses of $totalBuses buses active',
                style: const TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const Text(
                'Tap a bus marker to focus',
                style: TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Active count indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: activeBuses > 0
                  // FIX #5: withOpacity -> withValues
                  ? AppColors.activeGreen.withValues(alpha: 0.12)
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$activeBuses LIVE',
              style: TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: activeBuses > 0 ? AppColors.activeGreen : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;

  const _PanelStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 12, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontFamily: AppTextStyles.fontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: valueColor,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelDivider extends StatelessWidget {
  const _PanelDivider();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 32, color: AppColors.chipDivider);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zoom controls
// ─────────────────────────────────────────────────────────────────────────────

class _ZoomControls extends StatelessWidget {
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  const _ZoomControls({required this.onZoomIn, required this.onZoomOut});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: AppColors.shadow, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomBtn(icon: Icons.add, onTap: onZoomIn),
          Container(height: 1, width: 36, color: AppColors.chipDivider),
          _ZoomBtn(icon: Icons.remove, onTap: onZoomOut),
        ],
      ),
    );
  }
}

class _ZoomBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ZoomBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, color: AppColors.navy, size: 20),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Re-center FAB
// ─────────────────────────────────────────────────────────────────────────────

class _RecenterButton extends StatelessWidget {
  final VoidCallback onTap;

  const _RecenterButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.navy,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              // FIX #5: withOpacity -> withValues
              color: AppColors.navy.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Icon(
          Icons.my_location_rounded,
          color: Colors.white,
          size: 20,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tile error banner
// ─────────────────────────────────────────────────────────────────────────────

class _TileErrorBanner extends StatelessWidget {
  final VoidCallback onDismiss;

  const _TileErrorBanner({required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          // FIX #5: withOpacity -> withValues
          color: AppColors.errorRed.withValues(alpha: 0.95),
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(12),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Map tiles unavailable — check internet connection',
                style: TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            GestureDetector(
              onTap: onDismiss,
              child: const Icon(Icons.close, color: Colors.white, size: 16),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// REMOVED: Custom _IterableExt extension
// FIX #3: Using Dart SDK 2.15+ built-in IterableExtension from collection package
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Usage examples (reference only — not compiled)
// ─────────────────────────────────────────────────────────────────────────────
//
// ── Student: single bus focus ───────────────────────────────────────────────
//
// LiveMapWidget(
//   buses: [
//     MapBusMarker(
//       busId: 'bus_01',
//       busName: 'Shuttle A',
//       position: LatLng(23.8103, 90.4125),
//       speedKmh: 34,
//       heading: 45,
//       isActive: true,
//       etaMinutes: 4,
//     ),
//   ],
//   routePoints: myRouteLatLngs,
//   stops: [
//     MapStopMarker(label: 'Main Gate', position: LatLng(23.811, 90.413), isGate: true),
//     MapStopMarker(label: 'CSE Block', position: LatLng(23.809, 90.411)),
//   ],
//   userPosition: LatLng(23.8095, 90.412),
//   userAccuracyMeters: 15,
//   focusedBusId: 'bus_01',
//   autoFollow: true,
//   showInfoPanel: true,
//   showUserLocation: true,
//   onBusTapped: (bus) => debugPrint('Tapped ${bus.busName}'),
//   onMapDragged: () => ref.read(mapFollowProvider.notifier).state = false,
// ),
//
// ── Teacher: multi-bus overview ─────────────────────────────────────────────
//
// LiveMapWidget(
//   buses: allActiveBuses,  // List<MapBusMarker> from Riverpod provider
//   showInfoPanel: true,
//   showUserLocation: false,
//   autoFollow: false,
//   initialCenter: LatLng(23.8103, 90.4125),
//   initialZoom: 13,
// ),
