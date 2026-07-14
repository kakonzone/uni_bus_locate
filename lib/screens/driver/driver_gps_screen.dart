// lib/screens/driver/driver_gps_screen.dart
// GPS Hardware Device Setup Screen (GT06N / TK103)
// User enters Device IMEI/ID → app listens to Firebase path for that device
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/firebase_globals.dart';
import '../../theme/app_color.dart';
import '../../theme/app_text_styles.dart';

// ─── Constants ───────────────────────────────────────────────────────────────

// ─── State ────────────────────────────────────────────────────────────────────

enum _ValidationState { idle, checking, valid, invalid }

class _GpsSetupState {
  final String deviceId;
  final _ValidationState validation;
  final String? errorMessage;
  final bool isSaved;
  final String? savedDeviceId;

  const _GpsSetupState({
    this.deviceId = '',
    this.validation = _ValidationState.idle,
    this.errorMessage,
    this.isSaved = false,
    this.savedDeviceId,
  });

  // FIX 5: sentinel allows callers to pass `savedDeviceId: null` to explicitly clear it
  static const Object _sentinel = Object();

  _GpsSetupState copyWith({
    String? deviceId,
    _ValidationState? validation,
    String? errorMessage,
    bool? isSaved,
    Object? savedDeviceId = _sentinel, // FIX 5
    bool clearError = false,
  }) =>
      _GpsSetupState(
        deviceId: deviceId ?? this.deviceId,
        validation: validation ?? this.validation,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        isSaved: isSaved ?? this.isSaved,
        savedDeviceId: identical(savedDeviceId, _sentinel)
            ? this.savedDeviceId
            : savedDeviceId as String?, // FIX 5
      );
}

// ─── Notifier ────────────────────────────────────────────────────────────────

class _GpsSetupNotifier extends StateNotifier<_GpsSetupState> {
  _GpsSetupNotifier() : super(const _GpsSetupState()) {
    _loadSaved();
  }

  static const _prefKey = 'gps_device_id';

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved != null && saved.isNotEmpty) {
      state = state.copyWith(
        savedDeviceId: saved,
        deviceId: saved,
        isSaved: true,
      );
    }
  }

  void onDeviceIdChanged(String value) {
    state = state.copyWith(
      deviceId: value.trim(),
      validation: _ValidationState.idle,
      clearError: true,
      isSaved: false,
      savedDeviceId: null, // FIX 5
    );
  }

  /// Checks whether the GPS device is broadcasting on Firebase.
  /// Debug mode uses a mock check; production queries FirebaseDatabase.
  Future<void> verifyDevice() async {
    final id = state.deviceId.trim();

    // Local format check first
    if (id.isEmpty) {
      state = state.copyWith(
        validation: _ValidationState.invalid,
        errorMessage: 'Device ID cannot be empty.',
      );
      return;
    }
    if (id.length < 10) {
      state = state.copyWith(
        validation: _ValidationState.invalid,
        errorMessage: 'Device ID must be at least 10 characters.',
      );
      return;
    }
    if (!RegExp(r'^[A-Za-z0-9\-_]+$').hasMatch(id)) {
      state = state.copyWith(
        validation: _ValidationState.invalid,
        errorMessage: 'Only letters, numbers, hyphens and underscores allowed.',
      );
      return;
    }

    state = state.copyWith(validation: _ValidationState.checking);

    // ── FIX 1: kDebugMode wrap — mock only in debug, real Firebase in production ──
    bool exists;
    try {
      // FIX 1
      if (kDebugMode) {
        await Future.delayed(const Duration(seconds: 2)); // simulate network
        exists = _mockCheck(id);
      } else {
        final snap = await globalDB.ref('gps_devices/$id/last_seen').get();
        exists = snap.exists;
      }
    } catch (_) {
      // FIX 1
      state = state.copyWith(
        // FIX 1
        validation: _ValidationState.invalid, // FIX 1
        errorMessage:
            'Connection error. Check your internet and try again.', // FIX 1
      ); // FIX 1
      return; // FIX 1
    } // FIX 1
    // ──────────────────────────────────────────────────────────────────────────

    if (exists) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, id);
      // FIX 3: Save setup_complete flag on successful verification
      await prefs.setBool('driver_setup_complete', true);
      state = state.copyWith(
        validation: _ValidationState.valid,
        isSaved: true,
        savedDeviceId: id,
        clearError: true,
      );
    } else {
      state = state.copyWith(
        validation: _ValidationState.invalid,
        errorMessage:
            'Device not found in our network.\nEnsure the device is powered on and has a SIM card with data.',
      );
    }
  }

  Future<void> clearSaved() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    state = const _GpsSetupState();
  }

  /// Mock: any ID starting with "GT" or "TK" passes. Debug mode only.
  bool _mockCheck(String id) =>
      id.toUpperCase().startsWith('GT') ||
      id.toUpperCase().startsWith('TK') ||
      id.toUpperCase().startsWith('GL'); // FIX 4
}

