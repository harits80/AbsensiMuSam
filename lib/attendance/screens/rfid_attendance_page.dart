// lib/pages/rfid_attendance_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../helpers/language_helper.dart';

import '../../models/offline_attendance.dart';
import '../../services/offline_database_service.dart';
import '../services/attendance_sync_service.dart';
import '../../helpers/timezone_helper.dart';
import '../../helpers/sound_helper.dart';
import 'package:app_settings/app_settings.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'dart:io';
import '../../models/work_schedule_models.dart';
import '../services/attendance_service.dart';
import 'manual_check_page.dart';

class RfidAttendancePage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const RfidAttendancePage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
  });

  @override
  State<RfidAttendancePage> createState() => _RfidAttendancePageState();
}

class _RfidAttendancePageState extends State<RfidAttendancePage> {
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceSyncService _syncService = AttendanceSyncService();
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseClient _supabase = Supabase.instance.client;

  final TextEditingController _cardController = TextEditingController();
  final FocusNode _cardFocusNode = FocusNode();
  Timer? _clockTimer;

  final List<_AttendanceEntry> _entries = [];
  String _organizationTimezone = 'Asia/Jakarta';
  String _organizationName = '';
  String _attendanceMode = 'check_in';
  Map<String, dynamic>? _selectedMode;
  List<Map<String, dynamic>> _availableModes = [];
  bool _isLoadingModes = false;
  DateTime _currentTime = DateTime.now();

  // Animation Controller for pulsing effect
  double _pulseRadius = 0.0;
  Timer? _pulseTimer;

  String? _workTimeMode;
  Map<String, dynamic>? _memberSchedule;
  DailySchedule? _dailySchedule; // ✅ NEW: for break time validation
  Timer? _scheduleCheckTimer;

  bool _isOnline = true;
  int _pendingSyncCount = 0;
  StreamSubscription<SyncStatus>? _syncStatusSub;

  int? get _organizationId => widget.memberData['organization_id'] as int?;

