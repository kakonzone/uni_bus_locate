// lib/services/notification_service.dart
// UniTrack — Push Notification Service for Bus Nearby Alerts

import 'dart:typed_data' show Int64List;
import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Initialize the notification plugin
  /// Call this once in the app's main() or in initState()
  static Future<void> init() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(
        android: android,
        iOS: ios,
      ),
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    _initialized = true;
  }

  /// Handle notification tap
  static void _onNotificationTap(NotificationResponse response) {
    // Handle notification tap - could navigate to bus detail screen
    // The payload contains the bus ID
  }

  /// Request notification permissions (for iOS)
  static Future<bool> requestPermission() async {
    final iosImpl = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();

    if (iosImpl != null) {
      final result = await iosImpl.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return result ?? false;
    }

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    if (androidImpl != null) {
      final result = await androidImpl.requestNotificationsPermission();
      return result ?? false;
    }

    return true;
  }

  /// Show a bus nearby alert notification
  /// [busName] - The name of the bus (e.g., "Bus A1")
  /// [etaMinutes] - Estimated time of arrival in minutes
  static Future<void> showBusNearbyAlert({
    required String busName,
    required int etaMinutes,
  }) async {
    if (!_initialized) {
      await init();
    }

    // Non-const AndroidNotificationDetails (required for Int64List)
    final androidDetails = AndroidNotificationDetails(
      'bus_alerts',
      'Bus Alerts',
      channelDescription: 'Alerts when bus is nearby',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFF1B2CC1),
      enableLights: true,
      ledColor: Color(0xFF1B2CC1),
      ledOnMs: 1000,
      ledOffMs: 500,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 250, 250, 250]),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'default',
    );

    // Non-const NotificationDetails (required for non-const android details)
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      1001, // Notification ID for bus alerts
      '\u{1F68C} Bus Arriving Soon',
      '$busName is about $etaMinutes min away!',
      details,
      payload: 'bus_nearby:$busName',
    );
  }

  /// Show a custom notification
  static Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
    NotificationDetails? details,
  }) async {
    if (!_initialized) {
      await init();
    }

    await _plugin.show(
      id,
      title,
      body,
      details,
      payload: payload,
    );
  }

  /// Cancel a specific notification
  static Future<void> cancel(int id) async {
    await _plugin.cancel(id);
  }

  /// Cancel all notifications
  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  /// Get pending notifications
  static Future<List<PendingNotificationRequest>>
      getPendingNotifications() async {
    return await _plugin.pendingNotificationRequests();
  }
}