// ─── Provider ─────────────────────────────────────────────────────────────────

final _gpsSetupProvider =
    StateNotifierProvider.autoDispose<_GpsSetupNotifier, _GpsSetupState>(
  (ref) => _GpsSetupNotifier(),
);

// ─── Screen ──────────────────────────────────────────────────────────────────

class DriverGpsScreen extends ConsumerStatefulWidget {
  const DriverGpsScreen({super.key});

  @override
  ConsumerState<DriverGpsScreen> createState() => _DriverGpsScreenState();
}

class _DriverGpsScreenState extends ConsumerState<DriverGpsScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _controller;
  late final FocusNode _focus;
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focus = FocusNode();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(
      begin: 0.85,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // ── FIX 2: Controller sync moved to initState (removed from build) ──
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final saved = ref.read(_gpsSetupProvider).savedDeviceId ?? '';
      if (saved.isNotEmpty) {
        _controller.text = saved;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: saved.length),
        );
      }
    });

    // FIX 1: Removed _checkExistingSetup() call.
  }

  // FIX 1: Removed _checkExistingSetup() method.

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── FIX 3: QR scan method ──────────────────────────────────────────────────
  Future<void> _scanQr() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _QrScannerPage()),
    );
    if (result != null && result.isNotEmpty && mounted) {
      _controller.text = result;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: result.length),
      );
      ref.read(_gpsSetupProvider.notifier).onDeviceIdChanged(result);
    }
  }
  // ──────────────────────────────────────────────────────────────────────────

  // FIX 2: Completed _onContinue() action
  void _onContinue() {
    Navigator.pop(context);
  }

  // FIX 2: clears both notifier state and the TextEditingController
  void clearSaved() {
    // FIX 2
    ref.read(_gpsSetupProvider.notifier).clearSaved(); // FIX 2
    _controller.clear(); // FIX 2
  } // FIX 2

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(_gpsSetupProvider);
    final notifier = ref.read(_gpsSetupProvider.notifier);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(context),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DeviceIllustration(pulseAnim: _pulseAnim, state: state),
                const SizedBox(height: 28),
                _SectionHeader(
                  title: 'GPS Device Setup',
                  subtitle:
                      'Connect a hardware tracker (GT06N / TK103) to your bus.\nNo driver phone needed after setup.',
                ),
                const SizedBox(height: 24),
                _SupportedDevicesRow(),
                const SizedBox(height: 24),
                _DeviceIdField(
                  controller: _controller,
                  focus: _focus,
                  state: state,
                  onChanged: notifier.onDeviceIdChanged,
                  onScanQr: _scanQr, // FIX 3: pass scan callback
                ),
                const SizedBox(height: 8),
                _FieldHint(state: state),
                const SizedBox(height: 20),
                _VerifyButton(state: state, onTap: notifier.verifyDevice),
                const SizedBox(height: 20),
                if (state.validation == _ValidationState.valid)
                  _SuccessBanner(deviceId: state.savedDeviceId ?? ''),
                if (state.validation == _ValidationState.invalid &&
                    state.errorMessage != null)
                  _ErrorBanner(message: state.errorMessage!),
                const SizedBox(height: 24),
                _HowItWorksCard(),
                const SizedBox(height: 24),
                if (state.isSaved) ...[
                  _ContinueButton(onTap: _onContinue),
                  const SizedBox(height: 12),
                  _ClearLink(onTap: clearSaved), // FIX 2
                ],
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.navy,
      foregroundColor: Colors.white,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        onPressed: () => Navigator.pop(context),
      ),
      title: const Text(
        'GPS Device Setup',
        style: TextStyle(
          fontFamily: AppTextStyles.fontFamily,
          fontWeight: FontWeight.w600,
          fontSize: 18,
          color: Colors.white,
        ),
      ),
      centerTitle: true,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.navyDark, AppColors.navy],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      ),
    );
  }
}

