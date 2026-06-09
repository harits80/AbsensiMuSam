import 'package:absenmusam/Petugas/screens/petugas_dashboard.dart';
import 'package:absenmusam/User/screens/user_dashboard.dart';
import 'package:absenmusam/auth/services/role_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login.dart';
import 'package:absenmusam/helpers/language_helper.dart';

class JoinOrganizationScreen extends StatefulWidget {
  final bool fromDashboard;
  const JoinOrganizationScreen({super.key, this.fromDashboard = false});

  @override
  State<JoinOrganizationScreen> createState() => _JoinOrganizationScreenState();
}

class _JoinOrganizationScreenState extends State<JoinOrganizationScreen> {
  static const Color backgroundColor = Color(0xFF050011);
  static const Color cardColor = Colors.white;
  static const Color primaryPurple = Color(0xFF9747FF);
  static const Color darkPurple = Color(0xFF6200EE);
  static const Color textBlack = Color(0xFF1A1A1A);
  static const Color textGrey = Color(0xFF888888);
  static const Color inputFill = Color(0xFFF5F5F5);

  final TextEditingController _invCodeController = TextEditingController();
  final RoleService _roleService = RoleService();

  bool _isJoining = false;
  bool _isInitializing = true;

  String? _displayName;
  String? _profilePhotoUrl;
  String _currentLanguage = LanguageHelper.indonesian;

  @override
  void initState() {
    super.initState();
    _loadLanguage();
    _initializeScreen();
  }

  @override
  void dispose() {
    _invCodeController.dispose();
    super.dispose();
  }

  Future<void> _loadLanguage() async {
    final lang = await LanguageHelper.getSavedLanguage();
    if (mounted) {
      setState(() => _currentLanguage = lang);
    }
  }

  String _tr(String key) {
    return LanguageHelper.translate(key, _currentLanguage);
  }

  Future<void> _initializeScreen() async {
    if (!mounted) return;

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        if (mounted) setState(() => _isInitializing = false);
        return;
      }

      final profile = await Supabase.instance.client
          .from('user_profiles')
          .select(
            'first_name, last_name, display_name, profile_photo_url, email',
          )
          .eq('id', user.id)
          .maybeSingle();

      if (!mounted) return;

      if (profile != null) {
        setState(() {
          _displayName =
              profile['display_name'] ??
              profile['first_name'] ??
              user.email?.split('@')[0] ??
              'User';
          _profilePhotoUrl = profile['profile_photo_url'];
        });
      } else {
        setState(() {
          _displayName = user.email?.split('@')[0] ?? 'User';
        });
      }

      if (!widget.fromDashboard) {
        final memberData = await _roleService.getOrganizationMemberWithRole(
          user.id,
        );
        if (memberData != null && mounted) {
          final organizationMemberId = memberData['id'] as int;
          _navigateToDashboard(organizationMemberId, memberData);
          return;
        }
      }

