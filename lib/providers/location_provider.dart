// lib/providers/location_provider.dart
// UniTrack — University Bus Live Tracking System
// BUG-2 FIXED: _shouldWrite() force-writes every 30s (stationary bus fix)
// BUG-3 FIXED: _currentWindow now time-based (7–18 active, 18–22 low power, else sleep)
// BUG-4 FIXED: debugPrint added before/after Firebase write in _pollAndWrite()

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/bus_model.dart';
import '../services/firebase_service.dart';
import '../services/location_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1.  SERVICE PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

final firebaseServiceProvider = Provider<FirebaseService>((ref) {
  return FirebaseService.instance;
});

final locationServiceProvider = Provider<LocationService>((ref) {
  return LocationService();
});

// ─────────────────────────────────────────────────────────────────────────────
// 2.  DRIVER LIVE LOCATION  (StateNotifier)
// ─────────────────────────────────────────────────────────────────────────────

// REMOVED: DriverLocationState and DriverLocationNotifier classes were here.
// The driver dashboard now uses liveLocationProvider from tracking_provider.dart,
// making this redundant.

// REMOVED: driverLocationProvider was here.

// ─────────────────────────────────────────────────────────────────────────────
// 3.  ALL-BUSES LIVE STREAM
// ─────────────────────────────────────────────────────────────────────────────

final liveBusListProvider = StreamProvider<List<BusModel>>((ref) {
  final firebaseService = ref.watch(firebaseServiceProvider);
  return firebaseService.watchAllBuses();
});

// singleBusProvider শুধু এই ফাইলেই define থাকবে।
// bus_providers.dart এ singleBusStreamProvider আলাদা নামে আছে — কোনো conflict নেই।
final singleBusProvider =
    StreamProvider.family<BusModel?, String>((ref, busId) {
  final firebaseService = ref.watch(firebaseServiceProvider);
  return firebaseService.watchBus(busId);
});

// ─────────────────────────────────────────────────────────────────────────────
// 4.  SELECTED BUS
// ─────────────────────────────────────────────────────────────────────────────

final selectedBusIdProvider = StateProvider<String?>((ref) => null);

final selectedBusProvider = Provider<AsyncValue<BusModel?>>((ref) {
  final selectedId = ref.watch(selectedBusIdProvider);
  if (selectedId == null) return const AsyncData(null);
  return ref.watch(singleBusProvider(selectedId));
});

// ─────────────────────────────────────────────────────────────────────────────
// 5.  ETA + DISTANCE CALCULATOR
// ─────────────────────────────────────────────────────────────────────────────

class EtaResult {
  final double distanceKm;
  final int etaMinutes;
  final bool isReachable;

  const EtaResult({
    required this.distanceKm,
    required this.etaMinutes,
    required this.isReachable,
  });

  String get distanceLabel {
    if (distanceKm < 1) return '${(distanceKm * 1000).round()} m';
    return '${distanceKm.toStringAsFixed(1)} km';
  }

  String get etaLabel {
    if (!isReachable) return 'Unavailable';
    if (etaMinutes <= 0) return 'Arriving soon';
    if (etaMinutes >= 60) {
      final h = etaMinutes ~/ 60;
      final m = etaMinutes % 60;
      return m == 0 ? '${h}h' : '${h}h ${m}m';
    }
    return '${etaMinutes}m';
  }
}

final etaProvider = Provider.family<EtaResult?, String>((ref, busId) {
  final busAsync = ref.watch(singleBusProvider(busId));
  // FIX 1: Removed student location watch.
  // final studentPos = ref.watch(myLocationProvider).valueOrNull;

  // FIX 1: Use a fixed static campus reference point.
  const campusLat = 23.417188606102346;
  const campusLng = 91.12459015590844;
  const campusLocation = LatLng(campusLat, campusLng);

  return busAsync.when(
    data: (bus) {
      // FIX 1: Updated check to only verify bus data.
      if (bus == null) return null;
      if (!bus.active) return null;
      // BusModel.lat/lng এখন non-nullable double — 0.0 মানে unknown
      if (bus.lat == 0.0 && bus.lng == 0.0) return null;

      final busLatLng = LatLng(bus.lat, bus.lng);
      const dist = Distance();
      // FIX 1: Replaced studentPos with the static campus location.
      final distKm = dist.as(LengthUnit.Kilometer, campusLocation, busLatLng);

      // FIXED: Calculate ETA based on bus speed (km/h) instead of a hardcoded value.
      // If speed is <= 1 km/h, the bus is considered stationary/unreachable.
      if (bus.speed <= 1) {
        return EtaResult(
          distanceKm: distKm,
          etaMinutes: 0, // ETA is irrelevant if unreachable
          isReachable: false,
        );
      }

      final etaMin = ((distKm / bus.speed) * 60).round();

      return EtaResult(
        distanceKm: distKm,
        etaMinutes: etaMin,
        isReachable: true,
      );
    },
    loading: () => null,
    error: (_, __) => null,
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// 6.  STUDENT / MY LOCATION  (StreamProvider)
// ─────────────────────────────────────────────────────────────────────────────

// FIX 2: Removed myLocationProvider entirely.
// final myLocationProvider = StreamProvider<LatLng?>((ref) async* { ... });

// FIX 2: Removed backward-compatible alias.
// final studentPositionProvider = myLocationProvider;

// ─────────────────────────────────────────────────────────────────────────────
// 7.  PERMISSION STATUS
// ─────────────────────────────────────────────────────────────────────────────

class PermissionStatus {
  final bool locationGranted;
  final bool backgroundLocationGranted;
  final bool notificationGranted;

  const PermissionStatus({
    required this.locationGranted,
    required this.backgroundLocationGranted,
    required this.notificationGranted,
  });

  bool get allGranted =>
      locationGranted && backgroundLocationGranted && notificationGranted;
}

final permissionStatusProvider = FutureProvider<PermissionStatus>((ref) async {
  final locStatus = await Geolocator.checkPermission();
  final locationGranted = locStatus == LocationPermission.always ||
      locStatus == LocationPermission.whileInUse;
  final backgroundGranted = locStatus == LocationPermission.always;

  return PermissionStatus(
    locationGranted: locationGranted,
    backgroundLocationGranted: backgroundGranted,
    notificationGranted: true,
  );
});
