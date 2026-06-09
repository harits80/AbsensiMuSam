import 'package:absenmusam/Petugas/screens/petugas_records_page.dart';
import 'package:absenmusam/Petugas/widgets/petugas_bottom_nav.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import '../../attendance/services/biometric_service.dart';
import '../../auth/services/role_service.dart';
import '../../attendance/services/attendance_service.dart';
import '../../models/attendance_record.dart';
import '../../helpers/rfid_mode_helper.dart';
import '../../attendance/screens/face_registration_page.dart';
import '../../auth/screens/login.dart';
import '../../attendance/screens/export_report_screen.dart';
import 'petugas_members_page.dart';
import '../../helpers/language_helper.dart';

class PetugasProfilePage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;
  final bool isDarkMode;

  const PetugasProfilePage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
    this.isDarkMode = false,
  });

  @override
  State<PetugasProfilePage> createState() => _PetugasProfilePageState();
}

class _PetugasProfilePageState extends State<PetugasProfilePage> {
  final BiometricService _biometricService = BiometricService();
  final RoleService _roleService = RoleService();
  final AttendanceService _attendanceService = AttendanceService();
  final _supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();

  bool _hasRegisteredFace = false;
  bool _isCheckingFace = true;
  bool _isLoadingProfile = false;
  bool _isLoadingAttendance = false;
  bool _isUploadingPhoto = false;
  bool _isEditMode = false;
  bool _isSaving = false;
  String _attendanceMode = 'face';
  int _currentNavIndex = 3;
  Map<String, dynamic>? _userProfile;
  Map<String, dynamic>? _organization;
  AttendanceRecord? _todayAttendance;
  String? _memberCardNumber;

  final _formKey = GlobalKey<FormState>();
  late TextEditingController _displayNameController;
  late TextEditingController _phoneController;
  String _selectedGender = 'male';
  DateTime? _selectedDateOfBirth;

  static const Color primaryColor = Color(0xFF4A1E79);
  static const Color primaryDark = Color(0xFF1F0B38);

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController();
    _phoneController = TextEditingController();
    _userProfile = widget.userProfile;
    _checkFaceRegistration();
    _loadOrganizationInfo();
    _loadTodayAttendance();
    _loadMemberRfidCard();
    _loadAttendanceMode();
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

  void _handleNavigation(int index) {
    if (index == _currentNavIndex) {
      return;
    }

    setState(() {
      _currentNavIndex = index;
    });

    switch (index) {
      case 0:
        Navigator.popUntil(context, (route) => route.isFirst);
        break;

      case 1:
        Navigator.push<bool>(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => Container(
              color: widget.isDarkMode
                  ? const Color(0xFF1F0B38)
                  : const Color(0xFFF8F9FA),
              child: PetugasMembersPage(
                organizationMemberId: widget.organizationMemberId,
                memberData: widget.memberData,
                userProfile: _userProfile ?? widget.userProfile,
                isDarkMode: widget.isDarkMode,
              ),
            ),
          ),
        ).then((_) {
          if (mounted) {
            setState(() {
              _currentNavIndex = 3;
            });
          }
        });
        break;

      case 2:
        Navigator.push<bool>(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => Container(
              color: widget.isDarkMode
                  ? const Color(0xFF1F0B38)
                  : const Color(0xFFF8F9FA),
              child: PetugasRecordsPage(
                organizationMemberId: widget.organizationMemberId,
                memberData: widget.memberData,
                userProfile: _userProfile ?? widget.userProfile,
                isDarkMode: widget.isDarkMode,
              ),
            ),
          ),
        ).then((_) {
          if (mounted) {
            setState(() {
              _currentNavIndex = 3;
            });
          }
        });
        break;

