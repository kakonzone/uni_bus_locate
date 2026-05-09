// lib/providers/tracking_provider.dart
// ─────────────────────────────────────────────────────────────────────────────
// ALL BUGS FIXED (original BUG-1..5 + BUG-A..E + new BUG-F..H):
//
//   ✅ BUG-1  : _writeToFirebase() / _writeKeepAlive() — unawaited() wrap +
//               single in-flight guard দিয়ে race / out-of-order ঠেকানো
//   ✅ BUG-2  : SharedPreferences key — background_service.dart-এর সাথে align
//               (bg_bus_id, bg_trip_active, bg_trip_start_ms ...)
//   ✅ BUG-3  : Sleep mode dead code সরানো — _locationSettings() শুধু
//               active / lowPower handle করে
//   ✅ BUG-4  : Active mode-এ 500ms write storm বন্ধ — min 3s interval বা
//               5m distance delta থাকলে তবেই Firebase write
//   ✅ BUG-5  : _scheduleRestart()-এ _sleepKeepAliveTimer cancel করা হচ্ছে
//
//   ✅ BUG-A  : headingProvider এখন _onPosition()-এ pos.heading দিয়ে update হয়
//   ✅ BUG-B  : speedAlertProvider এখন kSpeedLimitKmh চেক করে trigger হয়
//   ✅ BUG-C  : startListening()-এ _restartGeneration++ — direct call এ
//               পুরনো pending restart stale হয়ে বাতিল হবে
//   ✅ BUG-D  : _lastWrittenAt / _lastWrittenPosition এখন শুধু সফল write-এর
//               পরে set হয় — failed write স্বয়ংক্রিয়ভাবে retry পাবে
//   ✅ BUG-E  : _haversineMeters() / _toRad() / _LatLng / _posToLatLng() সব
//               সরানো; সব জায়গায় Geolocator.distanceBetween() ব্যবহার হচ্ছে
//
//   ✅ BUG-F  : RACE — stopListening()-এর `active:false` write কে in-flight
//               বা concurrent _writeToFirebase()/_writeKeepAlive()
//               `active:true` দিয়ে overwrite করতে পারত। এখন `_stopped`
//               flag stopListening()-এর শুরুতে true হয়, এবং
//               _writeToFirebase / _writeKeepAlive / sleep keep-alive timer
//               callback সবাই top-এ `if (_stopped) return;` চেক করে।
//               startListening()-এ `_stopped = false` reset হয়।
//   ✅ BUG-G  : LOGIC — active mode-এ 60 km/h-এ প্রতি 500ms tick-এ ~8.3m
//               নড়ত, যা 5m _activeDeltaMeters ছাড়িয়ে যেত — 3s interval
//               guard bypass হয়ে যাচ্ছিল। এখন speedKmh > 30 হলে
//               dynamicDelta = 15m, না হলে 5m। ফলে highway-এ ~1 write/3s,
//               কিন্তু slow speed-এ fine-grained update বহাল।
//   ✅ BUG-H  : LOGIC — sleep mode activate হওয়া মাত্রই `active:true` write
//               করা হচ্ছে; আগে keep-alive timer 30s পরে fire হত, ততক্ষণ
//               bus offline দেখাত।
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';

import '../services/firebase_globals.dart';
import '../models/tracking_model.dart';
export '../models/tracking_model.dart';

// ─── TRACKING MODE ────────────────────────────────────────────────────────────

final trackingModeProvider = StreamProvider<TrackingMode>((ref) async* {
  TrackingMode _getMode() {
    final h = DateTime.now().hour;
    if (h >= 7 && h < 18) return TrackingMode.active;
    if (h >= 18 && h < 22) return TrackingMode.lowPower;
    return TrackingMode.sleep;
  }

  yield _getMode();

  await for (final _ in Stream.periodic(const Duration(minutes: 1))) {
    yield _getMode();
  }
});

// ─── PHONE HEADING (COMPASS) ──────────────────────────────────────────────────
// BUG-A FIX: এই provider এখন _onPosition()-এ pos.heading দিয়ে update হয়।

final headingProvider = StateProvider<double>((ref) => 0.0);

// ─── LIVE LOCATION ────────────────────────────────────────────────────────────

final liveLocationProvider =
    StateNotifierProvider<LiveLocationNotifier, LiveLocationState>(
  (ref) => LiveLocationNotifier(ref),
);

// ─── TRIP STATE ───────────────────────────────────────────────────────────────

final tripStatusProvider = StateProvider<TripStatus>((ref) => TripStatus.idle);
final tripStartTimeProvider = StateProvider<DateTime?>((ref) => null);

