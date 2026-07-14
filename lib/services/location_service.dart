// lib/services/location_service.dart
// UniTrack — GPS Handler & Geofence Logic
// Handles: adaptive GPS intervals, movement filtering, power modes, geofencing
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────
// ENUMS & CONSTANTS
// ─────────────────────────────────────────────

enum PowerMode {
  /// 07:00–18:00 — GPS every 2 s, write on >1 m change
  active,

  /// 18:00–22:00 — GPS every 60 s
  lowPower,

  /// 22:00–07:00 — GPS completely off
  sleep,
}

enum MovementState {
  stationary, // < 2 km/h  → 3 s interval (optimized for smoother tracking)
  moving, // ≥ 2 km/h  → use PowerMode interval
}

class LocationConstants {
  // Power mode hour boundaries (24-h)
  static const int activeStartHour = 7;
  static const int activeEndHour = 18;
  static const int lowPowerEndHour = 22;

  // GPS polling intervals (seconds) - OPTIMIZED FOR SMOOTH MOVEMENT
  static const int activeIntervalSec =
      2; // Changed from 5 to 2 for faster updates
  static const int lowPowerIntervalSec = 60;
  static const int stationaryIntervalSec =
      3; // Changed from 30 to 3 for smoother tracking

  // Thresholds - OPTIMIZED FOR SENSITIVE MOVEMENT DETECTION
  static const double minDistanceMeters =
      1.0; // Changed from 5.0 to 1.0 for detecting small movements
  static const double stationarySpeedKph = 2.0; // Below = stationary

  // Geofence
  static const double geofenceRadiusMeters = 200.0;

  // SharedPreferences keys
  static const String kLastLat = 'loc_last_lat';
  static const String kLastLng = 'loc_last_lng';
  static const String kLastUpdate = 'loc_last_update';
}

// ─────────────────────────────────────────────
// DATA CLASSES
// ─────────────────────────────────────────────

class LocationData {
  final double latitude;
  final double longitude;
  final double speedKph;
  final double accuracyMeters;
  final double headingDegrees;
  final DateTime timestamp;
  final PowerMode powerMode;
  final MovementState movementState;

  const LocationData({
    required this.latitude,
    required this.longitude,
    required this.speedKph,
    required this.accuracyMeters,
    required this.headingDegrees,
    required this.timestamp,
    required this.powerMode,
    required this.movementState,
  });

  Map<String, dynamic> toFirebaseMap() => {
        'lat': latitude,
        'lng': longitude,
        'speed': double.parse(speedKph.toStringAsFixed(1)),
        'accuracy': double.parse(accuracyMeters.toStringAsFixed(1)),
        'heading': double.parse(headingDegrees.toStringAsFixed(1)),
        'lastUpdate': timestamp.millisecondsSinceEpoch,
        'powerMode': powerMode.name,
      };

  @override
  String toString() => 'LocationData(lat: $latitude, lng: $longitude, '
      'speed: ${speedKph.toStringAsFixed(1)} km/h, '
      'mode: ${powerMode.name}, movement: ${movementState.name})';
}

class GeofenceZone {
  final String id;
  final String label;
  final double centerLat;
  final double centerLng;
  final double radiusMeters;

  const GeofenceZone({
    required this.id,
    required this.label,
    required this.centerLat,
    required this.centerLng,
    this.radiusMeters = LocationConstants.geofenceRadiusMeters,
  });
}

enum GeofenceEvent { entered, exited, dwelling }

class GeofenceResult {
  final GeofenceZone zone;
  final GeofenceEvent event;
  final LocationData location;

  const GeofenceResult({
    required this.zone,
    required this.event,
    required this.location,
  });
}

// ─────────────────────────────────────────────
// LOCATION SERVICE
// ─────────────────────────────────────────────

class LocationService {
  // Singleton
  LocationService._internal();
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;

  // ── State ──────────────────────────────────
  Timer? _pollingTimer;
  LocationData? _lastWrittenLocation;
  LocationData? _currentLocation;
  PowerMode _currentPowerMode = PowerMode.sleep;
  MovementState _movementState = MovementState.stationary;
  bool _isRunning = false;

  // Geofence tracking: zoneId → currently inside?
  final Map<String, bool> _geofenceState = {};
  final List<GeofenceZone> _registeredZones = [];

  // Speed smoothing: moving average of last 3 speeds
  final List<double> _speedHistory = [];

  // ── Stream controllers ──────────────────────
  final StreamController<LocationData> _locationController =
      StreamController<LocationData>.broadcast();
  final StreamController<GeofenceResult> _geofenceController =
      StreamController<GeofenceResult>.broadcast();

  Stream<LocationData> get locationStream => _locationController.stream;
  Stream<GeofenceResult> get geofenceStream => _geofenceController.stream;

  LocationData? get currentLocation => _currentLocation;
  PowerMode get currentPowerMode => _currentPowerMode;
  MovementState get movementState => _movementState;
  bool get isRunning => _isRunning;