// ─── QR Scanner Page ──────────────────────────────────────────────────────────
// FIX 3: Full-screen QR scanner using mobile_scanner

class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  final MobileScannerController _scannerCtrl = MobileScannerController();
  bool _scanned = false;

  @override
  void dispose() {
    _scannerCtrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null || value.isEmpty) return;
    _scanned = true;
    _scannerCtrl.stop();
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: const Text(
          'Scan Device QR Code',
          style: TextStyle(
            fontFamily: AppTextStyles.fontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 17,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on_rounded),
            onPressed: _scannerCtrl.toggleTorch,
            tooltip: 'Toggle torch',
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerCtrl,
            onDetect: _onDetect,
          ),
          // Overlay with scan frame
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.navyLight, width: 2.5),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          // Bottom hint
          Positioned(
            bottom: 48,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Text(
                  'Point camera at the device QR label',
                  style: TextStyle(
                    fontFamily: AppTextStyles.fontFamily,
                    fontSize: 13,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Illustration ─────────────────────────────────────────────────────────────

class _DeviceIllustration extends StatelessWidget {
  final Animation<double> pulseAnim;
  final _GpsSetupState state;

  const _DeviceIllustration({required this.pulseAnim, required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 160,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.navySoft, AppColors.navySoft],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (state.validation == _ValidationState.checking)
            ...List.generate(3, (i) {
              return AnimatedBuilder(
                animation: pulseAnim,
                builder: (_, __) => Container(
                  width: 60.0 + (i + 1) * 28 * pulseAnim.value,
                  height: 60.0 + (i + 1) * 28 * pulseAnim.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.navy.withValues(alpha: 0.15 - i * 0.04), // FIX 6
                      width: 1.5,
                    ),
                  ),
                ),
              );
            }),
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: _iconBg(state.validation),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _iconColor(state.validation)
                      .withValues(alpha: 0.25), // FIX 6
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(
              _icon(state.validation),
              color: _iconColor(state.validation),
              size: 32,
            ),
          ),
          Positioned(top: 14, right: 16, child: _StatusPill(state: state)),
        ],
      ),
    );
  }

  Color _iconBg(_ValidationState v) {
    if (v == _ValidationState.valid) return AppColors.greenBg;
    if (v == _ValidationState.invalid) return AppColors.redBg;
    return Colors.white;
  }

  Color _iconColor(_ValidationState v) {
    if (v == _ValidationState.valid) return AppColors.green;
    if (v == _ValidationState.invalid) return AppColors.red;
    return AppColors.navy;
  }

  IconData _icon(_ValidationState v) {
    if (v == _ValidationState.valid) return Icons.gps_fixed_rounded;
    if (v == _ValidationState.invalid) return Icons.gps_off_rounded;
    if (v == _ValidationState.checking) return Icons.gps_not_fixed_rounded;
    return Icons.router_rounded;
  }
}

// ─── Status Pill ─────────────────────────────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final _GpsSetupState state;
  const _StatusPill({required this.state});

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch (state.validation) {
      _ValidationState.valid => ('Connected', AppColors.greenBg, AppColors.green),
      _ValidationState.invalid => ('Not Found', AppColors.redBg, AppColors.red),
      _ValidationState.checking => (
          'Checking…',
          AppColors.amberSoft,
          AppColors.amber,
        ),
      _ValidationState.idle => state.isSaved
          ? ('Saved', AppColors.greenBg, AppColors.green)
          : ('Not Set', AppColors.pageBg, AppColors.labelGray),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withValues(alpha: 0.3)), // FIX 6
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontFamily: AppTextStyles.fontFamily,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Section Header ──────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const _SectionHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: AppTextStyles.fontFamily,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: const TextStyle(
            fontFamily: AppTextStyles.fontFamily,
            fontSize: 13.5,
            color: AppColors.labelGray,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

// ─── Supported Devices Row ────────────────────────────────────────────────────

class _SupportedDevicesRow extends StatelessWidget {
  const _SupportedDevicesRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'Supported devices:',
          style: TextStyle(
            fontFamily: AppTextStyles.fontFamily,
            fontSize: 12,
            color: AppColors.labelGray,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 8),
        _DeviceChip('GT06N'),
        const SizedBox(width: 6),
        _DeviceChip('TK103'),
        const SizedBox(width: 6),
        _DeviceChip('GL300'),
      ],
    );
  }
}