  List<_AttendanceEntry> get _filteredEntries {
    return _entries.where((entry) => entry.action == _attendanceMode).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadOrganizationData();
    _loadMemberSchedule();
    _startClock();
    _startPulseAnimation();
    _startScheduleCheck();
    _checkConnectivity();
    _loadPendingSyncCount();
    _syncService.startAutoSync();
    _syncStatusSub = _syncService.syncStatusStream.listen((status) {
      if (mounted) _loadPendingSyncCount();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _cardFocusNode.requestFocus();
      });

      // Cache member data after a short delay to ensure connectivity is checked
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _isOnline) {
          _cacheMemberData();
        }
      });

      // Trigger initial mode selection after page loads
      _loadAvailableModes();

      // Show OTG setup prompt automatically on entry
      _showOTGSetupPrompt();
    });
  }

  Future<void> _checkConnectivity() async {
    final result = await Connectivity().checkConnectivity();
    final isOnline = result != ConnectivityResult.none;
    setState(() {
      _isOnline = isOnline;
    });

    // Load offline data if offline (Removed per user request to start empty)
    // if (!isOnline) {
    //   _loadOfflineAttendanceData();
    // }

    Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) {
        final isOnlineNow = results != ConnectivityResult.none;
        setState(() {
          _isOnline = isOnlineNow;
        });
        if (isOnlineNow) {
          _loadPendingSyncCount();
          _cacheMemberData(); // Cache member data when coming online
        }
        // else {
        //   _loadOfflineAttendanceData(); // Load offline data when going offline
        // }
      }
    });
  }

  Future<void> _loadPendingSyncCount() async {
    final count = await _offlineDb.getUnsyncedCount();
    if (mounted) {
      setState(() {
        _pendingSyncCount = count;
      });
    }
  }

  void _startClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() => _currentTime = DateTime.now());
      } else {
        timer.cancel();
      }
    });
  }

  void _startScheduleCheck() {
    _scheduleCheckTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (mounted) {
        _updateModeBasedOnSchedule();
        if (_workTimeMode == null) setState(() {});
      }
    });
  }

  void _updateModeBasedOnSchedule() {
    if (_availableModes.isEmpty) return;

    final now = DateTime.now();
    final currentMinutes = now.hour * 60 + now.minute;

    Map<String, dynamic>? matchingMode;

    // 0. Priority: Match by assigned shift_id from member schedule
    final memberScheduleShiftId = _memberSchedule?['shift_id'] as int?;
    if (memberScheduleShiftId != null) {
      for (var mode in _availableModes) {
        if (mode['id'] == memberScheduleShiftId) {
          matchingMode = mode;
          break;
        }
      }
    }

    // 0b. Priority: Match by work schedule hours for today
    if (matchingMode == null && _memberSchedule?['type'] == 'work_schedule') {
      final detail = _memberSchedule?['detail'] as Map<String, dynamic>?;
      final startTime = detail?['start_time'] as String?;
      final endTime = detail?['end_time'] as String?;
      if (startTime != null && endTime != null) {
        for (var mode in _availableModes) {
          // Normalize time string (remove seconds if present)
          String norm(String t) => t.split(':').take(2).join(':');
          if (norm(mode['start_time'] ?? '') == norm(startTime) &&
              norm(mode['end_time'] ?? '') == norm(endTime)) {
            matchingMode = mode;
            break;
          }
        }
      }
    }

    // 1. Fallback: Find a shift that matches the current time range
    if (matchingMode == null) {
      for (var mode in _availableModes) {
        final startTimeStr = mode['start_time'] as String?;
        final endTimeStr = mode['end_time'] as String?;

        if (startTimeStr != null && endTimeStr != null) {
          final start = _parseTimeString(startTimeStr);
          final end = _parseTimeString(endTimeStr);

          if (start != null && end != null) {
            int startMin = start.hour * 60 + start.minute;
            int endMin = end.hour * 60 + end.minute;

            // Handle shifts crossing midnight
            if (endMin < startMin) {
              if (currentMinutes >= startMin || currentMinutes < endMin) {
                matchingMode = mode;
                break;
              }
            } else {
              if (currentMinutes >= startMin && currentMinutes < endMin) {
                matchingMode = mode;
                break;
              }
            }
          }
        }
      }
    }

    // 2. Fallback to existing schedule-based workTimeMode logic if no time-range match found
    if (matchingMode == null && _workTimeMode != null) {
      for (var mode in _availableModes) {
        final modeCode =
            mode['code'] as String? ?? mode['name'] as String? ?? '';
        final modeName = mode['name'] as String? ?? '';

        if (_workTimeMode == 'break_time' &&
            (modeCode.toLowerCase().contains('break') ||
                modeName.toLowerCase().contains('break'))) {
          matchingMode = mode;
          break;
        } else if (_workTimeMode == 'work_time' &&
            (modeCode.toLowerCase().contains('work') ||
                modeName.toLowerCase().contains('kerja'))) {
          matchingMode = mode;
          break;
        } else if (_workTimeMode == 'overtime' &&
            (modeCode.toLowerCase().contains('overtime') ||
                modeName.toLowerCase().contains('lembur'))) {
          matchingMode = mode;
          break;
        }
      }
    }

    // 3. Absolute fallback to first mode
    if (matchingMode == null && _availableModes.isNotEmpty) {
      matchingMode = _availableModes.first;
    }

    if (matchingMode != null && _selectedMode?['id'] != matchingMode['id']) {
      setState(() {
        _selectedMode = matchingMode;
        _workTimeMode =
            matchingMode?['code'] as String? ??
            matchingMode?['name'] as String? ??
            _workTimeMode;
      });
    }
  }

  Future<void> _loadMemberSchedule() async {
    try {
      final today = DateTime.now();
      final todayStr = today.toIso8601String().split('T')[0];

      // 1. Get basic member schedule for shift_id & work_schedule_id (used for mode auto-selection)
      final schedule = await _supabase
          .from('member_schedules')
          .select('id, work_schedule_id, shift_id, effective_date, end_date')
          .eq('organization_member_id', widget.organizationMemberId)
          .eq('is_active', true)
          .lte('effective_date', todayStr)
          .or('end_date.is.null,end_date.gte.$todayStr')
          .order('effective_date', ascending: false)
          .limit(1)
          .maybeSingle();

      if (schedule != null && mounted) {
        setState(() {
          _memberSchedule = schedule;
        });
      }

      // 2. Load the full DailySchedule via service for break time validation
      // AttendanceService.getTodaySchedule already handles offline cache internally.
      final dailySched = await _attendanceService.getTodaySchedule(
        widget.organizationMemberId,
        organizationTimezone: _organizationTimezone,
      );

      if (mounted) {
        setState(() {
          _dailySchedule = dailySched;
          // Trigger auto mode selection after schedule is loaded
          _updateModeBasedOnSchedule();
        });
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading schedule: $e');

      // Try fetching from cache via AttendanceService even on exception
      try {
        final dailySched = await _attendanceService.getTodaySchedule(
          widget.organizationMemberId,
          organizationTimezone: _organizationTimezone,
        );
        if (mounted) {
          setState(() {
            _dailySchedule = dailySched;
            _updateModeBasedOnSchedule();
          });
          debugPrint('💾 Using cached daily schedule via service');
        }
      } catch (_) {}
    }
  }

  /// Returns break button availability based on the schedule
  ({bool canBreakOut, bool canBreakIn, String? hint})
  _computeBreakButtonState() {
    final schedule = _dailySchedule;
    if (schedule == null) {
      // No schedule loaded: disable buttons to be safe (fail closed)
      return (canBreakOut: false, canBreakIn: false, hint: 'Memuat jadwal...');
    }

    final breakStartStr = schedule.breakStart;
    final breakEndStr = schedule.breakEnd;

    if (breakStartStr == null || breakEndStr == null) {
      // No break scheduled = disable both buttons
      return (
        canBreakOut: false,
        canBreakIn: false,
        hint: 'Tidak ada jadwal istirahat',
      );
    }

    // Parse break times
    TimeOfDay? parseTime(String s) {
      try {
        final parts = s.split(':');
        return TimeOfDay(
          hour: int.parse(parts[0]),
          minute: int.parse(parts[1]),
        );
      } catch (_) {
        return null;
      }
    }

    final breakStart = parseTime(breakStartStr);
    final breakEnd = parseTime(breakEndStr);
    if (breakStart == null || breakEnd == null) {
      return (canBreakOut: true, canBreakIn: true, hint: null);
    }

    // Use Organization Timezone for current time comparison
    final now = TimezoneHelper.convertUtcToOrgTimezone(
      DateTime.now().toUtc(),
      _organizationTimezone,
    );
    final nowMin = now.hour * 60 + now.minute;
    final bStartMin = breakStart.hour * 60 + breakStart.minute;
    final bEndMin = breakEnd.hour * 60 + breakEnd.minute;

    // Allow both "Mulai" and "Selesai" if within the schedule window
    // [breakStart - 30m, breakEnd + 30m]
    const windowMinutes = 30;
    final canBreakOut =
        nowMin >= (bStartMin - windowMinutes) &&
        nowMin <= (bEndMin + windowMinutes);
    final canBreakIn =
        nowMin >= (bStartMin - windowMinutes) &&
        nowMin <= (bEndMin + windowMinutes);

    String formatTime(TimeOfDay t) {
      final h = t.hour.toString().padLeft(2, '0');
      final m = t.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }

    String? hint;
    if (!canBreakOut) {
      hint =
          'Istirahat tersedia pukul ${formatTime(breakStart)} - ${formatTime(breakEnd)}';
    }

    return (canBreakOut: canBreakOut, canBreakIn: canBreakIn, hint: hint);
  }

  Future<void> _loadAvailableModes() async {
    if (_isLoadingModes) return;
    final orgId = _organizationId;
    if (orgId == null) return;

    setState(() => _isLoadingModes = true);
    try {
      final modes = await _supabase
          .from('shifts')
          .select('id, code, name, start_time, end_time, description')
          .eq('organization_id', orgId)
          .eq('is_active', true)
          .order('name', ascending: true);

      if (mounted) {
        setState(() {
          _availableModes = List<Map<String, dynamic>>.from(modes);
        });

        // Cache shifts for offline use
        await _offlineDb.cacheShifts(orgId, _availableModes);
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading modes: $e');

      // Fallback to cache
      final cachedShifts = await _offlineDb.getShifts(orgId);
      if (mounted) {
        setState(() {
          _availableModes = List<Map<String, dynamic>>.from(cachedShifts);
        });
        if (_availableModes.isNotEmpty) {
          debugPrint(
            '💾 Using cached shifts (${_availableModes.length} found)',
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingModes = false);
        // Trigger auto mode selection after modes are loaded
        _updateModeBasedOnSchedule();
      }
    }
  }

  Future<void> _openModePicker() async {
    await _loadAvailableModes();
    if (!mounted) return;

    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(top: 12, bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      AppLanguage.tr('attendance.rfid.pilih_mode_shift'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isLoadingModes)
                    const Expanded(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_availableModes.isEmpty)
                    Expanded(
                      child: Center(
                        child: Text(
                          AppLanguage.tr('attendance.rfid.belum_ada_mode'),
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        itemCount: _availableModes.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final mode = _availableModes[index];
                          final start = mode['start_time'] as String?;
                          final end = mode['end_time'] as String?;
                          final isSelected = _selectedMode?['id'] == mode['id'];

                          return ListTile(
                            title: Text(
                              mode['name'] ?? '-',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: start != null && end != null
                                ? Text('$start - $end')
                                : null,
                            trailing: isSelected
                                ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                  )
                                : null,
                            onTap: () => Navigator.of(context).pop(mode),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
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
                        child: Text(AppLanguage.tr('attendance.rfid.in')),
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
                        child: Text(AppLanguage.tr('attendance.rfid.out')),
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
                                  AppLanguage.tr('attendance.rfid.break_in'),
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
                                  AppLanguage.tr('attendance.rfid.break_out'),
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
          typeDisplay = AppLanguage.tr('attendance.rfid.in');
          break;
        case 'check_out':
          typeDisplay = AppLanguage.tr('attendance.rfid.out');
          break;
        case 'break_start':
          typeDisplay = AppLanguage.tr('attendance.rfid.break_in').toUpperCase();
          break;
        case 'break_end':
          typeDisplay = AppLanguage.tr('attendance.rfid.break_out').toUpperCase();
          break;
        default:
          typeDisplay = pickedMode.toUpperCase();
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Mode $typeDisplay dipilih'
            '${_selectedMode != null ? ' • ${_selectedMode!['name']}' : ''}',
          ),
          backgroundColor: const Color(0xFF9333EA),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String _getWorkTimeMode() {
    if (_workTimeMode != null) return _workTimeMode!;
    if (_memberSchedule == null) return 'work_time';

    final orgTime = TimezoneHelper.convertUtcToOrgTimezone(
      _currentTime.toUtc(),
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

  Future<void> _cacheMemberData() async {
    if (!_isOnline) return;

    try {
      final orgId = _organizationId;
      if (orgId == null) return;

      // debugPrint('🔄 Starting to cache member data for organization: $orgId');

      // Cache all active RFID cards for this organization
      final cards = await _supabase
          .from('rfid_cards')
          .select('''
          id, card_number, organization_member_id,
          organization_members!inner(
            id, organization_id, user_id, department_id,
            user_profiles (display_name, first_name, last_name, profile_photo_url),
            departments!organization_members_department_id_fkey (id, name)
          )
        ''')
          .eq('organization_members.organization_id', orgId)
          .eq('is_active', true);

      int cachedCount = 0;
      for (final card in cards) {
        try {
          await _offlineDb.cacheMemberData(card);
          cachedCount++;
        } catch (e) {
          debugPrint('❌ Failed to cache card ${card['card_number']}: $e');
        }
      }

      // debugPrint('✅ Successfully cached $cachedCount/${cards.length} member cards for offline use');
    } catch (e) {
      debugPrint('❌ Error caching member data: $e');
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

        // Re-calculate auto-selection now that we have the correct timezone
        if (mounted) {
          _updateModeBasedOnSchedule();
        }
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

        if (mounted) {
          _updateModeBasedOnSchedule();
        }
      }
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _pulseTimer?.cancel();
    _scheduleCheckTimer?.cancel();
    _syncStatusSub?.cancel();
    _cardController.dispose();
    _cardFocusNode.dispose();
    _syncService.stopAutoSync();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _findMemberByCard(String cardNumber) async {
    final orgId = _organizationId;
    if (orgId == null) return null;

    final normalizedCardNumber = cardNumber.trim();
    if (normalizedCardNumber.isEmpty) return null;

    try {
      // 1. ALWAYS TRY CACHE FIRST for maximum speed
      debugPrint('🔍 Searching in offline cache for $normalizedCardNumber...');
      Map<String, dynamic>? cardData = await _offlineDb.findMemberByCardInCache(
        normalizedCardNumber,
        orgId,
      );

      if (cardData != null) {
        final memberInfo =
            cardData['organization_members'] as Map<String, dynamic>?;
        final userName = _composeMemberName(memberInfo);
        debugPrint('✅ Instant cache hit: $userName');

        // In background, if online, verify if it still exists (silent cleanup)
        if (_isOnline) {
          _supabase
              .from('rfid_cards')
              .select('id')
              .eq('card_number', normalizedCardNumber)
              .eq('is_active', true)
              .maybeSingle()
              .then((res) {
                if (res == null) {
                  debugPrint(
                    '🗑️ Card deleted from server, removing from cache',
                  );
                  _offlineDb.deleteMemberFromCache(normalizedCardNumber);
                }
              });
        }
        return cardData;
      }

      // 2. ONLY IF NOT IN CACHE, try online search
      if (_isOnline) {
        debugPrint(
          '🌐 Cache miss, searching online for $normalizedCardNumber...',
        );
        final cardResult = await _supabase
            .from('rfid_cards')
            .select('id, card_number, organization_member_id, is_active')
            .eq('card_number', normalizedCardNumber)
            .eq('is_active', true)
            .maybeSingle();

        if (cardResult != null) {
          final memberId = cardResult['organization_member_id'] as int?;
          if (memberId != null) {
            final memberData = await _supabase
                .from('organization_members')
                .select('''
                  id, organization_id, user_id, department_id,
                  user_profiles (display_name, first_name, last_name, profile_photo_url),
                  departments!organization_members_department_id_fkey (id, name)
                ''')
                .eq('id', memberId)
                .eq('organization_id', orgId)
                .eq('is_active', true)
                .maybeSingle();

            if (memberData != null) {
              cardData = {
                'id': cardResult['id'],
                'card_number': cardResult['card_number'],
                'organization_member_id': memberId,
                'organization_members': memberData,
              };

              debugPrint('✅ Found card online, caching for next time');
              _offlineDb.cacheMemberData(cardData);
              return cardData;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Error finding card: $e');
    }

    return null;
  }

  void _showDuplicateAlert(String name, String department, String mode) {
    // Show elegant overlay notification instead of snackbar
    if (!mounted) return;

    final overlay = Overlay.of(context);
    late OverlayEntry overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: 100,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.orange.shade500, Colors.orange.shade600],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.orange.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sudah Absen',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$name • $mode',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    overlayEntry.remove();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      color: Colors.white.withValues(alpha: 0.8),
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    overlay.insert(overlayEntry);

    // Auto remove after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (overlayEntry.mounted) {
        overlayEntry.remove();
      }
    });
  }

  Future<void> _handleCardScan() async {
    final cardNumber = _cardController.text.trim();
    if (cardNumber.isEmpty) {
      debugPrint('⚠️ Empty card number');
      return;
    }

    debugPrint('📱 Card scanned: "$cardNumber"');

    try {
      final cardData = await _findMemberByCard(cardNumber);
      if (cardData == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Kartu RFID tidak terdaftar'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final memberInfo =
          cardData['organization_members'] as Map<String, dynamic>? ?? {};
      final memberId =
          cardData['organization_member_id'] as int? ??
          memberInfo['id'] as int?;

      if (memberId == null) {
        debugPrint('❌ Member ID not found');
        return;
      }

      final memberOrgId = memberInfo['organization_id'] as int?;
      if (memberOrgId != _organizationId) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLanguage.tr('attendance.rfid.card_not_registered'),
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final action = _attendanceMode;
      final workTimeMode = _getWorkTimeMode();
      final userName = _composeMemberName(memberInfo);

      // --- INSTANT FEEDBACK START ---
      // Provide success sound and UI update immediately
      await SoundHelper.playSuccessSound();

      if (mounted) {
        setState(() {
          final newEntry = _AttendanceEntry(
            memberId: memberId,
            memberInfo: memberInfo,
            cardNumber: cardNumber,
            action: action,
            timestamp: DateTime.now(),
            workTimeMode: workTimeMode,
          );
          _entries.insert(0, newEntry);
          if (_entries.length > 50) _entries.removeRange(50, _entries.length);
        });
      }
      // --- INSTANT FEEDBACK END ---

      // Perform duplicate checks and database saving in background
      _processAttendanceInBackground(
        memberId: memberId,
        cardNumber: cardNumber,
        userName: userName,
        action: action,
        workTimeMode: workTimeMode,
      );
    } catch (e) {
      debugPrint('❌ Error card scan: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      _cardController.clear();
      _cardFocusNode.requestFocus();
    }
  }

  Future<void> _processAttendanceInBackground({
    required int memberId,
    required String cardNumber,
    required String userName,
    required String action,
    required String? workTimeMode,
  }) async {
    try {
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(
        _organizationTimezone,
      );

      // 1. Check for duplicates (for logging/internal logic)
      bool hasDuplicate = false;
      if (_isOnline) {
        try {
          final existingRecord = await _supabase
              .from('attendance_records')
              .select(
                'id, actual_check_in, actual_check_out, actual_break_start, actual_break_end',
              )
              .eq('organization_member_id', memberId)
              .eq('attendance_date', todayStr)
              .maybeSingle();

          if (existingRecord != null) {
            if (action == 'check_in' &&
                existingRecord['actual_check_in'] != null) {
              hasDuplicate = true;
            } else if (action == 'check_out' &&
                existingRecord['actual_check_out'] != null) {
              hasDuplicate = true;
            } else if (action == 'break_out' &&
                existingRecord['actual_break_start'] != null) {
              hasDuplicate = true;
            } else if (action == 'break_in' &&
                existingRecord['actual_break_end'] != null) {
              hasDuplicate = true;
            }
          }
        } catch (e) {
          debugPrint('Error checking online duplicate: $e');
        }
      }

      if (!hasDuplicate) {
        hasDuplicate = await _offlineDb.hasDuplicateAttendance(
          organizationMemberId: memberId,
          eventType: action,
          attendanceDate: todayStr,
        );
      }

      if (hasDuplicate) {
        debugPrint(
          'ℹ️ Duplicate $action detected for $userName, but proceeding with log entry',
        );
      }

      // 2. Prepare local record
      debugPrint('💾 Background processing attendance: $userName ($action)');
      OfflineAttendance offlineAttendance = OfflineAttendance(
        cardNumber: cardNumber,
        eventType: action,
        method: 'rfid_card_mobile',
        timestamp: TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        workTimeMode: workTimeMode,
        organizationMemberId: memberId,
        userName: userName,
        isSynced: false,
      );

      // 3. Try online first if connected
      bool syncSuccess = false;
      if (_isOnline) {
        try {
          final rawData = {
            'card_number': cardNumber,
            'work_time_mode': workTimeMode,
            'synced_from_offline': false,
          };

          if (action == 'check_in') {
            await _attendanceService.checkIn(
              organizationMemberId: memberId,
              method: 'rfid_card_mobile',
              photoUrl: '', // RFID doesn't use photo
              rawData: rawData,
            );
          } else if (action == 'check_out') {
            await _attendanceService.checkOut(
              organizationMemberId: memberId,
              method: 'rfid_card_mobile',
              photoUrl: '', // RFID doesn't use photo
              rawData: rawData,
            );
          } else if (action == 'break_out' || action == 'break_start') {
            await _attendanceService.breakOut(
              organizationMemberId: memberId,
              method: 'rfid_card_mobile',
              photoUrl: '', // RFID doesn't use photo
              rawData: rawData,
            );
          } else if (action == 'break_in' || action == 'break_end') {
            await _attendanceService.breakIn(
              organizationMemberId: memberId,
              method: 'rfid_card_mobile',
              photoUrl: '', // RFID doesn't use photo
              rawData: rawData,
            );
          }
          syncSuccess = true;
          debugPrint('✅ Online rfid attendance recorded for $userName');
        } catch (e) {
          debugPrint('⚠️ Online rfid failed, preserving for offline sync: $e');
        }
      }

      // 4. Save to local DB (mark as synced if online was successful)
      offlineAttendance = offlineAttendance.copyWith(isSynced: syncSuccess);
      await _offlineDb.insertAttendance(offlineAttendance);

      // 5. If it was an offline save, trigger sync service to handle any queue
      if (!syncSuccess) {
        AttendanceSyncService().syncPendingAttendances();
      }

      await _loadPendingSyncCount();
      debugPrint('✅ Background processing complete for $userName');
    } catch (e) {
      debugPrint('❌ Background processing error: $e');
    }
  }

  Future<void> _openOTGSettings() async {
    if (!Platform.isAndroid) {
      AppSettings.openAppSettings(type: AppSettingsType.settings);
      return;
    }

    // Direct to Main Settings (Safest & Most Consistent)
    // Allows user to use the Search Bar to find "OTG" regardless of device brand.
    try {
      const intent = AndroidIntent(
        action: 'android.settings.SETTINGS',
        flags: [Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await intent.launch();
    } catch (e) {
      debugPrint('Main Settings Intent failed: $e');
      // Ultimate fallback
      AppSettings.openAppSettings(type: AppSettingsType.settings);
    }
  }

  void _showOTGSetupPrompt() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.usb_rounded, color: Color(0xFF9333EA), size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppLanguage.tr('attendance.rfid.otg_title'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                  color: Color(0xFF4A1E79),
                ),
              ),
            ),
          ],
        ),
        content: Text(
          AppLanguage.tr('attendance.rfid.otg_description'),
          style: const TextStyle(
            fontSize: 15,
            color: Colors.black87,
            height: 1.5,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              AppLanguage.tr('attendance.rfid.later'),
              style: TextStyle(
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9333EA),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.pop(context);
              _openOTGSettings();
            },
            child: Text(
              AppLanguage.tr('attendance.rfid.activate_now'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showSyncDialog() async {
    final stats = await _syncService.getSyncStats();

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(AppLanguage.tr('attendance.rfid.sync_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${AppLanguage.tr('attendance.rfid.total_pending')}: ${stats['pending'] ?? 0}',
            ),
            Text(
              '${AppLanguage.tr('attendance.rfid.success_count')}: ${stats['synced'] ?? 0}',
            ),
            Text(
              '${AppLanguage.tr('attendance.rfid.failed_count')}: ${stats['failed'] ?? 0}',
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                await _syncService.syncAllPendingAttendances();
                await _loadPendingSyncCount();
              },
              child: Text(AppLanguage.tr('attendance.rfid.start_sync')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLanguage.tr('attendance.rfid.close')),
          ),
        ],
      ),
    );
  }

  String _composeMemberName(Map<String, dynamic>? memberInfo) {
    final profile = memberInfo?['user_profiles'] as Map<String, dynamic>?;
    if (profile == null) {
      debugPrint('⚠️ No user profile found, using "Member"');
      return AppLanguage.tr('attendance.rfid.member');
    }

    final displayName = (profile['display_name'] as String?)?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }

    final first = profile['first_name'] as String? ?? '';
    final last = profile['last_name'] as String? ?? '';
    final name = '$first $last'.trim();

    if (name.isEmpty) {
      debugPrint('⚠️ No name found, using "Member"');
      return AppLanguage.tr('attendance.rfid.member');
    }

    return name;
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '-';
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime? time) => _formatTime(time);

  String _formatDate(DateTime? time) {
    if (time == null) return '-';
    const months = [
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
    return '${time.day} ${months[time.month - 1]} ${time.year}';
  }

  void _startPulseAnimation() {
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) {
      if (mounted) {
        setState(() {
          _pulseRadius = _pulseRadius == 0.0 ? 20.0 : 0.0;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Format Date & Time
    final dateStr = _formatDate(_currentTime).toUpperCase();
    final timeStr = _formatTimeShort(_currentTime);
    final amPm = _formatAmPm(_currentTime);

    return Scaffold(
      backgroundColor: Colors.white, // White background as per mockup
      body: GestureDetector(
        onTap: () => _cardFocusNode.requestFocus(),
        child: Stack(
          children: [
            // Hidden Input for RFID
            Offstage(
              offstage: true,
              child: TextField(
                controller: _cardController,
                focusNode: _cardFocusNode,
                autofocus: true,
                showCursor: false,
                enableInteractiveSelection: false,
                keyboardType: TextInputType.none,
                decoration: const InputDecoration(border: InputBorder.none),
                onSubmitted: (_) => _handleCardScan(),
              ),
            ),

            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 20),

                  // 1. CLOCK & DATE HEADER
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        // Phantom element on the left to balance the AM/PM on the right
                        // and keep the clock numbers exactly in the middle.
                        Text(
                          amPm,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.transparent, // Invisible
                          ),
                        ),
                        const SizedBox(width: 4), // Gap
                        Text(
                          timeStr,
                          style: const TextStyle(
                            fontSize: 72,
                            fontWeight: FontWeight.w400,
                            color: Colors.black87,
                            letterSpacing: -2,
                          ),
                        ),
                        const SizedBox(width: 4), // Gap
                        Text(
                          amPm,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      dateStr,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600, // Changed to gray
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),

                  const SizedBox(height: 40),

                  // 2. SELECT SHIFT CARD (Purple)
                  Padding(
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
                              color: const Color(0xFF9333EA).withOpacity(0.4),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.swap_horiz,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                _selectedMode != null
                                    ? '${_selectedMode!['name']} - ${_attendanceMode == 'check_in' ? AppLanguage.tr('attendance.rfid.in') : AppLanguage.tr('attendance.rfid.out')}'
                                    : AppLanguage.tr('attendance.rfid.select_shift'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right,
                              color: Colors.white,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 3. PULSING RFID ANIMATION (Only shown if no entries)
                  if (_filteredEntries.isEmpty)
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                // Outer Pulse
                                TweenAnimationBuilder(
                                  tween: Tween<double>(begin: 0, end: 1),
                                  duration: const Duration(seconds: 2),
                                  builder: (context, double value, child) {
                                    return Container(
                                      width: 200 + (value * 20),
                                      height: 200 + (value * 20),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: const Color(
                                            0xFF9333EA,
                                          ).withOpacity(0.1 * (1 - value)),
                                          width: 1,
                                        ),
                                      ),
                                    );
                                  },
                                  onEnd: () => setState(() {}), // Loop
                                ),
                                // Inner Circles
                                Container(
                                  width: 180,
                                  height: 180,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: const Color(
                                      0xFF9333EA,
                                    ).withOpacity(0.05),
                                  ),
                                ),
                                Container(
                                  width: 130,
                                  height: 130,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black12,
                                        blurRadius: 20,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.nfc, // RFID Icon
                                      size: 64,
                                      color: Color(0xFF9333EA),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 32),
                            Text(
                              'Scan your card here',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 4. ATTENDANCE LIST (Expanded when entries present)
                  if (_filteredEntries.isNotEmpty)
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.only(top: 24),
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 8,
                          ),
                          itemCount: _filteredEntries.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, index) =>
                              _buildNewEntryCard(_filteredEntries[index]),
                        ),
                      ),
                    )
                  else
                    const SizedBox(
                      height: 220,
                    ), // Placeholder height when empty
                ],
              ),
            ),

            // Menu Button (Top Right)
            // Header Buttons
            Positioned(
              top: 40,
              left: 20,
              right: 20,
              child: SafeArea(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Back Button
                    CircleAvatar(
                      backgroundColor: Colors.grey,
                      radius: 20,
                      child: IconButton(
                        icon: const Icon(
                          Icons.chevron_left,
                          color: Colors.white,
                          size: 24,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),

                    Row(
                      children: [
                        // Manual Check Button
                        CircleAvatar(
                          backgroundColor: Colors.grey,
                          radius: 20,
                          child: IconButton(
                            icon: const Icon(
                              Icons.assignment_ind_outlined,
                              color: Colors.white,
                              size: 22,
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ManualCheckPage(
                                    organizationMemberId:
                                        widget.organizationMemberId,
                                    memberData: widget.memberData,
                                    initialShiftName: _workTimeMode,
                                    sourceMode: 'RFID Kiosk',
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
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

  // Helper Formats
  String _formatTimeShort(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  String _formatAmPm(DateTime time) {
    return time.hour >= 12 ? 'PM' : 'AM';
  }

  // NEW BOTTOM SHEET UI
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
              const Text(
                'Select Your Shift',
                style: TextStyle(
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
      // Optionally show IN/OUT selector if needed, or default to IN if not specified
      // For this UI, user just selects shift. The actual action (IN/OUT) usually inferred or separate toggles?
      // User request didn't specify IN/OUT buttons, just "Select Shift".
      // Assuming 'check_in' as default or handled elsewhere.
      // Re-using _showInOutSelector if we want to confirm action
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

  Widget _buildNewEntryCard(_AttendanceEntry entry) {
    final profile =
        entry.memberInfo['user_profiles'] as Map<String, dynamic>? ?? {};
    final photoPath = profile['profile_photo_url'] as String?;
    final name = _composeMemberName(entry.memberInfo);

    ImageProvider? imageProvider;
    if (photoPath != null && photoPath.isNotEmpty) {
      if (photoPath.startsWith('http')) {
        imageProvider = NetworkImage(photoPath);
      } else {
        imageProvider = NetworkImage(
          _supabase.storage
              .from('profile-photos')
              .getPublicUrl('mass-profile/$photoPath'),
        );
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB), // Very light grey
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: Colors.grey.shade300,
            backgroundImage: imageProvider,
            child: imageProvider == null
                ? const Icon(Icons.person, color: Colors.grey)
                : null,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.black87,
                  ),
                ),
                Text(
                  entry.memberInfo['departments']?['name'] as String? ??
                      AppLanguage.tr('Petugas.members.no_department'),
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                // Format: 09:00 - 17:00
                _formatTimeShort(entry.timestamp),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF9333EA),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              // ✅ Action Label
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: entry.action == 'check_in'
                      ? Colors.green.shade50
                      : entry.action == 'check_out'
                      ? Colors.red.shade50
                      : entry.action == 'break_out'
                      ? Colors.orange.shade50
                      : Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: entry.action == 'check_in'
                        ? Colors.green.shade200
                        : entry.action == 'check_out'
                        ? Colors.red.shade200
                        : entry.action == 'break_out'
                        ? Colors.orange.shade200
                        : Colors.blue.shade200,
                  ),
                ),
                child: Text(
                  entry.action == 'check_in'
                      ? AppLanguage.tr('attendance.rfid.in')
                      : entry.action == 'check_out'
                      ? AppLanguage.tr('attendance.rfid.out')
                      : entry.action == 'break_start'
                      ? AppLanguage.tr('attendance.rfid.break_in').toUpperCase()
                      : AppLanguage.tr('attendance.rfid.break_out').toUpperCase(),
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    color: entry.action == 'check_in'
                        ? Colors.green.shade700
                        : entry.action == 'check_out'
                        ? Colors.red.shade700
                        : entry.action == 'break_out'
                        ? Colors.orange.shade700
                        : Colors.blue.shade700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              if (entry.workTimeMode != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Text(
                    entry.workTimeMode!,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue.shade700,
                    ),
                  ),
                ),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Text(
                  entry.method.toUpperCase(),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AttendanceEntry {
  final int memberId;
  final Map<String, dynamic> memberInfo;
  final String cardNumber;
  final String action;
  final DateTime timestamp;
  final String? workTimeMode;
  final String method = 'RFID';

  _AttendanceEntry({
    required this.memberId,
    required this.memberInfo,
    required this.cardNumber,
    required this.action,
    required this.timestamp,
    this.workTimeMode,
  });
}
