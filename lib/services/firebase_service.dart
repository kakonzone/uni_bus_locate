// lib/services/firebase_service.dart
// UniTrack — University Bus Live Tracking System
// Single source of truth for all Firebase Realtime Database operations.
// Covers: buses, users, trips — reads, writes, streams, and batch ops.
import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import '../models/bus_model.dart';
import '../models/location_model.dart';
import '../models/user_model.dart';
import 'firebase_globals.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DB PATH CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────
class _Path {
  static const String buses = 'buses';
  static const String users = 'users';
  static const String trips = 'trips';

  static const String busName = 'name';
  static const String busRoute = 'route';
  static const String busDriverName = 'driverName';
  static const String busTrackMode = 'trackMode';
  static const String busActive = 'active';
  static const String busLat = 'lat';
  static const String busLng = 'lng';
  static const String busSpeed = 'speed';
  static const String busHeading = 'heading';
  static const String busWatchCount = 'watchCount';
  static const String busLastUpdate = 'lastUpdate';

  static const String tripBusId = 'busId';
  static const String tripRoute = 'route';
  static const String tripStartTime = 'startTime';
  static const String tripEndTime = 'endTime';
  static const String tripStatus = 'status';

  static const String userId = 'id';
  static const String userBatch = 'batch';
  static const String userName = 'name';
  static const String userRole = 'role';
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULT WRAPPER
// ─────────────────────────────────────────────────────────────────────────────

class FirebaseResult<T> {
  final bool success;
  final T? data;
  final String? errorMessage;

  const FirebaseResult.success([this.data])
      : success = true,
        errorMessage = null;

  const FirebaseResult.failure(this.errorMessage)
      : success = false,
        data = null;
}

// ─────────────────────────────────────────────────────────────────────────────
// FIREBASE SERVICE
// ─────────────────────────────────────────────────────────────────────────────

class FirebaseService {
  FirebaseService._();
  static final FirebaseService instance = FirebaseService._();

  DatabaseReference get _root => globalDB.ref();

  // ✅ Bug #4 FIXED: 'buses' child path ব্যবহার করতে হবে
  DatabaseReference get _buses => _root.child(_Path.buses);
  DatabaseReference get _users => _root.child(_Path.users);
  DatabaseReference get _trips => _root.child(_Path.trips);

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION A — BUS READS (one-shot)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<FirebaseResult<List<BusModel>>> fetchAllBuses() async {
    try {
      final snap = await _buses.get();
      if (!snap.exists || snap.value == null) {
        return const FirebaseResult.success([]);
      }
      final raw = Map<String, dynamic>.from(snap.value as Map);
      final list = raw.entries
          .map(
            (e) => BusModel.fromMap(
              e.key,
              Map<String, dynamic>.from(e.value as Map),
            ),
          )
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      return FirebaseResult.success(list);
    } catch (e) {
      return FirebaseResult.failure('Failed to load buses: $e');
    }
  }

  Future<FirebaseResult<BusModel>> fetchBus(String busId) async {
    try {
      final snap = await _buses.child(busId).get();
      if (!snap.exists || snap.value == null) {
        return const FirebaseResult.failure('Bus not found.');
      }
      final bus = BusModel.fromMap(
        busId,
        Map<String, dynamic>.from(snap.value as Map),
      );
      return FirebaseResult.success(bus);
    } catch (e) {
      return FirebaseResult.failure('Failed to load bus: $e');
    }
  }

  Future<FirebaseResult<List<BusModel>>> fetchActiveBuses() async {
    try {
      final snap =
          await _buses.orderByChild(_Path.busActive).equalTo(true).get();
      if (!snap.exists || snap.value == null) {
        return const FirebaseResult.success([]);
      }
      final raw = Map<String, dynamic>.from(snap.value as Map);
      final list = raw.entries
          .map(
            (e) => BusModel.fromMap(
              e.key,
              Map<String, dynamic>.from(e.value as Map),
            ),
          )
          .toList();
      return FirebaseResult.success(list);
    } catch (e) {
      return FirebaseResult.failure('Failed to load active buses: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION B — BUS STREAMS (real-time)
  // ═══════════════════════════════════════════════════════════════════════════

  Stream<List<BusModel>> watchAllBuses() {
    return _buses.onValue.map((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) return [];
      final raw = Map<String, dynamic>.from(event.snapshot.value as Map);
      return raw.entries
          .map(
            (e) => BusModel.fromMap(
              e.key,
              Map<String, dynamic>.from(e.value as Map),
            ),
          )
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    });
  }

  Stream<BusModel?> watchBus(String busId) {
    return _buses.child(busId).onValue.map((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) return null;
      return BusModel.fromMap(
        busId,
        Map<String, dynamic>.from(event.snapshot.value as Map),
      );
    });
  }

  Stream<LocationModel?> watchBusLocation(String busId) {
    return _buses.child(busId).onValue.map((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) return null;
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      return LocationModel.fromBusMap(data);
    });
  }

