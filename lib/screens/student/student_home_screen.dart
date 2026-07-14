// lib/screens/student/student_home_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/bus_model.dart';
import '../../providers/bus_providers.dart';
import '../../providers/student_home_providers.dart';
import '../../theme/app_color.dart';
import '../../widgets/bottom_nav.dart';
import '../../widgets/app_drawer.dart';
import '../shared/map_screen.dart' show MapScreenArgs;

import '../../widgets/live_ticker_bar.dart';
import '../../widgets/student_home_header.dart';
import '../../widgets/student_bus_card.dart';
import '../../widgets/bus_card_shimmer.dart';
import '../../theme/app_text_styles.dart';

class StudentHomeScreen extends ConsumerStatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  ConsumerState<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends ConsumerState<StudentHomeScreen>
    with SingleTickerProviderStateMixin {
  final _scrollCtrl = ScrollController();
  late AnimationController _headerAnim;
  bool _headerCollapsed = false;

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

    _scrollCtrl.addListener(_onScroll);
  }

  void _onScroll() {
    final collapsed = _scrollCtrl.offset > 60;
    if (collapsed != _headerCollapsed) {
      setState(() => _headerCollapsed = collapsed);
      collapsed ? _headerAnim.forward() : _headerAnim.reverse();
    }
  }

  // FIX #2: specific exception handling in nav tap
  void _onNavTap(int index) {
    if (index == 1) {
      // Live Map tab: show ALL active buses (busId: null)
      final previousIndex = _navIndex;
      setState(() => _navIndex = 1);
      Navigator.pushNamed(
        context,
        '/student/map',
        arguments: null, // null busId = all-buses mode
      ).then((_) {
        if (!mounted) return;
        setState(() => _navIndex = previousIndex);
      });
      return;
    }
    setState(() => _navIndex = index);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _headerAnim.dispose();
    super.dispose();
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
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          SystemNavigator.pop();
        },
        child: Scaffold(
          backgroundColor: AppColors.surface,
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
            color: AppColors.navy,
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
                        style: TextStyle(fontFamily: AppTextStyles.fontFamily),
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
                  backgroundColor: AppColors.navy,
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
                      icon: const Icon(Icons.map_outlined,
                          color: Colors.white, size: 24),
                      onPressed: () {
                        Navigator.pushNamed(
                          context,
                          '/student/map',
                          arguments: null, // null busId = show all buses
                        );
                      },
                      tooltip: 'View All Buses',
                    ),
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
                                  color: AppColors.green,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: AppColors.navy, width: 1.5),
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
                              style: const TextStyle(fontFamily: AppTextStyles.fontFamily),
                            ),
                            behavior: SnackBarBehavior.floating,
                            backgroundColor: AppColors.navy,
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
                    background: StudentHomeHeader(allBuses: allBuses),
                  ),
                ),
                SliverToBoxAdapter(
                  child: busesAsync.when(
                    data: (_) => LiveTickerBar(buses: allBuses),
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
                          (context, index) => StudentBusCard(
                            key: ValueKey(buses[index].id),
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
                    backgroundColor: AppColors.navy,
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
      ),
    );
  }

  static Widget _buildSkeletonItem(BuildContext context, int index) =>
      const BusCardShimmer();

  // ── Filter Row ───────────────────────────────────────────────────────────────

  Widget _buildFilterRow({
    required bool activeOnly,
    required AsyncValue<List<BusModel>> busesAsync,
  }) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: busesAsync.maybeWhen(
              data: (buses) {
                final count = buses.length;
                return RichText(
                  text: TextSpan(
                    style: const TextStyle(fontFamily: AppTextStyles.fontFamily),
                    children: [
                      TextSpan(
                        text: '$count ',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppColors.headingGray,
                        ),
                      ),
                      TextSpan(
                        text: count == 1 ? 'Bus' : 'Buses',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.labelGray,
                        ),
                      ),
                    ],
                  ),
                );
              },
              orElse: () => const Text(
                'Buses',
                style: TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.headingGray,
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              ref.read(activeOnlyProvider.notifier).state = !activeOnly;
              HapticFeedback.selectionClick();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: activeOnly ? AppColors.navy : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: activeOnly ? AppColors.navy : Colors.grey.shade200,
                ),
                boxShadow: activeOnly
                    ? [
                        BoxShadow(
                          color: AppColors.navy.withValues(alpha: 0.25),
                          blurRadius: 8,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.gps_fixed_rounded,
                    size: 13,
                    color: activeOnly ? Colors.white : Colors.grey.shade500,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Active Only',
                    style: TextStyle(
                      fontFamily: AppTextStyles.fontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: activeOnly ? Colors.white : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
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
                color: AppColors.navy.withValues(alpha: 0.07),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.directions_bus_outlined,
                  color: AppColors.navy, size: 36),
            ),
            const SizedBox(height: 20),
            Text(
              activeOnly ? 'No Active Buses' : 'No Buses Found',
              style: const TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.headingGray,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              activeOnly
                  ? 'All buses are currently inactive.\nTry turning off the Active Only filter.'
                  : 'No buses available at the moment.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: AppTextStyles.fontFamily,
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
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.headingGray,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Unable to fetch bus data.\nCheck your internet connection.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AppTextStyles.fontFamily,
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
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 10,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openMap(BusModel bus) {
    Navigator.pushNamed(
      context,
      '/student/timeline',
      arguments: MapScreenArgs(
        busId: bus.id,
        busName: bus.name,
        route: bus.route,
      ),
    );
  }
}