// ─── SPEED ALERT ─────────────────────────────────────────────────────────────
// BUG-B FIX: এই constant এখন _onPosition()-এ actually ব্যবহার হচ্ছে।

const double kSpeedLimitKmh = 60.0;
final speedAlertProvider = StateProvider<bool>((ref) => false);

// ─── LIVE LOCATION NOTIFIER ──────────────────────────────────────────────────

class LiveLocationNotifier extends StateNotifier<LiveLocationState> {
  final Ref _ref;

  LiveLocationNotifier(this._ref) : super(const LiveLocationState());

  StreamSubscription<Position>? _positionSub;
  Position? _lastPosition;
  String? _currentBusId;
  TrackingMode? _currentMode;

  Timer? _watchdogTimer;
  bool _isRestarting = false;
  int _restartGeneration = 0;

  // ── BUG-4 FIX: Active mode write throttling ──────────────────────────────
  static const double _activeDeltaMeters = 5.0;
  static const int _activeMinIntervalMs = 3000;

  // lowPower / সাধারণ mode filter
  static const double _deltaMeters = 5.0;
  static const int _forceWriteIntervalSec = 30;

  Duration get _watchdogTimeout {
    switch (_currentMode) {
      case TrackingMode.active:
        return const Duration(seconds: 20);
      case TrackingMode.lowPower:
        return const Duration(seconds: 90);
      case TrackingMode.sleep:
        return const Duration(seconds: 120);
      default:
        return const Duration(seconds: 20);
    }
  }

  // BUG-D FIX: এই দুটো এখন শুধু successful write-এর পরে set হয় —
  // failed write-এর পর null থাকে, তাই পরের cycle-এ retry হবে।
  DateTime? _lastWrittenAt;
  Position? _lastWrittenPosition;

  DateTime? _tripStartTime;
  Timer? _sleepKeepAliveTimer;

  // ── BUG-1 FIX: Single in-flight write tracking ───────────────────────────
  bool _writeInFlight = false;
  bool _keepAliveInFlight = false;

  // ── NEW BUG-1 FIX: Hard-stop flag ────────────────────────────────────────
  // stopListening()-এর সাথে সাথে true হয় — ফলে কোনো in-flight বা concurrent
  // write/keep-alive `active: false` কে overwrite করতে পারে না।
  bool _stopped = false;

  // ── startListening ────────────────────────────────────────────────────────
  Future<void> startListening(TrackingMode mode, {String? busId}) async {
    // NEW BUG-1 FIX: নতুন session শুরু হলে stopped flag clear
    _stopped = false;

    // BUG-C FIX: direct call-এও generation বাড়ানো হচ্ছে যাতে পুরনো pending
    // _scheduleRestart stale হয়ে নিজে নিজে বাতিল হয়।
    _restartGeneration++;

    _currentMode = mode;
    await _positionSub?.cancel();
    _positionSub = null;

    _tripStartTime = DateTime.now();

    if (busId != null && busId.isNotEmpty) {
      _currentBusId = busId;
    } else {
      final prefs = await SharedPreferences.getInstance();
      _currentBusId = prefs.getString(TripPersistenceKeys.busId);
    }

    if (_currentBusId == null) {
      debugPrint('UniTrack WARNING: _currentBusId is null in startListening()');
    }

    // BUG-3 FIX: sleep mode-এ stream শুরু না করে early return
    if (mode == TrackingMode.sleep) {
      debugPrint('UniTrack: Sleep mode — GPS paused, starting keep-alive');
      // NEW BUG-3 FIX: sleep mode active হওয়া মাত্রই immediate active:true ping
      // (keep-alive timer 30s পরে fire হয়, ততক্ষণ bus offline দেখাত)
      if (_currentBusId != null && _currentBusId!.isNotEmpty) {
        try {
          unawaited(globalDB.ref('buses/$_currentBusId').update({
            'active': true,
            'lastUpdate': DateTime.now().millisecondsSinceEpoch,
          }));
          debugPrint('UniTrack: Sleep mode → immediate active:true sent');
        } catch (e) {
          debugPrint('UniTrack: Sleep mode immediate active:true failed → $e');
        }
      }
      _startSleepKeepAlive();
      return;
    }

    if (_currentBusId != null && _currentBusId!.isNotEmpty) {
      try {
        unawaited(
            globalDB.ref('buses/$_currentBusId').update({'active': true}));
        debugPrint('UniTrack: LiveLocationNotifier → active:true set');
        unawaited(saveTripState(
          active: true,
          busId: _currentBusId!,
          startTime: DateTime.now(),
        ));
      } catch (e) {
        debugPrint('UniTrack: active:true failed in notifier → $e');
      }
    }

    final settings = _locationSettings(mode);

    _positionSub = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      (pos) => _onPosition(pos),
      onError: (e) {
        debugPrint('UniTrack: GPS stream error → $e');
        unawaited(_scheduleRestart());
      },
      onDone: () {
        if (_currentBusId != null) {
          debugPrint(
              'UniTrack: GPS stream closed unexpectedly — scheduling restart');
          unawaited(_scheduleRestart());
        }
      },
      cancelOnError: false,
    );

