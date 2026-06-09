import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/petugas_bottom_nav.dart';
import '../../helpers/rfid_mode_helper.dart';
import 'petugas_members_page.dart';
import 'petugas_profile_page.dart';

class PetugasReportsPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;
  final bool isDarkMode;

  const PetugasReportsPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
    this.isDarkMode = false,
  });

  @override
  State<PetugasReportsPage> createState() => _PetugasReportsPageState();
}

class _PetugasReportsPageState extends State<PetugasReportsPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  int _currentNavIndex = 2;
  String _attendanceMode = 'face';
  bool _isCalendarView = true;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  int _hadirCount = 0;
  int _absenCount = 0;
  int _terlambatCount = 0;
  List<Map<String, dynamic>> _reports = [];

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    await _loadAttendanceMode();
    await _fetchStats();
    await _fetchReports();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _fetchStats() async {
    final orgId = widget.memberData['organization_id'];
    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_focusedDay);
      final res = await _supabase
          .from('attendance_records')
          .select('status, organization_members!inner(organization_id)')
          .eq('attendance_date', dateStr)
          .eq('organization_members.organization_id', orgId);

      int hadir = 0;
      int terlambat = 0;
      for (var row in res as List) {
        if (row['status'] == 'present') hadir++;
        if (row['status'] == 'late') terlambat++;
      }

      if (mounted) {
        setState(() {
          _hadirCount = hadir;
          _terlambatCount = terlambat;
          _absenCount = 0; // Requires member list comparison
        });
      }
    } catch (e) {
      debugPrint('Error fetching stats: $e');
    }
  }

  Future<void> _fetchReports() async {
    final orgId = widget.memberData['organization_id'];
    try {
      final res = await _supabase
          .from('attendance_records')
          .select('''
            *,
            organization_members!inner(
              id,
              user_profiles(display_name, profile_photo_url)
            )
          ''')
          .eq('organization_members.organization_id', orgId)
          .order('attendance_date', ascending: false)
          .limit(20);

      if (mounted) {
        setState(() {
          _reports = List<Map<String, dynamic>>.from(res);
        });
      }
    } catch (e) {
      debugPrint('Error fetching reports: $e');
    }
  }

  Future<void> _loadAttendanceMode() async {
    final orgId = widget.memberData['organization_id'];
    if (orgId != null) {
      final mode = await RfidModeHelper.getAttendanceMode(orgId);
      if (mounted) setState(() => _attendanceMode = mode);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.isDarkMode ? const Color(0xFF1F0B38) : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('Laporan', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: const Color(0xFF8938DF),
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF8938DF), Color(0xFF4A1E79)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () {},
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildStatsCard(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: _buildViewToggle(),
            ),
            _buildFilterSection(),
            const SizedBox(height: 16),
            if (_isCalendarView) _buildCalendarView() else _buildListView(),
            const SizedBox(height: 20),
          ],
        ),
      ),
      bottomNavigationBar: PetugasBottomNav(
        currentIndex: _currentNavIndex,
        onNavigationTap: (i) {
          if (i == _currentNavIndex) return;
          if (i == 0) {
            Navigator.pop(context);
          } else if (i == 1) {
            Navigator.pushReplacement(
              context,
              PageRouteBuilder(
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (context, _, __) => PetugasMembersPage(
                  organizationMemberId: widget.organizationMemberId,
                  memberData: widget.memberData,
                  userProfile: widget.userProfile,
                  isDarkMode: widget.isDarkMode,
                ),
              ),
            );
          } else if (i == 3) {
            Navigator.pushReplacement(
              context,
              PageRouteBuilder(
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (context, _, __) => PetugasProfilePage(
                  organizationMemberId: widget.organizationMemberId,
                  memberData: widget.memberData,
                  userProfile: widget.userProfile,
                  isDarkMode: widget.isDarkMode,
                ),
              ),
            );
          }
          setState(() => _currentNavIndex = i);
        },
        isDarkMode: widget.isDarkMode,
        attendanceMode: _attendanceMode,
      ),
    );
  }

  Widget _buildStatsCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem(Icons.check_circle, 'HADIR', '$_hadirCount', const Color(0xFF10B981)),
          Container(width: 1, height: 40, color: Colors.grey.shade100),
          _buildStatItem(Icons.cancel, 'ABSEN', '$_absenCount', const Color(0xFFEF4444)),
          Container(width: 1, height: 40, color: Colors.grey.shade100),
          _buildStatItem(Icons.access_time_filled, 'TERLAMBAT', '$_terlambatCount', const Color(0xFF0D9488)),
        ],
      ),
    );
  }

  Widget _buildStatItem(IconData icon, String label, String value, Color color) {
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
      ],
    );
  }

  Widget _buildViewToggle() {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _isCalendarView = true),
              child: Container(
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: _isCalendarView ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: _isCalendarView ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4)] : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  'Tampilan Kalender',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: _isCalendarView ? FontWeight.bold : FontWeight.w500,
                    color: _isCalendarView ? const Color(0xFF4A1E79) : Colors.grey.shade600,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _isCalendarView = false),
              child: Container(
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: !_isCalendarView ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: !_isCalendarView ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4)] : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  'Tampilan Daftar',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: !_isCalendarView ? FontWeight.bold : FontWeight.w500,
                    color: !_isCalendarView ? const Color(0xFF4A1E79) : Colors.grey.shade600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Filter', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              TextButton(onPressed: () {}, child: const Text('HAPUS SEMUA', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF4A1E79)))),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_month_outlined, color: Colors.grey.shade400, size: 20),
                const SizedBox(width: 12),
                const Expanded(child: Text('May 2026', style: TextStyle(fontWeight: FontWeight.w500))),
                Icon(Icons.keyboard_arrow_down, color: Colors.grey.shade400),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Cari anggota...',
              hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
              prefixIcon: Icon(Icons.search, color: Colors.grey.shade400),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarView() {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: TableCalendar(
            firstDay: DateTime.utc(2020, 10, 16),
            lastDay: DateTime.utc(2030, 3, 14),
            focusedDay: _focusedDay,
            calendarFormat: CalendarFormat.month,
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                _selectedDay = selectedDay;
                _focusedDay = focusedDay;
              });
              _loadData();
            },
            headerStyle: const HeaderStyle(
              formatButtonVisible: false,
              titleCentered: true,
              titleTextStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            calendarStyle: CalendarStyle(
              todayDecoration: BoxDecoration(color: const Color(0xFF8938DF).withOpacity(0.2), shape: BoxShape.circle),
              selectedDecoration: const BoxDecoration(color: Color(0xFF4A1E79), shape: BoxShape.circle),
              todayTextStyle: const TextStyle(color: Color(0xFF4A1E79), fontWeight: FontWeight.bold),
              weekendTextStyle: const TextStyle(color: Colors.red),
              markerDecoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Acara Harian', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(color: Color(0xFF4A1E79), shape: BoxShape.circle),
                child: Text('${_reports.where((r) => isSameDay(DateTime.parse(r['attendance_date']), _selectedDay)).length}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ..._reports
            .where((r) => isSameDay(DateTime.parse(r['attendance_date']), _selectedDay))
            .map((r) => _buildReportItemFromData(r)),
      ],
    );
  }

  Widget _buildListView() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_reports.isEmpty) return const Center(child: Text('Tidak ada laporan'));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Laporan Kehadiran', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFF4A1E79), borderRadius: BorderRadius.circular(10)),
                child: Text('${_reports.length}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ..._reports.map((report) => _buildReportItemFromData(report)),
      ],
    );
  }

  Widget _buildReportItemFromData(Map<String, dynamic> report) {
    final member = report['organization_members'];
    final profile = member?['user_profiles'];
    final status = (report['status'] ?? 'unknown').toString().toUpperCase();
    final checkIn = report['actual_check_in'] ?? '-';
    final lateMinutes = report['late_minutes'] ?? 0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFFF3E8FF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: profile?['profile_photo_url'] != null
                  ? CachedNetworkImage(imageUrl: profile['profile_photo_url'], fit: BoxFit.cover)
                  : Image.asset('assets/logo/app_icon_new.png', fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(profile?['display_name'] ?? 'Unknown Member', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1F2937))),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.access_time_rounded, size: 14, color: Colors.grey.shade400),
                    const SizedBox(width: 5),
                    Text(checkIn.length > 16 ? checkIn.substring(0, 16) : checkIn, style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: status == 'LATE' ? const Color(0xFFFEF3C7) : const Color(0xFFD1FAE5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: status == 'LATE' ? const Color(0xFFFDE68A) : const Color(0xFF10B981).withOpacity(0.2)),
                ),
                child: Text(status, style: TextStyle(color: status == 'LATE' ? const Color(0xFF92400E) : const Color(0xFF065F46), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
              ),
              if (lateMinutes > 0) ...[
                const SizedBox(height: 5),
                Text('+${lateMinutes}m Late', style: const TextStyle(color: Color(0xFFB45309), fontSize: 10, fontWeight: FontWeight.bold)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
