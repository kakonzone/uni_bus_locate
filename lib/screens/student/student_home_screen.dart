// lib/screens/student/student_home_screen.dart

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/bus_model.dart';
import '../../providers/bus_providers.dart';
import '../../widgets/bottom_nav.dart';
import '../../widgets/app_drawer.dart';
import '../shared/map_screen.dart' show MapScreenArgs;

extension BusModelUiHelper on BusModel {
  double distanceFrom(double refLat, double refLng) {
    if (lat == 0.0 && lng == 0.0) return double.infinity;
    const r = 6371.0;
    final dLat = _rad(lat - refLat);
    final dLng = _rad(lng - refLng);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(refLat)) *
            math.cos(_rad(lat)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  double _rad(double deg) => deg * math.pi / 180;

  // FIX #4: cap ETA at 120 min
  int? etaMinutes(double refLat, double refLng) {
    if (speed < 1) return null;
    final dist = distanceFrom(refLat, refLng);
    if (dist == double.infinity) return null;
    final eta = ((dist / speed) * 60).round();
    if (eta > 120) return null;
    return eta;
  }

  String get statusLabel {
    if (!active) return 'Inactive';
    if (speed < 2) return 'Stopped';
    return 'Moving';
  }

  Color get statusColor {
    if (!active) return const Color(0xFF9CA3AF);
    if (speed < 2) return const Color(0xFFF59E0B);
    return const Color(0xFF18C761);
  }
}

// ── Providers ────────────────────────────────────────────────────────────────

// FIX #7: autoDispose so SharedPreferences re-reads after login/update
final currentUserProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return {
    'id': prefs.getString('user_id') ?? '2021-CSE-000',
    'batch': prefs.getString('user_batch') ?? '2021',
    'name': prefs.getString('user_name') ?? 'Student',
  };
});

final activeOnlyProvider = StateProvider<bool>((ref) => false);

final filteredBusListProvider = Provider<AsyncValue<List<BusModel>>>((ref) {
  final activeOnly = ref.watch(activeOnlyProvider);
  final buses = ref.watch(busListProvider);

  return buses.whenData((list) {
    if (activeOnly) return list.where((b) => b.active).toList();
    return list;
  });
});

// ── Main Screen ───────────────────────────────────────────────────────────────