  Stream<List<BusModel>> watchActiveBuses() {
    return _buses.orderByChild(_Path.busActive).equalTo(true).onValue.map((
      event,
    ) {
      if (!event.snapshot.exists || event.snapshot.value == null) return [];
      final raw = Map<String, dynamic>.from(event.snapshot.value as Map);
      return raw.entries
          .map(
            (e) => BusModel.fromMap(
              e.key,
              Map<String, dynamic>.from(e.value as Map),
            ),
          )
          .toList();
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION C — BUS WRITES (driver-side)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<FirebaseResult<void>> updateBusLocation(
    String busId,
    LocationModel location,
  ) async {
    try {
      await _buses.child(busId).update({
        _Path.busLat: location.lat,
        _Path.busLng: location.lng,
        _Path.busSpeed: location.speedKmh,
        _Path.busHeading: location.heading,
        _Path.busLastUpdate: location.timestamp.millisecondsSinceEpoch,
      });
      return const FirebaseResult.success();
    } catch (e) {
      return FirebaseResult.failure('Location update failed: $e');
    }
  }

  Future<FirebaseResult<void>> updateBusActive(
    String busId,
    bool active,
  ) async {
    try {
      await _buses.child(busId).update({_Path.busActive: active});
      return const FirebaseResult.success();
    } catch (e) {
      return FirebaseResult.failure('Could not update bus status: $e');
    }
  }

  Future<FirebaseResult<void>> updateBusDriverName(
    String busId,
    String driverName,
  ) async {
    try {
      await _buses.child(busId).update({_Path.busDriverName: driverName});
      return const FirebaseResult.success();
    } catch (e) {
      return FirebaseResult.failure('Could not update driver name: $e');
    }
  }

  Future<FirebaseResult<void>> updateBusTrackMode(
    String busId,
    String trackMode,
  ) async {
    try {
      await _buses.child(busId).update({_Path.busTrackMode: trackMode});
      return const FirebaseResult.success();
    } catch (e) {
      return FirebaseResult.failure('Could not update track mode: $e');
    }
  }

  Future<FirebaseResult<void>> adjustWatchCount(
    String busId,
    int delta,
  ) async {
    try {
      final ref = _buses.child(busId).child(_Path.busWatchCount);
      await ref.runTransaction((current) {
        final count = (current as int? ?? 0) + delta;
        return Transaction.success(count.clamp(0, 99999));
      });
      return const FirebaseResult.success();
    } catch (e) {
      return FirebaseResult.failure('Could not update watch count: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION D — TRIP MANAGEMENT
  // ═══════════════════════════════════════════════════════════════════════════

  Future<FirebaseResult<String>> startTrip({
    required String busId,
    required String route,
  }) async {
    try {
      final tripRef = _trips.push();
      final now = DateTime.now().millisecondsSinceEpoch;
      await tripRef.set({
        _Path.tripBusId: busId,
        _Path.tripRoute: route,
        _Path.tripStartTime: now,
        _Path.tripEndTime: null,
        _Path.tripStatus: 'active',
      });
      await updateBusActive(busId, true);
      return FirebaseResult.success(tripRef.key!);
    } catch (e) {
      return FirebaseResult.failure('Could not start trip: $e');
    }
  }

  Future<FirebaseResult<void>> endTrip({
    required String tripId,
    required String busId,
  }) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _trips.child(tripId).update({
        _Path.tripEndTime: now,
        _Path.tripStatus: 'completed',
      });
      await updateBusActive(busId, false);
      return const FirebaseResult.success();
    } catch (e) {
      return FirebaseResult.failure('Could not end trip: $e');
    }
  }

  Future<FirebaseResult<List<TripModel>>> fetchTripsForBus(String busId) async {
    try {
      final snap =
          await _trips.orderByChild(_Path.tripBusId).equalTo(busId).get();
      if (!snap.exists || snap.value == null) {
        return const FirebaseResult.success([]);
      }
      final raw = Map<String, dynamic>.from(snap.value as Map);
      final list = raw.entries
          .map(
            (e) => TripModel.fromMap(
              id: e.key,
              data: Map<String, dynamic>.from(e.value as Map),
            ),
          )
          .toList()
        ..sort((a, b) => b.startTime.compareTo(a.startTime));
      return FirebaseResult.success(list);
    } catch (e) {
      return FirebaseResult.failure('Could not load trip history: $e');
    }
  }

  Stream<TripModel?> watchActiveTrip(String busId) {
    return _trips.orderByChild(_Path.tripBusId).equalTo(busId).onValue.map((
      event,
    ) {
      if (!event.snapshot.exists || event.snapshot.value == null) return null;
      final raw = Map<String, dynamic>.from(event.snapshot.value as Map);
      for (final e in raw.entries) {
        final data = Map<String, dynamic>.from(e.value as Map);
        if (data[_Path.tripStatus] == 'active') {
          return TripModel.fromMap(id: e.key, data: data);
        }
      }
      return null;
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION E — USER READS / WRITES
  // ═══════════════════════════════════════════════════════════════════════════

  Future<FirebaseResult<UserModel>> fetchUser(String uid) async {
    try {
      final snap = await _users.child(uid).get();
      if (!snap.exists || snap.value == null) {
        return const FirebaseResult.failure('User not found.');
      }
      final user = UserModel.fromMap(
        uid,
        Map<String, dynamic>.from(snap.value as Map),
      );
      return FirebaseResult.success(user);
    } catch (e) {
      return FirebaseResult.failure('Could not load user: $e');
    }
  }

  Future<FirebaseResult<void>> saveUser(UserModel user) async {
    try {
      await _users.child(user.uid).set(user.toMap());
      return const FirebaseResult.success();
    } catch (e) {
      return FirebaseResult.failure('Could not save user: $e');
    }
  }

  Future<FirebaseResult<void>> updateUser(
    String uid,
    Map<String, dynamic> fields,
  ) async {
    try {
      await _users.child(uid).update(fields);
      return const FirebaseResult.success();
    } catch (e) {
      return FirebaseResult.failure('Could not update user: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION F — TEACHER STATS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<FirebaseResult<Map<String, int>>> fetchAllWatchCounts() async {
    try {
      final snap = await _buses.get();
      if (!snap.exists || snap.value == null) {
        return const FirebaseResult.success({});
      }
      final raw = Map<String, dynamic>.from(snap.value as Map);
      final result = <String, int>{};
      for (final e in raw.entries) {
        final data = Map<String, dynamic>.from(e.value as Map);
        result[e.key] = (data[_Path.busWatchCount] as int? ?? 0);
      }
      return FirebaseResult.success(result);
    } catch (e) {
      return FirebaseResult.failure('Could not load watch counts: $e');
    }
  }

  Stream<Map<String, int>> watchAllWatchCounts() {
    return _buses.onValue.map((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) return {};
      final raw = Map<String, dynamic>.from(event.snapshot.value as Map);
      return {
        for (final e in raw.entries)
          e.key: (Map<String, dynamic>.from(e.value as Map)[_Path.busWatchCount]
                  as int? ??
              0),
      };
    });
  }

  Future<int> countActiveBuses() async {
    final result = await fetchActiveBuses();
    return result.data?.length ?? 0;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION G — ADMIN / SETUP
  // ═══════════════════════════════════════════════════════════════════════════

  Future<FirebaseResult<String>> createBus({
    required String name,
    required String route,
    String driverName = '',
    String trackMode = 'phone',
  }) async {
    try {
      final ref = _buses.push();
      await ref.set({
        _Path.busName: name,
        _Path.busRoute: route,
        _Path.busDriverName: driverName,
        _Path.busTrackMode: trackMode,
        _Path.busActive: false,
        _Path.busLat: 0.0,
        _Path.busLng: 0.0,
        _Path.busSpeed: 0.0,
        _Path.busHeading: 0.0,
        _Path.busWatchCount: 0,
        _Path.busLastUpdate: ServerValue.timestamp,
      });
      return FirebaseResult.success(ref.key!);
    } catch (e) {
      return FirebaseResult.failure('Could not create bus: $e');
    }
  }

  Future<FirebaseResult<void>> deleteBus(String busId) async {
    try {
      await _buses.child(busId).remove();
      return const FirebaseResult.success();
    } catch (e) {
      return FirebaseResult.failure('Could not delete bus: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION H — CONNECTIVITY HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<bool> get isConnected async {
    try {
      final snap = await globalDB.ref('.info/connected').get();
      return snap.value == true;
    } catch (_) {
      return false;
    }
  }

  Stream<bool> get connectionStream {
    return globalDB
        .ref('.info/connected')
        .onValue
        .map((e) => e.snapshot.value == true);
  }

  static void enableOfflinePersistence() {
    globalDB.setPersistenceEnabled(true);
    globalDB.ref(_Path.buses).keepSynced(true);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TRIP MODEL
// ─────────────────────────────────────────────────────────────────────────────

class TripModel {
  final String id;
  final String busId;
  final String route;
  final DateTime startTime;
  final DateTime? endTime;
  final String status;

  const TripModel({
    required this.id,
    required this.busId,
    required this.route,
    required this.startTime,
    this.endTime,
    required this.status,
  });

  bool get isActive => status == 'active';

  Duration? get duration {
    final end = endTime ?? (isActive ? DateTime.now() : null);
    if (end == null) return null;
    return end.difference(startTime);
  }

  factory TripModel.fromMap({
    required String id,
    required Map<String, dynamic> data,
  }) {
    return TripModel(
      id: id,
      busId: data['busId'] as String? ?? '',
      route: data['route'] as String? ?? '',
      startTime: DateTime.fromMillisecondsSinceEpoch(
        data['startTime'] as int? ?? 0,
      ),
      endTime: data['endTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(data['endTime'] as int)
          : null,
      status: data['status'] as String? ?? 'active',
    );
  }

  Map<String, dynamic> toMap() => {
        'busId': busId,
        'route': route,
        'startTime': startTime.millisecondsSinceEpoch,
        'endTime': endTime?.millisecondsSinceEpoch,
        'status': status,
      };
}
