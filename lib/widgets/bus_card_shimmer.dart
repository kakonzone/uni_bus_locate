import 'package:flutter/material.dart';

import '../theme/app_color.dart';

/// Loading skeleton matching [StudentBusCard] layout.
class BusCardShimmer extends StatefulWidget {
  const BusCardShimmer({super.key});

  @override
  State<BusCardShimmer> createState() => _BusCardShimmerState();
}

class _BusCardShimmerState extends State<BusCardShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _box(double w, double h, {BorderRadius? radius}) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Opacity(
        opacity: _anim.value,
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: AppColors.navyMuted,
            borderRadius: radius ?? BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.divider),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _box(52, 52, radius: BorderRadius.circular(14)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _box(120, 14),
                      const SizedBox(height: 8),
                      _box(180, 11),
                    ],
                  ),
                ),
                _box(48, 24, radius: BorderRadius.circular(20)),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: AppColors.divider, height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                _box(50, 32),
                const SizedBox(width: 28),
                _box(50, 32),
                const SizedBox(width: 28),
                _box(50, 32),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
