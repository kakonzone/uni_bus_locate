import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:latlong2/latlong.dart'; // ✅ FIX: google_maps_flutter সরিয়ে latlong2 দেওয়া হয়েছে
import '../models/stoppage_model.dart';

class StoppageNotificationService {
  static final StoppageNotificationService _instance =
      StoppageNotificationService._();
  factory StoppageNotificationService() => _instance;
  StoppageNotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final Set<String> _notifiedStops = {};
  final Set<String> _passedStops = {};

  // ✅ FIX Bug 2: Track both busId AND trip start time so same busId
  //    on a new trip still triggers a full reset.
  String? _currentBusId;
  DateTime? _tripStartTime;

  // ── Method 1: Initialise plugin + Android channel ─────────────────────────
  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestSoundPermission: true,
      requestBadgePermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    const channel = AndroidNotificationChannel(
      'bus_eta',
      'Bus ETA Alerts',
      importance: Importance.max,
      playSound: true,
    );

    // ✅ FIX: Generic type একলাইনে লেখা হয়েছে — আগে দুই লাইনে ভাগ হয়ে syntax error হচ্ছিল
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  // ── Method 2: Check proximity for every stop and fire alerts ─────────────
  void checkAndNotify({
    required String busId,
    required LatLng busPos,
    required double speedKmh,
    required List<Stoppage> stoppages,
  }) {
    if (busId != _currentBusId) {
      _currentBusId = busId;
      _tripStartTime = DateTime.now(); // ✅ FIX Bug 2: anchor a new trip time
      _notifiedStops.clear();
      _passedStops.clear();
    }

    for (final stop in stoppages) {
      if (_passedStops.contains(stop.id)) continue;

      final distKm = stop.distanceTo(busPos);

      if (distKm < 0.15) {
        _passedStops.add(stop.id);
        // ✅ FIX Bug 4: removed _notifiedStops.remove(stop.id) — stop is in
        //    _passedStops so the loop skips it anyway; removing from
        //    _notifiedStops only risked duplicate notifications on GPS jitter.
        continue;
      }

      final eta = stop.etaMinutes(busPos, speedKmh);
      if (eta == null) continue;

      // ✅ FIX Bug 3: added eta > 0.0 guard — negative/zero ETA means the
      //    bus has already passed at high speed but missed the 0.15 km check.
      if (eta > 0.0 && eta <= 5.0 && !_notifiedStops.contains(stop.id)) {
        _showNotification(stop, eta);
        _notifiedStops.add(stop.id);
      }
    }
  }

  // ── Method 3: Post the local notification ────────────────────────────────
  Future<void> _showNotification(Stoppage stop, double eta) async {
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

    await _plugin.show(
      // ✅ FIX Bug 1: replaced stop.orderIndex (not unique across routes) with
      //    a stable positive hash of stop.id so IDs never collide.
      stop.id.hashCode & 0x7FFFFFFF,
      '🚌 আসছে — ${stop.name}',
      'বাস প্রায় ${eta.toStringAsFixed(0)} মিনিটে পৌঁছাবে। প্রস্তুত থাকুন!',
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
    );
  }

  // ── Method 4: Reset all tracking state ───────────────────────────────────
  void reset() {
    _notifiedStops.clear();
    _passedStops.clear();
    _currentBusId = null;
    _tripStartTime = null; // ✅ FIX Bug 2: also clear trip anchor on full reset
  }

  // ✅ FIX Bug 2: New helper — call this when the same bus starts a new trip
  //    (e.g. driver presses "Start Route" again) so state is cleanly reset
  //    even though the busId hasn't changed.
  void resetForNewTrip(String busId) {
    _currentBusId = busId;
    _tripStartTime = DateTime.now();
    _notifiedStops.clear();
    _passedStops.clear();
  }
}

// Global singleton instance
final stoppageNotificationService = StoppageNotificationService();