class _DeviceChip extends StatelessWidget {
  final String label;
  const _DeviceChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.navySurface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.navy.withValues(alpha: 0.15)), // FIX 6
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: AppTextStyles.fontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.navy,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

// ─── Device ID Input Field ────────────────────────────────────────────────────

class _DeviceIdField extends StatelessWidget {
  // FIX 3
  final TextEditingController controller;
  final FocusNode focus;
  final _GpsSetupState state;
  final ValueChanged<String> onChanged;
  final VoidCallback onScanQr; // FIX 3: QR scan callback

  const _DeviceIdField({
    required this.controller,
    required this.focus,
    required this.state,
    required this.onChanged,
    required this.onScanQr,
  });

  Color get _borderColor {
    return switch (state.validation) {
      _ValidationState.valid => AppColors.green,
      _ValidationState.invalid => AppColors.red,
      _ValidationState.checking => AppColors.navyLight,
      _ValidationState.idle => AppColors.border,
    };
  }

  @override
  Widget build(BuildContext context) {
    // FIX 3
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Device IMEI / ID',
          style: TextStyle(
            fontFamily: AppTextStyles.fontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: AppColors.pageBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _borderColor, width: 1.8),
            boxShadow: state.validation == _ValidationState.valid
                ? [
                    BoxShadow(
                        color: AppColors.green.withValues(alpha: 0.12), blurRadius: 10)
                  ] // FIX 6
                : state.validation == _ValidationState.invalid
                    ? [
                        BoxShadow(
                            color: AppColors.red.withValues(alpha: 0.10),
                            blurRadius: 10) // FIX 6
                      ]
                    : [],
          ),
          child: TextField(
            controller: controller,
            focusNode: focus,
            onChanged: onChanged,
            enabled: state.validation != _ValidationState.checking,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-_]')),
              LengthLimitingTextInputFormatter(30),
            ],
            style: const TextStyle(
              fontFamily: AppTextStyles.fontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'e.g. GT06N-123456789',
              hintStyle: const TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 14,
                color: AppColors.border,
                fontWeight: FontWeight.w400,
                letterSpacing: 0.5,
              ),
              prefixIcon: const Padding(
                padding: EdgeInsets.only(left: 14, right: 10),
                child: Icon(Icons.router_rounded, color: AppColors.navy, size: 22),
              ),
              prefixIconConstraints: const BoxConstraints(),
              // ── FIX 3: QR icon in suffix (stacks with status icon) ──
              suffixIcon: _buildSuffix(state.validation),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget? _buildSuffix(_ValidationState v) {
    // Show spinner while checking — no QR button
    if (v == _ValidationState.checking) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.navy),
        ),
      );
    }

    // FIX 3: QR button + status icon side by side
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // QR scan icon button
        GestureDetector(
          onTap: onScanQr,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.qr_code_scanner_rounded,
              color: AppColors.navy.withValues(alpha: 0.7), // FIX 6
              size: 22,
            ),
          ),
        ),
        // Validation status icon
        if (v == _ValidationState.valid)
          const Padding(
            padding: EdgeInsets.only(right: 14),
            child: Icon(Icons.check_circle_rounded, color: AppColors.green, size: 22),
          )
        else if (v == _ValidationState.invalid)
          const Padding(
            padding: EdgeInsets.only(right: 14),
            child: Icon(Icons.cancel_rounded, color: AppColors.red, size: 22),
          )
        else
          const SizedBox(width: 6),
      ],
    );
  }
}

// ─── Field Hint ───────────────────────────────────────────────────────────────

class _FieldHint extends StatelessWidget {
  final _GpsSetupState state;
  const _FieldHint({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.validation != _ValidationState.idle &&
        state.validation != _ValidationState.checking) {
      return const SizedBox.shrink();
    }
    return const Padding(
      padding: EdgeInsets.only(left: 4),
      child: Text(
        'Find IMEI printed on device label or dial *#06# on SIM phone.',
        style: TextStyle(
          fontFamily: AppTextStyles.fontFamily,
          fontSize: 11.5,
          color: AppColors.labelGray,
        ),
      ),
    );
  }
}

// ─── Verify Button ────────────────────────────────────────────────────────────

class _VerifyButton extends StatelessWidget {
  final _GpsSetupState state;
  final VoidCallback onTap;

  const _VerifyButton({required this.state, required this.onTap});

