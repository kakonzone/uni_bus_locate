// lib/models/user_model.dart

// ─────────────────────────────────────────────────────────────────────────────
// UserRole enum
// ─────────────────────────────────────────────────────────────────────────────

enum UserRole { driver, student, teacher }

extension UserRoleX on UserRole {
  String get value {
    switch (this) {
      case UserRole.driver:
        return 'driver';
      case UserRole.student:
        return 'student';
      case UserRole.teacher:
        return 'teacher';
    }
  }

  String get label {
    switch (this) {
      case UserRole.driver:
        return 'Driver';
      case UserRole.student:
        return 'Student';
      case UserRole.teacher:
        return 'Teacher';
    }
  }

  static UserRole fromString(String? value) {
    switch (value?.toLowerCase().trim()) {
      case 'driver':
        return UserRole.driver;
      case 'teacher':
        return UserRole.teacher;
      case 'student':
      default:
        return UserRole.student;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// UserModel
// ─────────────────────────────────────────────────────────────────────────────

class UserModel {
  /// Firebase Anonymous Auth UID
  final String uid;

  /// Student/Driver ID — e.g. "111222021" or "driver"
  final String userId;

  /// Role: driver / student / teacher
  final UserRole role;

  /// Optional display name
  final String? name;

  /// Session created time (epoch ms)
  final int? createdAt;

  const UserModel({
    required this.uid,
    required this.userId,
    required this.role,
    this.name,
    this.createdAt,
  });

  // ── Convenience getters ───────────────────────────────────────────────────

  bool get isDriver => role == UserRole.driver;
  bool get isStudent => role == UserRole.student;
  bool get isTeacher => role == UserRole.teacher;

  String get displayName => (name != null && name!.isNotEmpty) ? name! : userId;

  // ── Firebase serialisation ────────────────────────────────────────────────

  /// Write to Firebase Realtime Database under users/{uid}
  Map<String, dynamic> toFirebaseMap() => {
        'userId': userId,
        'role': role.value,
        if (name != null && name!.isNotEmpty) 'name': name,
        'createdAt': createdAt ?? DateTime.now().millisecondsSinceEpoch,
      };

  Map<String, dynamic> toMap() => toFirebaseMap();

  factory UserModel.fromFirebaseMap(String uid, Map<dynamic, dynamic> map) =>
      UserModel(
        uid: uid,
        userId: (map['userId'] as String?) ?? '',
        role: UserRoleX.fromString(map['role'] as String?),
        name: map['name'] as String?,
        createdAt: map['createdAt'] as int?,
      );

  factory UserModel.fromMap(String uid, Map<dynamic, dynamic> map) =>
      UserModel.fromFirebaseMap(uid, map);

  // ── SharedPreferences serialisation ──────────────────────────────────────

  /// Keys match auth_providers.dart _PrefKeys exactly
  Map<String, String> toPrefsMap() => {
        'uni_uid': uid,
        'uni_user_id': userId,
        'uni_role': role.value,
        'uni_name': name ?? '',
      };

  /// Returns null if required fields are missing
  static UserModel? fromPrefsMap(Map<String, String?> prefs) {
    final uid = prefs['uni_uid'];
    final userId = prefs['uni_user_id'];
    final role = prefs['uni_role'];

    if (uid == null || uid.isEmpty) return null;
    if (userId == null || userId.isEmpty) return null;

    return UserModel(
      uid: uid,
      userId: userId,
      role: UserRoleX.fromString(role),
      name: (prefs['uni_name']?.isNotEmpty ?? false) ? prefs['uni_name'] : null,
    );
  }

  // ── Immutable copy ────────────────────────────────────────────────────────

  UserModel copyWith({
    String? uid,
    String? userId,
    UserRole? role,
    String? name,
    int? createdAt,
  }) =>
      UserModel(
        uid: uid ?? this.uid,
        userId: userId ?? this.userId,
        role: role ?? this.role,
        name: name ?? this.name,
        createdAt: createdAt ?? this.createdAt,
      );

  // ── Equality ──────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserModel &&
          uid == other.uid &&
          userId == other.userId &&
          role == other.role;

  @override
  int get hashCode => Object.hash(uid, userId, role);

  @override
  String toString() =>
      'UserModel(uid: $uid, userId: $userId, role: ${role.value})';
}
