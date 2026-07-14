import 'dart:async';
import 'package:flutter/material.dart';

import '../models/bus_model.dart';
import '../theme/app_color.dart';
import '../theme/app_text_styles.dart';

/// Rotating "LIVE" status ticker.
///
/// Self-contained: owns its own [Timer] and [AnimationController], and
/// reacts to bus-list changes via [didUpdateWidget] instead of checking
/// the message-list length on every 3-second timer tick like the old
/// inline version did.
class LiveTickerBar extends StatefulWidget {
  final List<BusModel> buses;

  const LiveTickerBar({super.key, required this.buses});

  @override
  State<LiveTickerBar> createState() => _LiveTickerBarState();
}

class _LiveTickerBarState extends State<LiveTickerBar>
    with SingleTickerProviderStateMixin {
  Timer? _tickerTimer;
  late AnimationController _tickerAnim;
  late Animation<Offset> _tickerSlide;

  int _tickerIndex = 0;
  late List<String> _messages;

  @override
  void initState() {
    super.initState();

    _tickerAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _tickerSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _tickerAnim, curve: Curves.easeOut));

    _messages = _buildMessages(widget.buses);
    _tickerAnim.forward();
    _startTicker();
  }

  @override
  void didUpdateWidget(covariant LiveTickerBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Bus list changed (new data pushed from the parent) — rebuild the
    // message list and reset to the first message if it actually differs.
    final newMessages = _buildMessages(widget.buses);
    if (!_listEquals(newMessages, _messages)) {
      setState(() {
        _messages = newMessages;
        _tickerIndex = 0;
      });
    }
  }

  void _startTicker() {
    _tickerTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      // Guard the entire callback against post-dispose execution.
      try {
        if (!mounted) return;

        if (mounted && _tickerAnim.isAnimating) {
          await _tickerAnim.reverse();
        }
        // Re-check mounted immediately after the await gap.
        if (!mounted) return;

        setState(() => _tickerIndex++);

        if (mounted) _tickerAnim.forward();
      } catch (_) {
        // Swallow errors caused by widget disposal mid-tick.
      }
    });
  }

  List<String> _buildMessages(List<BusModel> buses) {
    final active = buses.where((b) => b.active).toList();
    if (active.isEmpty) return ['No buses are currently active.'];

    final msgs = <String>[
      '${active.length} bus${active.length > 1 ? 'es' : ''} currently active',
    ];
    for (final b in active) {
      msgs.add(
        b.speed > 2
            ? '${b.name} is moving at ${b.speed.toStringAsFixed(0)} km/h on ${b.route}'
            : '${b.name} is stopped on ${b.route}',
      );
    }
    return msgs;
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _tickerAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_messages.isEmpty) return const SizedBox.shrink();

    final msg = _messages[_tickerIndex % _messages.length];

    return Container(
      color: AppColors.tickerNavy,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.green,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'LIVE',
              style: TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SlideTransition(
              position: _tickerSlide,
              child: Text(
                msg,
                style: const TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right_rounded,
              color: Colors.white38, size: 16),
        ],
      ),
    );
  }
}
