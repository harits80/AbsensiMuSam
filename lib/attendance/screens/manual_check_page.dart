import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../helpers/timezone_helper.dart';
import '../../services/offline_database_service.dart';
import '../services/attendance_sync_service.dart';
import '../services/attendance_service.dart';
import '../../models/offline_attendance.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';

class ManualCheckPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final String? initialShiftName;
  final String? sourceMode;

  const ManualCheckPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.initialShiftName,
    this.sourceMode,
  });

  @override
  State<ManualCheckPage> createState() => _ManualCheckPageState();
}

class _ManualCheckPageState extends State<ManualCheckPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceService _attendanceService = AttendanceService();

  // Form fields
  int? _selectedEmployeeId;
  String? _selectedEmployeeName;
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();
  String _eventType = 'check_in'; // check_in or check_out
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();

  // Data
  List<Map<String, dynamic>> _employees = [];
  List<Map<String, dynamic>> _filteredEmployees = [];
  bool _isLoadingEmployees = true;
  bool _isSubmitting = false;

  bool _isOnline = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  int? _organizationId;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _organizationId = widget.memberData['organization_id'] as int?;
    _loadEmployees();
    _checkConnectivity();
  }

  Future<void> _checkConnectivity() async {
    final result = await Connectivity().checkConnectivity();
    if (mounted) {
      setState(() {
        _isOnline = result.isNotEmpty && !result.contains(ConnectivityResult.none);
      });
    }

    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) {
        setState(() {
          _isOnline = results.isNotEmpty && !results.contains(ConnectivityResult.none);
        });
      }
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _notesController.dispose();
    _locationController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEmployees() async {
    if (_organizationId == null) {
      if (mounted) setState(() => _isLoadingEmployees = false);
      return;
    }

    try {
      if (mounted) setState(() => _isLoadingEmployees = true);

      final response = await _supabase
          .from('organization_members')
          .select('''
            id,
            employee_id,
            user_id,
            user_profiles!inner(
              id,
              first_name,
              last_name,
              display_name,
              profile_photo_url
            )
          ''')
          .eq('organization_id', _organizationId!)
          .eq('is_active', true)
          .order('user_profiles(display_name)', ascending: true);

      if (mounted) {
        setState(() {
          _employees = List<Map<String, dynamic>>.from(response);
          _filteredEmployees = _employees;
          _isLoadingEmployees = false;
        });

        // Cache members for offline manual entry
        await _offlineDb.cacheOrganizationMembers(_organizationId!, _employees);
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading employees: $e');

      // Try fallback from cache
      if (_organizationId != null) {
        final cachedMembers = await _offlineDb.getOrganizationMembers(
          _organizationId!,
        );
        if (mounted && cachedMembers != null) {
          setState(() {
            _employees = List<Map<String, dynamic>>.from(cachedMembers);
            _filteredEmployees = _employees;
            _isLoadingEmployees = false;
          });
          debugPrint('💾 Using cached members (${_employees.length} found)');
        } else if (mounted) {
          setState(() => _isLoadingEmployees = false);
        }
      } else if (mounted) {
        setState(() => _isLoadingEmployees = false);
      }
    }
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF9333EA),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _selectTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF9333EA),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedTime) {
      setState(() => _selectedTime = picked);
    }
  }

  String _getEmployeeName(Map<String, dynamic> employee) {
    final profile = employee['user_profiles'] as Map<String, dynamic>?;
    if (profile == null) return 'Unknown Employee';
    final displayName = profile['display_name'] as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }
    final first = profile['first_name'] as String? ?? '';
    final last = profile['last_name'] as String? ?? '';
    return '$first $last'.trim();
  }

  void _filterEmployees(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredEmployees = _employees;
      } else {
        _filteredEmployees = _employees.where((employee) {
          final name = _getEmployeeName(employee).toLowerCase();
          final id = (employee['employee_id'] as String? ?? '').toLowerCase();
          return name.contains(query.toLowerCase()) ||
              id.contains(query.toLowerCase());
        }).toList();
      }
    });
  }

  Future<void> _showEmployeeSelectionDialog() async {
    _searchController.clear();
    _filteredEmployees = _employees;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            width: double.infinity,
            height: MediaQuery.of(context).size.height * 0.7,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Select Employee',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    prefixIcon: const Icon(
                      Icons.search,
                      color: Color(0xFF9333EA),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onChanged: (val) =>
                      setDialogState(() => _filterEmployees(val)),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: _filteredEmployees.length,
                    itemBuilder: (context, idx) {
                      final employee = _filteredEmployees[idx];
                      final name = _getEmployeeName(employee);
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person)),
                        title: Text(name),
                        subtitle: Text('ID: ${employee['employee_id'] ?? '-'}'),
                        onTap: () {
                          setState(() {
                            _selectedEmployeeId = employee['id'];
                            _selectedEmployeeName = name;
                          });
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submitAttendance() async {
    if (_selectedEmployeeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an employee')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final eventDateTime = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );

      // Prepare data for attendance service
      final rawData = {
        'notes': _notesController.text,
        'manual_address': _locationController.text,
        'offline_timestamp': TimezoneHelper.formatUtcForSupabase(eventDateTime),
        'synced_from_offline': false,
      };

      bool syncSuccess = false;
      if (_isOnline) {
        try {
          if (_eventType == 'check_in') {
            await _attendanceService.checkIn(
              organizationMemberId: _selectedEmployeeId!,
              method: widget.sourceMode ?? 'manual',
              photoUrl: '',
              location: _locationController.text.isNotEmpty
                  ? {'address': _locationController.text, 'type': 'manual'}
                  : null,
              rawData: rawData,
            );
          } else {
            await _attendanceService.checkOut(
              organizationMemberId: _selectedEmployeeId!,
              method: widget.sourceMode ?? 'manual',
              photoUrl: '',
              location: _locationController.text.isNotEmpty
                  ? {'address': _locationController.text, 'type': 'manual'}
                  : null,
              rawData: rawData,
            );
          }
          syncSuccess = true;
          debugPrint('✅ Online manual attendance recorded');
        } catch (e) {
          debugPrint('⚠️ Online manual attempt failed: $e');
        }
      }

      // Save offline record as fallback/history
      final record = OfflineAttendance(
        organizationMemberId: _selectedEmployeeId,
        userName: _selectedEmployeeName,
        cardNumber: widget.sourceMode == 'face_recognition_kiosk'
            ? '' // Face mode doesn't need card number
            : 'MANUAL_$_selectedEmployeeId',
        eventType: _eventType,
        method: widget.sourceMode ?? 'manual',
        workTimeMode: widget.initialShiftName, // <-- ADDED THIS
        timestamp: TimezoneHelper.formatUtcForSupabase(eventDateTime),
        notes: _notesController.text,
        isSynced: syncSuccess,
      );

      final id = await _offlineDb.insertAttendance(record);

      if (id != 0) {
        debugPrint(
          '💾 Manual attendance saved to local DB (Synced: $syncSuccess)',
        );

        // Trigger background sync for other pending records
        if (!syncSuccess) {
          AttendanceSyncService().syncPendingAttendances();
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                syncSuccess
                    ? 'Attendance recorded successfully!'
                    : 'Attendance recorded offline (Safe for Sync)!',
              ),
              backgroundColor: syncSuccess ? Colors.green : Colors.blue,
            ),
          );
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      debugPrint('Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Aesthetic Colors from screenshots
    final bgColor = isDark ? const Color(0xFF130F26) : const Color(0xFFFBFBFF);
    final cardColor = isDark ? const Color(0xFF1E1E2C) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1E1E2C);
    final accentColor = const Color(0xFF9333EA);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: textColor, size: 32),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Manual Check',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
      ),
      body: _isLoadingEmployees
          ? Center(child: CircularProgressIndicator(color: accentColor))
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionTitle('Select Employee', textColor),
                  const SizedBox(height: 12),
                  _buildEmployeeSelector(cardColor, textColor, accentColor),

                  const SizedBox(height: 24),
                  if (widget.sourceMode != null ||
                      widget.initialShiftName != null) ...[
                    _buildSectionTitle('Attendance Context', textColor),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        children: [
                          if (widget.sourceMode != null)
                            Row(
                              children: [
                                Icon(
                                  Icons.devices,
                                  color: accentColor,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Mode: ${widget.sourceMode}',
                                  style: TextStyle(
                                    color: textColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          if (widget.sourceMode != null &&
                              widget.initialShiftName != null)
                            const SizedBox(height: 8),
                          if (widget.initialShiftName != null)
                            Row(
                              children: [
                                Icon(
                                  Icons.schedule,
                                  color: accentColor,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Shift: ${widget.initialShiftName}',
                                  style: TextStyle(
                                    color: textColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  _buildSectionTitle('Attendance Type', textColor),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildTypeCard(
                          'Check In',
                          'check_in',
                          Icons.login_rounded,
                          isDark,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildTypeCard(
                          'Check Out',
                          'check_out',
                          Icons.logout_rounded,
                          isDark,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                  _buildSectionTitle('Date & Time', textColor),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildDateTimeBox(
                          DateFormat('dd MMM yyyy').format(_selectedDate),
                          Icons.calendar_month_outlined,
                          isDark,
                          _selectDate,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildDateTimeBox(
                          _selectedTime.format(context),
                          Icons.access_time_rounded,
                          isDark,
                          _selectTime,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                  _buildSectionTitle('Location', textColor, isOptional: true),
                  const SizedBox(height: 12),
                  _buildTextField(
                    _locationController,
                    'Enter location',
                    Icons.location_on_outlined,
                    isDark,
                  ),

                  const SizedBox(height: 24),
                  _buildSectionTitle('Notes', textColor, isOptional: true),
                  const SizedBox(height: 12),
                  _buildTextField(
                    _notesController,
                    'Add any notes or remarks',
                    Icons.notes_rounded,
                    isDark,
                    maxLines: 4,
                  ),

                  const SizedBox(height: 40),
                  _buildSubmitButton(accentColor),
                  const SizedBox(height: 20),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionTitle(
    String title,
    Color color, {
    bool isOptional = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        if (isOptional)
          Text(
            '(Optional)',
            style: TextStyle(color: color.withValues(alpha: 0.5), fontSize: 12),
          ),
      ],
    );
  }

  Widget _buildEmployeeSelector(
    Color cardColor,
    Color textColor,
    Color accentColor,
  ) {
    return InkWell(
      onTap: _showEmployeeSelectionDialog,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: textColor.withValues(alpha: 0.1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(Icons.person_outline, color: accentColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _selectedEmployeeName ?? 'Choose an employee',
                style: TextStyle(
                  color: textColor.withValues(
                    alpha: _selectedEmployeeName == null ? 0.5 : 1.0,
                  ),
                  fontSize: 15,
                ),
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              color: textColor.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeCard(String label, String type, IconData icon, bool isDark) {
    final isSelected = _eventType == type;
    final accentColor = const Color(0xFF9333EA);

    return InkWell(
      onTap: () => setState(() => _eventType = type),
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 140,
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark
                    ? accentColor.withValues(alpha: 0.1)
                    : accentColor.withValues(alpha: 0.05))
              : (isDark ? const Color(0xFF1E1E2C) : Colors.white),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? accentColor.withValues(alpha: 0.8)
                : Colors.transparent,
            width: 2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.3),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ]
              : [],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 32,
              color: isSelected
                  ? accentColor
                  : (isDark ? Colors.white38 : Colors.black26),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? accentColor
                    : (isDark ? Colors.white38 : Colors.black26),
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateTimeBox(
    String text,
    IconData icon,
    bool isDark,
    VoidCallback onTap,
  ) {
    final cardColor = isDark ? const Color(0xFF1E1E2C) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1E1E2C);
    final accentColor = const Color(0xFF9333EA);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: textColor.withValues(alpha: 0.1)),
        ),
        child: Row(
          children: [
            Icon(icon, color: accentColor, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String hint,
    IconData icon,
    bool isDark, {
    int maxLines = 1,
  }) {
    final cardColor = isDark ? const Color(0xFF1E1E2C) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1E1E2C);

    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: textColor.withValues(alpha: 0.1)),
      ),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        style: TextStyle(color: textColor),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: textColor.withValues(alpha: 0.3)),
          prefixIcon: Icon(icon, color: textColor.withValues(alpha: 0.4)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
    );
  }

  Widget _buildSubmitButton(Color accentColor) {
    return Container(
      width: double.infinity,
      height: 60,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [accentColor, accentColor.withValues(alpha: 0.8)],
        ),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: _isSubmitting ? null : _submitAttendance,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: _isSubmitting
            ? const CircularProgressIndicator(color: Colors.white)
            : const Text(
                'Submit Attendance',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
      ),
    );
  }
}
