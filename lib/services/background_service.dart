// lib/services/background_service.dart
// UniTrack — Foreground Task, Boot Receiver, WakeLock, Battery Optimisation

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import 'location_service.dart';

// ─────────────────────────────────────────────
// WATCHDOG ALARM CALLBACK
// ─────────────────────────────────────────────
// This callback runs periodically via Android AlarmManager to check if the
// background service is still running. If the service was killed by OEM
// battery optimizations, this watchdog attempts to restart it.

@pragma('vm:entry-point')
void watchdogCallback() async {
  debugPrint('[Watchdog] Alarm triggered - checking service status');

  try {
    final prefs = await SharedPreferences.getInstance();

    // Check if a trip is active using the existing key
    final tripActive = prefs.getBool('bg_trip_active') ?? false;
    final explicitStop = prefs.getBool('bg_explicit_stop') ?? false;

    debugPrint('[Watchdog] tripActive: $tripActive, explicitStop: $explicitStop');

    // Only restart if trip is active AND user didn't explicitly stop it
    if (tripActive && !explicitStop) {
      final busId = prefs.getString('bg_bus_id') ?? '';
      final busName = prefs.getString('bg_bus_name') ?? 'Bus';
      final busRoute = prefs.getString('bg_bus_route') ?? '';
      final driverName = prefs.getString('bg_driver_name') ?? '';

      if (busId.isNotEmpty) {
        debugPrint('[Watchdog] Attempting to restart service for bus: $busId');

        // Reuse existing BackgroundService.start() method
        final service = BackgroundService();
        await service.start(
          busId: busId,
          busName: busName,
          busRoute: busRoute,
          driverName: driverName,
        );

        debugPrint('[Watchdog] Service restart attempted');
      } else {
        debugPrint('[Watchdog] No valid busId found, skipping restart');
      }
    } else {
      debugPrint('[Watchdog] No active trip or explicit stop, skipping restart');
    }
  } catch (e) {
    debugPrint('[Watchdog] Error in watchdog callback: $e');
  }
}

const String _firebaseDatabaseUrl =
    'https://uni-bus-locate-default-rtdb.asia-southeast1.firebasedatabase.app';

class _BgKeys {
  static const String busId = 'bg_bus_id';
  static const String busName = 'bg_bus_name';
  static const String busRoute = 'bg_bus_route';
  static const String driverName = 'bg_driver_name';
  static const String isActive = 'bg_is_active';
  static const String tripActive = 'bg_trip_active';
  static const String tripStartMs = 'bg_trip_start_ms';
  static const String currentTripId = 'bg_current_trip_id';
  static const String portName = 'unitrack_bg_port';
  static const String notifChannelId = 'unitrack_location_channel';
  static const String notifChannelName = 'UniTrack Live Tracking';
  // ✅ FIX: Aligned with TripPersistenceKeys in lib/providers/tracking_provider.dart
  static const String destLat = 'bg_dest_lat';
  static const String destLng = 'bg_dest_lng';
  static const String destRadiusM = 'bg_dest_radius_m';
  static const String destEnabled = 'bg_dest_enabled';

  // ✅ FIX: Driver "End Trip" press করলে এই key true হবে
  // App kill হলে এই key false থাকবে → onDestroy জানবে restart হবে
  static const String explicitStop = 'bg_explicit_stop';
}

class BgMessage {
  static const String locationUpdate = 'location_update';
  static const String modeChanged = 'mode_changed';
  static const String tripStarted = 'trip_started';
  static const String tripEnded = 'trip_ended';
  static const String error = 'error';
}

// ─────────────────────────────────────────────
// OFFLINE GPS QUEUE
// ─────────────────────────────────────────────

class OfflineLocationQueue {
  static const _key = 'offline_gps_queue';
  static const _maxSize = 500;

