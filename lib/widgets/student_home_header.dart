import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/bus_model.dart';
import '../providers/student_home_providers.dart';
import '../theme/app_color.dart';
import '../theme/app_text_styles.dart';
import 'shimmer_line.dart';

/// Collapsible header content inside the student home [SliverAppBar].
class StudentHomeHeader extends ConsumerWidget {
  const StudentHomeHeader({super.key, required this.allBuses});

  final List<BusModel> allBuses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider);
    final activeCount = allBuses.where((b) => b.active).length;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.navyDark, AppColors.navy],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 56, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          userAsync.when(
            data: (user) => Text(
              'Hello, ${user['name'] ?? 'Student'}',
              style: const TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            loading: () => const ShimmerLine(width: 160),
            error: (_, __) => const Text(
              'Hello, Student',
              style: TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            activeCount > 0
                ? '$activeCount bus${activeCount == 1 ? '' : 'es'} live now'
                : 'No buses active right now',
            style: TextStyle(
              fontFamily: AppTextStyles.fontFamily,
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}