  // ─────────────────────────────────────────────
  // PUBLIC API
  // ─────────────────────────────────────────────

  /// Call once when Driver dashboard initialises.
  /// Returns false if permissions are denied.
  Future<bool> start() async {
    if (_isRunning) return true;

    final hasPermission = await _ensurePermissions();
    if (!hasPermission) return false;

    _isRunning = true;
    await _restoreLastLocation();
    _scheduleNextPoll();

    debugPrint('[LocationService] Started.');
    return true;
  }

  /// Stop all GPS polling (e.g., when trip ends or SLEEP mode kicks in).
  void stop() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _isRunning = false;
    debugPrint('[LocationService] Stopped.');
  }

  /// Register a geofence zone (e.g., university gate, bus depot).
  void registerGeofence(GeofenceZone zone) {
    _registeredZones.removeWhere((z) => z.id == zone.id);
    _registeredZones.add(zone);
    _geofenceState.putIfAbsent(zone.id, () => false);
    debugPrint('[LocationService] Geofence registered: ${zone.label}');
  }

  void unregisterGeofence(String zoneId) {
    _registeredZones.removeWhere((z) => z.id == zoneId);
    _geofenceState.remove(zoneId);
  }

  void clearGeofences() {
    _registeredZones.clear();
    _geofenceState.clear();
  }

  /// One-shot location fetch (used by student ETA calculation).
  Future<LocationData?> getCurrentLocationOnce() async {
    final hasPermission = await _ensurePermissions();
    if (!hasPermission) return null;

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return _positionToLocationData(pos, PowerMode.active);
    } catch (e) {
      debugPrint('[LocationService] One-shot fetch error: $e');
      return null;
    }
  }

  /// Returns true if the given coordinates are within [radiusMeters] of a point.
  static bool isWithinRadius({
    required double lat1,
    required double lng1,
    required double lat2,
    required double lng2,
    required double radiusMeters,
  }) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2) <= radiusMeters;
  }

  /// Calculate distance in meters between two coordinates.
  static double distanceBetween(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2);
  }

  /// Estimate ETA in minutes given current speed and remaining distance.
  /// Returns null if bus is stationary.
  static double? estimateEtaMinutes({
    required double remainingDistanceMeters,
    required double speedKph,
  }) {
    if (speedKph < LocationConstants.stationarySpeedKph) return null;
    final speedMps = speedKph / 3.6;
    return remainingDistanceMeters / speedMps / 60.0;
  }

  void dispose() {
    stop();
    _speedHistory.clear();
    _locationController.close();
    _geofenceController.close();
  }

  // ─────────────────────────────────────────────
  // CORE POLLING LOOP
  // ─────────────────────────────────────────────

  void _scheduleNextPoll() {
    _pollingTimer?.cancel();

    final mode = _computePowerMode();
    _currentPowerMode = mode;

    if (mode == PowerMode.sleep) {
      debugPrint('[LocationService] SLEEP mode — GPS off.');
      _isRunning = false;
      return;
    }

    final intervalSec = _computeIntervalSeconds(mode);
    debugPrint(
      '[LocationService] Mode: ${mode.name}, next poll in ${intervalSec}s',
    );

    _pollingTimer = Timer(Duration(seconds: intervalSec), () async {
      await _poll();
      if (_isRunning) _scheduleNextPoll(); // reschedule after each poll
    });
  }

  Future<void> _poll() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: _currentPowerMode == PowerMode.active
              ? LocationAccuracy.high
              : LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 15),
        ),
      );

      // Accuracy filter: reject readings with poor GPS lock
      if (pos.accuracy > 30.0) {
        debugPrint(
          '[LocationService] GPS accuracy too poor (${pos.accuracy.toStringAsFixed(1)}m), ignoring.',
        );
        return;
      }

      final location = _positionToLocationData(pos, _currentPowerMode);
      _currentLocation = location;
      _movementState = location.movementState;

      // Always emit to stream (for live UI)
      _locationController.add(location);

      // Check geofences
      _evaluateGeofences(location);

      // Gate Firebase write: only if moved >1 m (optimized threshold)
      if (_shouldWrite(location)) {
        _lastWrittenLocation = location;
        await _persistLocation(location);
        debugPrint('[LocationService] Write: $location');
      }
    } on LocationServiceDisabledException {
      debugPrint('[LocationService] Location services disabled.');
    } on PermissionDeniedException {
      debugPrint('[LocationService] Permission denied mid-session.');
      stop();
    } catch (e) {
      debugPrint('[LocationService] Poll error: $e');
    }
  }

  // ─────────────────────────────────────────────
  // POWER MODE LOGIC
  // ─────────────────────────────────────────────

  PowerMode _computePowerMode() {
    final hour = DateTime.now().hour;
    if (hour >= LocationConstants.activeStartHour &&
        hour < LocationConstants.activeEndHour) {
      return PowerMode.active;
    }
    if (hour >= LocationConstants.activeEndHour &&
        hour < LocationConstants.lowPowerEndHour) {
      return PowerMode.lowPower;
    }
    return PowerMode.sleep;
  }

  int _computeIntervalSeconds(PowerMode mode) {
    // OPTIMIZED: Always use activeIntervalSec in active mode for smooth tracking
    // Removed stationary override - now tracks movement continuously
    if (mode == PowerMode.active) {
      return LocationConstants.activeIntervalSec;
    }
    return LocationConstants.lowPowerIntervalSec;
  }

  // ─────────────────────────────────────────────
  // WRITE GATE
  // ─────────────────────────────────────────────

  bool _shouldWrite(LocationData location) {
    final last = _lastWrittenLocation;
    if (last == null) return true;

    final dist = Geolocator.distanceBetween(
      last.latitude,
      last.longitude,
      location.latitude,
      location.longitude,
    );
    return dist >= LocationConstants.minDistanceMeters;
  }

  // ─────────────────────────────────────────────
  // GEOFENCE EVALUATION
  // ─────────────────────────────────────────────

  void _evaluateGeofences(LocationData location) {
    for (final zone in _registeredZones) {
      final distance = Geolocator.distanceBetween(
        location.latitude,
        location.longitude,
        zone.centerLat,
        zone.centerLng,
      );

      final wasInside = _geofenceState[zone.id] ?? false;
      final isInside = distance <= zone.radiusMeters;

      if (isInside && !wasInside) {
        _geofenceState[zone.id] = true;
        _geofenceController.add(
          GeofenceResult(
            zone: zone,
            event: GeofenceEvent.entered,
            location: location,
          ),
        );
        debugPrint('[LocationService] Geofence ENTER: ${zone.label}');
      } else if (!isInside && wasInside) {
        _geofenceState[zone.id] = false;
        _geofenceController.add(
          GeofenceResult(
            zone: zone,
            event: GeofenceEvent.exited,
            location: location,
          ),
        );
        debugPrint('[LocationService] Geofence EXIT: ${zone.label}');
      }
    }
  }

  // ─────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────

  LocationData _positionToLocationData(Position pos, PowerMode mode) {
    // Raw speed in m/s, convert to km/h
    final rawSpeedKph = (pos.speed < 0 ? 0.0 : pos.speed) * 3.6;

    // Speed smoothing: maintain moving average of last 3 speeds
    _speedHistory.add(rawSpeedKph);
    if (_speedHistory.length > 3) {
      _speedHistory.removeAt(0);
    }
    final smoothedSpeedKph =
        _speedHistory.fold(0.0, (sum, s) => sum + s) / _speedHistory.length;

    return LocationData(
      latitude: pos.latitude,
      longitude: pos.longitude,
      speedKph: smoothedSpeedKph,
      accuracyMeters: pos.accuracy,
      headingDegrees: pos.heading,
      timestamp: pos.timestamp,
      powerMode: mode,
      movementState: smoothedSpeedKph < LocationConstants.stationarySpeedKph
          ? MovementState.stationary
          : MovementState.moving,
    );
  }


  // ─────────────────────────────────────────────
  // PERMISSIONS
  // ─────────────────────────────────────────────

  Future<bool> ensurePermissions() => _ensurePermissions();

  Future<Position?> getCurrentPosition() async {
    final ok = await _ensurePermissions();
    if (!ok) return null;
    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.bestForNavigation,
    );
  }

  Future<bool> _ensurePermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[LocationService] Location services disabled.');
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('[LocationService] Location permission denied.');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('[LocationService] Location permission permanently denied.');
      return false;
    }

    return true;
  }

  // ─────────────────────────────────────────────
  // PERSISTENCE (SharedPreferences cache)
  // ─────────────────────────────────────────────

  Future<void> _persistLocation(LocationData location) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(LocationConstants.kLastLat, location.latitude);
      await prefs.setDouble(LocationConstants.kLastLng, location.longitude);
      await prefs.setInt(
        LocationConstants.kLastUpdate,
        location.timestamp.millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('[LocationService] Persist error: $e');
    }
  }

  Future<void> _restoreLastLocation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble(LocationConstants.kLastLat);
      final lng = prefs.getDouble(LocationConstants.kLastLng);
      final ms = prefs.getInt(LocationConstants.kLastUpdate);
      if (lat != null && lng != null && ms != null) {
        _lastWrittenLocation = LocationData(
          latitude: lat,
          longitude: lng,
          speedKph: 0,
          accuracyMeters: 0,
          headingDegrees: 0,
          timestamp: DateTime.fromMillisecondsSinceEpoch(ms),
          powerMode: PowerMode.sleep,
          movementState: MovementState.stationary,
        );
        debugPrint('[LocationService] Restored last location: ($lat, $lng)');
      }
    } catch (e) {
      debugPrint('[LocationService] Restore error: $e');
    }
  }
}
