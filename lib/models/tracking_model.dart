import 'package:geolocator/geolocator.dart';

enum TrackingMode { active, lowPower, sleep }

enum TripStatus { idle, running, paused }

/// How a bus location is sourced (phone GPS vs dedicated GPS device).
enum BusTrackMode {
  phoneGps,
  gpsDevice;

  static BusTrackMode fromFirebase(dynamic value) {
    final raw = value?.toString().toLowerCase() ?? '';
    if (raw == 'gps_device' || raw == 'gps') return BusTrackMode.gpsDevice;
    return BusTrackMode.phoneGps;
  }

  String get firebaseValue =>
      this == BusTrackMode.gpsDevice ? 'gps_device' : 'phone_gps';

  bool get isGpsDevice => this == BusTrackMode.gpsDevice;
}

class LiveLocationState {
  final Position? position;
  final DateTime? lastUpdate;
  final int totalUpdates;
  final double totalDistanceM;

  const LiveLocationState({
    this.position,
    this.lastUpdate,
    this.totalUpdates = 0,
    this.totalDistanceM = 0.0,
  });

  LiveLocationState copyWith({
    Position? position,
    DateTime? lastUpdate,
    int? totalUpdates,
    double? totalDistanceM,
  }) {
    return LiveLocationState(
      position: position ?? this.position,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      totalUpdates: totalUpdates ?? this.totalUpdates,
      totalDistanceM: totalDistanceM ?? this.totalDistanceM,
    );
  }
}