  static Future<void> enqueue(Position pos) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final List<dynamic> list =
          raw != null ? jsonDecode(raw) as List<dynamic> : [];
      list.add({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'speed': pos.speed < 0 ? 0.0 : pos.speed * 3.6,
        'accuracy': pos.accuracy,
        'heading': pos.heading,
        'ts': pos.timestamp.millisecondsSinceEpoch,
      });
      final trimmed =
          list.length > _maxSize ? list.sublist(list.length - _maxSize) : list;
      await prefs.setString(_key, jsonEncode(trimmed));
    } catch (e) {
      debugPrint('[OfflineQueue] enqueue error: $e');
    }
  }

  static Future<void> enqueueMap(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final List<dynamic> list =
          raw != null ? jsonDecode(raw) as List<dynamic> : [];
      list.add(data);
      final trimmed =
          list.length > _maxSize ? list.sublist(list.length - _maxSize) : list;
      await prefs.setString(_key, jsonEncode(trimmed));
    } catch (e) {
      debugPrint('[OfflineQueue] enqueueMap error: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> dequeueAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      await prefs.remove(_key);
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[OfflineQueue] dequeueAll error: $e');
      return [];
    }
  }

  static Future<int> pendingCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return 0;
      final list = jsonDecode(raw) as List<dynamic>;
      return list.length;
    } catch (_) {
      return 0;
    }
  }
}

// ─────────────────────────────────────────────
// TASK HANDLER
// ─────────────────────────────────────────────

@pragma('vm:entry-point')
class UniTrackTaskHandler extends TaskHandler {
  StreamSubscription<Position>? _positionSub;
  LocationData? _lastWritten;
  PowerMode _powerMode = PowerMode.sleep;
  MovementState _movementState = MovementState.stationary;
  bool _tripActive = false;
  DateTime? _tripStartTime;

  String _busId = '';
  String _busName = '';
  String _busRoute = '';
  String _driverName = '';

  String _lastNotificationBody = ''; // Will be set to initial notification text on service start

  bool _destEnabled = false;
  double? _destLat;
  double? _destLng;
  double _destRadiusM = 100.0;

  DateTime? _lastForceWrite;

  FirebaseDatabase? _db;
  SendPort? _mainPort;

  // ✅ FIX: Driver explicit stop flag — sadharno app kill e false thake
  bool _isExplicitStop = false;