      case 3:
        break;
    }
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
    setState(() {
      _isLoadingProfile = true;
    });

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not logged in');
      }

      final response = await _supabase
          .from('user_profiles')
          .select()
          .eq('id', userId)
          .single();

      if (mounted) {
        setState(() {
          _userProfile = response;
          _populateControllers();
          _isLoadingProfile = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading user profile: $e');
      if (mounted) {
        setState(() {
          _isLoadingProfile = false;
        });
      }
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

  Future<void> _loadAttendanceMode() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final mode = await RfidModeHelper.getAttendanceMode(organizationId);
      if (mounted) {
        setState(() {
          _attendanceMode = mode;
        });
        debugPrint(
          'Attendance mode loaded: $_attendanceMode for org $organizationId',
        );
      }
    } catch (e) {
      debugPrint('Error loading attendance mode: $e');
    }
  }

  Future<void> _saveAttendanceMode(String mode) async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      await RfidModeHelper.saveAttendanceMode(organizationId, mode);
      debugPrint('Attendance mode saved: $mode for org $organizationId');
    } catch (e) {
      debugPrint('Error saving attendance mode: $e');
    }
  }

  Future<void> _loadTodayAttendance() async {
    setState(() {
      _isLoadingAttendance = true;
    });

    try {
      final record = await _attendanceService.getTodayAttendance(
        widget.organizationMemberId,
      );
      if (mounted) {
        setState(() {
          _todayAttendance = record;
          _isLoadingAttendance = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading today attendance: $e');
      if (mounted) {
        setState(() {
          _isLoadingAttendance = false;
        });
      }
    }
  }

  Future<void> _loadMemberRfidCard() async {
    try {
      final card = await _supabase
          .from('rfid_cards')
          .select()
          .eq('organization_member_id', widget.organizationMemberId)
          .eq('is_active', true)
          .maybeSingle();

      if (mounted && card != null) {
        setState(() {
          _memberCardNumber = card['card_number'] as String?;
        });
      }
    } catch (e) {
      debugPrint('Error loading RFID card: $e');
    }
  }

  Future<void> _checkFaceRegistration() async {
    setState(() {
      _isCheckingFace = true;
    });

    try {
      final hasRegistered = await _biometricService.hasRegisteredFace(
        widget.organizationMemberId,
      );

      if (mounted) {
        setState(() {
          _hasRegisteredFace = hasRegistered;
          _isCheckingFace = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR checking face registration: $e');
      if (mounted) {
        setState(() {
          _hasRegisteredFace = false;
          _isCheckingFace = false;
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
      _checkFaceRegistration();
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
          const SnackBar(
            content: Text('Profile photo updated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('!!! ERROR uploading photo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to upload photo: $e'),
            backgroundColor: Colors.red,
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

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) throw Exception('User not logged in');

      final displayName = _displayNameController.text.trim();
      final nameParts = displayName
          .split(' ')
          .where((n) => n.isNotEmpty)
          .toList();

      String firstName;
      String lastName;

      if (nameParts.isEmpty) {
        firstName = 'User';
        lastName = '';
      } else if (nameParts.length == 1) {
        firstName = nameParts[0];
        lastName = '';
      } else {
        firstName = nameParts[0];
        lastName = nameParts.sublist(1).join(' ');
      }

      await _supabase
          .from('user_profiles')
          .update({
            'first_name': firstName,
            'last_name': lastName,
            'display_name': displayName,
            'phone': _phoneController.text.trim().isEmpty
                ? null
                : _phoneController.text.trim(),
            'jenis_kelamin': _selectedGender,
            'date_of_birth': _selectedDateOfBirth?.toIso8601String().split(
              'T',
            )[0],
          })
          .eq('id', userId);

      await _loadUserProfile();

      if (mounted) {
        setState(() {
          _isEditMode = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile updated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('!!! ERROR saving profile: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update profile: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _toggleEditMode() {
    setState(() {
      _isEditMode = !_isEditMode;
      if (!_isEditMode) {
        _populateControllers();
      }
    });
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate:
          _selectedDateOfBirth ??
          DateTime.now().subtract(const Duration(days: 365 * 25)),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: primaryColor,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedDateOfBirth = picked;
      });
    }
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _supabase.auth.signOut();

        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
            (route) => false,
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Logout failed: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  String _getFullName() {
    if (_userProfile == null) return 'Loading...';
    final firstName = _userProfile!['first_name'] ?? '';
    final middleName = _userProfile!['middle_name'] ?? '';
    final lastName = _userProfile!['last_name'] ?? '';

    if (middleName.isNotEmpty) {
      return '$firstName $middleName $lastName'.trim();
    }
    return '$firstName $lastName'.trim();
  }

  String? _getProfilePhotoUrl() {
    if (_userProfile == null || _userProfile!['profile_photo_url'] == null) {
      return null;
    }

    final photoPath = _userProfile!['profile_photo_url'] as String;

    if (photoPath.trim().isEmpty) {
      return null;
    }

    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      return photoPath;
    }

    return _supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return 'Not set';
    try {
      final date = DateTime.parse(dateStr);
      final months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${date.day} ${months[date.month - 1]} ${date.year}';
    } catch (e) {
      return 'Invalid date';
    }
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '-';
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _attendanceMode == 'rfid');
        return false;
      },
      child: Scaffold(
        backgroundColor: widget.isDarkMode
            ? primaryDark
            : const Color(0xFFF8F9FA),
        body: _isLoadingProfile
            ? Center(
                child: CircularProgressIndicator(
                  color: widget.isDarkMode ? Colors.white : primaryColor,
                ),
              )
            : Column(
                children: [
                  _buildHeader(),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          _buildProfileSection(),
                          const SizedBox(height: 32),
                          _buildAccountInformation(),
                          const SizedBox(height: 32),
                          _buildFaceRecognitionCard(),
                          const SizedBox(height: 16),
                          _buildAttendanceSettingsCard(),
                          const SizedBox(height: 16),
                          _buildLanguageSettingsCard(),
                          const SizedBox(height: 24),
                          // 🔥 MENU EXPORT LAPORAN
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 24),
                            child: Card(
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: BorderSide(
                                  color: widget.isDarkMode
                                      ? Colors.white12
                                      : Colors.grey.shade200,
                                ),
                              ),
                              color: widget.isDarkMode
                                  ? const Color(0xFF2D144B)
                                  : Colors.white,
                              child: ListTile(
                                leading: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF2196F3,
                                    ).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.download,
                                    color: Color.fromARGB(255, 103, 45, 196),
                                  ),
                                ),
                                title: const Text(
                                  'Export Laporan',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                                subtitle: const Text(
                                  'Export data absensi ke PDF atau Excel',
                                  style: TextStyle(fontSize: 12),
                                ),
                                trailing: const Icon(
                                  Icons.chevron_right,
                                  color: Colors.grey,
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          const ExportReportScreen(),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // LOGOUT BUTTON
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24.0,
                            ),
                            child: SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _handleLogout,
                                icon: const Icon(Icons.logout),
                                label: const Text('Logout'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: widget.isDarkMode
                                      ? Colors.red.withOpacity(0.15)
                                      : Colors.red.shade50,
                                  foregroundColor: widget.isDarkMode
                                      ? Colors.redAccent.shade100
                                      : Colors.red.shade700,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15),
                                    side: BorderSide(
                                      color: Colors.red.withOpacity(
                                        widget.isDarkMode ? 0.3 : 0.2,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 100),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
        bottomNavigationBar: PetugasBottomNav(
          currentIndex: _currentNavIndex,
          onNavigationTap: _handleNavigation,
          isDarkMode: widget.isDarkMode,
          attendanceMode: _attendanceMode,
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
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
      child: Text(
        AppLanguage.tr('profile'),
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildProfileSection() {
    final photoUrl = _getProfilePhotoUrl();
    final userEmail = _supabase.auth.currentUser?.email ?? 'No email';
    final location = _organization?['name'] ?? 'Loading organization...';

    return Container(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        children: [
          Stack(
            children: [
              Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF8938DF), width: 2),
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
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : (photoUrl != null
                              ? CachedNetworkImage(
                                  imageUrl: photoUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) =>
                                      Container(color: Colors.grey.shade100),
                                  errorWidget: (context, url, error) => Icon(
                                    Icons.person,
                                    size: 80,
                                    color: Colors.grey.shade400,
                                  ),
                                )
                              : Icon(
                                  Icons.person,
                                  size: 80,
                                  color: Colors.grey.shade400,
                                )),
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
                      border: Border.all(color: Colors.white, width: 2),
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
          Text(
            _getFullName(),
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: widget.isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
          Text(
            userEmail,
            style: TextStyle(
              fontSize: 16,
              color: widget.isDarkMode
                  ? const Color(0xFFB066FF)
                  : const Color(0xFF8938DF),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.location_on_outlined,
                size: 16,
                color: widget.isDarkMode
                    ? Colors.white60
                    : Colors.grey.shade500,
              ),
              const SizedBox(width: 4),
              Text(
                location,
                style: TextStyle(
                  fontSize: 14,
                  color: widget.isDarkMode
                      ? Colors.white60
                      : Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAccountInformation() {
    final displayName = _displayNameController.text.isNotEmpty
        ? _displayNameController.text
        : _getFullName();
    final phone = _phoneController.text.isNotEmpty
        ? _phoneController.text
        : (_userProfile?['phone'] ?? 'Not set');
    final jeniskelaminValue = _userProfile?['jenis_kelamin'];
    final employeeCode = _userProfile?['employee_code'] ?? 'Not set';
    final position = _roleService.getRoleName(widget.memberData);

    final dobStr = _selectedDateOfBirth != null
        ? _formatDate(_selectedDateOfBirth!.toIso8601String())
        : (_userProfile?['date_of_birth'] != null
              ? _formatDate(_userProfile!['date_of_birth'])
              : 'Not set');

    final isMale = _selectedGender == 'male';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppLanguage.tr('account_information'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: widget.isDarkMode
                      ? Colors.white70
                      : Colors.grey.shade700,
                  letterSpacing: 1.2,
                ),
              ),
              TextButton.icon(
                onPressed: _isSaving ? null : _toggleEditMode,
                icon: Icon(
                  _isEditMode ? Icons.close : Icons.edit_note_rounded,
                  size: 18,
                ),
                label: Text(
                  _isEditMode
                      ? AppLanguage.tr('cancel')
                      : AppLanguage.tr('edit'),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: widget.isDarkMode
                      ? const Color(0xFFB066FF)
                      : const Color(0xFF8938DF),
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
                  _buildEditableField(
                    label: AppLanguage.tr('display_name'),
                    controller: _displayNameController,
                    validator: (v) =>
                        v!.isEmpty ? AppLanguage.tr('name_required') : null,
                  ),
                  _buildEditableField(
                    label: AppLanguage.tr('phone_number'),
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                  ),
                  _buildGenderField(),
                  _buildDateOfBirthField(),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _saveProfile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8938DF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
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
                          : Text(AppLanguage.tr('save_profile')),
                    ),
                  ),
                ],
              ),
            )
          else
            Column(
              children: [
                _buildInfoRowDesign(
                  AppLanguage.tr('display_name'),
                  displayName,
                ),
                _buildDivider(),
                _buildInfoRowDesign(AppLanguage.tr('phone_number'), phone),
                _buildDivider(),
                _buildInfoRowDesign(
                  AppLanguage.tr('gender'),
                  jeniskelaminValue != null
                      ? (jeniskelaminValue == 'male'
                            ? AppLanguage.tr('male')
                            : AppLanguage.tr('female'))
                      : (isMale
                            ? AppLanguage.tr('male')
                            : AppLanguage.tr('female')),
                ),
                _buildDivider(),
                _buildInfoRowDesign(AppLanguage.tr('date_of_birth'), dobStr),
                _buildDivider(),
                _buildInfoRowDesign(
                  AppLanguage.tr('employee_code'),
                  employeeCode,
                ),
                _buildDivider(),
                _buildInfoRowDesign(AppLanguage.tr('position'), position),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildInfoRowDesign(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: widget.isDarkMode
                  ? Colors.white.withOpacity(0.7)
                  : Colors.grey.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            value ?? 'Not set',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: value != null
                  ? (widget.isDarkMode ? Colors.white : Colors.black)
                  : (widget.isDarkMode ? Colors.white24 : Colors.grey.shade400),
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
          ? Colors.white.withOpacity(0.05)
          : Colors.grey.withOpacity(0.1),
    );
  }

  Widget _buildEditableField({
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: widget.isDarkMode ? Colors.white70 : Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            keyboardType: keyboardType,
            validator: validator,
            style: TextStyle(
              color: widget.isDarkMode ? Colors.white : Colors.black87,
              fontSize: 15,
            ),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: widget.isDarkMode
                  ? Colors.white.withOpacity(0.05)
                  : Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: widget.isDarkMode
                      ? Colors.white12
                      : Colors.grey.shade300,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: widget.isDarkMode
                      ? Colors.white12
                      : Colors.grey.shade300,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFF8938DF),
                  width: 1.5,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenderField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLanguage.tr('gender'),
            style: TextStyle(
              fontSize: 14,
              color: widget.isDarkMode ? Colors.white70 : Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: RadioListTile<String>(
                  title: Text(
                    AppLanguage.tr('male'),
                    style: TextStyle(
                      color: widget.isDarkMode ? Colors.white : Colors.black87,
                    ),
                  ),
                  value: 'male',
                  groupValue: _selectedGender,
                  activeColor: primaryColor,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _selectedGender = v!),
                ),
              ),
              Expanded(
                child: RadioListTile<String>(
                  title: Text(
                    AppLanguage.tr('female'),
                    style: TextStyle(
                      color: widget.isDarkMode ? Colors.white : Colors.black87,
                    ),
                  ),
                  value: 'female',
                  groupValue: _selectedGender,
                  activeColor: primaryColor,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _selectedGender = v!),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDateOfBirthField() {
    final dateDisplay = _selectedDateOfBirth != null
        ? '${_selectedDateOfBirth!.day.toString().padLeft(2, '0')}/${_selectedDateOfBirth!.month.toString().padLeft(2, '0')}/${_selectedDateOfBirth!.year}'
        : AppLanguage.tr('select_date');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLanguage.tr('date_of_birth'),
            style: TextStyle(
              fontSize: 14,
              color: widget.isDarkMode ? Colors.white70 : Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _selectDate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: widget.isDarkMode
                      ? Colors.white12
                      : Colors.grey.shade300,
                ),
                borderRadius: BorderRadius.circular(12),
                color: widget.isDarkMode
                    ? Colors.white.withOpacity(0.05)
                    : Colors.grey.shade50,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    dateDisplay,
                    style: TextStyle(
                      fontSize: 16,
                      color: _selectedDateOfBirth != null
                          ? (widget.isDarkMode ? Colors.white : Colors.black87)
                          : (widget.isDarkMode
                                ? Colors.white38
                                : Colors.grey.shade600),
                    ),
                  ),
                  Icon(
                    Icons.calendar_today,
                    size: 20,
                    color: widget.isDarkMode
                        ? Colors.white54
                        : Colors.grey.shade600,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaceRecognitionCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: widget.isDarkMode ? const Color(0xFF2D144B) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8938DF).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.face_unlock_rounded,
                    color: Color(0xFF8938DF),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLanguage.tr('face_recognition'),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: widget.isDarkMode
                              ? Colors.white
                              : Colors.black87,
                        ),
                      ),
                      Text(
                        _hasRegisteredFace
                            ? AppLanguage.tr('already_registered')
                            : AppLanguage.tr('not_registered_yet'),
                        style: TextStyle(
                          fontSize: 13,
                          color: _hasRegisteredFace
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
                _isCheckingFace
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _hasRegisteredFace
                              ? Colors.green.withOpacity(0.1)
                              : Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _hasRegisteredFace
                              ? AppLanguage.tr('active')
                              : AppLanguage.tr('missing'),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: _hasRegisteredFace
                                ? Colors.green
                                : Colors.orange,
                          ),
                        ),
                      ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _navigateToFaceRegistration,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF8938DF)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(
                  _hasRegisteredFace
                      ? AppLanguage.tr('re_register_face')
                      : AppLanguage.tr('register_now'),
                  style: const TextStyle(color: Color(0xFF8938DF)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttendanceSettingsCard() {
    String modeTitle = '';
    IconData modeIcon = Icons.help_outline;

    switch (_attendanceMode) {
      case 'face':
        modeTitle = AppLanguage.tr('face_recognition');
        modeIcon = Icons.face_retouching_natural_rounded;
        break;
      case 'rfid':
        modeTitle = AppLanguage.tr('rfid_card');
        modeIcon = Icons.copy_all_rounded;
        break;
      case 'selfie':
        modeTitle = AppLanguage.tr('selfie_attendance');
        modeIcon = Icons.camera_alt_rounded;
        break;
      case 'fingerprint':
        modeTitle = AppLanguage.tr('fingerprint');
        modeIcon = Icons.fingerprint_rounded;
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: widget.isDarkMode ? const Color(0xFF2D144B) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
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
                    color: const Color(0xFF8938DF).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.settings_suggest_rounded,
                    color: Color(0xFF8938DF),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    AppLanguage.tr('attendance_settings'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: widget.isDarkMode ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: _showAttendanceModeBottomSheet,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: widget.isDarkMode
                      ? Colors.white.withOpacity(0.05)
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
                    Icon(modeIcon, color: const Color(0xFF8938DF), size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        modeTitle,
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
            ),
          ],
        ),
      ),
    );
  }

  void _showAttendanceModeBottomSheet() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _buildModernSelectMenu(
        title: AppLanguage.tr('attendance_settings'),
        options: [
          _buildSelectOption(
            id: 'face',
            title: AppLanguage.tr('face_recognition'),
            subtitle: AppLanguage.tr('scan_face_subtitle'),
            icon: Icons.face_retouching_natural_rounded,
            isSelected: _attendanceMode == 'face',
          ),
          _buildSelectOption(
            id: 'rfid',
            title: AppLanguage.tr('rfid_card'),
            subtitle: AppLanguage.tr('tap_rfid_subtitle'),
            icon: Icons.copy_all_rounded,
            isSelected: _attendanceMode == 'rfid',
          ),
          _buildSelectOption(
            id: 'selfie',
            title: AppLanguage.tr('selfie_attendance'),
            subtitle: AppLanguage.tr('take_selfie_subtitle'),
            icon: Icons.camera_alt_rounded,
            isSelected: _attendanceMode == 'selfie',
          ),
          _buildSelectOption(
            id: 'fingerprint',
            title: AppLanguage.tr('fingerprint'),
            subtitle: AppLanguage.tr('scan_fingerprint_subtitle'),
            icon: Icons.fingerprint_rounded,
            isSelected: _attendanceMode == 'fingerprint',
          ),
        ],
      ),
    );

    if (result != null) {
      setState(() => _attendanceMode = result);
      _saveAttendanceMode(result);
    }
  }

  Widget _buildSelectOption({
    required String id,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    bool isSoon = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: isSoon ? null : () => Navigator.pop(context, id),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF8938DF).withOpacity(0.1)
                : (widget.isDarkMode
                      ? Colors.white.withOpacity(0.05)
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
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF8938DF)
                      : Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: isSelected ? Colors.white : Colors.grey,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
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
                        if (isSoon) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'SOON',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.orange,
                              ),
                            ),
                          ),
                        ],
                      ],
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
              color: Colors.grey.withOpacity(0.3),
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

  Widget _buildLanguageSettingsCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: widget.isDarkMode ? const Color(0xFF2D144B) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
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
                    color: const Color(0xFF8938DF).withOpacity(0.1),
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
                    AppLanguage.tr('language_settings'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: widget.isDarkMode ? Colors.white : Colors.black87,
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
                          ? Colors.white.withOpacity(0.05)
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
        title: AppLanguage.tr('language_settings'),
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
                ? const Color(0xFF8938DF).withOpacity(0.1)
                : (widget.isDarkMode
                      ? Colors.white.withOpacity(0.05)
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
                      ? Colors.white.withOpacity(0.1)
                      : Colors.grey.withOpacity(0.1),
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
}
