// lib/services/student_tracking_state.dart
// UniTrack — Student Background Tracking State Management
// Handles SharedPreferences persistence for student bus tracking

import 'package:shared_preferences/shared_preferences.dart';

class _StudentTrackingKeys {
  static const String trackedBusId = 'student_tracked_bus_id';
  static const String trackingActive = 'student_tracking_active';
  static const String trackingStartTime = 'student_tracking_start_time';
}

class StudentTrackingState {
  // Save tracking state when student opens a bus timeline
  static Future<void> saveTrackingState({
    required String busId,
    required bool active,
    DateTime? startTime,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_StudentTrackingKeys.trackedBusId, busId);
    await prefs.setBool(_StudentTrackingKeys.trackingActive, active);
    await prefs.setInt(
      _StudentTrackingKeys.trackingStartTime,
      (startTime ?? DateTime.now()).millisecondsSinceEpoch,
    );
  }

  // Get the currently tracked bus ID
  static Future<String?> getTrackedBusId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_StudentTrackingKeys.trackedBusId);
  }

  // Check if tracking is currently active
  static Future<bool> isTrackingActive() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_StudentTrackingKeys.trackingActive) ?? false;
  }

  // Get the tracking start time
  static Future<DateTime?> getTrackingStartTime() async {
    final prefs = await SharedPreferences.getInstance();
    final startMs = prefs.getInt(_StudentTrackingKeys.trackingStartTime);
    if (startMs == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(startMs);
  }

  // Set tracking active flag (for toggle ON/OFF)
  static Future<void> setTrackingActive(bool active) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_StudentTrackingKeys.trackingActive, active);
    if (active) {
      await prefs.setInt(
        _StudentTrackingKeys.trackingStartTime,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  // Clear all tracking state
  static Future<void> clearTrackingState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_StudentTrackingKeys.trackedBusId);
    await prefs.remove(_StudentTrackingKeys.trackingActive);
    await prefs.remove(_StudentTrackingKeys.trackingStartTime);
  }

  // Check if tracking has exceeded the 2-hour timeout
  static Future<bool> hasTrackingTimeout() async {
    final startTime = await getTrackingStartTime();
    if (startTime == null) return false;
    final elapsed = DateTime.now().difference(startTime);
    return elapsed.inHours >= 2;
  }
}