  // ── Lifecycle ──────────────────────────────

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BgTask] onStart — starter: $starter');

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    _db = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: _firebaseDatabaseUrl,
    );

    // ✅ BUG 4 FIX: Read the explicit-stop flag BEFORE _loadConfig() so
    // that resetting the flag below doesn't wipe the value we need to
    // act on. Previously _loadConfig() set _isExplicitStop from prefs
    // and then the very next lines reset both prefs + the field to
    // false, losing the loaded value entirely.
    final prefs = await SharedPreferences
        .getInstance(); // BUG 4: prefs accessed before _loadConfig()
    final bool wasExplicitStop = prefs.getBool(_BgKeys.explicitStop) ??
        false; // BUG 4: capture into local var

    // BUG 4: If the previous lifecycle ended with an explicit stop, do
    // NOT silently restart tracking. Reset the flag and stop the
    // service so we don't undo the user's "End Trip" / geofence stop.
    if (wasExplicitStop) {
      // BUG 4: skip restart on explicit stop
      debugPrint('[BgTask] onStart — explicit stop detected, skipping restart');
      await prefs.setBool(
          _BgKeys.explicitStop, false); // BUG 4: reset persisted flag
      _isExplicitStop =
          true; // BUG 4: ensure onDestroy() runs the explicit-stop branch
      await FlutterForegroundTask
          .stopService(); // BUG 4: don't continue starting GPS stream
      return; // BUG 4: early-return so _loadConfig / stream startup is skipped
    }

    await _loadConfig();

    // ✅ FIX: onStart এ explicit stop flag reset করো
    // Service restart হলে আবার track করা শুরু হবে
    await prefs.setBool(_BgKeys.explicitStop,
        false); // BUG 4: reuse the prefs instance read above
    _isExplicitStop = false;

    _mainPort = IsolateNameServer.lookupPortByName(_BgKeys.portName);

    _powerMode = _computePowerMode();
    if (_powerMode == PowerMode.sleep) {
      _updateNotification('Resting — resumes at 7:00 AM', isTracking: false);
    }
    _startLocationStream();
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    final newMode = _computePowerMode();
    if (newMode != _powerMode) {
      debugPrint('[BgTask] PowerMode changed from $_powerMode to $newMode');
      _powerMode = newMode;

      if (_powerMode == PowerMode.sleep) {
        _updateNotification('Resting — resumes at 7:00 AM', isTracking: false);
        _positionSub?.cancel();
        _positionSub = null;
        debugPrint('[BgTask] Sleep mode — GPS paused, trip remains active');
        return;
      } else {
        _startLocationStream();
      }
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[BgTask] onDestroy — explicitStop: $_isExplicitStop');
    _positionSub?.cancel();

    // ✅ BUG 2 FIX: Also read the persisted explicit-stop flag from
    // SharedPreferences. If the 'stop' IPC message hasn't been received
    // yet (e.g. stopService() was triggered directly), the in-memory
    // _isExplicitStop may still be false even though the user / geofence
    // explicitly requested a stop. Treat EITHER flag being true as an
    // explicit stop so _endTrip() always runs in those cases.
    bool persistedExplicitStop = false; // BUG 2: local flag from prefs
    try {
      final prefs = await SharedPreferences
          .getInstance(); // BUG 2: read prefs in onDestroy
      persistedExplicitStop =
          prefs.getBool(_BgKeys.explicitStop) ?? false; // BUG 2
    } catch (_) {}
    final bool isExplicitStop =
        _isExplicitStop || persistedExplicitStop; // BUG 2: union of both flags

    // ✅ CORE FIX:
    // App kill (recent apps swipe) হলে _isExplicitStop = false
    //   → _endTrip() call হবে না
    //   → Firebase-এ active=true থাকবে
    //   → Service OS restart করবে, GPS আবার চালু হবে
    //
    // Driver "End Trip" press করলে _isExplicitStop = true
    //   → _endTrip() call হবে → Firebase-এ active=false হবে
    if (isExplicitStop) {
      // BUG 2: use combined flag instead of just _isExplicitStop
      await _endTrip();
    } else {
      // App kill — শুধু lastUpdate timestamp দাও, active=true রাখো
      // Student screen দেখবে lastUpdate পুরনো হলে "Signal Lost"
      if (_busId.isNotEmpty && _db != null) {
        try {
          await _db!.ref('buses/$_busId').update({
            'lastUpdate': DateTime.now().millisecondsSinceEpoch,
            'active': true, // ✅ active=true রাখো, service restart হবে
          });
        } catch (_) {}
      }
      debugPrint('[BgTask] App killed — trip preserved, service will restart');
    }
  }

  // ── Data from main isolate ─────────────────

  @override
  void onReceiveData(Object data) {
    if (data is Map<String, dynamic>) {
      final cmd = data['cmd'] as String?;
      switch (cmd) {
        case 'update_bus':
          _busId = data['busId'] ?? _busId;
          _busName = data['busName'] ?? _busName;
          _busRoute = data['busRoute'] ?? _busRoute;
          _driverName = data['driverName'] ?? _driverName;
          break;

        case 'set_initial_notif':
          _lastNotificationBody = data['initialNotifText'] as String? ?? '';
          break;

        // ✅ FIX: 'stop' command এলে explicit stop flag set করো
        // তারপর service বন্ধ করো
        case 'stop':
          _isExplicitStop = true;
          // SharedPreferences-এও save করো কারণ isolate আলাদা
          SharedPreferences.getInstance().then((prefs) {
            prefs.setBool(_BgKeys.explicitStop, true);
          });
          FlutterForegroundTask.stopService();
          break;
      }
    }
  }

  // ─────────────────────────────────────────────
  // LOCATION STREAM
  // ─────────────────────────────────────────────

  void _startLocationStream() {
    _positionSub?.cancel();

    if (_powerMode == PowerMode.sleep) {
      debugPrint('[BgTask] SLEEP mode — stopping GPS stream.');
      return;
    }

    LocationSettings locationSettings;
    if (_powerMode == PowerMode.active) {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.low,
        distanceFilter: 50,
      );
    }

    _positionSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) => _onNewPosition(position),
      onError: (e) {
        debugPrint('[BgTask] GPS stream error: $e');
        _sendToMain({'type': BgMessage.error, 'msg': e.toString()});
      },
    );

    debugPrint('[BgTask] Location stream started in $_powerMode mode.');
  }

  Future<void> _onNewPosition(Position pos) async {
    final speedKph = (pos.speed < 0 ? 0.0 : pos.speed) * 3.6;
    _movementState = speedKph < LocationConstants.stationarySpeedKph
        ? MovementState.stationary
        : MovementState.moving;

    final location = LocationData(
      latitude: pos.latitude,
      longitude: pos.longitude,
      speedKph: speedKph,
      accuracyMeters: pos.accuracy,
      headingDegrees: pos.heading,
      timestamp: pos.timestamp,
      powerMode: _powerMode,
      movementState: _movementState,
    );

    _sendToMain({
      'type': BgMessage.locationUpdate,
      'lat': location.latitude,
      'lng': location.longitude,
      'speed': location.speedKph,
      'heading': location.headingDegrees,
      'mode': _powerMode.name,
    });

    if (_shouldWrite(location)) {
      _lastWritten = location;
      await _writeToFirebase(location);
      _updateNotification(_buildNotificationBody(location), isTracking: true);
    }

    await _checkGeofence(pos);
  }

  // ─────────────────────────────────────────────
  // GEOFENCE
  // ─────────────────────────────────────────────

  Future<void> _checkGeofence(Position currentPos) async {
    if (!_destEnabled || _destLat == null || _destLng == null) return;

    final distance = Geolocator.distanceBetween(
      currentPos.latitude,
      currentPos.longitude,
      _destLat!,
      _destLng!,
    );

    if (distance <= _destRadiusM) {
      debugPrint('[BgTask] Geofence reached — stopping trip.');
      if (_busId.isNotEmpty && _db != null) {
        try {
          await _db!.ref('buses/$_busId').update({'active': false});
        } catch (_) {}
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('bg_trip_active', false);
      // ✅ BUG 1 FIX: Mark this as an explicit stop BEFORE stopService()
      // so onDestroy() runs the _endTrip() branch instead of the
      // "app killed" branch (which would set active=true again).
      _isExplicitStop = true; // BUG 1: in-memory flag for onDestroy()
      await prefs.setBool(_BgKeys.explicitStop,
          true); // BUG 1: persisted flag (cross-isolate safe)
      // Cancel watchdog alarm on geofence-triggered stop
      await BackgroundService._cancelWatchdogAlarm();
      await FlutterForegroundTask.stopService();
    }
  }

  // ─────────────────────────────────────────────
  // FIREBASE WRITE
  // ─────────────────────────────────────────────

  Future<void> _writeToFirebase(LocationData loc) async {
    if (_busId.isEmpty || _db == null) return;

    try {
      if (!_tripActive) await _startTrip();

      await _db!.ref('buses/$_busId').update({
        'lat': loc.latitude,
        'lng': loc.longitude,
        'speed': double.parse(loc.speedKph.toStringAsFixed(1)),
        'active': true,
        'lastUpdate': loc.timestamp.millisecondsSinceEpoch,
        'trackMode': 'phone',
        if (_driverName.isNotEmpty) 'driverName': _driverName,
      });

      debugPrint(
        '[BgTask] Firebase write: (${loc.latitude}, ${loc.longitude}) '
        '${loc.speedKph.toStringAsFixed(1)} km/h',
      );
    } catch (e) {
      debugPrint('[BgTask] Firebase write error: $e — queuing offline.');
      try {
        await OfflineLocationQueue.enqueueMap({
          'lat': loc.latitude,
          'lng': loc.longitude,
          'speed': loc.speedKph,
          'accuracy': loc.accuracyMeters,
          'heading': loc.headingDegrees,
          'ts': loc.timestamp.millisecondsSinceEpoch,
        });
      } catch (queueErr) {
        debugPrint('[BgTask] Offline queue error: $queueErr');
      }
    }
  }

  Future<void> _startTrip() async {
    if (_tripActive || _db == null) return;

    final prefs = await SharedPreferences.getInstance();
    final existingTripId = prefs.getString(_BgKeys.currentTripId);
    if (existingTripId != null && existingTripId.isNotEmpty) {
      // ✅ BUG 5 FIX: A stale tripId may remain in SharedPreferences
      // after a crash / force-kill. Verify the trip actually exists in
      // Firebase and is still 'active' before resuming. Otherwise the
      // service would silently latch onto a trip that no longer exists.
      try {
        final snap = await _db!
            .ref('trips/$existingTripId')
            .get(); // BUG 5: verify trip in Firebase
        final value = snap
            .value; // BUG 5: snapshot payload (may be null if trip was deleted)
        if (snap.exists && value is Map && value['status'] == 'active') {
          // BUG 5: only resume if still active
          _tripActive = true; // BUG 5: safe to resume — trip is real & active
          debugPrint('[BgTask] Resuming existing trip: $existingTripId');
          return;
        }
        // BUG 5: trip missing or not active → drop stale key and fall
        // through to create a fresh trip below.
        debugPrint(
            '[BgTask] Stale tripId $existingTripId (missing/non-active) — clearing'); // BUG 5
        await prefs.remove(_BgKeys.currentTripId); // BUG 5: clear stale key
      } catch (e) {
        // BUG 5: On read failure, be conservative — clear the stale key
        // and create a new trip rather than resuming an unverified one.
        debugPrint(
            '[BgTask] Trip verify failed ($e) — clearing stale tripId'); // BUG 5
        await prefs
            .remove(_BgKeys.currentTripId); // BUG 5: clear unverifiable key
      }
    }

    _tripActive = true;
    _tripStartTime = DateTime.now();

    final tripRef = _db!.ref('trips').push();
    await tripRef.set({
      'busId': _busId,
      'route': _busRoute,
      'startTime': _tripStartTime!.millisecondsSinceEpoch,
      'status': 'active',
    });

    await prefs.setString(_BgKeys.currentTripId, tripRef.key!);
    _sendToMain({'type': BgMessage.tripStarted, 'busId': _busId});
    debugPrint('[BgTask] Trip started: $_busId, tripId: ${tripRef.key}');
  }

  Future<void> _endTrip() async {
    if (!_tripActive || _db == null) return;
    _tripActive = false;

    if (_busId.isNotEmpty) {
      try {
        await _db!.ref('buses/$_busId').update({
          'active': false,
          'speed': 0,
          'lastUpdate': DateTime.now().millisecondsSinceEpoch,
        });
      } catch (_) {}
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_BgKeys.currentTripId);
    // ✅ FIX: explicit stop flag clear করো
    await prefs.setBool(_BgKeys.explicitStop, false);

    _sendToMain({'type': BgMessage.tripEnded, 'busId': _busId});
    debugPrint('[BgTask] Trip ended for bus: $_busId');
  }

  // ─────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────

  bool _shouldWrite(LocationData loc) {
    final now = DateTime.now();
    if (_lastForceWrite == null ||
        now.difference(_lastForceWrite!).inSeconds >= 30) {
      _lastForceWrite = now;
      return true;
    }
    final last = _lastWritten;
    if (last == null) return true;
    final dist = LocationService.distanceBetween(
      last.latitude,
      last.longitude,
      loc.latitude,
      loc.longitude,
    );
    return dist >= LocationConstants.minDistanceMeters;
  }

  PowerMode _computePowerMode() {
    final h = DateTime.now().hour;
    if (h >= LocationConstants.activeStartHour &&
        h < LocationConstants.activeEndHour) return PowerMode.active;
    if (h >= LocationConstants.activeEndHour &&
        h < LocationConstants.lowPowerEndHour) return PowerMode.lowPower;
    return PowerMode.sleep;
  }

  String _buildNotificationBody(LocationData loc) {
    final speed = loc.speedKph.toStringAsFixed(0);
    final modeLabel = _powerMode == PowerMode.active ? 'Active' : 'Low Power';
    return '$_busName · ${loc.speedKph < 2 ? "Stationary" : "$speed km/h"} · $modeLabel';
  }

  void _updateNotification(String body, {required bool isTracking}) {
    if (body == _lastNotificationBody) return;
    _lastNotificationBody = body;
    FlutterForegroundTask.updateService(
      notificationTitle: isTracking ? '🚌 UniTrack — Tracking' : '🚌 UniTrack',
      notificationText: body,
    );
  }

  void _sendToMain(Map<String, dynamic> data) {
    _mainPort?.send(data);
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _busId = prefs.getString(_BgKeys.busId) ?? '';
    _busName = prefs.getString(_BgKeys.busName) ?? 'Bus';
    _busRoute = prefs.getString(_BgKeys.busRoute) ?? '';
    _driverName = prefs.getString(_BgKeys.driverName) ?? '';
    _destEnabled = prefs.getBool(_BgKeys.destEnabled) ?? false;
    _destLat = prefs.getDouble(_BgKeys.destLat);
    _destLng = prefs.getDouble(_BgKeys.destLng);
    _destRadiusM = prefs.getDouble(_BgKeys.destRadiusM) ?? 100.0;

    // ✅ FIX: Startup এ explicit stop flag পড়ো
    _isExplicitStop = prefs.getBool(_BgKeys.explicitStop) ?? false;

    debugPrint('[BgTask] Config loaded — busId: $_busId, route: $_busRoute');
  }
}

