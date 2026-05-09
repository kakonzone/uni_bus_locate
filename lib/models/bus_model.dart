// lib/models/bus_model.dart

class BusModel {
  final String busId;
  final String name;
  final String route;
  final String? driverName;
  final String trackMode; // 'phone' | 'gps_device'
  final bool active;
  final double lat;
  final double lng;
  final double speed; // km/h
  final double heading; // degrees 0–360, bus direction for marker rotation
  final double? destLat;
  final double? destLng;
  final int watchCount;
  final DateTime? lastUpdate;

  const BusModel({
    required this.busId,
    required this.name,
    required this.route,
    this.driverName,
    this.trackMode = 'phone_gps',
    required this.active,
    required this.lat,
    required this.lng,
    required this.speed,
    this.heading = 0.0,
    this.destLat,
    this.destLng,
    this.watchCount = 0,
    this.lastUpdate,
  });

  // Backward-compatible alias used by older UI code.
  String get id => busId;

  // New backward-compatible alias for old code:
  bool? get isActive => active;

  // ─── Computed helpers ──────────────────────────────────────────────────────

  /// True if a location update arrived within the last 2 minutes.
  bool get isLive {
    if (lastUpdate == null) return false;
    return DateTime.now().difference(lastUpdate!).inMinutes < 2;
  }

  /// Human-readable speed label.
  String get speedLabel {
    if (speed < 2) return 'Stationary';
    return '${speed.toStringAsFixed(1)} km/h';
  }

  /// Status string shown on bus cards.
  String get statusLabel {
    if (!active) return 'Inactive';
    if (!isLive) return 'Signal Lost';
    return 'Live';
  }

  // ─── Firebase serialisation ────────────────────────────────────────────────

  factory BusModel.fromMap(String id, Map<String, dynamic> map) {
    return BusModel(
      busId: id,
      name: (map['name'] as String?) ?? 'Bus $id',
      route: (map['route'] as String?) ?? '',
      driverName: map['driverName'] as String?,
      trackMode: map['trackMode'] as String? ?? 'phone_gps',
      active: (map['active'] as bool?) ?? false,
      lat: _toDouble(map['lat']),
      lng: _toDouble(map['lng']),
      speed: _toDouble(map['speed']),
      heading: (map['heading'] ?? 0.0).toDouble(),
      destLat: _toDoubleOrNull(map['destLat']),
      destLng: _toDoubleOrNull(map['destLng']),
      watchCount: (map['watchCount'] as int?) ?? 0,
      lastUpdate: map['lastUpdate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (map['lastUpdate'] as int),
              isUtc: true,
            )
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'route': route,
      if (driverName != null) 'driverName': driverName,
      'trackMode': trackMode,
      'active': active,
      'lat': lat,
      'lng': lng,
      'speed': speed,
      'heading': heading,
      if (destLat != null) 'destLat': destLat,
      if (destLng != null) 'destLng': destLng,
      'watchCount': watchCount,
      if (lastUpdate != null) 'lastUpdate': lastUpdate!.millisecondsSinceEpoch,
    };
  }

  /// Partial update payload — only the fields that change every GPS tick.
  Map<String, dynamic> toLocationUpdate() {
    return {
      'lat': lat,
      'lng': lng,
      'speed': speed,
      'heading': heading,
      'active': active,
      'lastUpdate': DateTime.now().toUtc().millisecondsSinceEpoch,
    };
  }

  // ─── copyWith ──────────────────────────────────────────────────────────────

  BusModel copyWith({
    String? busId,
    String? name,
    String? route,
    String? driverName,
    String? trackMode,
    bool? active,
    double? lat,
    double? lng,
    double? speed,
    double? heading,
    double? destLat,
    double? destLng,
    int? watchCount,
    DateTime? lastUpdate,
  }) {
    return BusModel(
      busId: busId ?? this.busId,
      name: name ?? this.name,
      route: route ?? this.route,
      driverName: driverName ?? this.driverName,
      trackMode: trackMode ?? this.trackMode,
      active: active ?? this.active,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      speed: speed ?? this.speed,
      heading: heading ?? this.heading,
      destLat: destLat ?? this.destLat,
      destLng: destLng ?? this.destLng,
      watchCount: watchCount ?? this.watchCount,
      lastUpdate: lastUpdate ?? this.lastUpdate,
    );
  }

  // ─── Equality ──────────────────────────────────────────────────────────────

  // BUG-3 FIX: আগে শুধু busId দিয়ে compare হতো।
  // ফলে _scheduleTrailUpdate() এ bus == _lastBus সবসময় true হতো
  // (same busId) → trail কখনোই update হতো না first set এর পর।
  // এখন lat, lng, speed, active, lastUpdate সহ compare করা হচ্ছে —
  // GPS update আসলে equality false হবে এবং trail সঠিকভাবে আঁকবে।
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BusModel &&
        runtimeType == other.runtimeType &&
        busId == other.busId &&
        lat == other.lat &&
        lng == other.lng &&
        speed == other.speed &&
        heading == other.heading &&
        active == other.active &&
        lastUpdate == other.lastUpdate;
  }

  @override
  int get hashCode => Object.hash(
        busId,
        lat,
        lng,
        speed,
        heading,
        active,
        lastUpdate,
      );

  @override
  String toString() => 'BusModel(busId: $busId, name: $name, active: $active, '
      'lat: $lat, lng: $lng, speed: $speed, heading: $heading)';

  // ─── Private utils ─────────────────────────────────────────────────────────

  static double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  /// Nullable double helper for optional fields like destLat/destLng
  static double? _toDoubleOrNull(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}

/// Route model for storing route stops
class RouteModel {
  final String id;
  final String name;
  final List<dynamic> stops;
  final String? description;

  const RouteModel({
    required this.id,
    required this.name,
    required this.stops,
    this.description,
  });

  factory RouteModel.fromJson(String id, Map<String, dynamic> json) {
    return RouteModel(
      id: id,
      name: json['name'] as String? ?? 'Unknown Route',
      stops: json['stops'] as List<dynamic>? ?? [],
      description: json['description'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'stops': stops,
      if (description != null) 'description': description,
    };
  }
}
