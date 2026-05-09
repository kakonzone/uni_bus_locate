// lib/screens/driver/driver_dash_screen.dart
// UniTrack — Driver Dashboard Redesign
// All-in-one dashboard: bus selection, permissions, trip control

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:geocoding/geocoding.dart';
import '../../services/background_service.dart';
import '../../services/firebase_globals.dart';
import '../../providers/tracking_provider.dart';
import '../../providers/bus_providers.dart';
import '../../models/bus_model.dart';
import '../../models/tracking_model.dart';
import '../../providers/location_provider.dart';

// ─── KALMAN FILTER FOR GPS SMOOTHING ─────────────────────────────────────
// Reduces GPS noise using velocity-based filtering
class KalmanFilterGPS {
  double _lat = 0;
  double _lng = 0;
  double _pLat = 1.0; // position uncertainty
  double _pLng = 1.0;

  static const double _q = 0.001; // process noise (movement)

  KalmanFilterGPS(double initLat, double initLng) {
    _lat = initLat;
    _lng = initLng;
  }

  void update(double measLat, double measLng, {double accuracy = 30.0}) {
    // Update process noise based on accuracy
    final q = _q + (accuracy / 100.0).clamp(0, 1);
    final r = (accuracy * 0.5).clamp(15.0, 100.0);

    // Latitude update using Kalman gain
    final pLatOld = _pLat + q;
    final kLat = pLatOld / (pLatOld + r);
    _lat = _lat + kLat * (measLat - _lat);
    _pLat = (1 - kLat) * pLatOld;

    // Longitude update using Kalman gain
    final pLngOld = _pLng + q;
    final kLng = pLngOld / (pLngOld + r);
    _lng = _lng + kLng * (measLng - _lng);
    _pLng = (1 - kLng) * pLngOld;
  }

  LatLng get position => LatLng(_lat, _lng);
  double get latitude => _lat;
  double get longitude => _lng;
}

// ─── Theme Constants ──────────────────────────────────────────────────────
const _navy = Color(0xFF1B2CC1);
const _navyDark = Color(0xFF1221A0);
const _navyLight = Color(0xFF2D3FD4);
const _green = Color(0xFF18C761);
const _amber = Color(0xFFF59E0B);
const _red = Color(0xFFEF4444);
const _surface = Color(0xFFF8F9FF);
const _cardBg = Colors.white;
const _textPrimary = Color(0xFF0F172A);
const _textSecondary = Color(0xFF64748B);
const _textMuted = Color(0xFF94A3B8);
const _divider = Color(0xFFE2E8F0);
const _navyGlow = Color(0xFFE8EAFB);

// FIX 1: Add missing speed limit constant
const kSpeedLimitKmh = 60.0;

// NOTE: `TripPersistenceKeys` is defined in `tracking_provider.dart` (already
// imported above) and is the single source of truth for all trip-persistence
// SharedPreferences keys (`busId`, `tripStartMs`, `destLat`, `tripActive`,
// etc.). The local duplicate that previously lived here has been removed to
// avoid an incomplete redefinition.

// ─── MAIN SCREEN ─────────────────────────────────────────────────────────────

class DriverDashScreen extends ConsumerStatefulWidget {
  const DriverDashScreen({super.key});

  @override
  ConsumerState<DriverDashScreen> createState() => _DriverDashScreenState();
}

