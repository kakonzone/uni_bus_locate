// lib/services/student_background_service.dart
// UniTrack — Student Background Notification Service
// Tracks bus location in background and fires stoppage proximity notifications

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:latlong2/latlong.dart';

import '../firebase_options.dart';
import '../models/stoppage_model.dart';
import 'student_tracking_state.dart';

// ─────────────────────────────────────────────
// WATCHDOG ALARM CALLBACK
// ─────────────────────────────────────────────

@pragma('vm:entry-point')
void studentWatchdogCallback() async {
  debugPrint('[StudentWatchdog] Alarm triggered - checking service status');

  try {
    final isActive = await StudentTrackingState.isTrackingActive();
    final hasTimeout = await StudentTrackingState.hasTrackingTimeout();
    final busId = await StudentTrackingState.getTrackedBusId();

    debugPrint('[StudentWatchdog] isActive: $isActive, hasTimeout: $hasTimeout, busId: $busId');

    // Only restart if tracking is active, within timeout window, and has a valid busId
    if (isActive && !hasTimeout && busId != null && busId.isNotEmpty) {
      debugPrint('[StudentWatchdog] Attempting to restart service for bus: $busId');

      final service = StudentBackgroundService();
      await service.start(busId: busId, busName: 'Bus $busId');

      debugPrint('[StudentWatchdog] Service restart attempted');
    } else {
      debugPrint('[StudentWatchdog] Not restarting - conditions not met');
      // Clear state if timeout exceeded
      if (hasTimeout) {
        await StudentTrackingState.clearTrackingState();
      }
    }
  } catch (e) {
    debugPrint('[StudentWatchdog] Error in watchdog callback: $e');
  }
}

const String _firebaseDatabaseUrl =
    'https://uni-bus-locate-default-rtdb.asia-southeast1.firebasedatabase.app';

class _StudentBgKeys {
  static const String portName = 'unitrack_student_bg_port';
  static const String notifChannelId = 'unitrack_student_notification_channel';
  static const String notifChannelName = 'UniTrack Student Notifications';
}

class _StudentBgMessage {
  static const String stop = 'stop';
  static const String updateBus = 'update_bus';
  static const String autoStopped = 'auto_stopped';
  static const String showNotification = 'show_notification';
}

// ─────────────────────────────────────────────
// STUDENT TASK HANDLER
// ─────────────────────────────────────────────

@pragma('vm:entry-point')
class StudentTaskHandler extends TaskHandler {
  StreamSubscription<DatabaseEvent>? _busLocationSub;
  List<Stoppage> _cachedStoppages = [];
  String _busId = '';
  String _busName = '';
  bool _isTracking = false;
  DateTime? _trackingStartTime;
  int _highestOrderIndex = 0;

  FirebaseDatabase? _db;
  SendPort? _mainPort;