      if (mounted) setState(() => _isInitializing = false);
    } catch (e) {
      debugPrint('Error initializing screen: $e');
      if (mounted) setState(() => _isInitializing = false);
    }
  }

  Future<void> _joinOrganizationWithCode() async {
    final invCode = _invCodeController.text.trim().toUpperCase();

    if (invCode.isEmpty) {
      _showSnackBar(_tr('join_org_enter_code'), false);
      return;
    }

    setState(() => _isJoining = true);

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('User tidak terautentikasi');

      if (!widget.fromDashboard) {
        final existingMemberData = await _roleService
            .getOrganizationMemberWithRole(user.id);
        if (existingMemberData != null) {
          if (mounted) {
            _navigateToDashboard(
              existingMemberData['id'] as int,
              existingMemberData,
            );
          }
          return;
        }
      }

      debugPrint('🔍 Validating Inv Code: "$invCode"');

      final orgResponse = await Supabase.instance.client
          .from('organizations')
          .select('id, name, inv_code')
          .eq('inv_code', invCode)
          .eq('is_active', true)
          .maybeSingle();

      debugPrint('✅ Validating Inv Code Result: $orgResponse');

      if (orgResponse == null) throw Exception('Kode undangan tidak valid');

      final orgId = orgResponse['id'];
      final orgName = orgResponse['name'];

      final existingMemberInOrg = await Supabase.instance.client
          .from('organization_members')
          .select('id, is_active')
          .eq('organization_id', orgId)
          .eq('user_id', user.id)
          .maybeSingle();

      int organizationMemberId;

      if (existingMemberInOrg != null) {
        if (existingMemberInOrg['is_active'] == true) {
          if (widget.fromDashboard) {
            organizationMemberId = existingMemberInOrg['id'] as int;
          } else {
            throw Exception('Anda sudah tergabung di organisasi ini');
          }
        } else {
          await Supabase.instance.client
              .from('organization_members')
              .update({
                'is_active': true,
                'work_location': 'field',
                'updated_at': DateTime.now().toIso8601String(),
              })
              .eq('id', existingMemberInOrg['id']);
          organizationMemberId = existingMemberInOrg['id'] as int;
        }
      } else {
        final newMember = await Supabase.instance.client
            .from('organization_members')
            .insert({
              'organization_id': orgId,
              'user_id': user.id,
              'role_id': 2,
              'hire_date': DateTime.now().toIso8601String().split('T')[0],
              'employment_status': 'active',
              'work_location': 'field',
              'is_active': true,
            })
            .select('id')
            .single();
        organizationMemberId = newMember['id'] as int;
      }

      final memberData = await _roleService.getOrganizationMemberWithRole(
        user.id,
      );
      if (memberData == null) throw Exception('Failed to fetch member data');

      if (mounted) {
        _showSuccessDialog(orgName, organizationMemberId, memberData);
      }
    } catch (e) {
      debugPrint('Error joining organization: $e');
      if (mounted) {
        String errorMessage = _tr('join_org_error');
        if (e.toString().contains('tidak valid') ||
            e.toString().contains('not valid')) {
          errorMessage = _tr('join_org_invalid_code');
        } else if (e.toString().contains('sudah tergabung') ||
            e.toString().contains('already')) {
          errorMessage = _tr('join_org_already_joined');
        }
        _showSnackBar(errorMessage, false);
      }
    } finally {
      if (mounted) setState(() => _isJoining = false);
    }
  }

  void _navigateToDashboard(
    int organizationMemberId,
    Map<String, dynamic> memberData,
  ) {
    final page = _roleService.isPetugas(memberData)
        ? PetugasDashboardPage(
            organizationMemberId: organizationMemberId,
            memberData: memberData,
          )
        : UserDashboardPage(
            organizationMemberId: organizationMemberId,
            memberData: memberData,
          );

    final route = PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    );

    if (widget.fromDashboard) {
      Navigator.of(context).pushAndRemoveUntil(route, (route) => false);
    } else {
      Navigator.of(context).pushReplacement(route);
    }
  }

  void _showSuccessDialog(
    String orgName,
    int organizationMemberId,
    Map<String, dynamic> memberData,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            Navigator.of(context).pop();
            _navigateToDashboard(organizationMemberId, memberData);
          }
        });
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle,
                  size: 60,
                  color: Color(0xFF10B981),
                ),
                const SizedBox(height: 24),
                Text(
                  _tr('join_org_success_title'),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _tr('join_org_success_message').replaceAll('{org}', orgName),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleLogout() async {
    await Supabase.instance.client.auth.signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
        (route) => false,
      );
    }
  }

  void _showSnackBar(String message, bool isSuccess) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return const Scaffold(
        backgroundColor: backgroundColor,
        body: Center(child: CircularProgressIndicator(color: primaryPurple)),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: true, // 🔥 TAMBAHKAN INI
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(), // 🔥 TUTUP KEYBOARD
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Color(0xFFE3F2FD)],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              // 🔥 TAMBAHKAN SCROLLVIEW
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (widget.fromDashboard)
                          IconButton(
                            icon: const Icon(
                              Icons.arrow_back,
                              color: Colors.black87,
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.blue.withOpacity(0.2),
                                  width: 1,
                                ),
                              ),
                              child: CircleAvatar(
                                radius: 18,
                                backgroundColor: Colors.grey.shade200,
                                backgroundImage: _profilePhotoUrl != null
                                    ? NetworkImage(_profilePhotoUrl!)
                                    : null,
                                child: _profilePhotoUrl == null
                                    ? const Icon(
                                        Icons.person,
                                        color: Colors.grey,
                                        size: 20,
                                      )
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _displayName ?? 'User',
                              style: const TextStyle(
                                color: Colors.black87,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        TextButton(
                          onPressed: _handleLogout,
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                              side: BorderSide(color: Colors.grey.shade200),
                            ),
                            elevation: 2,
                            shadowColor: Colors.black.withOpacity(0.05),
                          ),
                          child: Row(
                            children: [
                              Text(
                                'LOGOUT',
                                style: TextStyle(
                                  color: Colors.red.shade600,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.logout,
                                size: 14,
                                color: Colors.red.shade600,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(
                      height: 20,
                    ), // 🔥 GANTI Spacer dengan SizedBox
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 40,
                        horizontal: 24,
                      ),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(32),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset(
                            'assets/logo/app_logo_new.png',
                            height: 60,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const SizedBox.shrink(),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'Enter Access Key',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: textBlack,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              'Enter the invitation code provided\nby your HR or Admin.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: textGrey,
                                height: 1.5,
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: 4,
                                bottom: 8,
                              ),
                              child: Text(
                                'ORGANIZATION CODE',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: textBlack.withOpacity(0.7),
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              color: inputFill,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: TextField(
                              controller: _invCodeController,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: textBlack,
                                letterSpacing: 2.0,
                              ),
                              decoration: InputDecoration(
                                hintText: '•••• - •••• - ••••',
                                hintStyle: TextStyle(
                                  color: Colors.grey.shade400,
                                  letterSpacing: 2.0,
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                              ),
                              inputFormatters: [UpperCaseTextFormatter()],
                            ),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF9747FF),
                                    Color(0xFF6200EE),
                                  ],
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFF6200EE,
                                    ).withOpacity(0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 5),
                                  ),
                                ],
                              ),
                              child: ElevatedButton(
                                onPressed: _isJoining
                                    ? null
                                    : _joinOrganizationWithCode,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: _isJoining
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            'Join Organization',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                          SizedBox(width: 8),
                                          Icon(
                                            Icons.arrow_forward_rounded,
                                            color: Colors.white,
                                            size: 20,
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          GestureDetector(
                            onTap: () {
                              _showSnackBar(
                                'Contact your administrator for code',
                                true,
                              );
                            },
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Need verification help? ',
                                  style: TextStyle(
                                    color: primaryPurple,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Icon(
                                  Icons.help_outline_rounded,
                                  size: 14,
                                  color: primaryPurple,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(
                      height: 20,
                    ), // 🔥 GANTI Spacer dengan SizedBox
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
