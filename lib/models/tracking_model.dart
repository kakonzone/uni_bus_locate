import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum TrackingMode { active, lowPower, sleep }

enum TripStatus { idle, running, paused }

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

class LiveLocationNotifier extends StateNotifier<LiveLocationState> {
  LiveLocationNotifier() : super(const LiveLocationState());

  StreamSubscription<Position>? _sub;

  void startListening(TrackingMode mode) {
    _sub?.cancel();
    final distanceFilter = switch (mode) {
      TrackingMode.active => 5,
      TrackingMode.lowPower => 20,
      TrackingMode.sleep => 50,
    };
    final settings = LocationSettings(
      accuracy: mode == TrackingMode.active
          ? LocationAccuracy.high
          : LocationAccuracy.medium,
      distanceFilter: distanceFilter,
    );
    _sub =
        Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
      final prev = state.position;
      double added = 0.0;
      if (prev != null) {
        added = Geolocator.distanceBetween(
          prev.latitude,
          prev.longitude,
          pos.latitude,
          pos.longitude,
        );
      }
      state = state.copyWith(
        position: pos,
        lastUpdate: DateTime.now(),
        totalUpdates: state.totalUpdates + 1,
        totalDistanceM: state.totalDistanceM + added,
      );
    });
  }

  void stopListening() {
    _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