  bool get _enabled =>
      state.deviceId.trim().length >= 10 &&
      state.validation != _ValidationState.checking;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: _enabled ? 1.0 : 0.45,
        child: ElevatedButton(
          onPressed: _enabled ? onTap : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.navy,
            disabledBackgroundColor: AppColors.navy,
            foregroundColor: Colors.white,
            elevation: _enabled ? 3 : 0,
            shadowColor: AppColors.navy.withValues(alpha: 0.4), // FIX 6
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (state.validation == _ValidationState.checking) ...[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Verifying Device…',
                  style: TextStyle(
                    fontFamily: AppTextStyles.fontFamily,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ] else ...[
                const Icon(Icons.wifi_tethering_rounded, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Verify & Connect Device',
                  style: TextStyle(
                    fontFamily: AppTextStyles.fontFamily,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Success Banner ───────────────────────────────────────────────────────────

class _SuccessBanner extends StatelessWidget {
  final String deviceId;
  const _SuccessBanner({required this.deviceId});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: AppColors.greenBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.green.withValues(alpha: 0.35)), // FIX 6
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            color: AppColors.green,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Device Connected Successfully',
                  style: TextStyle(
                    fontFamily: AppTextStyles.fontFamily,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.greenDark,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Device ID "$deviceId" is active and broadcasting. You can now proceed to select a bus route.',
                  style: const TextStyle(
                    fontFamily: AppTextStyles.fontFamily,
                    fontSize: 12,
                    color: AppColors.activeGreen,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Error Banner ─────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: AppColors.redBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.red.withValues(alpha: 0.35)), // FIX 6
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.red, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 12.5,
                color: AppColors.redDark,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── How It Works Card ────────────────────────────────────────────────────────

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.pageBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: AppColors.navy.withValues(alpha: 0.1), // FIX 6
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.lightbulb_outline_rounded,
                  color: AppColors.navy,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'How GPS Hardware Mode Works',
                style: TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...[
            (
              // FIX 7
              Icons.sim_card_outlined,
              'Install device in bus',
              'GT06N / TK103 is hardwired to the bus power supply.',
            ),
            (
              // FIX 7
              Icons.cell_tower_rounded,
              'Device sends GPS to server',
              'Device uses its own SIM card to push location every 10 seconds.',
            ),
            (
              // FIX 7
              Icons.cloud_sync_rounded,
              'UniTrack reads location',
              'Our backend bridges the TCP feed to Firebase Realtime Database.',
            ),
            (
              // FIX 7
              Icons.phone_android_rounded,
              'No driver phone needed',
              'Once set up, students see live location without any driver action.',
            ),
          ].map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppColors.navy.withValues(alpha: 0.08), // FIX 6
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(item.$1, color: AppColors.navy, size: 15), // FIX 7
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.$2, // FIX 7
                          style: const TextStyle(
                            fontFamily: AppTextStyles.fontFamily,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          item.$3, // FIX 7
                          style: const TextStyle(
                            fontFamily: AppTextStyles.fontFamily,
                            fontSize: 11.5,
                            color: AppColors.labelGray,
                            height: 1.4,
                          ),
                        ),
                      ],
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
}

// ─── Continue Button ──────────────────────────────────────────────────────────

class _ContinueButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ContinueButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.green,
          foregroundColor: Colors.white,
          elevation: 2,
          shadowColor: AppColors.green.withValues(alpha: 0.4), // FIX 6
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.directions_bus_rounded, size: 20),
            SizedBox(width: 8),
            Text(
              'Continue to Bus Selection',
              style: TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            SizedBox(width: 6),
            Icon(Icons.arrow_forward_rounded, size: 17),
          ],
        ),
      ),
    );
  }
}

// ─── Clear Link ───────────────────────────────────────────────────────────────

class _ClearLink extends StatelessWidget {
  final VoidCallback onTap;
  const _ClearLink({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton.icon(
        onPressed: onTap,
        icon: const Icon(
          Icons.delete_outline_rounded,
          size: 16,
          color: AppColors.labelGray,
        ),
        label: const Text(
          'Clear saved device',
          style: TextStyle(
            fontFamily: AppTextStyles.fontFamily,
            fontSize: 13,
            color: AppColors.labelGray,
            fontWeight: FontWeight.w500,
          ),
        ),
        style: TextButton.styleFrom(splashFactory: NoSplash.splashFactory),
      ),
    );
  }
}
