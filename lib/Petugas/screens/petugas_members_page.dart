import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import '../../attendance/services/attendance_service.dart';
import '../../auth/services/role_service.dart';
import '../services/member_performance_service.dart';
import '../../attendance/services/face_recognition_tflite_service.dart';
import '../../attendance/services/biometric_service.dart';
import '../../services/supabase_storage_service.dart';

import '../../helpers/rfid_mode_helper.dart';
import '../widgets/petugas_bottom_nav.dart';

import 'petugas_records_page.dart';
import 'petugas_profile_page.dart';
import '../../attendance/screens/face_registration_page.dart';
import '../../attendance/screens/fingerprint_registration_page.dart';
import '../../helpers/language_helper.dart';

class PetugasMembersPage extends StatefulWidget {
  final bool isDarkMode;
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const PetugasMembersPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
    this.isDarkMode = false,
  });

  @override
  State<PetugasMembersPage> createState() => _PetugasMembersPageState();
}

class _PetugasMembersPageState extends State<PetugasMembersPage>
    with SingleTickerProviderStateMixin {
  static const Color primaryColor = Color(0xFF4A1E79);
  static const Color primaryDark = Color(0xFF3B1860);
  static const Color successColor = Color(0xFF10B981);
  static const Color warningColor = Color(0xFFF59E0B);
  static const Color errorColor = Color(0xFFEF4444);
  static const Color backgroundColor = Color(0xFFF8F9FA);

  final SupabaseClient _supabase = Supabase.instance.client;
  final AttendanceService _attendanceService = AttendanceService();
  final RoleService _roleService = RoleService();
  final MemberPerformanceService _performanceService =
      MemberPerformanceService();

  bool _isInitialLoading = true;
  bool _isContentLoading = false;
  bool _isLoadingPerformance = false;
  bool _isLoadingActivities = false;
  String? _errorMessage;
  int _currentNavIndex = 1;
  String _attendanceMode = 'face';
  String _organizationTimezone = 'Asia/Jakarta';
  List<Map<String, dynamic>> _organizationMembers = [];
  Map<String, dynamic>? _organization;
  Map<String, dynamic> _memberPerformanceStats = {};
  List<Map<String, dynamic>> _membersPerformance = [];
  List<Map<String, dynamic>> _recentActivities = [];
  final TextEditingController _searchController = TextEditingController();
  String _selectedDepartment = 'all';
  String _selectedBioFilter = 'all';
  List<String> _departments = ['all'];

  String _selectedTimePeriod = 'today';
  String _selectedSortBy = 'score';

  final ScrollController _scrollController = ScrollController();
  int _currentPage = 1;
  static const int _pageSize = 20;
  int _totalMembers = 0;
  int _totalPages = 0;

  late TabController _tabController;
  StreamSubscription? _biometricSubscription;

  @override
  void initState() {
    _tabController = TabController(length: 3, vsync: this);
    _scrollController.addListener(_onScroll);
    _loadDataOptimized();
    _setupBiometricRealtimeListener();
  }

  void _onScroll() {}

  @override
  void dispose() {
    _biometricSubscription?.cancel();
    _tabController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _setupBiometricRealtimeListener() {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    _biometricSubscription = _supabase
        .from('biometric_data')
        .stream(primaryKey: ['id'])
        .listen((_) {
          if (!mounted) return;
          debugPrint('🔄 Biometric data changed, refreshing member list...');
          _loadOrganizationMembersOptimized(page: _currentPage);
        });
  }

  Future<void> _loadDataOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    setState(() => _isInitialLoading = true);

    try {
      _attendanceMode = await RfidModeHelper.getAttendanceMode(organizationId);

      await Future.wait([
        _loadOrganizationData(),
        _loadOrganizationMembersOptimized(page: 1, isInitial: true),
      ]);

      await _applyFilters();
    } finally {
      if (mounted) setState(() => _isInitialLoading = false);
    }

    _loadRecentActivitiesOptimized();
  }

  Future<void> _loadOrganizationMembersOptimized({
    int page = 1,
    bool isInitial = false,
  }) async {
    final rawOrgId = widget.memberData['organization_id'];
    final organizationId = rawOrgId is int
        ? rawOrgId
        : int.tryParse(rawOrgId.toString());

    if (organizationId == null) {
      debugPrint('❌ ERROR: organizationId is null');
      return;
    }

    if (!mounted) return;
    setState(() {
      if (!isInitial) _isContentLoading = true;
      _currentPage = page;
    });

    try {
      final searchQuery = _searchController.text.trim();
      final departmentFilter = _selectedDepartment == 'all'
          ? null
          : _selectedDepartment;

      debugPrint(
        '🔍 REFRESH: Query="$searchQuery", Dept="$departmentFilter", Page=$_currentPage',
      );

      final futures = <Future>[
        _performanceService.getOrganizationMembers(
          organizationId,
          page: _currentPage,
          limit: _pageSize,
          searchQuery: searchQuery.isNotEmpty ? searchQuery : null,
          departmentFilter: departmentFilter,
        ),
      ];

      if (_currentPage == 1 || _totalMembers == 0) {
        futures.add(
          _performanceService.getOrganizationMembersCount(
            organizationId,
            searchQuery: searchQuery.isNotEmpty ? searchQuery : null,
            departmentFilter: departmentFilter,
          ),
        );
      }

      final results = await Future.wait(futures);
      final members = results[0] as List<Map<String, dynamic>>;
      debugPrint('📦 RESULTS: Received ${members.length} members');

      if (mounted) {
        setState(() {
          _organizationMembers = members;

          if (results.length > 1) {
            _totalMembers = results[1] as int;
            _totalPages = (_totalMembers / _pageSize).ceil();
          }

          if (_departments.length <= 1 && members.isNotEmpty) {
            final deptSet = <String>{'all'};
            for (final member in members) {
              final dept = member['departments'] as Map<String, dynamic>?;
              if (dept != null && dept['name'] != null) {
                deptSet.add(dept['name'] as String);
              }
            }
            _departments = deptSet.toList()..sort();
            debugPrint('✅ Departments initialized: $_departments');
          }

          if (!isInitial) _isContentLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (!isInitial) _isContentLoading = false;
        });
      }
    }
  }

  Future<void> _loadRecentActivitiesOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING RECENT ACTIVITIES (OPTIMIZED) ===');

    if (!mounted) return;
    setState(() => _isLoadingActivities = true);

    try {
      final activities = await _performanceService.getRecentMemberActivities(
        organizationId,
        limit: 5,
        organizationTimezone: _organizationTimezone,
      );

      debugPrint('Recent activities loaded: ${activities.length}');

      if (mounted) {
        setState(() {
          _recentActivities = activities;
          _isLoadingActivities = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading recent activities: $e');
      if (mounted) {
        setState(() {
          _isLoadingActivities = false;
        });
      }
    }
  }

  Future<void> _loadOrganizationData() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final org = await _supabase
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

  void _handleNavigation(int index) {
    if (index == _currentNavIndex) return;

    setState(() {
      _currentNavIndex = index;
    });

    switch (index) {
      case 0:
        Navigator.popUntil(context, (route) => route.isFirst);
        break;
      case 1:
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
                userProfile: widget.userProfile,
                isDarkMode: widget.isDarkMode,
              ),
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 1;
          });
        });
        break;
      case 3:
        Navigator.push<bool>(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => Container(
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
        ).then((_) {
          setState(() {
            _currentNavIndex = 1;
          });
        });
        break;
    }
  }

  String _getMemberName(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>?;
    if (profile == null) return 'Unknown User';

    final displayName = (profile['display_name'] as String? ?? '').trim();
    final firstName = (profile['first_name'] as String? ?? '').trim();
    final lastName = (profile['last_name'] as String? ?? '').trim();
    
    final fullName = '$firstName $lastName'.trim();

    if (displayName.isNotEmpty) {
      if (fullName.isNotEmpty && displayName.toLowerCase() != fullName.toLowerCase()) {
        return '$displayName - $fullName';
      }
      return displayName;
    }

    return fullName.isEmpty ? 'Unknown User' : fullName;
  }

  String? _getMemberPhotoUrl(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>?;
    final photoPath = profile?['profile_photo_url'] as String?;

    if (photoPath == null || photoPath.trim().isEmpty) return null;

    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      return photoPath;
    }

    return _supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  String _formatPercentage(double value) {
    return '${(value * 100).toStringAsFixed(1)}%';
  }

  Future<void> _applyFilters() async {
    if (!mounted) return;
    setState(() => _isLoadingPerformance = true);

    try {
      final organizationId = widget.memberData['organization_id'] as int;

      final summary = await _performanceService
          .getOrganizationPerformanceSummary(
            organizationId,
            organizationTimezone: _organizationTimezone,
          );

      String timePeriod;
      if (_selectedTimePeriod == 'today') {
        timePeriod = 'today';
      } else if (_selectedTimePeriod == 'yesterday') {
        timePeriod = 'yesterday';
      } else if (_selectedTimePeriod == 'this_week') {
        timePeriod = 'this_week';
      } else if (_selectedTimePeriod == 'last_week') {
        timePeriod = 'last_week';
      } else if (_selectedTimePeriod == 'this_month') {
        timePeriod = 'this_month';
      } else if (_selectedTimePeriod == 'last_month') {
        timePeriod = 'last_month';
      } else if (_selectedTimePeriod == 'this_year') {
        timePeriod = 'this_year';
      } else if (_selectedTimePeriod == 'last_year') {
        timePeriod = 'last_year';
      } else {
        timePeriod = 'this_month';
      }

      String sortBy;
      if (_selectedSortBy == 'score') {
        sortBy = 'productivity';
      } else {
        sortBy = 'attendance';
      }

      final filteredData = await _performanceService.getFilteredPerformance(
        organizationId,
        timePeriod: timePeriod,
        sortBy: sortBy,
        organizationTimezone: _organizationTimezone,
      );

      if (mounted) {
        setState(() {
          _memberPerformanceStats = summary;
          _membersPerformance = filteredData;
          _isLoadingPerformance = false;
        });
      }
    } catch (e) {
      debugPrint('Error applying filters: $e');
      if (mounted) {
        setState(() => _isLoadingPerformance = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitialLoading) {
      return Scaffold(
        backgroundColor: widget.isDarkMode
            ? const Color(0xFF1F0B38)
            : const Color(0xFFF5F5F5),
        body: const Center(
          child: CircularProgressIndicator(color: primaryColor),
        ),
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
          : const Color(0xFFF8F9FA),
      body: NestedScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverToBoxAdapter(
              child: Container(
                height: MediaQuery.of(context).padding.top,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: widget.isDarkMode
                        ? [const Color(0xFF2D1B4E), const Color(0xFF1F0B38)]
                        : [const Color(0xFF8938DF), const Color(0xFF4A1E79)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _SliverTabBarDelegate(
                height: 48.0,
                child: Container(
                  decoration: BoxDecoration(
                    color: widget.isDarkMode ? const Color(0xFF1F0B38) : null,
                    border: Border(
                      bottom: BorderSide(
                        color: widget.isDarkMode
                            ? Colors.white.withOpacity(0.08)
                            : Colors.grey.withOpacity(0.15),
                        width: 1.0,
                      ),
                    ),
                    gradient: widget.isDarkMode
                        ? null
                        : const LinearGradient(
                            colors: [Color(0xFF8938DF), Color(0xFF4A1E79)],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                  ),
                  child: Center(
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: false,
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white.withOpacity(0.6),
                      indicatorColor: Colors.white,
                      indicatorWeight: 3,
                      indicatorSize: TabBarIndicatorSize.label,
                      dividerColor: Colors.transparent,
                      dividerHeight: 0,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 16),
                      labelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      tabs: [
                        Tab(text: AppLanguage.tr('Petugas.members.overview')),
                        Tab(text: AppLanguage.tr('Petugas.members.members')),
                        Tab(
                          text: AppLanguage.tr('Petugas.members.performance'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ];
        },
        body: Container(
          color: widget.isDarkMode
              ? const Color(0xFF1F0B38)
              : Colors.grey.shade50,
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOverviewTab(),
              _buildMembersTab(),
              _buildPerformanceTab(),
            ],
          ),
        ),
      ),
      bottomNavigationBar: PetugasBottomNav(
        currentIndex: _currentNavIndex,
        onNavigationTap: _handleNavigation,
        isDarkMode: widget.isDarkMode,
        attendanceMode: _attendanceMode,
      ),
    );
  }

  Widget _buildOverviewTab() {
    return Container(
      color: widget.isDarkMode ? const Color(0xFF1F0B38) : Colors.grey.shade50,
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildStatCardModern(
                    AppLanguage.tr('Petugas.members.total_members'),
                    '${_memberPerformanceStats['total_members'] ?? 0}',
                    Icons.groups_rounded,
                    widget.isDarkMode
                        ? Colors.white.withOpacity(0.1)
                        : const Color(0xFFF3E8FF),
                    widget.isDarkMode ? Colors.white : const Color(0xFF9333EA),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatCardModern(
                    AppLanguage.tr('Petugas.members.active_members'),
                    '${_memberPerformanceStats['active_members'] ?? 0}',
                    Icons.group_add_rounded,
                    widget.isDarkMode
                        ? Colors.white.withOpacity(0.1)
                        : const Color(0xFFF3E8FF),
                    widget.isDarkMode ? Colors.white : const Color(0xFF9333EA),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildRecentActivitySummaryCard(),
            const SizedBox(height: 24),
            _buildRecentActivityHeader(),
            const SizedBox(height: 12),
            _buildRecentActivityList(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCardModern(
    String title,
    String value,
    IconData icon,
    Color bgColor,
    Color iconColor,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: widget.isDarkMode ? Colors.white10 : const Color(0xFFE9D5FF),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF9333EA).withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: widget.isDarkMode
                  ? Colors.white54
                  : const Color(0xFF4B5563),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: widget.isDarkMode ? Colors.white : const Color(0xFF111827),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentActivitySummaryCard() {
    final punctualityRate =
        _memberPerformanceStats['avg_punctuality_rate'] ?? 0.0;
    final percentage = (punctualityRate * 100).toStringAsFixed(1);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6B21A8), Color(0xFF9333EA)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF9333EA).withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppLanguage.tr('Petugas.members.punctuality_rate'),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
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
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Color(0xFF34D399),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      AppLanguage.tr('Petugas.members.live'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '$percentage%',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 42,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            AppLanguage.tr('Petugas.members.on_time_attendance'),
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(
                height: 36,
                width: 100,
                child: Stack(
                  children: List.generate(
                    _organizationMembers.length > 3
                        ? 4
                        : _organizationMembers.length,
                    (index) {
                      if (index == 3 && _organizationMembers.length > 3) {
                        return Positioned(
                          left: index * 24.0,
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE9D5FF),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF6B21A8),
                                width: 2,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '${_organizationMembers.length - 3}+',
                                style: const TextStyle(
                                  color: Color(0xFF6B21A8),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        );
                      }

                      final member = _organizationMembers[index];
                      final photoUrl = _getMemberPhotoUrl(member);

                      return Positioned(
                        left: index * 24.0,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: CircleAvatar(
                            radius: 15,
                            backgroundColor: Colors.grey.shade200,
                            backgroundImage: photoUrl != null
                                ? CachedNetworkImageProvider(photoUrl)
                                : null,
                            child: photoUrl == null
                                ? const Icon(
                                    Icons.person,
                                    size: 16,
                                    color: Colors.grey,
                                  )
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  _tabController.animateTo(1);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF6B21A8),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                ),
                child: Text(
                  AppLanguage.tr('Petugas.members.manage'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecentActivityHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          AppLanguage.tr('Petugas.members.recent_activity'),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: widget.isDarkMode ? Colors.white : const Color(0xFF111827),
          ),
        ),
        GestureDetector(
          onTap: () {},
          child: Text(
            AppLanguage.tr('Petugas.members.view_all'),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Color(0xFF6B21A8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecentActivityList() {
    if (_isLoadingActivities) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(color: primaryColor),
        ),
      );
    }

    if (_recentActivities.isEmpty) {
      return Container(
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
                Icons.history,
                size: 40,
                color: widget.isDarkMode
                    ? Colors.white24
                    : Colors.grey.shade300,
              ),
              const SizedBox(height: 12),
              Text(
                AppLanguage.tr('Petugas.members.no_activities_today'),
                style: TextStyle(
                  color: widget.isDarkMode
                      ? Colors.white54
                      : Colors.grey.shade500,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _recentActivities.length,
      itemBuilder: (context, index) {
        final activity = _recentActivities[index];
        final memberName = activity['member_name'] as String? ?? 'Unknown';
        final eventType = activity['event_type'] as String? ?? 'Unknown';
        final timeAgo = activity['time_ago'] as String? ?? 'Just now';
        final method = activity['method'] as String? ?? '';
        final memberInfo =
            activity['member_info'] as Map<String, dynamic>? ?? {};

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.02),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFE9D5FF),
                    width: 1.5,
                  ),
                ),
                child: CircleAvatar(
                  radius: 24,
                  backgroundColor: Colors.grey.shade100,
                  backgroundImage: _getMemberPhotoUrl(memberInfo) != null
                      ? CachedNetworkImageProvider(
                          _getMemberPhotoUrl(memberInfo)!,
                        )
                      : null,
                  child: _getMemberPhotoUrl(memberInfo) == null
                      ? const Icon(Icons.person, color: Colors.grey, size: 24)
                      : null,
                ),
              ),
              const SizedBox(width: 14),
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
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _buildActivityBadgeModern(eventType),
                        if (method.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            'via ${method.replaceAll('_', ' ')}',
                            style: TextStyle(
                              fontSize: 11,
                              color: widget.isDarkMode
                                  ? Colors.white54
                                  : Colors.grey.shade500,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Text(
                timeAgo,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActivityBadgeModern(String eventType) {
    Color color;
    String label;

    switch (eventType.toLowerCase()) {
      case 'check_in':
        color = const Color(0xFF10B981);
        label = 'Check In';
        break;
      case 'check_out':
        color = const Color(0xFFEF4444);
        label = 'Check Out';
        break;
      case 'break_start':
        color = const Color(0xFFF59E0B);
        label = 'Break Start';
        break;
      case 'break_end':
        color = const Color(0xFF3B82F6);
        label = 'Break End';
        break;
      default:
        color = Colors.grey;
        label = eventType.replaceAll('_', ' ');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildMembersTab() {
    return Container(
      color: widget.isDarkMode ? const Color(0xFF1F0B38) : Colors.grey.shade50,
      child: Column(
        children: [
          _buildSummaryCard(),
          Expanded(child: _buildMembersList()),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: widget.isDarkMode ? Colors.white10 : Colors.grey.shade100,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(widget.isDarkMode ? 0.2 : 0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: widget.isDarkMode
                        ? Colors.white.withOpacity(0.05)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search,
                        size: 14,
                        color: widget.isDarkMode ? Colors.white54 : Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          style: TextStyle(
                            fontSize: 11,
                            color: widget.isDarkMode
                                ? Colors.white
                                : Colors.black87,
                          ),
                          textInputAction: TextInputAction.search,
                          onSubmitted: (value) {
                            _loadOrganizationMembersOptimized(page: 1);
                          },
                          decoration: InputDecoration(
                            hintText: AppLanguage.tr('Petugas.members.search'),
                            hintStyle: TextStyle(
                              fontSize: 11,
                              color: widget.isDarkMode
                                  ? Colors.white38
                                  : Colors.grey,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.search,
                          size: 18,
                          color: widget.isDarkMode
                              ? const Color(0xFFD8B4FE)
                              : primaryColor,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          _loadOrganizationMembersOptimized(page: 1);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: widget.isDarkMode
                      ? Colors.white.withOpacity(0.05)
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedDepartment,
                    isDense: true,
                    icon: Icon(
                      Icons.filter_list,
                      size: 14,
                      color: widget.isDarkMode ? Colors.white70 : Colors.grey,
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.isDarkMode ? Colors.white : Colors.black87,
                    ),
                    dropdownColor: widget.isDarkMode
                        ? const Color(0xFF2D1B4E)
                        : Colors.white,
                    items: _departments.map<DropdownMenuItem<String>>((
                      String value,
                    ) {
                      return DropdownMenuItem(
                        value: value,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 50),
                          child: Text(
                            value == 'all' ? AppLanguage.tr('all') : value,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      if (newValue != null) {
                        setState(() {
                          _selectedDepartment = newValue;
                        });
                        _loadOrganizationMembersOptimized(isInitial: false);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildBioFilterChip('all', 'Semua'),
                _buildBioFilterChip('no_face', 'Belum Wajah'),
                _buildBioFilterChip('no_finger', 'Belum Jari'),
                _buildBioFilterChip('no_rfid', 'Belum RFID'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBioFilterChip(String value, String label) {
    final isSelected = _selectedBioFilter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (selected) {
          if (selected) {
            setState(() {
              _selectedBioFilter = value;
            });
            _loadOrganizationMembersOptimized(isInitial: false);
          }
        },
        labelStyle: TextStyle(
          fontSize: 10,
          color: isSelected
              ? Colors.white
              : (widget.isDarkMode ? Colors.white70 : Colors.black87),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
        selectedColor: const Color(0xFF8938DF),
        backgroundColor: widget.isDarkMode
            ? Colors.white.withOpacity(0.05)
            : Colors.grey.shade100,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: isSelected ? Colors.transparent : Colors.grey.shade200,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _buildMembersList() {
    var filteredMembers = List<Map<String, dynamic>>.from(_organizationMembers);

    if (_selectedBioFilter != 'all') {
      filteredMembers = filteredMembers.where((m) {
        final bioData = m['biometric_data'];
        final rfidData = m['rfid_cards'];

        bool hasFace = false;
        bool hasFinger = false;
        bool hasRfid = false;

        if (bioData is List) {
          hasFace = bioData.any((b) =>
              (b['biometric_type'] == 'face' ||
                  b['biometric_type'] == 'face_recognition') &&
              b['is_active'] == true);
          hasFinger = bioData.any(
              (b) => b['biometric_type'] == 'fingerprint' && b['is_active'] == true);
        }
        if (rfidData is List) {
          hasRfid = rfidData.any((r) => r['is_active'] == true);
        } else if (rfidData is Map) {
          hasRfid = rfidData['is_active'] == true;
        }

        if (_selectedBioFilter == 'no_face') return !hasFace;
        if (_selectedBioFilter == 'no_finger') return !hasFinger;
        if (_selectedBioFilter == 'no_rfid') return !hasRfid;
        return true;
      }).toList();
    }

    final isFiltering =
        _searchController.text.isNotEmpty ||
        _selectedDepartment != 'all' ||
        _selectedBioFilter != 'all';

    if (_isContentLoading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(strokeWidth: 3),
              const SizedBox(height: 16),
              Text(
                AppLanguage.tr('Petugas.members.searching'),
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    if (filteredMembers.isEmpty) {
      return _buildEmptyState(isFiltering);
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            itemCount: filteredMembers.length,
            itemBuilder: (context, index) {
              return _buildMemberCard(filteredMembers[index]);
            },
          ),
        ),
        _buildPaginationControls(),
      ],
    );
  }

  Widget _buildEmptyState(bool isFiltering) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline, size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              isFiltering
                  ? AppLanguage.tr('Petugas.members.no_members_found')
                  : AppLanguage.tr('Petugas.members.no_members_available'),
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaginationControls() {
    if (_totalMembers == 0 && !_isContentLoading) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF1F0B38) : Colors.white,
        border: Border(
          top: BorderSide(
            color: widget.isDarkMode ? Colors.white10 : Colors.grey.shade100,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildPaginationButton(
            label: AppLanguage.tr('prev'),
            icon: Icons.chevron_left,
            onPressed: _currentPage > 1
                ? () =>
                      _loadOrganizationMembersOptimized(page: _currentPage - 1)
                : null,
          ),
          Expanded(
            child: InkWell(
              onTap: _showJumpToPageDialog,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${AppLanguage.tr('page')} $_currentPage ${AppLanguage.tr('of')} $_totalPages',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: widget.isDarkMode
                            ? const Color(0xFFD8B4FE)
                            : Colors.black87,
                        fontSize: 10,
                      ),
                    ),
                    Text(
                      '$_totalMembers ${AppLanguage.tr('Petugas.members.total_members')}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 8,
                        color: widget.isDarkMode
                            ? Colors.white38
                            : Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _buildPaginationButton(
            label: AppLanguage.tr('next'),
            icon: Icons.chevron_right,
            onPressed: _currentPage < _totalPages
                ? () =>
                      _loadOrganizationMembersOptimized(page: _currentPage + 1)
                : null,
            isRightIcon: true,
          ),
        ],
      ),
    );
  }

  Widget _buildPaginationButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool isRightIcon = false,
  }) {
    return SizedBox(
      width: 65,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          side: BorderSide(
            color: onPressed != null
                ? (widget.isDarkMode ? const Color(0xFF8938DF) : primaryColor)
                : (widget.isDarkMode ? Colors.white12 : Colors.grey.shade200),
          ),
          backgroundColor: onPressed != null && widget.isDarkMode
              ? const Color(0xFF8938DF).withOpacity(0.05)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isRightIcon)
              Icon(
                icon,
                size: 12,
                color: onPressed != null
                    ? (widget.isDarkMode
                          ? const Color(0xFFA855F7)
                          : primaryColor)
                    : Colors.grey,
              ),
            if (!isRightIcon) const SizedBox(width: 1),
            Text(
              label,
              style: TextStyle(
                color: onPressed != null
                    ? (widget.isDarkMode
                          ? const Color(0xFFA855F7)
                          : primaryColor)
                    : Colors.grey,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (isRightIcon) const SizedBox(width: 1),
            if (isRightIcon)
              Icon(
                icon,
                size: 12,
                color: onPressed != null
                    ? (widget.isDarkMode
                          ? const Color(0xFFA855F7)
                          : primaryColor)
                    : Colors.grey,
              ),
          ],
        ),
      ),
    );
  }

  void _showJumpToPageDialog() {
    final TextEditingController pageController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: widget.isDarkMode
            ? const Color(0xFF2D1B4E)
            : Colors.white,
        title: Text(
          AppLanguage.tr('go_to_page'),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: widget.isDarkMode ? Colors.white : Colors.black87,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLanguage.tr(
                'Petugas.members.enter_page_number',
              ).replaceFirst('{range}', '1 - $_totalPages'),
              style: TextStyle(
                color: widget.isDarkMode
                    ? Colors.white54
                    : Colors.grey.shade600,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pageController,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: TextStyle(
                color: widget.isDarkMode ? Colors.white : Colors.black87,
                fontSize: 13,
              ),
              decoration: InputDecoration(
                hintText: AppLanguage.tr('Petugas.members.example_page'),
                hintStyle: TextStyle(
                  color: widget.isDarkMode ? Colors.white30 : Colors.grey,
                  fontSize: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: widget.isDarkMode
                        ? Colors.white10
                        : Colors.grey.shade300,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: widget.isDarkMode
                        ? Colors.white10
                        : Colors.grey.shade300,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              AppLanguage.tr('cancel'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final page = int.tryParse(pageController.text);
              if (page != null && page >= 1 && page <= _totalPages) {
                Navigator.pop(context);
                _loadOrganizationMembersOptimized(page: page);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      AppLanguage.tr(
                        'Petugas.members.invalid_page_number',
                      ).replaceFirst('{totalPages}', '$_totalPages'),
                    ),
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: Text(
              AppLanguage.tr('go'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberCard(Map<String, dynamic> member) {
    final department = member['departments'] as Map<String, dynamic>?;
    final position = member['positions'] as Map<String, dynamic>?;

    String roleName = AppLanguage.tr('Petugas.members.member');
    final posTitle = position?['title'] ?? position?['name'];
    if (department != null && posTitle != null) {
      roleName = '${department['name']} • $posTitle';
    } else {
      roleName =
          posTitle ??
          department?['name'] ??
          AppLanguage.tr('Petugas.members.member');
    }

    final photoUrl = _getMemberPhotoUrl(member);
    final accentColor = const Color(0xFF8938DF);
    final softAccent = accentColor.withOpacity(0.1);

    bool hasFace = false;
    bool hasFinger = false;
    bool hasRfid = false;
    
    final bioData = member['biometric_data'];
    final rfidData = member['rfid_cards'];

    if (bioData is List) {
      hasFace = bioData.any((b) =>
          (b['biometric_type'] == 'face' ||
              b['biometric_type'] == 'face_recognition') &&
          b['is_active'] == true);
      hasFinger = bioData.any(
          (b) => b['biometric_type'] == 'fingerprint' && b['is_active'] == true);
    }
    
    if (rfidData is List) {
      hasRfid = rfidData.any((r) => r['is_active'] == true);
    } else if (rfidData is Map) {
      hasRfid = rfidData['is_active'] == true;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.isDarkMode ? Colors.white10 : Colors.grey.shade100,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(widget.isDarkMode ? 0.2 : 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: () => _showMemberDetail(member),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey.shade100,
                  border: Border.all(
                    color: widget.isDarkMode
                        ? Colors.white10
                        : Colors.grey.shade100,
                    width: 1.5,
                  ),
                ),
                child: ClipOval(
                  child: photoUrl != null
                      ? CachedNetworkImage(
                          imageUrl: photoUrl,
                          fit: BoxFit.cover,
                          placeholder: (context, url) =>
                              Container(color: Colors.grey.shade50),
                          errorWidget: (context, url, error) => Icon(
                            Icons.person,
                            color: Colors.grey.shade400,
                            size: 22,
                          ),
                        )
                      : Icon(
                          Icons.person,
                          color: Colors.grey.shade400,
                          size: 22,
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _getMemberName(member),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: widget.isDarkMode
                            ? Colors.white
                            : Colors.black87,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            roleName,
                            style: TextStyle(
                              fontSize: 11,
                              color: widget.isDarkMode
                                  ? Colors.white54
                                  : const Color(0xFF8938DF).withOpacity(0.7),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildMiniBioIcon(Icons.face_rounded, hasFace),
                        const SizedBox(width: 4),
                        _buildMiniBioIcon(Icons.fingerprint_rounded, hasFinger),
                        const SizedBox(width: 4),
                        _buildMiniBioIcon(Icons.credit_card_rounded, hasRfid),
                      ],
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMemberActionIcon(
                    Icons.chat_bubble_outline_rounded,
                    softAccent,
                    accentColor,
                    () {},
                  ),
                  const SizedBox(width: 4),
                  _buildMemberActionIcon(
                    Icons.phone_outlined,
                    softAccent,
                    accentColor,
                    () {},
                  ),
                  const SizedBox(width: 4),
                  _buildMemberActionIcon(
                    Icons.edit_outlined,
                    softAccent,
                    accentColor,
                    () => _showEditProfileSheet(member),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniBioIcon(IconData icon, bool isActive) {
    return Icon(
      icon,
      size: 12,
      color: isActive
          ? const Color(0xFF10B981)
          : Colors.grey.withOpacity(0.3),
    );
  }

  Widget _buildMemberActionIcon(
    IconData icon,
    Color bgColor,
    Color iconColor,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: widget.isDarkMode ? Colors.white.withOpacity(0.05) : bgColor,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 14,
          color: widget.isDarkMode ? Colors.white70 : iconColor,
        ),
      ),
    );
  }

  void _showMemberDetail(Map<String, dynamic> member) {
    final department = member['departments'] as Map<String, dynamic>?;
    final position = member['positions'] as Map<String, dynamic>?;

    bool hasFaceData = false;
    bool hasFingerprintData = false;
    bool hasRfidData = false;
    bool isHighAccuracy = false;
    final bioData = member['biometric_data'];
    final rfidData = member['rfid_cards'];
    Map<String, dynamic>? activeFaceData;
    Map<String, dynamic>? activeFingerData;

    if (rfidData is List) {
      hasRfidData = rfidData.any((r) => r['is_active'] == true);
    } else if (rfidData is Map) {
      hasRfidData = rfidData['is_active'] == true;
    }

    if (bioData is List) {
      activeFaceData = bioData.firstWhere(
        (b) =>
            (b['biometric_type'] == 'face' ||
                b['biometric_type'] == 'face_recognition') &&
            b['is_active'] == true,
        orElse: () => null,
      );
      activeFingerData = bioData.firstWhere(
        (b) => b['biometric_type'] == 'fingerprint' && b['is_active'] == true,
        orElse: () => null,
      );
    }

    if (activeFaceData != null) {
      hasFaceData = true;
      final template = activeFaceData['face_template'] as Map<String, dynamic>?;
      if (template != null && (template['totalAngles'] ?? 0) > 1) {
        isHighAccuracy = true;
      }
    }
    if (activeFingerData != null) {
      hasFingerprintData = true;
    }

    String deptName = AppLanguage.tr('Petugas.members.no_department');
    final posTitle = position?['title'] ?? position?['name'];
    if (department != null && posTitle != null) {
      deptName = department['name'];
    } else {
      deptName =
          department?['name'] ??
          AppLanguage.tr('Petugas.members.no_department');
    }

    final empId = member['employee_id'] ?? '#----';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFF5B259F),
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 0),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Stack(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: CircleAvatar(
                                radius: 40,
                                backgroundColor: Colors.grey.shade200,
                                backgroundImage:
                                    _getMemberPhotoUrl(member) != null
                                    ? CachedNetworkImageProvider(
                                        _getMemberPhotoUrl(member)!,
                                      )
                                    : null,
                                child: _getMemberPhotoUrl(member) == null
                                    ? const Icon(
                                        Icons.person,
                                        size: 40,
                                        color: Colors.grey,
                                      )
                                    : null,
                              ),
                            ),
                            Positioned(
                              bottom: 5,
                              right: 5,
                              child: Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _getMemberName(member),
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${AppLanguage.tr('Petugas.members.department')} $deptName',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    AppLanguage.tr(
                                      'Petugas.members.employee_id',
                                    ),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    '$empId',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          if (hasFaceData && !isHighAccuracy) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => FaceRegistrationPage(
                                  organizationMemberId: member['id'],
                                ),
                              ),
                            ).then((refresh) {
                              if (refresh == true) {
                                _loadOrganizationMembersOptimized();
                              }
                            });
                          } else {
                            _showRegistrationOptions(member);
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF312E81),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: const BorderSide(
                              color: Color(0xFF4F46E5),
                              width: 1.5,
                            ),
                          ),
                          elevation: 0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.face_rounded, size: 18),
                            const SizedBox(width: 6),
                            const Text(
                              'Registrasi Wajah',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (hasFaceData) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.check_circle,
                                color: Color(0xFF10B981),
                                size: 18,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => FingerprintRegistrationPage(
                                organizationMemberId: member['id'],
                                memberName: _getMemberName(member),
                              ),
                            ),
                          ).then((refresh) {
                            if (refresh == true) {
                              _loadOrganizationMembersOptimized();
                            }
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF312E81),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: const BorderSide(
                              color: Color(0xFF4F46E5),
                              width: 1.5,
                            ),
                          ),
                          elevation: 0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.fingerprint_rounded, size: 18),
                            const SizedBox(width: 6),
                            const Text(
                              'Registrasi Sidik Jari',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (hasFingerprintData) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.check_circle,
                                color: Color(0xFF10B981),
                                size: 18,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _showRfidRegistrationDialog(member);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF312E81),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: const BorderSide(
                              color: Color(0xFF4F46E5),
                              width: 1.5,
                            ),
                          ),
                          elevation: 0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.nfc_rounded, size: 18),
                            const SizedBox(width: 6),
                            const Text(
                              'Registrasi RFID',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (hasRfidData) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.check_circle,
                                color: Color(0xFF10B981),
                                size: 18,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showRfidRegistrationDialog(Map<String, dynamic> member) {
    String? scannedCardId;
    final TextEditingController rfidController = TextEditingController();
    final FocusNode rfidFocusNode = FocusNode();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      enableDrag: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future.delayed(const Duration(milliseconds: 50), () {
              rfidFocusNode.requestFocus();
              SystemChannels.textInput.invokeMethod('TextInput.hide');
            });

            rfidController.addListener(() {
              final text = rfidController.text;
              if (text.endsWith('\n') || text.endsWith('\r')) {
                final cardId = text.trim();
                if (cardId.isNotEmpty) {
                  setDialogState(() {
                    scannedCardId = cardId;
                    rfidController.clear();
                  });
                }
              }
            });

            return Container(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              decoration: BoxDecoration(
                color: widget.isDarkMode
                    ? const Color(0xFF1E1040)
                    : Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      AppLanguage.tr('Petugas.members.rfid_registration'),
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
                      _getMemberName(member),
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.isDarkMode
                            ? Colors.white54
                            : Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 24),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: scannedCardId == null
                          ? Column(
                              key: const ValueKey('scanning'),
                              children: [
                                Container(
                                  width: 80,
                                  height: 80,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: const Color(
                                      0xFF8938DF,
                                    ).withOpacity(0.1),
                                  ),
                                  child: const Icon(
                                    Icons.nfc_rounded,
                                    size: 40,
                                    color: Color(0xFF8938DF),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  AppLanguage.tr(
                                    'Petugas.members.tap_card_to_scan',
                                  ),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: widget.isDarkMode
                                        ? Colors.white70
                                        : Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              key: const ValueKey('scanned'),
                              children: [
                                Container(
                                  width: 80,
                                  height: 80,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: const Color(
                                      0xFF10B981,
                                    ).withOpacity(0.1),
                                  ),
                                  child: const Icon(
                                    Icons.check_circle_rounded,
                                    size: 40,
                                    color: Color(0xFF10B981),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  AppLanguage.tr(
                                    'Petugas.members.card_id_detected',
                                  ),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF10B981),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF8938DF,
                                    ).withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: const Color(
                                        0xFF8938DF,
                                      ).withOpacity(0.2),
                                    ),
                                  ),
                                  child: Text(
                                    scannedCardId!,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF8938DF),
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 0,
                      child: TextField(
                        controller: rfidController,
                        focusNode: rfidFocusNode,
                        autofocus: true,
                        readOnly: false,
                        showCursor: false,
                        onSubmitted: (value) {
                          final cardId = value.trim();
                          if (cardId.isNotEmpty) {
                            setDialogState(() {
                              scannedCardId = cardId;
                              rfidController.clear();
                            });
                          }
                          Future.delayed(const Duration(milliseconds: 50), () {
                            rfidFocusNode.requestFocus();
                            SystemChannels.textInput.invokeMethod(
                              'TextInput.hide',
                            );
                          });
                        },
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              side: BorderSide(color: Colors.grey.shade300),
                            ),
                            child: Text(
                              AppLanguage.tr('cancel'),
                              style: TextStyle(
                                fontSize: 13,
                                color: widget.isDarkMode
                                    ? Colors.white70
                                    : Colors.grey.shade700,
                              ),
                            ),
                          ),
                        ),
                        if (scannedCardId != null) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () async {
                                Navigator.pop(context);
                                _handleSaveRfid(member, scannedCardId!);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8938DF),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                elevation: 0,
                              ),
                              child: Text(
                                AppLanguage.tr(
                                  'Petugas.members.save_rfid_card',
                                ),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      rfidController.dispose();
      rfidFocusNode.dispose();
    });
  }

  Future<void> _handleSaveRfid(
    Map<String, dynamic> member,
    String cardNumber,
  ) async {
    _showProcessingOverlay(context, 'Menyimpan data kartu...');
    try {
      await _attendanceService.registerRfidCard(
        organizationMemberId: member['id'],
        cardNumber: cardNumber,
      );
      if (mounted) {
        Navigator.pop(context);
        _showSuccessSnackBar(
          AppLanguage.tr('Petugas.members.rfid_card_registered_success'),
        );
        _loadOrganizationMembersOptimized();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        _showErrorDialog(
          e.toString().contains('Exception:')
              ? e.toString().split('Exception:')[1].trim()
              : e.toString(),
        );
      }
    }
  }

  void _showRegistrationOptions(Map<String, dynamic> member) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLanguage.tr('Petugas.members.face_registration'),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: widget.isDarkMode ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppLanguage.tr('Petugas.members.choose_registration_method'),
              style: TextStyle(
                fontSize: 12,
                color: widget.isDarkMode ? Colors.white54 : Colors.grey,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: widget.isDarkMode
                    ? Colors.blue.withOpacity(0.15)
                    : Colors.blue.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: widget.isDarkMode
                      ? Colors.blue.withOpacity(0.3)
                      : Colors.blue.withOpacity(0.2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        size: 12,
                        color: Color(0xFF10B981),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Live Camera: 5 Sudut (Akurasi Tinggi)',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: widget.isDarkMode
                              ? Colors.white70
                              : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.check_circle, size: 12, color: primaryColor),
                      const SizedBox(width: 4),
                      Text(
                        'Upload Photo: 1 Foto Depan (Praktis)',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: widget.isDarkMode
                              ? Colors.white70
                              : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _buildOptionCard(
                    'Live Camera',
                    Icons.face_retouching_natural,
                    const Color(0xFF10B981),
                    () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => FaceRegistrationPage(
                            organizationMemberId: member['id'],
                          ),
                        ),
                      ).then((refresh) {
                        if (refresh == true) {
                          _loadOrganizationMembersOptimized();
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildOptionCard(
                    'Upload Photos',
                    Icons.photo_library_rounded,
                    primaryColor,
                    () {
                      Navigator.pop(context);
                      _registerFaceFromSinglePhoto(member);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildOptionCard(
              'Fingerprint Scanner',
              Icons.fingerprint_rounded,
              const Color(0xFFF59E0B),
              () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => FingerprintRegistrationPage(
                      organizationMemberId: member['id'],
                      memberName: _getMemberName(member),
                    ),
                  ),
                ).then((refresh) {
                  if (refresh == true) _loadOrganizationMembersOptimized();
                });
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionCard(
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: color.withOpacity(widget.isDarkMode ? 0.15 : 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: color.withOpacity(widget.isDarkMode ? 0.3 : 0.1),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: color,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _registerFaceFromSinglePhoto(Map<String, dynamic> member) async {
    final faceService = FaceRecognitionTFLiteService();
    final organizationMemberId = member['id'] as int?;

    if (organizationMemberId == null) return;

    try {
      await faceService.initialize();
      final ImagePicker picker = ImagePicker();

      final XFile? image = await showDialog<XFile?>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: widget.isDarkMode
              ? const Color(0xFF2D1B4E)
              : Colors.white,
          title: Text(
            'Pilih Foto Wajah Depan',
            style: TextStyle(
              color: widget.isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
          content: Text(
            'Pastikan foto:\n'
            '1. Wajah menghadap lurus ke depan\n'
            '2. Pencahayaan terang & jelas\n'
            '3. Tidak memakai masker/kacamata gelap',
            style: TextStyle(
              fontSize: 12,
              color: widget.isDarkMode ? Colors.white70 : Colors.black87,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () async {
                final img = await picker.pickImage(
                  source: ImageSource.gallery,
                  imageQuality: 100,
                );
                if (mounted) Navigator.pop(context, img);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8938DF),
                foregroundColor: Colors.white,
              ),
              child: const Text('Buka Galeri'),
            ),
          ],
        ),
      );

      if (image == null) return;

      if (!mounted) return;
      _showProcessingOverlay(context, 'Memproses foto & Menyimpan data...');

      try {
        final faceTemplate = await faceService.extractFaceFeatures(
          image.path,
          allowSidePose: false,
        );

        double qualityScore =
            (faceTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;
        if (qualityScore < 0.85) {
          throw Exception(
            'Kualitas foto kurang baik (Score: ${(qualityScore * 100).toInt()}%). Gunakan foto yang lebih jelas (Min. 85%).',
          );
        }

        final biometricService = BiometricService();
        final storageService = SupabaseStorageService();

        final processedFile = File(image.path);
        await storageService.uploadFaceTemplate(
          processedFile,
          organizationMemberId,
        );

        await biometricService.registerFaceTemplate(
          organizationMemberId: organizationMemberId,
          faceTemplate: faceTemplate,
        );

        if (mounted) {
          Navigator.of(context).pop();
          _showSuccessSnackBar(
            'Wajah ${_getMemberName(member)} berhasil didaftarkan (Single Mode)!',
          );
          _loadOrganizationMembersOptimized();
        }
      } catch (e) {
        if (mounted) {
          Navigator.of(context).pop();
        }
        _showErrorDialog('Gagal: $e');
      }
    } catch (e) {
      debugPrint('Single-photo reg error: $e');
      if (mounted) _showErrorDialog('Terjadi kesalahan sistem: $e');
    } finally {
      faceService.dispose();
    }
  }

  void _showProcessingOverlay(BuildContext context, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          color: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 14),
                Text(
                  message,
                  style: TextStyle(
                    color: widget.isDarkMode ? Colors.white70 : Colors.black87,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showEditProfileSheet(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>? ?? {};
    final userId = member['user_id'] as String?;
    final memberId = member['id'] as int?;

    if (userId == null || memberId == null) return;

    final TextEditingController displayNameController =
        TextEditingController(text: profile['display_name'] ?? '');
    final TextEditingController firstNameController =
        TextEditingController(text: profile['first_name'] ?? '');
    final TextEditingController lastNameController =
        TextEditingController(text: profile['last_name'] ?? '');
    final TextEditingController phoneController =
        TextEditingController(text: profile['phone'] ?? '');
    final TextEditingController employeeIdController =
        TextEditingController(text: member['employee_id'] ?? '');

    // ✅ AMBIL DATA RFID DARI MEMBER
    String? rfidNumber;
    final rfidData = member['rfid_cards'];
    if (rfidData is List && rfidData.isNotEmpty) {
      final activeRfid = rfidData.firstWhere((r) => r['is_active'] == true, orElse: () => null);
      if (activeRfid != null) rfidNumber = activeRfid['card_number']?.toString();
    } else if (rfidData is Map && rfidData['is_active'] == true) {
      rfidNumber = rfidData['card_number']?.toString();
    }

    int? selectedDeptId = member['department_id'] as int?;
    String selectedGender = profile['jenis_kelamin'] ?? 'male';

    List<Map<String, dynamic>> availableDepartments = [];
    bool isLoadingDepts = true;

    // Load real departments from Supabase
    Future<void> loadDepts(Function(void Function()) setLocalState) async {
      try {
        final organizationId = widget.memberData['organization_id'] as int;
        final res = await _supabase
            .from('departments')
            .select('id, name')
            .eq('organization_id', organizationId)
            .order('name');
        setLocalState(() {
          availableDepartments = List<Map<String, dynamic>>.from(res);
          isLoadingDepts = false;
        });
      } catch (e) {
        debugPrint('Error loading depts: $e');
        setLocalState(() => isLoadingDepts = false);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          if (isLoadingDepts) {
            loadDepts(setSheetState);
          }

          return Container(
            decoration: BoxDecoration(
              color: widget.isDarkMode ? const Color(0xFF1E1040) : Colors.white,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(32),
              ),
            ),
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Icon(
                        Icons.manage_accounts_rounded,
                        color: Color(0xFF8938DF),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Edit Profil Anggota',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: widget.isDarkMode
                              ? Colors.white
                              : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildEditField(
                    'Nama Tampilan',
                    displayNameController,
                    Icons.badge_outlined,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _buildEditField(
                          'Nama Depan',
                          firstNameController,
                          Icons.person_outline,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildEditField(
                          'Nama Belakang',
                          lastNameController,
                          Icons.person_outline,
                        ),
                      ),
                    ],
                  ),
                  _buildEditField(
                    'Nomor Telepon',
                    phoneController,
                    Icons.phone_android_rounded,
                    keyboardType: TextInputType.phone,
                  ),
                  
                  // --- DEPARTMENT SELECTOR ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Departemen',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                        ),
                      ),
                      GestureDetector(
                        onTap: () async {
                          final newDeptName = await _showCreateDeptDialog();
                          if (newDeptName != null && newDeptName.isNotEmpty) {
                            _showProcessingOverlay(context, 'Menambah departemen...');
                            try {
                              final orgId = widget.memberData['organization_id'] as int;
                              
                              // ✅ PERBAIKAN: Tambahkan 'code' otomatis dari nama
                              final String deptCode = newDeptName.toUpperCase().replaceAll(' ', '_');
                              
                              final res = await _supabase.from('departments').insert({
                                'name': newDeptName,
                                'code': deptCode, // Tambahkan ini agar database menerima
                                'organization_id': orgId,
                              }).select().single();
                              
                              if (mounted) {
                                Navigator.pop(context); // Close overlay
                                _showSuccessSnackBar('Departemen "$newDeptName" berhasil ditambahkan!');
                                
                                // ✅ PERBAIKAN: Masukkan ke list lokal dulu agar dropdown tidak crash (Layar Merah)
                                setSheetState(() {
                                  final newDept = {
                                    'id': res['id'],
                                    'name': res['name'],
                                  };
                                  
                                  // Update list lokal
                                  availableDepartments.add(newDept);
                                  availableDepartments.sort((a, b) => 
                                    (a['name'] as String).compareTo(b['name'] as String));
                                  
                                  // Sekarang aman untuk set ID karena item sudah ada di list
                                  selectedDeptId = res['id'] as int;
                                });
                              }
                            } catch (e) {
                              if (mounted) {
                                Navigator.pop(context);
                                _showErrorDialog('Gagal menambah departemen: $e');
                              }
                            }
                          }
                        },
                        child: Text(
                          '+ Tambah Baru',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF8938DF),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode
                          ? Colors.white.withOpacity(0.05)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int?>(
                        // ✅ PERBAIKAN: Pastikan value tersedia di items agar tidak crash (Layar Merah)
                        value: (isLoadingDepts || !availableDepartments.any((d) => d['id'] == selectedDeptId)) 
                            ? null 
                            : selectedDeptId,
                        isExpanded: true,
                        hint: Text(
                          isLoadingDepts ? 'Memuat...' : 'Pilih Departemen',
                          style: const TextStyle(fontSize: 14),
                        ),
                        dropdownColor: widget.isDarkMode
                            ? const Color(0xFF2D1B4E)
                            : Colors.white,
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('Tidak Ada Departemen', style: TextStyle(fontSize: 14)),
                          ),
                          ...availableDepartments.map((dept) => DropdownMenuItem<int?>(
                                value: dept['id'] as int,
                                child: Text(dept['name'] as String, style: const TextStyle(fontSize: 14)),
                              )),
                        ],
                        onChanged: (val) => setSheetState(() => selectedDeptId = val),
                      ),
                    ),
                  ),

                  _buildEditField(
                    'ID Karyawan',
                    employeeIdController,
                    Icons.confirmation_number_outlined,
                    suffixIcon: rfidNumber != null 
                      ? IconButton(
                          icon: const Icon(Icons.nfc_rounded, color: Color(0xFF8938DF)),
                          tooltip: 'Gunakan dari kartu RFID',
                          onPressed: () {
                            employeeIdController.text = rfidNumber!;
                            _showSuccessSnackBar('ID disinkronkan dari kartu RFID!');
                          },
                        )
                      : null,
                  ),
                  const Text(
                    'Jenis Kelamin',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _buildGenderOption(
                        'Laki-laki',
                        'male',
                        selectedGender,
                        (val) => setSheetState(() => selectedGender = val),
                      ),
                      const SizedBox(width: 12),
                      _buildGenderOption(
                        'Perempuan',
                        'female',
                        selectedGender,
                        (val) => setSheetState(() => selectedGender = val),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.pop(context);
                        _handleUpdateProfile(
                          userId,
                          memberId,
                          {
                            'display_name': displayNameController.text.trim(),
                            'first_name': firstNameController.text.trim(),
                            'last_name': lastNameController.text.trim(),
                            'phone': phoneController.text.trim(),
                            'jenis_kelamin': selectedGender,
                          },
                          employeeIdController.text.trim(),
                          selectedDeptId,
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8938DF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Simpan Perubahan',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEditField(
    String label,
    TextEditingController controller,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
    Widget? suffixIcon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: widget.isDarkMode
                ? Colors.white.withOpacity(0.05)
                : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            style: TextStyle(
              color: widget.isDarkMode ? Colors.white : Colors.black87,
              fontSize: 14,
            ),
            decoration: InputDecoration(
              prefixIcon: Icon(icon, size: 20, color: const Color(0xFF8938DF)),
              suffixIcon: suffixIcon,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGenderOption(
    String label,
    String value,
    String selected,
    Function(String) onSelect,
  ) {
    final isSelected = selected == value;
    return Expanded(
      child: InkWell(
        onTap: () => onSelect(value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF8938DF).withOpacity(0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? const Color(0xFF8938DF) : Colors.grey.shade300,
              width: 1.5,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? const Color(0xFF8938DF) : Colors.grey,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleUpdateProfile(
    String userId,
    int memberId,
    Map<String, dynamic> profileData,
    String employeeId,
    int? departmentId,
  ) async {
    _showProcessingOverlay(context, 'Memperbarui profil...');
    try {
      await _supabase.from('user_profiles').update(profileData).eq('id', userId);

      await _supabase
          .from('organization_members')
          .update({
            'employee_id': employeeId,
            'department_id': departmentId,
          })
          .eq('id', memberId);

      if (mounted) {
        Navigator.pop(context);
        _showSuccessSnackBar('Profil berhasil diperbarui!');
        _loadOrganizationMembersOptimized();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        _showErrorDialog('Gagal memperbarui profil: $e');
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: widget.isDarkMode
            ? const Color(0xFF2D1B4E)
            : Colors.white,
        title: Text(
          'Gagal',
          style: TextStyle(
            color: widget.isDarkMode ? Colors.white : Colors.black87,
          ),
        ),
        content: Text(
          message,
          style: TextStyle(
            color: widget.isDarkMode ? Colors.white70 : Colors.black87,
            fontSize: 13,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<String?> _showCreateDeptDialog() async {
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: widget.isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        title: Text(
          'Tambah Departemen Baru',
          style: TextStyle(
            color: widget.isDarkMode ? Colors.white : Colors.black87,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Masukkan nama departemen baru untuk organisasi ini.',
              style: TextStyle(
                fontSize: 13,
                color: widget.isDarkMode ? Colors.white70 : Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              style: TextStyle(
                color: widget.isDarkMode ? Colors.white : Colors.black87,
              ),
              decoration: InputDecoration(
                hintText: 'Misal: IT, Marketing, HRD',
                hintStyle: const TextStyle(fontSize: 14, color: Colors.grey),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8938DF),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceTab() {
    return Container(
      color: widget.isDarkMode ? const Color(0xFF1F0B38) : Colors.grey.shade50,
      child: RefreshIndicator(
        onRefresh: () async {
          await _applyFilters();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: _buildFilterSection(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: widget.isDarkMode
                        ? const Color(0xFF2D1B4E)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(
                          widget.isDarkMode ? 0.2 : 0.05,
                        ),
                        blurRadius: 15,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_isLoadingPerformance)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 40),
                            child: CircularProgressIndicator(
                              color: Color(0xFF8B5CF6),
                            ),
                          ),
                        )
                      else ...[
                        ..._buildPerformersList(),
                      ],
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPerformersList() {
    final sortedList = List<Map<String, dynamic>>.from(_membersPerformance)
      ..sort((a, b) {
        final aStats = a['performance_stats'] as Map<String, dynamic>;
        final bStats = b['performance_stats'] as Map<String, dynamic>;
        if (_selectedSortBy == 'score') {
          return (bStats['productivity_score'] as num).compareTo(
            aStats['productivity_score'] as num,
          );
        } else {
          return (bStats['present_days'] as num).compareTo(
            aStats['present_days'] as num,
          );
        }
      });

    final displayList = sortedList.take(10).toList();

    if (displayList.isEmpty) {
      return [
        const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Text('No performance data available'),
          ),
        ),
      ];
    }

    return List.generate(displayList.length, (index) {
      final performer = displayList[index];
      final performance =
          performer['performance_stats'] as Map<String, dynamic>;

      return _buildPerformerListItem(
        performer,
        performance,
        index + 1,
        index < 3,
      );
    });
  }

  Widget _buildFilterSection() {
    final periods = {
      'today': AppLanguage.tr('today'),
      'yesterday': AppLanguage.tr('yesterday'),
      'this_week': AppLanguage.tr('this_week'),
      'last_week': AppLanguage.tr('last_week'),
      'this_month': AppLanguage.tr('this_month'),
      'last_month': AppLanguage.tr('last_month'),
      'this_year': AppLanguage.tr('this_year'),
      'last_year': AppLanguage.tr('last_year'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              ...periods.entries.map((entry) {
                final key = entry.key;
                final label = entry.value;
                final isSelected = _selectedTimePeriod == key;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(label),
                    labelStyle: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected
                          ? Colors.white
                          : (widget.isDarkMode
                                ? Colors.white70
                                : Colors.black87),
                    ),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _selectedTimePeriod = key);
                        _applyFilters();
                      }
                    },
                    backgroundColor: widget.isDarkMode
                        ? Colors.white10
                        : Colors.grey.shade100,
                    selectedColor: const Color(0xFF8938DF),
                    checkmarkColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                      side: BorderSide(
                        color: isSelected
                            ? Colors.transparent
                            : (widget.isDarkMode
                                  ? Colors.white10
                                  : Colors.grey.shade200),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: widget.isDarkMode
                ? Colors.white.withOpacity(0.03)
                : Colors.grey.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.isDarkMode ? Colors.white10 : Colors.grey.shade100,
            ),
          ),
          child: Row(
            children: [
              Text(
                'SORT BY',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  color: widget.isDarkMode
                      ? Colors.white38
                      : Colors.grey.shade500,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedSortBy,
                    isExpanded: true,
                    isDense: true,
                    icon: Icon(
                      Icons.sort_rounded,
                      size: 14,
                      color: widget.isDarkMode ? Colors.white38 : Colors.grey,
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: widget.isDarkMode
                          ? Colors.white70
                          : Colors.black87,
                    ),
                    dropdownColor: widget.isDarkMode
                        ? const Color(0xFF2D1B4E)
                        : Colors.white,
                    items:
                        {
                              'score': AppLanguage.tr('score'),
                              'logs': AppLanguage.tr('logs'),
                            }.entries
                            .map(
                              (entry) => DropdownMenuItem(
                                value: entry.key,
                                child: Text(entry.value),
                              ),
                            )
                            .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedSortBy = value);
                        _applyFilters();
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPerformerListItem(
    Map<String, dynamic> member,
    Map<String, dynamic> performance,
    int rank,
    bool isTopPerformer,
  ) {
    final totalAttendance = performance['present_days'] as num? ?? 0;
    final totalWorkMinutes = performance['total_work_minutes'] as num? ?? 0;
    final workHours = (totalWorkMinutes.toDouble() / 60).toStringAsFixed(1);
    final productivityScore =
        performance['productivity_score'] as double? ?? 0.0;

    final rankColors = [
      const Color(0xFF8B5CF6),
      const Color(0xFF9333EA),
      const Color(0xFFA855F7),
    ];
    final circleColor = rank <= 3
        ? rankColors[rank - 1]
        : (widget.isDarkMode ? Colors.white12 : Colors.grey.shade100);
    final textColor = rank <= 3
        ? Colors.white
        : (widget.isDarkMode ? Colors.white70 : Colors.black87);

    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: widget.isDarkMode
                ? Colors.white.withOpacity(0.05)
                : Colors.grey.shade100,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: circleColor,
              shape: BoxShape.circle,
              boxShadow: rank <= 3
                  ? [
                      BoxShadow(
                        color: circleColor.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              '$rank',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _getMemberName(member),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: widget.isDarkMode ? Colors.white : Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 11,
                      color: const Color(0xFFA855F7),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$totalAttendance ${AppLanguage.tr('logs')}',
                      style: TextStyle(
                        fontSize: 10,
                        color: widget.isDarkMode
                            ? Colors.white54
                            : Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(
                      Icons.access_time,
                      size: 11,
                      color: const Color(0xFFA855F7),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$workHours${AppLanguage.tr('hrs_short')}',
                      style: TextStyle(
                        fontSize: 10,
                        color: widget.isDarkMode
                            ? Colors.white54
                            : Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(
                    0xFF8B5CF6,
                  ).withOpacity(widget.isDarkMode ? 0.2 : 0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _formatPercentage(productivityScore),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF8938DF),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                AppLanguage.tr('score').toUpperCase(),
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w900,
                  color: widget.isDarkMode
                      ? Colors.white24
                      : Colors.grey.shade400,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;

  _SliverTabBarDelegate({required this.child, required this.height});

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return false;
  }
}
