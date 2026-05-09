// lib/models/location_model.dart

import 'dart:math' as math;

class LocationModel {
  final double lat;
  final double lng;
  final double speed; // km/h
  final double accuracy; // metres — from geolocator
  final double heading; // degrees 0–360 (0 = North)
  final double altitude; // metres
  final DateTime timestamp;

  const LocationModel({
    required this.lat,
    required this.lng,
    double speed = 0.0,
    double? speedKmh,
    this.accuracy = 0.0,
    this.heading = 0.0,
    this.altitude = 0.0,
    required this.timestamp,
  }) : speed = speedKmh ?? speed;

  // ─── Computed helpers ──────────────────────────────────────────────────────

  /// True when the accuracy reading is good enough to trust (≤ 20 m).
  bool get isAccurate => accuracy <= 20.0;

  /// True when the bus is effectively stationary (< 2 km/h).
  bool get isStationary => speed < 2.0;

  /// Human-readable speed string.
  String get speedLabel {
    if (isStationary) return 'Stationary';
    return '${speed.toStringAsFixed(1)} km/h';
  }

  // Backward-compatible alias used by older service/provider code.
  double get speedKmh => speed;

  /// Cardinal/intercardinal bearing label (N, NE, E, …).
  String get headingLabel {
    const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW', 'N'];
    final index = ((heading + 22.5) / 45).floor().clamp(0, 8);
    return directions[index];
  }

  /// Age of this location fix in seconds.
  int get ageInSeconds => DateTime.now().difference(timestamp).inSeconds.abs();

  /// True if the fix is fresh enough to display on the map (< 30 s old).
  bool get isFresh => ageInSeconds < 30;

  // ─── Distance calculation ──────────────────────────────────────────────────

  /// Returns the Haversine distance in **metres** between this location and
  /// [other].  Used by the background service to decide whether to write a
  /// new Firebase update (only when distance > 5 m).
  double distanceTo(LocationModel other) =>
      _haversine(lat, lng, other.lat, other.lng);

  /// Convenience overload that accepts raw coordinates.
  double distanceToCoords(double otherLat, double otherLng) =>
      _haversine(lat, lng, otherLat, otherLng);

  /// Rough ETA string to a destination given current speed.
  /// Returns null when the bus is stationary or speed data is unavailable.
  String? etaTo(double destLat, double destLng) {
    if (isStationary || speed <= 0) return null;
    final distanceKm = distanceToCoords(destLat, destLng) / 1000.0;
    final hours = distanceKm / speed;
    final totalMinutes = (hours * 60).round();
    if (totalMinutes < 1) return '< 1 min';
    if (totalMinutes < 60) return '$totalMinutes min';
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  // ─── Firebase serialisation ────────────────────────────────────────────────

  /// Build from a Firebase Realtime Database map snapshot.
  factory LocationModel.fromMap(Map<dynamic, dynamic> map) {
    return LocationModel(
      lat: _toDouble(map['lat']),
      lng: _toDouble(map['lng']),
      speed: _toDouble(map['speed']),
      accuracy: _toDouble(map['accuracy']),
      heading: _toDouble(map['heading']),
      altitude: _toDouble(map['altitude']),
      timestamp: map['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (map['timestamp'] as int),
              isUtc: true,
            )
          : DateTime.now().toUtc(),
    );
  }

  factory LocationModel.fromBusMap(Map<dynamic, dynamic> map) =>
      LocationModel.fromMap(map);

  /// Full serialisation — used when writing a trip history point.
  Map<String, dynamic> toMap() {
    return {
      'lat': lat,
      'lng': lng,
      'speed': speed,
      'accuracy': accuracy,
      'heading': heading,
      'altitude': altitude,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  /// Minimal payload for the hot-path live bus update.
  /// Keeps the Firebase write small — only fields the map UI needs.
  Map<String, dynamic> toLiveUpdate() {
    return {
      'lat': lat,
      'lng': lng,
      'speed': speed,
      'heading': heading,
      'lastUpdate': timestamp.millisecondsSinceEpoch,
    };
  }

  // ─── Geolocator bridge ─────────────────────────────────────────────────────

  /// Convert a [geolocator] `Position` object into a [LocationModel].
  /// Import geolocator in location_service.dart and call this factory there
  /// so this model file stays package-free.
  factory LocationModel.fromValues({
    required double lat,
    required double lng,
    required double speedMs, // geolocator gives m/s — we convert to km/h
    required double accuracy,
    required double heading,
    required double altitude,
    required DateTime timestamp,
  }) {
    return LocationModel(
      lat: lat,
      lng: lng,
      speed: speedMs >= 0 ? speedMs * 3.6 : 0.0, // m/s → km/h
      accuracy: accuracy,
      heading: heading >= 0 ? heading : 0.0,
      altitude: altitude,
      timestamp: timestamp,
    );
  }

  // ─── copyWith ──────────────────────────────────────────────────────────────

  LocationModel copyWith({
    double? lat,
    double? lng,
    double? speed,
    double? accuracy,
    double? heading,
    double? altitude,
    DateTime? timestamp,
  }) {
    return LocationModel(
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      speed: speed ?? this.speed,
      accuracy: accuracy ?? this.accuracy,
      heading: heading ?? this.heading,
      altitude: altitude ?? this.altitude,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  // ─── Equality ──────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocationModel &&
          runtimeType == other.runtimeType &&
          lat == other.lat &&
          lng == other.lng &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(lat, lng, timestamp);

  @override
  String toString() =>
      'LocationModel(lat: $lat, lng: $lng, speed: ${speedLabel}, '
      'heading: ${headingLabel}, accuracy: ${accuracy}m, '
      'age: ${ageInSeconds}s)';

  // ─── Private utils ─────────────────────────────────────────────────────────

  /// Haversine formula — returns distance in **metres**.
  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0; // Earth radius in metres
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  static double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }
}
