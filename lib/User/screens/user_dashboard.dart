import 'package:absenmusam/attendance/screens/face_registration_page.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../../attendance/services/biometric_service.dart';
import '../../auth/services/role_service.dart';
import '../widgets/user_bottom_nav.dart';
import 'user_profile_page.dart';
import '../../auth/screens/join_organization_screen.dart';
import 'dart:async';
import 'package:absenmusam/Petugas/screens/petugas_dashboard.dart';
import '../../helpers/timezone_helper.dart';
import '../../Petugas/screens/selfie_attendance_flow_page.dart';
import '../../helpers/language_helper.dart';
import '../../services/timezone_service.dart';

class UserDashboardPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;
  final bool isDarkMode;

  const UserDashboardPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
    this.isDarkMode = false,
  });

  @override
  State<UserDashboardPage> createState() => _UserDashboardPageState();
}

class _UserDashboardPageState extends State<UserDashboardPage>
    with SingleTickerProviderStateMixin {
  final BiometricService _biometricService = BiometricService();
  final RoleService _roleService = RoleService();
  final _supabase = Supabase.instance.client;
  final TimezoneService _timezoneService = TimezoneService();

  bool _hasRegisteredFace = false;
  bool _isCheckingFace = false;
  bool _isLoadingAttendance = true;
  String? _errorMessage;
  Map<String, dynamic>? _userProfile;
  bool _isDarkMode = false;

  // Calendar & Daily Events
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  CalendarFormat _calendarFormat = CalendarFormat.month;
  Map<DateTime, List<Map<String, dynamic>>> _attendanceByDate = {};
  List<Map<String, dynamic>> _recentActivities = [];
  bool _isLoadingActivities = true;
  bool _isLoadingWeeklyData = true;
  double _totalWeeklyHours = 0.0;
  double _weeklyPercentageChange = 0.0;
  List<double> _dailyHours = [0.0, 0.0, 0.0, 0.0, 0.0];
  late TabController _tabController;

  // Real-time updates
  Timer? _clockTimer;
  String _organizationTimezone = 'Asia/Jakarta';
  String _userTimezone = 'Asia/Jakarta';
  Map<String, dynamic>? _organization;
  DateTime _nowUtc = DateTime.now().toUtc();
  DateTime? _currentOrgTime;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.isDarkMode;
    _userProfile = widget.userProfile;
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        setState(() {});
      }
    });
    _loadUserProfile();
    _checkFaceRegistration();
    _loadWeeklyOverview();
    _loadAttendanceData(_focusedDay);
    _loadRecentActivities();
    _loadOrganizationTimezone();
    _loadUserTimezone();
    _loadOrganizationInfo();
    _initRealTimeClock();
  }

  void _initRealTimeClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _nowUtc = DateTime.now().toUtc();
          final timezoneToUse = _userTimezone.isNotEmpty
              ? _userTimezone
              : _organizationTimezone;
          _currentOrgTime = TimezoneHelper.convertUtcToOrgTimezone(
            _nowUtc,
            timezoneToUse,
          );
        });
      }
    });
  }

  Future<void> _loadUserTimezone() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      final response = await _supabase
          .from('user_profiles')
          .select('timezone')
          .eq('id', userId)
          .maybeSingle();

      if (response != null && response['timezone'] != null) {
        setState(() {
          _userTimezone = response['timezone'];
        });
        debugPrint('User timezone loaded: $_userTimezone');
      } else {
        _userTimezone = _organizationTimezone;
      }
    } catch (e) {
      debugPrint('Error loading user timezone: $e');
      _userTimezone = _organizationTimezone;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _clockTimer?.cancel();
    super.dispose();
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
      debugPrint('Error loading organization info: $e');
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

  Future<void> _showOrganizationSwitcher() async {
    final selectedMembership = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _buildOrganizationSwitcherSheet(),
    );

    if (!mounted) return;
    if (selectedMembership == null) return;

    if (selectedMembership['id'] == widget.organizationMemberId) {
      debugPrint('Already on this organization dashboard');
      return;
    }

    final roleCode = _roleService.getRoleCode(selectedMembership);
    if (_roleService.isPetugas(selectedMembership) || roleCode == 'SA001') {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              PetugasDashboardPage(
            organizationMemberId: selectedMembership['id'] as int,
            memberData: selectedMembership,
            isDarkMode: _isDarkMode,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
        (route) => false,
      );
    } else {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              UserDashboardPage(
            organizationMemberId: selectedMembership['id'] as int,
            memberData: selectedMembership,
            isDarkMode: _isDarkMode,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
        (route) => false,
      );
    }
  }

  Widget _buildOrganizationSwitcherSheet() {
    return Container(
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
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
              color: Colors.grey.shade300,
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
                return const Center(child: CircularProgressIndicator());
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
                        onTap: () => Navigator.pop(context, membership),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isActive
                                ? (_isDarkMode
                                      ? const Color(0xFFD0BCFF).withOpacity(0.1)
                                      : const Color(
                                          0xFF4A1E79,
                                        ).withOpacity(0.05))
                                : (_isDarkMode
                                      ? Colors.white.withValues(alpha: 0.05)
                                      : Colors.white),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isActive
                                  ? (_isDarkMode
                                        ? const Color(0xFFD0BCFF)
                                        : const Color(0xFF4A1E79))
                                  : (_isDarkMode
                                        ? Colors.white10
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
                                      ? (_isDarkMode
                                            ? const Color(0xFFD0BCFF)
                                            : const Color(0xFF4A1E79))
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
                                      organization['name'] ?? 'Unknown Org',
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
                                        color: Colors.grey.shade500,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (isActive)
                                const Icon(
                                  Icons.check_circle,
                                  color: Color(0xFF4A1E79),
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
                        Navigator.pop(context);
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

  Future<void> _loadUserProfile() async {
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
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading user profile: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load profile: $e';
        });
      }
    }
  }

  // ========== EXTRACT PHOTO URL HELPER ==========
  String? _extractPhotoUrl(Map<String, dynamic> event) {
    if (event['photo_url'] != null &&
        event['photo_url'].toString().isNotEmpty) {
      return event['photo_url'];
    }
    if (event['checkInPhoto'] != null &&
        event['checkInPhoto'].toString().isNotEmpty) {
      return event['checkInPhoto'];
    }
    if (event['checkOutPhoto'] != null &&
        event['checkOutPhoto'].toString().isNotEmpty) {
      return event['checkOutPhoto'];
    }
    if (event['location'] is Map && event['location']['photo_url'] != null) {
      return event['location']['photo_url'];
    }
    return null;
  }

  Future<void> _loadRecentActivities() async {
    if (!mounted) return;
    setState(() => _isLoadingActivities = true);

    try {
      final response = await _supabase
          .from('attendance_logs')
          .select('''
            id,
            event_type,
            event_time,
            method,
            raw_data,
            location,
            attendance_records(
              status
            )
          ''')
          .eq('organization_member_id', widget.organizationMemberId)
          .order('event_time', ascending: false)
          .limit(20);

      if (mounted) {
        final groupedActivities = <String, Map<String, dynamic>>{};

        for (final log in response) {
          final eventTimeStr = log['event_time'] as String;
          final timezoneToUse = _userTimezone.isNotEmpty
              ? _userTimezone
              : _organizationTimezone;
          final eventTime = TimezoneHelper.parseAndConvert(
            eventTimeStr,
            timezoneToUse,
          );
          if (eventTime == null) continue;

          final dateKey = eventTime.toIso8601String().split('T').first;

          final recordsData = log['attendance_records'];
          final record = recordsData is List
              ? (recordsData.isNotEmpty
                    ? recordsData[0] as Map<String, dynamic>
                    : {})
              : (recordsData as Map<String, dynamic>? ?? {});

          final rawData = log['raw_data'] as Map<String, dynamic>? ?? {};

          Map<String, dynamic> parsedLocation = {};
          try {
            if (log['location'] is Map) {
              parsedLocation = log['location'] as Map<String, dynamic>;
            } else if (log['location'] is String) {
              final decoded = Uri.decodeFull(log['location']);
              if (decoded.startsWith('{')) {
                if (decoded.contains('"photo_url"')) {
                  final start = decoded.indexOf('"photo_url"') + 12;
                  final end = decoded.indexOf('"', start + 1);
                  if (start > 12 && end > start) {
                    parsedLocation['photo_url'] = decoded.substring(
                      start + 1,
                      end,
                    );
                  }
                }
              }
            }
          } catch (_) {}

          final entry = groupedActivities.putIfAbsent(dateKey, () {
            return {
              'date': dateKey,
              'checkInTime': null,
              'checkOutTime': null,
              'checkInMethod': null,
              'checkOutMethod': null,
              'checkInPhoto': null,
              'checkOutPhoto': null,
              'photo_url': null,
              'status': record['status'],
              'shiftName': rawData['work_time_mode']?.toString(),
              'lastUpdated': eventTime,
            };
          });

          final photoUrl = parsedLocation['photo_url']?.toString();

          if (log['event_type'] == 'check_in') {
            entry['checkInTime'] = eventTime;
            entry['checkInMethod'] = log['method'];
            entry['checkInPhoto'] = photoUrl;
            entry['photo_url'] = photoUrl;
          } else if (log['event_type'] == 'check_out') {
            entry['checkOutTime'] ??= eventTime;
            entry['checkOutMethod'] = log['method'];
            entry['checkOutPhoto'] = photoUrl;
            entry['photo_url'] = photoUrl;
          }

          if (eventTime.isAfter(entry['lastUpdated'] as DateTime)) {
            entry['lastUpdated'] = eventTime;
          }
        }

        final sortedActivities = groupedActivities.values.toList()
          ..sort(
            (a, b) => (b['lastUpdated'] as DateTime).compareTo(
              a['lastUpdated'] as DateTime,
            ),
          );

        setState(() {
          _recentActivities = sortedActivities.take(5).toList();
          _isLoadingActivities = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading recent activities: $e');
      if (mounted) {
        setState(() => _isLoadingActivities = false);
      }
    }
  }

  Future<void> _loadAttendanceData(DateTime focusedMonth) async {
    _loadUserProfile();
    setState(() {
      _isLoadingAttendance = true;
    });

    try {
      final firstDayOfMonth = DateTime(
        focusedMonth.year,
        focusedMonth.month,
        1,
      );
      final lastDayOfMonth = DateTime(
        focusedMonth.year,
        focusedMonth.month + 1,
        0,
      );

      final records = await _supabase
          .from('attendance_records')
          .select(
            'id, attendance_date, status, actual_check_in, actual_check_out, check_in_photo_url, check_in_location, check_in_method, check_out_photo_url, check_out_location, check_out_method, late_minutes, work_duration_minutes',
          )
          .eq('organization_member_id', widget.organizationMemberId)
          .gte(
            'attendance_date',
            firstDayOfMonth.toIso8601String().split('T')[0],
          )
          .lte(
            'attendance_date',
            lastDayOfMonth.toIso8601String().split('T')[0],
          )
          .order('attendance_date', ascending: false);

      if (mounted) {
        _processAttendanceRecords(records);
        setState(() {
          _isLoadingAttendance = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading attendance data: $e');
    } finally {
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _processAttendanceRecords(List<dynamic> records) {
    final Map<DateTime, List<Map<String, dynamic>>> groupedData = {};

    for (var record in records) {
      try {
        final attendanceDate = DateTime.parse(record['attendance_date']);
        final dateOnly = DateTime(
          attendanceDate.year,
          attendanceDate.month,
          attendanceDate.day,
        );

        groupedData[dateOnly] ??= [];

        if (record['actual_check_in'] != null) {
          groupedData[dateOnly]!.add({
            'type': 'check_in',
            'event_time': record['actual_check_in'],
            'photo_url': record['check_in_photo_url'],
            'location': record['check_in_location'],
            'method': record['check_in_method'],
            'status': record['status'],
            'late_minutes': record['late_minutes'],
          });
        }

        if (record['actual_check_out'] != null) {
          groupedData[dateOnly]!.add({
            'type': 'check_out',
            'event_time': record['actual_check_out'],
            'photo_url': record['check_out_photo_url'],
            'location': record['check_out_location'],
            'method': record['check_out_method'],
            'status': record['status'],
            'work_duration_minutes': record['work_duration_minutes'],
          });
        }
      } catch (e) {
        debugPrint('Error processing record: $e');
      }
    }

    for (final dateEvents in groupedData.values) {
      dateEvents.sort((a, b) {
        final timeA = DateTime.parse(a['event_time']);
        final timeB = DateTime.parse(b['event_time']);
        return timeA.compareTo(timeB);
      });
    }

    setState(() {
      _attendanceByDate = groupedData;
    });
  }

  Future<void> _loadWeeklyOverview() async {
    if (!mounted) return;

    setState(() {
      _isLoadingWeeklyData = true;
    });

    try {
      final now = DateTime.now();
      final currentWeekday = now.weekday;
      final monday = now.subtract(Duration(days: currentWeekday - 1));
      final mondayStr = monday.toIso8601String().split('T')[0];
      final friday = monday.add(const Duration(days: 4));
      final fridayStr = friday.toIso8601String().split('T')[0];
      final lastMonday = monday.subtract(const Duration(days: 7));
      final lastMondayStr = lastMonday.toIso8601String().split('T')[0];
      final lastFriday = lastMonday.add(const Duration(days: 4));
      final lastFridayStr = lastFriday.toIso8601String().split('T')[0];

      final currentWeekRecords = await _supabase
          .from('attendance_records')
          .select('attendance_date, work_duration_minutes')
          .eq('organization_member_id', widget.organizationMemberId)
          .gte('attendance_date', mondayStr)
          .lte('attendance_date', fridayStr);

      final lastWeekRecords = await _supabase
          .from('attendance_records')
          .select('work_duration_minutes')
          .eq('organization_member_id', widget.organizationMemberId)
          .gte('attendance_date', lastMondayStr)
          .lte('attendance_date', lastFridayStr);

      final dailyHoursMap = <int, double>{
        1: 0.0,
        2: 0.0,
        3: 0.0,
        4: 0.0,
        5: 0.0,
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

      double lastWeekMinutes = 0.0;
      for (final record in lastWeekRecords as List) {
        final minutes = record['work_duration_minutes'] as int?;
        if (minutes != null && minutes > 0) {
          lastWeekMinutes += minutes;
        }
      }

      double percentageChange = 0.0;
      if (lastWeekMinutes > 0) {
        percentageChange =
            ((totalMinutes - lastWeekMinutes) / lastWeekMinutes) * 100;
      } else if (totalMinutes > 0) {
        percentageChange = 100.0;
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
    } catch (e) {
      debugPrint('!!! ERROR loading weekly overview: $e');
      if (mounted) {
        setState(() {
          _isLoadingWeeklyData = false;
        });
      }
    }
  }

  Future<void> _checkFaceRegistration() async {
    setState(() {
      _isCheckingFace = true;
      _errorMessage = null;
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
          _errorMessage = 'Failed to check face: $e';
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

  void _navigateToProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserProfilePage(
          organizationMemberId: widget.organizationMemberId,
          memberData: widget.memberData,
          userProfile: _userProfile,
          isDarkMode: _isDarkMode,
        ),
      ),
    ).then((_) {
      _loadUserTimezone();
    });
  }

  Future<void> _handleSelfieAttendance() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SelfieAttendanceFlowPage(
          organizationId: organizationId,
          organizationName: _organization?['name'] ?? 'Organization',
          petugasData: widget.memberData,
          isSelfAttendance: true,
        ),
      ),
    );

    if (result != null && result['success'] == true) {
      await Future.wait([
        _loadAttendanceData(_focusedDay),
        _loadRecentActivities(),
      ]);
    }
  }

  String _getCurrentDate() {
    final timezoneToUse = _userTimezone.isNotEmpty
        ? _userTimezone
        : _organizationTimezone;
    final nowOrg = TimezoneHelper.convertUtcToOrgTimezone(
      _nowUtc,
      timezoneToUse,
    );
    return DateFormat(
      'EEEE, dd MMM yyyy',
      AppLanguage.currentLanguage == 'id' ? 'id_ID' : 'en_US',
    ).format(nowOrg);
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

  String? _getProfilePhotoUrl() {
    final profile = _userProfile ?? widget.userProfile;
    if (profile == null) return null;
    final photoPath = profile['profile_photo_url'] as String?;
    return _resolveProfilePhotoUrl(photoPath);
  }

  List<Map<String, dynamic>> _getEventsForDay(DateTime day) {
    final dateOnly = DateTime(day.year, day.month, day.day);
    return _attendanceByDate[dateOnly] ?? [];
  }

  List<Map<String, dynamic>> _getSelectedDayEvents() {
    final dateOnly = DateTime(
      _selectedDay.year,
      _selectedDay.month,
      _selectedDay.day,
    );
    return _attendanceByDate[dateOnly] ?? [];
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    if (!mounted) return;
    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = focusedDay;
    });
  }

  Color _getEventColor(String type) {
    switch (type) {
      case 'check_in':
        return const Color(0xFF10B981);
      case 'check_out':
        return const Color(0xFFEF4444);
      default:
        return Colors.grey;
    }
  }

  IconData _getEventIcon(String type) {
    switch (type) {
      case 'check_in':
        return Icons.login;
      case 'check_out':
        return Icons.logout;
      default:
        return Icons.event;
    }
  }

  String _getEventLabel(String type) {
    switch (type) {
      case 'check_in':
        return AppLanguage.tr('User.dashboard.check_in');
      case 'check_out':
        return AppLanguage.tr('User.dashboard.check_out');
      default:
        return type.replaceAll('_', ' ').toUpperCase();
    }
  }

  String _formatEventTime(DateTime? time) {
    if (time == null) return 'Unknown time';
    final timezoneToUse = _userTimezone.isNotEmpty
        ? _userTimezone
        : _organizationTimezone;
    final nowOrg = TimezoneHelper.convertUtcToOrgTimezone(
      _nowUtc,
      timezoneToUse,
    );
    final isToday =
        nowOrg.year == time.year &&
        nowOrg.month == time.month &&
        nowOrg.day == time.day;
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute';
    if (isToday) {
      return '${AppLanguage.tr('User.dashboard.today')} • $timeStr';
    }
    final dateStr = '${time.day}/${time.month}/${time.year}';
    return '$dateStr • $timeStr';
  }

  String _formatShortTime(DateTime? time) {
    if (time == null) return '--:--';
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  IconData _getMethodIcon(dynamic method) {
    final m = method?.toString().toLowerCase() ?? '';
    if (m.contains('face')) return Icons.face_rounded;
    if (m.contains('rfid')) return Icons.contactless_rounded;
    if (m.contains('selfie')) return Icons.camera_alt_rounded;
    return Icons.devices_rounded;
  }

  String _formatMethodName(dynamic method) {
    final m = method?.toString().split('_').last.toUpperCase() ?? 'AUTO';
    return m;
  }

  String _formatTime(String? dateTimeStr) {
    if (dateTimeStr == null) return '--:--';
    try {
      final timezoneToUse = _userTimezone.isNotEmpty
          ? _userTimezone
          : _organizationTimezone;
      final convertedTime = TimezoneHelper.parseAndConvert(
        dateTimeStr,
        timezoneToUse,
      );
      if (convertedTime == null) return '--:--';
      return DateFormat('HH:mm').format(convertedTime);
    } catch (e) {
      return '--:--';
    }
  }

  Future<void> _showEventDetails(Map<String, dynamic> event) async {
    if (!mounted) return;

    final photoUrl = _extractPhotoUrl(event);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        final eventTime = DateTime.parse(event['event_time']);
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.9,
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            child: SingleChildScrollView(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _isDarkMode ? Colors.white10 : Colors.transparent,
                    width: 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _getEventColor(
                              event['type'],
                            ).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            _getEventIcon(event['type']),
                            color: _getEventColor(event['type']),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _getEventLabel(event['type']),
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: _isDarkMode
                                  ? Colors.white
                                  : Colors.black87,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(
                            Icons.close,
                            color: _isDarkMode
                                ? Colors.white70
                                : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    if (photoUrl != null && photoUrl.isNotEmpty) ...[
                      GestureDetector(
                        onTap: () => _showFullImage(context, photoUrl),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: CachedNetworkImage(
                            imageUrl: photoUrl,
                            width: double.infinity,
                            height: 220,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Container(
                              width: double.infinity,
                              height: 220,
                              color: _isDarkMode
                                  ? Colors.white.withOpacity(0.05)
                                  : Colors.grey[200],
                              child: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            ),
                            errorWidget: (context, url, error) => Container(
                              width: double.infinity,
                              height: 220,
                              color: _isDarkMode
                                  ? Colors.white.withOpacity(0.05)
                                  : Colors.grey[200],
                              child: Icon(
                                Icons.error_outline,
                                color: _isDarkMode
                                    ? Colors.white54
                                    : Colors.grey.shade400,
                                size: 40,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _isDarkMode
                            ? Colors.white.withOpacity(0.03)
                            : const Color(0xFF4A1E79).withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _isDarkMode
                              ? Colors.white10
                              : const Color(0xFF4A1E79).withOpacity(0.1),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          _buildDetailRow(
                            Icons.calendar_today,
                            AppLanguage.tr('User.dashboard.detail_date'),
                            DateFormat('EEEE, d MMM yyyy').format(eventTime),
                          ),
                          _buildDetailRow(
                            Icons.access_time,
                            AppLanguage.tr('User.dashboard.detail_time'),
                            DateFormat('HH:mm:ss').format(eventTime),
                          ),
                          if (event['late_minutes'] != null &&
                              event['late_minutes'] > 0)
                            _buildDetailRow(
                              Icons.schedule,
                              AppLanguage.tr('User.dashboard.detail_late'),
                              '${event['late_minutes']} ${AppLanguage.tr('User.dashboard.detail_minutes')}',
                            ),
                          if (event['work_duration_minutes'] != null)
                            _buildDetailRow(
                              Icons.work,
                              AppLanguage.tr(
                                'User.dashboard.detail_work_duration',
                              ),
                              '${(event['work_duration_minutes'] / 60).toStringAsFixed(1)} ${AppLanguage.tr('User.dashboard.detail_hours')}',
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
    );
  }

  void _showFullImage(BuildContext context, String photoUrl) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black87,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: CachedNetworkImage(
                  imageUrl: photoUrl,
                  fit: BoxFit.contain,
                  placeholder: (context, url) =>
                      const CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                  errorWidget: (context, error, stackTrace) {
                    return const Center(
                      child: Icon(Icons.error, color: Colors.white, size: 50),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                style: IconButton.styleFrom(backgroundColor: Colors.black45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF4A1E79)),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 13, color: Colors.black87),
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: value),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayTime = _currentOrgTime ?? DateTime.now();
    final hourFormat = displayTime.hour.toString().padLeft(2, '0');
    final minuteFormat = displayTime.minute.toString().padLeft(2, '0');
    final currentTime = '$hourFormat:$minuteFormat';
    final isAmPm = displayTime.hour < 12;

    return Scaffold(
      backgroundColor: _isDarkMode
          ? const Color(0xFF1F0B38)
          : const Color(0xFFF5F5F5),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            _loadUserProfile(),
            _loadUserTimezone(),
            _checkFaceRegistration(),
            _loadWeeklyOverview(),
            _loadAttendanceData(_focusedDay),
            _loadRecentActivities(),
          ]);
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // HEADER SECTION
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
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Transform.translate(
                            offset: const Offset(-16, -16),
                            child: Image.asset(
                              'assets/logo/app_logo.png',
                              width: 180,
                              height: 180,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                          Transform.translate(
                            offset: const Offset(0, -16),
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
                    Transform.translate(
                      offset: const Offset(0, -60),
                      child: Column(
                        children: [
                          GestureDetector(
                            onTap: _navigateToProfile,
                            child: Container(
                              width: 110,
                              height: 110,
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
                              child: ClipOval(
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
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: _navigateToProfile,
                            child: Text(
                              _getFullName(),
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _showOrganizationSwitcher,
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
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
                                  children: [
                                    Flexible(
                                      child: Text(
                                        '${_roleService.getRoleName(widget.memberData)}${_organization != null ? ' - ${_organization!['name']}' : ''}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
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
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
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
              // CONTENT AREA
              Container(
                width: double.infinity,
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
                    Transform.translate(
                      offset: const Offset(0, -80),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: _isDarkMode
                                ? const Color(0xFF2D1B4E)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.1),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          AppLanguage.tr(
                                            'User.dashboard.current_time',
                                          ),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _isDarkMode
                                                ? Colors.white70
                                                : Colors.grey.shade600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '$currentTime ${isAmPm ? AppLanguage.tr('am') : AppLanguage.tr('pm')}',
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          AppLanguage.tr(
                                            'User.dashboard.office_location',
                                          ),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _isDarkMode
                                                ? Colors.white70
                                                : Colors.grey.shade600,
                                          ),
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
                                                    AppLanguage.tr('office'),
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: _isDarkMode
                                                      ? const Color(0xFFD0BCFF)
                                                      : Colors.black87,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Transform.translate(
                      offset: const Offset(0, -70),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          children: [
                            if (_isCheckingFace)
                              const Center(child: CircularProgressIndicator())
                            else if (!_hasRegisteredFace)
                              _buildFaceRegistrationCard()
                            else
                              _buildMainContent(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: CustomBottomNav(
        currentIndex: 0,
        isDarkMode: _isDarkMode,
        attendanceMode: 'selfie',
        onAttendanceTap: _handleSelfieAttendance,
        onTap: (index) {
          if (index == 1) {
            _navigateToProfile();
          }
        },
      ),
    );
  }

  Widget _buildFaceRegistrationCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_isDarkMode ? 0.2 : 0.04),
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
                        color: _isDarkMode
                            ? Colors.white
                            : const Color(0xFF1F2937),
                      ),
                    ),
                    Text(
                      AppLanguage.tr('User.dashboard.face_register_prompt'),
                      style: TextStyle(
                        fontSize: 13,
                        color: _isDarkMode
                            ? Colors.white70
                            : Colors.grey.shade500,
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
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  AppLanguage.tr('missing'),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
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
                AppLanguage.tr('User.profile.register'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF8938DF),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: _isDarkMode ? 0.2 : 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: TabBar(
            controller: _tabController,
            labelColor: _isDarkMode
                ? const Color(0xFFD0BCFF)
                : const Color(0xFF4A1E79),
            unselectedLabelColor: _isDarkMode ? Colors.white38 : Colors.grey,
            indicatorColor: _isDarkMode
                ? const Color(0xFFD0BCFF)
                : const Color(0xFF4A1E79),
            indicatorWeight: 3,
            labelStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            tabs: [
              Tab(text: AppLanguage.tr('User.dashboard.statistics')),
              Tab(text: AppLanguage.tr('User.dashboard.calendar')),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _tabController.index == 0 ? _buildStatisticsTab() : _buildCalendarTab(),
      ],
    );
  }

  Widget _buildStatisticsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    AppLanguage.tr('User.dashboard.weekly_overview'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: _isDarkMode ? Colors.white : Colors.black87,
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
                              .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      AppLanguage.tr('User.dashboard.this_week'),
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
                  color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
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
                              : _totalWeeklyHours.toStringAsFixed(1),
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            color: _isDarkMode ? Colors.white : Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            AppLanguage.tr('User.dashboard.hrs'),
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
                          padding: const EdgeInsets.only(bottom: 6),
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
                                AppLanguage.tr('User.dashboard.hours'),
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
                            '${_weeklyPercentageChange >= 0 ? '+' : ''}${_weeklyPercentageChange.toStringAsFixed(1)}% ${AppLanguage.tr('User.dashboard.from_last_week')}',
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
                    if (!_isLoadingWeeklyData)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _buildBarChart(
                            AppLanguage.currentLanguage == 'id' ? 'SEN' : 'MON',
                            _dailyHours[0],
                            0,
                          ),
                          _buildBarChart(
                            AppLanguage.currentLanguage == 'id' ? 'SEL' : 'TUE',
                            _dailyHours[1],
                            1,
                          ),
                          _buildBarChart(
                            AppLanguage.currentLanguage == 'id' ? 'RAB' : 'WED',
                            _dailyHours[2],
                            2,
                          ),
                          _buildBarChart(
                            AppLanguage.currentLanguage == 'id' ? 'KAM' : 'THU',
                            _dailyHours[3],
                            3,
                          ),
                          _buildBarChart(
                            AppLanguage.currentLanguage == 'id' ? 'JUM' : 'FRI',
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
        const SizedBox(height: 8),
        _buildRecentActivitySection(),
      ],
    );
  }

  Widget _buildRecentActivitySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppLanguage.tr('User.dashboard.recent_activity'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
              if (_recentActivities.isNotEmpty)
                TextButton(
                  onPressed: () => _tabController.animateTo(1),
                  child: Text(
                    AppLanguage.tr('User.dashboard.view_all'),
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
        ),
        const SizedBox(height: 12),
        if (_isLoadingActivities)
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
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
              color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    Icons.history,
                    size: 48,
                    color: _isDarkMode ? Colors.white24 : Colors.grey.shade300,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppLanguage.tr('User.dashboard.no_recent_activity'),
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
                .map((activity) => _buildModernActivityItem(activity))
                .toList(),
          ),
      ],
    );
  }

  // ========== RECENT ACTIVITY ITEM WITH PHOTO ==========
  Widget _buildModernActivityItem(Map<String, dynamic> activity) {
    final checkInTime = activity['checkInTime'] as DateTime?;
    final checkOutTime = activity['checkOutTime'] as DateTime?;
    final lastUpdated = activity['lastUpdated'] as DateTime?;
    final status = activity['status']?.toString().toUpperCase();
    final shiftName = activity['shiftName']?.toString().toUpperCase();
    final photoUrl = _extractPhotoUrl(activity);

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
                : Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // PHOTO SECTION
          if (photoUrl != null && photoUrl.isNotEmpty)
            GestureDetector(
              onTap: () => _showFullImage(context, photoUrl),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedNetworkImage(
                  imageUrl: photoUrl,
                  width: 60,
                  height: 60,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Container(
                    width: 60,
                    height: 60,
                    color: Colors.grey.shade200,
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  errorWidget: (context, url, error) => Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: _isDarkMode
                          ? Colors.white10
                          : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.camera_alt,
                      size: 30,
                      color: _isDarkMode
                          ? Colors.white38
                          : Colors.grey.shade400,
                    ),
                  ),
                ),
              ),
            ),
          if (photoUrl != null && photoUrl.isNotEmpty)
            const SizedBox(width: 12),
          // CONTENT COLUMN
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (checkInTime != null)
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _isDarkMode
                              ? Colors.white10
                              : Colors.green.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.login,
                          color: _isDarkMode
                              ? Colors.green
                              : Colors.green.shade600,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppLanguage.tr('User.dashboard.check_in'),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: _isDarkMode
                                    ? Colors.white
                                    : Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              lastUpdated != null
                                  ? _formatEventTime(lastUpdated)
                                  : AppLanguage.tr('User.dashboard.today'),
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
                              color: _isDarkMode
                                  ? Colors.white
                                  : Colors.black87,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (activity['checkInMethod'] != null)
                                Container(
                                  margin: const EdgeInsets.only(
                                    top: 4,
                                    right: 4,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _isDarkMode
                                        ? Colors.white10
                                        : Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: _isDarkMode
                                          ? Colors.white12
                                          : Colors.grey.shade300,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _getMethodIcon(
                                          activity['checkInMethod'],
                                        ),
                                        size: 10,
                                        color: _isDarkMode
                                            ? Colors.white70
                                            : Colors.grey.shade700,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _formatMethodName(
                                          activity['checkInMethod'],
                                        ),
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                          color: _isDarkMode
                                              ? Colors.white70
                                              : Colors.grey.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (status != null)
                                Container(
                                  margin: const EdgeInsets.only(top: 4),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        (status.contains('LATE')
                                                ? Colors.orange
                                                : Colors.green)
                                            .withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    status,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: status.contains('LATE')
                                          ? Colors.orange.shade700
                                          : Colors.green.shade700,
                                    ),
                                  ),
                                ),
                            ],
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
                      color: _isDarkMode
                          ? Colors.white24
                          : Colors.grey.shade200,
                    ),
                  ),
                if (checkOutTime != null)
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _isDarkMode
                              ? Colors.white10
                              : Colors.red.shade50,
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
                              AppLanguage.tr('User.dashboard.check_out'),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: _isDarkMode
                                    ? Colors.white
                                    : Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              lastUpdated != null
                                  ? _formatEventTime(lastUpdated)
                                  : AppLanguage.tr('User.dashboard.today'),
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
                              color: _isDarkMode
                                  ? Colors.white
                                  : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (activity['checkOutMethod'] != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  margin: const EdgeInsets.only(right: 4),
                                  decoration: BoxDecoration(
                                    color: _isDarkMode
                                        ? Colors.white10
                                        : Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: _isDarkMode
                                          ? Colors.white12
                                          : Colors.grey.shade300,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _getMethodIcon(
                                          activity['checkOutMethod'],
                                        ),
                                        size: 10,
                                        color: _isDarkMode
                                            ? Colors.white70
                                            : Colors.grey.shade700,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _formatMethodName(
                                          activity['checkOutMethod'],
                                        ),
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                          color: _isDarkMode
                                              ? Colors.white70
                                              : Colors.grey.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (shiftName != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _isDarkMode
                                        ? Colors.white10
                                        : const Color(
                                            0xFF4A1E79,
                                          ).withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: const Color(
                                        0xFF4A1E79,
                                      ).withOpacity(0.1),
                                    ),
                                  ),
                                  child: Text(
                                    shiftName,
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      color: _isDarkMode
                                          ? Colors.white70
                                          : const Color(0xFF4A1E79),
                                    ),
                                  ),
                                ),
                            ],
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
    );
  }

  Widget _buildBarChart(String day, double hours, int dayIndex) {
    final maxHours = _dailyHours.isEmpty
        ? 0.0
        : _dailyHours.reduce((a, b) => a > b ? a : b);
    double normalizedHeight = 0.2;
    if (maxHours > 0 && hours > 0) {
      normalizedHeight = (hours / maxHours).clamp(0.2, 1.0);
    }
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
                          .withValues(alpha: _isDarkMode ? 0.25 : 0.15),
                      (_isDarkMode
                              ? const Color(0xFFD0BCFF)
                              : const Color(0xFF4A1E79))
                          .withValues(alpha: _isDarkMode ? 0.25 : 0.15),
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

  Widget _buildCalendarTab() {
    return Column(
      children: [
        _buildCalendarSection(),
        const SizedBox(height: 16),
        _buildDailyEvents(),
      ],
    );
  }

  Widget _buildCalendarSection() {
    return Container(
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _isDarkMode ? 0.2 : 0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          TableCalendar<Map<String, dynamic>>(
            locale: AppLanguage.currentLanguage == 'id' ? 'id_ID' : 'en_US',
            firstDay: DateTime.utc(2023, 1, 1),
            lastDay: DateTime.utc(2100, 12, 31),
            focusedDay: _focusedDay,
            calendarFormat: _calendarFormat,
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: _onDaySelected,
            onFormatChanged: (format) {
              if (_calendarFormat != format) {
                setState(() {
                  _calendarFormat = format;
                });
              }
            },
            onPageChanged: (focusedDay) {
              _focusedDay = focusedDay;
              _loadAttendanceData(focusedDay);
            },
            eventLoader: _getEventsForDay,
            calendarStyle: CalendarStyle(
              outsideDaysVisible: false,
              cellMargin: const EdgeInsets.all(6),
              defaultTextStyle: TextStyle(
                fontSize: 14,
                color: _isDarkMode ? Colors.white70 : Colors.black87,
              ),
              weekendTextStyle: const TextStyle(
                fontSize: 14,
                color: Colors.red,
              ),
              selectedDecoration: BoxDecoration(
                color: const Color(0xFF4A1E79),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF4A1E79).withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              selectedTextStyle: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
              todayDecoration: BoxDecoration(
                color: const Color(0xFF4A1E79).withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              todayTextStyle: const TextStyle(
                color: Color(0xFF4A1E79),
                fontWeight: FontWeight.bold,
              ),
              markersMaxCount: 1,
              markerDecoration: const BoxDecoration(
                color: Color(0xFFF59E0B),
                shape: BoxShape.circle,
              ),
              markerSize: 6,
            ),
            headerStyle: HeaderStyle(
              formatButtonVisible: false,
              titleCentered: true,
              titleTextStyle: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: _isDarkMode ? Colors.white : Colors.black87,
              ),
              leftChevronIcon: Icon(
                Icons.chevron_left,
                color: _isDarkMode ? Colors.white70 : Colors.grey,
              ),
              rightChevronIcon: Icon(
                Icons.chevron_right,
                color: _isDarkMode ? Colors.white70 : Colors.grey,
              ),
            ),
            daysOfWeekStyle: DaysOfWeekStyle(
              weekdayStyle: TextStyle(
                color: _isDarkMode ? Colors.white54 : Colors.grey.shade600,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
              weekendStyle: TextStyle(
                color: _isDarkMode ? Colors.white54 : Colors.grey.shade600,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildDailyEvents() {
    final events = _getSelectedDayEvents();

    if (events.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
        decoration: BoxDecoration(
          color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _isDarkMode ? 0.2 : 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_busy, color: Colors.grey.shade300, size: 48),
              const SizedBox(height: 12),
              Text(
                AppLanguage.tr('User.dashboard.no_attendance_data'),
                style: TextStyle(
                  color: _isDarkMode ? Colors.white60 : Colors.grey.shade600,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                DateFormat('dd MMM yyyy').format(_selectedDay),
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(
              0xFF6C63FF,
            ).withValues(alpha: _isDarkMode ? 0.2 : 0.08),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(
                0xFF6C63FF,
              ).withValues(alpha: _isDarkMode ? 0.15 : 0.05),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.event_note,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLanguage.tr('User.dashboard.daily_events'),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: _isDarkMode ? Colors.white : Colors.black87,
                        ),
                      ),
                      Text(
                        DateFormat('EEE, dd MMM yyyy').format(_selectedDay),
                        style: TextStyle(
                          fontSize: 12,
                          color: _isDarkMode
                              ? Colors.white38
                              : Colors.grey.shade600,
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
                    color: const Color(0xFF6C63FF),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${events.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: events.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                return _buildEventListItem(events[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventListItem(Map<String, dynamic> event) {
    final eventColor = _getEventColor(event['type']);
    final photoUrl = _extractPhotoUrl(event);

    return Container(
      decoration: BoxDecoration(
        color: _isDarkMode
            ? const Color(0xFF1F0B38).withValues(alpha: 0.3)
            : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: eventColor.withValues(alpha: _isDarkMode ? 0.4 : 0.2),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showEventDetails(event),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [eventColor.withOpacity(0.8), eventColor],
                    ),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: eventColor.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: _buildEventLeadingWidget(event, Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getEventLabel(event['type']),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: _isDarkMode ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.access_time,
                            size: 12,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatTime(event['event_time']),
                            style: TextStyle(
                              fontSize: 12,
                              color: _isDarkMode
                                  ? Colors.white70
                                  : Colors.grey.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _buildEventStatusRow(event),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: Colors.grey.shade400,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEventLeadingWidget(Map<String, dynamic> event, Color iconColor) {
    final photoUrl = _extractPhotoUrl(event);

    if (photoUrl != null && photoUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CachedNetworkImage(
          imageUrl: photoUrl,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          placeholder: (context, url) =>
              Icon(_getEventIcon(event['type']), color: iconColor, size: 22),
          errorWidget: (context, url, error) =>
              Icon(_getEventIcon(event['type']), color: iconColor, size: 22),
        ),
      );
    }

    return Icon(_getEventIcon(event['type']), color: iconColor, size: 22);
  }

  Widget _buildEventStatusRow(Map<String, dynamic> event) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        if (event['status'] != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _getStatusColor(event['status']).withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _getStatusColor(event['status']).withOpacity(0.5),
                width: 1,
              ),
            ),
            child: Text(
              event['status'].toString().toUpperCase(),
              style: TextStyle(
                fontSize: 9,
                color: _getStatusColor(event['status']),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        if (event['late_minutes'] != null && event['late_minutes'] > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Colors.orange.withOpacity(0.5),
                width: 1,
              ),
            ),
            child: Text(
              '+${event['late_minutes']}m',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Colors.orange,
              ),
            ),
          ),
      ],
    );
  }

  Color _getStatusColor(String? status) {
    if (status == null) return Colors.grey;
    switch (status.toLowerCase()) {
      case 'present':
        return const Color(0xFF10B981);
      case 'absent':
        return const Color(0xFFEF4444);
      case 'late':
        return const Color(0xFFF59E0B);
      default:
        return Colors.grey;
    }
  }
}