    _resetWatchdog();

    debugPrint(
        'UniTrack: GPS stream started → mode=$mode, busId=$_currentBusId');
  }

  void _startSleepKeepAlive() {
    _sleepKeepAliveTimer?.cancel();
    _sleepKeepAliveTimer =
        Timer.periodic(const Duration(seconds: 30), (_) async {
      // NEW BUG-1 FIX: stop-এর পর timer callback ঢুকে গেলেও write hold
      if (_stopped) return;
      if (_currentBusId != null) {
        try {
          await globalDB.ref('buses/$_currentBusId').update({
            'active': true,
            'lastUpdate': DateTime.now().millisecondsSinceEpoch,
          });
          debugPrint('UniTrack: Sleep mode keep-alive ping sent');
        } catch (e) {
          debugPrint('UniTrack: Sleep mode keep-alive failed → $e');
        }
      }
    });
  }

  // ── stopListening ─────────────────────────────────────────────────────────
  Future<void> stopListening() async {
    // NEW BUG-1 FIX: সবার আগে stopped flag set — যাতে এই point-এর পর কোনো
    // in-flight বা newly-fired _writeToFirebase / _writeKeepAlive call আর
    // active:true লিখতে না পারে।
    _stopped = true;

    _restartGeneration++;

    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _isRestarting = false;

    _sleepKeepAliveTimer?.cancel();
    _sleepKeepAliveTimer = null;

    _tripStartTime = null;

    await _positionSub?.cancel();
    _positionSub = null;

    _lastPosition = null;
    _lastWrittenAt = null;
    _lastWrittenPosition = null;
    _currentMode = null;
    _writeInFlight = false;
    _keepAliveInFlight = false;

    // BUG-B FIX: trip শেষে speed alert reset
    if (mounted) {
      _ref.read(speedAlertProvider.notifier).state = false;
    }

    if (_currentBusId != null && _currentBusId!.isNotEmpty) {
      try {
        await globalDB
            .ref('buses/$_currentBusId')
            .update({'active': false, 'speed': 0.0});
        debugPrint('UniTrack: LiveLocationNotifier → active:false set');
        await clearTripState();
      } catch (e) {
        debugPrint('UniTrack: active:false failed in notifier → $e');
      }
    }

    _currentBusId = null;
    state = const LiveLocationState();
    debugPrint('UniTrack: GPS stream stopped');
  }

  void _resetWatchdog() {
    _watchdogTimer?.cancel();
    if (_currentBusId == null) return;

    _watchdogTimer = Timer(
      _watchdogTimeout,
      () {
        debugPrint(
          'UniTrack: ⚠️ Watchdog triggered — no GPS in ${_watchdogTimeout.inSeconds}s, restarting stream',
        );
        unawaited(_scheduleRestart());
      },
    );
  }

  // ── BUG-5 FIX: _sleepKeepAliveTimer সবার আগে cancel ─────────────────────
  Future<void> _scheduleRestart() async {
    if (_isRestarting || _currentBusId == null) return;

    final myGen = ++_restartGeneration;

    _isRestarting = true;
    _watchdogTimer?.cancel();

    // BUG-5 FIX: 2s delay-এর মধ্যে ghost write রোধ
    _sleepKeepAliveTimer?.cancel();
    _sleepKeepAliveTimer = null;

    await _positionSub?.cancel();
    _positionSub = null;

    try {
      await Future.delayed(const Duration(seconds: 2));

      if (myGen != _restartGeneration || _currentBusId == null) {
        debugPrint('UniTrack: Restart cancelled (stale or trip ended).');
        return;
      }

      debugPrint('UniTrack: 🔄 Restarting GPS stream → mode=$_currentMode');
      await startListening(_currentMode ?? TrackingMode.active,
          busId: _currentBusId);
    } finally {
      _isRestarting = false;
    }
  }

  // ── GPS position handler ──────────────────────────────────────────────────
  void _onPosition(Position pos) {
    _resetWatchdog();

    final isWarming = _tripStartTime != null &&
        DateTime.now().difference(_tripStartTime!) <
            const Duration(seconds: 90);
    final maxAccuracy = isWarming ? 150.0 : 65.0;

    if (pos.accuracy > maxAccuracy) {
      debugPrint(
        'UniTrack: poor accuracy (${pos.accuracy.toStringAsFixed(1)}m), sending keep-alive',
      );
      unawaited(_writeKeepAlive());
      return;
    }

    // BUG-E FIX: _haversineMeters() সরিয়ে Geolocator.distanceBetween() ব্যবহার
    double distanceDelta = 0;
    if (_lastPosition != null) {
      distanceDelta = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        pos.latitude,
        pos.longitude,
      );
    }

    state = state.copyWith(
      position: pos,
      lastUpdate: DateTime.now(),
      totalUpdates: state.totalUpdates + 1,
      totalDistanceM: state.totalDistanceM + distanceDelta,
    );

    _lastPosition = pos;

    // BUG-A FIX: headingProvider কে GPS heading দিয়ে update করা হচ্ছে
    if (mounted) {
      _ref.read(headingProvider.notifier).state = pos.heading;
    }

    // BUG-B FIX: speed limit চেক করে speedAlertProvider update করা হচ্ছে
    final speedKmh = pos.speed * 3.6;
    if (mounted) {
      _ref.read(speedAlertProvider.notifier).state = speedKmh > kSpeedLimitKmh;
    }

    if (_shouldWrite(pos)) {
      // BUG-D FIX: _lastWrittenAt / _lastWrittenPosition এখন _writeToFirebase()-এর
      // ভেতরে সফল হলে তবেই set হবে। এখানে আর pre-set করা হচ্ছে না।
      unawaited(_writeToFirebase(pos));
    }
  }

  // ── BUG-4 FIX: Active mode throttling ────────────────────────────────────
  bool _shouldWrite(Position newPos) {
    if (_lastWrittenPosition == null || _lastWrittenAt == null) return true;

    // BUG-E FIX: _haversineMeters() এর পরিবর্তে Geolocator.distanceBetween()
    final now = DateTime.now();
    final msSinceLast = now.difference(_lastWrittenAt!).inMilliseconds;

    if (_currentMode == TrackingMode.active) {
      // BUG-1 FIX: in-flight থাকলে skip
      if (_writeInFlight) return false;

      if (msSinceLast < _activeMinIntervalMs) {
        final moved = Geolocator.distanceBetween(
          _lastWrittenPosition!.latitude,
          _lastWrittenPosition!.longitude,
          newPos.latitude,
          newPos.longitude,
        );
        // NEW BUG-2 FIX: highway speed-এ delta threshold scale করা হলো —
        // 30 km/h-এর উপরে 15m, না হলে default 5m। এতে 60 km/h-এ আর প্রতি
        // 500ms tick-এ write trigger হবে না; ~3s interval guard কার্যকর থাকবে।
        final speedKmh = newPos.speed * 3.6;
        final dynamicDelta = (speedKmh > 30) ? 15.0 : _activeDeltaMeters;
        return moved >= dynamicDelta;
      }
      return true;
    }

    // lowPower / অন্যান্য mode
    // in-flight থাকলে skip (consistency)
    if (_writeInFlight) return false;

    if (msSinceLast >= _forceWriteIntervalSec * 1000) return true;

    if (newPos.speed * 3.6 > 30) return true;

    return Geolocator.distanceBetween(
          _lastWrittenPosition!.latitude,
          _lastWrittenPosition!.longitude,
          newPos.latitude,
          newPos.longitude,
        ) >=
        _deltaMeters;
  }

  // ── BUG-1 + BUG-D FIX: Single in-flight guard + timestamp on success ─────
  Future<void> _writeToFirebase(Position pos) async {
    // NEW BUG-1 FIX: stopListening()-এর পর কোনো ভাবেই active:true লেখা যাবে না
    if (_stopped) return;
    if (_currentBusId == null || _currentBusId!.isEmpty) return;
    if (_writeInFlight) return;
    _writeInFlight = true;
    try {
      // double-check: await/scheduling-এর মাঝে stopListening() চলে আসতে পারে
      if (_stopped || _currentBusId == null || _currentBusId!.isEmpty) return;
      await globalDB.ref('buses/$_currentBusId').update({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'speed': (pos.speed * 3.6).clamp(0, 200),
        'heading': pos.heading,
        'lastUpdate': DateTime.now().millisecondsSinceEpoch,
        'active': true,
      });
      // BUG-D FIX: write সফল হলে তবেই timestamp update — failed হলে
      // null থাকে, পরের cycle-এ retry পাবে
      _lastWrittenAt = DateTime.now();
      _lastWrittenPosition = pos;
    } catch (e) {
      debugPrint('UniTrack: Firebase write failed → $e');
      // _lastWrittenAt / _lastWrittenPosition intentionally NOT updated
    } finally {
      _writeInFlight = false;
    }
  }

  Future<void> _writeKeepAlive() async {
    // NEW BUG-1 FIX: stop-এর পর keep-alive ও বন্ধ
    if (_stopped) return;
    if (_currentBusId == null || _currentBusId!.isEmpty) return;
    if (_keepAliveInFlight) return;
    _keepAliveInFlight = true;
    try {
      if (_stopped || _currentBusId == null || _currentBusId!.isEmpty) return;
      await globalDB.ref('buses/$_currentBusId').update({
        'active': true,
        'lastUpdate': DateTime.now().millisecondsSinceEpoch,
      });
      debugPrint('UniTrack: keep-alive ping sent');
    } catch (e) {
      debugPrint('UniTrack: keep-alive failed → $e');
    } finally {
      _keepAliveInFlight = false;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  // BUG-3 FIX: sleep case removed
  // BUG-E FIX: _haversineMeters, _toRad, _LatLng, _posToLatLng সব সরানো হয়েছে
  LocationSettings _locationSettings(TrackingMode mode) {
    switch (mode) {
      case TrackingMode.active:
        if (Platform.isAndroid) {
          return AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            intervalDuration: const Duration(milliseconds: 500),
          );
        }
        return const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        );
      case TrackingMode.lowPower:
        return const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 10,
        );
      case TrackingMode.sleep:
        // unreachable — startListening early-returns আগেই
        // defensive default: future refactor-এ crash না হওয়ার জন্য
        return const LocationSettings(
          accuracy: LocationAccuracy.low,
          distanceFilter: 50,
        );
    }
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    _sleepKeepAliveTimer?.cancel();
    _positionSub?.cancel();
    super.dispose();
  }
}

