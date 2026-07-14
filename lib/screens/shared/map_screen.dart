// lib/screens/shared/map_screen.dart
// UniTrack — Student Live Map Screen (Google Maps)

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../../theme/app_color.dart';
import '../../theme/app_text_styles.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:intl/intl.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/bus_model.dart';
import '../../providers/bus_providers.dart';
import '../../services/location_cache_service.dart';
import '../../models/stoppage_model.dart';
import '../../services/stoppage_notification_service.dart';
import 'package:latlong2/latlong.dart' as ll;

class LiveMapScreen extends ConsumerStatefulWidget {
  final String? busId;

  const LiveMapScreen({
    super.key,
    this.busId,
  });

  @override
  ConsumerState<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends ConsumerState<LiveMapScreen>
    with TickerProviderStateMixin {
  GoogleMapController? _mapCtrl;

  late final AnimationController _panelCtrl;
  late final AnimationController _pulseCtrl;
  late final Animation<double> _panelAnim;
  late final Animation<double> _pulseAnim;

  bool _following = true;
  bool _mapLoaded = false;

  // Marker smooth animation
  LatLng? _lastBusPos;
  LatLng? _animatedBusPos;
  late final AnimationController _markerAnimCtrl;
  late Animation<LatLng> _markerPosAnim;

  // Google Maps state
  Set<Marker> _markers = {};

  // Custom bus icon cache (pre-generated per bus color)
  final Map<String, BitmapDescriptor> _busIconCache = {};

  // Stop flag icon for stoppage markers
  BitmapDescriptor? _stopFlagIcon;

  MapType _mapType = MapType.normal;

  // GPS noise filter
  DateTime? _lastGpsUpdate;
  LatLng? _lastValidPos;

  // Track timing of bus updates for smooth marker animation
  DateTime? _lastBusUpdateReceivedAt;

  bool _isOffline = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  bool _trafficEnabled = false;
  bool _isBusHalted = false;
  Timer? _haltTimer;
  // FIX: Timer for geocoding — completely separate from update flow
  Timer? _geocodeTimer;
  LatLng? _lastGeocodePos;

  final DraggableScrollableController _sheetCtrl =
      DraggableScrollableController();

  String _currentPlaceName = '';

  // FIX: Track the latest bus update — no drop, always process latest
  final Queue<BusModel> _pendingBusUpdates = Queue<BusModel>();
  bool _isProcessingUpdate = false;

  @override
  void initState() {
    super.initState();

    _panelCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _panelAnim =
        CurvedAnimation(parent: _panelCtrl, curve: Curves.easeOutCubic);
    _panelCtrl.forward();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // FIX: Reduced to 600ms — fast enough to look smooth, doesn't block next update
    _markerAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    // FIX 1: Initialize _markerPosAnim with a no-op tween so the listener never
    // accesses an uninitialized late field before the first bus update arrives.
    _markerPosAnim = AlwaysStoppedAnimation<LatLng>(const LatLng(0, 0));
    _markerAnimCtrl.addListener(_onMarkerAnimTick);

    _startConnectivityMonitoring();

    // STEP 2: Load stop flag icon and pre-generate custom bus icons after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _preloadBusIcons();
      final flag = await _buildStopFlag();
      if (mounted) {
        setState(() => _stopFlagIcon = flag);
        // Re-trigger overlay update once icons finish loading so any
        // bus data that arrived before icons were ready gets rendered properly.
        if (widget.busId != null) {
          final bus = ref.read(busDetailProvider(widget.busId!)).valueOrNull;
          if (bus != null) _updateMapOverlays(bus);
        }
        // For all-buses mode, trigger a rebuild to refresh markers with custom icons
        if (widget.busId == null) {
          setState(() {});
        }
      }
    });
  }

  void _startConnectivityMonitoring() async {
    final initial = await Connectivity().checkConnectivity();
    if (mounted) {
      setState(() =>
          _isOffline = initial.every((r) => r == ConnectivityResult.none));
    }
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      if (mounted && _isOffline != !isConnected) {
        setState(() => _isOffline = !isConnected);
      }
    });
  }

  @override
  void dispose() {
    // FIX: Reset stoppage notification service before navigating away
    stoppageNotificationService.reset();

    _haltTimer?.cancel();
    _geocodeTimer?.cancel();
    _connectivitySub?.cancel();
    _panelCtrl.dispose();
    _pulseCtrl.dispose();
    // FIX 5: Remove the listener BEFORE disposing the controller to avoid
    // a leaked subscription on the AnimationController.
    _markerAnimCtrl.removeListener(_onMarkerAnimTick);
    _markerAnimCtrl.dispose();
    _sheetCtrl.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }

  Future<BitmapDescriptor> _buildStopFlag() async {
    const double W = 48.0, H = 72.0;
    const double cx = W / 2; // 24
    const double signR = 18.0; // octagon circumradius
    const double signCY = 20.0; // octagon center Y
    const double poleX = cx;
    const double poleTop = signCY + signR - 2;
    const double poleBottom = H - 6;
    const double poleW = 5.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // ── 1. Ground shadow ──────────────────────────────
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(cx + 1, poleBottom + 3), width: 14, height: 5),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // ── 2. Pole (gold/yellow like the image) ─────────
    final poleRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(poleX - poleW / 2, poleTop, poleW, poleBottom - poleTop),
      const Radius.circular(2.5),
    );
    // Pole gradient — left lighter, right darker for depth
    canvas.drawRRect(
      poleRect,
      Paint()..color = AppColors.amber,
    );
    // Highlight strip on left edge of pole
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
            poleX - poleW / 2, poleTop, poleW * 0.35, poleBottom - poleTop),
        const Radius.circular(2.5),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.25),
    );

    // ── 3. Octagon path ───────────────────────────────
    Path _octagon(double cx, double cy, double r) {
      final path = Path();
      for (int i = 0; i < 8; i++) {
        final angle = (math.pi / 8) + (i * math.pi / 4);
        final x = cx + r * math.cos(angle);
        final y = cy + r * math.sin(angle);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();
      return path;
    }

    // Drop shadow behind sign
    canvas.drawPath(
      _octagon(cx + 1.5, signCY + 1.5, signR),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // Dark border ring
    canvas.drawPath(
      _octagon(cx, signCY, signR),
      Paint()..color = Colors.black,
    );

    // Red fill
    canvas.drawPath(
      _octagon(cx, signCY, signR - 2),
      Paint()..color = AppColors.red,
    );

    // White inner border
    canvas.drawPath(
      _octagon(cx, signCY, signR - 4),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // ── 4. "STOP" text ────────────────────────────────
    final paragraph = (ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: TextAlign.center,
        fontSize: 7.5,
        fontWeight: ui.FontWeight.w700,
      ),
    )
          ..pushStyle(ui.TextStyle(color: Colors.white))
          ..addText('STOP'))
        .build()
      ..layout(const ui.ParagraphConstraints(width: 28));

    canvas.drawParagraph(paragraph, Offset(cx - 14, signCY - 4.5));

    // ── Convert ───────────────────────────────────────
    final picture = recorder.endRecording();
    final image = await picture.toImage(W.toInt(), H.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  // FIX: Geocoding with road name priority (thoroughfare) and 2s debounce
  void _scheduleGeocode(double lat, double lng) {
    final pos = LatLng(lat, lng);

    // FIX: Simple debounce — skip if position unchanged
    if (_lastGeocodePos != null &&
        _lastGeocodePos!.latitude == lat &&
        _lastGeocodePos!.longitude == lng) {
      return;
    }
    _lastGeocodePos = pos;

    _geocodeTimer?.cancel();
    // FIX: Reduced debounce from 5s to 2s for faster road name updates
    _geocodeTimer = Timer(const Duration(seconds: 2), () async {
      // FIX 7: Bail out immediately if the widget was disposed during the
      // 2s debounce window — otherwise we'd fire a network call on a dead
      // widget and `setState` after `await` would throw.
      if (!mounted) return;
      try {
        final placemarks = await placemarkFromCoordinates(lat, lng);
        if (placemarks.isNotEmpty && mounted) {
          final p = placemarks.first;

          // FIX: Build road-focused place name
          // Priority: thoroughfare (road) → subLocality → locality
          // Format: "Dhaka-Chittagong Highway, Krishnapur"
          String roadName = '';

          // First try: thoroughfare (actual road/street name)
          if (p.thoroughfare != null && p.thoroughfare!.isNotEmpty) {
            roadName = p.thoroughfare!;

            // Add subLocality if available (e.g., area name)
            if (p.subLocality != null && p.subLocality!.isNotEmpty) {
              roadName += ', ${p.subLocality}';
            }
          }
          // Second try: subLocality → locality as fallback
          else if (p.subLocality != null && p.subLocality!.isNotEmpty) {
            roadName = p.subLocality!;
            if (p.locality != null &&
                p.locality!.isNotEmpty &&
                p.locality != p.subLocality) {
              roadName += ', ${p.locality}';
            }
          }
          // Third try: locality
          else if (p.locality != null && p.locality!.isNotEmpty) {
            roadName = p.locality!;
          }
          // Last resort: use name field
          else if (p.name != null && p.name!.isNotEmpty) {
            roadName = p.name!;
          }

          if (roadName.isNotEmpty) {
            setState(() => _currentPlaceName = roadName);
          }
        }
      } catch (_) {}
    });
  }

  double _distanceKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = _toRad(b.latitude - a.latitude);
    final dLon = _toRad(b.longitude - a.longitude);
    final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(a.latitude)) *
            math.cos(_toRad(b.latitude)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  double _toRad(double deg) => deg * math.pi / 180;

  int _maxAnimClampMs() {
    final h = DateTime.now().hour;
    if (h >= 7 && h < 18) return 4000;   // active mode — matches ~3s write interval
    if (h >= 18 && h < 22) return 15000; // lowPower mode — matches ~30s write interval, capped below 30s so it doesn't feel sluggish
    return 20000; // sleep mode — GPS mostly paused, updates are rare; allow a longer glide
  }

  String _formatTime(int? ms) {
    if (ms == null) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(d);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return DateFormat('h:mm a').format(d);
  }

  // FIX: Removed _isProcessingUpdate guard — use simple position debounce instead
  void _onBusUpdateReceived(BusModel bus) {
    // FIX 4: Use a Queue so rapid intermediate updates are not silently
    // overwritten/dropped before they can be processed.
    _pendingBusUpdates.add(bus);
    _processNextUpdate();
  }

  Future<void> _processNextUpdate() async {
    if (!mounted) return;
    // FIX 4: Re-entrancy guard — if a previous update is still being
    // processed, just return. The currently-running invocation will drain
    // the queue when it finishes.
    if (_isProcessingUpdate) return;
    if (_pendingBusUpdates.isEmpty) return;

    _isProcessingUpdate = true;
    try {
      while (_pendingBusUpdates.isNotEmpty && mounted) {
        final bus = _pendingBusUpdates.removeFirst();
        await _handleBusUpdate(bus);
      }
    } finally {
      _isProcessingUpdate = false;
    }
  }

  Future<void> _handleBusUpdate(BusModel bus) async {
    try {
      if (bus.lat == 0.0 && bus.lng == 0.0) return;

      final newPos = LatLng(bus.lat, bus.lng);
      final now = DateTime.now();

      // FIX: Looser GPS noise filter — only reject truly impossible jumps
      if (_lastValidPos != null && _lastGpsUpdate != null) {
        final timeDiff =
            now.difference(_lastGpsUpdate!).inMilliseconds / 1000.0;
        if (timeDiff > 0.1) {
          final distKm = _distanceKm(_lastValidPos!, newPos);
          final speedMs = (distKm * 1000.0) / timeDiff;
          // Reject only if >55 m/s (≈200 km/h) — clearly GPS glitch
          if (speedMs > 55) {
            debugPrint(
                'UniTrack: GPS glitch rejected (${(speedMs * 3.6).toStringAsFixed(0)} km/h)');
            // FIX 3: Do NOT update _lastGpsUpdate / _lastValidPos when the
            // ping is rejected, otherwise the time-window resets and the
            // next valid ping could falsely pass the filter.
            return;
          }
        }
      }
      // FIX 3: Only mark this ping as the last valid one AFTER it survives
      // the rejection check above.
      _lastGpsUpdate = now;
      _lastValidPos = newPos;

      // STEP 5: _gpsHeading assignment removed
      // STEP 5: _breadcrumbs lines removed

      // FIX: Geocode scheduled separately — never blocks location update
      _scheduleGeocode(bus.lat, bus.lng);

      // First position — center map immediately
      if (_lastBusPos == null && _mapCtrl != null) {
        _mapCtrl?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: newPos, zoom: 16),
          ),
        );
        if (mounted) setState(() => _following = true);
        _lastBusUpdateReceivedAt = now;
      }

      if (widget.busId != null) {
        LocationCacheService.savePosition(widget.busId!, bus.lat, bus.lng);
      }

      // Smooth marker animation from current animated pos to new pos
      if (_lastBusPos != null) {
        // Compute elapsed time since last update for dynamic animation duration
        final elapsedMs = _lastBusUpdateReceivedAt != null
            ? now.difference(_lastBusUpdateReceivedAt!).inMilliseconds
            : 900; // Default 900ms for first animation
        // Clamp to reasonable range to handle GPS glitches
        final animDurationMs = elapsedMs.clamp(500, _maxAnimClampMs());
        _markerAnimCtrl.duration = Duration(milliseconds: animDurationMs);
        
        // FIX: If animation is running, start from current animated position
        final startPos = _animatedBusPos ?? _lastBusPos!;
        _markerAnimCtrl.stop();
        _markerAnimCtrl.reset();
        _markerPosAnim = LatLngTween(begin: startPos, end: newPos).animate(
            CurvedAnimation(parent: _markerAnimCtrl, curve: Curves.linear));
        _markerAnimCtrl.forward();
        
        _lastBusUpdateReceivedAt = now;
      }
      _lastBusPos = newPos;
      _animatedBusPos ??= newPos;

      // Halt detection
      if (bus.speed < 2) {
        _haltTimer ??= Timer(const Duration(seconds: 30), () {
          if (mounted) setState(() => _isBusHalted = true);
        });
      } else {
        _haltTimer?.cancel();
        _haltTimer = null;
        if (_isBusHalted && mounted) setState(() => _isBusHalted = false);
      }

      await _updateMapOverlays(bus);

      if (widget.busId != null) {
        final stoppages =
            ref.read(stoppagesProvider(widget.busId!)).valueOrNull ?? [];
        if (stoppages.isNotEmpty) {
          stoppageNotificationService.checkAndNotify(
            busId: widget.busId!,
            busPos: ll.LatLng(newPos.latitude, newPos.longitude),
            speedKmh: bus.speed,
            stoppages: stoppages,
          );
        }
      }

      if (_following && _mapLoaded && _mapCtrl != null) {
        _mapCtrl!.animateCamera(CameraUpdate.newLatLng(newPos));
      }
    } catch (_) {
      // Silently handle errors to continue processing
    }
  }

  void _onMarkerAnimTick() {
    if (mounted && _markerAnimCtrl.isAnimating) {
      setState(() => _animatedBusPos = _markerPosAnim.value);
    }
  }

  // STEP 6: Simple marker — no rotation, uses custom canvas-drawn pin with color tint
  Future<void> _updateMapOverlays(BusModel bus) async {
    // Stop flag icon is loaded asynchronously after the first frame.
    // If `onMapCreated` (or any other caller) invokes this before the
    // icon finishes decoding, bail out — `initState`'s post-frame callback
    // re-invokes us once the icon is ready.
    if (_stopFlagIcon == null) {
      debugPrint(
          'UniTrack: _updateMapOverlays skipped — stopFlag icon not loaded yet.');
      return;
    }

    final displayPos = _animatedBusPos ?? LatLng(bus.lat, bus.lng);

    // Use cached custom icon if available, otherwise generate on-demand for single-bus view
    BitmapDescriptor busIcon = _busIconCache[bus.busId] ??
        _busIconCache['default'] ??
        BitmapDescriptor.defaultMarker;

    // If icon not cached yet (rare race condition), generate it now
    if (_busIconCache[bus.busId] == null && _busIconCache['default'] == null) {
      busIcon = await _buildBusPin(_busMarkerColor(bus.busId));
      if (mounted) {
        setState(() => _busIconCache[bus.busId] = busIcon);
      }
    }

    // Simple marker — no rotation, custom icon with color tint
    final newMarkers = <Marker>{
      Marker(
        markerId: const MarkerId('bus'),
        position: displayPos,
        icon: busIcon,
        infoWindow: InfoWindow(
          title: bus.name,
          snippet: '${bus.speed.toStringAsFixed(0)} km/h • ${bus.route}',
        ),
        anchor: const Offset(0.5, 1.0), // pin tip নিচে → road এর উপর বসবে
        zIndex: 3,
      ),
    };

    // Stop flag markers — loaded from Firebase via stoppagesProvider
    if (widget.busId != null) {
      final stoppages =
          ref.read(stoppagesProvider(widget.busId!)).valueOrNull ?? [];
      for (final stop in stoppages) {
        newMarkers.add(Marker(
          markerId: MarkerId('stop_${stop.id}'),
          position: LatLng(stop.position.latitude, stop.position.longitude),
          icon: _stopFlagIcon ?? BitmapDescriptor.defaultMarker,
          anchor: const Offset(0.5, 1.0),
          zIndex: 2,
          infoWindow: InfoWindow(
            title: stop.name,
            snippet: _etaText(stop, bus),
          ),
        ));
      }
    }

    // _polylines field নেই — setState এ শুধু _markers update করো
    if (mounted) {
      setState(() {
        _markers = newMarkers;
      });
    }
  }

  String _etaText(Stoppage stop, BusModel bus) {
    if (!bus.active) return 'Bus offline';
    final eta = stop.etaMinutes(ll.LatLng(bus.lat, bus.lng), bus.speed);
    if (eta == null) return 'Bus is stopped';
    if (eta < 1) return 'Arriving now';
    return '~${eta.toStringAsFixed(0)} min away';
  }

  void _centerOnBus(BusModel bus) {
    if (bus.lat == 0 && bus.lng == 0) return;
    _mapCtrl?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: LatLng(bus.lat, bus.lng), zoom: 16),
      ),
    );
    setState(() => _following = true);
  }

  void _toggleTraffic() => setState(() => _trafficEnabled = !_trafficEnabled);
  void _toggleMapType() => setState(() {
        _mapType =
            _mapType == MapType.normal ? MapType.satellite : MapType.normal;
      });

  void _shareLocation(BusModel bus) {
    final deepLink = widget.busId != null
        ? 'https://unitrackapp.page.link/bus?id=${widget.busId}'
        : 'https://unitrackapp.page.link/';
    final text = '\u{1F4FD} Track ${bus.name} live on UniTrack!\n'
        'Route: ${bus.route}\n'
        'Tap to open: $deepLink';
    Share.share(text, subject: 'Track ${bus.name} — UniTrack');
  }

  static const LatLng _defaultMapPos = LatLng(23.8103, 90.4125);

  @override
  Widget build(BuildContext context) {
    // Single-bus mode: watch specific bus; All-buses mode: watch all buses
    final busAsync = widget.busId != null
        ? ref.watch(busDetailProvider(widget.busId!))
        : ref.watch(busesListProvider);

    if (widget.busId != null) {
      ref.listen<AsyncValue<BusModel?>>(busDetailProvider(widget.busId!),
          (_, next) {
        next.whenData((bus) {
          if (bus != null) _onBusUpdateReceived(bus);
        });
      });

      // FIX: stoppages listener with explicit busId guard
      ref.listen<AsyncValue<List<Stoppage>>>(stoppagesProvider(widget.busId!),
          (_, next) {
        next.whenData((stoppages) {
          // FIX 6: Bus data may not be loaded yet when stoppages arrive first.
          // Previously this returned silently — now log it so the issue is
          // visible during debugging instead of being swallowed.
          final bus = ref.read(busDetailProvider(widget.busId!)).valueOrNull;
          if (bus == null) {
            debugPrint(
                'UniTrack: stoppages update received but busDetailProvider(${widget.busId}) is not loaded yet — skipping overlay update.');
            return;
          }
          if (mounted) _updateMapOverlays(bus);
        });
      });
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: widget.busId != null
            ? (busAsync as AsyncValue<BusModel?>).when(
                loading: () => _buildLoading(),
                error: (e, _) => _buildError(e.toString()),
                data: (bus) => bus == null ? _buildLoading() : _buildMap(bus),
              )
            : (busAsync as AsyncValue<List<BusModel>>).when(
                loading: () => _buildLoading(),
                error: (e, _) => _buildError(e.toString()),
                data: (buses) => _buildAllBusesMap(buses),
              ),
      ),
    );
  }

  Widget _buildMap(BusModel bus) {
    final initialTarget = _lastBusPos ??
        (bus.lat != 0 && bus.lng != 0
            ? LatLng(bus.lat, bus.lng)
            : _defaultMapPos);

    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition:
              CameraPosition(target: initialTarget, zoom: 15.5),
          onMapCreated: (ctrl) {
            _mapCtrl = ctrl;
            setState(() => _mapLoaded = true);
            // Map load হওয়ার সাথে সাথেই existing stoppages দেখাও
            if (widget.busId != null) {
              final bus = ref.read(busDetailProvider(widget.busId!)).valueOrNull;
              if (bus != null) _updateMapOverlays(bus);
            }
          },
          markers: _markers,
          polylines: const {}, // STEP 7: breadcrumb trail removed
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          compassEnabled: false,
          mapToolbarEnabled: false,
          onCameraMoveStarted: () {
            if (_following) setState(() => _following = false);
          },
          mapType: _mapType,
          trafficEnabled: _trafficEnabled,
        ),
        if (_isOffline) _buildOfflineBanner(),
        _buildTopBar(bus),
        if (bus.active)
          Positioned(
            top: MediaQuery.of(context).padding.top + 72,
            right: 16,
            child: _buildSpeedBadge(bus.speed),
          ),
        Positioned(right: 16, bottom: 240, child: _buildMapControls(bus)),
        _buildBottomPanel(bus),
      ],
    );
  }

  Widget _buildAllBusesMap(List<BusModel> buses) {
    final activeBuses = buses.where((b) => b.active).toList();
    final initialTarget = activeBuses.isNotEmpty
        ? LatLng(activeBuses.first.lat, activeBuses.first.lng)
        : _defaultMapPos;

    // Compute markers directly without setState during build
    final markers = _buildAllBusesMarkerSet(activeBuses);

    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition:
              CameraPosition(target: initialTarget, zoom: 15.5),
          onMapCreated: (ctrl) {
            _mapCtrl = ctrl;
            setState(() => _mapLoaded = true);
            // Fit all active buses in view
            if (activeBuses.isNotEmpty) {
              _fitAllBusesInView(activeBuses);
            }
          },
          markers: markers,
          polylines: const {},
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          compassEnabled: false,
          mapToolbarEnabled: false,
          onCameraMoveStarted: () {
            if (_following) setState(() => _following = false);
          },
          mapType: _mapType,
          trafficEnabled: _trafficEnabled,
        ),
        if (_isOffline) _buildOfflineBanner(),
        _buildAllBusesTopBar(activeBuses),
        Positioned(right: 16, bottom: 240, child: _buildMapControlsForAllBuses()),
      ],
    );
  }

  void _fitAllBusesInView(List<BusModel> buses) {
    if (buses.isEmpty || _mapCtrl == null) return;

    double minLat = buses.first.lat;
    double maxLat = buses.first.lat;
    double minLng = buses.first.lng;
    double maxLng = buses.first.lng;

    for (final bus in buses) {
      if (bus.lat < minLat) minLat = bus.lat;
      if (bus.lat > maxLat) maxLat = bus.lat;
      if (bus.lng < minLng) minLng = bus.lng;
      if (bus.lng > maxLng) maxLng = bus.lng;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapCtrl?.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 100),
    );
  }

  Color _busMarkerColor(String busId) {
    // Map busId to actual Color for custom icon tinting
    switch (busId) {
      case 'bus_001':
        return Colors.red;
      case 'bus_002':
        return Colors.green;
      case 'bus_003':
        return Colors.blue;
      case 'bus_004':
        return Colors.orange;
      case 'bus_005':
        return const Color(0xFFE91E63); // Pink/Rose
      default:
        return AppColors.navy; // Default to app navy for unknown buses
    }
  }

  // Custom canvas-drawn bus pin with configurable color
  Future<BitmapDescriptor> _buildBusPin(Color color) async {
    const double W = 56.0;
    const double H = 72.0;
    const double cx = W / 2;
    const double r = 22.0;
    const double cy = r + 5;
    const double tipY = H - 5;
    final double D = tipY - cy;
    final double alpha = math.acos(r / D);
    final double leftJoinAngle = math.pi / 2 + alpha;
    final double sweepAngle = 2 * (math.pi - alpha);
    final double lx = cx + r * math.cos(leftJoinAngle);
    final double ly = cy + r * math.sin(leftJoinAngle);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Drop shadow
    final shadowPath = Path();
    shadowPath.moveTo(cx + 2, tipY + 2);
    shadowPath.lineTo(lx + 2, ly + 2);
    shadowPath.arcTo(
      Rect.fromCircle(center: Offset(cx + 2, cy + 2), radius: r),
      leftJoinAngle,
      sweepAngle,
      false,
    );
    shadowPath.lineTo(cx + 2, tipY + 2);
    shadowPath.close();

    canvas.drawPath(
      shadowPath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Pin body with custom color
    final pinPath = Path();
    pinPath.moveTo(cx, tipY);
    pinPath.lineTo(lx, ly);
    pinPath.arcTo(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      leftJoinAngle,
      sweepAngle,
      false,
    );
    pinPath.lineTo(cx, tipY);
    pinPath.close();

    canvas.drawPath(
      pinPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );

    // Highlight
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx - 3, cy - 3), radius: r * 0.72),
      math.pi * 1.1,
      math.pi * 0.65,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round,
    );

    // White circle hole
    canvas.drawCircle(
      Offset(cx, cy),
      r * 0.415,
      Paint()..color = Colors.white,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(W.toInt(), H.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  // Pre-generate bus icons for all known bus IDs
  Future<void> _preloadBusIcons() async {
    final knownBusIds = ['bus_001', 'bus_002', 'bus_003', 'bus_004', 'bus_005'];
    for (final busId in knownBusIds) {
      final color = _busMarkerColor(busId);
      final icon = await _buildBusPin(color);
      _busIconCache[busId] = icon;
    }
    // Also pre-generate a default icon for unknown buses
    final defaultIcon = await _buildBusPin(AppColors.navy);
    _busIconCache['default'] = defaultIcon;
  }

  Set<Marker> _buildAllBusesMarkerSet(List<BusModel> buses) {
    final newMarkers = <Marker>{};
    for (final bus in buses) {
      // Use cached custom icon if available, otherwise fall back to default marker
      final icon = _busIconCache[bus.busId] ??
          _busIconCache['default'] ??
          BitmapDescriptor.defaultMarker;
      newMarkers.add(Marker(
        markerId: MarkerId('bus_${bus.busId}'),
        position: LatLng(bus.lat, bus.lng),
        icon: icon,
        infoWindow: InfoWindow(
          title: bus.name,
          snippet: '${bus.speed.toStringAsFixed(0)} km/h • ${bus.route}',
        ),
        anchor: const Offset(0.5, 1.0),
        zIndex: 3,
      ));
    }
    return newMarkers;
  }

  Widget _buildAllBusesTopBar(List<BusModel> activeBuses) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 8,
          left: 8,
          right: 8,
          bottom: 12,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            _GlassButton(
              onTap: () => Navigator.pop(context),
              child: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15), width: 1),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: activeBuses.isNotEmpty ? AppColors.green : AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${activeBuses.length} Active Bus${activeBuses.length == 1 ? '' : 'es'}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: AppTextStyles.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapControlsForAllBuses() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GlassButton(
          onTap: () => _mapCtrl?.animateCamera(CameraUpdate.zoomIn()),
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 20),
        ),
        const SizedBox(height: 8),
        _GlassButton(
          onTap: () => _mapCtrl?.animateCamera(CameraUpdate.zoomOut()),
          child: const Icon(Icons.remove_rounded, color: Colors.white, size: 20),
        ),
        const SizedBox(height: 8),
        _GlassButton(
          onTap: _toggleTraffic,
          size: 44,
          active: _trafficEnabled,
          child: Icon(Icons.traffic_rounded,
              color: _trafficEnabled ? AppColors.green : Colors.white, size: 20),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _toggleMapType,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _mapType == MapType.satellite
                  ? AppColors.navy.withValues(alpha: 0.9)
                  : Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _mapType == MapType.satellite
                    ? AppColors.navyLight.withValues(alpha: 0.6)
                    : Colors.white.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _mapType == MapType.satellite
                      ? Icons.map_rounded
                      : Icons.satellite_alt_rounded,
                  color: Colors.white,
                  size: 16,
                ),
                const SizedBox(width: 5),
                Text(
                  _mapType == MapType.satellite ? 'Normal' : 'Satellite',
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: AppTextStyles.fontFamily,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOfflineBanner() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 60,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          children: [
            Icon(Icons.cloud_off_rounded, color: Colors.white, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Offline — showing last known location',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BusModel bus) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 8,
          left: 8,
          right: 8,
          bottom: 12,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            _GlassButton(
              onTap: () => Navigator.pop(context),
              child: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15), width: 1),
                ),
                child: Row(
                  children: [
                    AnimatedBuilder(
                      animation: _pulseAnim,
                      builder: (_, __) => Opacity(
                        opacity: bus.active ? _pulseAnim.value : 0.3,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: bus.active ? AppColors.green : AppColors.textMuted,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            bus.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontFamily: AppTextStyles.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            bus.route,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontFamily: AppTextStyles.fontFamily,
                                fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: bus.active
                            ? AppColors.green.withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: bus.active
                              ? AppColors.green.withValues(alpha: 0.5)
                              : Colors.white.withValues(alpha: 0.15),
                        ),
                      ),
                      child: Text(
                        bus.active ? 'LIVE' : 'OFFLINE',
                        style: TextStyle(
                          fontSize: 9,
                          fontFamily: AppTextStyles.fontFamily,
                          fontWeight: FontWeight.w800,
                          color: bus.active ? AppColors.green : AppColors.textMuted,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _GlassButton(
              onTap: () => _shareLocation(bus),
              child: const Icon(Icons.share_rounded,
                  color: Colors.white, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedBadge(double speed) {
    final isStationary = speed < 2;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isStationary
            ? Colors.black.withValues(alpha: 0.6)
            : AppColors.navy.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isStationary ? Icons.pause_circle_rounded : Icons.speed_rounded,
            color: isStationary ? AppColors.textMuted : Colors.white,
            size: 14,
          ),
          const SizedBox(width: 5),
          Text(
            isStationary ? 'Stopped' : '${speed.toStringAsFixed(0)} km/h',
            style: TextStyle(
              color: isStationary ? AppColors.textMuted : Colors.white,
              fontFamily: AppTextStyles.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapControls(BusModel bus) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GlassButton(
          onTap: () => _centerOnBus(bus),
          size: 44,
          active: _following,
          child: Icon(
            _following
                ? Icons.my_location_rounded
                : Icons.location_searching_rounded,
            color: _following ? AppColors.green : Colors.white,
            size: 20,
          ),
        ),
        const SizedBox(height: 8),
        _GlassButton(
          onTap: () => _mapCtrl?.animateCamera(CameraUpdate.zoomIn()),
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 20),
        ),
        const SizedBox(height: 8),
        _GlassButton(
          onTap: () => _mapCtrl?.animateCamera(CameraUpdate.zoomOut()),
          child:
              const Icon(Icons.remove_rounded, color: Colors.white, size: 20),
        ),
        const SizedBox(height: 8),
        _GlassButton(
          onTap: _toggleTraffic,
          size: 44,
          active: _trafficEnabled,
          child: Icon(Icons.traffic_rounded,
              color: _trafficEnabled ? AppColors.green : Colors.white, size: 20),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _toggleMapType,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _mapType == MapType.satellite
                  ? AppColors.navy.withValues(alpha: 0.9)
                  : Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _mapType == MapType.satellite
                    ? AppColors.navyLight.withValues(alpha: 0.6)
                    : Colors.white.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _mapType == MapType.satellite
                      ? Icons.map_rounded
                      : Icons.satellite_alt_rounded,
                  color: Colors.white,
                  size: 16,
                ),
                const SizedBox(width: 5),
                Text(
                  _mapType == MapType.satellite ? 'Normal' : 'Satellite',
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: AppTextStyles.fontFamily,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomPanel(BusModel bus) {
    final driverName = bus.driverName?.isNotEmpty == true
        ? bus.driverName!
        : 'Driver not specified';
    final driverNameColor =
        (bus.driverName?.isNotEmpty ?? false) ? AppColors.textPrimary : AppColors.textMuted;

    return DraggableScrollableSheet(
      controller: _sheetCtrl,
      initialChildSize: 0.22,
      minChildSize: 0.12,
      maxChildSize: 0.50,
      snap: true,
      snapSizes: const [0.12, 0.22, 0.42],
      builder: (_, scrollCtrl) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(_panelAnim),
          child: Container(
            decoration: const BoxDecoration(
              color: AppColors.cardBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x22000000),
                  blurRadius: 24,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: CustomScrollView(
              controller: scrollCtrl,
              physics: const ClampingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        bus.name,
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontFamily: AppTextStyles.fontFamily,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.textPrimary,
                                          letterSpacing: -0.3,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          const Icon(Icons.route_rounded,
                                              size: 12, color: AppColors.textMuted),
                                          const SizedBox(width: 4),
                                          Text(
                                            bus.route,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontFamily: AppTextStyles.fontFamily,
                                              color: AppColors.textSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                      // FIX: Show road name with road icon instead of place icon
                                      if (_currentPlaceName.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Icon(Icons.turn_right_rounded,
                                                size: 12, color: AppColors.navy),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                _currentPlaceName,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  fontFamily: AppTextStyles.fontFamily,
                                                  color: AppColors.navy,
                                                  fontWeight: FontWeight.w500,
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
                            const SizedBox(height: 12),
                            if (_isBusHalted)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.amberSoft,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.pause_circle_outline_rounded,
                                        size: 14, color: AppColors.amber),
                                    SizedBox(width: 4),
                                    Text(
                                      'Bus is currently halted',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontFamily: AppTextStyles.fontFamily,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.amber,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            _StatStrip(
                              icon: Icons.speed_rounded,
                              label: 'Speed',
                              value: bus.active
                                  ? '${bus.speed.toStringAsFixed(0)} km/h'
                                  : '—',
                              color: AppColors.navy,
                            ),
                            _StatStripDivider(),
                            _StatStrip(
                              icon: Icons.update_rounded,
                              label: 'Updated',
                              value: _formatTime(
                                  bus.lastUpdate?.millisecondsSinceEpoch),
                              color: AppColors.textSecondary,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1, color: AppColors.divider),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: AppColors.navySurface,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.person_rounded,
                                  color: AppColors.navy, size: 20),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    driverName,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontFamily: AppTextStyles.fontFamily,
                                      fontWeight: FontWeight.w600,
                                      color: driverNameColor,
                                    ),
                                  ),
                                  const Text(
                                    'Bus Driver',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: AppTextStyles.fontFamily,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: AppColors.navySurface,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    bus.trackMode.isGpsDevice
                                        ? Icons.router_rounded
                                        : Icons.phone_android_rounded,
                                    size: 12,
                                    color: AppColors.navy,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    bus.trackMode.isGpsDevice
                                        ? 'GPS Device'
                                        : 'Phone GPS',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontFamily: AppTextStyles.fontFamily,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.navy,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: AppColors.navy, strokeWidth: 2.5),
          SizedBox(height: 16),
          Text(
            'Loading map...',
            style: TextStyle(
                fontFamily: AppTextStyles.fontFamily, color: AppColors.textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String msg) {
    if (widget.busId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.map_outlined, color: AppColors.textMuted, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Could not load map',
                style: TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                msg,
                style: const TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.navy,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Go Back',
                    style: TextStyle(fontFamily: AppTextStyles.fontFamily)),
              ),
            ],
          ),
        ),
      );
    }

    return FutureBuilder<Map<String, dynamic>?>(
      future: LocationCacheService.getLastPosition(widget.busId!),
      builder: (context, snapshot) {
        final cached = snapshot.data;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  cached != null ? Icons.cloud_off_rounded : Icons.map_outlined,
                  color: AppColors.textMuted,
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  cached != null
                      ? 'Offline — last known location'
                      : 'Could not load map',
                  style: const TextStyle(
                    fontFamily: AppTextStyles.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  cached != null
                      ? 'Bus was last seen at ${_formatTime(cached['time'] as int?)}'
                      : msg,
                  style: const TextStyle(
                    fontFamily: AppTextStyles.fontFamily,
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.navy,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Go Back',
                      style: TextStyle(fontFamily: AppTextStyles.fontFamily)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUPPORTING WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _GlassButton extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;
  final double size;
  final bool active;

  const _GlassButton({
    required this.onTap,
    required this.child,
    this.size = 40,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: active
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(size / 2.5),
          border: Border.all(
            color: active
                ? AppColors.green.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.15),
          ),
        ),
        child: Center(child: child),
      ),
    );
  }
}

class _StatStrip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatStrip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontFamily: AppTextStyles.fontFamily,
              fontWeight: FontWeight.w700,
              color:
                  color == AppColors.textSecondary ? AppColors.textSecondary : AppColors.textPrimary,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontFamily: AppTextStyles.fontFamily,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatStripDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 36,
        color: AppColors.divider,
        margin: const EdgeInsets.symmetric(horizontal: 4),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN WRAPPERS
// ─────────────────────────────────────────────────────────────────────────────

class StudentMapScreen extends StatelessWidget {
  final String? busId;
  const StudentMapScreen({super.key, this.busId});
  @override
  Widget build(BuildContext context) => LiveMapScreen(busId: busId);
}

// FIX: Added missing TeacherMapScreen wrapper — was referenced in main.dart
// but never defined, causing the build failure.
// Both roles share the same LiveMapScreen underneath; diverge here later
// if teachers need extra controls (e.g. edit route, force-stop button).
class TeacherMapScreen extends StatelessWidget {
  final String? busId;
  const TeacherMapScreen({super.key, this.busId});
  @override
  Widget build(BuildContext context) => LiveMapScreen(busId: busId);
}

// ─────────────────────────────────────────────────────────────────────────────
// ROUTE ARGUMENTS
// ─────────────────────────────────────────────────────────────────────────────

class MapScreenArgs {
  final String busId;
  final String busName;
  final String route;

  const MapScreenArgs({
    required this.busId,
    this.busName = '',
    this.route = '',
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// LATLNG TWEEN
// ─────────────────────────────────────────────────────────────────────────────

class LatLngTween extends Tween<LatLng> {
  LatLngTween({required LatLng begin, required LatLng end})
      : super(begin: begin, end: end);

  @override
  LatLng lerp(double t) => LatLng(
        begin!.latitude + (end!.latitude - begin!.latitude) * t,
        begin!.longitude + (end!.longitude - begin!.longitude) * t,
      );
}