class _DriverDashScreenState extends ConsumerState<DriverDashScreen>
    with TickerProviderStateMixin {
  // ─── Animation Controllers ────────────────────────────────────────────────
  late AnimationController _pulseController;
  late AnimationController _slideController;
  late Animation<double> _pulseAnim;
  late Animation<Offset> _slideAnim;

  // ─── State Fields ────────────────────────────────────────────────────────
  String? _selectedBusId;
  String _searchQuery = '';
  bool _isMiui = false;
  bool _isSamsung = false;
  bool _batteryWarningDismissed = false;
  bool _bgTripActive = false;
  // STATE FIELD ADDITIONS
  String _currentPlaceName = '';
  BitmapDescriptor? _cachedMarkerIcon;
  // BUG 3 FIX: Add loading state for starting a trip
  bool _isStartingTrip = false;
  // CRITICAL BUG #3 FIX: Add loading state for stopping a trip (double-tap guard)
  bool _isStoppingTrip = false;
  // WARNING BUG #5 FIX: Hard guarantee against setState after dispose across async gaps
  bool _disposed = false;
  // PERF FIX: Debounce geocoding to reduce network calls
  DateTime? _lastGeocodingTime;
  // WARNING BUG #6 FIX: LRU-capped polyline cache to prevent unbounded memory growth
  static const _kMaxCacheSize = 5;
  final Map<String, List<LatLng>> _polylineCache =
      LinkedHashMap<String, List<LatLng>>();
  // FIX 8: Store trip running state for safe access in dispose()
  bool _isTripRunning = false;

  // ─── Feature 1: Firebase Connection Status ───────────────────────────────
  bool _isFirebaseConnected = false;
  StreamSubscription<DatabaseEvent>? _firebaseConnSub;
  Timer?
      _firebaseConnDebounce; // FIX: Debounce timer to ignore momentary disconnects

  // ─── Feature 3: Offline Mode ─────────────────────────────────────────────
  bool _isOffline = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  // ─── Feature 4: Route Deviation ──────────────────────────────────────────
  bool _isRouteDeviated = false;
  List<LatLng> _routePolyline = [];

  // ─── Google Map ──────────────────────────────────────────────────────────
  GoogleMapController? _mapController;

  // ─── GPS Filtering ────────────────────────────────────────
  KalmanFilterGPS? _kalmanFilter;
  bool _useKalmanFilter = true;
  // BUG FIX: Animation throttle to prevent unbounded queue
  DateTime? _lastCameraAnimTime;
  // FIX 4: Add state field for filtered position
  LatLng? _filteredPosition;

  // ─── Text Editing ────────────────────────────────────────────────────────
  final _searchCtrl = TextEditingController();
  @override
  void initState() {
    super.initState();

    // ── Animation Init ────────────────────────────────────────────────────
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOut));
    _slideController.forward();

    // ── Clock Timer ───────────────────────────────────────────────────────
    // PERF BUG #8 FIX: Clock moved to its own _LiveClock StatefulWidget so the
    // 1-second tick no longer rebuilds the entire dashboard.

    // BUG FIX 2: Await async init tasks properly after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initAsync();
    });

    // ── Listeners ────────────────────────────────────────────────────────
    _firebaseConnSub = globalDB.ref('.info/connected').onValue.listen((event) {
      final connected = event.snapshot.value as bool? ?? false;

      if (connected) {
        // Connected: show green immediately
        _firebaseConnDebounce?.cancel();
        if (mounted) setState(() => _isFirebaseConnected = true);
      } else {
        // Disconnected: wait 6 seconds before showing red (ignore momentary drops)
        _firebaseConnDebounce?.cancel();
        _firebaseConnDebounce = Timer(const Duration(seconds: 6), () {
          if (mounted) setState(() => _isFirebaseConnected = false);
        });
      }
    });

    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (!mounted) return;
      final offline =
          results.isEmpty || results.every((r) => r == ConnectivityResult.none);
      setState(() => _isOffline = offline);
    });

    // WARNING BUG #7 FIX: Kalman filter is now lazily initialized on first GPS
    // fix in the ref.listen<LiveLocationState> callback (see build()), so
    // drivers far from Dhaka don't see a lagging filtered position.
  }

  // FIX 1: New _initMarker() method - one-time initialization for static marker icon
  Future<void> _initMarker() async {
    const double size = 60;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2,
      Paint()..color = const Color(0xFF1B2CC1).withOpacity(0.18),
    );
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2.8,
      Paint()..color = const Color(0xFF1B2CC1),
    );
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2.8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (mounted) {
      setState(() {
        _cachedMarkerIcon =
            BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
      });
    }
  }

  // FIX 2: New method for instant location on trip start
  void _getImmediatePosition() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 4));
      if (!mounted) return;
      // WARNING BUG #7 FIX: Removed Kalman re-init here. The filter is lazily
      // initialized on the first real GPS fix in the ref.listen callback so
      // it always seeds with the driver's actual location, not Dhaka.
      setState(() {
        _filteredPosition = LatLng(pos.latitude, pos.longitude);
      });
      _mapController?.animateCamera(
        CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)),
      );
    } catch (e) {
      debugPrint('UniTrack: Immediate position failed (non-fatal) → $e');
    }
  }

  // FIX 6: Updated _initAsync() call order with _initMarker() as FIRST call
  Future<void> _initAsync() async {
    await _initMarker(); // ← ADD THIS FIRST
    if (mounted) {
      setState(() {}); // remove old _markerFuture init if present
    }
    await _loadSavedBusSelection();
    await _loadResumeState();
    await _requestPermissionsOnce();
    await _detectDevice();
    await _autoResumeIfNeeded();
  }

  @override
  void dispose() {
    // WARNING BUG #5 FIX: Mark disposed BEFORE tearing things down so any
    // in-flight async (e.g. _updatePlaceName geocoding) cannot setState.
    _disposed = true;
    _pulseController.dispose();
    _slideController.dispose();
    // PERF BUG #8 FIX: _clockTimer no longer lives on this state.
    _mapController?.dispose();
    _searchCtrl.dispose();
    _firebaseConnSub?.cancel();
    _firebaseConnDebounce?.cancel(); // FIX: Cancel debounce timer on dispose
    _connectivitySub?.cancel();
    // FIX 8: Read local state field instead of provider in dispose()
    if (!_isTripRunning) WakelockPlus.disable();
    super.dispose();
  }

  // ─── STATE & RESUME LOGIC ─────────────────────────────────────────────────═

  Future<void> _loadResumeState() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _bgTripActive =
          prefs.getBool(TripPersistenceKeys.tripActive) ?? false);
    }
  }

  Future<void> _autoResumeIfNeeded() async {
    // PERF FIX: Skip hasSavedTrip check and try to load directly
    final trip = await BackgroundService.loadSavedTrip();
    if (trip.isEmpty || !mounted) {
      // WARNING BUG #4 FIX: Clear stale resume banner + persistence so a
      // failed/empty resume doesn't leave _bgTripActive=true forever.
      if (mounted) setState(() => _bgTripActive = false);
      try {
        await BackgroundService().stopAndClear();
      } catch (e) {
        debugPrint(
            'UniTrack: stopAndClear after empty trip failed (non-fatal) → $e');
      }
      return;
    }

    final savedBusId = trip['busId'] as String? ?? '';
    final busName = trip['busName'] as String? ?? 'Bus';
    final busRoute = trip['busRoute'] as String? ?? '';
    final startTime = trip['startTime'] as DateTime?;

    if (savedBusId.isEmpty || !mounted) {
      // WARNING BUG #4 FIX: Same cleanup if busId missing — wipe the stale
      // SharedPreferences state and drop the resume banner.
      if (mounted) setState(() => _bgTripActive = false);
      try {
        await BackgroundService().stopAndClear();
      } catch (e) {
        debugPrint(
            'UniTrack: stopAndClear after empty busId failed (non-fatal) → $e');
      }
      return;
    }

    setState(() {
      _selectedBusId = savedBusId;
      _bgTripActive = true;
    });
    ref.read(selectedBusIdProvider.notifier).state = savedBusId;

    if (!mounted) return;

    final mode =
        ref.read(trackingModeProvider).valueOrNull ?? TrackingMode.active;
    ref
        .read(liveLocationProvider.notifier)
        .startListening(mode, busId: savedBusId);
    ref.read(tripStatusProvider.notifier).state = TripStatus.running;

    if (startTime != null) {
      ref.read(tripStartTimeProvider.notifier).state = startTime;
    }
    WakelockPlus.enable();

    // PERF FIX: Always restart service on resume (simpler than checking isRunning)
    // BUG D-3 FIX: BackgroundService is non-fatal, wrapped in try/catch
    try {
      await BackgroundService().startAndSave(
        busId: savedBusId,
        busName: busName,
        busRoute: busRoute,
        startTime: startTime,
      );
    } catch (e) {
      debugPrint('UniTrack: BackgroundService resume failed (non-fatal) → $e');
    }

    debugPrint('UniTrack: ✅ Auto-resumed trip for $savedBusId');
  }

  // ─── PERMISSIONS & SETUP ───────────────────────────────────────────────────

  Future<void> _requestPermissionsOnce() async {
    final prefs = await SharedPreferences.getInstance();

    if (!(prefs.getBool('perm_location_asked') ?? false)) {
      final locStatus = await Permission.locationAlways.status;
      if (!locStatus.isGranted) {
        final whenInUse = await Permission.locationWhenInUse.request();
        if (whenInUse.isGranted) {
          if (Platform.isAndroid) {
            final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
            if (sdk >= 30) {
              await _showLocationAlwaysDialog();
              await openAppSettings();
            } else {
              await Permission.locationAlways.request();
            }
          } else {
            await Permission.locationAlways.request();
          }
        }
      }
      await prefs.setBool('perm_location_asked', true);
    }

    if (!(prefs.getBool('perm_notification_asked') ?? false)) {
      await Permission.notification.request();
      await prefs.setBool('perm_notification_asked', true);
    }

    if (!(prefs.getBool('perm_battery_asked') ?? false)) {
      await Permission.ignoreBatteryOptimizations.request();
      await prefs.setBool('perm_battery_asked', true);
    }
  }

  Future<void> _showLocationAlwaysDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.location_on_rounded, color: _navy, size: 22),
            SizedBox(width: 8),
            Text(
              'Location সেট করুন',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: _textPrimary,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'App Settings খুলবে। নিচের steps follow করুন:',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 13.5,
                color: _textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            _dialogStep('১', 'Location tap করো'),
            _dialogStep('২', '"Allow all the time" select করো'),
            _dialogStep('৩', 'Back দিয়ে ফিরে এসো'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'বুঝেছি, Settings খুলুন',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontWeight: FontWeight.w700,
                color: _navy,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dialogStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _navy.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  fontFamily: 'DMSans',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _navy,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: 'DMSans',
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: _textPrimary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _detectDevice() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final manufacturer = info.manufacturer.toLowerCase();
      if (mounted) {
        setState(() {
          _isMiui = manufacturer.contains('xiaomi') ||
              manufacturer.contains('redmi') ||
              manufacturer.contains('poco');
          _isSamsung = manufacturer.contains('samsung');
        });
      }
    } catch (_) {}
  }

  // ─── BUS SELECTION & ROUTE LOGIC ──────────────────────────────────────────

  Future<void> _loadSavedBusSelection() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('driver_selected_bus_id');
    final dismissed = prefs.getBool('battery_warning_dismissed') ?? false;
    if (mounted) {
      setState(() {
        if (saved != null) _selectedBusId = saved;
        _batteryWarningDismissed = dismissed;
      });
    }
  }

  Future<void> _saveSelection(BusModel bus) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_selected_bus_id', bus.id);
    await prefs.setString('driver_selected_bus_name', bus.name);
    await prefs.setString('driver_selected_bus_route', bus.route);
  }

  // BUG D-1 FIX: Make _onBusSelected async and await _saveSelection
  Future<void> _onBusSelected(BusModel bus) async {
    final isRunning = ref.read(tripStatusProvider) == TripStatus.running;
    if (isRunning) return;
    setState(() => _selectedBusId = bus.id);
    // BUG D-1 FIX: Await _saveSelection to ensure SharedPreferences is updated
    await _saveSelection(bus);
    ref.read(selectedBusIdProvider.notifier).state = bus.id;
    _loadRoutePolyline(bus.id);
  }

  Future<void> _loadRoutePolyline(String busId) async {
    // PERF FIX: Check cache first before Firebase read
    if (_polylineCache.containsKey(busId)) {
      if (mounted) setState(() => _routePolyline = _polylineCache[busId]!);
      return;
    }

    try {
      final snapshot = await globalDB.ref('buses/$busId/route_polyline').get();
      if (!snapshot.exists) {
        if (mounted) setState(() => _routePolyline = []);
        _polylineCache[busId] = []; // Cache empty result
        return;
      }
      final raw = snapshot.value;
      final List<LatLng> points = [];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final lat = (item['lat'] ?? item['latitude']) as num?;
            final lng =
                (item['lng'] ?? item['longitude'] ?? item['lon']) as num?;
            // BUG FIX #3: Safe type checking to prevent ClassCastException
            if (lat is! num || lng is! num) continue;
            points.add(LatLng(lat.toDouble(), lng.toDouble()));
          }
        }
      }
      _polylineCache[busId] = points; // Cache the result
      // WARNING BUG #6 FIX: Cap cache size — evict oldest (LinkedHashMap
      // preserves insertion order so .keys.first is the oldest entry).
      if (_polylineCache.length > _kMaxCacheSize) {
        _polylineCache.remove(_polylineCache.keys.first);
      }
      if (mounted) setState(() => _routePolyline = points);
      debugPrint(
          'UniTrack: Loaded ${points.length} route polyline points for $busId');
    } catch (e) {
      debugPrint('UniTrack: Failed to load route polyline → $e');
      if (mounted) setState(() => _routePolyline = []);
    }
  }

  double _distanceToPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) return 0;
    double minDist = double.infinity;
    for (final p in polyline) {
      final d = Geolocator.distanceBetween(
        point.latitude,
        point.longitude,
        p.latitude,
        p.longitude,
      );
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  Future<void> _updatePlaceName(double lat, double lng) async {
    // PERF FIX: Debounce geocoding to reduce network calls (max once per 30s)
    final now = DateTime.now();
    if (_lastGeocodingTime != null &&
        now.difference(_lastGeocodingTime!).inSeconds < 30) {
      return; // Skip if last geocoding was less than 30 seconds ago
    }

    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      // WARNING BUG #5 FIX: Hard guard against setState after dispose. The
      // `_disposed` flag is flipped synchronously at the very top of dispose()
      // so it covers async gaps that `mounted` may slip through.
      if (placemarks.isNotEmpty && mounted && !_disposed) {
        // FIX 9: Move time update to only happen on success
        _lastGeocodingTime = now;
        final p = placemarks.first;
        final parts = [p.name, p.subLocality, p.locality]
            .where((s) => s != null && s.isNotEmpty)
            .toList();
        setState(() => _currentPlaceName = parts.join(', '));
      }
    } catch (e) {
      // BUG FIX #6: Handle geocoding errors gracefully
      debugPrint('UniTrack: Geocoding error for ($lat, $lng) → $e');
    }
  }

  // ─── TRIP CONTROL ────────────────────────────────────────────────────────

  Future<void> _startTrip() async {
    // BUG 1 FIX: Check for locationAlways permission before starting
    final locStatus = await Permission.locationAlways.status;
    // MINOR BUG #9 FIX: Guard ScaffoldMessenger.of(context) against the case
    // where the widget unmounts during the permission status await.
    if (!mounted) return;
    if (!locStatus.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please grant "Allow all the time" location permission in settings.',
          ),
          backgroundColor: _red,
          action: SnackBarAction(
            label: 'SETTINGS',
            textColor: Colors.white,
            onPressed: openAppSettings,
          ),
        ),
      );
      return;
    }

    // CRITICAL BUG #1 FIX: Persist the selected bus to SharedPreferences BEFORE
    // we start the trip. _onBusSelected() awaits _saveSelection() but
    // _startTrip() previously did not, so if the app was killed mid-trip
    // _autoResumeIfNeeded() would read an empty busId and silently abandon
    // resume. We resolve the selected bus from busListProvider here and save
    // it; if no bus is selected/found we bail out with a SnackBar.
    final buses = ref.read(busListProvider).valueOrNull ?? [];
    final selectedBus = buses.where((b) => b.id == _selectedBusId).firstOrNull;
    if (selectedBus == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a bus before starting the trip.'),
          backgroundColor: _red,
        ),
      );
      return;
    }
    await _saveSelection(selectedBus);
    if (!mounted) return;

    // BUG 3 FIX: Prevent UI lag and handle loading state
    if (_isStartingTrip) return; // Prevent double taps
    if (mounted) setState(() => _isStartingTrip = true);

    try {
      HapticFeedback.mediumImpact();

      // Immediately update providers and state for quick UI feedback
      final startTime = DateTime.now();
      ref.read(tripStatusProvider.notifier).state = TripStatus.running;
      ref.read(tripStartTimeProvider.notifier).state = startTime;
      WakelockPlus.enable();

      // FIX 3: Sync `_isTripRunning` synchronously here (not only in build()).
      // If `dispose()` runs before the next build (e.g. widget removed before
      // the first frame after starting), the wakelock-disable check in
      // `dispose()` must still see the correct running state.
      _isTripRunning = true;

      if (mounted) setState(() => _bgTripActive = true);

      // FIX 2: Get immediate position before starting listening
      unawaited(Future(() => _getImmediatePosition()));

      // BUG D-2 FIX: Pass busId to startListening and always use TrackingMode.active
      // liveLocationProvider is the PRIMARY GPS source (drives UI stats and Firebase writes)
      unawaited(ref.read(liveLocationProvider.notifier).startListening(
            TrackingMode.active,
            busId: selectedBus.id,
          ));

      // BUG D-3 FIX: BackgroundService is non-fatal (background persistence only)
      // Wrapped in try/catch - it handles app-killed scenarios
      // Intentional split: liveLocationProvider = UI/Firebase writes, BackgroundService = persistence
      unawaited(
        BackgroundService()
            .startAndSave(
          busId: selectedBus.id,
          busName: selectedBus.name,
          busRoute: selectedBus.route,
          startTime: startTime,
        )
            .catchError((e) {
          debugPrint(
              'UniTrack: BackgroundService start failed (non-fatal) → $e');
          return false;
        }),
      );
    } catch (e) {
      debugPrint("UniTrack: Error starting trip: $e");
      // Revert state on error
      ref.read(tripStatusProvider.notifier).state = TripStatus.idle;
      ref.read(tripStartTimeProvider.notifier).state = null;
      WakelockPlus.disable();
      // FIX 3: Keep local running flag in sync with the reverted state.
      _isTripRunning = false;
      if (mounted) setState(() => _bgTripActive = false);
    } finally {
      // Reset loading state. The UI will have already changed to "End Trip"
      // if successful, but this handles failures and is good practice.
      if (mounted) setState(() => _isStartingTrip = false);
    }
  }

  Future<void> _stopTrip() async {
    // CRITICAL BUG #3 FIX: Guard against double-tap. Without this a fast
    // double-tap on "End Trip" shows the confirm dialog twice and calls
    // stopAndClear() twice, crashing the providers.
    if (_isStoppingTrip) return;
    if (mounted) setState(() => _isStoppingTrip = true);

    try {
      final confirm = await _showStopDialog();
      if (!confirm) return;
      if (!mounted) return;
      HapticFeedback.heavyImpact();

      final locState = ref.read(liveLocationProvider);
      ref.read(liveLocationProvider.notifier).stopListening();
      ref.read(tripStatusProvider.notifier).state = TripStatus.idle;

      final startTime = ref.read(tripStartTimeProvider);
      ref.read(tripStartTimeProvider.notifier).state = null;
      WakelockPlus.disable();

      // FIX 3: Sync `_isTripRunning` synchronously here so a `dispose()` that
      // races with stop sees the correct value without depending on the next
      // build cycle.
      _isTripRunning = false;

      // Stops foreground service AND clears SharedPreferences state
      await BackgroundService().stopAndClear();

      if (mounted) {
        setState(() {
          _bgTripActive = false;
          _searchQuery = '';
          _isRouteDeviated = false;
          _currentPlaceName = '';
          // FIX 4: Clear polylineCache and filteredPosition in _stopTrip()
          _polylineCache.clear();
          _filteredPosition = null;
        });
      }
      _searchCtrl.clear();

      if (mounted && startTime != null) {
        _showTripSummary(locState, startTime);
      }
    } finally {
      // CRITICAL BUG #3 FIX: Always release the guard so the user can retry
      // (e.g. they tapped Cancel in the confirm dialog).
      if (mounted) setState(() => _isStoppingTrip = false);
    }
  }

  Future<bool> _showStopDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text(
              'End Trip?',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontWeight: FontWeight.w700,
                color: _navy,
              ),
            ),
            content: const Text(
              'This will stop GPS tracking and end the current trip.',
              style: TextStyle(fontFamily: 'DMSans'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(fontFamily: 'DMSans', color: Colors.grey),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _red,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'End Trip',
                  style: TextStyle(fontFamily: 'DMSans', color: Colors.white),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showTripSummary(LiveLocationState locState, DateTime startTime) {
    final duration = DateTime.now().difference(startTime);
    final h = duration.inHours.toString().padLeft(2, '0');
    final m = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final s = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final durationStr = duration.inHours > 0 ? '$h:$m:$s' : '$m:$s';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.flag_rounded, color: _navy),
            SizedBox(width: 8),
            Text(
              'Trip Summary',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontWeight: FontWeight.w700,
                color: _navy,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SummaryRow(
              icon: Icons.straighten_rounded,
              label: 'Total Distance',
              value: _formatDistance(locState.totalDistanceM),
              color: _green,
            ),
            const SizedBox(height: 12),
            _SummaryRow(
              icon: Icons.timer_rounded,
              label: 'Trip Duration',
              value: durationStr,
              color: _navy,
            ),
            const SizedBox(height: 12),
            _SummaryRow(
              icon: Icons.gps_fixed_rounded,
              label: 'GPS Pings',
              value: '${locState.totalUpdates}',
              color: const Color(0xFF8B5CF6),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _navy,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Done',
              style: TextStyle(fontFamily: 'DMSans', color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────────

  String _formatSpeed(double? mps) {
    if (mps == null) return '-- km/h';
    return '${(mps * 3.6).toStringAsFixed(1)} km/h';
  }

  String _formatCoord(double? v, {bool isLat = true}) {
    if (v == null) return '--°';
    final dir = isLat ? (v >= 0 ? 'N' : 'S') : (v >= 0 ? 'E' : 'W');
    return '${v.abs().toStringAsFixed(5)}° $dir';
  }

  String _formatDistance(double m) {
    if (m < 1000) return '${m.toStringAsFixed(0)} m';
    return '${(m / 1000).toStringAsFixed(2)} km';
  }

  String _formatUptime(DateTime? startTime) {
    if (startTime == null) return '--:--';
    final diff = DateTime.now().difference(startTime);
    final h = diff.inHours.toString().padLeft(2, '0');
    final m = (diff.inMinutes % 60).toString().padLeft(2, '0');
    final s = (diff.inSeconds % 60).toString().padLeft(2, '0');
    return diff.inHours > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _modeLabel(TrackingMode mode) {
    switch (mode) {
      case TrackingMode.active:
        return 'ACTIVE';
      case TrackingMode.lowPower:
        return 'LOW POWER';
      case TrackingMode.sleep:
        return 'SLEEP MODE';
    }
  }

  Color _modeColor(TrackingMode mode) {
    switch (mode) {
      case TrackingMode.active:
        return _green;
      case TrackingMode.lowPower:
        return _amber;
      case TrackingMode.sleep:
        return Colors.blueGrey;
    }
  }

  String _modeDescription(TrackingMode mode) {
    switch (mode) {
      case TrackingMode.active:
        return 'GPS updates every 5 sec  •  7 AM – 6 PM';
      case TrackingMode.lowPower:
        return 'GPS updates every 60 sec  •  6 PM – 10 PM';
      case TrackingMode.sleep:
        return 'GPS paused to save battery  •  10 PM – 7 AM';
    }
  }

  IconData _modeIcon(TrackingMode mode) {
    switch (mode) {
      case TrackingMode.active:
        return Icons.gps_fixed_rounded;
      case TrackingMode.lowPower:
        return Icons.battery_saver_rounded;
      case TrackingMode.sleep:
        return Icons.bedtime_rounded;
    }
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 5) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    return '${diff.inMinutes}m ago';
  }

  List<BusModel> _filtered(List<BusModel> all) {
    if (_searchQuery.isEmpty) return all;
    final q = _searchQuery.toLowerCase();
    return all.where((b) {
      return b.name.toLowerCase().contains(q) ||
          b.route.toLowerCase().contains(q) ||
          (b.driverName?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  // ─── BUILD ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mode =
        ref.watch(trackingModeProvider).valueOrNull ?? TrackingMode.active;
    final tripStatus = ref.watch(tripStatusProvider);
    final locState = ref.watch(liveLocationProvider);
    final isRunning = tripStatus == TripStatus.running;
    final tripStartTime = ref.watch(tripStartTimeProvider);

    // FIX 8: Sync running state for safe access in dispose()
    _isTripRunning = isRunning;

    // ── LISTENERS ──────────────────────────────────────────────────────────
    // FIX 3: Clean up ref.listen - removed heading-related code
    ref.listen<LiveLocationState>(liveLocationProvider, (prev, next) {
      if (next.position != null) {
        // CRITICAL BUG #2 FIX: Check `mounted && _mapController != null` BEFORE
        // calling animateCamera. Previously the code threw a platform
        // exception when a GPS update arrived after the widget disposed.
        if (_mapController != null && mounted) {
          final now = DateTime.now();
          if (_lastCameraAnimTime == null ||
              now.difference(_lastCameraAnimTime!).inSeconds >= 5) {
            _mapController!.animateCamera(
              CameraUpdate.newLatLng(
                LatLng(next.position!.latitude, next.position!.longitude),
              ),
            );
            _lastCameraAnimTime = now;
          }
        }

        // PERF FIX: Batch state updates into single setState call
        bool? newRouteDeviated;
        LatLng? newFilteredPosition;

        // WARNING BUG #7 FIX: Lazily initialize the Kalman filter on the
        // first real GPS fix so drivers far from Dhaka don't see a lagging
        // filtered position for the first several pings.
        if (_kalmanFilter == null) {
          _kalmanFilter = KalmanFilterGPS(
            next.position!.latitude,
            next.position!.longitude,
          );
          newFilteredPosition = _kalmanFilter!.position;
        } else {
          _kalmanFilter!.update(
            next.position!.latitude,
            next.position!.longitude,
            accuracy: next.position!.accuracy,
          );
          newFilteredPosition = _kalmanFilter!.position;
        }

        // Check route deviation
        if (_routePolyline.isNotEmpty) {
          final currentPos = LatLng(
            next.position!.latitude,
            next.position!.longitude,
          );
          final distToRoute = _distanceToPolyline(currentPos, _routePolyline);
          if (!_isRouteDeviated && distToRoute > 200) {
            newRouteDeviated = true;
            debugPrint(
                'UniTrack: Route deviation detected — ${distToRoute.toStringAsFixed(1)}m from route');
          } else if (_isRouteDeviated && distToRoute <= 150) {
            newRouteDeviated = false;
            debugPrint(
                'UniTrack: Back on route — ${distToRoute.toStringAsFixed(1)}m from route');
          }
        }

        // Trigger geocoding (async, non-blocking)
        _updatePlaceName(next.position!.latitude, next.position!.longitude);

        // FIX 3: Updated setState condition - only handle position and deviation
        if ((newFilteredPosition != null || newRouteDeviated != null) &&
            mounted) {
          setState(() {
            if (newFilteredPosition != null)
              _filteredPosition = newFilteredPosition;
            if (newRouteDeviated != null) _isRouteDeviated = newRouteDeviated;
          });
        }
      }
    });

    // BUG T-4 FIX: Add guards to trackingModeProvider listener to prevent unnecessary restarts
    ref.listen<AsyncValue<TrackingMode>>(trackingModeProvider, (prev, next) {
      // Guard: Don't restart if mode hasn't changed
      if (prev?.valueOrNull == next.valueOrNull) return;
      final running = ref.read(tripStatusProvider) == TripStatus.running;
      // Guard: Only restart if trip is running
      if (!running) return;
      // BUG T-4 FIX: Pass busId when calling startListening on mode change
      final trackingMode = next.valueOrNull ?? TrackingMode.active;
      // FIX 5: `startListening` requires a non-null busId to write to the
      // correct Firebase node. If the bus selection was cleared mid-trip we
      // must not call it with `busId: null` — log a warning and skip.
      final busId = _selectedBusId;
      if (busId == null) {
        debugPrint(
          'UniTrack: trackingMode changed to $trackingMode but '
          '_selectedBusId is null — skipping startListening().',
        );
        return;
      }
      ref.read(liveLocationProvider.notifier).startListening(
            trackingMode,
            busId: busId,
          );
    });

    // ─── UI ──────────────────────────────────────────────────────────────────
    return Scaffold(
      backgroundColor: _surface,
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 220,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [_navyDark, _navyLight],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(32),
                  bottomRight: Radius.circular(32),
                ),
              ),
            ),
          ),
          SafeArea(
            child: SlideTransition(
              position: _slideAnim,
              child: Column(
                children: [
                  _buildTopBar(isRunning),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: Column(
                        children: [
                          const SizedBox(height: 12),
                          if (_isOffline) ...[
                            _buildOfflineBanner(),
                            const SizedBox(height: 12),
                          ],
                          if (_isMiui || _isSamsung) ...[
                            _buildOemWarning(),
                            const SizedBox(height: 12),
                          ],
                          _buildResumeBanner(isRunning),
                          if (!_batteryWarningDismissed) ...[
                            _buildBatteryWarning(),
                            const SizedBox(height: 12),
                          ],
                          _buildSpeedWarning(locState.position?.speed),
                          if (_isRouteDeviated) ...[
                            _buildRouteDeviationWarning(),
                          ],
                          if (!isRunning) _buildBusListSection(),
                          if (isRunning) _buildSelectedBusSummary(),
                          const SizedBox(height: 16),
                          _buildModeCard(mode),
                          if (isRunning) ...[
                            const SizedBox(height: 16),
                            _buildMiniMap(locState.position),
                          ],
                          const SizedBox(height: 16),
                          _buildGpsStatsCard(locState, isRunning),
                          if (isRunning) ...[
                            const SizedBox(height: 16),
                            _buildTripMetrics(locState, tripStartTime),
                          ],
                          const SizedBox(height: 16),
                          _buildTripButton(isRunning),
                          const SizedBox(height: 8),
                          _buildServiceNote(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── TOP BAR ─────────────────────────────────────────────────────────────

  Widget _buildTopBar(bool isRunning) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          // Feature 1: Firebase connection dot next to title
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text(
                    'UniTrack',
                    style: TextStyle(
                      fontFamily: 'DMSans',
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: _isFirebaseConnected
                        ? 'Firebase: Connected'
                        : 'Firebase: Disconnected',
                    triggerMode: TooltipTriggerMode.longPress,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isFirebaseConnected ? _green : _red,
                        boxShadow: [
                          BoxShadow(
                            color: (_isFirebaseConnected ? _green : _red)
                                .withOpacity(0.5),
                            blurRadius: 4,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const Text(
                'Driver Dashboard',
                style: TextStyle(
                  fontFamily: 'DMSans',
                  fontSize: 12,
                  color: Colors.white60,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const Spacer(),
          // PERF BUG #8 FIX: Clock extracted into its own StatefulWidget so
          // the 1s tick no longer rebuilds the entire dashboard.
          const _LiveClock(),
          const SizedBox(width: 8),
          // Feature 2: GPS Live Location Display (only when trip is running)
          if (isRunning) ...[
            GestureDetector(
              onTap: () {
                // Show current GPS coordinates instead of hardware setup screen
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Live GPS tracking active - check map for location'),
                    backgroundColor: Colors.green,
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(
                  Icons.gps_fixed_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          GestureDetector(
            onTap: () => _showLogoutDialog(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24),
              ),
              child: const Icon(
                Icons.person_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── BANNERS & WARNINGS ─────────────────────────────────────────────────

  Widget _buildOfflineBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _red,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        children: [
          Icon(Icons.wifi_off_rounded, color: Colors.white, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'No internet connection — showing cached data',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteDeviationWarning() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _red.withOpacity(0.4)),
        ),
        child: const Row(
          children: [
            Icon(Icons.route_outlined, color: _red, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Off route — you are more than 200m from the assigned route.',
                style: TextStyle(
                  fontFamily: 'DMSans',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF991B1B),
                ),
              ),
            ), // ← Expanded বন্ধ
          ], // ← children: [ বন্ধ
        ), // ← Row বন্ধ
      ), // ← Container বন্ধ
    ); // ← Padding বন্ধ
  }

  Widget _buildOemWarning() {
    final brand = _isMiui ? 'Xiaomi / MIUI' : 'Samsung One UI';
    final extraStep = _isMiui
        ? 'Also enable "Autostart" in Security app → Manage Apps → UniTrack.'
        : 'Also set "Sleeping apps" to never put UniTrack to sleep.';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _amber.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: _amber, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$brand Detected',
                  style: const TextStyle(
                    fontFamily: 'DMSans',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF7B4F00),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$extraStep Grant all permissions for uninterrupted tracking.',
                  style: const TextStyle(
                    fontFamily: 'DMSans',
                    fontSize: 12,
                    color: Color(0xFF7B4F00),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBatteryWarning() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _amber.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.battery_alert_rounded, color: _amber, size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Disable battery optimization for UniTrack to keep tracking running in background.',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 12,
                color: Color(0xFF92400E),
              ),
            ),
          ),
          GestureDetector(
            onTap: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('battery_warning_dismissed', true);
              if (mounted) {
                setState(() => _batteryWarningDismissed = true);
              }
            },
            child: const Icon(Icons.close_rounded, size: 16, color: _amber),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedWarning(double? speedMs) {
    if (speedMs == null) return const SizedBox.shrink();
    final kmh = speedMs * 3.6;
    if (kmh <= kSpeedLimitKmh) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _red.withOpacity(0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.speed_rounded, color: _red, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Speed alert: ${kmh.toStringAsFixed(1)} km/h — limit is ${kSpeedLimitKmh.toInt()} km/h',
                style: const TextStyle(
                  fontFamily: 'DMSans',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF991B1B),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResumeBanner(bool isRunning) {
    if (isRunning || !_bgTripActive) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _amber.withOpacity(0.5)),
        ),
        child: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: _amber, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'A trip is still running in the background. Tap Start Trip to resume tracking.',
                style: TextStyle(
                  fontFamily: 'DMSans',
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF92400E),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── BUS LIST & SUMMARY ──────────────────────────────────────────────────

  Widget _buildBusListSection() {
    final busListAsync = ref.watch(busListProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Select Your Bus',
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _textPrimary,
            ),
          ),
        ),
        _buildSearchBar(),
        const SizedBox(height: 8),
        busListAsync.when(
          loading: () => _buildLoading(),
          error: (e, _) => _buildError(e),
          data: (buses) {
            final filtered = _filtered(buses);
            final active = filtered.where((b) => b.active).toList();
            final inactive = filtered.where((b) => !b.active).toList();

            if (filtered.isEmpty) {
              return _buildEmptyState();
            }

            return Column(children: [
              if (active.isNotEmpty) ...[
                _SectionLabel(label: 'Active Routes', count: active.length),
                const SizedBox(height: 8),
                ...active.map((b) => _BusCard(
                      bus: b,
                      isSelected: _selectedBusId == b.id,
                      onTap: () => _onBusSelected(b),
                    )),
              ],
              if (inactive.isNotEmpty) ...[
                const SizedBox(height: 16),
                _SectionLabel(label: 'Inactive Routes', count: inactive.length),
                const SizedBox(height: 8),
                ...inactive.map((b) => _BusCard(
                      bus: b,
                      isSelected: _selectedBusId == b.id,
                      onTap: () => _onBusSelected(b),
                      dimmed: true,
                    )),
              ],
            ]);
          },
        ),
      ],
    );
  }

  Widget _buildSelectedBusSummary() {
    final busListAsync = ref.watch(busListProvider);
    return busListAsync.when(
      loading: () => _shimmerCard(height: 100),
      error: (_, __) => _buildBusCardSimple('Bus 01', 'Campus → City'),
      data: (buses) {
        BusModel? selected;
        if (_selectedBusId != null) {
          try {
            selected = buses.firstWhere((b) => b.id == _selectedBusId);
          } catch (_) {}
        }
        return _buildBusCardSimple(
          selected?.name ?? 'Bus 01',
          selected?.route ?? 'Campus → City',
        );
      },
    );
  }

  Widget _buildBusCardSimple(String name, String route) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _navy.withOpacity(0.10),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: _navy.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.directions_bus_rounded,
              color: _navy,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: 'DMSans',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(Icons.route_rounded,
                        size: 13, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      route,
                      style: const TextStyle(
                        fontFamily: 'DMSans',
                        fontSize: 13,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, __) => Opacity(
              opacity: _pulseAnim.value,
              child: const _StatusBadge(
                label: 'LIVE',
                color: _green,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── SEARCH & STATE WIDGETS ────────────────────────────────────────────────

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _divider, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _searchQuery = v),
        style: const TextStyle(
          fontFamily: 'DMSans',
          fontSize: 15,
          color: _textPrimary,
        ),
        decoration: InputDecoration(
          hintText: 'Search by bus name or route…',
          hintStyle: const TextStyle(
            fontFamily: 'DMSans',
            fontSize: 15,
            color: _textMuted,
          ),
          prefixIcon: const Icon(
            Icons.search_rounded,
            color: _textMuted,
            size: 20,
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: _textMuted,
                    size: 18,
                  ),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Column(
      children: [
        const Row(
          children: [
            _SkeletonLine(width: 100, height: 12),
            SizedBox(width: 8),
            _SkeletonLine(width: 24, height: 12),
          ],
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < 3; i++) _SkeletonCard(delay: i * 80),
      ],
    );
  }

  Widget _buildError(Object e) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, color: _red, size: 40),
            const SizedBox(height: 12),
            const Text(
              'Could not load buses',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              e.toString(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'DMSans',
                fontSize: 12,
                color: _textSecondary,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _navy,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () {
                    ref.invalidate(busListProvider);
                    debugPrint('UniTrack: Retrying bus list fetch...');
                  },
                  icon: const Icon(Icons.refresh_rounded,
                      size: 18, color: Colors.white),
                  label: const Text(
                    'Retry',
                    style: TextStyle(fontFamily: 'DMSans', color: Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _navy,
                    side: const BorderSide(color: _navy),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () async {
                    try {
                      debugPrint('UniTrack: Checking Firebase connection...');
                      final snapshot = await globalDB.ref('buses').get();
                      if (snapshot.exists) {
                        debugPrint(
                            'UniTrack: Firebase has ${snapshot.children.length} buses');
                        ref.invalidate(busListProvider);
                      } else {
                        debugPrint('UniTrack: Firebase buses node is empty');
                        _showFirebaseDebugDialog();
                      }
                    } catch (err) {
                      debugPrint('UniTrack: Firebase error → $err');
                      _showFirebaseDebugDialog();
                    }
                  },
                  icon: const Icon(Icons.cloud_queue_rounded, size: 18),
                  label: const Text(
                    'Check Firebase',
                    style: TextStyle(fontFamily: 'DMSans'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showFirebaseDebugDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.bug_report_rounded, color: _amber, size: 22),
            SizedBox(width: 8),
            Text(
              'Firebase Debug',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontWeight: FontWeight.w700,
                color: _navy,
              ),
            ),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Possible causes:',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontWeight: FontWeight.w700,
                color: _textPrimary,
              ),
            ),
            SizedBox(height: 8),
            Text('• Firebase not initialized',
                style: TextStyle(fontFamily: 'DMSans', fontSize: 13)),
            Text('• Wrong database URL',
                style: TextStyle(fontFamily: 'DMSans', fontSize: 13)),
            Text('• No read permission',
                style: TextStyle(fontFamily: 'DMSans', fontSize: 13)),
            Text('• Database is empty',
                style: TextStyle(fontFamily: 'DMSans', fontSize: 13)),
            SizedBox(height: 12),
            Text(
              'Check Firebase Console → Realtime Database → Rules',
              style: TextStyle(
                  fontFamily: 'DMSans', fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'OK',
              style:
                  TextStyle(fontFamily: 'DMSans', fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, color: _navy, size: 40),
            const SizedBox(height: 12),
            const Text(
              'No buses found',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Try a different name or route keyword.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 13,
                color: _textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                _searchCtrl.clear();
                setState(() => _searchQuery = '');
              },
              icon: const Icon(Icons.clear_rounded, size: 16),
              label: const Text('Clear search'),
            ),
          ],
        ),
      ),
    );
  }

  // ─── MAIN CARDS ────────────────────────────────────────────────────────────

  Widget _buildModeCard(TrackingMode mode) {
    final color = _modeColor(mode);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(_modeIcon(mode), color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Tracking Mode',
                      style: TextStyle(
                        fontFamily: 'DMSans',
                        fontSize: 12,
                        color: _textSecondary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _modeLabel(mode),
                        style: TextStyle(
                          fontFamily: 'DMSans',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: color,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _modeDescription(mode),
                  style: const TextStyle(
                    fontFamily: 'DMSans',
                    fontSize: 12,
                    color: Color(0xFF374151),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // FIX 1: Updated _buildMiniMap - GoogleMap is direct child, NOT inside FutureBuilder
  Widget _buildMiniMap(Position? pos) {
    final center = _filteredPosition ??
        LatLng(pos?.latitude ?? 23.8103, pos?.longitude ?? 90.4125);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: 200,
        child: GoogleMap(
          initialCameraPosition: CameraPosition(target: center, zoom: 15),
          // FIX 4: Avoid leaking the previous `GoogleMapController` when the
          // mini map rebuilds. Dispose the old one before storing the new
          // reference. Without this, every rebuild silently leaks a native
          // controller and accumulates platform-channel listeners.
          onMapCreated: (controller) {
            _mapController?.dispose();
            _mapController = controller;
          },
          markers: (pos != null && _cachedMarkerIcon != null)
              ? {
                  Marker(
                    markerId: const MarkerId('bus'),
                    position: center,
                    icon: _cachedMarkerIcon!,
                    flat: true,
                    anchor: const Offset(0.5, 0.5),
                  ),
                }
              : {},
          myLocationEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          compassEnabled: true,
          mapType: MapType.normal,
        ),
      ),
    );
  }

  Widget _buildGpsStatsCard(LiveLocationState locState, bool isRunning) {
    final pos = locState.position;
    final lastUpdate = locState.lastUpdate;

    return Container(
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _navy.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, __) => Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isRunning
                          ? _green.withOpacity(_pulseAnim.value)
                          : Colors.grey.shade300,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Live GPS Data',
                  style: TextStyle(
                    fontFamily: 'DMSans',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827),
                  ),
                ),
                const Spacer(),
                if (lastUpdate != null)
                  Text(
                    'Updated ${_timeAgo(lastUpdate)}',
                    style: TextStyle(
                      fontFamily: 'DMSans',
                      fontSize: 11,
                      color: Colors.grey.shade400,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 18, endIndent: 18),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    _GpsStat(
                      icon: Icons.location_on_rounded,
                      label: 'Latitude',
                      value: _formatCoord(pos?.latitude, isLat: true),
                      color: _navy,
                    ),
                    const SizedBox(width: 12),
                    _GpsStat(
                      icon: Icons.location_on_rounded,
                      label: 'Longitude',
                      value: _formatCoord(pos?.longitude, isLat: false),
                      color: _navy,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _GpsStat(
                      icon: Icons.speed_rounded,
                      label: 'Speed',
                      value: _formatSpeed(pos?.speed),
                      color: const Color(0xFF8B5CF6),
                    ),
                    const SizedBox(width: 12),
                    _GpsStat(
                      icon: Icons.radar_rounded,
                      label: 'Accuracy',
                      value: pos != null
                          ? '±${pos.accuracy.toStringAsFixed(1)} m'
                          : '-- m',
                      color: _amber,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _GpsStat(
                      icon: Icons.terrain_rounded,
                      label: 'Altitude',
                      value: pos != null
                          ? '${pos.altitude.toStringAsFixed(1)} m'
                          : '-- m',
                      color: const Color(0xFF059669),
                    ),
                    const SizedBox(width: 12),
                    _GpsStat(
                      icon: Icons.explore_rounded,
                      label: 'Heading',
                      value: pos != null
                          ? '${pos.heading.toStringAsFixed(0)}°'
                          : '--°',
                      color: const Color(0xFFEC4899),
                    ),
                  ],
                ),
                if (_currentPlaceName.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: _navy.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _navy.withOpacity(0.12)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.place_rounded, size: 14, color: _navy),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _currentPlaceName,
                            style: const TextStyle(
                              fontFamily: 'DMSans',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _navy,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTripMetrics(
      LiveLocationState locState, DateTime? tripStartTime) {
    return Row(
      children: [
        Expanded(
          child: _MetricTile(
            icon: Icons.update_rounded,
            label: 'GPS Pings',
            value: '${locState.totalUpdates}',
            color: _navy,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MetricTile(
            icon: Icons.straighten_rounded,
            label: 'Distance',
            value: _formatDistance(locState.totalDistanceM),
            color: _green,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MetricTile(
            icon: Icons.timer_rounded,
            label: 'Uptime',
            value: _formatUptime(tripStartTime),
            color: const Color(0xFF8B5CF6),
          ),
        ),
      ],
    );
  }

  // ─── ACTION BUTTONS ──────────────────────────────────────────────────────

  Widget _buildTripButton(bool isRunning) {
    final canStart = _selectedBusId != null && !isRunning;
    return GestureDetector(
      // CRITICAL BUG #3 FIX: Disable onTap while a stop is in progress so a
      // double-tap can't fire _stopTrip() twice and crash the providers.
      onTap: canStart && !_isStartingTrip
          ? _startTrip
          : (isRunning && !_isStoppingTrip ? _stopTrip : null),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: 58,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isRunning
                ? [_red, const Color(0xFFC0392B)]
                : [_navy, _navyLight],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: (isRunning ? _red : _navy).withOpacity(0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: _isStartingTrip
            ? const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isRunning
                        ? Icons.stop_circle_rounded
                        : Icons.play_circle_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isRunning
                        ? 'End Trip'
                        : (canStart ? 'Start Trip' : 'Select a Bus First'),
                    style: const TextStyle(
                      fontFamily: 'DMSans',
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildServiceNote() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.verified_user_rounded,
            size: 13,
            color: Colors.grey.shade400,
          ),
          const SizedBox(width: 6),
          Text(
            'Background service active  •  Auto-starts on boot',
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 11,
              color: Colors.grey.shade400,
            ),
          ),
        ],
      ),
    );
  }

  // ─── SHIMMER & LOGOUT ────────────────────────────────────────────────────

  Widget _shimmerCard({double height = 80}) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(18),
      ),
    );
  }

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Sign Out',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontWeight: FontWeight.w700,
            color: _navy,
          ),
        ),
        content: const Text(
          'Are you sure you want to sign out?',
          style: TextStyle(fontFamily: 'DMSans'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(fontFamily: 'DMSans', color: Colors.grey),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _navy,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            // FIX 7: Add trip cleanup logic before signing out
            onPressed: () async {
              Navigator.pop(ctx);

              // Stop trip if running
              final isRunning =
                  ref.read(tripStatusProvider) == TripStatus.running;
              if (isRunning) {
                ref.read(liveLocationProvider.notifier).stopListening();
                ref.read(tripStatusProvider.notifier).state = TripStatus.idle;
                ref.read(tripStartTimeProvider.notifier).state = null;
                await BackgroundService().stopAndClear();
                WakelockPlus.disable();
              }

              try {
                await FirebaseAuth.instance.signOut();
                debugPrint('UniTrack: Sign out SUCCESS');
              } catch (e) {
                debugPrint('UniTrack: Sign out error → $e');
              }
              if (mounted) {
                Navigator.of(context)
                    .pushNamedAndRemoveUntil('/login', (route) => false);
              }
            },
            child: const Text(
              'Sign Out',
              style: TextStyle(fontFamily: 'DMSans', color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── REUSABLE SUB-WIDGETS ───────────────────────────────────────────────────

class _BusCard extends StatefulWidget {
  final BusModel bus;
  final bool isSelected;
  final VoidCallback onTap;
  final bool dimmed;

  const _BusCard({
    required this.bus,
    required this.isSelected,
    required this.onTap,
    this.dimmed = false,
  });

  @override
  State<_BusCard> createState() => _BusCardState();
}

class _BusCardState extends State<_BusCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeIn;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _scaleAnim = Tween<double>(
      begin: 0.96,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _fadeIn = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeIn,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                color: widget.isSelected ? _navy : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: widget.isSelected ? _navy : _divider,
                  width: widget.isSelected ? 1.5 : 1.2,
                ),
                boxShadow: widget.isSelected
                    ? [
                        BoxShadow(
                          color: _navy.withOpacity(0.28),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: Opacity(
                opacity: widget.dimmed && !widget.isSelected ? 0.55 : 1.0,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: widget.isSelected
                              ? Colors.white.withOpacity(0.15)
                              : _navyGlow,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.directions_bus_filled_rounded,
                          color: widget.isSelected ? Colors.white : _navy,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.bus.name,
                                    style: TextStyle(
                                      fontFamily: 'DMSans',
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: widget.isSelected
                                          ? Colors.white
                                          : _textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _StatusDot(
                                  active: widget.bus.active,
                                  selected: widget.isSelected,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  Icons.route_rounded,
                                  size: 13,
                                  color: widget.isSelected
                                      ? Colors.white.withOpacity(0.7)
                                      : _textMuted,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    widget.bus.route,
                                    style: TextStyle(
                                      fontFamily: 'DMSans',
                                      fontSize: 13,
                                      color: widget.isSelected
                                          ? Colors.white.withOpacity(0.75)
                                          : _textSecondary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            if (widget.bus.driverName != null &&
                                widget.bus.driverName!.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    Icons.person_outline_rounded,
                                    size: 13,
                                    color: widget.isSelected
                                        ? Colors.white.withOpacity(0.6)
                                        : _textMuted,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    widget.bus.driverName!,
                                    style: TextStyle(
                                      fontFamily: 'DMSans',
                                      fontSize: 12,
                                      color: widget.isSelected
                                          ? Colors.white.withOpacity(0.65)
                                          : _textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.isSelected
                              ? Colors.white
                              : Colors.transparent,
                          border: Border.all(
                            color: widget.isSelected
                                ? Colors.white
                                : _textMuted.withOpacity(0.5),
                            width: 2,
                          ),
                        ),
                        child: widget.isSelected
                            ? Center(
                                child: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _navy,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool active;
  final bool selected;
  const _StatusDot({required this.active, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: active
            ? (selected
                ? Colors.white.withOpacity(0.15)
                : const Color(0xFFDCFCE7))
            : (selected
                ? Colors.white.withOpacity(0.1)
                : const Color(0xFFF1F5F9)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? (selected ? Colors.greenAccent : _green)
                  : (selected ? Colors.white.withOpacity(0.4) : _textMuted),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            active ? 'Active' : 'Inactive',
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: active
                  ? (selected ? Colors.greenAccent : _green)
                  : (selected ? Colors.white.withOpacity(0.5) : _textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final int count;
  const _SectionLabel({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'DMSans',
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: _textMuted,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: _divider,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              fontFamily: 'DMSans',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  final double width;
  final double height;
  const _SkeletonLine({required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE2E8F0),
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}

class _SkeletonCard extends StatefulWidget {
  final int delay;
  const _SkeletonCard({this.delay = 0});

  @override
  State<_SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<_SkeletonCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _shimmer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _shimmer = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shimmer,
      builder: (_, __) {
        final shimmerColor = Color.lerp(
          const Color(0xFFE2E8F0),
          const Color(0xFFF1F5F9),
          _shimmer.value,
        )!;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            height: 78,
            decoration: BoxDecoration(
              color: shimmerColor,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        );
      },
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _GpsStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _GpsStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'DMSans',
                    fontSize: 11,
                    color: color.withOpacity(0.7),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              value,
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: color,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.10),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'DMSans',
              fontSize: 10,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withOpacity(0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'DMSans',
              fontSize: 13,
              color: Colors.grey,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}

// PERF BUG #8 FIX: A self-contained 1-second clock widget. Lifting this out of
// _DriverDashScreenState means the per-second setState() only rebuilds these
// two Text widgets — not the entire dashboard (which previously re-ran every
// `ref.watch()` and rebuilt all child widgets every tick).
class _LiveClock extends StatefulWidget {
  const _LiveClock();

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() => _now = DateTime.now());
      },
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          DateFormat('hh:mm:ss a').format(_now),
          style: const TextStyle(
            fontFamily: 'DMSans',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        Text(
          DateFormat('EEE, dd MMM').format(_now),
          style: const TextStyle(
            fontFamily: 'DMSans',
            fontSize: 11,
            color: Colors.white54,
          ),
        ),
      ],
    );
  }
}
