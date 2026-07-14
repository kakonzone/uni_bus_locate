// lib/screens/login/login_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/app_color.dart';
import '../../theme/app_text_styles.dart';

// ─── Login Screen ──────────────────────────────────────────────────────────────

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with TickerProviderStateMixin {
  // Controllers
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // Animation controllers
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late AnimationController _logoController;

  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  late Animation<double> _logoScaleAnim;

  // State
  bool _isLoading = false;
  bool _idFocused = false;
  bool _passwordFocused = false;
  bool _obscurePassword = true;
  String? _errorMessage;
  String _selectedRole = 'student'; // 'student' or 'driver'

  // Focus nodes
  final _idFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _checkExistingSession();

    _idFocusNode.addListener(() {
      setState(() => _idFocused = _idFocusNode.hasFocus);
    });
    _passwordFocusNode.addListener(() {
      setState(() => _passwordFocused = _passwordFocusNode.hasFocus);
    });
  }

  void _setupAnimations() {
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    _logoScaleAnim = CurvedAnimation(
      parent: _logoController,
      curve: Curves.elasticOut,
    );
    _fadeAnim = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));

    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _logoController.forward();
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        _fadeController.forward();
        _slideController.forward();
      }
    });
  }

  // ─── Role Toggle Widgets ────────────────────────────────────────────────────

  Widget _buildRoleToggle() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          _roleTab('student', Icons.school_rounded, 'Student'),
          _roleTab('driver', Icons.directions_bus_rounded, 'Driver'),
        ],
      ),
    );
  }

  Widget _roleTab(String role, IconData icon, String label) {
    final isActive = _selectedRole == role;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedRole = role),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isActive ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isActive ? Colors.white : AppColors.textLight,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isActive ? Colors.white : AppColors.textLight,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Session Check (Auto-login) ────────────────────────────────────────────

  Future<void> _checkExistingSession() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('uni_user_id');
    final role = prefs.getString('uni_role');

    if (userId != null && role != null) {
      if (!mounted) return;
      _navigateByRole(role, userId);
    }
  }

  // ─── Navigation ───────────────────────────────────────────────────────────

  void _navigateByRole(String role, String userId) {
    if (role == 'driver') {
      Navigator.pushReplacementNamed(context, '/driver/dashboard');
    } else {
      Navigator.pushReplacementNamed(context, '/student/home');
    }
  }

  // ─── Login Handler ─────────────────────────────────────────────────────────

  Future<void> _handleLogin() async {
    HapticFeedback.lightImpact();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final userId = _idController.text.trim();
    final password = _passwordController.text;

    try {
      final prefs = await SharedPreferences.getInstance();

      if (_selectedRole == 'driver') {
        // ── Driver Login ──────────────────────────────────────────────────
        if (password != 'driver') {
          setState(() {
            _errorMessage = 'Invalid driver credentials.';
            _isLoading = false;
          });
          return;
        }
        await prefs.setString('uni_user_id', userId);
        await prefs.setString('uni_role', 'driver');
        await prefs.setString('uni_uid', 'driver_uid');
        await prefs.setString('uni_password', password);

        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/driver/dashboard');
      } else {
        // ── Student Login ─────────────────────────────────────────────────
        await prefs.setString('uni_user_id', userId);
        await prefs.setString('uni_uid', 'test_uid_$userId');
        await prefs.setString('uni_role', 'student');
        await prefs.setString('uni_password', password);

        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/student/home');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Login failed: $e';
        _isLoading = false;
      });
      HapticFeedback.mediumImpact();
    }
  }

  @override
  void dispose() {
    _idController.dispose();
    _passwordController.dispose();
    _fadeController.dispose();
    _slideController.dispose();
    _logoController.dispose();
    _idFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),
                  _buildHeader(),
                  const SizedBox(height: 48),
                  _buildFormCard(),
                  const SizedBox(height: 32),
                  _buildFooter(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ScaleTransition(
          scale: _logoScaleAnim,
          child: Row(
            children: [
              _buildLogoMark(),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'UniTrack',
                    style: AppTextStyles.headlineMedium.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 22,
                    ),
                  ),
                  Text(
                    'University Bus Tracker',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textLight,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              _buildLivePill(),
            ],
          ),
        ),
        const SizedBox(height: 44),
        FadeTransition(
          opacity: _fadeAnim,
          child: _buildBusStrip(),
        ),
        const SizedBox(height: 32),
        FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Welcome back.', style: AppTextStyles.displayLarge),
                const SizedBox(height: 10),
                Text(
                  'Sign in with your university ID\nto track your campus bus.',
                  style: AppTextStyles.bodyLarge,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogoMark() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: const Center(
        child:
            Icon(Icons.directions_bus_rounded, color: Colors.white, size: 26),
      ),
    );
  }

  Widget _buildLivePill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.5),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'LIVE',
            style: AppTextStyles.labelMedium.copyWith(
              color: AppColors.accent,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBusStrip() {
    return Container(
      height: 80,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.surface,
            AppColors.primary.withValues(alpha: 0.06),
            AppColors.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            _buildRouteStop('Campus Gate', true),
            _buildRouteLine(),
            _buildRouteStop('Faculty Block', false),
            _buildRouteLine(),
            _buildRouteStop('Library', false),
            _buildRouteLine(),
            _buildRouteStop('Dormitory', false),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteStop(String label, bool active) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: active ? AppColors.primary : AppColors.border,
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? AppColors.primary : AppColors.textLight,
              width: 2,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: AppTextStyles.labelMedium.copyWith(
            fontSize: 9,
            color: active ? AppColors.primary : AppColors.textLight,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildRouteLine() {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 22),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.primary.withValues(alpha: 0.4),
              AppColors.border,
            ],
          ),
        ),
      ),
    );
  }

  // ─── Form Card ─────────────────────────────────────────────────────────────

  Widget _buildFormCard() {
    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Role toggle
              _buildRoleToggle(),
              const SizedBox(height: 24),

              // Error banner
              if (_errorMessage != null) ...[
                _buildErrorBanner(_errorMessage!),
                const SizedBox(height: 16),
              ],

              // ── Student/Driver ID Field ───────────────────────────────────
              _buildFieldLabel(
                  _selectedRole == 'driver' ? 'Driver ID' : 'Student ID',
                  required: true),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _idController,
                focusNode: _idFocusNode,
                isFocused: _idFocused,
                hint: _selectedRole == 'driver'
                    ? 'e.g. driver'
                    : 'e.g. 111222021',
                icon: Icons.badge_outlined,
                keyboardType: TextInputType.text,
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return _selectedRole == 'driver'
                        ? 'Driver ID is required'
                        : 'Student ID is required';
                  }
                  return null;
                },
                onFieldSubmitted: (_) =>
                    FocusScope.of(context).requestFocus(_passwordFocusNode),
              ),

              const SizedBox(height: 20),

              // ── Password Field ───────────────────────────────────────────
              _buildFieldLabel('Password', required: true),
              const SizedBox(height: 8),
              _buildPasswordField(),

              const SizedBox(height: 32),

              // ── Login Button ──────────────────────────────────────────────
              _buildLoginButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String label, {bool required = false}) {
    return Row(
      children: [
        Text(
          label,
          style: AppTextStyles.labelMedium.copyWith(
            color: AppColors.textDark,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (required) ...[
          const SizedBox(width: 4),
          const Text(
            '*',
            style: TextStyle(color: AppColors.error, fontSize: 14),
          ),
        ],
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required bool isFocused,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
    void Function(String)? onFieldSubmitted,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: isFocused ? Colors.white : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isFocused ? AppColors.primary : AppColors.border,
          width: isFocused ? 1.8 : 1.2,
        ),
        boxShadow: isFocused
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : [],
      ),
      child: TextFormField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        validator: validator,
        onFieldSubmitted: onFieldSubmitted,
        textInputAction: textInputAction,
        style: AppTextStyles.bodyLarge.copyWith(
          color: AppColors.textDark,
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppTextStyles.bodyLarge.copyWith(
            color: AppColors.textLight,
            fontSize: 14,
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 14, right: 10),
            child: Icon(
              icon,
              color: isFocused ? AppColors.primary : AppColors.textLight,
              size: 20,
            ),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          errorStyle: const TextStyle(height: 0.01, fontSize: 0.01),
        ),
      ),
    );
  }

  Widget _buildPasswordField() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: _passwordFocused ? Colors.white : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _passwordFocused ? AppColors.primary : AppColors.border,
          width: _passwordFocused ? 1.8 : 1.2,
        ),
        boxShadow: _passwordFocused
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : [],
      ),
      child: TextFormField(
        controller: _passwordController,
        focusNode: _passwordFocusNode,
        obscureText: _obscurePassword,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _handleLogin(),
        style: AppTextStyles.bodyLarge.copyWith(
          color: AppColors.textDark,
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
        validator: (val) {
          if (val == null || val.isEmpty) return 'Password is required';
          return null;
        },
        decoration: InputDecoration(
          hintText: 'Enter your password',
          hintStyle: AppTextStyles.bodyLarge.copyWith(
            color: AppColors.textLight,
            fontSize: 14,
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 14, right: 10),
            child: Icon(
              Icons.lock_outline_rounded,
              color: _passwordFocused ? AppColors.primary : AppColors.textLight,
              size: 20,
            ),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
          suffixIcon: GestureDetector(
            onTap: () => setState(() => _obscurePassword = !_obscurePassword),
            child: Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Icon(
                _obscurePassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: AppColors.textLight,
                size: 20,
              ),
            ),
          ),
          suffixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          errorStyle: const TextStyle(height: 0.01, fontSize: 0.01),
        ),
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.error.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: AppColors.error, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.labelMedium.copyWith(
                color: AppColors.error,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _isLoading
                ? [AppColors.primaryLight, AppColors.primaryLight]
                : [AppColors.primary, AppColors.primaryDark],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: _isLoading
              ? []
              : [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                    spreadRadius: -2,
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _isLoading ? null : _handleLogin,
            borderRadius: BorderRadius.circular(16),
            splashColor: Colors.white.withValues(alpha: 0.15),
            highlightColor: Colors.white.withValues(alpha: 0.08),
            child: Center(
              child: _isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Continue', style: AppTextStyles.buttonText),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── Footer ────────────────────────────────────────────────────────────────

  Widget _buildFooter() {
    return FadeTransition(
      opacity: _fadeAnim,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Divider(color: AppColors.border, thickness: 1)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'UniTrack v1.0',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.textLight,
                    fontSize: 11,
                  ),
                ),
              ),
              Expanded(child: Divider(color: AppColors.border, thickness: 1)),
            ],
          ),
          const SizedBox(height: 20),
          // ✅ FIX: Row → Wrap to prevent RenderFlex overflow
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              _buildInfoChip(Icons.location_on_outlined, 'Live Tracking'),
              _buildInfoChip(Icons.access_time_outlined, 'Real-time ETA'),
              _buildInfoChip(Icons.shield_outlined, 'Secure'),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            "Your university's official bus tracking system.",
            style: AppTextStyles.labelMedium.copyWith(
              color: AppColors.textLight,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: AppTextStyles.labelMedium.copyWith(
              fontSize: 11,
              color: AppColors.textMid,
            ),
          ),
        ],
      ),
    );
  }
}
