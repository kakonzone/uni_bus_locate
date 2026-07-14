import 'package:flutter/material.dart';

/// Generic shimmer placeholder line, e.g. used for the header username
/// while [currentUserProvider] is loading.
class ShimmerLine extends StatelessWidget {
  final double width;
  const ShimmerLine({super.key, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 16,
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}
