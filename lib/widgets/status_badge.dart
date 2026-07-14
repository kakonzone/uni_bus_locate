import 'package:flutter/material.dart';

import '../theme/app_color.dart';

class StatusBadge extends StatelessWidget {
  final bool isActive;

  const StatusBadge({super.key, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppColors.activeGreen : AppColors.errorRed;
    final label = isActive ? 'Active' : 'Inactive';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