  // Power schedule: only track during 6:00-22:00
  static const int activeStartHour = 6;
  static const int activeEndHour = 22;
  static const Duration trackingTimeout = Duration(hours: 2);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[StudentBgTask] onStart — starter: $starter');

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    _db = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: _firebaseDatabaseUrl,
    );

    await _loadConfig();

    // Check if outside active hours or timeout
    if (!_shouldTrackNow()) {
      debugPrint('[StudentBgTask] Outside active hours or timeout — stopping');
      await _stopTracking();
      return;
    }

    _mainPort = IsolateNameServer.lookupPortByName(_StudentBgKeys.portName);

    await _fetchStoppages();
    await _startBusLocationListener();
    _updateNotification('Tracking $_busName — notifications active');
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // Check if we should stop due to timeout or time window
    if (!_shouldTrackNow()) {
      debugPrint('[StudentBgTask] Stop condition met — stopping tracking');
      await _stopTracking();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[StudentBgTask] onDestroy');
    _busLocationSub?.cancel();
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map<String, dynamic>) {
      final cmd = data['cmd'] as String?;
      switch (cmd) {
        case _StudentBgMessage.stop:
          _stopTracking();
          FlutterForegroundTask.stopService();
          break;
        case _StudentBgMessage.updateBus:
          _busId = data['busId'] ?? _busId;
          _busName = data['busName'] ?? _busName;
          break;
      }
    }
  }

  // ─────────────────────────────────────────────
  // FIREBASE LISTENERS
  // ─────────────────────────────────────────────

  Future<void> _fetchStoppages() async {
    if (_busId.isEmpty || _db == null) return;

    try {
      final snapshot = await _db!.ref('stoppages/$_busId').get();
      if (!snapshot.exists) {
        debugPrint('[StudentBgTask] No stoppages found for bus: $_busId');
        return;
      }

      final data = snapshot.value as Map<dynamic, dynamic>;
      _cachedStoppages = [];
      _highestOrderIndex = 0;

      for (final entry in data.entries) {
        try {
          final stop = Stoppage.fromMap(
            entry.key as String,
            Map<String, dynamic>.from(entry.value as Map),
          );
          _cachedStoppages.add(stop);
          if (stop.orderIndex > _highestOrderIndex) {
            _highestOrderIndex = stop.orderIndex;
          }
        } catch (e) {
          debugPrint('[StudentBgTask] Error parsing stoppage: $e');
        }
      }

      _cachedStoppages.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      debugPrint('[StudentBgTask] Loaded ${_cachedStoppages.length} stoppages');
    } catch (e) {
      debugPrint('[StudentBgTask] Error fetching stoppages: $e');
    }
  }

  Future<void> _startBusLocationListener() async {
    if (_busId.isEmpty || _db == null) return;

    _busLocationSub?.cancel();

    _busLocationSub = _db!.ref('buses/$_busId').onValue.listen(
      (event) {
        if (!_isTracking) return;

        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data == null) return;

        final lat = (data['lat'] as num?)?.toDouble() ?? 0.0;
        final lng = (data['lng'] as num?)?.toDouble() ?? 0.0;
        final speed = (data['speed'] as num?)?.toDouble() ?? 0.0;
        final active = data['active'] as bool? ?? false;

        if (lat == 0.0 || lng == 0.0 || !active) return;

        final busPos = LatLng(lat, lng);

        // Check if bus reached final stop
        if (_hasReachedFinalStop(busPos)) {
          debugPrint('[StudentBgTask] Bus reached final stop — stopping tracking');
          _stopTracking();
          FlutterForegroundTask.stopService();
          return;
        }

        // Call notification check
        _checkNotifications(busPos, speed);
      },
      onError: (e) {
        debugPrint('[StudentBgTask] Bus location listener error: $e');
      },
    );

    debugPrint('[StudentBgTask] Started bus location listener for $_busId');
  }

  // ─────────────────────────────────────────────
  // NOTIFICATION CHECK
  // ─────────────────────────────────────────────

  void _checkNotifications(LatLng busPos, double speed) {
    if (_cachedStoppages.isEmpty) return;

    // Import the notification service singleton
    // Note: This runs in background isolate, so we need to call the singleton
    // The notification service uses flutter_local_notifications which works
    // from background isolates
    try {
      // We'll need to access the global stoppageNotificationService
      // Since this is a background isolate, we need to handle this carefully
      // For now, we'll implement the logic inline since we can't easily
      // access the main isolate's singleton from here
      _checkProximityInline(busPos, speed);
    } catch (e) {
      debugPrint('[StudentBgTask] Notification check error: $e');
    }
  }

  void _checkProximityInline(LatLng busPos, double speed) {
    // Inline implementation of notification logic
    // This duplicates the logic from stoppage_notification_service.dart
    // because we can't easily access the main isolate singleton from here
    final passedStops = <String>{};
    final notifiedStops = <String>{};

    for (final stop in _cachedStoppages) {
      if (passedStops.contains(stop.id)) continue;

      final distKm = stop.distanceTo(busPos);

      if (distKm < 0.15) {
        passedStops.add(stop.id);
        continue;
      }

      final eta = stop.etaMinutes(busPos, speed);
      if (eta == null) continue;

      if (eta > 0.0 && eta <= 5.0 && !notifiedStops.contains(stop.id)) {
        _showNotification(stop, eta);
        notifiedStops.add(stop.id);
      }
    }
  }

  Future<void> _showNotification(Stoppage stop, double eta) async {
    // Send notification request to main isolate via IPC
    _sendToMain({
      'cmd': _StudentBgMessage.showNotification,
      'stopId': stop.id,
      'stopName': stop.name,
      'eta': eta,
    });
  }

  // ─────────────────────────────────────────────
  // STOP CONDITIONS
  // ─────────────────────────────────────────────

  bool _shouldTrackNow() {
    if (!_isTracking) return false;

    // Check timeout
    if (_trackingStartTime != null) {
      final elapsed = DateTime.now().difference(_trackingStartTime!);
      if (elapsed >= trackingTimeout) {
        debugPrint('[StudentBgTask] Tracking timeout reached');
        return false;
      }
    }

    // Check time window (6:00-22:00)
    final hour = DateTime.now().hour;
    if (hour < activeStartHour || hour >= activeEndHour) {
      debugPrint('[StudentBgTask] Outside active hours ($activeStartHour:00-$activeEndHour:00)');
      return false;
    }

    return true;
  }

  bool _hasReachedFinalStop(LatLng busPos) {
    if (_cachedStoppages.isEmpty) return false;

    // Find the final stop (highest orderIndex)
    final finalStop = _cachedStoppages.last;
    if (finalStop.orderIndex != _highestOrderIndex) {
      // Find the actual final stop
      for (final stop in _cachedStoppages) {
        if (stop.orderIndex == _highestOrderIndex) {
          final distKm = stop.distanceTo(busPos);
          if (distKm < 0.15) {
            debugPrint('[StudentBgTask] Bus within 0.15km of final stop');
            return true;
          }
        }
      }
    } else {
      final distKm = finalStop.distanceTo(busPos);
      if (distKm < 0.15) {
        debugPrint('[StudentBgTask] Bus within 0.15km of final stop');
        return true;
      }
    }

    return false;
  }

  Future<void> _stopTracking() async {
    _isTracking = false;
    _busLocationSub?.cancel();
    await StudentTrackingState.clearTrackingState();
    _sendToMain({'cmd': _StudentBgMessage.autoStopped});
    debugPrint('[StudentBgTask] Tracking stopped');
  }

  // ─────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────

  Future<void> _loadConfig() async {
    _busId = await StudentTrackingState.getTrackedBusId() ?? '';
    _busName = 'Bus $_busId';
    _isTracking = await StudentTrackingState.isTrackingActive();
    _trackingStartTime = await StudentTrackingState.getTrackingStartTime();
    debugPrint('[StudentBgTask] Config loaded — busId: $_busId, tracking: $_isTracking');
  }

  void _updateNotification(String body) {
    FlutterForegroundTask.updateService(
      notificationTitle: '🚌 UniTrack — Student Tracking',
      notificationText: body,
    );
  }

  void _sendToMain(Map<String, dynamic> data) {
    _mainPort?.send(data);
  }
}

