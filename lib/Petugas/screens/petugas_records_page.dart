// Part 1: Imports and Class Definition
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../attendance/services/attendance_service.dart';
import '../../helpers/timezone_helper.dart';
import '../../auth/services/role_service.dart';
import '../../helpers/rfid_mode_helper.dart';
import '../widgets/petugas_bottom_nav.dart';
import 'petugas_dashboard.dart';
import 'petugas_members_page.dart';
import 'petugas_profile_page.dart';
import '../../helpers/language_helper.dart';
import '../widgets/sync_status_dialog.dart';

class PetugasRecordsPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;
  final bool isDarkMode;

  const PetugasRecordsPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
    this.isDarkMode = false,
  });

  @override
  State<PetugasRecordsPage> createState() => _PetugasRecordsPageState();
}

class _PetugasRecordsPageState extends State<PetugasRecordsPage> {
  static const Color primaryColor = Color(
    0xFF4A1E79,
  ); // Updated to match Members Page
  static const Color primaryDark = Color(0xFF3B1860);
  static const Color successColor = Color(0xFF10B981);
  static const Color warningColor = Color(0xFFF59E0B);
  static const Color errorColor = Color(0xFFEF4444);
  static const Color backgroundColor = Color(0xFFF8F9FA); // Updated light bg

  final AttendanceService _attendanceService = AttendanceService();
  final RoleService _roleService = RoleService();
  final supabase = Supabase.instance.client;

  bool _isLoading = true;
  bool _isInitialized = false;
  String? _errorMessage;
  int _currentNavIndex = 2;
  String _attendanceMode = 'face';

  Map<String, dynamic>? _organization;
  Map<String, dynamic>? _userProfile;
  String _organizationTimezone = 'Asia/Jakarta';

  List<Map<String, dynamic>> _allAttendanceRecords = [];
  List<Map<String, dynamic>> _filteredRecords = [];
  Map<int, String> _deviceLocations = {};
  final Map<int, dynamic> _memberProfiles = {}; // Changed key type to int

  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  CalendarFormat _calendarFormat = CalendarFormat.month;
  late int _selectedMonth;
  late int _selectedYear;

  List<Map<String, dynamic>> _organizationMembers = [];
  String _searchQuery = '';

  bool _showCalendarView = true; // New state for view toggle

