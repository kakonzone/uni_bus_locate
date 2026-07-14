import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/bus_model.dart';
import 'bus_providers.dart';

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
