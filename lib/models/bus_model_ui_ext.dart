import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../theme/app_color.dart';
import 'bus_model.dart';

/// UI-facing helpers for [BusModel]. Kept separate from `bus_model.dart`
/// on purpose — this file imports `material.dart` (for `Color`), so if
/// `bus_model.dart` is a plain Flutter-free data class, it stays that way.
extension BusModelUiHelper on BusModel {
  double distanceFrom(double refLat, double refLng) {
    if (lat == 0.0 && lng == 0.0) return double.infinity;
    return Geolocator.distanceBetween(lat, lng, refLat, refLng) / 1000.0;
  }

  // FIX #4: cap ETA at 120 min
  int? etaMinutes(double refLat, double refLng) {
    if (speed < 1) return null;
    final dist = distanceFrom(refLat, refLng);
    if (dist == double.infinity) return null;
    final eta = ((dist / speed) * 60).round();
    if (eta > 120) return null;
    return eta;
  }

  String get movementStatusLabel {
    if (!active) return 'Inactive';
    if (speed < 2) return 'Stopped';
    return 'Moving';
  }

  Color get statusColor {
    if (!active) return AppColors.inactiveGrey;
    if (speed < 2) return AppColors.amber;
    return AppColors.activeGreen;
  }
}