  @override
  void initState() {
    super.initState();

    final now = DateTime.now();
    _selectedMonth = now.month;
    _selectedYear = now.year;
    _selectedDay = now;
    _focusedDay = now;
    _userProfile = widget.userProfile;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeData();
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  // Initialize all data
  Future<void> _initializeData() async {
    if (!mounted || _isInitialized) return;

    try {
      // Load attendance mode
      final organizationId = widget.memberData['organization_id'] as int?;
      if (organizationId != null) {
        _attendanceMode = await RfidModeHelper.getAttendanceMode(
          organizationId,
        );
      }

      await _loadOrganizationData();

      // After loading org data, we have the timezone. Update Today.
      final nowOrg = TimezoneHelper.getCurrentTimeInOrgTimezone(
        _organizationTimezone,
      );
      if (mounted) {
        setState(() {
          _selectedMonth = nowOrg.month;
          _selectedYear = nowOrg.year;
          _selectedDay = nowOrg;
          _focusedDay = nowOrg;
        });
      }

      await _loadOrganizationMembers();
      await _loadDeviceLocations();
      await _loadAttendanceRecords();

      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error initializing data: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isInitialized = true;
          _errorMessage = 'Failed to initialize: $e';
        });
      }
    }
  }

  // Load organization data
  Future<void> _loadOrganizationData() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final org = await supabase
          .from('organizations')
          .select('id, name, logo_url, timezone')
          .eq('id', organizationId)
          .single();

      if (mounted) {
        setState(() {
          _organization = org;
          if (org['timezone'] != null) {
            _organizationTimezone = org['timezone'];
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading organization data: $e');
    }
  }

  // Load all organization members - simplified since we get this from attendance_records join
  Future<void> _loadOrganizationMembers() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final response = await supabase
          .from('organization_members')
          .select(
            'id, employee_id, user_profiles(display_name, first_name, last_name, profile_photo_url)',
          )
          .eq('organization_id', organizationId);

      if (mounted) {
        setState(() {
          _organizationMembers = List<Map<String, dynamic>>.from(response);
          // Create a lookup map for profiles
          for (var member in _organizationMembers) {
            if (member['user_profiles'] != null) {
              _memberProfiles[member['id']] = member['user_profiles'];
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading members: $e');
    }
  }

  // Load device locations - simplified to just use device IDs from records
  Future<void> _loadDeviceLocations() async {
    // Device names will be shown as "Device #ID" since we don't have a separate devices table
    // This is called but doesn't need to query anything
    if (mounted) {
      setState(() {
        _deviceLocations =
            {}; // Empty map, will use fallback in _getDeviceLocationName
      });
    }
  }
  // Part 2: Data Loading and Filtering Methods

  // Load attendance records for all members
  Future<void> _loadAttendanceRecords() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      // Calculate start and end dates for the selected month
      final startDate = DateTime(_selectedYear, _selectedMonth, 1);
      // For end date, go to next month day 0 (which is last day of current month)
      final endDate = DateTime(
        _selectedYear,
        _selectedMonth + 1,
        0,
        23,
        59,
        59,
      );

      final formattedStartDate = DateFormat('yyyy-MM-dd').format(startDate);
      final formattedEndDate = DateFormat('yyyy-MM-dd').format(endDate);

      // Query records with user profiles
      final response = await supabase
          .from('attendance_records')
          .select('''
            *,
            organization_members!inner (
              organization_id,
              user_profiles (
                display_name,
                first_name,
                last_name,
                profile_photo_url
              )
            )
          ''')
          .eq('organization_members.organization_id', organizationId)
          .gte('attendance_date', formattedStartDate)
          .lte('attendance_date', formattedEndDate)
          .order('attendance_date', ascending: false)
          .order('actual_check_in', ascending: false);

      if (mounted) {
        setState(() {
          _allAttendanceRecords = List<Map<String, dynamic>>.from(response);
          _applyFilters();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading records: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load records';
        });
      }
    }
  }

  // Apply filters to attendance records
  void _applyFilters() {
    List<Map<String, dynamic>> filtered = List.from(_allAttendanceRecords);

    // Filter by search query if exists
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((record) {
        final memberName = _getMemberName(record).toLowerCase();
        return memberName.contains(query);
      }).toList();
    }

    setState(() {
      _filteredRecords = filtered;
    });
  }

  // Helper methods for getting member information
  String? _getDeviceLocationName(int? deviceId) {
    if (deviceId == null) return 'Unknown Location';
    return _deviceLocations[deviceId] ?? 'Unknown Device';
  }

  String _getMemberName(Map<String, dynamic> record) {
    // Try to get from joined organization_members.user_profiles
    final orgMember = record['organization_members'];
    if (orgMember != null && orgMember is Map<String, dynamic>) {
      final profile = orgMember['user_profiles'];
      if (profile != null && profile is Map<String, dynamic>) {
        final displayName = profile['display_name'] as String?;
        if (displayName != null && displayName.isNotEmpty) {
          return displayName;
        }
        final firstName = profile['first_name'] as String? ?? '';
        final lastName = profile['last_name'] as String? ?? '';
        final fullName = '$firstName $lastName'.trim();
        if (fullName.isNotEmpty) {
          return fullName;
        }
      }
    }

    // Fallback to old lookup method
    final memberId = record['organization_member_id'];
    if (_memberProfiles.containsKey(memberId)) {
      final profile = _memberProfiles[memberId];
      return profile['display_name'] ??
          '${profile['first_name'] ?? ''} ${profile['last_name'] ?? ''}'.trim();
    }

    // Default fallback
    return 'Unknown Member';
  }

  String _getEmployeeId(Map<String, dynamic> record) {
    final memberId = record['organization_member_id'];

    // Find member in listing
    final member = _organizationMembers.firstWhere(
      (m) => m['id'] == memberId,
      orElse: () => {},
    );

    return member['employee_id'] ?? '';
  }

  String? _getMemberPhotoUrl(Map<String, dynamic> record) {
    String? photoPath;

    // Try to get from joined organization_members.user_profiles
    final orgMember = record['organization_members'];
    if (orgMember != null && orgMember is Map<String, dynamic>) {
      final profile = orgMember['user_profiles'];
      if (profile != null && profile is Map<String, dynamic>) {
        photoPath = profile['profile_photo_url'] as String?;
      }
    }

    // Fallback to old lookup method if joined data is missing
    if (photoPath == null) {
      final memberId = record['organization_member_id'];
      if (_memberProfiles.containsKey(memberId)) {
        photoPath =
            _memberProfiles[memberId]['profile_photo_url'] ??
            _memberProfiles[memberId]['photo_url'];
      }
    }

    if (photoPath == null || photoPath.trim().isEmpty) return null;

    // If it's a full URL, return it
    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      return photoPath;
    }

    // Otherwise, construct Supabase storage URL matching PetugasMembersPage logic
    return supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  Future<void> refreshData() async {
    await _loadAttendanceRecords();
  }

  void _handleNavigation(int index) {
    setState(() {
      _currentNavIndex = index;
    });

    switch (index) {
      case 0:
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => PetugasDashboardPage(
              organizationMemberId: widget.organizationMemberId,
              memberData: widget.memberData,
              userProfile: widget.userProfile,
              isDarkMode: widget.isDarkMode,
            ),
            transitionDuration: Duration.zero,
          ),
        );
        break;
      case 1:
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, __, ___) => Container(
              color: widget.isDarkMode
                  ? const Color(0xFF1F0B38)
                  : const Color(0xFFF8F9FA),
              child: PetugasMembersPage(
                organizationMemberId: widget.organizationMemberId,
                memberData: widget.memberData,
                userProfile: widget.userProfile,
                isDarkMode: widget.isDarkMode,
              ),
            ),
          ),
        );
        break;
      case 2:
        // Already on records page
        break;
      case 3:
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, __, ___) => Container(
              color: widget.isDarkMode
                  ? const Color(0xFF1F0B38)
                  : const Color(0xFFF8F9FA),
              child: PetugasProfilePage(
                organizationMemberId: widget.organizationMemberId,
                memberData: widget.memberData,
                userProfile: widget.userProfile,
                isDarkMode: widget.isDarkMode,
              ),
            ),
          ),
        );
        break;
    }
  }

  // Calendar event methods
  List<Map<String, dynamic>> _getEventsForDay(DateTime day) {
    final dateStr = DateFormat('yyyy-MM-dd').format(day);
    return _filteredRecords.where((record) {
      final recDate = record['attendance_date'] as String? ?? '';
      return recDate == dateStr;
    }).toList();
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    if (!mounted) return;
    if (!isSameDay(_selectedDay, selectedDay)) {
      setState(() {
        _selectedDay = selectedDay;
        _focusedDay = focusedDay;
      });
    }
  }

  String _getMonthName(int month) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return months[month - 1];
  }

  String _formatTime(String? timeStr) {
    if (timeStr == null) return '--:--';
    try {
      final parts = timeStr.split(':');
      if (parts.length >= 2) {
        return '${parts[0]}:${parts[1]}';
      }
      return timeStr;
    } catch (e) {
      return timeStr;
    }
  }

  String _formatDateTime(String? dateTimeString) {
    if (dateTimeString == null) return '--';

    try {
      final orgTime = TimezoneHelper.parseAndConvert(
        dateTimeString,
        _organizationTimezone,
      );
      if (orgTime == null) return '--';
      return DateFormat('HH:mm:ss').format(orgTime);
    } catch (e) {
      debugPrint('Error formatting datetime: $e');
      return '--';
    }
  }

  String _formatFullDateTime(String? dateTimeString) {
    if (dateTimeString == null) return '--';

    try {
      final orgTime = TimezoneHelper.parseAndConvert(
        dateTimeString,
        _organizationTimezone,
      );
      if (orgTime == null) return '--';
      return DateFormat('dd MMM yyyy, HH:mm:ss').format(orgTime);
    } catch (e) {
      debugPrint('Error formatting full datetime: $e');
      return '--';
    }
  }

  String _getTimezoneDisplay() {
    if (_organizationTimezone.toLowerCase().contains('jakarta') ||
        _organizationTimezone.toLowerCase() == 'wib') {
      return 'WIB (GMT+7)';
    } else if (_organizationTimezone.toLowerCase().contains('makassar') ||
        _organizationTimezone.toLowerCase() == 'wita') {
      return 'WITA (GMT+8)';
    } else if (_organizationTimezone.toLowerCase().contains('jayapura') ||
        _organizationTimezone.toLowerCase() == 'wit') {
      return 'WIT (GMT+9)';
    } else if (_organizationTimezone.toLowerCase() == 'utc') {
      return 'UTC (GMT+0)';
    }
    return _organizationTimezone;
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'present':
        return successColor;
      case 'absent':
        return errorColor;
      case 'late':
        return warningColor;
      default:
        return Colors.grey;
    }
  }

  // Part 3: Build Methods - Main UI

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _isLoading) {
      return Scaffold(
        backgroundColor: widget.isDarkMode
            ? const Color(0xFF1F0B38)
            : const Color(0xFFF5F5F5),
        body: _buildLoadingState(),
        bottomNavigationBar: PetugasBottomNav(
          currentIndex: _currentNavIndex,
          onNavigationTap: _handleNavigation,
          isDarkMode: widget.isDarkMode,
          attendanceMode: _attendanceMode,
        ),
      );
    }

    return Scaffold(
      backgroundColor: widget.isDarkMode
          ? const Color(0xFF1F0B38)
          : Colors.white,
      body: Column(
        children: [
          _buildRecordsHeader(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: refreshData,
              color: primaryColor,
              child: SingleChildScrollView(
                // Changed to standard scroll view
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  children: [
                    _buildAttendanceStats(),
                    const SizedBox(height: 24),
                    _buildViewToggle(),
                    const SizedBox(height: 20),
                    _buildFilterSection(),
                    const SizedBox(height: 4), // We will reuse/refactor this
                    if (_showCalendarView)
                      _buildCalendarTab()
                    else
                      _buildListTab(),
                    const SizedBox(height: 20),
                  ],
                ),
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
    );
  }

  Widget _buildLoadingState() {
    return const Center(child: CircularProgressIndicator(color: primaryColor));
  }

  Widget _buildRecordsHeader() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 16,
        bottom: 16, // Reduced from 32
        left: 16,
        right: 16,
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
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            AppLanguage.tr('Petugas.attendance.report'),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: -0.5,
            ),
          ),
          Positioned(
            right: 0,
            child: IconButton(
              icon: const Icon(Icons.sync, color: Colors.white),
              onPressed: () async {
                await SyncStatusDialog.show(
                  context,
                  isDarkMode: widget.isDarkMode,
                );
                refreshData();
              },
              tooltip: AppLanguage.tr('Sync Now'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceStats() {
    final presentCount = _filteredRecords
        .where((r) => r['status'] == 'present')
        .length;
    final absentCount = _filteredRecords
        .where((r) => r['status'] == 'absent')
        .length;
    final lateCount = _filteredRecords
        .where((r) => (r['late_minutes'] as int? ?? 0) > 0)
        .length;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF9333EA).withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: _buildNewStatItem(
                presentCount.toString(),
                AppLanguage.tr('Petugas.attendance.present'),
                successColor,
                Icons.check_circle,
              ),
            ),
            VerticalDivider(color: Colors.grey.withValues(alpha: 0.2), thickness: 1),
            Expanded(
              child: _buildNewStatItem(
                absentCount.toString(),
                AppLanguage.tr('Petugas.attendance.absent'),
                errorColor,
                Icons.cancel,
              ),
            ),
            VerticalDivider(color: Colors.grey.withValues(alpha: 0.2), thickness: 1),
            Expanded(
              child: _buildNewStatItem(
                lateCount.toString(),
                AppLanguage.tr('Petugas.attendance.late'),
                Colors.teal,
                Icons.access_time_filled,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNewStatItem(
    String value,
    String label,
    Color color,
    IconData icon,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade500,
            letterSpacing: 1.0,
          ),
        ),
      ],
    );
  }

  Widget _buildViewToggle() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: widget.isDarkMode
            ? const Color(0xFF2D1B4E)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildToggleItem(
              AppLanguage.tr('Petugas.attendance.calendar_view'),
              true,
            ),
          ),
          Expanded(
            child: _buildToggleItem(
              AppLanguage.tr('Petugas.attendance.list_view'),
              false,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleItem(String label, bool isCalendar) {
    final isSelected = _showCalendarView == isCalendar;
    return GestureDetector(
      onTap: () {
        setState(() {
          _showCalendarView = isCalendar;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? (widget.isDarkMode ? primaryColor : Colors.white)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: isSelected && !widget.isDarkMode
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: isSelected
                ? (widget.isDarkMode ? Colors.white : primaryColor)
                : (widget.isDarkMode ? Colors.white54 : Colors.grey.shade600),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppLanguage.tr('Petugas.attendance.filters'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: widget.isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _searchQuery = '';
                    _applyFilters();
                  });
                },
                child: Text(
                  AppLanguage.tr('Petugas.attendance.clear_all'),
                  style: const TextStyle(
                    color: primaryColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildMonthSelectorPill(),
          const SizedBox(height: 16),
          _buildSearchField(),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildMonthSelectorPill() {
    return InkWell(
      onTap: _showMonthYearPicker,
      borderRadius: BorderRadius.circular(50),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: widget.isDarkMode
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.white,
          borderRadius: BorderRadius.circular(50),
          border: Border.all(
            color: widget.isDarkMode ? Colors.white10 : Colors.grey.shade200,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.calendar_today,
              color: widget.isDarkMode ? Colors.white70 : Colors.grey.shade600,
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${_getMonthName(_selectedMonth)} $_selectedYear',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: widget.isDarkMode ? Colors.white : Colors.black87,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down,
              color: widget.isDarkMode ? Colors.white54 : Colors.grey.shade400,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      style: const TextStyle(fontSize: 13), // Reduced size
      decoration: InputDecoration(
        hintText: AppLanguage.tr('Petugas.attendance.search_member'),
        hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
        prefixIcon: Icon(Icons.search, color: primaryColor, size: 20),
        suffixIcon: _searchQuery.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  setState(() {
                    _searchQuery = '';
                    _applyFilters();
                  });
                },
              )
            : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primaryColor, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8, // Reduced padding
        ),
        isDense: true,
      ),
      onChanged: (value) {
        setState(() {
          _searchQuery = value;
          _applyFilters();
        });
      },
    );
  }

  Widget _buildFilterStats() {
    final presentCount = _filteredRecords
        .where((r) => r['status'] == 'present')
        .length;
    final absentCount = _filteredRecords
        .where((r) => r['status'] == 'absent')
        .length;
    final lateCount = _filteredRecords
        .where((r) => (r['late_minutes'] as int? ?? 0) > 0)
        .length;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem(
            AppLanguage.tr('Petugas.attendance.present'),
            presentCount,
            successColor,
          ),
          _buildStatItem(
            AppLanguage.tr('Petugas.attendance.absent'),
            absentCount,
            errorColor,
          ),
          _buildStatItem(
            AppLanguage.tr('Petugas.attendance.late'),
            lateCount,
            warningColor,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }
  // Part 4: Calendar and List Views

  Widget _buildCalendarTab() {
    return Column(
      children: [
        _buildCalendarSection(),
        _buildCalendarEvents(),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildCalendarSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TableCalendar<Map<String, dynamic>>(
        availableGestures: AvailableGestures.horizontalSwipe,
        locale: 'en_US',
        firstDay: DateTime.utc(2020, 1, 1),
        lastDay: DateTime.utc(2030, 12, 31),
        focusedDay: _focusedDay,
        calendarFormat: _calendarFormat,
        eventLoader: _getEventsForDay,
        startingDayOfWeek: StartingDayOfWeek.monday,
        rowHeight: 45,
        daysOfWeekHeight: 40,
        selectedDayPredicate: (day) {
          return isSameDay(_selectedDay, day);
        },
        onDaySelected: _onDaySelected,
        onFormatChanged: (format) {
          if (!mounted) return;
          if (_calendarFormat != format) {
            setState(() {
              _calendarFormat = format;
            });
          }
        },
        onPageChanged: (focusedDay) {
          if (!mounted) return;

          final nowOrg = TimezoneHelper.getCurrentTimeInOrgTimezone(
            _organizationTimezone,
          );
          final isCurrentMonth =
              focusedDay.year == nowOrg.year &&
              focusedDay.month == nowOrg.month;

          setState(() {
            _focusedDay = focusedDay;
            _selectedMonth = focusedDay.month;
            _selectedYear = focusedDay.year;

            // If swiping into the current month, select Today. Otherwise select the 1st.
            if (isCurrentMonth) {
              _selectedDay = nowOrg;
            } else if (_selectedDay.month != focusedDay.month ||
                _selectedDay.year != focusedDay.year) {
              _selectedDay = DateTime(focusedDay.year, focusedDay.month, 1);
            }
          });
          _loadAttendanceRecords();
        },
        calendarStyle: CalendarStyle(
          outsideDaysVisible: false,
          cellMargin: const EdgeInsets.all(6),
          defaultTextStyle: TextStyle(
            fontSize: 14,
            color: widget.isDarkMode ? Colors.white70 : Colors.black87,
          ),
          weekendTextStyle: const TextStyle(
            fontSize: 14,
            color: Colors.red,
          ), // Red for weekends
          selectedDecoration: BoxDecoration(
            color: primaryColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: primaryColor.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          todayDecoration: BoxDecoration(
            color: primaryColor.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          todayTextStyle: TextStyle(
            color: primaryColor,
            fontWeight: FontWeight.bold,
          ),
          markersMaxCount: 1,
          markerDecoration: const BoxDecoration(
            color: warningColor,
            shape: BoxShape.circle,
          ),
          markerSize: 6,
        ),
        headerStyle: HeaderStyle(
          formatButtonVisible: false, // Hidden as per clean design
          titleCentered: true,
          titleTextStyle: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: widget.isDarkMode ? Colors.white : Colors.black87,
          ),
          leftChevronIcon: Icon(
            Icons.chevron_left,
            color: widget.isDarkMode ? Colors.white70 : Colors.grey,
          ),
          rightChevronIcon: Icon(
            Icons.chevron_right,
            color: widget.isDarkMode ? Colors.white70 : Colors.grey,
          ),
        ),
        daysOfWeekStyle: DaysOfWeekStyle(
          weekdayStyle: TextStyle(
            color: widget.isDarkMode ? Colors.white54 : Colors.grey.shade600,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
          weekendStyle: TextStyle(
            color: widget.isDarkMode ? Colors.white54 : Colors.grey.shade600,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildCalendarEvents() {
    final events = _getEventsForDay(_selectedDay);

    if (events.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.event_busy,
                color: widget.isDarkMode
                    ? Colors.white24
                    : Colors.grey.shade300,
                size: 32,
              ),
              const SizedBox(height: 12),
              Text(
                AppLanguage.tr('Petugas.attendance.no_events_today'),
                style: TextStyle(
                  color: widget.isDarkMode
                      ? Colors.white54
                      : Colors.grey.shade600,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                DateFormat('EEEE, dd MMM').format(_selectedDay),
                style: TextStyle(
                  color: widget.isDarkMode
                      ? Colors.white38
                      : Colors.grey.shade400,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLanguage.tr('Petugas.attendance.daily_events'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: widget.isDarkMode
                            ? Colors.white
                            : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat('dd MMMM yyyy').format(_selectedDay),
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.isDarkMode ? Colors.white54 : Colors.grey,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: primaryColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${events.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: events.length,
            itemBuilder: (context, index) {
              return _buildRecordListItem(events[index]);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildListTab() {
    return Column(children: [_buildRecordsList(), const SizedBox(height: 12)]);
  }

  Widget _buildRecordsList() {
    if (_filteredRecords.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: widget.isDarkMode ? Colors.white10 : Colors.grey.shade100,
          ),
        ),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.inbox_outlined,
                size: 48,
                color: widget.isDarkMode
                    ? Colors.white24
                    : Colors.grey.shade300,
              ),
              const SizedBox(height: 16),
              Text(
                AppLanguage.tr('Petugas.attendance.no_report_data'),
                style: TextStyle(
                  color: widget.isDarkMode
                      ? Colors.white54
                      : Colors.grey.shade600,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (_searchQuery.isNotEmpty) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _searchQuery = '';
                      _applyFilters();
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primaryColor,
                    side: const BorderSide(color: primaryColor),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  icon: const Icon(Icons.clear_all, size: 18),
                  label: Text(
                    AppLanguage.tr('Petugas.attendance.clear_search'),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  AppLanguage.tr('Petugas.attendance.attendance_report'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: widget.isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: primaryColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_filteredRecords.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _filteredRecords.length,
            itemBuilder: (context, index) {
              return _buildRecordListItem(_filteredRecords[index]);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildRecordListItem(
    Map<String, dynamic> record) {
    final memberName = _getMemberName(record);
    final employeeId = _getEmployeeId(record);
    final memberPhoto = _getMemberPhotoUrl(record);
    final attendanceDate = record['attendance_date'] as String? ?? '';
    final checkInTime = record['actual_check_in'] as String?;
    final checkOutTime = record['actual_check_out'] as String?;
    final status = record['status'] as String? ?? 'unknown';
    final lateMinutes = record['late_minutes'] as int?;

    final isPresent = status.toLowerCase() == 'present';
    final isLate = lateMinutes != null && lateMinutes > 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showRecordDetails(record),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _buildPhotoCircle(memberPhoto, isPresent, size: 50),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        memberName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: widget.isDarkMode
                              ? Colors.white
                              : Colors.black87,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.access_time,
                            size: 14,
                            color: widget.isDarkMode
                                ? Colors.white54
                                : Colors.grey.shade500,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            checkInTime != null
                                ? _formatTime(checkInTime)
                                : '--:--',
                            style: TextStyle(
                              fontSize: 13,
                              color: widget.isDarkMode
                                  ? Colors.white54
                                  : Colors.grey.shade500,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _buildStatusPill(status, isLate, lateMinutes),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoCircle(
    String? photoUrl,
    bool isPresent, {
    double size = 44,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: widget.isDarkMode ? Colors.white24 : Colors.grey.shade200,
          width: 2,
        ),
      ),
      child: ClipOval(
        child: photoUrl != null
            ? CachedNetworkImage(
                imageUrl: photoUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                placeholder: (context, url) =>
                    Container(color: Colors.grey.shade200),
                errorWidget: (context, url, error) => Icon(
                  Icons.person,
                  color: Colors.grey.shade400,
                  size: size * 0.6,
                ),
              )
            : Icon(Icons.person, color: Colors.grey.shade400, size: size * 0.6),
      ),
    );
  }

  Widget _buildStatusPill(String status, bool isLate, int? lateMinutes) {
    Color chipColor;
    String displayStatus;

    switch (status.toLowerCase()) {
      case 'present':
        chipColor = successColor;
        displayStatus = AppLanguage.tr('Petugas.attendance.present');
        break;
      case 'absent':
        chipColor = errorColor;
        displayStatus = AppLanguage.tr('Petugas.attendance.absent');
        break;
      case 'late':
        chipColor = warningColor;
        displayStatus = AppLanguage.tr('Petugas.attendance.late');
        break;
      default:
        chipColor = Colors.grey;
        displayStatus = status.toUpperCase();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: chipColor.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: chipColor.withValues(alpha: 0.5), width: 1),
          ),
          child: Text(
            displayStatus,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: chipColor,
            ),
          ),
        ),
        if (isLate)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+${lateMinutes}m Late',
              style: TextStyle(
                fontSize: 10,
                color: warningColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStatusChip(String status) {
    Color chipColor;
    String displayStatus;

    switch (status.toLowerCase()) {
      case 'present':
        chipColor = successColor;
        displayStatus = AppLanguage.tr('Petugas.attendance.present');
        break;
      case 'absent':
        chipColor = errorColor;
        displayStatus = AppLanguage.tr('Petugas.attendance.absent');
        break;
      case 'late':
        chipColor = warningColor;
        displayStatus = AppLanguage.tr('Petugas.attendance.late');
        break;
      default:
        chipColor = Colors.grey;
        displayStatus = status.toUpperCase();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: chipColor.withValues(alpha: 0.3)),
      ),
      child: Text(
        displayStatus,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: chipColor,
        ),
      ),
    );
  }
  // Part 5: Detail Dialog and Month Picker

  Future<void> _showRecordDetails(Map<String, dynamic> record) async {
    if (!mounted) return;

    final memberName = _getMemberName(record);
    final employeeId = _getEmployeeId(record);
    final memberPhoto = _getMemberPhotoUrl(record);
    final attendanceDate = record['attendance_date'] as String? ?? '';
    final checkInTime = record['actual_check_in'] as String?;
    final checkOutTime = record['actual_check_out'] as String?;
    final status = record['status'] as String? ?? 'unknown';
    final lateMinutes = record['late_minutes'] as int?;
    final earlyLeaveMinutes = record['early_leave_minutes'] as int?;
    final workDurationMinutes = record['work_duration_minutes'] as int?;
    final checkInDeviceId = record['check_in_device_id'] as int?;
    final checkOutDeviceId = record['check_out_device_id'] as int?;
    final checkInMethod = record['check_in_method'] as String?;
    final checkOutMethod = record['check_out_method'] as String?;

    final checkInLocation = _getDeviceLocationName(checkInDeviceId);
    final checkOutLocation = _getDeviceLocationName(checkOutDeviceId);

    // ✅ NEW: Break Fields
    final actualBreakStart = record['actual_break_start'] as String?;
    final actualBreakEnd = record['actual_break_end'] as String?;
    final breakOutDeviceId = record['break_out_device_id'] as int?;
    final breakInDeviceId = record['break_in_device_id'] as int?;
    final breakOutMethod = record['break_out_method'] as String?;
    final breakInMethod = record['break_in_method'] as String?;

    final breakOutLocation = _getDeviceLocationName(breakOutDeviceId);
    final breakInLocation = _getDeviceLocationName(breakInDeviceId);

    showDialog(
      context: context,
      builder: (BuildContext context) {
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
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header with photo and name
                    Row(
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.grey.shade200,
                            border: Border.all(
                              color: _getStatusColor(status).withValues(alpha: 0.3),
                              width: 2,
                            ),
                          ),
                          child: ClipOval(
                            child: memberPhoto != null
                                ? Image.network(
                                    memberPhoto,
                                    width: 60,
                                    height: 60,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Icon(
                                        Icons.person,
                                        color: Colors.grey.shade600,
                                        size: 30,
                                      );
                                    },
                                  )
                                : Icon(
                                    Icons.person,
                                    color: Colors.grey.shade600,
                                    size: 30,
                                  ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                memberName,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (employeeId.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Employee ID: $employeeId',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 4),
                              _buildStatusChip(status),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(Icons.close, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Timezone info banner
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.blue.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.access_time,
                            size: 14,
                            color: Colors.blue.shade700,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${AppLanguage.tr('Petugas.attendance.timezone')}: ${_getTimezoneDisplay()}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Details section
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: primaryColor.withValues(alpha: 0.1),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          _buildDetailRow(
                            Icons.calendar_today,
                            AppLanguage.tr('Petugas.attendance.date'),
                            attendanceDate,
                          ),
                          if (checkInTime != null) ...[
                            const Divider(height: 20),
                            _buildDetailRow(
                              Icons.login,
                              AppLanguage.tr(
                                'Petugas.attendance.check_in_time',
                              ),
                              _formatDateTime(checkInTime),
                            ),
                            if (checkInMethod != null)
                              _buildDetailRow(
                                Icons.fingerprint,
                                AppLanguage.tr(
                                  'Petugas.attendance.check_in_method',
                                ),
                                checkInMethod,
                              ),
                            if (checkInLocation != null)
                              _buildDetailRow(
                                Icons.location_on,
                                AppLanguage.tr(
                                  'Petugas.attendance.check_in_location',
                                ),
                                checkInLocation,
                              ),
                          ],
                          if (checkOutTime != null) ...[
                            const Divider(height: 20),
                            _buildDetailRow(
                              Icons.logout,
                              AppLanguage.tr(
                                'Petugas.attendance.check_out_time',
                              ),
                              _formatDateTime(checkOutTime),
                            ),
                            if (checkOutMethod != null)
                              _buildDetailRow(
                                Icons.fingerprint,
                                AppLanguage.tr(
                                  'Petugas.attendance.check_out_method',
                                ),
                                checkOutMethod,
                              ),
                            if (checkOutLocation != null)
                              _buildDetailRow(
                                Icons.location_on,
                                AppLanguage.tr(
                                  'Petugas.attendance.check_out_location',
                                ),
                                checkOutLocation,
                              ),
                          ],

                          // ✅ NEW: Break Details
                          if (actualBreakStart != null) ...[
                            const Divider(height: 20),
                            _buildDetailRow(
                              Icons.coffee_outlined,
                              'Mulai Istirahat',
                              _formatDateTime(actualBreakStart),
                            ),
                            if (breakOutMethod != null)
                              _buildDetailRow(
                                Icons.fingerprint,
                                'Metode Istirahat Keluar',
                                breakOutMethod,
                              ),
                            if (breakOutLocation != null)
                              _buildDetailRow(
                                Icons.location_on,
                                'Lokasi Istirahat Keluar',
                                breakOutLocation,
                              ),
                          ],
                          if (actualBreakEnd != null) ...[
                            const Divider(height: 20),
                            _buildDetailRow(
                              Icons.login_outlined,
                              'Selesai Istirahat',
                              _formatDateTime(actualBreakEnd),
                            ),
                            if (breakInMethod != null)
                              _buildDetailRow(
                                Icons.fingerprint,
                                'Metode Istirahat Masuk',
                                breakInMethod,
                              ),
                            if (breakInLocation != null)
                              _buildDetailRow(
                                Icons.location_on,
                                'Lokasi Istirahat Masuk',
                                breakInLocation,
                              ),
                          ],
                          if (workDurationMinutes != null ||
                              lateMinutes != null ||
                              earlyLeaveMinutes != null) ...[
                            const Divider(height: 20),
                            if (workDurationMinutes != null)
                              _buildDetailRow(
                                Icons.work,
                                AppLanguage.tr(
                                  'Petugas.attendance.work_duration',
                                ),
                                '${(workDurationMinutes / 60).toStringAsFixed(1)} ${AppLanguage.tr('Petugas.attendance.hours')}',
                              ),
                            if (lateMinutes != null && lateMinutes > 0)
                              _buildDetailRow(
                                Icons.schedule,
                                AppLanguage.tr('Petugas.attendance.late'),
                                '$lateMinutes ${AppLanguage.tr('Petugas.attendance.minutes')}',
                                valueColor: warningColor,
                              ),
                            if (earlyLeaveMinutes != null &&
                                earlyLeaveMinutes > 0)
                              _buildDetailRow(
                                Icons.schedule,
                                AppLanguage.tr(
                                  'Petugas.attendance.early_leave',
                                ),
                                '$earlyLeaveMinutes ${AppLanguage.tr('Petugas.attendance.minutes')}',
                                valueColor: warningColor,
                              ),
                          ],
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

  Widget _buildDetailRow(
    IconData icon,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: primaryColor),
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
                  TextSpan(
                    text: value,
                    style: TextStyle(
                      color: valueColor ?? Colors.black87,
                      fontWeight: valueColor != null
                          ? FontWeight.w600
                          : FontWeight.normal,
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

  Future<void> _showMonthYearPicker() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext context) {
        int tempYear = _selectedYear;
        int tempMonth = _selectedMonth;

        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return Container(
              decoration: BoxDecoration(
                color: widget.isDarkMode
                    ? const Color(0xFF2D1B4E)
                    : Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: widget.isDarkMode
                          ? Colors.white24
                          : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        onPressed: () => setStateDialog(() => tempYear--),
                        icon: Icon(Icons.chevron_left, color: primaryColor),
                      ),
                      Text(
                        tempYear.toString(),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: widget.isDarkMode
                              ? Colors.white
                              : Colors.black87,
                        ),
                      ),
                      IconButton(
                        onPressed: () => setStateDialog(() => tempYear++),
                        icon: Icon(Icons.chevron_right, color: primaryColor),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          childAspectRatio: 2,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: 12,
                    itemBuilder: (context, index) {
                      final month = index + 1;
                      final isSelected = month == tempMonth;
                      final monthName = _getMonthName(month);

                      return InkWell(
                        onTap: () => setStateDialog(() => tempMonth = month),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? primaryColor
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected
                                  ? primaryColor
                                  : (widget.isDarkMode
                                        ? Colors.white24
                                        : Colors.grey.shade300),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              monthName.length >= 3
                                  ? monthName.substring(0, 3)
                                  : monthName,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isSelected
                                    ? Colors.white
                                    : (widget.isDarkMode
                                          ? Colors.white70
                                          : Colors.black87),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        if (!mounted) return;
                        setState(() {
                          _selectedMonth = tempMonth;
                          _selectedYear = tempYear;

                          final nowOrg =
                              TimezoneHelper.getCurrentTimeInOrgTimezone(
                                _organizationTimezone,
                              );
                          final isCurrentMonth =
                              tempYear == nowOrg.year &&
                              tempMonth == nowOrg.month;

                          if (isCurrentMonth) {
                            _selectedDay = nowOrg;
                            _focusedDay = nowOrg;
                          } else {
                            _selectedDay = DateTime(tempYear, tempMonth, 1);
                            _focusedDay = DateTime(tempYear, tempMonth, 1);
                          }
                        });
                        Navigator.pop(context);
                        _loadAttendanceRecords();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryColor,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        AppLanguage.tr('Petugas.attendance.apply'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