// ─────────────────────────────────────────────
// BACKGROUND SERVICE (called from main isolate)
// ─────────────────────────────────────────────

class BackgroundService {
  BackgroundService._internal();
  static final BackgroundService _instance = BackgroundService._internal();
  factory BackgroundService() => _instance;

  ReceivePort? _receivePort;
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  static void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _BgKeys.notifChannelId,
        channelName: _BgKeys.notifChannelName,
        channelDescription:
            'Keeps the bus tracking service running in the background.',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  Future<bool> start({
    required String busId,
    required String busName,
    required String busRoute,
    String driverName = '',
  }) async {
    final locStatus = await Permission.locationAlways.request();
    if (!locStatus.isGranted) {
      debugPrint('[BackgroundService] locationAlways not granted.');
      return false;
    }

    await _requestNotificationPermission();
    _openReceivePort();
    await _requestBatteryOptimisationExemption();
    await _requestExactAlarmPermission();

    final serviceRunning = await FlutterForegroundTask.isRunningService;

    if (serviceRunning) {
      FlutterForegroundTask.sendDataToTask({
        'cmd': 'update_bus',
        'busId': busId,
        'busName': busName,
        'busRoute': busRoute,
        'driverName': driverName,
      });
      await _flushOfflineQueue(busId: busId);
      return true;
    }

    final initialNotifText = 'Initialising GPS for $busName...';
    final result = await FlutterForegroundTask.startService(
      notificationTitle: '🚌 UniTrack — Starting',
      notificationText: initialNotifText,
    );
    final success = result is ServiceRequestSuccess;

    if (success) {
      // Send initial notification text to background isolate so first GPS update will always differ
      FlutterForegroundTask.sendDataToTask({
        'cmd': 'set_initial_notif',
        'initialNotifText': initialNotifText,
      });
      await _flushOfflineQueue(busId: busId);
    }

    return success;
  }

