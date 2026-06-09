import 'package:absenmusam/attendance/screens/face_registration_page.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../attendance/services/biometric_service.dart';
import '../../auth/services/role_service.dart';
import '../widgets/user_bottom_nav.dart';
import '../../auth/screens/login.dart';
import '../../helpers/language_helper.dart';
import '../../attendance/screens/timezone_settings_screen.dart';
import '../../services/timezone_service.dart'; // Tambahkan import ini

class UserProfilePage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;
  final bool isDarkMode;

  const UserProfilePage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
    this.isDarkMode = false,
  });

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  final BiometricService _biometricService = BiometricService();
  final RoleService _roleService = RoleService();
  final _supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();

  bool _hasRegisteredFace = false;
  bool _hasRegisteredFingerprint = false;
  bool _hasRegisteredRfid = false;
  bool _isCheckingSecurity = true;
  bool _isUploadingPhoto = false;
  bool _isEditMode = false;
  bool _isSaving = false;
  Map<String, dynamic>? _userProfile;
  Map<String, dynamic>? _organization;

  // Timezone state
  String _selectedTimezone = 'Asia/Jakarta';
  String _timezoneDisplay = 'Jakarta (WIB)';
  bool _isLoadingTimezone = true;

  // Form controllers
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _displayNameController;
  late TextEditingController _phoneController;
  String _selectedGender = 'male';
  DateTime? _selectedDateOfBirth;

  static const Color primaryColor = Color(0xFF4A1E79); // Indigo

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController();
    _phoneController = TextEditingController();
    _userProfile = widget.userProfile;
    
    // Gunakan Future.microtask agar build selesai dulu baru cek status
    Future.microtask(() => _checkSecurityStatus());
    
    _loadOrganizationInfo();
    _loadTimezone(); 
    if (_userProfile == null) {
      _loadUserProfile();
    } else {
      _populateControllers();
    }
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _populateControllers() {
    _displayNameController.text = _userProfile?['display_name'] ?? '';
    _phoneController.text = _userProfile?['phone'] ?? '';
    _selectedGender = _userProfile?['jenis_kelamin'] ?? 'male';
    _selectedDateOfBirth = _userProfile?['date_of_birth'] != null
        ? DateTime.parse(_userProfile!['date_of_birth'])
        : null;
  }

  Future<void> _loadUserProfile() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) throw Exception('User not logged in');

      final response = await _supabase
          .from('user_profiles')
          .select()
          .eq('id', userId)
          .single();

      if (mounted) {
        setState(() {
          _userProfile = response;
          _populateControllers();
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading user profile: $e');
    }
  }

  Future<void> _loadOrganizationInfo() async {
    try {
      final response = await _supabase
          .from('organizations')
          .select('id, name, logo_url')
          .eq('id', widget.memberData['organization_id'])
          .single();

      if (mounted) {
        setState(() {
          _organization = response;
        });
      }
    } catch (e) {
      debugPrint('Error loading organization info: $e');
    }
  }

  // Load timezone from database
  Future<void> _loadTimezone() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      final response = await _supabase
          .from('user_profiles')
          .select('timezone')
          .eq('id', userId)
          .maybeSingle();

      if (mounted) {
        String tz = 'Asia/Jakarta';
        if (response != null && response['timezone'] != null) {
          tz = response['timezone'];
        }

        final info = TimezoneService.getTimezoneInfo(tz);
        setState(() {
          _selectedTimezone = tz;
          _timezoneDisplay = info?['display'] ?? tz;
          _isLoadingTimezone = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading timezone: $e');
      if (mounted) {
        setState(() => _isLoadingTimezone = false);
      }
    }
  }

  // Save timezone to database
  Future<void> _saveTimezone(String timezone, String display) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      await _supabase
          .from('user_profiles')
          .update({'timezone': timezone})
          .eq('id', userId);

      if (mounted) {
        setState(() {
          _selectedTimezone = timezone;
          _timezoneDisplay = display;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Timezone diubah ke $display'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error saving timezone: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal menyimpan timezone: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _checkSecurityStatus() async {
    if (!mounted) return;
    
    final memberId = widget.organizationMemberId;
    debugPrint('🔍 Memeriksa status keamanan untuk Member ID: $memberId');

    setState(() {
      _isCheckingSecurity = true;
    });

    try {
      // Kita panggil satu-satu untuk mempermudah debugging jika ada yang gagal
      final hasFace = await _biometricService.hasRegisteredFace(memberId);
      final hasFinger = await _biometricService.hasRegisteredFingerprint(memberId);
      final hasRfid = await _biometricService.hasRegisteredRfid(memberId);

      debugPrint('📊 Hasil: Wajah=$hasFace, Jari=$hasFinger, RFID=$hasRfid');

      if (mounted) {
        setState(() {
          _hasRegisteredFace = hasFace;
          _hasRegisteredFingerprint = hasFinger;
          _hasRegisteredRfid = hasRfid;
          _isCheckingSecurity = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR checking security status: $e');
      if (mounted) {
        setState(() {
          _isCheckingSecurity = false;
        });
      }
    }
  }

  Future<void> _navigateToFaceRegistration() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FaceRegistrationPage(
          organizationMemberId: widget.organizationMemberId,
        ),
      ),
    );

    if (result == true) {
      _checkSecurityStatus();
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (image == null) return;

      setState(() {
        _isUploadingPhoto = true;
      });

      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) throw Exception('User not logged in');

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '$userId-$timestamp.jpg';
      final filePath = 'mass-profile/$fileName';

      final file = File(image.path);
      await _supabase.storage.from('profile-photos').upload(filePath, file);

      await _supabase
          .from('user_profiles')
          .update({'profile_photo_url': fileName})
          .eq('id', userId);

      await _loadUserProfile();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLanguage.tr('User.profile.photo_updated'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${AppLanguage.tr('User.profile.photo_failed')}: $e'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingPhoto = false;
        });
      }
    }
  }

  Future<void> _updateProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) throw Exception('User not logged in');

      await _supabase
          .from('user_profiles')
          .update({
            'display_name': _displayNameController.text.trim(),
            'phone': _phoneController.text.trim(),
            'jenis_kelamin': _selectedGender,
            'date_of_birth': _selectedDateOfBirth?.toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', userId);

      await _loadUserProfile();

      if (mounted) {
        setState(() {
          _isEditMode = false;
          _isSaving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLanguage.tr('User.profile.profile_updated')),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${AppLanguage.tr('User.profile.profile_failed')}: $e',
            ),
          ),
        );
      }
    }
  }

  String _getFullName() {
    final profile = _userProfile ?? widget.userProfile;
    if (profile == null) return 'User';
    final displayName = profile['display_name'] as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }
    final firstName = profile['first_name'] as String? ?? '';
    final lastName = profile['last_name'] as String? ?? '';
    return '$firstName $lastName'.trim().isEmpty
        ? 'User'
        : '$firstName $lastName'.trim();
  }

  String? _getProfilePhotoUrl() {
    final profile = _userProfile ?? widget.userProfile;
    if (profile == null || profile['profile_photo_url'] == null) return null;
    final photoPath = profile['profile_photo_url'] as String;
    if (photoPath.trim().isEmpty) return null;
    if (photoPath.startsWith('http')) return photoPath;
    return _supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppLanguage.tr('logout_confirm_title')),
        content: Text(AppLanguage.tr('logout_confirm_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppLanguage.tr('cancel')),
          ),
          TextButton(
            onPressed: () async {
              await _supabase.auth.signOut();
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pushAndRemoveUntil(
                  MaterialPageRoute(
                    builder: (context) => const ModernLoginScreen(),
                  ),
                  (route) => false,
                );
              }
            },
            child: Text(
              AppLanguage.tr('logout_confirm_title'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.isDarkMode
          ? const Color(0xFF1F0B38)
          : const Color(0xFFF5F5F5),
      body: RefreshIndicator(
        onRefresh: _loadUserProfile,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // ---------- HEADER SECTION ----------
              Container(
                width: double.infinity,
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 16,
                  bottom: 16,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: widget.isDarkMode
                        ? [const Color(0xFF2D1B4E), const Color(0xFF1F0B38)]
                        : [const Color(0xFF8938DF), const Color(0xFF4A1E79)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Center(
                  child: Text(
                    AppLanguage.tr('User.profile.title'),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

              // ---------- PROFILE SECTION ----------
              Container(
                color: widget.isDarkMode
                    ? const Color(0xFF1F0B38)
                    : const Color(0xFFF5F5F5),
                padding: const EdgeInsets.only(top: 32),
                child: Column(
                  children: [
                    // Profile Photo
                    Stack(
                      children: [
                        Container(
                          width: 130,
                          height: 130,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: widget.isDarkMode
                                  ? const Color(0xFFD0BCFF)
                                  : const Color(0xFF8938DF),
                              width: 2,
                            ),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.grey.shade200,
                            ),
                            child: ClipOval(
                              child: _isUploadingPhoto
                                  ? const Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : _getProfilePhotoUrl() != null
                                  ? Image.network(
                                      _getProfilePhotoUrl()!,
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (context, error, stackTrace) =>
                                              const Icon(
                                                Icons.person,
                                                size: 80,
                                                color: Colors.grey,
                                              ),
                                    )
                                  : Icon(
                                      Icons.person,
                                      size: 80,
                                      color: Colors.grey.shade400,
                                    ),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 5,
                          right: 5,
                          child: GestureDetector(
                            onTap: _pickAndUploadPhoto,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF8938DF),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                              child: const Icon(
                                Icons.edit,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Name
                    Text(
                      _getFullName(),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: widget.isDarkMode
                            ? Colors.white
                            : Colors.black87,
                      ),
                    ),
                    // Email
                    Text(
                      _supabase.auth.currentUser?.email ?? 'No email',
                      style: TextStyle(
                        fontSize: 16,
                        color: widget.isDarkMode
                            ? const Color(0xFFD0BCFF)
                            : const Color(0xFF8938DF),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Location
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 16,
                          color: Colors.grey.shade500,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _organization?['name'] ?? 'Loading...',
                          style: TextStyle(
                            fontSize: 14,
                            color: widget.isDarkMode
                                ? Colors.white54
                                : Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // ---------- CONTENT AREA ----------
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          AppLanguage.tr('User.profile.account_information'),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: widget.isDarkMode
                                ? Colors.white54
                                : Colors.grey.shade700,
                            letterSpacing: 1.2,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _isSaving
                              ? null
                              : () {
                                  setState(() {
                                    _isEditMode = !_isEditMode;
                                    if (!_isEditMode) _populateControllers();
                                  });
                                },
                          icon: Icon(
                            _isEditMode ? Icons.close : Icons.edit_note_rounded,
                            size: 18,
                          ),
                          label: Text(
                            _isEditMode
                                ? AppLanguage.tr('User.profile.cancel')
                                : AppLanguage.tr('User.profile.edit'),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF8938DF),
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_isEditMode)
                      Form(
                        key: _formKey,
                        child: Column(
                          children: [
                            _buildTextField(
                              label: AppLanguage.tr(
                                'User.profile.display_name',
                              ),
                              controller: _displayNameController,
                              icon: Icons.badge_outlined,
                            ),
                            const SizedBox(height: 12),
                            _buildTextField(
                              label: AppLanguage.tr(
                                'User.profile.phone_number',
                              ),
                              controller: _phoneController,
                              icon: Icons.phone_android_rounded,
                              keyboardType: TextInputType.phone,
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: _isSaving ? null : _updateProfile,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF8938DF),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: _isSaving
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Text(
                                        AppLanguage.tr(
                                          'User.profile.save_profile',
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Column(
                        children: [
                          _buildInfoRow(
                            AppLanguage.tr('User.profile.display_name'),
                            _displayNameController.text,
                          ),
                          _buildDivider(),
                          _buildInfoRow(
                            AppLanguage.tr('User.profile.phone_number'),
                            _phoneController.text.isNotEmpty
                                ? _phoneController.text
                                : AppLanguage.tr('User.profile.not_set'),
                          ),
                          _buildDivider(),
                          _buildInfoRow(
                            AppLanguage.tr('User.profile.gender'),
                            _selectedGender.toUpperCase(),
                          ),
                          _buildDivider(),
                          _buildInfoRow(
                            AppLanguage.tr('User.profile.position'),
                            _roleService.getRoleName(widget.memberData),
                          ),
                        ],
                      ),

                    const SizedBox(height: 32),
                    Text(
                      AppLanguage.tr('User.profile.security_status'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: widget.isDarkMode
                            ? Colors.white54
                            : Colors.grey.shade700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildSecurityCard(),
                    const SizedBox(height: 16),

                    // Timezone Settings Card
                    _buildTimezoneSettingsCard(),
                    const SizedBox(height: 16),

                    _buildLanguageSettingsCard(),

                    const SizedBox(height: 48),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showLogoutDialog,
                        icon: const Icon(Icons.logout_rounded),
                        label: Text(AppLanguage.tr('logout_account')),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          backgroundColor: widget.isDarkMode
                              ? Colors.red.withValues(alpha: 0.1)
                              : Colors.red.shade50.withValues(alpha: 0.3),
                          side: BorderSide(
                            color: Colors.redAccent.withValues(alpha: 0.5),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
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
      bottomNavigationBar: CustomBottomNav(
        currentIndex: 1,
        isDarkMode: widget.isDarkMode,
        onTap: (index) {
          if (index == 0) Navigator.pop(context);
        },
      ),
    );
  }

  Widget _buildInfoRow(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: widget.isDarkMode ? Colors.white70 : Colors.grey.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            value ?? AppLanguage.tr('User.profile.not_set'),
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: value != null
                  ? (widget.isDarkMode ? Colors.white : Colors.black)
                  : Colors.grey.shade400,
              fontStyle: value != null ? FontStyle.normal : FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(
      height: 1,
      thickness: 1,
      color: widget.isDarkMode
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.grey.withValues(alpha: 0.1),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required IconData icon,
    bool enabled = true,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(
            icon,
            size: 22,
            color: enabled ? primaryColor : Colors.grey,
          ),
          border: InputBorder.none,
          labelStyle: TextStyle(
            color: enabled ? primaryColor : Colors.grey,
            fontSize: 14,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildSecurityCard() {
    return _isCheckingSecurity
        ? const Center(child: CircularProgressIndicator())
        : Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: widget.isDarkMode ? 0.2 : 0.04,
                  ),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                _buildSecurityItem(
                  icon: _hasRegisteredFace
                      ? Icons.face_retouching_natural_rounded
                      : Icons.face_unlock_rounded,
                  title: AppLanguage.tr('face_recognition'),
                  isRegistered: _hasRegisteredFace,
                  onTap: _navigateToFaceRegistration,
                  registerLabel: AppLanguage.tr('User.profile.register'),
                  reRegisterLabel: AppLanguage.tr('re_register_face'),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1, thickness: 0.5),
                ),
                _buildSecurityItem(
                  icon: Icons.fingerprint_rounded,
                  title: AppLanguage.tr('common.fingerprint'),
                  isRegistered: _hasRegisteredFingerprint,
                  showButton: false, // User can't self-register fingerprint yet
                  promptText: _hasRegisteredFingerprint
                      ? 'Sidik jari sudah aktif'
                      : 'Belum mendaftarkan sidik jari',
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1, thickness: 0.5),
                ),
                _buildSecurityItem(
                  icon: Icons.nfc_rounded,
                  title: AppLanguage.tr('common.rfid_card'),
                  isRegistered: _hasRegisteredRfid,
                  showButton: false, // User can't self-register RFID yet
                  promptText: _hasRegisteredRfid
                      ? 'Kartu RFID sudah aktif'
                      : 'Belum mendaftarkan kartu RFID',
                ),
              ],
            ),
          );
  }

  Widget _buildSecurityItem({
    required IconData icon,
    required String title,
    required bool isRegistered,
    VoidCallback? onTap,
    String? registerLabel,
    String? reRegisterLabel,
    bool showButton = true,
    String? promptText,
  }) {
    return Column(
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF8938DF).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: const Color(0xFF8938DF),
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: widget.isDarkMode
                          ? Colors.white
                          : const Color(0xFF1F2937),
                    ),
                  ),
                  Text(
                    promptText ??
                        (isRegistered
                            ? AppLanguage.tr('User.profile.biometric_ok')
                            : AppLanguage.tr(
                                'User.profile.register_face_prompt',
                              )),
                    style: TextStyle(
                      fontSize: 13,
                      color: isRegistered
                          ? (widget.isDarkMode
                              ? Colors.greenAccent.shade200
                              : Colors.greenAccent.shade700)
                          : (widget.isDarkMode
                              ? Colors.white70
                              : Colors.grey.shade500),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: isRegistered
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                isRegistered
                    ? AppLanguage.tr('active')
                    : AppLanguage.tr('missing'),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isRegistered ? Colors.green : Colors.orange,
                ),
              ),
            ),
          ],
        ),
        if (showButton && onTap != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF8938DF)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
              child: Text(
                isRegistered
                    ? (reRegisterLabel ?? AppLanguage.tr('re_register_face'))
                    : (registerLabel ?? AppLanguage.tr('User.profile.register')),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF8938DF),
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTimezoneSettingsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: widget.isDarkMode ? 0.2 : 0.04,
            ),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF8938DF).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.access_time,
                  color: Color(0xFF8938DF),
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  AppLanguage.tr('User.profile.timezone_settings'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: widget.isDarkMode
                        ? Colors.white54
                        : Colors.grey.shade700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: () async {
              // Navigasi ke TimezoneSettingsScreen dengan mengirim current timezone
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => TimezoneSettingsScreen(
                    currentTimezone: _selectedTimezone,
                  ),
                ),
              );

              // Tangkap hasil yang dikembalikan
              if (result != null && result is Map<String, dynamic>) {
                final newTimezone = result['timezone'] as String;
                final newDisplay = result['display'] as String;

                if (newTimezone != _selectedTimezone) {
                  await _saveTimezone(newTimezone, newDisplay);
                }
              }
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: widget.isDarkMode
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: widget.isDarkMode
                      ? Colors.white12
                      : Colors.grey.shade200,
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.public_rounded,
                    color: Color(0xFF8938DF),
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      AppLanguage.tr('User.profile.current_timezone'),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: widget.isDarkMode
                            ? Colors.white
                            : Colors.black87,
                      ),
                    ),
                  ),
                  if (_isLoadingTimezone)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(
                      _timezoneDisplay,
                      style: TextStyle(
                        fontSize: 14,
                        color: widget.isDarkMode
                            ? Colors.white70
                            : Colors.grey.shade600,
                      ),
                    ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.grey,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Preview current time based on selected timezone
          Row(
            children: [
              Icon(Icons.schedule, size: 16, color: Colors.grey.shade500),
              const SizedBox(width: 8),
              Expanded(
                child: FutureBuilder<DateTime>(
                  future: _getCurrentTimeInTimezone(),
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      final time = snapshot.data!;
                      final formattedTime =
                          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
                      return Text(
                        '${AppLanguage.tr('User.profile.current_time_preview')}: $formattedTime',
                        style: TextStyle(
                          fontSize: 12,
                          color: widget.isDarkMode
                              ? Colors.white54
                              : Colors.grey.shade500,
                        ),
                      );
                    }
                    return Text(
                      _timezoneDisplay,
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.isDarkMode
                            ? Colors.white54
                            : Colors.grey.shade500,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Helper method to get current time in selected timezone
  Future<DateTime> _getCurrentTimeInTimezone() async {
    final now = DateTime.now().toUtc();
    final offset = await _getTimezoneOffset();
    return now.add(Duration(hours: offset));
  }

  // Helper method to get timezone offset
  Future<int> _getTimezoneOffset() async {
    final timezoneService = TimezoneService();
    // Set the selected timezone in service temporarily
    await timezoneService.setSelectedTimezone(_selectedTimezone);
    final time = await timezoneService.getCurrentTimeInTimezone();
    final utcNow = DateTime.now().toUtc();
    return time.difference(utcNow).inHours;
  }

  Widget _buildLanguageSettingsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: widget.isDarkMode ? 0.2 : 0.04,
            ),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF8938DF).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.language_rounded,
                  color: Color(0xFF8938DF),
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  AppLanguage.tr('User.profile.language_settings'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: widget.isDarkMode
                        ? Colors.white54
                        : Colors.grey.shade700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<String>(
            valueListenable: LanguageHelper.languageNotifier,
            builder: (context, currentLang, _) {
              String langName = currentLang == LanguageHelper.indonesian
                  ? 'Bahasa Indonesia'
                  : (currentLang == LanguageHelper.english ? 'English' : 'العربية');
              String flag = currentLang == LanguageHelper.indonesian
                  ? '🇮🇩'
                  : (currentLang == LanguageHelper.english ? '🇺🇸' : '🇸🇦');

              return InkWell(
                onTap: _showLanguageBottomSheet,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: widget.isDarkMode
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: widget.isDarkMode
                          ? Colors.white12
                          : Colors.grey.shade200,
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(flag, style: const TextStyle(fontSize: 20)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          langName,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: widget.isDarkMode
                                ? Colors.white
                                : Colors.black87,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: Colors.grey,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showLanguageBottomSheet() async {
    final currentLang = LanguageHelper.languageNotifier.value;

    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _buildModernSelectMenu(
        title: AppLanguage.tr('User.profile.language_settings'),
        options: [
          _buildLanguageSelectOption(
            code: LanguageHelper.indonesian,
            title: 'Bahasa Indonesia',
            subtitle: 'Indonesian',
            isSelected: currentLang == LanguageHelper.indonesian,
          ),
          _buildLanguageSelectOption(
            code: LanguageHelper.english,
            title: 'English',
            subtitle: 'International',
            isSelected: currentLang == LanguageHelper.english,
          ),
          _buildLanguageSelectOption(
            code: LanguageHelper.arabic,
            title: 'العربية',
            subtitle: 'Arabic',
            isSelected: currentLang == LanguageHelper.arabic,
          ),
        ],
      ),
    );

    if (result != null) {
      await AppLanguage.setLanguage(result);
    }
  }

  Widget _buildLanguageSelectOption({
    required String code,
    required String title,
    required String subtitle,
    required bool isSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => Navigator.pop(context, code),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF8938DF).withValues(alpha: 0.1)
                : (widget.isDarkMode
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.grey.shade50),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? const Color(0xFF8938DF) : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: widget.isDarkMode
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.grey.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    code == 'id'
                        ? '🇮🇩'
                        : (code == 'en' ? '🇺🇸' : '🇸🇦'),
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: widget.isDarkMode
                            ? Colors.white
                            : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: widget.isDarkMode
                            ? Colors.white60
                            : Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                const Icon(
                  Icons.check_circle_rounded,
                  color: Color(0xFF8938DF),
                  size: 24,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModernSelectMenu({
    required String title,
    required List<Widget> options,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF1F0B38) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: widget.isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 24),
          ...options,
        ],
      ),
    );
  }
}
