// lib/providers/bus_providers.dart
// UniTrack — Riverpod Providers for Bus Data
// ✅ BUG 4: latlong2 LatLng consistently use করা হয়েছে (google_maps_flutter LatLng নয়)
// ✅ BUG 5: routeStopsProvider এ async*/await for এর বদলে StreamController + cancel() pattern
// ✅ BUG 6: stoppagesProvider এ error swallow না করে controller.addError()

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/bus_model.dart';
import '../services/firebase_globals.dart';
import '../models/stoppage_model.dart';
import '../utils/retry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Connection state provider
// ─────────────────────────────────────────────────────────────────────────────

final firebaseConnectionProvider = StreamProvider<bool>((ref) {
  return globalDB.ref('.info/connected').onValue.map((event) {
    return event.snapshot.value as bool? ?? false;
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Database Provider
// ─────────────────────────────────────────────────────────────────────────────

final databaseProvider = Provider<DatabaseReference>((ref) {
  return globalDB.ref();
});

// ─────────────────────────────────────────────────────────────────────────────
// Internal helper: converts Firebase snapshot to List<BusModel>
// ─────────────────────────────────────────────────────────────────────────────

List<BusModel> _parseBuses(DataSnapshot snapshot) {
  final data = snapshot.value as Map<dynamic, dynamic>?;
  if (data == null || data.isEmpty) return [];

  final buses = <BusModel>[];
  for (final entry in data.entries) {
    try {
      final busData = entry.value as Map<dynamic, dynamic>?;
      if (busData == null) continue;
      buses.add(BusModel.fromMap(
        entry.key as String,
        Map<String, dynamic>.from(busData),
      ));
    } catch (e, st) {
      debugPrint(
        'UniTrack [bus_providers]: Skipping malformed bus "${entry.key}" → $e',
      );
      debugPrint('$st');
      continue;
    }
  }
  return buses;
}

// ─────────────────────────────────────────────────────────────────────────────
// busesListProvider — StreamProvider with retry logic
// ─────────────────────────────────────────────────────────────────────────────

final busesListProvider = StreamProvider<List<BusModel>>((ref) {
  final controller = StreamController<List<BusModel>>();

  StreamSubscription<DatabaseEvent>? subscription;
  bool isDisposed = false;
  int retryCount = 0;
  Timer? retryTimer;

  void subscribe() {
    subscription?.cancel();

    subscription = globalDB.ref('buses').onValue.listen(
      (event) {
        if (isDisposed) return;
        retryCount = 0;
        final buses = _parseBuses(event.snapshot);
        if (!controller.isClosed) controller.add(buses);
      },
      onError: (error) {
        if (isDisposed) return;
        debugPrint('UniTrack [bus_providers]: Firebase error → $error');

        if (retryCount < defaultStreamRetryConfig.maxRetries) {
          retryCount++;
          debugPrint(
              'UniTrack [bus_providers]: Retrying ($retryCount/${defaultStreamRetryConfig.maxRetries})...');
          retryTimer?.cancel();
          retryTimer = Timer(defaultStreamRetryConfig.retryDelay, subscribe);
        }

        if (!controller.isClosed) {
          controller.addError(error, StackTrace.current);
        }
      },
    );
  }

  subscribe();

  ref.onDispose(() {
    isDisposed = true;
    subscription?.cancel();
    retryTimer?.cancel();
    controller.close();
  });

  return controller.stream;
});

// ─────────────────────────────────────────────────────────────────────────────
// busListProvider alias
// ─────────────────────────────────────────────────────────────────────────────

final busListProvider = busesListProvider;

// ─────────────────────────────────────────────────────────────────────────────
// busDetailProvider — single bus by ID
// ─────────────────────────────────────────────────────────────────────────────

final busDetailProvider =
    StreamProvider.family<BusModel?, String>((ref, busId) {
  final controller = StreamController<BusModel?>();
  StreamSubscription<DatabaseEvent>? subscription;

  subscription = globalDB.ref('buses/$busId').onValue.listen(
    (event) {
      if (controller.isClosed) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        controller.add(null);
        return;
      }
      try {
        final bus = BusModel.fromMap(busId, Map<String, dynamic>.from(data));
        if (!controller.isClosed) controller.add(bus);
      } catch (e) {
        if (!controller.isClosed) controller.add(null);
      }
    },
    onError: (error) {
      debugPrint('UniTrack [busDetailProvider]: Error for $busId → $error');
      if (!controller.isClosed) {
        controller.addError(error, StackTrace.current);
      }
    },
  );

  ref.onDispose(() {
    subscription?.cancel();
    controller.close();
  });

  return controller.stream;
});

// ─────────────────────────────────────────────────────────────────────────────
// Active buses provider
// ─────────────────────────────────────────────────────────────────────────────

final activeBusesProvider = Provider<AsyncValue<List<BusModel>>>((ref) {
  final busesAsync = ref.watch(busesListProvider);
  return busesAsync.whenData((buses) {
    return buses.where((bus) => bus.active).toList();
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Route Stops Provider
// ✅ BUG 5 FIXED: async* + await for → StreamController pattern
// async* দিয়ে Firebase listener cancel হয় না, তাই StreamController ব্যবহার করা হলো
// যাতে ref.onDispose()-এ subscription.cancel() properly কাজ করে।
// ─────────────────────────────────────────────────────────────────────────────

final routeStopsProvider =
    StreamProvider.family<List<LatLng>, String>((ref, routeId) {
  final controller = StreamController<List<LatLng>>();
  StreamSubscription<DatabaseEvent>? subscription;

  final db =
      ref.read(databaseProvider); // read, not watch — inside non-async provider

  subscription = db.child('routes/$routeId/stops').onValue.listen(
    (event) {
      if (controller.isClosed) return;
      final data = event.snapshot.value as List<dynamic>?;
      if (data == null) {
        controller.add([]);
        return;
      }

      try {
        final stops = data.map((stop) {
          final stopMap = stop as Map<dynamic, dynamic>;
          return LatLng(
            (stopMap['lat'] as num).toDouble(),
            (stopMap['lng'] as num).toDouble(),
          );
        }).toList();

        if (!controller.isClosed) controller.add(stops);
      } catch (e, st) {
        debugPrint('UniTrack [routeStopsProvider]: Parse error → $e');
        if (!controller.isClosed) controller.addError(e, st);
      }
    },
    onError: (error, StackTrace st) {
      debugPrint(
          'UniTrack [routeStopsProvider]: Firebase error for $routeId → $error');
      if (!controller.isClosed) controller.addError(error, st);
    },
  );

  ref.onDispose(() {
    subscription?.cancel(); // ✅ এখন properly cancel হবে
    controller.close();
  });

  return controller.stream;
});

// ─────────────────────────────────────────────────────────────────────────────
// Stoppages Provider
// ✅ BUG 6 FIXED: error silently swallow করা বন্ধ
// আগে: controller.add([]) — error হলেও empty list দেখাতো, UI বুঝতে পারতো না
// এখন: controller.addError() — Riverpod AsyncError state দেখাবে, UI সেটা handle করতে পারবে
// + isClosed guard added everywhere for safety
// ─────────────────────────────────────────────────────────────────────────────

final stoppagesProvider =
    StreamProvider.family<List<Stoppage>, String>((ref, busId) {
  final controller = StreamController<List<Stoppage>>();
  StreamSubscription<DatabaseEvent>? subscription;

  subscription = globalDB.ref('stoppages/$busId').onValue.listen(
    (event) {
      if (controller.isClosed) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        controller.add([]);
        return;
      }
      final stops = <Stoppage>[];
      for (final entry in data.entries) {
        try {
          stops.add(Stoppage.fromMap(
            entry.key as String,
            Map<String, dynamic>.from(entry.value as Map),
          ));
        } catch (e, st) {
          debugPrint(
            'UniTrack [stoppagesProvider]: Skipping malformed stoppage '
            '"${entry.key}" for $busId → $e',
          );
          debugPrint('$st');
          continue;
        }
      }
      stops.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      if (!controller.isClosed) controller.add(stops);
    },
    onError: (error, StackTrace st) {
      // ✅ BUG 6 FIXED: আগে add([]) ছিল, এখন addError — UI AsyncError দেখাবে
      debugPrint('UniTrack [stoppagesProvider]: Error for $busId → $error');
      if (!controller.isClosed) controller.addError(error, st);
    },
  );

  ref.onDispose(() {
    subscription?.cancel();
    controller.close();
  });

  return controller.stream;
});

// ─────────────────────────────────────────────────────────────────────────────
// Routes List Provider
// ─────────────────────────────────────────────────────────────────────────────

final routesListProvider = StreamProvider<List<RouteModel>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.child('routes').onValue.map((event) {
    final data = event.snapshot.value as Map<dynamic, dynamic>?;
    if (data == null || data.isEmpty) return [];

    final routes = <RouteModel>[];
    for (final entry in data.entries) {
      try {
        routes.add(RouteModel.fromJson(
          entry.key as String,
          Map<String, dynamic>.from(entry.value as Map),
        ));
      } catch (e, st) {
        debugPrint(
          'UniTrack [routesListProvider]: Skipping malformed route "${entry.key}" → $e',
        );
        debugPrint('$st');
        continue;
      }
    }
    return routes;
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// User Location Provider
// ✅ BUG 4: latlong2's LatLng (consistent with rest of file)
// ─────────────────────────────────────────────────────────────────────────────

class UserLocationNotifier extends StateNotifier<LatLng?> {
  UserLocationNotifier() : super(null);

  void updateLocation(LatLng location) => state = location;
  void clearLocation() => state = null;
}

final userLocationProvider =
    StateNotifierProvider<UserLocationNotifier, LatLng?>((ref) {
  return UserLocationNotifier();
});

// ─────────────────────────────────────────────────────────────────────────────
// ETA Timer Provider
// ─────────────────────────────────────────────────────────────────────────────

class EtaNotifier extends StateNotifier<int> {
  EtaNotifier() : super(420);

  void updateEta(int seconds) => state = seconds.clamp(0, 7200);
  void decrement() {
    if (state > 0) state = state - 1;
  }

  void reset() => state = 420;
}

final etaTimerProvider = StateNotifierProvider<EtaNotifier, int>((ref) {
  return EtaNotifier();
});

// ─────────────────────────────────────────────────────────────────────────────
// Distance to Bus Provider — Haversine formula (km)
// latlong2: .latitude / .longitude
// ─────────────────────────────────────────────────────────────────────────────

final distanceToBusProvider = Provider.family<double?, String>((ref, busId) {
  final userLocation = ref.watch(userLocationProvider);
  final busAsync = ref.watch(busDetailProvider(busId));

  return busAsync.whenOrNull(data: (bus) {
    if (bus == null || userLocation == null) return null;
    if (bus.lat == 0.0 && bus.lng == 0.0) return null;

    return Geolocator.distanceBetween(
          userLocation.latitude,
          userLocation.longitude,
          bus.lat,
          bus.lng,
        ) /
        1000.0;
  });
});
