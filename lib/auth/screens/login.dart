import 'dart:io';
import 'package:flutter/material.dart';
import 'package:absenmusam/auth/screens/join_organization_screen.dart';
import 'package:absenmusam/Petugas/screens/petugas_dashboard.dart';
import 'package:absenmusam/User/screens/user_dashboard.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart' as gsi;
import 'signup.dart';
import '../../helpers/language_helper.dart';
import '../services/role_service.dart';

class ModernLoginScreen extends StatefulWidget {
  const ModernLoginScreen({super.key});

  @override
  State<ModernLoginScreen> createState() => _ModernLoginScreenState();
}

class _ModernLoginScreenState extends State<ModernLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;

  final supabase = Supabase.instance.client;
  final RoleService _roleService = RoleService();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<bool> _checkInternetConnection() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();

      if (connectivityResult.contains(ConnectivityResult.none)) {
        return false;
      }

      // Double check dengan ping ke Google DNS
      final result = await InternetAddress.lookup('google.com');
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Connection check error: $e');
      return false;
    }
  }

  String _extractNameFromEmail(String email) {
    try {
      String namePart = email.split('@')[0];
      namePart = namePart.replaceAll(RegExp(r'[_.\-0-9]'), ' ').trim();

      List<String> words = namePart
          .split(' ')
          .where((w) => w.isNotEmpty)
          .toList();
      String capitalizedName = words
          .map(
            (word) => word[0].toUpperCase() + word.substring(1).toLowerCase(),
          )
          .join(' ')
          .trim();

      return capitalizedName.isEmpty ? email.split('@')[0] : capitalizedName;
    } catch (e) {
      debugPrint('Error extracting name from email: $e');
      return email.split('@')[0];
    }
  }

  Map<String, String> _splitName(String fullName) {
    List<String> nameParts = fullName
        .trim()
        .split(' ')
        .where((n) => n.isNotEmpty)
        .toList();

    if (nameParts.isEmpty) {
      return {'first_name': 'User', 'last_name': ''};
    } else if (nameParts.length == 1) {
      return {'first_name': nameParts[0], 'last_name': ''};
    } else {
      String firstName = nameParts[0];
      String lastName = nameParts.sublist(1).join(' ');
      return {'first_name': firstName, 'last_name': lastName};
    }
  }

  Future<bool> _ensureUserProfile(
    String userId,
    String email, {
    String? googleName,
  }) async {
    try {
      debugPrint('Ensuring user profile for: $userId');

      final existingProfile = await supabase
          .from('user_profiles')
          .select('id, first_name, last_name, display_name, email')
          .eq('id', userId)
          .maybeSingle();

      String fullName = googleName?.isNotEmpty == true
          ? googleName!
          : _extractNameFromEmail(email);

      final nameParts = _splitName(fullName);
      final firstName = nameParts['first_name']!;
      final lastName = nameParts['last_name']!;

      if (existingProfile == null) {
        debugPrint('Creating new user profile...');

        await supabase.from('user_profiles').insert({
          'id': userId,
          'first_name': firstName,
          'last_name': lastName,
          'display_name': fullName,
          'email': email,
          'is_active': true,
        });

        debugPrint('✓ User profile created successfully');
        return true;
      } else {
        debugPrint('User profile already exists');

        final hasValidName =
            existingProfile['first_name'] != null &&
            existingProfile['first_name'].toString().isNotEmpty &&
            existingProfile['first_name'] != 'User';

        if (!hasValidName) {
          await supabase
              .from('user_profiles')
              .update({
                'first_name': firstName,
                'last_name': lastName,
                'display_name': fullName,
                'email': email,
              })
              .eq('id', userId);

          debugPrint('✓ User profile updated with name');
        }
        return true;
      }
    } catch (e) {
      debugPrint('❌ Error ensuring user profile: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _getUserOrganizations(
    String userId,
  ) async {
    try {
      return await _roleService.getAllOrganizationMembersWithRoles(userId);
    } catch (e) {
      debugPrint('Error checking user organizations: $e');
      return [];
    }
  }

  // Extracted dashboard navigation logic
  Future<void> _navigateToDashboard(Map<String, dynamic> memberData) async {
    if (!mounted) return;

    final organizationMemberId = memberData['id'] as int;

    if (_roleService.isPetugas(memberData)) {
      debugPrint('✓ User is Admin - navigating to Petugas Dashboard');
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => PetugasDashboardPage(
            organizationMemberId: organizationMemberId,
            memberData: memberData,
          ),
        ),
        (route) => false,
      );
    } else if (_roleService.isUser(memberData)) {
      debugPrint('✓ User is Regular User - navigating to User Dashboard');
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => UserDashboardPage(
            organizationMemberId: organizationMemberId,
            memberData: memberData,
          ),
        ),
        (route) => false,
      );
    } else {
      debugPrint('⚠️ Unknown role - navigating to User Dashboard');
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => UserDashboardPage(
            organizationMemberId: organizationMemberId,
            memberData: memberData,
          ),
        ),
        (route) => false,
      );
    }
  }

  Future<void> _navigateAfterLogin(String userId) async {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF673AB7)),
        ),
      ),
    );

    try {
      final memberships = await _getUserOrganizations(userId);

      if (!mounted) return;
      Navigator.of(context).pop(); // Close loading dialog

      if (!mounted) return;

      if (memberships.isNotEmpty) {
        debugPrint('✓ User has ${memberships.length} organizations');
        _showSnackBar(AppLanguage.tr('login_success'), true);

        // Always pick the first membership and navigate to dashboard
        // SKIP: OrganizationSelectionPage
        final memberData = memberships.first;
        _navigateToDashboard(memberData);
      } else {
        debugPrint(
          '⚠️ User has no organization - navigating to Join Organization',
        );
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => const JoinOrganizationScreen(),
          ),
          (route) => false,
        );
      }
    } catch (e) {
      debugPrint('Error checking organization: $e');

      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      _showSnackBar(
        '${AppLanguage.tr('check_organization_failed')}: ${e.toString()}',
        false,
      );
    }
  }

  Future<void> _signInWithEmail() async {
    if (_isLoading) return;

    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      // CEK KONEKSI INTERNET DULU
      final hasConnection = await _checkInternetConnection();
      if (!hasConnection) {
        throw SocketException('Tidak ada koneksi internet');
      }

      debugPrint('Attempting email login...');

      final res = await supabase.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      final user = res.user;
      if (user != null) {
        debugPrint('✓ Email login successful, user ID: ${user.id}');

        final profileCreated = await _ensureUserProfile(user.id, user.email!);

        if (!profileCreated) {
          debugPrint(
            '⚠️ Warning: Profile creation/update failed, but continuing...',
          );
        }

        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_email', user.email!);

        if (!mounted) return;
        await _navigateAfterLogin(user.id);
      }
    } on SocketException catch (e) {
      debugPrint('❌ No internet connection: $e');
      if (!mounted) return;
      _showSnackBar(
        'Tidak ada koneksi internet. Mohon periksa koneksi Anda dan coba lagi.',
        false,
      );
    } catch (e) {
      debugPrint('❌ Login error: $e');
      if (!mounted) return;

      String errorMessage = AppLanguage.tr('login_error');

      // Check for network errors
      if (e.toString().toLowerCase().contains('socketexception') ||
          e.toString().toLowerCase().contains('failed host lookup') ||
          e.toString().toLowerCase().contains('network')) {
        errorMessage =
            'Tidak ada koneksi internet. Mohon periksa koneksi Anda.';
      } else if (e is AuthException) {
        if (e.message.toLowerCase().contains('invalid login credentials') ||
            e.message.toLowerCase().contains('invalid_credentials')) {
          errorMessage = AppLanguage.tr('invalid_credentials');
        } else if (e.message.toLowerCase().contains('email not confirmed')) {
          errorMessage = AppLanguage.tr('email_not_confirmed');
        } else {
          errorMessage = e.message;
        }
      }

      _showSnackBar(errorMessage, false);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);

    try {
      // CEK KONEKSI INTERNET DULU
      final hasConnection = await _checkInternetConnection();
      if (!hasConnection) {
        throw SocketException('Tidak ada koneksi internet');
      }

      debugPrint('🔵 Starting Google Sign In...');

      const webClientId =
          '210380129521-9kb8of23fk2jrf6p09do71v4df4asehf.apps.googleusercontent.com';
      const androidClientIds = [
        '210380129521-tt2solatsiu1ieo6547kmgu6pfl19t7a.apps.googleusercontent.com',
        '210380129521-lr442btemji6k32tnh4a29llllapc8q9.apps.googleusercontent.com',
      ];

      String activeAndroidClientId = androidClientIds.first;

      gsi.GoogleSignInAccount? googleUser;
      gsi.GoogleSignInAuthentication? googleAuth;

      bool success = false;

      for (final clientId in androidClientIds) {
        try {
          debugPrint('🧩 Trying Google Sign In with clientId: $clientId');

          final signInManager = gsi.GoogleSignIn.instance;
          await signInManager.initialize(
            serverClientId: webClientId,
            clientId: clientId,
          );

          await signInManager.signOut();
          
          // In 7.2.0, authenticate() is used instead of signIn()
          googleUser = await signInManager.authenticate();

          googleAuth = googleUser.authentication;
          if (googleAuth.idToken != null) {
            activeAndroidClientId = clientId;
            success = true;
            debugPrint('✅ Sign-in successful with clientId: $clientId');
            break;
          }
        } catch (e) {
          debugPrint('❌ Failed with clientId $clientId: $e');
          continue;
        }
      }

      if (!success || googleAuth == null || googleAuth.idToken == null) {
        throw Exception('Semua Client ID gagal. Cek konfigurasi Google Cloud.');
      }

      debugPrint('🔵 Authenticating with Supabase...');
      
      // Supabase signInWithIdToken prioritize idToken. 
      final response = await supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: googleAuth.idToken!,
      );

      final user = response.user;
      if (user == null) {
        throw Exception('Supabase authentication gagal: user null');
      }

      debugPrint('✅ Supabase auth success for ${user.email}');
      debugPrint('   Using Android Client: $activeAndroidClientId');

      await _ensureUserProfile(
        user.id,
        user.email!,
        googleName: googleUser?.displayName ?? user.userMetadata?['full_name'],
      );

      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_email', user.email!);
      await prefs.setBool('logged_in_with_google', true);

      if (!mounted) return;
      await _navigateAfterLogin(user.id);
    } on SocketException catch (e) {
      debugPrint('❌ No internet connection: $e');
      if (!mounted) return;
      _showSnackBar(
        'Tidak ada koneksi internet. Mohon periksa koneksi Anda dan coba lagi.',
        false,
      );
    } catch (e) {
      debugPrint('❌ Error during Google Sign In: $e');
      if (!mounted) return;

      String errorMessage =
          '${AppLanguage.tr('google_signin_failed')}: ${e.toString()}';

      if (e.toString().toLowerCase().contains('socketexception') ||
          e.toString().toLowerCase().contains('failed host lookup')) {
        errorMessage =
            'Tidak ada koneksi internet. Mohon periksa koneksi Anda.';
      }

      _showSnackBar(errorMessage, false);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message, bool isSuccess) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: isSuccess ? 3 : 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),
                        Image.asset(
                          'assets/logo/app_logo_new.png',
                          height: 80,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          AppLanguage.tr('welcome_back'),
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: Colors.black,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Email Field
                        _buildInputLabel(AppLanguage.tr('email_address')),
                        const SizedBox(height: 6),
                        _buildTextField(
                          controller: _emailController,
                          hintText: 'name@school.edu',
                          keyboardType: TextInputType.emailAddress,
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return AppLanguage.tr('email_required');
                            }
                            if (!RegExp(
                              r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$',
                            ).hasMatch(value)) {
                              return AppLanguage.tr('email_invalid');
                            }
                            return null;
                          },
                        ),

                        const SizedBox(height: 16),

                        // Password Field
                        _buildInputLabel(AppLanguage.tr('password')),
                        const SizedBox(height: 6),
                        _buildTextField(
                          controller: _passwordController,
                          hintText: '••••••••••••',
                          obscureText: _obscurePassword,
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              color: Colors.grey.shade400,
                              size: 20,
                            ),
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return AppLanguage.tr('password_required');
                            }
                            return null;
                          },
                        ),

                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () {
                              // Forgot password logic
                            },
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 30),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              AppLanguage.tr('forgot_password'),
                              style: const TextStyle(
                                color: Color(0xFF673AB7),
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Sign In Button
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFF673AB7,
                                  ).withValues(alpha: 0.2),
                                  blurRadius: 15,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _signInWithEmail,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF673AB7),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              Colors.white,
                                            ),
                                      ),
                                    )
                                  : Text(
                                      AppLanguage.tr('login'),
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        Row(
                          children: [
                            Expanded(
                              child: Divider(color: Colors.grey.shade300),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Text(
                                AppLanguage.tr('or'),
                                style: TextStyle(
                                  color: Colors.grey.shade500,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(color: Colors.grey.shade300),
                            ),
                          ],
                        ),

                        const SizedBox(height: 24),

                        // Google Sign In Button
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: OutlinedButton(
                            onPressed: _isLoading ? null : _signInWithGoogle,
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: Colors.grey.shade300),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              backgroundColor: Colors.white,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Image.asset(
                                  'assets/logo/logo_google.png',
                                  width: 20,
                                  height: 20,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  AppLanguage.tr('sign_in_with_google'),
                                  style: const TextStyle(
                                    color: Colors.black87,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 8),

                        Padding(
                          padding: EdgeInsets.zero,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                AppLanguage.tr('dont_have_account'),
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 14,
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          const ModernSignupScreen(),
                                    ),
                                  );
                                },
                                child: const Text(
                                  'Create Account',
                                  style: TextStyle(
                                    color: Color(0xFF673AB7),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildInputLabel(String label) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: Colors.blueGrey.shade800.withValues(alpha: 0.6),
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(color: Colors.black87, fontSize: 15),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 15),
        filled: true,
        fillColor: const Color(0xFFF1F4F9),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 18,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF673AB7), width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.redAccent, width: 1),
        ),
        suffixIcon: suffixIcon,
      ),
    );
  }
}