// ─────────────────────────────────────────────
// STUDENT BACKGROUND SERVICE (main isolate)
// ─────────────────────────────────────────────

class StudentBackgroundService {
  StudentBackgroundService._internal();
  static final StudentBackgroundService _instance =
      StudentBackgroundService._internal();
  factory StudentBackgroundService() => _instance;

  ReceivePort? _receivePort;
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  // Notification plugin for main isolate
  final _notificationPlugin = FlutterLocalNotificationsPlugin();
  bool _notificationInitialized = false;

  static void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _StudentBgKeys.notifChannelId,
        channelName: _StudentBgKeys.notifChannelName,
        channelDescription:
            'Keeps student bus tracking alive for notifications.',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000), // Check every minute
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  Future<bool> start({
    required String busId,
    required String busName,
  }) async {
    // Save tracking state
    await StudentTrackingState.saveTrackingState(
      busId: busId,
      active: true,
    );

    _openReceivePort();
    await _registerWatchdogAlarm();

    final serviceRunning = await FlutterForegroundTask.isRunningService;

    if (serviceRunning) {
      // Update existing service
      FlutterForegroundTask.sendDataToTask({
        'cmd': _StudentBgMessage.updateBus,
        'busId': busId,
        'busName': busName,
      });
      return true;
    }

    final result = await FlutterForegroundTask.startService(
      notificationTitle: '🚌 UniTrack — Student Tracking',
      notificationText: 'Tracking $busName for notifications...',
    );

    return result is ServiceRequestSuccess;
  }

  Future<void> stop() async {
    await StudentTrackingState.setTrackingActive(false);
    await _cancelWatchdogAlarm();
    FlutterForegroundTask.sendDataToTask({'cmd': _StudentBgMessage.stop});
    _closeReceivePort();
    debugPrint('[StudentBackgroundService] Stopped');
  }

  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  void _openReceivePort() {
    _closeReceivePort();
    _receivePort = FlutterForegroundTask.receivePort;
    if (_receivePort != null) {
      IsolateNameServer.registerPortWithName(
        _receivePort!.sendPort,
        _StudentBgKeys.portName,
      );
      _receivePort!.listen((data) {
        if (data is Map<String, dynamic>) {
          _messageController.add(data);
          // Handle notification requests
          if (data['cmd'] == _StudentBgMessage.showNotification) {
            _handleNotificationRequest(data);
          }
        }
      });
    }
  }

  void _closeReceivePort() {
    IsolateNameServer.removePortNameMapping(_StudentBgKeys.portName);
    _receivePort?.close();
    _receivePort = null;
  }

  void dispose() {
    _closeReceivePort();
    _messageController.close();
  }

  // ─────────────────────────────────────────────
  // NOTIFICATION HANDLING (main isolate)
  // ─────────────────────────────────────────────

  Future<void> _ensureNotificationInitialized() async {
    if (_notificationInitialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestSoundPermission: true,
      requestBadgePermission: true,
    );

    await _notificationPlugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    // Reuse existing notification channel from stoppage_notification_service.dart
    const channel = AndroidNotificationChannel(
      'bus_eta',
      'Bus ETA Alerts',
      importance: Importance.max,
      playSound: true,
    );

    await _notificationPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _notificationInitialized = true;
  }

  Future<void> _handleNotificationRequest(Map<String, dynamic> data) async {
    await _ensureNotificationInitialized();

    final stopId = data['stopId'] as String;
    final stopName = data['stopName'] as String;
    final eta = data['eta'] as double;

    const androidDetails = AndroidNotificationDetails(
      'bus_eta',
      'Bus ETA Alerts',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      badgeNumber: 1,
    );

    await _notificationPlugin.show(
      stopId.hashCode & 0x7FFFFFFF,
      '🚌 আসছে — $stopName',
      'বাস প্রায় ${eta.toStringAsFixed(0)} মিনিটে পৌঁছাবে। প্রস্তুত থাকুন!',
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
    );
  }

  // ─────────────────────────────────────────────
  // WATCHDOG ALARM HELPERS
  // ─────────────────────────────────────────────

  static Future<void> _registerWatchdogAlarm() async {
    if (!Platform.isAndroid) return;
    try {
      await AndroidAlarmManager.periodic(
        const Duration(minutes: 2),
        1, // Different alarm ID from driver service
        studentWatchdogCallback,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
      );
      debugPrint('[StudentBackgroundService] Watchdog alarm registered (periodic every 2 minutes)');
    } catch (e) {
      debugPrint('[StudentBackgroundService] Failed to register watchdog alarm: $e');
    }
  }

  static Future<void> _cancelWatchdogAlarm() async {
    if (!Platform.isAndroid) return;
    try {
      await AndroidAlarmManager.cancel(1);
      debugPrint('[StudentBackgroundService] Watchdog alarm cancelled');
    } catch (e) {
      debugPrint('[StudentBackgroundService] Failed to cancel watchdog alarm: $e');
    }
  }
}
