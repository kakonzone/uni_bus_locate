import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../../models/bus_model.dart';
import '../../models/stoppage_model.dart';
import '../../providers/bus_providers.dart';
import '../../screens/shared/map_screen.dart' show MapScreenArgs;
import '../../services/student_background_service.dart';
import '../../services/student_tracking_state.dart';
import '../../theme/app_color.dart';

class StoppageTimelineScreen extends ConsumerStatefulWidget {
  final String busId;
  final String busName;
  final String route;

  const StoppageTimelineScreen({
    super.key,
    required this.busId,
    required this.busName,
    required this.route,
  });

  @override
  ConsumerState<StoppageTimelineScreen> createState() =>
      _StoppageTimelineScreenState();
}

class _StoppageTimelineScreenState
    extends ConsumerState<StoppageTimelineScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _isTrackingEnabled = true;
  StreamSubscription? _messageSubscription;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    // Auto-start background tracking for this bus
    _startBackgroundTracking();
    // Load current tracking state for toggle
    _loadTrackingState();
    // Listen for background service messages
    _listenToBackgroundService();
  }

  void _listenToBackgroundService() {
    final service = StudentBackgroundService();
    _messageSubscription = service.messageStream.listen((message) {
      if (message['cmd'] == 'auto_stopped' && mounted) {
        setState(() {
          _isTrackingEnabled = false;
        });
      }
    });
  }

  Future<void> _loadTrackingState() async {
    final isActive = await StudentTrackingState.isTrackingActive();
    final trackedBusId = await StudentTrackingState.getTrackedBusId();
    if (mounted) {
      setState(() {
        _isTrackingEnabled = isActive && trackedBusId == widget.busId;
      });
    }
  }

  Future<void> _startBackgroundTracking() async {
    // Check if we're already tracking a different bus
    final currentTrackedBusId = await StudentTrackingState.getTrackedBusId();
    if (currentTrackedBusId != null && currentTrackedBusId != widget.busId) {
      // Stop tracking the old bus first
      await StudentBackgroundService().stop();
    }

    // Start tracking this bus
    await StudentTrackingState.saveTrackingState(
      busId: widget.busId,
      active: true,
    );
    await StudentBackgroundService().start(
      busId: widget.busId,
      busName: widget.busName,
    );
    debugPrint('[StoppageTimeline] Auto-started tracking for ${widget.busId}');
  }

  Future<void> _toggleTracking(bool enabled) async {
    if (enabled) {
      await StudentTrackingState.saveTrackingState(
        busId: widget.busId,
        active: true,
      );
      await StudentBackgroundService().start(
        busId: widget.busId,
        busName: widget.busName,
      );
    } else {
      await StudentTrackingState.setTrackingActive(false);
      await StudentBackgroundService().stop();
    }
    if (mounted) {
      setState(() {
        _isTrackingEnabled = enabled;
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _messageSubscription?.cancel();
    super.dispose();
  }

  /// Determines which stop the bus has most recently passed / is currently approaching.
  /// Returns the index of the current stop (last passed), or -1 if bus hasn't reached any stop yet.
  int _currentStopIndex(List<Stoppage> stops, BusModel bus) {
    if (stops.isEmpty) return -1;
    if (!bus.active) return -1;

    final busPos = ll.LatLng(bus.lat, bus.lng);
    int currentIndex = -1;

    // Find the last stop the bus has passed (distance < 0.15 km threshold)
    for (int i = 0; i < stops.length; i++) {
      final distKm = stops[i].distanceTo(busPos);
      if (distKm < 0.15) {
        currentIndex = i;
      }
    }

    return currentIndex;
  }

  @override
  Widget build(BuildContext context) {
    final stoppagesAsync = ref.watch(stoppagesProvider(widget.busId));
    final busAsync = ref.watch(busDetailProvider(widget.busId));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.busName,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: stoppagesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('Error loading stops: $e'),
        ),
        data: (stoppages) {
          if (stoppages.isEmpty) {
            return _buildEmptyState();
          }

          return busAsync.when(
            loading: () => _buildTimeline(stoppages, null),
            error: (_, __) => _buildTimeline(stoppages, null),
            data: (bus) => _buildTimeline(stoppages, bus),
          );
        },
      ),
      bottomNavigationBar: _buildLocateBusButton(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.location_off_outlined,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            'No stops configured for this bus',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeline(List<Stoppage> stoppages, BusModel? bus) {
    final currentIndex = bus != null ? _currentStopIndex(stoppages, bus) : -1;
    final isOffline = bus == null || !bus.active;

    return Column(
      children: [
        // Header with bus info
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          color: AppColors.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.busName,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.route,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                ),
              ),
              if (isOffline) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Bus is currently offline',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange[800],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // Notification toggle
              Row(
                children: [
                  const Icon(Icons.notifications_outlined, size: 20, color: AppColors.primary),
                  const SizedBox(width: 8),
                  const Text(
                    'Notify me for this bus',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Switch(
                    value: _isTrackingEnabled,
                    onChanged: _toggleTracking,
                    activeThumbColor: AppColors.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
        // Timeline
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 20),
            itemCount: stoppages.length,
            itemBuilder: (context, index) {
              final stop = stoppages[index];
              final isPassed = index < currentIndex;
              final isNext = index == currentIndex + 1;
              final isCurrent = index == currentIndex;

              return _buildStopItem(
                stop,
                isPassed: isPassed,
                isNext: isNext,
                isCurrent: isCurrent,
                isOffline: isOffline,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStopItem(
    Stoppage stop, {
    required bool isPassed,
    required bool isNext,
    required bool isCurrent,
    required bool isOffline,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeline dot
          Column(
            children: [
              _buildStopDot(
                isPassed: isPassed,
                isNext: isNext,
                isCurrent: isCurrent,
                isOffline: isOffline,
              ),
              if (stop.orderIndex < 1000) // Arbitrary large number to avoid drawing line for last item
                Container(
                  width: 2,
                  height: 40,
                  color: isPassed
                      ? Colors.grey[400]
                      : Colors.grey[300],
                ),
            ],
          ),
          const SizedBox(width: 16),
          // Stop name
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                stop.name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: isNext || isCurrent
                      ? FontWeight.w600
                      : FontWeight.normal,
                  color: isNext || isCurrent
                      ? AppColors.primary
                      : Colors.grey[700],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStopDot({
    required bool isPassed,
    required bool isNext,
    required bool isCurrent,
    required bool isOffline,
  }) {
    Color dotColor;
    double dotSize = 16;

    if (isOffline) {
      dotColor = Colors.grey[400]!;
    } else if (isNext) {
      // Next stop - green with pulse animation
      return AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _pulseAnimation.value,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.green,
                boxShadow: [
                  BoxShadow(
                    color: Colors.green.withValues(alpha: 0.4),
                    blurRadius: 8,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          );
        },
      );
    } else if (isCurrent) {
      dotColor = Colors.green;
      dotSize = 18;
    } else if (isPassed) {
      dotColor = Colors.grey[500]!;
    } else {
      // Not yet reached
      dotColor = Colors.grey[300]!;
    }

    return Container(
      width: dotSize,
      height: dotSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: dotColor,
        border: !isPassed && !isCurrent && !isNext
            ? Border.all(color: Colors.grey[400]!, width: 2)
            : null,
      ),
    );
  }

  Widget _buildLocateBusButton() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton(
          onPressed: () {
            Navigator.pushNamed(
              context,
              '/student/map',
              arguments: MapScreenArgs(
                busId: widget.busId,
                busName: widget.busName,
                route: widget.route,
              ),
            );
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.location_on_outlined, size: 20),
              SizedBox(width: 8),
              Text(
                'Locate Bus',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
