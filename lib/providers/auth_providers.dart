// lib/providers/auth_providers.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SharedPreferences Keys
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
// Enums
// ─────────────────────────────────────────────────────────────────────────────

// UserRole enum টা user_model.dart থেকে import করা হয়েছে।
// এখানে আর define করা নেই।

enum AuthStatus {
  initial, // app launch হচ্ছে, session check চলছে
  unauthenticated, // কোনো session নেই → LoginScreen
  authenticated, // login হয়েছে কিন্তু role select হয়নি → RoleSelectScreen
  roleSelected, // সব ঠিক → role home screen
}

// ─────────────────────────────────────────────────────────────────────────────
// AuthState
// ─────────────────────────────────────────────────────────────────────────────

class AuthState {
  final AuthStatus status;
  final String? uid;
  final String? userId;
  final UserRole? role;
  final String? busId;
  final String? trackMode;
  final String? errorMessage;
  final bool isLoading;
  final User? firebaseUser;

  const AuthState({
    this.status = AuthStatus.initial,
    this.uid,
    this.userId,
    this.role,
    this.busId,
    this.trackMode,
    this.errorMessage,
    this.isLoading = false,
    this.firebaseUser,
  });

  bool get isDriver => role == UserRole.driver;
  bool get isStudent => role == UserRole.student;
  bool get isTeacher => role == UserRole.teacher;

  AuthState copyWith({
    AuthStatus? status,
    String? uid,
    String? userId,
    UserRole? role,
    String? busId,
    String? trackMode,
    String? errorMessage,
    bool? isLoading,
    User? firebaseUser,
  }) {
    return AuthState(
      status: status ?? this.status,
      uid: uid ?? this.uid,
      userId: userId ?? this.userId,
      role: role ?? this.role,
      busId: busId ?? this.busId,
      trackMode: trackMode ?? this.trackMode,
      errorMessage: errorMessage, // null দিলে error clear হয়
      isLoading: isLoading ?? this.isLoading,
      firebaseUser: firebaseUser ?? this.firebaseUser,
    );
  }

  @override
  String toString() =>
      'AuthState(status: $status, userId: $userId, role: $role)';
}

