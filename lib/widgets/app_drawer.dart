// lib/widgets/app_drawer.dart
// UniTrack — Shared App Drawer
// Used by Student and Teacher home screens

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Colors (inline to avoid import issues)
// ─────────────────────────────────────────────────────────────────────────────
class _DC {
  static const navy = Color(0xFF1B2CC1);
  static const navyDark = Color(0xFF1221A3);
  static const navyLight = Color(0xFF2D3FD4);
  static const navySurface = Color(0xFFE8EAFB);
  static const green = Color(0xFF22C55E);
  static const textPrimary = Color(0xFF0F172A);
  static const textSecondary = Color(0xFF64748B);
  static const textMuted = Color(0xFF94A3B8);
  static const divider = Color(0xFFE2E8F0);
  static const bg = Color(0xFFF8F9FF);
}

// ─────────────────────────────────────────────────────────────────────────────
// Drawer Item Model
// ─────────────────────────────────────────────────────────────────────────────
class _DrawerItem {
  const _DrawerItem({
    required this.icon,
    required this.label,
    this.badge,
    this.isDestructive = false,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final String? badge;
  final bool isDestructive;
  final VoidCallback? Function(BuildContext)? onTap;
}

// ─────────────────────────────────────────────────────────────────────────────
// AppDrawer
// ─────────────────────────────────────────────────────────────────────────────
class AppDrawer extends ConsumerWidget {
  const AppDrawer({
    super.key,
    required this.role, // 'student' | 'teacher' | 'driver'
    required this.userName,
    required this.userId,
    this.batch,
  });

  final String role;
  final String userName;
  final String userId;
  final String? batch;

  String get _roleLabel {
    switch (role) {
      case 'teacher':
        return 'Faculty Member';
      case 'driver':
        return 'Bus Driver';
      default:
        return batch != null && batch!.isNotEmpty
            ? 'Student · Batch $batch'
            : 'Student';
    }
  }

  IconData get _roleIcon {
    switch (role) {
      case 'teacher':
        return Icons.school_rounded;
      case 'driver':
        return Icons.drive_eta_rounded;
      default:
        return Icons.person_rounded;
    }
  }

  Color get _roleColor {
    switch (role) {
      case 'teacher':
        return const Color(0xFFF59E0B);
      case 'driver':
        return _DC.green;
      default:
        return _DC.navy;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Drawer(
      backgroundColor: Colors.white,
      width: MediaQuery.of(context).size.width * 0.82,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────────
          _DrawerHeader(
            userName: userName,
            userId: userId,
            roleLabel: _roleLabel,
            roleIcon: _roleIcon,
            roleColor: _roleColor,
          ),

          // ── Menu Items ──────────────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionLabel(label: 'Navigation'),
                  const SizedBox(height: 6),

                  _DrawerTile(
                    icon: role == 'teacher'
                        ? Icons.dashboard_rounded
                        : Icons.directions_bus_rounded,
                    label: role == 'teacher' ? 'Overview' : 'Bus List',
                    isActive: true,
                    onTap: () => Navigator.pop(context),
                  ),

                  _DrawerTile(
                    icon: Icons.map_rounded,
                    label: 'Live Map',
                    onTap: () {
                      Navigator.pop(context);
                      if (role == 'teacher') {
                        Navigator.pushNamed(context, '/teacher/map',
                            arguments: '');
                      } else {
                        Navigator.pushNamed(context, '/student/map',
                            arguments: '');
                      }
                    },
                  ),

                  if (role == 'teacher') ...[
                    _DrawerTile(
                      icon: Icons.bar_chart_rounded,
                      label: 'Statistics',
                      onTap: () => Navigator.pop(context),
                    ),
                  ],

                  const SizedBox(height: 16),
                  const Divider(color: _DC.divider, thickness: 1),
                  const SizedBox(height: 12),

                  _SectionLabel(label: 'General'),
                  const SizedBox(height: 6),

                  _DrawerTile(
                    icon: Icons.info_outline_rounded,
                    label: 'About UniTrack',
                    onTap: () {
                      Navigator.pop(context);
                      showAboutDialog(
                        context: context,
                        applicationName: 'UniTrack',
                        applicationVersion: 'v1.0.0',
                        applicationIcon: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: _DC.navy,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.directions_bus_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                        children: const [
                          Text(
                            'University Bus Tracking System — real-time GPS tracking for campus buses.',
                            style: TextStyle(fontFamily: 'DM Sans'),
                          ),
                        ],
                      );
                    },
                  ),

                  _DrawerTile(
                    icon: Icons.help_outline_rounded,
                    label: 'Help & Support',
                    onTap: () {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text(
                            'Contact: support@unitrack.edu.bd',
                            style: TextStyle(fontFamily: 'DM Sans'),
                          ),
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: _DC.textPrimary,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 16),
                  const Divider(color: _DC.divider, thickness: 1),
                  const SizedBox(height: 12),

                  // ── Logout ──────────────────────────────────────────────
                  _DrawerTile(
                    icon: Icons.logout_rounded,
                    label: 'Logout',
                    isDestructive: true,
                    onTap: () => _confirmLogout(context),
                  ),
                ],
              ),
            ),
          ),

          // ── Footer ──────────────────────────────────────────────────────
          _DrawerFooter(role: role),
        ],
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Logout',
          style: TextStyle(
            fontFamily: 'DM Sans',
            fontWeight: FontWeight.w700,
          ),
        ),
        content: const Text(
          'Are you sure you want to logout?',
          style: TextStyle(fontFamily: 'DM Sans'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(
                fontFamily: 'DM Sans',
                color: Colors.grey.shade600,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              final prefs = await SharedPreferences.getInstance();
              await prefs.clear();
              if (context.mounted) {
                Navigator.of(context)
                    .pushNamedAndRemoveUntil('/login', (_) => false);
              }
            },
            child: const Text(
              'Logout',
              style:
                  TextStyle(fontFamily: 'DM Sans', fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Drawer Header
// ─────────────────────────────────────────────────────────────────────────────
class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({
    required this.userName,
    required this.userId,
    required this.roleLabel,
    required this.roleIcon,
    required this.roleColor,
  });

  final String userName;
  final String userId;
  final String roleLabel;
  final IconData roleIcon;
  final Color roleColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1221A3), Color(0xFF2D3FD4)],
        ),
        borderRadius: BorderRadius.only(topRight: Radius.circular(28)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Close button
              Align(
                alignment: Alignment.topRight,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white60,
                      size: 18,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Avatar
              Stack(
                children: [
                  Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withOpacity(0.3),
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        userName.isNotEmpty ? userName[0].toUpperCase() : '?',
                        style: const TextStyle(
                          fontFamily: 'DM Sans',
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: roleColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: Icon(roleIcon, size: 10, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Name
              Text(
                userName,
                style: const TextStyle(
                  fontFamily: 'DM Sans',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 3),

              // ID
              Text(
                userId,
                style: const TextStyle(
                  fontFamily: 'DM Sans',
                  fontSize: 12,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 10),

              // Role badge
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(roleIcon, size: 12, color: Colors.white70),
                    const SizedBox(width: 5),
                    Text(
                      roleLabel,
                      style: const TextStyle(
                        fontFamily: 'DM Sans',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section Label
// ─────────────────────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontFamily: 'DM Sans',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: _DC.textMuted,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Drawer Tile
// ─────────────────────────────────────────────────────────────────────────────
class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.icon,
    required this.label,
    this.badge,
    this.isActive = false,
    this.isDestructive = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? badge;
  final bool isActive;
  final bool isDestructive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color activeColor = _DC.navy;
    final Color destructColor = const Color(0xFFEF4444);
    final Color color = isDestructive
        ? destructColor
        : isActive
            ? activeColor
            : _DC.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: isActive ? _DC.navy.withOpacity(0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          splashColor: color.withOpacity(0.08),
          highlightColor: color.withOpacity(0.05),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isActive
                        ? _DC.navy.withOpacity(0.10)
                        : isDestructive
                            ? destructColor.withOpacity(0.08)
                            : _DC.bg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'DM Sans',
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                      color: isDestructive ? destructColor : _DC.textPrimary,
                    ),
                  ),
                ),
                if (badge != null) ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _DC.navy,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        fontFamily: 'DM Sans',
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
                if (isActive)
                  Icon(Icons.circle, size: 6, color: _DC.navy.withOpacity(0.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Drawer Footer
// ─────────────────────────────────────────────────────────────────────────────
class _DrawerFooter extends StatelessWidget {
  const _DrawerFooter({required this.role});
  final String role;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      decoration: BoxDecoration(
        color: _DC.bg,
        borderRadius: const BorderRadius.only(bottomRight: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: _DC.divider, width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _DC.navy,
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.directions_bus_rounded,
              color: Colors.white,
              size: 17,
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'UniTrack',
                style: TextStyle(
                  fontFamily: 'DM Sans',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _DC.textPrimary,
                ),
              ),
              Text(
                'v1.0.0  ·  ${role[0].toUpperCase()}${role.substring(1)}',
                style: const TextStyle(
                  fontFamily: 'DM Sans',
                  fontSize: 10,
                  color: _DC.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
