// lib/attendance/screens/fingerprint_attendance_page.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/language_helper.dart';
import '../../helpers/sound_helper.dart';
import '../../helpers/timezone_helper.dart';
import '../../services/offline_database_service.dart';
import '../services/attendance_sync_service.dart';
import '../services/fingerprint_service.dart';
import '../services/biometric_service.dart';
import '../services/attendance_service.dart';
import '../../models/work_schedule_models.dart';

class FingerprintAttendancePage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const FingerprintAttendancePage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
  });

  @override
  State<FingerprintAttendancePage> createState() =>
      _FingerprintAttendancePageState();
}

class _FingerprintAttendancePageState extends State<FingerprintAttendancePage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final AttendanceService _attendanceService = AttendanceService();
  final FingerprintService _fingerprintService = FingerprintService();
  final BiometricService _biometricService = BiometricService();
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  String? _organizationName;

  final List<_AttendanceEntry> _entries = [];
  Timer? _clockTimer;
  DateTime _currentTime = DateTime.now();

  String _attendanceMode = 'check_in';
  Map<String, dynamic>? _selectedMode;
  List<Map<String, dynamic>> _availableModes = [];
  bool _isLoadingModes = false;
  DailySchedule? _dailySchedule;
  String _organizationTimezone = 'Asia/Jakarta';

  Map<String, dynamic>? _memberSchedule;
  String? _workTimeMode;

  // Duplicate Prevention
  final Map<String, DateTime> _lastAttendanceTime = {};
  static const Duration _duplicateCooldown = Duration(minutes: 5);

  // Fingerprint State
  bool _isScannerReady = false;
  String _statusMessage = AppLanguage.tr('attendance.fingerprint.initializing');
  Uint8List? _capturedImage;
  bool _isProcessing = false;
  bool _isRefreshing = false;
  List<Map<String, dynamic>> _allTemplates = [];

  StreamSubscription? _statusSubscription;
  StreamSubscription? _imageSubscription;
  StreamSubscription? _resultSubscription;

  int? get _organizationId => widget.memberData['organization_id'] as int?;

  @override
  void initState() {
    super.initState();
    _organizationTimezone =
        widget.userProfile?['organization']?['timezone'] ?? 'Asia/Jakarta';
    _startClock();
    _loadOrganizationData();
    _loadAvailableModes();
    _loadMemberSchedule();
    _setupFingerprintListeners();
    _initializeFlow();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _statusSubscription?.cancel();
    _imageSubscription?.cancel();
    _resultSubscription?.cancel();
    _fingerprintService.stopScanner();
    super.dispose();
  }

  void _startClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() => _currentTime = DateTime.now());
    });
  }

  Future<void> _loadMemberSchedule() async {
    try {
      final dailySched = await _attendanceService.getTodaySchedule(
        widget.organizationMemberId,
        organizationTimezone: _organizationTimezone,
      );
      if (mounted) {
        setState(() => _dailySchedule = dailySched);
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading schedule: $e');
      // Fallback is already handled by AttendanceService.getTodaySchedule
    }
  }

  ({bool canBreakOut, bool canBreakIn, String? hint})
  _computeBreakButtonState() {
    final schedule = _dailySchedule;
    if (schedule == null) {
      return (
        canBreakOut: false,
        canBreakIn: false,
        hint: AppLanguage.tr('attendance.common.loading_schedule'),
      );
    }

    final bStartStr = schedule.breakStart;
    final bEndStr = schedule.breakEnd;
    if (bStartStr == null || bEndStr == null) {
      return (
        canBreakOut: false,
        canBreakIn: false,
        hint: AppLanguage.tr('attendance.fingerprint.no_break_schedule'),
      );
    }

    TimeOfDay? parseTime(String s) {
      try {
        final p = s.split(':');
        return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
      } catch (_) {
        return null;
      }
    }

    final bStart = parseTime(bStartStr);
    final bEnd = parseTime(bEndStr);
    if (bStart == null || bEnd == null) {
      return (canBreakOut: true, canBreakIn: true, hint: null);
    }

    final now = TimezoneHelper.convertUtcToOrgTimezone(
      DateTime.now().toUtc(),
      _organizationTimezone,
    );
    final nowMin = now.hour * 60 + now.minute;
    final bStartMin = bStart.hour * 60 + bStart.minute;
    final bEndMin = bEnd.hour * 60 + bEnd.minute;

    const window = 30;
    final can = nowMin >= (bStartMin - window) && nowMin <= (bEndMin + window);

    String? hint;
    if (!can) {
      String fmt(TimeOfDay t) =>
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      hint =
          '${AppLanguage.tr('attendance.fingerprint.break_available_at')} ${fmt(bStart)} - ${fmt(bEnd)}';
    }

    return (canBreakOut: can, canBreakIn: can, hint: hint);
  }

  void _setupFingerprintListeners() {
    _statusSubscription = _fingerprintService.onStatusUpdate.listen((status) {
      if (mounted) {
        final lowerStatus = status.toLowerCase();

        // Ignore transient capture/extract errors unless they indicate a disconnected device
        if ((lowerStatus.contains('capture error') ||
                lowerStatus.contains('extract error')) &&
            !lowerStatus.contains('not found')) {
          // If we are already ready, just keep the ready message
          if (_isScannerReady && !_isProcessing) {
            setState(
              () => _statusMessage = AppLanguage.tr(
                'attendance.fingerprint.place_finger',
              ),
            );
          }
          return;
        }

        setState(() {
          _statusMessage = _translateStatus(status);

          if (status.contains('Ready') ||
              status.contains('Identification') ||
              status.contains('connect success')) {
            _isScannerReady = true;
          } else if (status.contains('error') ||
              status.contains('fail') ||
              status.contains('failed')) {
            if (!status.contains('Capture error') ||
                status.contains('not found')) {
              _isScannerReady = false;
            }
          }
        });
      }
    });

    _imageSubscription = _fingerprintService.onImageCaptured.listen((image) {
      if (mounted) setState(() => _capturedImage = image);
    });

    _resultSubscription = _fingerprintService.onIdentificationResult.listen((
      result,
    ) {
      if (mounted && !_isProcessing) _handleIdentificationMatch(result);
    });
  }

  String _translateStatus(String status) {
    if (status.contains('Identification active') || status.contains('Ready')) {
      return AppLanguage.tr('attendance.fingerprint.place_finger');
    }
    if (status.contains('connect success')) {
      return AppLanguage.tr('attendance.fingerprint.connect_success');
    }
    if (status.contains('connect failed') || status.contains('failed!')) {
      return AppLanguage.tr('attendance.fingerprint.connect_failed');
    }
    if (status.contains('Capture error')) {
      return status.contains('not found')
          ? AppLanguage.tr('attendance.fingerprint.scanner_not_found')
          : AppLanguage.tr('attendance.fingerprint.place_finger');
    }
    if (status.contains('Not recognized')) {
      return AppLanguage.tr('attendance.fingerprint.scan_failed');
    }
    if (status.contains('Identify success')) {
      return AppLanguage.tr('attendance.fingerprint.scan_success');
    }
    return status;
  }

  Future<void> _initializeFlow() async {
    await _loadAllTemplates();
    await _startScanner();
  }

  /// Refresh template dari Supabase dan reload ke alat scanner.
  /// Dipanggil saat tombol refresh ditekan — berguna jika ada user baru registrasi
  /// setelah halaman ini sudah terbuka.
  Future<void> _refreshTemplates() async {
    if (_isRefreshing || _isProcessing) return;
    final orgId = _organizationId;
    if (orgId == null) return;

    setState(() {
      _isRefreshing = true;
      _statusMessage = 'Memuat ulang template...';
    });

    try {
      // 1. Hapus semua template lama dari memori alat
      await _fingerprintService.clearAll();
      debugPrint('🗑️ Cleared old templates from scanner memory');

      // 2. Paksa fetch ulang dari Supabase (bypass cache)
      final results = await _supabase
          .from('biometric_data')
          .select('''
            id,
            organization_member_id,
            template_data,
            organization_members!inner (
              id,
              user_id,
              organization_id,
              employee_id,
              department_id,
              user_profiles!inner (
                id,
                first_name,
                last_name,
                display_name,
                profile_photo_url
              ),
              departments!organization_members_department_id_fkey (
                id,
                name
              )
            )
          ''')
          .eq('biometric_type', 'fingerprint')
          .eq('is_active', true)
          .eq('organization_members.organization_id', orgId);

      final freshTemplates = List<Map<String, dynamic>>.from(results);
      debugPrint('✅ Fetched ${freshTemplates.length} templates from Supabase');

      // 3. Simpan ke state
      if (mounted) {
        setState(() {
          _allTemplates = freshTemplates;
        });
      }

      // 4. Load ke memori alat
      if (freshTemplates.isNotEmpty) {
        final formatted = freshTemplates
            .map((t) => {
                  'memberId': t['organization_member_id'].toString(),
                  'template': t['template_data'],
                })
            .toList();
        await _fingerprintService.loadTemplates(formatted);
        await _fingerprintService.startIdentification();
        debugPrint('📥 Reloaded ${freshTemplates.length} templates into scanner');

        if (mounted) {
          setState(() {
            _statusMessage = AppLanguage.tr('attendance.fingerprint.place_finger');
            _isScannerReady = true;
          });
        }

        // Tampilkan snackbar sukses
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '✅ ${freshTemplates.length} template berhasil dimuat ulang',
                style: const TextStyle(color: Colors.white),
              ),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
      } else {
        if (mounted) {
          setState(() {
            _statusMessage = AppLanguage.tr('attendance.fingerprint.no_database');
            _isScannerReady = false;
          });
        }
      }
    } catch (e) {
      debugPrint('❌ Refresh templates error: $e');
      if (mounted) {
        setState(() {
          _statusMessage = 'Gagal memuat ulang: $e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '❌ Gagal refresh template: $e',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _loadAllTemplates() async {
    final orgId = _organizationId;
    if (orgId == null) return;
    try {
      debugPrint('🔍 Loading fingerprint templates for org: $orgId');
      final templates = await _biometricService
          .getAllActiveFingerprintTemplates(orgId);

      if (mounted) {
        setState(() {
          _allTemplates = templates;
        });
      }
      debugPrint('✅ Found ${templates.length} fingerprint templates');
    } catch (e) {
      debugPrint('❌ Error loading fingerprint templates: $e');
    }
  }

  Future<void> _startScanner() async {
    try {
      bool permission = await _fingerprintService.requestPermission();
      if (!permission) {
        setState(
          () => _statusMessage = AppLanguage.tr(
            'attendance.fingerprint.usb_permission_denied',
          ),
        );
        return;
      }

      final result = await _fingerprintService.startScanner();
      if (result != 'success') {
        setState(() {
          _statusMessage =
              result ??
              AppLanguage.tr('attendance.fingerprint.failed_to_start');
          _isScannerReady = false;
        });
        return;
      }

      if (_allTemplates.isNotEmpty) {
        debugPrint(
          '📥 Loading ${_allTemplates.length} templates into scanner...',
        );
        final List<Map<String, dynamic>> formatted = _allTemplates
            .map(
              (t) => {
                'memberId': t['organization_member_id'].toString(),
                'template': t['template_data'],
              },
            )
            .toList();
        final loadResult = await _fingerprintService.loadTemplates(formatted);
        debugPrint('📤 Scanner load result: $loadResult');
        await _fingerprintService.startIdentification();
      } else {
        setState(
          () => _statusMessage = AppLanguage.tr(
            'attendance.fingerprint.no_database',
          ),
        );
      }
    } catch (e) {
      setState(
        () => _statusMessage =
            '${AppLanguage.tr('attendance.fingerprint.system_error')}: $e',
      );
    }
  }

  Future<void> _loadAvailableModes() async {
    if (_isLoadingModes) return;
    final orgId = _organizationId;
    if (orgId == null) return;
    setState(() => _isLoadingModes = true);
    try {
      final modes = await _supabase
          .from('shifts')
          .select('id, code, name, start_time, end_time')
          .eq('organization_id', orgId)
          .eq('is_active', true)
          .order('name', ascending: true);

      if (mounted) {
        setState(() {
          _availableModes = List<Map<String, dynamic>>.from(modes);
          if (_availableModes.isNotEmpty) _selectedMode = _availableModes.first;
        });

        // Cache shifts for offline use
        await _offlineDb.cacheShifts(orgId, _availableModes);
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading modes result: $e');

      // Fallback to cache
      final cachedShifts = await _offlineDb.getShifts(orgId);
      if (mounted) {
        setState(() {
          _availableModes = List<Map<String, dynamic>>.from(cachedShifts);
          if (_availableModes.isNotEmpty) _selectedMode = _availableModes.first;
        });
        if (_availableModes.isNotEmpty) {
          debugPrint(
            '💾 Using cached shifts (${_availableModes.length} found)',
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isLoadingModes = false);
    }
  }

  Future<void> _loadOrganizationData() async {
    final orgId = _organizationId;
    if (orgId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone, name')
          .eq('id', orgId)
          .maybeSingle();

      if (org != null && mounted) {
        setState(() {
          _organizationTimezone = org['timezone'] as String? ?? 'Asia/Jakarta';
          _organizationName = org['name'] as String? ?? '';
        });

        // Cache for offline use
        await _offlineDb.cacheOrganizationData({
          'id': orgId,
          'name': _organizationName,
          'timezone': _organizationTimezone,
        });
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading org data: $e');

      // Try fallback from cache
      final cachedOrg = await _offlineDb.getOrganizationData(orgId);
      if (cachedOrg != null && mounted) {
        setState(() {
          _organizationTimezone =
              cachedOrg['timezone'] as String? ?? 'Asia/Jakarta';
          _organizationName = cachedOrg['name'] as String? ?? '';
        });
        debugPrint('💾 Using cached organization data');
      }
    }
  }

  Future<void> _handleIdentificationMatch(Map<String, dynamic> result) async {
    debugPrint('🎯 Fingerprint Match Result: $result');

    final mid = int.tryParse(result['memberId']?.toString() ?? '');
    if (mid == null) {
      debugPrint('⚠️ Invalid memberId in match result');
      return;
    }

    final info = _allTemplates.firstWhere(
      (t) => t['organization_member_id'] == mid,
      orElse: () => {},
    );
    if (info.isEmpty) {
      debugPrint(
        '❌ Member info not found in local template list for MID: $mid',
      );
      return;
    }

    debugPrint('👤 Identified member: $mid (Info found: ${info.isNotEmpty})');

    final action = _attendanceMode;
    final workMode = _selectedMode?['code'] ?? _selectedMode?['name'];
    final cooldownKey = "${mid}_${action}_$workMode";

    // Check Cooldown
    if (_lastAttendanceTime.containsKey(cooldownKey)) {
      final lastTime = _lastAttendanceTime[cooldownKey]!;
      final diff = DateTime.now().difference(lastTime);
      if (diff < _duplicateCooldown) {
        final remaining = 5 - diff.inMinutes;
        final profile =
            (info['organization_members'] as Map?)?['user_profiles'] as Map?;
        final name =
            profile?['display_name'] ?? profile?['first_name'] ?? 'Member';
        String modeLabel = action.toUpperCase().replaceAll('_', ' ');
        if (action == 'check_in') {
          modeLabel = AppLanguage.tr('attendance.fingerprint.in');
        }
        if (action == 'check_out') {
          modeLabel = AppLanguage.tr('attendance.fingerprint.out');
        }
        if (action == 'break_start') {
          modeLabel = AppLanguage.tr('attendance.fingerprint.break_in');
        }
        if (action == 'break_end') {
          modeLabel = AppLanguage.tr('attendance.fingerprint.break_out');
        }

        _showDuplicateOverlay(
          "$name ${AppLanguage.tr('attendance.fingerprint.already_attended')} $modeLabel. ${AppLanguage.tr('attendance.fingerprint.try_again_in')} $remaining ${AppLanguage.tr('attendance.fingerprint.minutes')}.",
        );
        return;
      }
    }

    setState(() => _isProcessing = true);
    try {
      await SoundHelper.playSuccessSound();
      await _recordAttendance(mid, _organizationTimezone, action, workMode);

      // Update cooldown
      _lastAttendanceTime[cooldownKey] = DateTime.now();

      if (mounted) {
        setState(() {
          _entries.insert(
            0,
            _AttendanceEntry(
              memberId: mid,
              memberInfo: info,
              action: action,
              timestamp: DateTime.now(),
              workTimeMode: workMode,
            ),
          );
          if (_entries.length > 50) _entries.removeRange(50, _entries.length);

          final profile =
              (info['organization_members'] as Map?)?['user_profiles'] as Map?;
          final name =
              profile?['display_name'] ?? profile?['first_name'] ?? 'Member';
          String modeLabel = action.toUpperCase().replaceAll('_', ' ');
          if (action == 'check_in') {
            modeLabel = AppLanguage.tr('attendance.fingerprint.in');
          }
          if (action == 'check_out') {
            modeLabel = AppLanguage.tr('attendance.fingerprint.out');
          }
          if (action == 'break_start') {
            modeLabel = AppLanguage.tr('attendance.fingerprint.break_in');
          }
          if (action == 'break_end') {
            modeLabel = AppLanguage.tr('attendance.fingerprint.break_out');
          }

          _statusMessage =
              '${AppLanguage.tr('attendance.fingerprint.success_prefix')}: $name ($modeLabel)';
        });
      }
    } catch (e) {
      debugPrint('Error: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showDuplicateOverlay(String message) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry oe;
    oe = OverlayEntry(
      builder: (c) => Positioned(
        top: MediaQuery.of(c).padding.top + 8,
        left: 12,
        right: 12,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.orange.shade500, Colors.orange.shade700],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.orange.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.warning_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(oe);
    Future.delayed(const Duration(seconds: 4), () {
      if (oe.mounted) oe.remove();
    });
  }

  Future<void> _recordAttendance(
    int mid,
    String tz,
    String action,
    String? workMode,
  ) async {
    try {
      debugPrint('🌐 Attempting online record for MID: $mid, Action: $action');

      switch (action) {
        case 'check_in':
          await _attendanceService.checkInFingerprint(
            organizationMemberId: mid,
            organizationTimezone: tz,
            rawData: {'work_time_mode': workMode ?? _getWorkTimeMode()},
          );
          break;
        case 'check_out':
          await _attendanceService.checkOutFingerprint(
            organizationMemberId: mid,
            organizationTimezone: tz,
            rawData: {'work_time_mode': workMode ?? _getWorkTimeMode()},
          );
          break;
        case 'break_start':
          await _attendanceService.breakOutFingerprint(
            organizationMemberId: mid,
            organizationTimezone: tz,
            rawData: {'work_time_mode': workMode ?? _getWorkTimeMode()},
          );
          break;
        case 'break_end':
          await _attendanceService.breakInFingerprint(
            organizationMemberId: mid,
            organizationTimezone: tz,
            rawData: {'work_time_mode': workMode ?? _getWorkTimeMode()},
          );
          break;
      }
      debugPrint('✅ Online record successful for MID: $mid');
    } catch (e) {
      debugPrint('⚠️ Online record failed, falling back to offline: $e');

      // Fallback to offline storage
      await _saveOfflineAttendance(
        mid: mid,
        action: action,
        workMode: workMode ?? _getWorkTimeMode(),
      );
    }
  }

  Future<void> _saveOfflineAttendance({
    required int mid,
    required String action,
    String? workMode,
  }) async {
    try {
      final info = _allTemplates.firstWhere(
        (t) => t['organization_member_id'] == mid,
        orElse: () => {},
      );
      final profile =
          (info['organization_members'] as Map?)?['user_profiles'] as Map?;
      final name =
          profile?['display_name'] ?? profile?['first_name'] ?? 'Member';

      debugPrint('💾 Saving offline attendance for $name (MID: $mid)...');

      await _offlineDb.cacheAttendance({
        'organization_member_id': mid,
        'user_name': name,
        'event_type': action,
        'method': 'fingerprint',
        'work_time_mode': workMode,
      });

      debugPrint('✅ Saved fingerprint attendance for $name offline');

      // Trigger background sync
      AttendanceSyncService().syncPendingAttendances();
    } catch (e) {
      debugPrint('❌ Failed to save fingerprint attendance offline: $e');
    }
  }

  String _formatTimeShort(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  String _formatAmPm(DateTime time) => time.hour >= 12
      ? AppLanguage.tr('common.pm')
      : AppLanguage.tr('common.am');
  String _formatDate(DateTime time) {
    final months = [
      AppLanguage.tr('common.jan_short'),
      AppLanguage.tr('common.feb_short'),
      AppLanguage.tr('common.mar_short'),
      AppLanguage.tr('common.apr_short'),
      AppLanguage.tr('common.may_short'),
      AppLanguage.tr('common.jun_short'),
      AppLanguage.tr('common.jul_short'),
      AppLanguage.tr('common.aug_short'),
      AppLanguage.tr('common.sep_short'),
      AppLanguage.tr('common.oct_short'),
      AppLanguage.tr('common.nov_short'),
      AppLanguage.tr('common.dec_short'),
    ];
    return '${time.day} ${months[time.month - 1]} ${time.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 10),
                _buildClockHeader(),
                const SizedBox(height: 10),
                _buildShiftCard(),
                const SizedBox(height: 15),
                // Fingerprint Preview Area Always Visible at Top
                _buildFingerprintPreview(),
                const SizedBox(height: 20),
                Expanded(child: _buildAttendanceList()),
              ],
            ),
          ),
          Positioned(
            top: 40,
            left: 20,
            child: SafeArea(
              child: CircleAvatar(
                backgroundColor: Colors.grey.shade200.withOpacity(0.8),
                radius: 20,
                child: IconButton(
                  icon: const Icon(
                    Icons.chevron_left,
                    color: Colors.black,
                    size: 24,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),
          // Tombol Refresh Template (pojok kanan atas)
          Positioned(
            top: 40,
            right: 20,
            child: SafeArea(
              child: Tooltip(
                message: 'Refresh data fingerprint',
                child: CircleAvatar(
                  backgroundColor: const Color(0xFF9333EA).withOpacity(0.15),
                  radius: 20,
                  child: _isRefreshing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF9333EA),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(
                            Icons.refresh_rounded,
                            color: Color(0xFF9333EA),
                            size: 22,
                          ),
                          onPressed: _refreshTemplates,
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClockHeader() {
    final t = _formatTimeShort(_currentTime);
    final ap = _formatAmPm(_currentTime);
    final d = _formatDate(_currentTime);
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              ap,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.transparent,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              t,
              style: const TextStyle(
                fontSize: 72,
                fontWeight: FontWeight.w400,
                color: Colors.black87,
                letterSpacing: -2,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              ap,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
        Text(
          d,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade600,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }

  Widget _buildShiftCard() {
    String label = AppLanguage.tr('attendance.fingerprint.select_shift');
    if (_selectedMode != null) {
      String act = _attendanceMode.toUpperCase().replaceAll('_', ' ');
      if (_attendanceMode == 'check_in') {
        act = AppLanguage.tr('attendance.fingerprint.in');
      }
      if (_attendanceMode == 'check_out') {
        act = AppLanguage.tr('attendance.fingerprint.out');
      }
      if (_attendanceMode == 'break_start') {
        act = AppLanguage.tr('attendance.fingerprint.break_in');
      }
      if (_attendanceMode == 'break_end') {
        act = AppLanguage.tr('attendance.fingerprint.break_out');
      }
      label = '${_selectedMode!['name']} - $act';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: InkWell(
        onTap: _openShiftSelectionSheet,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF9333EA), Color(0xFF7E22CE)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF9333EA).withOpacity(0.3),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.swap_horiz,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white, size: 24),
            ],
          ),
        ),
      ),
    );
  }

  String _getWorkTimeMode() {
    if (_workTimeMode != null) return _workTimeMode!;
    if (_memberSchedule == null) return 'work_time';

    try {
      final orgTime = TimezoneHelper.convertUtcToOrgTimezone(
        DateTime.now().toUtc(),
        _organizationTimezone,
      );

      final currentMinutes = orgTime.hour * 60 + orgTime.minute;
      final scheduleType = _memberSchedule!['type'] as String?;

      if (scheduleType == 'shift') {
        final shift = _memberSchedule!['shift'] as Map<String, dynamic>?;
        if (shift != null) {
          final startTime = _parseTimeString(shift['start_time'] as String?);
          final endTime = _parseTimeString(shift['end_time'] as String?);

          if (startTime != null && endTime != null) {
            final startMin = startTime.hour * 60 + startTime.minute;
            final endMin = endTime.hour * 60 + endTime.minute;

            if (currentMinutes >= startMin && currentMinutes < endMin) {
              return 'work_time';
            }
          }
        }
      } else if (scheduleType == 'work_schedule') {
        final detail = _memberSchedule!['detail'] as Map<String, dynamic>?;
        if (detail != null) {
          final startTime = _parseTimeString(detail['start_time'] as String?);
          final breakStart = _parseTimeString(detail['break_start'] as String?);
          final breakEnd = _parseTimeString(detail['break_end'] as String?);

          if (startTime != null && breakStart != null && breakEnd != null) {
            final startMin = startTime.hour * 60 + startTime.minute;
            final breakStartMin = breakStart.hour * 60 + breakStart.minute;
            final breakEndMin = breakEnd.hour * 60 + breakEnd.minute;

            if (currentMinutes >= startMin && currentMinutes < breakStartMin) {
              return 'work_time';
            } else if (currentMinutes >= breakStartMin &&
                currentMinutes < breakEndMin) {
              return 'break_time';
            } else if (currentMinutes >= breakEndMin) {
              return 'work_time';
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error getting work time mode: $e');
    }

    return 'work_time';
  }

  TimeOfDay? _parseTimeString(String? timeStr) {
    if (timeStr == null) return null;
    try {
      final parts = timeStr.split(':');
      if (parts.length >= 2) {
        return TimeOfDay(
          hour: int.parse(parts[0]),
          minute: int.parse(parts[1]),
        );
      }
    } catch (e) {
      debugPrint('Error parsing time: $timeStr');
    }
    return null;
  }

  Widget _buildFingerprintPreview() {
    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            _buildPulseCircle(100, 0.1),
            _buildPulseCircle(95, 0.05),
            Container(
              width: 100,
              height: 100,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 15,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Center(
                child: _capturedImage != null
                    ? ClipOval(
                        child: Image.memory(
                          _capturedImage!,
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Icon(
                        Icons.fingerprint,
                        size: 60,
                        color: _isScannerReady
                            ? const Color(0xFF9333EA)
                            : Colors.redAccent,
                      ),
              ),
            ),
            if (_isProcessing)
              const SizedBox(
                width: 110,
                height: 110,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF9333EA),
                ),
              ),
          ],
        ),
        Text(
          _statusMessage,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
            height: _statusMessage.trim().isEmpty ? 0 : 1.2,
          ),
        ),
      ],
    );
  }

  Widget _buildPulseCircle(double size, double opacity) {
    return TweenAnimationBuilder(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(seconds: 2),
      builder: (context, double value, child) => Container(
        width: size + (value * 15),
        height: size + (value * 15),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFF9333EA).withOpacity(opacity * (1 - value)),
            width: 1,
          ),
        ),
      ),
      onEnd: () => setState(() {}),
    );
  }

  Widget _buildAttendanceList() {
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          AppLanguage.tr('attendance.fingerprint.no_data_today'),
          style: TextStyle(color: Colors.grey.shade400),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, index) => _buildEntryCard(_entries[index]),
    );
  }

  Widget _buildEntryCard(_AttendanceEntry entry) {
    final p = entry.memberInfo['organization_members']?['user_profiles'] ?? {};
    final n = p['display_name'] ?? '${p['first_name']} ${p['last_name']}';
    final photo = p['profile_photo_url'];
    final d =
        entry.memberInfo['organization_members']?['departments']?['name'] ??
        '-';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundImage: photo != null ? NetworkImage(photo) : null,
            child: photo == null ? const Icon(Icons.person, size: 20) : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                ),
                Text(
                  d,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatTimeShort(entry.timestamp),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF9333EA),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              _buildActionBadge(entry.action),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionBadge(String action) {
    Color color = Colors.green;
    String label = AppLanguage.tr('attendance.fingerprint.in');
    if (action == 'check_out') {
      color = Colors.red;
      label = AppLanguage.tr('attendance.fingerprint.out');
    }
    if (action == 'break_start') {
      color = Colors.orange;
      label = AppLanguage.tr('attendance.fingerprint.break_in');
    }
    if (action == 'break_end') {
      color = Colors.blue;
      label = AppLanguage.tr('attendance.fingerprint.break_out');
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Future<void> _openShiftSelectionSheet() async {
    await _loadAvailableModes();
    if (!mounted) return;

    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
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
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                AppLanguage.tr('attendance.fingerprint.select_shift'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF9333EA), // Purple title
                ),
              ),
              const SizedBox(height: 24),

              ..._availableModes.map((mode) {
                final isSelected = _selectedMode?['id'] == mode['id'];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InkWell(
                    onTap: () => Navigator.pop(context, mode),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFFF3E8FF)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFF9333EA)
                              : Colors.grey.shade200,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF9333EA).withOpacity(0.1)
                                  : Colors.grey.shade100,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _getIconForMode(mode['name'] ?? ''),
                              color: isSelected
                                  ? const Color(0xFF9333EA)
                                  : Colors.grey,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  mode['name'] ?? 'Shift',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: isSelected
                                        ? Colors.black
                                        : Colors.black87,
                                  ),
                                ),
                                if (mode['start_time'] != null &&
                                    mode['end_time'] != null)
                                  Text(
                                    '${mode['start_time']} - ${mode['end_time']}',
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 13,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (isSelected)
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Color(0xFF9333EA),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 14,
                              ),
                            )
                          else
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }),

              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );

    if (selected != null && mounted) {
      setState(() {
        _selectedMode = selected;
        _workTimeMode =
            selected['code'] as String? ?? selected['name'] as String?;
      });
      await _showInOutSelector();
    }
  }

  IconData _getIconForMode(String name) {
    name = name.toLowerCase();
    if (name.contains('morning') || name.contains('pagi')) {
      return Icons.wb_sunny_outlined;
    }
    if (name.contains('afternoon') || name.contains('siang')) {
      return Icons.wb_twilight;
    }
    if (name.contains('night') || name.contains('malam')) {
      return Icons.nights_stay_outlined;
    }
    return Icons.schedule;
  }

  Future<void> _showInOutSelector() async {
    if (!mounted) return;
    final pickedMode = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => Navigator.pop(context, 'check_in'),
                        child: Text(AppLanguage.tr('attendance.fingerprint.in')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => Navigator.pop(context, 'check_out'),
                        child: Text(AppLanguage.tr('attendance.fingerprint.out')),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                StatefulBuilder(
                  builder: (context, setState2) {
                    final bState = _computeBreakButtonState();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: bState.canBreakOut
                                      ? Colors.orange
                                      : Colors.grey.shade400,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                onPressed: bState.canBreakOut
                                    ? () =>
                                          Navigator.pop(context, 'break_start')
                                    : null,
                                child: Text(
                                  AppLanguage.tr(
                                    'attendance.fingerprint.break_in',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: bState.canBreakIn
                                      ? Colors.blue
                                      : Colors.grey.shade400,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                onPressed: bState.canBreakIn
                                    ? () => Navigator.pop(context, 'break_end')
                                    : null,
                                child: Text(
                                  AppLanguage.tr(
                                    'attendance.fingerprint.break_out',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (bState.hint != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              bState.hint!,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange.shade700,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );

    if (pickedMode != null && mounted) {
      setState(() => _attendanceMode = pickedMode);

      String typeDisplay;
      switch (pickedMode) {
        case 'check_in':
          typeDisplay = AppLanguage.tr('attendance.fingerprint.in');
          break;
        case 'check_out':
          typeDisplay = AppLanguage.tr('attendance.fingerprint.out');
          break;
        case 'break_start':
          typeDisplay = AppLanguage.tr('attendance.fingerprint.break_in').toUpperCase();
          break;
        case 'break_end':
          typeDisplay = AppLanguage.tr('attendance.fingerprint.break_out').toUpperCase();
          break;
        default:
          typeDisplay = pickedMode;
      }
      _showDuplicateOverlay("Mode set: $typeDisplay");
    }
  }
}

class _AttendanceEntry {
  final int memberId;
  final Map<String, dynamic> memberInfo;
  final String action;
  final DateTime timestamp;
  final String? workTimeMode;
  _AttendanceEntry({
    required this.memberId,
    required this.memberInfo,
    required this.action,
    required this.timestamp,
    this.workTimeMode,
  });
}