class StudentHomeScreen extends ConsumerStatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  ConsumerState<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends ConsumerState<StudentHomeScreen>
    with TickerProviderStateMixin {
  static const _navy = Color(0xFF1B2CC1);
  static const _navyDark = Color(0xFF1221A0);
  static const _navyLight = Color(0xFF2D3FD4);
  static const _green = Color(0xFF18C761);
  static const _surface = Color(0xFFF4F6FF);

  final _scrollCtrl = ScrollController();
  int _tickerIndex = 0;
  Timer? _tickerTimer;
  late AnimationController _headerAnim;
  late AnimationController _tickerAnim;
  late Animation<Offset> _tickerSlide;
  bool _headerCollapsed = false;

  // FIX #5: track last ticker messages to detect list changes
  List<String> _lastTickerMessages = [];

  int _navIndex = 0;

  static const double _campusLat = 23.417188606102346;
  static const double _campusLng = 91.12459015590844;

  @override
  void initState() {
    super.initState();

    _headerAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _tickerAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _tickerSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _tickerAnim, curve: Curves.easeOut));

    _tickerAnim.forward();
    _scrollCtrl.addListener(_onScroll);
    _startTicker();
  }

  void _onScroll() {
    final collapsed = _scrollCtrl.offset > 60;
    if (collapsed != _headerCollapsed) {
      setState(() => _headerCollapsed = collapsed);
      collapsed ? _headerAnim.forward() : _headerAnim.reverse();
    }
  }

  void _startTicker() {
    _tickerTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      // FIX #1: guard the entire callback against post-dispose execution.
      try {
        if (!mounted) return;

        // FIX #3: reset _tickerIndex if the underlying message list length
        // changed since the last tick (e.g. busListProvider updated).
        final currentBuses = ref.read(busListProvider).valueOrNull ?? [];
        final currentMessages = _buildTickerMessages(currentBuses);
        if (currentMessages.length != _lastTickerMessages.length) {
          _lastTickerMessages = List.from(currentMessages);
          _tickerIndex = 0;
        }

        // FIX #1: only reverse if still mounted AND animation is running.
        if (mounted && _tickerAnim.isAnimating) {
          await _tickerAnim.reverse();
        }
        // FIX #1: re-check mounted immediately after the await gap.
        if (!mounted) return;

        setState(() => _tickerIndex++);

        // FIX #9: mounted check before forward()
        if (mounted) _tickerAnim.forward();
      } catch (_) {
        // Swallow errors caused by widget disposal mid-tick.
      }
    });
  }

  // FIX #2: specific exception handling in nav tap
  void _onNavTap(int index) {
    if (index == 1) {
      final buses = ref.read(busListProvider).valueOrNull ?? [];
      try {
        final activeBus = buses.firstWhere((b) => b.active);
        // FIX #2 (UI): briefly highlight the map tab while the map screen
        // is open, then restore the previous index when it pops.
        final previousIndex = _navIndex;
        setState(() => _navIndex = 1);
        Navigator.pushNamed(
          context,
          '/student/map',
          arguments: MapScreenArgs(
            busId: activeBus.id,
            busName: activeBus.name,
            route: activeBus.route,
          ),
        ).then((_) {
          if (!mounted) return;
          setState(() => _navIndex = previousIndex);
        });
      } on StateError catch (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'No buses available. Select a bus from the list.',
              style: TextStyle(fontFamily: 'DM Sans'),
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: _navy,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Something went wrong: ${e.runtimeType}',
              style: const TextStyle(fontFamily: 'DM Sans'),
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.redAccent,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      return;
    }
    setState(() => _navIndex = index);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _tickerTimer?.cancel();
    _headerAnim.dispose();
    _tickerAnim.dispose();
    super.dispose();
  }

  List<String> _buildTickerMessages(List<BusModel> buses) {
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

  // FIX #5: helper to compare message lists
  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(currentUserProvider);
    final busesAsync = ref.watch(filteredBusListProvider);
    final activeOnly = ref.watch(activeOnlyProvider);
    final allBuses = ref.watch(busListProvider).valueOrNull ?? [];
    final hasLive = allBuses.any((b) => b.active);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _surface,
        drawer: userAsync.when(
          data: (user) => AppDrawer(
            role: 'student',
            userName: user['name'] ?? 'Student',
            userId: user['id'] ?? '',
            batch: user['batch'],
          ),
          loading: () =>
              AppDrawer(role: 'student', userName: 'Student', userId: ''),
          error: (_, __) =>
              AppDrawer(role: 'student', userName: 'Student', userId: ''),
        ),
        bottomNavigationBar: UniTrackBottomNav(
          currentIndex: _navIndex,
          onTap: _onNavTap,
          isTeacher: false,
          hasLiveActivity: hasLive,
        ),
        body: RefreshIndicator(
          color: _navy,
          // FIX #1: timeout throws instead of returning []
          onRefresh: () async {
            ref.invalidate(busListProvider);
            try {
              await ref.read(busListProvider.future).timeout(
                    const Duration(seconds: 5),
                    onTimeout: () =>
                        throw TimeoutException('Bus data fetch timed out'),
                  );
            } catch (_) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text(
                      'Failed to refresh. Check your connection.',
                      style: TextStyle(fontFamily: 'DM Sans'),
                    ),
                    behavior: SnackBarBehavior.floating,
                    backgroundColor: Colors.redAccent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                );
              }
            }
          },
          child: CustomScrollView(
            controller: _scrollCtrl,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 210,
                backgroundColor: _navy,
                elevation: 0,
                systemOverlayStyle: SystemUiOverlayStyle.light,
                automaticallyImplyLeading: false,
                leading: Builder(
                  builder: (context) => IconButton(
                    icon: const Icon(Icons.menu_rounded,
                        color: Colors.white, size: 24),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      Scaffold.of(context).openDrawer();
                    },
                  ),
                ),
                actions: [
                  IconButton(
                    icon: Stack(
                      children: [
                        const Icon(Icons.notifications_outlined,
                            color: Colors.white, size: 24),
                        if (hasLive)
                          Positioned(
                            right: 0,
                            top: 0,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _green,
                                shape: BoxShape.circle,
                                border: Border.all(color: _navy, width: 1.5),
                              ),
                            ),
                          ),
                      ],
                    ),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            hasLive
                                ? '${allBuses.where((b) => b.active).length} bus(es) are currently active.'
                                : 'No active buses right now.',
                            style: const TextStyle(fontFamily: 'DM Sans'),
                          ),
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: _navy,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.pin,
                  background: _buildHeader(userAsync, allBuses),
                ),
              ),
              SliverToBoxAdapter(
                child: busesAsync.when(
                  data: (buses) => _buildTicker(allBuses),
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ),
              SliverToBoxAdapter(
                child: _buildFilterRow(
                  activeOnly: activeOnly,
                  busesAsync: busesAsync,
                ),
              ),
              busesAsync.when(
                data: (buses) {
                  if (buses.isEmpty) {
                    return SliverFillRemaining(
                      child: _buildEmptyState(activeOnly),
                    );
                  }
                  return SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => _BusCard(
                          bus: buses[index],
                          campusLat: _campusLat,
                          campusLng: _campusLng,
                          // FIX #8: null onTap for inactive buses
                          onTap: buses[index].active
                              ? () => _openMap(buses[index])
                              : null,
                        ),
                        childCount: buses.length,
                      ),
                    ),
                  );
                },
                loading: () => const SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 20),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      _buildSkeletonItem,
                      childCount: 4,
                    ),
                  ),
                ),
                error: (err, _) => SliverFillRemaining(
                  child: _buildErrorState(err.toString()),
                ),
              ),
            ],
          ),
        ),
        floatingActionButton: AnimatedBuilder(
          animation: _headerAnim,
          builder: (_, __) => _headerCollapsed
              ? FloatingActionButton.small(
                  backgroundColor: _navy,
                  onPressed: () => _scrollCtrl.animateTo(
                    0,
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOut,
                  ),
                  child: const Icon(Icons.keyboard_arrow_up_rounded,
                      color: Colors.white),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  static Widget _buildSkeletonItem(BuildContext context, int index) =>
      const _BusCardSkeleton();

  // ── Header ─────────────────────────────────────────────────────────────────

  // FIX #6: allBuses passed as parameter — no extra ref.watch inside
  Widget _buildHeader(
      AsyncValue<Map<String, String>> userAsync, List<BusModel> allBuses) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [_navyDark, _navyLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 62, 20, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: userAsync.when(
                      data: (user) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _greeting(),
                            style: const TextStyle(
                                fontFamily: 'DMSans',
                                fontSize: 12,
                                color: Colors.white60),
                          ),
                          Text(
                            user['name'] ?? 'Student',
                            style: const TextStyle(
                              fontFamily: 'DMSans',
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -0.3,
                            ),
                          ),
                          Text(
                            '${user['id']}  ·  Batch ${user['batch']}',
                            style: const TextStyle(
                              fontFamily: 'DMSans',
                              fontSize: 11,
                              color: Colors.white38,
                            ),
                          ),
                        ],
                      ),
                      loading: () => const _ShimmerLine(width: 140),
                      error: (_, __) => const SizedBox.shrink(),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.directions_bus_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // FIX #6: pass allBuses directly, no second watch
              _buildHeaderStats(allBuses),
            ],
          ),
        ),
      ),
    );
  }

  // FIX #6: accepts allBuses parameter instead of calling ref.watch again
  Widget _buildHeaderStats(List<BusModel> allBuses) {
    final active = allBuses.where((b) => b.active).length;
    final moving = allBuses.where((b) => b.active && b.speed > 2).length;
    final watchers = allBuses.fold<int>(0, (s, b) => s + b.watchCount);
    return _HeaderStatsRow(
      total: allBuses.length,
      active: active,
      moving: moving,
      watchers: watchers,
      green: _green,
    );
  }

  // ── Ticker ──────────────────────────────────────────────────────────────────

  Widget _buildTicker(List<BusModel> buses) {
    final messages = _buildTickerMessages(buses);
    if (messages.isEmpty) return const SizedBox.shrink();

    // FIX #5: reset index when message list changes
    if (!_listEquals(messages, _lastTickerMessages)) {
      _lastTickerMessages = List.from(messages);
      _tickerIndex = 0;
    }

    final msg = messages[_tickerIndex % messages.length];

    return Container(
      color: const Color(0xFF0E1B8C),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: _green,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'LIVE',
              style: TextStyle(
                fontFamily: 'DMSans',
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
                  fontFamily: 'DMSans',
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

  // ── Filter Row ───────────────────────────────────────────────────────────────

  Widget _buildFilterRow({
    required bool activeOnly,
    required AsyncValue<List<BusModel>> busesAsync,
  }) {
    return Container(
      color: _surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: busesAsync.maybeWhen(
              data: (buses) {
                final count = buses.length;
                return RichText(
                  text: TextSpan(
                    style: const TextStyle(fontFamily: 'DMSans'),
                    children: [
                      TextSpan(
                        text: '$count ',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                        ),
                      ),
                      TextSpan(
                        text: count == 1 ? 'Bus' : 'Buses',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ],
                  ),
                );
              },
              orElse: () => const Text(
                'Buses',
                style: TextStyle(
                  fontFamily: 'DMSans',
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827),
                ),
              ),
            ),
          ),
          _FilterChip(
            label: 'Active Only',
            selected: activeOnly,
            icon: Icons.gps_fixed_rounded,
            onTap: () {
              ref.read(activeOnlyProvider.notifier).state = !activeOnly;
              HapticFeedback.selectionClick();
            },
          ),
        ],
      ),
    );
  }

  // ── Empty / Error States ─────────────────────────────────────────────────────

  Widget _buildEmptyState(bool activeOnly) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _navy.withValues(alpha: 0.07),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.directions_bus_outlined,
                  color: _navy, size: 36),
            ),
            const SizedBox(height: 20),
            Text(
              activeOnly ? 'No Active Buses' : 'No Buses Found',
              style: const TextStyle(
                fontFamily: 'DMSans',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              activeOnly
                  ? 'All buses are currently inactive.\nTry turning off the Active Only filter.'
                  : 'No buses available at the moment.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'DMSans',
                fontSize: 13,
                color: Colors.grey,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // FIX #3: err is now shown as debug text
  Widget _buildErrorState(String err) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded,
                color: Colors.redAccent, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Connection Error',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Unable to fetch bus data.\nCheck your internet connection.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 13,
                color: Colors.grey,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              err,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'DMSans',
                fontSize: 10,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning,';
    if (h < 17) return 'Good afternoon,';
    return 'Good evening,';
  }

  void _openMap(BusModel bus) {
    Navigator.pushNamed(
      context,
      '/student/map',
      arguments: MapScreenArgs(
        busId: bus.id,
        busName: bus.name,
        route: bus.route,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  HEADER STATS ROW
// ════════════════════════════════════════════════════════════════════════════

class _HeaderStatsRow extends StatelessWidget {
  final int total;
  final int active;
  final int moving;
  final int watchers;
  final Color green;

  const _HeaderStatsRow({
    required this.total,
    required this.active,
    required this.moving,
    required this.watchers,
    required this.green,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _HeaderStat(label: 'Total Buses', value: '$total')),
        _divider(),
        Expanded(
          child: _HeaderStat(
            label: 'Active Now',
            value: '$active',
            valueColor: green,
          ),
        ),
        _divider(),
        Expanded(child: _HeaderStat(label: 'Moving', value: '$moving')),
        _divider(),
        Expanded(child: _HeaderStat(label: 'Watching', value: '$watchers')),
      ],
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 28,
        color: Colors.white12,
        margin: const EdgeInsets.symmetric(horizontal: 8),
      );
}

// ════════════════════════════════════════════════════════════════════════════
//  BUS CARD
// ════════════════════════════════════════════════════════════════════════════

class _BusCard extends StatefulWidget {
  final BusModel bus;
  final double campusLat;
  final double campusLng;
  // FIX #8: nullable onTap
  final VoidCallback? onTap;

  const _BusCard({
    required this.bus,
    required this.campusLat,
    required this.campusLng,
    required this.onTap,
  });

  @override
  State<_BusCard> createState() => _BusCardState();
}

class _BusCardState extends State<_BusCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleCtrl;
  late Animation<double> _scaleAnim;

  static const _navy = Color(0xFF1B2CC1);

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scaleAnim = Tween(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeIn),
    );
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bus = widget.bus;
    final dist = bus.distanceFrom(widget.campusLat, widget.campusLng);
    final eta = bus.etaMinutes(widget.campusLat, widget.campusLng);
    final hasLocation = bus.lat != 0.0 && bus.lng != 0.0;

    return GestureDetector(
      onTapDown: widget.onTap != null ? (_) => _scaleCtrl.forward() : null,
      onTapUp: widget.onTap != null
          ? (_) {
              _scaleCtrl.reverse();
              // FIX #8: null-safe call
              widget.onTap?.call();
            }
          : null,
      onTapCancel: widget.onTap != null ? () => _scaleCtrl.reverse() : null,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: bus.active
                    ? _navy.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.04),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BusIconBadge(bus: bus),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  bus.name,
                                  style: const TextStyle(
                                    fontFamily: 'DMSans',
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                              ),
                              _StatusPill(
                                label: bus.statusLabel,
                                color: bus.statusColor,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.route_rounded,
                                  size: 12, color: Colors.grey),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  bus.route,
                                  style: const TextStyle(
                                    fontFamily: 'DMSans',
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (bus.driverName != null &&
                              bus.driverName!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                const Icon(Icons.person_outline_rounded,
                                    size: 12, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(
                                  bus.driverName!,
                                  style: const TextStyle(
                                    fontFamily: 'DMSans',
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (bus.active) ...[
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: Colors.grey.shade100,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Row(
                    children: [
                      _StatChip(
                        icon: Icons.speed_rounded,
                        label: '${bus.speed.toStringAsFixed(0)} km/h',
                        color: const Color(0xFF8B5CF6),
                      ),
                      const SizedBox(width: 8),
                      if (hasLocation && dist != double.infinity)
                        _StatChip(
                          icon: Icons.straighten_rounded,
                          label: dist < 1
                              ? '${(dist * 1000).toStringAsFixed(0)} m'
                              : '${dist.toStringAsFixed(1)} km',
                          color: _navy,
                        ),
                      if (hasLocation && dist != double.infinity)
                        const SizedBox(width: 8),
                      if (eta != null)
                        _StatChip(
                          icon: Icons.access_time_rounded,
                          label: eta < 1 ? 'Arriving' : '~$eta min',
                          color: const Color(0xFF059669),
                        ),
                      const Spacer(),
                      Row(
                        children: [
                          Icon(Icons.visibility_rounded,
                              size: 13, color: Colors.grey.shade400),
                          const SizedBox(width: 4),
                          Text(
                            '${bus.watchCount}',
                            style: TextStyle(
                              fontFamily: 'DMSans',
                              fontSize: 12,
                              color: Colors.grey.shade400,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _navy,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.map_rounded,
                                color: Colors.white, size: 13),
                            SizedBox(width: 5),
                            Text(
                              'Track',
                              style: TextStyle(
                                fontFamily: 'DMSans',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Icon(Icons.schedule_rounded,
                          size: 13, color: Colors.grey.shade400),
                      const SizedBox(width: 5),
                      Text(
                        bus.lastUpdate != null
                            ? 'Last seen ${_timeAgo(bus.lastUpdate!)}'
                            : 'No recent activity',
                        style: TextStyle(
                          fontFamily: 'DMSans',
                          fontSize: 11,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('dd MMM').format(dt);
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  SUB-WIDGETS (unchanged)
// ════════════════════════════════════════════════════════════════════════════

class _BusIconBadge extends StatefulWidget {
  final BusModel bus;
  const _BusIconBadge({required this.bus});

  @override
  State<_BusIconBadge> createState() => _BusIconBadgeState();
}

class _BusIconBadgeState extends State<_BusIconBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.bus.active && widget.bus.speed > 2) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_BusIconBadge old) {
    super.didUpdateWidget(old);
    final shouldAnimate = widget.bus.active && widget.bus.speed > 2;
    if (shouldAnimate && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!shouldAnimate) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.bus.statusColor;
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, child) => Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: const Color(0xFF1B2CC1).withValues(alpha: 0.08),
              border: Border.all(
                color: widget.bus.active
                    ? color.withValues(alpha: 0.25 + _ctrl.value * 0.25)
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: child,
          ),
          child: const Icon(
            Icons.directions_bus_rounded,
            color: Color(0xFF1B2CC1),
            size: 28,
          ),
        ),
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _StatChip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.icon,
    required this.onTap,
  });

  static const _navy = Color(0xFF1B2CC1);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? _navy : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? _navy : Colors.grey.shade200),
          boxShadow: selected
              ? [BoxShadow(color: _navy.withValues(alpha: 0.25), blurRadius: 8)]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: selected ? Colors.white : Colors.grey.shade500,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _HeaderStat(
      {required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: valueColor ?? Colors.white,
            ),
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'DMSans',
            fontSize: 10,
            color: Colors.white54,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _BusCardSkeleton extends StatefulWidget {
  const _BusCardSkeleton();

  @override
  State<_BusCardSkeleton> createState() => _BusCardSkeletonState();
}

class _BusCardSkeletonState extends State<_BusCardSkeleton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween(begin: 0.4, end: 0.9).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        height: 90,
        decoration: BoxDecoration(
          color: Colors.grey.shade200.withValues(alpha: _anim.value),
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}

class _ShimmerLine extends StatelessWidget {
  final double width;
  const _ShimmerLine({required this.width});

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