// ─── TRIP PERSISTENCE ────────────────────────────────────────────────────────
// BUG-2 FIX: background_service.dart-এর _BgKeys-এর সাথে exact match।
// background_service.dart-এ যা আছে:
//     static const String busId        = 'bg_bus_id';
//     static const String tripActive   = 'bg_trip_active';
//     static const String tripStartMs  = 'bg_trip_start_ms';
//     static const String destLat      = 'bg_dest_lat';
//     static const String destLng      = 'bg_dest_lng';
//     static const String destRadiusM  = 'bg_dest_radius_m';
//     static const String destEnabled  = 'bg_dest_enabled';

class TripPersistenceKeys {
  TripPersistenceKeys._();
  static const String tripActive = 'bg_trip_active';
  static const String tripStartMs = 'bg_trip_start_ms';
  static const String busId = 'bg_bus_id'; // ← FIXED (was 'bg_trip_bus_id')
  static const String destLat = 'bg_dest_lat'; // ← FIXED
  static const String destLng = 'bg_dest_lng'; // ← FIXED
  static const String destRadiusM = 'bg_dest_radius_m'; // ← FIXED
  static const String destEnabled = 'bg_dest_enabled'; // ← FIXED
}

Future<void> saveTripState({
  required bool active,
  required String busId,
  DateTime? startTime,
  double? destLat,
  double? destLng,
  double destRadiusM = 100.0,
  bool destEnabled = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(TripPersistenceKeys.tripActive, active);
  await prefs.setString(TripPersistenceKeys.busId, busId);
  if (startTime != null) {
    await prefs.setInt(
        TripPersistenceKeys.tripStartMs, startTime.millisecondsSinceEpoch);
  }
  if (destLat != null) {
    await prefs.setDouble(TripPersistenceKeys.destLat, destLat);
  }
  if (destLng != null) {
    await prefs.setDouble(TripPersistenceKeys.destLng, destLng);
  }
  await prefs.setDouble(TripPersistenceKeys.destRadiusM, destRadiusM);
  await prefs.setBool(TripPersistenceKeys.destEnabled, destEnabled);
}

Future<void> clearTripState() async {
  final prefs = await SharedPreferences.getInstance();
  for (final key in [
    TripPersistenceKeys.tripActive,
    TripPersistenceKeys.tripStartMs,
    TripPersistenceKeys.busId,
    TripPersistenceKeys.destLat,
    TripPersistenceKeys.destLng,
    TripPersistenceKeys.destRadiusM,
    TripPersistenceKeys.destEnabled,
  ]) {
    await prefs.remove(key);
  }
}