// ─────────────────────────────────────────────────────────────────────────────
// AuthNotifier
// ─────────────────────────────────────────────────────────────────────────────

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState()) {
    _restoreSession(); // app launch এ session check
  }

  final _auth = FirebaseAuth.instance;

  // ───────────────────────────────────────────────────────────────────────────
  // SESSION RESTORE — app খুললেই call হয়
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> _restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString(_PrefKeys.userId);
      final roleStr = prefs.getString(_PrefKeys.role);
      final uid = prefs.getString(_PrefKeys.uid);

      // uni_user_id আর uni_role দুটোই না থাকলে → login screen
      if (userId == null ||
          userId.isEmpty ||
          roleStr == null ||
          roleStr.isEmpty) {
        state = state.copyWith(status: AuthStatus.unauthenticated);
        return;
      }

      // Firebase anonymous session check করো
      var firebaseUser = _auth.currentUser;

      // যদি Firebase session dead হয়, তাহলে আবার anonymous sign-in করো
      if (firebaseUser == null) {
        try {
          final cred = await _auth.signInAnonymously();
          firebaseUser = cred.user;
          // নতুন UID update করো local storage এ
          await prefs.setString(_PrefKeys.uid, firebaseUser!.uid);
        } catch (_) {
          // Re-auth failed হলে শুধু তখনই clear করো
          // এটা rare case - সাধারণত local session থাকলে auto login হবে
        }
      }

      // Firebase session restored না হলেও local session valid থাকলে keep logged in
      if (firebaseUser == null) {
        // Firebase restore failed, কিন্তু local session আছে
        // User কে logged in রাখো এবং background এ retry করো
        final role = _parseRole(roleStr);
        final busId = prefs.getString(_PrefKeys.busId);
        final trackMode = prefs.getString(_PrefKeys.trackMode);

        state = AuthState(
          status: AuthStatus.roleSelected,
          uid: uid,
          userId: userId,
          role: role,
          busId: busId,
          trackMode: trackMode,
          firebaseUser: null, // null but still logged in via local session
        );
        // এখানে একটা timer দিয়ে পরে আবার Firebase session try করতে পারো
        // এখনকার মতো এটাই যথেষ্ট
        return;
      }

      final role = _parseRole(roleStr);
      final busId = prefs.getString(_PrefKeys.busId);
      final trackMode = prefs.getString(_PrefKeys.trackMode);

      // Session আছে → সরাসরি role home screen এ যাও
      state = AuthState(
        status: AuthStatus.roleSelected,
        uid: uid ?? firebaseUser.uid,
        userId: userId,
        role: role,
        busId: busId,
        trackMode: trackMode,
        firebaseUser: firebaseUser,
      );
    } catch (_) {
      state = state.copyWith(status: AuthStatus.unauthenticated);
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // LOGIN — ID + Password দিয়ে
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> login({
    required String userId,
    required String password,
  }) async {
    final trimId = userId.trim();
    final trimPass = password.trim();

    // Validation
    if (trimId.isEmpty) {
      state = state.copyWith(errorMessage: 'Student ID is required.');
      return;
    }
    if (trimPass.isEmpty) {
      state = state.copyWith(errorMessage: 'Password is required.');
      return;
    }

    state = state.copyWith(isLoading: true, errorMessage: null);

    // Driver check — ID এবং Password দুটোই "driver" হলে
    final isDriver =
        trimId.toLowerCase() == 'driver' && trimPass.toLowerCase() == 'driver';

    try {
      // Firebase Anonymous sign-in
      final cred = await _auth.signInAnonymously();
      final uid = cred.user!.uid;

      // Role is set below in state; student/teacher pick role on next screen.

      // SharedPreferences এ session save
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_PrefKeys.uid, uid);
      await prefs.setString(_PrefKeys.userId, trimId);
      await prefs.setString(_PrefKeys.password, trimPass);

      // Driver হলে এখনই role save করো
      // Student/teacher হলে role save হবে RoleSelectScreen থেকে
      if (isDriver) {
        await prefs.setString(_PrefKeys.role, 'driver');
      }

      state = AuthState(
        status: isDriver
            ? AuthStatus.roleSelected // driver → সরাসরি DriverScreen
            : AuthStatus.authenticated, // student/teacher → RoleSelect
        uid: uid,
        userId: trimId,
        role: isDriver ? UserRole.driver : null,
        isLoading: false,
        firebaseUser: cred.user,
      );
    } on FirebaseAuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: _friendlyError(e.code),
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Login failed. Please check your connection.',
      );
    }
  }

  // login screen থেকে call করার জন্য wrapper
  Future<void> loginWithStudentId(String userId, String password) =>
      login(userId: userId, password: password);

  // ───────────────────────────────────────────────────────────────────────────
  // ROLE SELECTION — RoleSelectScreen থেকে call হয়
  // ───────────────────────────────────────────────────────────────────────────
  // login_screen থেকে anonymous uid নেওয়ার জন্য
  Future<String> loginAnonymously() async {
    final cred = await _auth.signInAnonymously();
    return cred.user!.uid;
  }

  Future<void> selectRole(UserRole role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefKeys.role, role.name);
    state = state.copyWith(
      status: AuthStatus.roleSelected,
      role: role,
    );
  }

  // role select screen থেকে string দিয়ে call করার wrapper
  Future<void> setRole(String roleName) async {
    final role = UserRole.values.where((r) => r.name == roleName).firstOrNull;
    if (role == null) return;
    return selectRole(role);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // DRIVER CONFIG — bus select screen থেকে call হয়
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> saveDriverConfig({
    required String busId,
    required String trackMode,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefKeys.busId, busId);
    await prefs.setString(_PrefKeys.trackMode, trackMode);
    state = state.copyWith(busId: busId, trackMode: trackMode);
  }

  Future<void> setTrackMode(String trackMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefKeys.trackMode, trackMode);
    state = state.copyWith(trackMode: trackMode);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // LOGOUT
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> logout() async {
    state = state.copyWith(isLoading: true);
    try {
      await _auth.signOut();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await _clearPrefs(prefs);
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  // Error clear করো
  void clearError() => state = state.copyWith(errorMessage: null);

  // ───────────────────────────────────────────────────────────────────────────
  // PRIVATE HELPERS
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> _clearPrefs(SharedPreferences prefs) async {
    await prefs.remove(_PrefKeys.uid);
    await prefs.remove(_PrefKeys.userId);
    await prefs.remove(_PrefKeys.role);
    await prefs.remove(_PrefKeys.password);
    await prefs.remove(_PrefKeys.busId);
    await prefs.remove(_PrefKeys.trackMode);
  }

  UserRole _parseRole(String? raw) {
    switch (raw?.toLowerCase()) {
      case 'driver':
        return UserRole.driver;
      case 'teacher':
        return UserRole.teacher;
      default:
        return UserRole.student;
    }
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

// ─────────────────────────────────────────────────────────────────────────────
// Providers
// ─────────────────────────────────────────────────────────────────────────────

/// App এর সব জায়গায় এই একটাই provider use করো
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(),
);

/// Splash screen এ use করার জন্য — loading/data/error wrap করা
final authStateProvider = Provider<AsyncValue<AuthState?>>((ref) {
  final s = ref.watch(authProvider);
  if (s.status == AuthStatus.initial) return const AsyncValue.loading();
  if (s.status == AuthStatus.unauthenticated)
    return const AsyncValue.data(null);
  return AsyncValue.data(s);
});

/// শুধু role দরকার হলে
final userRoleProvider = Provider<UserRole?>(
  (ref) => ref.watch(authProvider).role,
);

/// শুধু UID দরকার হলে
final currentUidProvider = Provider<String?>(
  (ref) => ref.watch(authProvider).uid,
);

/// Loading state
final authLoadingProvider = Provider<bool>(
  (ref) => ref.watch(authProvider).isLoading,
);

/// Error message
final authErrorProvider = Provider<String?>(
  (ref) => ref.watch(authProvider).errorMessage,
);

/// Driver ready — bus select হয়েছে কিনা
final driverReadyProvider = Provider<bool>((ref) {
  final s = ref.watch(authProvider);
  return s.isDriver && (s.busId?.isNotEmpty ?? false);
});
