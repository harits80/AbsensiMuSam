import 'package:absenmusam/auth/screens/login.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/language_helper.dart';

class ModernSignupScreen extends StatefulWidget {
  const ModernSignupScreen({super.key});

  @override
  State<ModernSignupScreen> createState() => _ModernSignupScreenState();
}

class _ModernSignupScreenState extends State<ModernSignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  // HAPUS: bool _agreeToTerms = false;
  
  final supabase = Supabase.instance.client;
  static const Color successColor = Color(0xFF10B981);

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Map<String, String> _splitName(String fullName) {
    List<String> nameParts = fullName.trim().split(' ').where((n) => n.isNotEmpty).toList();
    
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

  Future<bool> _createUserProfile(String userId, String fullName, String email) async {
    try {
      debugPrint('Creating user profile for: $userId');
      
      final nameParts = _splitName(fullName);
      final firstName = nameParts['first_name']!;
      final lastName = nameParts['last_name']!;
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final existingProfile = await supabase
          .from('user_profiles')
          .select('id, email')
          .eq('id', userId)
          .maybeSingle();

      if (existingProfile != null) {
        debugPrint('Updating existing profile created by trigger...');
        await supabase
            .from('user_profiles')
            .update({
              'first_name': firstName,
              'last_name': lastName,
              'display_name': fullName,
              'email': email,
              'is_active': true,
            })
            .eq('id', userId);
      } else {
        debugPrint('Creating new user profile...');
        await supabase
            .from('user_profiles')
            .insert({
              'id': userId,
              'first_name': firstName,
              'last_name': lastName,
              'display_name': fullName,
              'email': email,
              'is_active': true,
            });
      }

      // ✅ AUTOMATICALLY JOIN ORGANIZATION 3 (Testing Mode)
      debugPrint('Automatically adding user to Org 3...');
      await supabase
          .from('organization_members')
          .upsert({
            'organization_id': 3,
            'user_id': userId,
            'role_id': 2, // Role 2 = User
            'is_active': true,
          }, onConflict: 'organization_id, user_id');

      debugPrint('User profile and membership created successfully.');
      return true;
    } catch (e) {
      debugPrint('Error creating user profile/membership: $e');
      return false;
    }
  }

  String _parseAuthError(dynamic error) {
    try {
      String errorString = error.toString().toLowerCase();
      
      if (errorString.contains('already registered') ||
          errorString.contains('user_already_exists')) {
        return AppLanguage.tr('email_already_registered');
      }
      if (errorString.contains('invalid email')) {
        return AppLanguage.tr('email_invalid');
      }
      if (errorString.contains('weak password')) {
        return AppLanguage.tr('weak_password');
      }
      if (errorString.contains('network') ||
          errorString.contains('connection') ||
          errorString.contains('socketexception') ||
          errorString.contains('failed host lookup')) {
        return 'Tidak ada koneksi internet. Mohon periksa koneksi Anda dan coba lagi.';
      }
      
      // Return raw error string for debugging
      return errorString;
    } catch (e) {
      return 'Error: $e';
    }
  }

  Future<void> _signUp() async {
    if (_isLoading) return;
    
    if (!_formKey.currentState!.validate()) return;

    // HAPUS pengecekan terms
    // if (!_agreeToTerms) {
    //   _showSnackBar(AppLanguage.tr('terms_required'), false);
    //   return;
    // }

    setState(() => _isLoading = true);

    try {
      final name = _nameController.text.trim();
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();

      final AuthResponse res = await supabase.auth.signUp(
        email: email,
        password: password,
        data: {
          'name': name,
          'display_name': name,
        },
      );

      if (res.user != null) {
        debugPrint('Signup successful, user ID: ${res.user!.id}');
        
        final profileSuccess = await _createUserProfile(
          res.user!.id,
          name,
          email,
        );

        if (!profileSuccess) {
          debugPrint('Warning: Failed to create user profile');
        }

        if (!mounted) return;
        
        _showSuccessDialog();
      } else {
        if (!mounted) return;
        _showSnackBar(AppLanguage.tr('failed_create_account'), false);
      }
    } catch (e) {
      if (!mounted) return;
      final errorMessage = _parseAuthError(e);
      _showSnackBar(errorMessage, false);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showSnackBar(String message, bool isSuccess) {
    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? successColor : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
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
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: successColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: successColor.withOpacity(0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_circle,
                    size: 48,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  AppLanguage.tr('signup_success_title'),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  AppLanguage.tr('signup_success_message'),
                  style: const TextStyle(
                    fontSize: 15,
                    color: Colors.grey,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _nameController.clear();
                      _emailController.clear();
                      _passwordController.clear();
                      
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const ModernLoginScreen()),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF673AB7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(26),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      AppLanguage.tr('continue_to_login'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
                          AppLanguage.tr('create_account_title'),
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: Colors.black,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 24),
                        
                        // Full Name Field
                        _buildInputLabel(AppLanguage.tr('full_name')),
                        const SizedBox(height: 6),
                        _buildTextField(
                          controller: _nameController,
                          hintText: 'Enter your full name',
                          keyboardType: TextInputType.name,
                          textCapitalization: TextCapitalization.words,
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return AppLanguage.tr('name_required');
                            }
                            if (value.trim().length < 3) {
                              return AppLanguage.tr('name_min_length');
                            }
                            return null;
                          },
                        ),
                        
                        const SizedBox(height: 16),
                        
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
                            if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
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
                              _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                              color: Colors.grey.shade400,
                              size: 20,
                            ),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return AppLanguage.tr('password_required');
                            }
                            if (value.length < 6) {
                              return AppLanguage.tr('password_min_length');
                            }
                            return null;
                          },
                        ),
                        
                        const SizedBox(height: 32),
                        
                        // Create Account Button
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF673AB7).withOpacity(0.2),
                                  blurRadius: 15,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _signUp,
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
                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                      ),
                                    )
                                  : Text(
                                      AppLanguage.tr('create_account_title'),
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
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
                                AppLanguage.tr('already_have_account'),
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 14,
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  Navigator.pushReplacement(
                                    context,
                                    MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
                                  );
                                },
                                child: Text(
                                  AppLanguage.tr('login'),
                                  style: const TextStyle(
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
        color: Colors.blueGrey.shade800.withOpacity(0.6),
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
    TextCapitalization textCapitalization = TextCapitalization.none,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      validator: validator,
      style: const TextStyle(color: Colors.black87, fontSize: 15),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 15),
        filled: true,
        fillColor: const Color(0xFFF1F4F9),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
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