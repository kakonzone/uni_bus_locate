// lib/services/auth_service.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/firebase_globals.dart';
import '../models/user_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SharedPreferences Keys — auth_providers.dart এর সাথে exact match
// ─────────────────────────────────────────────────────────────────────────────

class _PrefKeys {
  static const uid = 'uni_uid';
  static const userId = 'uni_user_id';
  static const role = 'uni_role';
  static const password = 'uni_password';
  static const busId = 'uni_bus_id';
  static const trackMode = 'uni_track_mode';
}

// ─────────────────────────────────────────────────────────────────────────────
// AuthResult — success/failure wrapper
// ─────────────────────────────────────────────────────────────────────────────

class AuthResult {
  final bool success;
  final UserModel? user;
  final String? errorMessage;

  const AuthResult.success(this.user)
      : success = true,
        errorMessage = null;

  const AuthResult.failure(this.errorMessage)
      : success = false,
        user = null;
}

// ─────────────────────────────────────────────────────────────────────────────
// DriverPrefs
// ─────────────────────────────────────────────────────────────────────────────

class DriverPrefs {
  final String busId;
  final String trackMode; // 'phone' | 'gps_device'

  const DriverPrefs({required this.busId, required this.trackMode});

  bool get isPhoneMode => trackMode == 'phone';
  bool get isGpsDeviceMode => trackMode == 'gps_device';
}

