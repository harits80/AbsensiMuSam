import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/timezone_helper.dart';
import '../../helpers/rfid_mode_helper.dart';
import '../../attendance/services/attendance_service.dart';
import '../../auth/services/role_service.dart';
import '../widgets/petugas_bottom_nav.dart';
import '../../attendance/screens/face_attendance_multi_user_page.dart';
import '../../attendance/screens/face_registration_page.dart';
import 'petugas_members_page.dart';
import 'petugas_records_page.dart';
import 'petugas_profile_page.dart';
import '../../attendance/screens/rfid_attendance_page.dart';
import '../../User/screens/user_dashboard.dart'; // ✅ Added for organization switcher
import 'selfie_attendance_flow_page.dart';
import '../../attendance/screens/fingerprint_attendance_page.dart';
import '../../auth/screens/join_organization_screen.dart'; // ✅ Added for Join Organization option
import '../../helpers/language_helper.dart';
import 'package:cached_network_image/cached_network_image.dart';

class PetugasDashboardPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;
  final bool isDarkMode;

  const PetugasDashboardPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
    this.isDarkMode = false,
  });

  @override
  State<PetugasDashboardPage> createState() => _PetugasDashboardPageState();
}

class _PetugasDashboardPageState extends State<PetugasDashboardPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final AttendanceService _attendanceService = AttendanceService();
  final RoleService _roleService = RoleService();

  bool _isLoadingActivities = true;
  bool _hasRegisteredFace = false;
  bool _isCheckingFace = true;
  int _currentNavIndex = 0;
  String _attendanceMode = 'face';
  String _organizationTimezone = 'Asia/Jakarta';
  Map<String, dynamic>? _organization;
  Map<String, dynamic>? _userProfile;
  bool _isDarkMode = false;

  List<Map<String, dynamic>> _recentActivities = [];

  // Weekly overview data
  bool _isLoadingWeeklyData = true;
  double _totalWeeklyHours = 0.0;
  double _weeklyPercentageChange = 0.0;
  List<double> _dailyHours = [0.0, 0.0, 0.0, 0.0, 0.0]; // Mon-Fri

  // Real-time updates
  Timer? _clockTimer;
  StreamSubscription? _activitySubscription;
  DateTime _nowUtc = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
    debugPrint('=== PETUGAS DASHBOARD INIT (KIOSK MODE) ===');
    debugPrint('Organization Member ID: ${widget.organizationMemberId}');
    debugPrint('Role: ${_roleService.getRoleName(widget.memberData)}');
    _userProfile = widget.userProfile;
    _isDarkMode = widget.isDarkMode;

    // Log memberships for debugging
    final userId = _supabase.auth.currentUser?.id;
    if (userId != null) {
      _roleService.getAllOrganizationMembersWithRoles(userId).then((list) {
        debugPrint(
          '🕵️ DEBUG: User has ${list.length} organization memberships.',
        );
        for (var m in list) {
          debugPrint(
            '  - Org: ${m['organizations']?['name']}, Role: ${m['system_roles']?['name']}',
          );
        }
      });
    }

    _loadUserProfile();
    _loadOrganizationTimezone();
    _loadOrganizationInfo();
    _loadAttendanceMode();
    _checkFaceRegistration();
    _refreshAll();
    _loadWeeklyOverview();
    _initRealTimeClock();
    _initActivityStream();
  }

  void _initRealTimeClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _nowUtc = DateTime.now().toUtc();
        });
      }
    });
  }

  void _initActivityStream() {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    // Standard practice: cancel existing subscription before starting a new one
    _activitySubscription?.cancel();

    // Listen to attendance_logs for real-time updates
    try {
      _activitySubscription = _supabase
          .from('attendance_logs')
          .stream(primaryKey: ['id'])
          .order('event_time')
          .listen(
            (data) {
              debugPrint('📡 Real-time update detected in attendance_logs');
              _refreshAll();
            },
            onError: (error) {
              debugPrint('❌ Real-time subscription error: $error');
              // Optionally attempt to restart after a delay or just swallow to prevent crash
            },
            cancelOnError: false,
          );
    } catch (e) {
      debugPrint('❌ Failed to initialize real-time stream: $e');
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _activitySubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadUserProfile() async {
    // Refresh fully from DB to ensure we have all fields (like profile_photo_url)
    // even if partial data was passed via widget.userProfile.

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        debugPrint('No user logged in');
        return;
      }

      final response = await _supabase
          .from('user_profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();

      if (mounted && response != null) {
        setState(() {
          _userProfile = response;
        });
        debugPrint('User profile loaded: ${_userProfile?['display_name']}');
      }
    } catch (e) {
      debugPrint('Error loading user profile: $e');
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

  Future<void> _loadOrganizationInfo() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('id, name, logo_url')
          .eq('id', organizationId)
          .maybeSingle();

      if (org != null) {
        setState(() {
          _organization = org;
        });
      }
    } catch (e) {
      debugPrint('Error loading organization info for ID $organizationId: $e');
    }
  }

  Future<void> _loadOrganizationTimezone() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone')
          .eq('id', organizationId)
          .maybeSingle();

      if (org != null && org['timezone'] != null) {
        setState(() {
          _organizationTimezone = org['timezone'] as String;
        });
        debugPrint('Organization timezone: $_organizationTimezone');
      }
    } catch (e) {
      debugPrint('Error loading organization timezone: $e');
    }
  }

  Future<void> _loadTodayStats() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      debugPrint(
        'Loading today statistics for organization $organizationId...',
      );

      await _attendanceService.getOrganizationTodayStats(
        organizationId,
        organizationTimezone: _organizationTimezone,
      );
    } catch (e) {
      debugPrint('!!! ERROR loading stats: $e');
    }
  }

  Future<void> _refreshAll() async {
    debugPrint('=== REFRESHING ALL DATA ===');
    _loadUserProfile(); // ✅ Added to ensure profile is updated
    _loadTodayStats();
    _loadRecentActivities();
    _loadWeeklyOverview();
    _checkFaceRegistration();
  }

  Future<void> _checkFaceRegistration() async {
    try {
      debugPrint('🔍 Checking face registration for member ID: ${widget.organizationMemberId}');
      
      final result = await _supabase
          .from('biometric_data')
          .select('id, organization_member_id, biometric_type, is_active')
          .eq('organization_member_id', widget.organizationMemberId)
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true);

      final List data = result as List;
      debugPrint('📊 DB RAW RESPONSE: $data');

      if (mounted) {
        setState(() {
          _hasRegisteredFace = data.isNotEmpty;
          _isCheckingFace = false;
        });
        debugPrint('✅ Final result updated: $_hasRegisteredFace');
      }
    } catch (e) {
      debugPrint('❌ Error checking face registration: $e');
      if (mounted) {
        setState(() {
          _isCheckingFace = false;
        });
      }
    }
  }

  String _composeUserName(Map<String, dynamic>? profile) {
    if (profile == null) return AppLanguage.tr('unknown_user');
    final displayName = profile['display_name'] as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }
    final firstName = profile['first_name'] as String? ?? '';
    final lastName = profile['last_name'] as String? ?? '';
    final fullName = '$firstName $lastName'.trim();
    return fullName.isEmpty ? AppLanguage.tr('unknown_user') : fullName;
  }

  String? _resolveProfilePhotoUrl(String? storedPath) {
    if (storedPath == null || storedPath.trim().isEmpty) return null;
    if (storedPath.startsWith('http://') || storedPath.startsWith('https://')) {
      return storedPath;
    }

    final normalizedPath = storedPath.startsWith('mass-profile/')
        ? storedPath
        : 'mass-profile/$storedPath';

    try {
      return Supabase.instance.client.storage
          .from('profile-photos')
          .getPublicUrl(normalizedPath);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadRecentActivities() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) {
      setState(() {
        _isLoadingActivities = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _isLoadingActivities = true);

    try {
      final activities = await _attendanceService
          .getOrganizationRecentActivities(
            organizationId: organizationId,
            limit: 10,
          );

      if (!mounted) return;

      final groupedActivities = <String, Map<String, dynamic>>{};

      for (final activity in activities) {
        final member =
            activity['organization_members'] as Map<String, dynamic>? ?? {};
        final profile = member['user_profiles'] as Map<String, dynamic>? ?? {};
        final department = member['departments'] as Map<String, dynamic>? ?? {};
        final record =
            activity['attendance_records'] as Map<String, dynamic>? ?? {};
        final rawData = activity['raw_data'] as Map<String, dynamic>? ?? {};

        // Try to get shift name
        String? shiftName = rawData['shift_name']?.toString();
        if (shiftName == null) {
          final wtm = rawData['work_time_mode']?.toString();
          if (wtm != null && !wtm.startsWith('{')) {
            shiftName = wtm;
          }
        }
        // Also try schedule name
        shiftName ??= rawData['schedule_name']?.toString();

        final memberId =
            member['id']?.toString() ??
            activity['organization_member_id']?.toString() ??
            '';
        DateTime? eventTime;
        final eventTimeStr = activity['event_time'] as String?;
        if (eventTimeStr != null) {
          eventTime = TimezoneHelper.parseAndConvert(
            eventTimeStr,
            _organizationTimezone,
          );
        }

        final attendanceDate =
            (record['attendance_date'] as String?) ??
            (eventTimeStr != null ? eventTimeStr.split('T').first : '');
        final key = '$memberId-$attendanceDate';

        final entry = groupedActivities.putIfAbsent(key, () {
          return {
            'name': _composeUserName(profile),
            'photoUrl': _resolveProfilePhotoUrl(
              profile['profile_photo_url'] as String?,
            ),
            'department':
                department['name'] as String? ??
                AppLanguage.tr('no_department'),
            'status': record['status'] as String?,
            'checkInTime': null,
            'checkOutTime': null,
            'checkInMethod': null,
            'checkOutMethod': null,
            'lastAction': null,
            'method': null,
            'lastUpdated': null,
            'shiftName': shiftName,
          };
        });

        if (activity['event_type'] == 'check_in') {
          // If multiple check-ins, usually we want the EARLIEST for the "Check In" slot,
          // but since the loop is NEWEST to OLDEST (DESC), we overwrite to let the
          // last iteration (oldest) win for earliest check-in time.
          entry['checkInTime'] = eventTime;
          entry['checkInMethod'] = activity['method'];
        } else if (activity['event_type'] == 'check_out') {
          // For Check Out, we want the LATEST. Since loop is NEWEST to OLDEST,
          // the first check_out we encounter is the latest one.
          entry['checkOutTime'] ??= eventTime;
          entry['checkOutMethod'] ??= activity['method'];
        }

        // These should reflect the LATEST action overall
        entry['lastAction'] ??= activity['event_type'];
        entry['method'] ??= activity['method'];
        entry['lastUpdated'] ??= eventTime;
      }

      final mappedActivities = groupedActivities.values.toList()
        ..sort((a, b) {
          final aTime =
              a['lastUpdated'] as DateTime? ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final bTime =
              b['lastUpdated'] as DateTime? ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return bTime.compareTo(aTime);
        });

      final limitedActivities = mappedActivities.take(6).toList();

      setState(() {
        _recentActivities = limitedActivities;
        _isLoadingActivities = false;
      });
    } catch (e) {
      debugPrint('!!! ERROR loading recent activities: $e');
      if (!mounted) return;

      setState(() {
        _isLoadingActivities = false;
        _recentActivities = [];
      });
    }
  }

  Future<void> _loadWeeklyOverview() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) {
      setState(() {
        _isLoadingWeeklyData = false;
      });
      return;
    }

    setState(() {
      _isLoadingWeeklyData = true;
    });

    try {
      // Get current week (Monday to Friday)
      final now = DateTime.now();
      final currentWeekday = now.weekday; // 1 = Monday, 7 = Sunday

      // Calculate Monday of current week
      final monday = now.subtract(Duration(days: currentWeekday - 1));
      final mondayStr = monday.toIso8601String().split('T')[0];

      // Calculate Friday of current week
      final friday = monday.add(const Duration(days: 4));
      final fridayStr = friday.toIso8601String().split('T')[0];

      // Get last week's Monday and Friday for comparison
      final lastMonday = monday.subtract(const Duration(days: 7));
      final lastMondayStr = lastMonday.toIso8601String().split('T')[0];
      final lastFriday = lastMonday.add(const Duration(days: 4));
      final lastFridayStr = lastFriday.toIso8601String().split('T')[0];

      debugPrint('Loading weekly overview: $mondayStr to $fridayStr');

      // Fetch current week's attendance records
      final currentWeekRecords = await _supabase
          .from('attendance_records')
          .select('''
            attendance_date,
            work_duration_minutes,
            organization_members!inner(organization_id)
          ''')
          .eq('organization_members.organization_id', organizationId)
          .gte('attendance_date', mondayStr)
          .lte('attendance_date', fridayStr);

      // Fetch last week's attendance records
      final lastWeekRecords = await _supabase
          .from('attendance_records')
          .select('''
            work_duration_minutes,
            organization_members!inner(organization_id)
          ''')
          .eq('organization_members.organization_id', organizationId)
          .gte('attendance_date', lastMondayStr)
          .lte('attendance_date', lastFridayStr);

      // Calculate daily hours for current week
      final dailyHoursMap = <int, double>{
        1: 0.0, // Monday
        2: 0.0, // Tuesday
        3: 0.0, // Wednesday
        4: 0.0, // Thursday
        5: 0.0, // Friday
      };

      double totalMinutes = 0.0;
      for (final record in currentWeekRecords as List) {
        final dateStr = record['attendance_date'] as String?;
        final minutes = record['work_duration_minutes'] as int?;

        if (dateStr != null && minutes != null && minutes > 0) {
          final date = DateTime.parse(dateStr);
          final weekday = date.weekday;

          if (weekday >= 1 && weekday <= 5) {
            dailyHoursMap[weekday] =
                (dailyHoursMap[weekday] ?? 0.0) + (minutes / 60.0);
            totalMinutes += minutes;
          }
        }
      }

      // Calculate last week's total
      double lastWeekMinutes = 0.0;
      for (final record in lastWeekRecords as List) {
        final minutes = record['work_duration_minutes'] as int?;
        if (minutes != null && minutes > 0) {
          lastWeekMinutes += minutes;
        }
      }

      // Calculate percentage change
      double percentageChange = 0.0;
      if (lastWeekMinutes > 0) {
        percentageChange =
            ((totalMinutes - lastWeekMinutes) / lastWeekMinutes) * 100;
      } else if (totalMinutes > 0) {
        percentageChange =
            100.0; // If no data last week but have data this week
      }

      if (mounted) {
        setState(() {
          _totalWeeklyHours = totalMinutes / 60.0;
          _weeklyPercentageChange = percentageChange;
          _dailyHours = [
            dailyHoursMap[1]!,
            dailyHoursMap[2]!,
            dailyHoursMap[3]!,
            dailyHoursMap[4]!,
            dailyHoursMap[5]!,
          ];
          _isLoadingWeeklyData = false;
        });
      }

      debugPrint(
        'Weekly overview loaded: ${_totalWeeklyHours.toStringAsFixed(1)} hrs, ${_weeklyPercentageChange.toStringAsFixed(1)}% change',
      );
    } catch (e) {
      debugPrint('!!! ERROR loading weekly overview: $e');
      if (mounted) {
        setState(() {
          _isLoadingWeeklyData = false;
        });
      }
    }
  }

  Future<void> _navigateToMultiUserFaceAttendance(String? type) async {
    try {
      final organizationId = widget.memberData['organization_id'];

      if (organizationId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLanguage.tr('organization_id_not_found'))),
        );
        return;
      }

      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FaceAttendanceMultiUserPage(
            organizationId: organizationId,
            attendanceType: type,
          ),
        ),
      );

      if (result == true) {
        _refreshAll();
      }
    } catch (e) {
      debugPrint('Error navigating to multi-user face attendance: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${AppLanguage.tr('error')}: $e')));
    }
  }

  Future<void> _handleCameraButtonPress() async {
    // Reload attendance mode from SharedPreferences to ensure latest value
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId != null) {
      _attendanceMode = await RfidModeHelper.getAttendanceMode(organizationId);
    }

    if (_attendanceMode == 'rfid') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => RfidAttendancePage(
            organizationMemberId: widget.organizationMemberId,
            memberData: widget.memberData,
            userProfile: _userProfile ?? widget.userProfile,
          ),
        ),
      ).then((_) {
        _refreshAll();
      });
      return;
    } else if (_attendanceMode == 'selfie') {
      // Navigate to selfie attendance flow - always use self-attendance mode from dashboard button
      _handleSelfAttendance();
      return;
    } else if (_attendanceMode == 'fingerprint') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FingerprintAttendancePage(
            organizationMemberId: widget.organizationMemberId,
            memberData: widget.memberData,
            userProfile: _userProfile ?? widget.userProfile,
          ),
        ),
      ).then((_) => _refreshAll());
    } else if (_attendanceMode == 'face') {
      _navigateToMultiUserFaceAttendance(null);
    }
  }

  void _handleSelfAttendance() {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    final orgName = _organization?['name'] ?? AppLanguage.tr('organization');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SelfieAttendanceFlowPage(
          organizationId: organizationId,
          organizationName: orgName,
          petugasData: widget.memberData,
          isSelfAttendance: true,
        ),
      ),
    ).then((result) {
      if (result != null && result['success'] == true) {
        _refreshAll();
      }
    });
  }

  Future<void> _showOrganizationSwitcher() async {
    final selectedMembership = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _buildOrganizationSwitcherSheet(),
    );

    if (!mounted) return;
    if (selectedMembership == null) return;

    // Skip jika sudah di organisasi yang sama
    if (selectedMembership['id'] == widget.organizationMemberId) return;

    // Navigasi berdasarkan role — dilakukan di context dashboard (valid)
    final roleCode = _roleService.getRoleCode(selectedMembership);
    if (_roleService.isPetugas(selectedMembership) || roleCode == 'SA001') {
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              PetugasDashboardPage(
                organizationMemberId: selectedMembership['id'] as int,
                memberData: selectedMembership,
                userProfile: _userProfile,
                isDarkMode: _isDarkMode,
              ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => UserDashboardPage(
            organizationMemberId: selectedMembership['id'] as int,
            memberData: selectedMembership,
            isDarkMode: _isDarkMode,
          ),
        ),
      );
    }
  }

  Widget _buildOrganizationSwitcherSheet() {
    return Container(
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF1F0B38) : Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: _isDarkMode ? Colors.white24 : Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppLanguage.tr('switch_organization'),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: _isDarkMode ? Colors.white : const Color(0xFF1F2937),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _roleService.getAllOrganizationMembersWithRoles(
              _supabase.auth.currentUser!.id,
            ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              final memberships = snapshot.data ?? [];

              return Column(
                children: [
                  ...memberships.map((membership) {
                    final organization = membership['organizations'];
                    final roleName = _roleService.getRoleName(membership);
                    final isActive =
                        membership['id'] == widget.organizationMemberId;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: InkWell(
                        // Kembalikan membership ke .then() di _showOrganizationSwitcher
                        onTap: () => Navigator.pop(context, membership),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isActive
                                ? const Color(
                                    0xFF4A1E79,
                                  ).withOpacity(_isDarkMode ? 0.3 : 0.05)
                                : (_isDarkMode
                                      ? const Color(0xFF2D1B4E)
                                      : Colors.white),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isActive
                                  ? const Color(0xFF8938DF)
                                  : (_isDarkMode
                                        ? Colors.white12
                                        : Colors.grey.shade200),
                              width: isActive ? 2 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? const Color(0xFF4A1E79)
                                      : (_isDarkMode
                                            ? Colors.white10
                                            : Colors.grey.shade100),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.business,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      organization?['name'] ??
                                          AppLanguage.tr('unknown_org'),
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        height: 1.1,
                                        color: _isDarkMode
                                            ? Colors.white
                                            : const Color(0xFF1F2937),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      roleName.toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 11,
                                        height: 1.0,
                                        color: _isDarkMode
                                            ? Colors.white60
                                            : Colors.grey.shade500,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (isActive)
                                const Icon(
                                  Icons.check_circle,
                                  color: Color(0xFF8938DF),
                                  size: 24,
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                  const Divider(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context); // Close switcher
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const JoinOrganizationScreen(
                              fromDashboard: true,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.add_business_rounded),
                      label: Text(AppLanguage.tr('join_new_organization')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4A1E79),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _navigateToProfile() {
    Navigator.push<bool>(
      context,
      PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, _, __) => Container(
          color: _isDarkMode
              ? const Color(0xFF1F0B38)
              : const Color(0xFFF8F9FA),
          child: PetugasProfilePage(
            organizationMemberId: widget.organizationMemberId,
            memberData: widget.memberData,
            userProfile: _userProfile ?? widget.userProfile,
            isDarkMode: _isDarkMode,
          ),
        ),
      ),
    ).then((_) {
      _loadAttendanceMode();
      _loadUserProfile();
    });
  }

  void _handleNavigation(int index) {
    if (index == _currentNavIndex) return;

    setState(() {
      _currentNavIndex = index;
    });

    switch (index) {
      case 0:
        break;
      case 1:
        Navigator.push<bool>(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => Container(
              color: _isDarkMode
                  ? const Color(0xFF1F0B38)
                  : const Color(0xFFF8F9FA),
              child: PetugasMembersPage(
                organizationMemberId: widget.organizationMemberId,
                memberData: widget.memberData,
                userProfile: _userProfile ?? widget.userProfile,
                isDarkMode: _isDarkMode,
              ),
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 0;
          });
          _refreshAll();
        });
        break;
      case 2:
        Navigator.push<bool>(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => Container(
              color: _isDarkMode
                  ? const Color(0xFF1F0B38)
                  : const Color(0xFFF8F9FA),
              child: PetugasRecordsPage(
                organizationMemberId: widget.organizationMemberId,
                memberData: widget.memberData,
                userProfile: _userProfile ?? widget.userProfile,
                isDarkMode: _isDarkMode,
              ),
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 0;
          });
          _refreshAll();
        });
        break;
      case 3:
        _navigateToProfile();
        setState(() {
          _currentNavIndex = 0;
        });
        break;
    }
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    return DateFormat(
      'EEEE, dd MMM yyyy',
      AppLanguage.currentLanguage == 'id' ? 'id_ID' : 'en_US',
    ).format(now);
  }

  String _getFullName() {
    final profile = _userProfile ?? widget.userProfile;
    if (profile == null) {
      return '';
    }

    final displayName = profile['display_name'] as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }

    final firstName = profile['first_name'] as String? ?? '';
    final middleName = profile['middle_name'] as String? ?? '';
    final lastName = profile['last_name'] as String? ?? '';

    if (middleName.isNotEmpty) {
      return '$firstName $middleName $lastName'.trim();
    }

    return '$firstName $lastName'.trim();
  }

  String _getEmail() {
    return _supabase.auth.currentUser?.email ?? AppLanguage.tr('no_email');
  }

  String? _getProfilePhotoUrl() {
    final profile = _userProfile ?? widget.userProfile;
    if (profile == null) return null;

    final photoPath = profile['profile_photo_url'] as String?;
    return _resolveProfilePhotoUrl(photoPath);
  }

  String _formatEventType(String? type) {
    switch (type) {
      case 'check_in':
        return AppLanguage.tr('check_in');
      case 'check_out':
        return AppLanguage.tr('check_out');
      default:
        if (type == null) return AppLanguage.tr('activity');
        return type.replaceAll('_', ' ').toUpperCase();
    }
  }

  String _formatEventTime(DateTime? time) {
    if (time == null) return AppLanguage.tr('unknown_time');

    final nowUtc = DateTime.now().toUtc();
    final nowOrg = TimezoneHelper.convertUtcToOrgTimezone(
      nowUtc,
      _organizationTimezone,
    );

    final isToday =
        nowOrg.year == time.year &&
        nowOrg.month == time.month &&
        nowOrg.day == time.day;

    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute';

    if (isToday) {
      return '${AppLanguage.tr('today')} • $timeStr';
    }

    final dateStr = '${time.day}/${time.month}/${time.year}';
    return '$dateStr • $timeStr';
  }

  String _formatShortTime(DateTime? time) {
    if (time == null) return '--';
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final nowOrg = TimezoneHelper.convertUtcToOrgTimezone(
      _nowUtc,
      _organizationTimezone,
    );
    final hour = nowOrg.hour.toString().padLeft(2, '0');
    final minute = nowOrg.minute.toString().padLeft(2, '0');
    final currentTime = '$hour:$minute';

    return Scaffold(
      backgroundColor: _isDarkMode
          ? const Color(0xFF1F0B38)
          : const Color(0xFFF5F5F5),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // HEADER WITH PROFILE
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 32),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _isDarkMode
                        ? [const Color(0xFF2D1B4E), const Color(0xFF1F0B38)]
                        : [const Color(0xFF8938DF), const Color(0xFF4A1E79)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Column(
                  children: [
                    // Logo and Theme Toggle Row
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Transform.translate(
                            offset: const Offset(-16, -16), // Shift left and up
                            child: Image.asset(
                              'assets/logo/app_logo.png',
                              width: 180,
                              height: 180,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              isAntiAlias: true,
                              errorBuilder: (context, error, stackTrace) {
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                          Transform.translate(
                            offset: const Offset(
                              0,
                              -16,
                            ), // Shift up to align with logo
                            child: IconButton(
                              icon: Icon(
                                _isDarkMode
                                    ? Icons.light_mode_rounded
                                    : Icons.dark_mode_outlined,
                                color: Colors.white,
                                size: 26,
                              ),
                              onPressed: () {
                                setState(() {
                                  _isDarkMode = !_isDarkMode;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    // PROFILE SECTION (Photo, Name, Role, Date) - Combined
                    Transform.translate(
                      offset: const Offset(0, -60),
                      child: Column(
                        children: [
                          // Profile Photo
                          GestureDetector(
                            onTap: _navigateToProfile,
                            child: Container(
                              width: 110,
                              height: 110,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 15,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: ClipOval(
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: _isDarkMode
                                          ? [
                                              const Color(0xFFD0BCFF),
                                              const Color(0xFF8938DF),
                                            ]
                                          : [
                                              const Color(0xFF8938DF),
                                              const Color(0xFF4A1E79),
                                            ],
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                    ),
                                  ),
                                  child: _getProfilePhotoUrl() != null
                                      ? CachedNetworkImage(
                                          imageUrl: _getProfilePhotoUrl()!,
                                          fit: BoxFit.cover,
                                          placeholder: (context, url) =>
                                              const Icon(
                                                Icons.person,
                                                size: 60,
                                                color: Colors.white70,
                                              ),
                                          errorWidget: (context, url, error) =>
                                              const Icon(
                                                Icons.person,
                                                size: 60,
                                                color: Colors.white,
                                              ),
                                        )
                                      : const Icon(
                                          Icons.person,
                                          size: 60,
                                          color: Colors.white,
                                        ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Name
                          GestureDetector(
                            onTap: _navigateToProfile,
                            child: Text(
                              _getFullName().isNotEmpty
                                  ? _getFullName()
                                  : AppLanguage.tr('user'),
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Role and Organization
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                debugPrint(
                                  '🏢 HEADER Organization Switcher tapped!',
                                );
                                _showOrganizationSwitcher();
                              },
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.2),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        '${_roleService.getRoleName(widget.memberData)}${_organization != null ? ' - ${_organization!['name']}' : ''}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          height: 1.0,
                                          color: Colors.white.withOpacity(0.95),
                                        ),
                                        textAlign: TextAlign.center,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      color: Colors.white.withOpacity(0.8),
                                      size: 16,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Date
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.calendar_today,
                                  color: Colors.white,
                                  size: 14,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _getCurrentDate(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // WHITE CONTENT AREA
              Container(
                decoration: BoxDecoration(
                  color: _isDarkMode
                      ? const Color(0xFF1F0B38)
                      : const Color(0xFFF5F5F5),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(32),
                    topRight: Radius.circular(32),
                  ),
                ),
                child: Column(
                  children: [
                    // COMBINED TIME & CHECK-IN CARD (OVERLAPPING)
                    Transform.translate(
                      offset: const Offset(0, -80),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          children: [
                            _buildTimeCard(currentTime, nowOrg),
                            const SizedBox(height: 16),
                            _buildFaceRegistrationCard(),
                          ],
                        ),
                      ),
                    ),

                    Transform.translate(
                      offset: const Offset(0, -20),
                      child: const SizedBox(height: 0),
                    ),

                    // WEEKLY OVERVIEW
                    Transform.translate(
                      offset: const Offset(0, -70),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  AppLanguage.tr(
                                    'Petugas.dashboard.weekly_overview',
                                  ),
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: _isDarkMode
                                        ? Colors.white
                                        : Colors.black87,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        (_isDarkMode
                                                ? const Color(0xFFD0BCFF)
                                                : const Color(0xFF4A1E79))
                                            .withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    AppLanguage.tr(
                                      'Petugas.dashboard.this_week',
                                    ),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: _isDarkMode
                                          ? const Color(0xFFD0BCFF)
                                          : const Color(0xFF4A1E79),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: _isDarkMode
                                    ? const Color(0xFF2D1B4E)
                                    : Colors.white,
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
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        _isLoadingWeeklyData
                                            ? '--'
                                            : _totalWeeklyHours.toStringAsFixed(
                                                1,
                                              ),
                                        style: TextStyle(
                                          fontSize: 36,
                                          fontWeight: FontWeight.bold,
                                          color: _isDarkMode
                                              ? Colors.white
                                              : Colors.black87,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Padding(
                                        padding: EdgeInsets.only(bottom: 8),
                                        child: Text(
                                          AppLanguage.tr(
                                            'Petugas.dashboard.total_hours',
                                          ),
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: _isDarkMode
                                                ? Colors.white54
                                                : Colors.grey.shade600,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 6,
                                        ), // Slightly adjusted for optinal optical alignment
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 12,
                                              height: 12,
                                              decoration: BoxDecoration(
                                                color: _isDarkMode
                                                    ? const Color(0xFFD0BCFF)
                                                    : const Color(0xFF4A1E79),
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              AppLanguage.tr(
                                                'Petugas.dashboard.hours',
                                              ),
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: _isDarkMode
                                                    ? Colors.white54
                                                    : Colors.grey.shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (!_isLoadingWeeklyData)
                                    Row(
                                      children: [
                                        Icon(
                                          _weeklyPercentageChange >= 0
                                              ? Icons.trending_up
                                              : Icons.trending_down,
                                          color: _weeklyPercentageChange >= 0
                                              ? (_isDarkMode
                                                    ? Colors.greenAccent
                                                    : Colors.green.shade600)
                                              : (_isDarkMode
                                                    ? Colors.redAccent
                                                    : Colors.red.shade600),
                                          size: 16,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${_weeklyPercentageChange >= 0 ? '+' : ''}${_weeklyPercentageChange.toStringAsFixed(1)}% ${AppLanguage.tr('from_last_week')}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _weeklyPercentageChange >= 0
                                                ? (_isDarkMode
                                                      ? Colors.greenAccent
                                                      : Colors.green.shade600)
                                                : (_isDarkMode
                                                      ? Colors.redAccent
                                                      : Colors.red.shade600),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  const SizedBox(height: 24),
                                  // Bar Chart
                                  if (!_isLoadingWeeklyData)
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceAround,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        _buildBarChart(
                                          AppLanguage.tr('mon_short'),
                                          _dailyHours[0],
                                          0,
                                        ),
                                        _buildBarChart(
                                          AppLanguage.tr('tue_short'),
                                          _dailyHours[1],
                                          1,
                                        ),
                                        _buildBarChart(
                                          AppLanguage.tr('wed_short'),
                                          _dailyHours[2],
                                          2,
                                        ),
                                        _buildBarChart(
                                          AppLanguage.tr('thu_short'),
                                          _dailyHours[3],
                                          3,
                                        ),
                                        _buildBarChart(
                                          AppLanguage.tr('fri_short'),
                                          _dailyHours[4],
                                          4,
                                        ),
                                      ],
                                    )
                                  else
                                    const Center(
                                      child: Padding(
                                        padding: EdgeInsets.all(20),
                                        child: CircularProgressIndicator(),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // RECENT ACTIVITY
                    Transform.translate(
                      offset: const Offset(0, -70),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  AppLanguage.tr(
                                    'Petugas.dashboard.recent_activity',
                                  ),
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: _isDarkMode
                                        ? Colors.white
                                        : Colors.black87,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    _handleNavigation(2);
                                  },
                                  child: Text(
                                    AppLanguage.tr('view_all'),
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: _isDarkMode
                                          ? const Color(0xFFD0BCFF)
                                          : const Color(0xFF4A1E79),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (_isLoadingActivities)
                              Container(
                                padding: const EdgeInsets.all(32),
                                decoration: BoxDecoration(
                                  color: _isDarkMode
                                      ? const Color(0xFF2D1B4E)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Center(
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        _isDarkMode
                                            ? const Color(0xFFD0BCFF)
                                            : const Color(0xFF4A1E79),
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else if (_recentActivities.isEmpty)
                              Container(
                                padding: const EdgeInsets.all(32),
                                decoration: BoxDecoration(
                                  color: _isDarkMode
                                      ? const Color(0xFF2D1B4E)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Center(
                                  child: Column(
                                    children: [
                                      Icon(
                                        Icons.history,
                                        size: 48,
                                        color: _isDarkMode
                                            ? Colors.white24
                                            : Colors.grey.shade300,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        AppLanguage.tr(
                                          'Petugas.dashboard.no_recent_activity',
                                        ),
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: _isDarkMode
                                              ? Colors.white54
                                              : Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            else
                              Column(
                                children: _recentActivities
                                    .take(3)
                                    .map(
                                      (activity) =>
                                          _buildModernActivityItem(activity),
                                    )
                                    .toList(),
                              ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: PetugasBottomNav(
        currentIndex: _currentNavIndex,
        onNavigationTap: _handleNavigation,
        onAttendanceTap: _handleCameraButtonPress,
        isDarkMode: _isDarkMode,
        attendanceMode: _attendanceMode,
      ),
    );
  }

  Widget _buildTimeCard(String currentTime, DateTime nowOrg) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          // Time and Location Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLanguage.tr('current_time'),
                      style: TextStyle(
                        fontSize: 12,
                        color: _isDarkMode
                            ? Colors.white70
                            : Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$currentTime ${nowOrg.hour < 12 ? AppLanguage.tr('am') : AppLanguage.tr('pm')}',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: _isDarkMode
                            ? Colors.white
                            : const Color(0xFF4A1E79),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 1,
                height: 45,
                margin: const EdgeInsets.only(top: 10),
                color: _isDarkMode
                    ? Colors.white24
                    : Colors.grey.shade200,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              AppLanguage.tr(
                                'Petugas.dashboard.office_location',
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                color: _isDarkMode
                                    ? Colors.white70
                                    : Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              Icons.location_on,
                              color: _isDarkMode
                                  ? const Color(0xFFD0BCFF)
                                  : const Color(0xFF4A1E79),
                              size: 16,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                _organization?['name'] ??
                                    AppLanguage.tr(
                                      'office',
                                    ),
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: _isDarkMode
                                      ? const Color(
                                          0xFFD0BCFF,
                                        )
                                      : Colors.black87,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Check In Button
          SizedBox(
            width: double.infinity,
            child: Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF8938DF),
                    Color(0xFF4A1E79),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(
                      0xFF4A1E79,
                    ).withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _handleSelfAttendance,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                    ),
                    child: Text(
                      AppLanguage.tr(
                        'Petugas.dashboard.selfie_gps',
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaceRegistrationCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF8938DF).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.face_unlock_rounded,
                  color: Color(0xFF8938DF),
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pengenalan Wajah',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _hasRegisteredFace 
                          ? 'Semua sudah baik' 
                          : 'Daftarkan wajah Anda untuk menggunakan fitur absensi',
                      style: TextStyle(
                        fontSize: 13,
                        color: _hasRegisteredFace ? Colors.green : Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _hasRegisteredFace ? Colors.green.withOpacity(0.1) : const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _hasRegisteredFace ? 'Aktif' : 'Belum ada',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _hasRegisteredFace ? Colors.green : const Color(0xFFB45309),
                  ),
                ),
              ),
            ],
          ),
          if (!_hasRegisteredFace) ...[
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => FaceRegistrationPage(
                      organizationMemberId: widget.organizationMemberId,
                    ),
                  ),
                ).then((_) => _checkFaceRegistration()),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF8938DF), width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'DAFTARKAN',
                  style: TextStyle(
                    color: Color(0xFF8938DF),
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBarChart(String day, double hours, int dayIndex) {
    // Find max hours for normalization
    final maxHours = _dailyHours.isEmpty
        ? 0.0
        : _dailyHours.reduce((a, b) => a > b ? a : b);

    // Calculate height (normalize to 0-1 range, with minimum 20% for visibility)
    double normalizedHeight = 0.2; // Minimum height for empty days
    if (maxHours > 0 && hours > 0) {
      normalizedHeight = (hours / maxHours).clamp(0.2, 1.0);
    }

    // Check if this is the current day
    final now = DateTime.now();
    final isCurrentDay = now.weekday == dayIndex + 1;

    return Column(
      children: [
        Container(
          width: 40,
          height: 100 * normalizedHeight,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isCurrentDay
                  ? (_isDarkMode
                        ? [const Color(0xFFD0BCFF), const Color(0xFF8938DF)]
                        : [const Color(0xFF8938DF), const Color(0xFF4A1E79)])
                  : [
                      (_isDarkMode
                              ? const Color(0xFFD0BCFF)
                              : const Color(0xFF4A1E79))
                          .withOpacity(_isDarkMode ? 0.25 : 0.15),
                      (_isDarkMode
                              ? const Color(0xFFD0BCFF)
                              : const Color(0xFF4A1E79))
                          .withOpacity(_isDarkMode ? 0.25 : 0.15),
                    ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          day,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isCurrentDay ? FontWeight.bold : FontWeight.w500,
            color: isCurrentDay
                ? (_isDarkMode
                      ? const Color(0xFFD0BCFF)
                      : const Color(0xFF4A1E79))
                : (_isDarkMode ? Colors.white54 : Colors.grey.shade600),
          ),
        ),
      ],
    );
  }

  Widget _buildModernActivityItem(Map<String, dynamic> activity) {
    final name = activity['name'] as String? ?? AppLanguage.tr('unknown_user');
    final checkInTime = activity['checkInTime'] as DateTime?;
    final checkOutTime = activity['checkOutTime'] as DateTime?;
    final lastUpdated = activity['lastUpdated'] as DateTime?;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _isDarkMode
                ? Colors.black26
                : Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          if (checkInTime != null)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _isDarkMode ? Colors.white : Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.login,
                    color: _isDarkMode ? Colors.green : Colors.green.shade600,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLanguage.tr('Petugas.dashboard.check_in'),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: _isDarkMode ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lastUpdated != null
                            ? _formatEventTime(lastUpdated)
                            : AppLanguage.tr('unknown_time'),
                        style: TextStyle(
                          fontSize: 12,
                          color: _isDarkMode
                              ? Colors.white54
                              : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatShortTime(checkInTime),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _isDarkMode ? Colors.white : Colors.black87,
                      ),
                    ),
                    if (activity['checkInMethod'] != null)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green.shade100),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _getMethodIcon(activity['checkInMethod']),
                              size: 10,
                              color: Colors.green.shade700,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatMethodName(activity['checkInMethod']),
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.green.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          if (checkInTime != null && checkOutTime != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Divider(
                height: 1,
                color: _isDarkMode ? Colors.white24 : Colors.grey.shade200,
              ),
            ),
          if (checkOutTime != null)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _isDarkMode ? Colors.white : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.logout,
                    color: _isDarkMode ? Colors.red : Colors.red.shade600,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLanguage.tr('Petugas.dashboard.check_out'),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: _isDarkMode ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lastUpdated != null
                            ? _formatEventTime(lastUpdated)
                            : AppLanguage.tr('unknown_time'),
                        style: TextStyle(
                          fontSize: 12,
                          color: _isDarkMode
                              ? Colors.white54
                              : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatShortTime(checkOutTime),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _isDarkMode ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Shift Name Badge
                    if (activity['shiftName'] != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.blue.shade200),
                        ),
                        child: Text(
                          activity['shiftName']!.toString().toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.blue.shade700,
                          ),
                        ),
                      ),
                    // Method Badge (e.g. RFID, SELFIE)
                    if (activity['checkOutMethod'] != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _getMethodIcon(activity['checkOutMethod']),
                              size: 10,
                              color: Colors.grey.shade700,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatMethodName(activity['checkOutMethod']),
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildActivityItem(Map<String, dynamic> activity) {
    final name = activity['name'] as String? ?? 'Unknown User';
    final photoUrl = activity['photoUrl'] as String?;
    final lastUpdated = activity['lastUpdated'] as DateTime?;
    final checkInTime = activity['checkInTime'] as DateTime?;
    final checkOutTime = activity['checkOutTime'] as DateTime?;
    final checkInMethod = activity['checkInMethod'] as String?;
    final checkOutMethod = activity['checkOutMethod'] as String?;

    // Get department info from the activity data
    final department = activity['department'] as String? ?? 'No Department';

    final ImageProvider avatarImage = (photoUrl != null && photoUrl.isNotEmpty)
        ? NetworkImage(photoUrl)
        : const AssetImage('images/logo.png');

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Profile Photo - smaller
              Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF4A1E79), width: 2),
                  color: Colors.grey.shade100,
                ),
                child: ClipOval(
                  child: photoUrl != null && photoUrl.isNotEmpty
                      ? Image.network(
                          photoUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return const Icon(
                              Icons.person,
                              size: 22,
                              color: Colors.grey,
                            );
                          },
                        )
                      : const Icon(Icons.person, size: 22, color: Colors.grey),
                ),
              ),
              const SizedBox(width: 12),
              // User Info with Department
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      department,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatEventTime(lastUpdated),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Status Information without icons
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Check In',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.green.shade800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatShortTime(checkInTime),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Check Out',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue.shade800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatShortTime(checkOutTime),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChipWithMethod(
    String label,
    String time,
    String? method,
    Color textColor,
    Color backgroundColor,
  ) {
    IconData? methodIcon;
    final m = (method ?? '').toString().toLowerCase();
    if (method == 'manual') {
      methodIcon = Icons.edit;
    } else if (method == 'rfid') {
      methodIcon = Icons.nfc;
    } else if (m.contains('fingerprint')) {
      methodIcon = Icons.fingerprint;
    } else if (m.contains('face') || m.contains('wajah')) {
      methodIcon = Icons.face;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (methodIcon != null) ...[
                Icon(methodIcon, size: 10, color: textColor),
                const SizedBox(width: 3),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            time,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }

  IconData _getMethodIcon(dynamic method) {
    if (method == null) return Icons.help_outline;
    final m = method.toString().toLowerCase();
    if (m.contains('rfid')) return Icons.credit_card;
    if (m.contains('face') || m.contains('wajah')) return Icons.face;
    if (m.contains('selfie')) return Icons.camera_alt;
    if (m.contains('manual')) return Icons.edit_note;
    if (m.contains('fingerprint')) return Icons.fingerprint;
    return Icons.check_circle_outline;
  }

  String _formatMethodName(dynamic method) {
    if (method == null) return '-';
    final m = method.toString().toLowerCase();
    if (m.contains('rfid')) return 'RFID';
    if (m.contains('face') || m.contains('wajah')) return 'FACE';
    if (m.contains('selfie')) return 'SELFIE';
    if (m.contains('manual')) return 'MANUAL';
    if (m.contains('fingerprint')) return 'FINGER';
    return method.toString().toUpperCase();
  }
}
