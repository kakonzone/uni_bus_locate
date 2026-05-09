// lib/services/location_cache_service.dart
// UniTrack — Offline Position Cache Service
// Stores the last known bus position for offline fallback

import 'package:shared_preferences/shared_preferences.dart';

class LocationCacheService {
  static const String _latKey = 'last_bus_lat_';
  static const String _lngKey = 'last_bus_lng_';
  static const String _timeKey = 'last_bus_time_';
  static const String _speedKey = 'last_bus_speed_';
  static const String _nameKey = 'last_bus_name_';

  /// Save the current bus position to local storage
  /// [busId] - Unique identifier for the bus
  /// [lat] - Latitude coordinate
  /// [lng] - Longitude coordinate
  /// [speed] - Optional: bus speed in km/h
  /// [name] - Optional: bus name for display
  static Future<void> savePosition(
    String busId,
    double lat,
    double lng, {
    double? speed,
    String? name,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    await Future.wait([
      prefs.setDouble('$_latKey$busId', lat),
      prefs.setDouble('$_lngKey$busId', lng),
      prefs.setInt('$_timeKey$busId', DateTime.now().millisecondsSinceEpoch),
      if (speed != null) prefs.setDouble('$_speedKey$busId', speed),
      if (name != null) prefs.setString('$_nameKey$busId', name),
    ]);
  }

  /// Get the last known position for a bus
  /// Returns a map with 'lat', 'lng', 'time', 'speed' (optional), and 'name' (optional)
  /// Returns null if no cached position exists
  static Future<Map<String, dynamic>?> getLastPosition(String busId) async {
    final prefs = await SharedPreferences.getInstance();

    final lat = prefs.getDouble('$_latKey$busId');
    final lng = prefs.getDouble('$_lngKey$busId');
    final time = prefs.getInt('$_timeKey$busId');
    final speed = prefs.getDouble('$_speedKey$busId');
    final name = prefs.getString('$_nameKey$busId');

    if (lat == null || lng == null) return null;

    return {
      'lat': lat,
      'lng': lng,
      'time': time,
      if (speed != null) 'speed': speed,
      if (name != null) 'name': name,
    };
  }

  /// Clear cached position for a specific bus
  static Future<void> clearPosition(String busId) async {
    final prefs = await SharedPreferences.getInstance();

    await Future.wait([
      prefs.remove('$_latKey$busId'),
      prefs.remove('$_lngKey$busId'),
      prefs.remove('$_timeKey$busId'),
      prefs.remove('$_speedKey$busId'),
      prefs.remove('$_nameKey$busId'),
    ]);
  }

  /// Clear all cached bus positions
  static Future<void> clearAllPositions() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();

    final keysToRemove = keys.where((key) =>
        key.startsWith(_latKey) ||
        key.startsWith(_lngKey) ||
        key.startsWith(_timeKey) ||
        key.startsWith(_speedKey) ||
        key.startsWith(_nameKey));

    for (final key in keysToRemove) {
      await prefs.remove(key);
    }
  }

  /// Check if a cached position exists for a bus
  static Future<bool> hasCachedPosition(String busId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_latKey$busId') &&
        prefs.containsKey('$_lngKey$busId');
  }

  /// Get the age of the cached position in minutes
  /// Returns null if no cache exists
  static Future<int?> getCacheAgeMinutes(String busId) async {
    final prefs = await SharedPreferences.getInstance();
    final time = prefs.getInt('$_timeKey$busId');

    if (time == null) return null;

    final cacheTime = DateTime.fromMillisecondsSinceEpoch(time);
    final age = DateTime.now().difference(cacheTime);
    return age.inMinutes;
  }

  /// Save user preferences (theme, last viewed bus, etc.)
  static Future<void> saveUserPreference(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();

    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is List<String>) {
      await prefs.setStringList(key, value);
    }
  }

  /// Get a user preference value
  static Future<T?> getUserPreference<T>(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.get(key) as T?;
  }
}