// ─────────────────────────────────────────────────────────────────────────────
// AuthService
// ─────────────────────────────────────────────────────────────────────────────

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final _auth = FirebaseAuth.instance;
  DatabaseReference get _db => globalDB.ref();

  UserModel? _currentUser;
  UserModel? get currentUser => _currentUser;

  // ───────────────────────────────────────────────────────────────────────────
  // 1. SESSION RESTORE
  // App খুললে call করো — session থাকলে UserModel ফেরত দেবে
  // ───────────────────────────────────────────────────────────────────────────

  Future<UserModel?> restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString(_PrefKeys.userId);
      final role = prefs.getString(_PrefKeys.role);

      // দুটোই না থাকলে session নেই
      if (userId == null || userId.isEmpty) return null;
      if (role == null || role.isEmpty) return null;

      // Firebase anonymous session check করো
      var firebaseUser = _auth.currentUser;

      // যদি Firebase session dead হয়, তাহলে আবার anonymous sign-in করো
      if (firebaseUser == null) {
        try {
          final cred = await _auth.signInAnonymously();
          firebaseUser = cred.user;
          // নতুন UID update করো local storage এ
          if (firebaseUser != null) {
            await prefs.setString(_PrefKeys.uid, firebaseUser.uid);
          }
        } catch (_) {
          // Re-auth failed হলে শুধু তখনই clear করো
          // এটা rare case - সাধারণত local session থাকলে auto login হবে
        }
      }

      // Firebase session restored না হলেও local session valid থাকলে keep logged in
      if (firebaseUser == null) {
        // Firebase restore failed, কিন্তু local session আছে
        // User কে logged in রাখো
        _currentUser = UserModel(
          uid: prefs.getString(_PrefKeys.uid) ?? '',
          userId: userId,
          role: UserRoleX.fromString(role),
        );
        return _currentUser;
      }

      _currentUser = UserModel(
        uid: prefs.getString(_PrefKeys.uid) ?? firebaseUser.uid,
        userId: userId,
        role: UserRoleX.fromString(role),
      );

      return _currentUser;
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 2. LOGIN
  // ID + Password নিয়ে anonymous Firebase sign-in করে session save করে
  // ───────────────────────────────────────────────────────────────────────────

  Future<AuthResult> login({
    required String userId,
    required String password,
  }) async {
    final trimId = userId.trim();
    final trimPass = password.trim();

    // Basic validation
    if (trimId.isEmpty) {
      return const AuthResult.failure('Student ID is required.');
    }
    if (trimPass.isEmpty) {
      return const AuthResult.failure('Password is required.');
    }

    // ── Driver check ────────────────────────────────────────────────────────
    final isDriver =
        trimId.toLowerCase() == 'driver' && trimPass.toLowerCase() == 'driver';

    try {
      // Anonymous Firebase sign-in
      final cred = _auth.currentUser != null
          ? await _auth.signInAnonymously()
          : await _auth.signInAnonymously();

      final uid = cred.user!.uid;

      // Role নির্ধারণ
      final role = isDriver ? UserRole.driver : UserRole.student;

      // Firebase Realtime DB তে user record তৈরি / update
      final userRef = _db.child('users/$uid');
      final snapshot = await userRef.get();

      if (!snapshot.exists) {
        await userRef.set({
          'userId': trimId,
          'role': role.value,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        });
      } else if (isDriver) {
        // Driver হলে role update করে রাখো
        await userRef.update({'role': 'driver'});
      }

      _currentUser = UserModel(
        uid: uid,
        userId: trimId,
        role: role,
      );

      await _persistSession(_currentUser!, password: trimPass);
      return AuthResult.success(_currentUser);
    } on FirebaseAuthException catch (e) {
      return AuthResult.failure(_friendlyError(e.code));
    } catch (e) {
      return const AuthResult.failure(
          'Login failed. Please check your connection.');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 3. ROLE SELECTION
  // RoleSelectScreen থেকে call করো — student/teacher role save করে
  // ───────────────────────────────────────────────────────────────────────────

  Future<AuthResult> selectRole(UserRole role) async {
    if (_currentUser == null) {
      return const AuthResult.failure(
          'No active session. Please log in again.');
    }

    try {
      // Firebase তে role update
      await _db.child('users/${_currentUser!.uid}').update({
        'role': role.value,
      });

      _currentUser = _currentUser!.copyWith(role: role);

      // SharedPreferences এ role save
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_PrefKeys.role, role.value);

      return AuthResult.success(_currentUser);
    } catch (e) {
      return const AuthResult.failure('Failed to save role. Please try again.');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 4. DRIVER PREFERENCES
  // Bus select এবং track mode save/load
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> saveDriverPreferences({
    required String busId,
    required String trackMode,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefKeys.busId, busId);
    await prefs.setString(_PrefKeys.trackMode, trackMode);
  }

  Future<DriverPrefs?> loadDriverPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final busId = prefs.getString(_PrefKeys.busId);
    final trackMode = prefs.getString(_PrefKeys.trackMode);
    if (busId == null || trackMode == null) return null;
    return DriverPrefs(busId: busId, trackMode: trackMode);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 5. LOGOUT
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> logout() async {
    try {
      await _auth.signOut();
    } catch (_) {}
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await _clearPrefs(prefs);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 6. AUTH STATE STREAM
  // ───────────────────────────────────────────────────────────────────────────

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ───────────────────────────────────────────────────────────────────────────
  // PRIVATE HELPERS
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> _persistSession(UserModel user,
      {required String password}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefKeys.uid, user.uid);
    await prefs.setString(_PrefKeys.userId, user.userId);
    await prefs.setString(_PrefKeys.role, user.role.value);
    await prefs.setString(_PrefKeys.password, password);
  }

  Future<void> _clearPrefs(SharedPreferences prefs) async {
    await prefs.remove(_PrefKeys.uid);
    await prefs.remove(_PrefKeys.userId);
    await prefs.remove(_PrefKeys.role);
    await prefs.remove(_PrefKeys.password);
    await prefs.remove(_PrefKeys.busId);
    await prefs.remove(_PrefKeys.trackMode);
    // Clear permission flags so they show again on next login
    await prefs.remove('battery_opt_requested');
    await prefs.remove('notification_perm_requested');
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'network-request-failed':
        return 'No internet connection. Please try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment.';
      case 'operation-not-allowed':
        return 'Login is disabled. Contact administrator.';
      default:
        return 'Login failed ($code). Please try again.';
    }
  }
}
