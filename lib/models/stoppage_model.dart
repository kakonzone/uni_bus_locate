// lib/models/stoppage_model.dart
// UniTrack — Stoppage Model with Haversine distance + ETA calculation
// FIXED: Replaced google_maps_flutter LatLng → latlong2 LatLng

import 'package:latlong2/latlong.dart'; // ✅ FIXED
import 'dart:math' as math;

class Stoppage {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final int orderIndex;
  final double notifyRadiusKm;

  const Stoppage({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.orderIndex,
    this.notifyRadiusKm = 0.8,
  });

  // ─── Computed ──────────────────────────────────────────────────────────────

  LatLng get position => LatLng(lat, lng); // ✅ latlong2 LatLng

  /// Haversine distance in km from this stop to the bus position
  double distanceTo(LatLng busPos) {
    const r = 6371.0;
    final dLat = (busPos.latitude - lat) * math.pi / 180;
    final dLon = (busPos.longitude - lng) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat * math.pi / 180) *
            math.cos(busPos.latitude * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Returns ETA in minutes. Returns null if bus is stationary (speed < 2 km/h)
  double? etaMinutes(LatLng busPos, double speedKmh) {
    if (speedKmh < 2) return null;
    return distanceTo(busPos) / speedKmh * 60.0;
  }

  // ─── Firebase serialisation ────────────────────────────────────────────────

  factory Stoppage.fromMap(String id, Map<String, dynamic> map) {
    return Stoppage(
      id: id,
      name: (map['name'] as String?) ?? id,
      lat: (map['lat'] as num).toDouble(),
      lng: (map['lng'] as num).toDouble(),
      orderIndex: (map['orderIndex'] as int?) ?? 0,
      notifyRadiusKm: (map['notifyRadiusKm'] as num?)?.toDouble() ?? 0.8,
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'lat': lat,
        'lng': lng,
        'orderIndex': orderIndex,
        'notifyRadiusKm': notifyRadiusKm,
      };

  // ─── copyWith ──────────────────────────────────────────────────────────────

  Stoppage copyWith({
    String? id,
    String? name,
    double? lat,
    double? lng,
    int? orderIndex,
    double? notifyRadiusKm,
  }) {
    return Stoppage(
      id: id ?? this.id,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      orderIndex: orderIndex ?? this.orderIndex,
      notifyRadiusKm: notifyRadiusKm ?? this.notifyRadiusKm,
    );
  }

  // ─── Equality ──────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Stoppage && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Stoppage(id: $id, name: $name, lat: $lat, lng: $lng, orderIndex: $orderIndex)';
}