  Future<void> _flushOfflineQueue({required String busId}) async {
    final pending = await OfflineLocationQueue.pendingCount();
    if (pending == 0) return;

    debugPrint('[BackgroundService] Flushing $pending offline GPS points…');
    final items = await OfflineLocationQueue.dequeueAll();
    if (items.isEmpty) return;

    FirebaseDatabase? db;
    try {
      db = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: _firebaseDatabaseUrl,
      );
    } catch (e) {
      debugPrint('[BackgroundService] Firebase unavailable for flush: $e');
      return;
    }

    for (final item in items) {
      try {
        await db.ref('buses/$busId').update({
          'lat': item['lat'],
          'lng': item['lng'],
          'speed': item['speed'],
          'active': true,
          'lastUpdate': item['ts'],
          'trackMode': 'phone',
        });
      } catch (e) {
        debugPrint('[BackgroundService] Flush write failed (skipping): $e');
      }
    }

    debugPrint('[BackgroundService] Offline queue flush complete.');
  }

  // ✅ FIX: stop() এ explicit stop flag set করো
  // তারপরেই service বন্ধ করো
  Future<void> stop() async {
    // SharedPreferences-এ flag set করো — isolate পড়বে
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_BgKeys.explicitStop, true);

    // Task handler-কেও জানাও
    // ✅ BUG 3 FIX: Only the task handler should call
    // FlutterForegroundTask.stopService() (via its onReceiveData('stop')
    // branch). Calling it here as well caused stopService() to fire
    // twice. Removed the direct stopService() call (and the surrounding
    // delay) below; the SharedPreferences flag write and sendDataToTask
    // call are intentionally kept.
    FlutterForegroundTask.sendDataToTask(
        {'cmd': 'stop'}); // BUG 3: handler will call stopService() once

    // BUG 3: Removed `await Future.delayed(...)` and
    // `await FlutterForegroundTask.stopService();` to avoid double-stop.
    _closeReceivePort();
    debugPrint('[BackgroundService] Stopped explicitly.');
  }

  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  void _openReceivePort() {
    _closeReceivePort();
    _receivePort = FlutterForegroundTask.receivePort;
    if (_receivePort != null) {
      IsolateNameServer.registerPortWithName(
        _receivePort!.sendPort,
        _BgKeys.portName,
      );
      _receivePort!.listen((data) {
        if (data is Map<String, dynamic>) {
          _messageController.add(data);
        }
      });
    }
  }

  void _closeReceivePort() {
    IsolateNameServer.removePortNameMapping(_BgKeys.portName);
    _receivePort?.close();
    _receivePort = null;
  }

  Future<void> _requestBatteryOptimisationExemption() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final requested = prefs.getBool('battery_opt_requested') ?? false;
      if (requested) return;
      final isIgnoring =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      debugPrint('[BackgroundService] Battery opt exemption - isIgnoring: $isIgnoring');
      if (!isIgnoring) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        final isIgnoringAfter =
            await FlutterForegroundTask.isIgnoringBatteryOptimizations;
        debugPrint('[BackgroundService] Battery opt exemption - isIgnoring after request: $isIgnoringAfter');
      }
      await prefs.setBool('battery_opt_requested', true);
    } catch (e) {
      debugPrint('[BackgroundService] Battery opt exemption error: $e');
    }
  }

  Future<void> _requestNotificationPermission() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final requested = prefs.getBool('notification_perm_requested') ?? false;
      if (requested) return;
      await Permission.notification.request();
      await prefs.setBool('notification_perm_requested', true);
    } catch (e) {
      debugPrint('[BackgroundService] Notification permission error: $e');
    }
  }

  Future<void> _requestExactAlarmPermission() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final requested = prefs.getBool('exact_alarm_requested') ?? false;
      if (requested) return;

      final status = await Permission.scheduleExactAlarm.status;
      debugPrint('[BackgroundService] Exact alarm permission status before request: $status');

      if (!status.isGranted) {
        final result = await Permission.scheduleExactAlarm.request();
        debugPrint('[BackgroundService] Exact alarm permission status after request: $result');
      }

      await prefs.setBool('exact_alarm_requested', true);
    } catch (e) {
      debugPrint('[BackgroundService] Exact alarm permission error: $e');
    }
  }

  static Future<void> clearConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_BgKeys.busId);
    await prefs.remove(_BgKeys.busName);
    await prefs.remove(_BgKeys.busRoute);
    await prefs.remove(_BgKeys.driverName);
    await prefs.setBool(_BgKeys.isActive, false);
  }

  static Future<bool> hasStoredConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final busId = prefs.getString(_BgKeys.busId) ?? '';
    final isActive = prefs.getBool(_BgKeys.isActive) ?? false;
    return busId.isNotEmpty && isActive;
  }

  static Future<Map<String, String>> loadStoredConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'busId': prefs.getString(_BgKeys.busId) ?? '',
      'busName': prefs.getString(_BgKeys.busName) ?? '',
      'busRoute': prefs.getString(_BgKeys.busRoute) ?? '',
      'driverName': prefs.getString(_BgKeys.driverName) ?? '',
    };
  }

  void dispose() {
    _closeReceivePort();
    _messageController.close();
  }

  // ─────────────────────────────────────────────
  // WATCHDOG ALARM HELPERS
  // ─────────────────────────────────────────────

  static Future<void> _registerWatchdogAlarm() async {
    if (!Platform.isAndroid) return;
    try {
      await AndroidAlarmManager.periodic(
        const Duration(minutes: 2),
        0,
        watchdogCallback,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
      );
      debugPrint('[BackgroundService] Watchdog alarm registered (periodic every 2 minutes)');
    } catch (e) {
      debugPrint('[BackgroundService] Failed to register watchdog alarm: $e');
    }
  }

  static Future<void> _cancelWatchdogAlarm() async {
    if (!Platform.isAndroid) return;
    try {
      await AndroidAlarmManager.cancel(0);
      debugPrint('[BackgroundService] Watchdog alarm cancelled');
    } catch (e) {
      debugPrint('[BackgroundService] Failed to cancel watchdog alarm: $e');
    }
  }

  static Future<void> saveTripState({
    required String busId,
    required String busName,
    required String busRoute,
    String driverName = '',
    DateTime? startTime,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_BgKeys.tripActive, true);
    await prefs.setInt(
      _BgKeys.tripStartMs,
      (startTime ?? DateTime.now()).millisecondsSinceEpoch,
    );
    await prefs.setString(_BgKeys.busId, busId);
    await prefs.setString(_BgKeys.busName, busName);
    await prefs.setString(_BgKeys.busRoute, busRoute);
    await prefs.setString(_BgKeys.driverName, driverName);
    await prefs.setBool(_BgKeys.isActive, true);
    // ✅ FIX: Trip start হলে explicit stop flag clear করো
    await prefs.setBool(_BgKeys.explicitStop, false);
    await prefs.setString('driver_selected_bus_id', busId);
    await prefs.setString('driver_selected_bus_name', busName);
    // Register watchdog alarm to detect if service gets killed by OEM optimizations
    await _registerWatchdogAlarm();
    debugPrint('[BackgroundService] saveTripState → busId=$busId');
  }

  static Future<void> clearTripState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_BgKeys.tripActive);
    await prefs.remove(_BgKeys.tripStartMs);
    await prefs.setBool(_BgKeys.isActive, false);
    // Cancel watchdog alarm when trip is explicitly stopped
    await _cancelWatchdogAlarm();
    debugPrint('[BackgroundService] clearTripState done');
  }

  static Future<bool> hasSavedTrip() async {
    final prefs = await SharedPreferences.getInstance();
    final isActive = prefs.getBool(_BgKeys.tripActive) ?? false;
    final busId = prefs.getString(_BgKeys.busId) ?? '';
    // ✅ FIX: explicit stop হলে saved trip নেই
    final explicitStop = prefs.getBool(_BgKeys.explicitStop) ?? false;
    return isActive && busId.isNotEmpty && !explicitStop;
  }

  static Future<Map<String, dynamic>> loadSavedTrip() async {
    final config = await loadStoredConfig();
    final prefs = await SharedPreferences.getInstance();
    final startMs = prefs.getInt(_BgKeys.tripStartMs);
    final startTime =
        startMs != null ? DateTime.fromMillisecondsSinceEpoch(startMs) : null;
    debugPrint('[BackgroundService] loadSavedTrip → busId=${config['busId']}');
    return {
      'busId': config['busId'] ?? '',
      'busName': config['busName'] ?? '',
      'busRoute': config['busRoute'] ?? '',
      'driverName': config['driverName'] ?? '',
      'startTime': startTime,
    };
  }

  Future<bool> startAndSave({
    required String busId,
    required String busName,
    required String busRoute,
    String driverName = '',
    DateTime? startTime,
  }) async {
    await BackgroundService.saveTripState(
      busId: busId,
      busName: busName,
      busRoute: busRoute,
      driverName: driverName,
      startTime: startTime,
    );
    final result = await start(
      busId: busId,
      busName: busName,
      busRoute: busRoute,
      driverName: driverName,
    );
    debugPrint('[BackgroundService] startAndSave → success=$result');
    return result;
  }

  Future<void> stopAndClear() async {
    await stop();
    await BackgroundService.clearTripState();
    debugPrint('[BackgroundService] stopAndClear done');
  }
}
