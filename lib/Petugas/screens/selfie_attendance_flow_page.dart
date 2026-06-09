import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/language_helper.dart';
import 'package:intl/intl.dart';
import '../../services/camera_service.dart';
import '../../attendance/services/attendance_service.dart';
import '../../attendance/screens/camera_selfie_screen.dart';
import 'member_selection_page.dart';
import 'device_selection_screen.dart';
import '../../services/supabase_storage_service.dart';
import '../../models/attendance_model.dart';
import '../../helpers/timezone_helper.dart';

class SelfieAttendanceFlowPage extends StatefulWidget {
  final int organizationId;
  final String organizationName;
  final Map<String, dynamic> petugasData;
  final bool isSelfAttendance;

  const SelfieAttendanceFlowPage({
    super.key,
    required this.organizationId,
    required this.organizationName,
    required this.petugasData,
    this.isSelfAttendance = false,
  });

  @override
  State<SelfieAttendanceFlowPage> createState() =>
      _SelfieAttendanceFlowPageState();
}

class _SelfieAttendanceFlowPageState extends State<SelfieAttendanceFlowPage> {
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseStorageService _storageService = SupabaseStorageService();

  bool _isProcessing = false;

  static const Color primaryColor = Color(0xFF6366F1);
  static const Color backgroundColor = Color(0xFF1F2937);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startSelfieAttendanceFlow();
    });
  }

  Future<void> _startSelfieAttendanceFlow() async {
    int currentStep = 1;
    Map<String, dynamic>? selectedMember;
    Map<String, dynamic>? selectedShift;
    Map<String, dynamic>? locationData;
    String? selectedAction;
    String? photoPath;

    try {
      while (mounted) {
        if (currentStep == 1) {
          if (widget.isSelfAttendance) {
            selectedMember = widget.petugasData;
          } else {
            selectedMember = await _selectMember();
          }

          if (selectedMember == null) {
            Navigator.pop(context);
            return;
          }
          currentStep = 3;
        } else if (currentStep == 3) {
          final selection = await _selectLocation(selectedMember!['id']);
          if (selection == null) {
            Navigator.pop(context);
            return;
          }
          locationData = selection;
          selectedShift = selection['selectedShift'];

          selectedAction = await _selectAction(
            selectedMember['id'],
            selectedShift: selectedShift,
          );

          if (selectedAction == null) {
            continue;
          }
          currentStep = 4;
        } else if (currentStep == 4) {
          photoPath = await _takeSelfie();
          if (photoPath == null) {
            currentStep = 3;
            continue;
          }
          currentStep = 5;
        } else if (currentStep == 5) {
          await _submitSelfieAttendance(
            member: selectedMember!,
            locationData: locationData!,
            photoPath: photoPath!,
            selectedShift: selectedShift,
            selectedAction: selectedAction!,
          );

          if (mounted) {
            Navigator.pop(context, {'success': true});
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('Error in selfie attendance flow: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${AppLanguage.tr('attendance.selfie.error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<String?> _selectAction(
    int memberId, {
    Map<String, dynamic>? selectedShift,
  }) async {
    final todayAttendance = await _attendanceService.getTodayAttendance(
      memberId,
      organizationTimezone: 'Asia/Jakarta',
    );

    final schedule = await _attendanceService.getTodaySchedule(
      memberId,
      organizationTimezone: 'Asia/Jakarta',
    );

    String? autoAction;
    bool canBreakOut = false;
    bool canBreakIn = false;
    String breakHint = 'Mencari jadwal...';

    final now = TimezoneHelper.convertUtcToOrgTimezone(
      DateTime.now().toUtc(),
      'Asia/Jakarta',
    );
    final currentTime = TimeOfDay.fromDateTime(now);
    final currentMin = currentTime.hour * 60 + currentTime.minute;

    String? effectiveBreakStart;
    String? effectiveBreakEnd;

    if (selectedShift != null &&
        selectedShift['break_start'] != null &&
        selectedShift['break_end'] != null) {
      effectiveBreakStart = selectedShift['break_start'];
      effectiveBreakEnd = selectedShift['break_end'];
    } else if (schedule.breakStart != null && schedule.breakEnd != null) {
      effectiveBreakStart = schedule.breakStart;
      effectiveBreakEnd = schedule.breakEnd;
    } else {
      try {
        final dbDayOfWeek = now.weekday % 7;

        final shiftsRes = await Supabase.instance.client
            .from('shifts')
            .select('break_start, break_end')
            .eq('organization_id', widget.organizationId)
            .eq('is_active', true);

        for (final shift in shiftsRes) {
          final bStartStr = shift['break_start'] as String?;
          final bEndStr = shift['break_end'] as String?;
          if (bStartStr != null && bEndStr != null) {
            final bStart = _parseBreakTime(bStartStr);
            final bEnd = _parseBreakTime(bEndStr);
            if (bStart != null && bEnd != null) {
              final startMin = bStart.hour * 60 + bStart.minute;
              final endMin = bEnd.hour * 60 + bEnd.minute;
              const windowMin = 30;

              if (currentMin >= (startMin - windowMin) &&
                  currentMin <= (endMin + windowMin)) {
                effectiveBreakStart = bStartStr;
                effectiveBreakEnd = bEndStr;
                break;
              }
            }
          }
        }

        if (effectiveBreakStart == null) {
          final schedulesRes = await Supabase.instance.client
              .from('work_schedules')
              .select('id, name')
              .eq('organization_id', widget.organizationId)
              .eq('is_active', true);

          final scheduleIds = (schedulesRes as List)
              .map((s) => s['id'] as int)
              .toList();

          if (scheduleIds.isNotEmpty) {
            final detailsRes = await Supabase.instance.client
                .from('work_schedule_details')
                .select('break_start, break_end, work_schedule_id')
                .filter('work_schedule_id', 'in', '(${scheduleIds.join(',')})')
                .eq('day_of_week', dbDayOfWeek);

            for (final detail in detailsRes) {
              final bStartStr = detail['break_start'] as String?;
              final bEndStr = detail['break_end'] as String?;
              if (bStartStr != null && bEndStr != null) {
                final bStart = _parseBreakTime(bStartStr);
                final bEnd = _parseBreakTime(bEndStr);
                if (bStart != null && bEnd != null) {
                  final startMin = bStart.hour * 60 + bStart.minute;
                  final endMin = bEnd.hour * 60 + bEnd.minute;
                  const windowMin = 30;

                  if (currentMin >= (startMin - windowMin) &&
                      currentMin <= (endMin + windowMin)) {
                    effectiveBreakStart = bStartStr;
                    effectiveBreakEnd = bEndStr;
                    break;
                  }
                }
              }
            }
            if (effectiveBreakStart == null && detailsRes.isNotEmpty) {
              breakHint = 'Jam istirahat di luar jendela waktu.';
            }
          }
        }
      } catch (e) {
        breakHint = 'Gagal memuat jadwal';
      }
    }

    if (effectiveBreakStart != null && effectiveBreakEnd != null) {
      final bStart = _parseBreakTime(effectiveBreakStart);
      final bEnd = _parseBreakTime(effectiveBreakEnd);

      if (bStart != null && bEnd != null) {
        final startMin = bStart.hour * 60 + bStart.minute;
        final endMin = bEnd.hour * 60 + bEnd.minute;
        const windowMin = 30;

        canBreakOut =
            currentMin >= (startMin - windowMin) &&
            currentMin <= (endMin + windowMin);
        canBreakIn =
            currentMin >= (startMin - windowMin) &&
            currentMin <= (endMin + windowMin);

        if (canBreakOut) {
          breakHint =
              'Istirahat tersedia ($effectiveBreakStart - $effectiveBreakEnd)';
        } else {
          breakHint =
              'Jadwal istirahat: $effectiveBreakStart - $effectiveBreakEnd';
        }
      }
    } else if (breakHint.startsWith('Mencari')) {
      breakHint = 'Tidak ada jadwal istirahat aktif.';
    }

    if (todayAttendance == null || todayAttendance.actualCheckIn == null) {
      autoAction = 'check_in';
      if (canBreakOut || canBreakIn) {
        breakHint =
            'Silakan Masuk terlebih dulu. Jam istirahat: $effectiveBreakStart - $effectiveBreakEnd';
      }
    } else {
      if (canBreakOut) {
        if (todayAttendance.actualBreakStart == null) {
          autoAction = 'break_start';
        } else if (todayAttendance.actualBreakEnd == null) {
          autoAction = 'break_end';
        } else {
          autoAction = 'check_out';
        }
      } else {
        autoAction = 'check_out';
      }
    }

    if (!mounted) return null;

    return await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => ActionSelectionBottomSheet(
        autoAction: autoAction,
        canBreakOut: canBreakOut,
        canBreakIn: canBreakIn,
        breakHint: breakHint,
      ),
    );
  }

  TimeOfDay? _parseBreakTime(String timeStr) {
    try {
      final parts = timeStr.split(':');
      if (parts.length >= 2) {
        return TimeOfDay(
          hour: int.parse(parts[0]),
          minute: int.parse(parts[1]),
        );
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> _selectMember() async {
    return await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => MemberSelectionPage(
          organizationId: widget.organizationId,
          organizationName: widget.organizationName,
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _selectLocation(int memberId) async {
    return await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => DeviceSelectionScreen(
          organizationId: widget.organizationId.toString(),
          organizationName: widget.organizationName,
          isRequired: false,
          allowCurrentLocation: true,
          memberId: memberId,
        ),
      ),
    );
  }

  Future<String?> _takeSelfie() async {
    try {
      final cameras = await CameraService.initializeCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available');
      }

      return await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (context) => CameraSelfieScreen(cameras: cameras),
        ),
      );
    } catch (e) {
      debugPrint('Error initializing camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${AppLanguage.tr('attendance.selfie.camera_error')}: $e',
            ),
          ),
        );
      }
      return null;
    }
  }

  Future<void> _submitSelfieAttendance({
    required Map<String, dynamic> member,
    required Map<String, dynamic> locationData,
    required String photoPath,
    required String selectedAction,
    Map<String, dynamic>? selectedShift,
  }) async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      // Show loading dialog
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => WillPopScope(
            onWillPop: () async => false,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      AppLanguage.tr('attendance.selfie.submitting'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      // 1. Upload photo to Supabase Storage
      final photoUrl = await _uploadPhoto(photoPath, member['id']);
      debugPrint('Photo URL: $photoUrl'); // DEBUG

      // 2. Prepare location data with photo_url (FIX: Pastikan photo_url tersimpan)
      final latitude = locationData['latitude'] as double?;
      final longitude = locationData['longitude'] as double?;
      final accuracy = locationData['accuracy'] as double?;

      // ========== PERBAIKAN UTAMA ==========
      // Location Map HARUS berisi photo_url agar foto muncul di database
      final locationMap = {
        'photo_url': photoUrl, // ← INI YANG PALING PENTING!
        'latitude': latitude,
        'longitude': longitude,
        if (accuracy != null) 'accuracy': accuracy,
        if (locationData['type'] == 'device')
          'device_id':
              (locationData['selectedDevice'] as AttendanceDevice?)?.id,
        if (locationData['reason'] != null) 'reason': locationData['reason'],
      };

      // Raw data sebagai backup
      final rawData = {
        'photo_url': photoUrl, // ← Backup juga di raw_data
        if (selectedShift != null) 'selected_shift_id': selectedShift['id'],
        if (selectedShift != null) 'selected_shift_name': selectedShift['name'],
      };

      final memberId = member['id'] as int;
      final nowUtc = DateTime.now().toUtc();

      // 3. Langsung insert ke attendance_logs (memastikan data tersimpan)
      final supabase = Supabase.instance.client;

      await supabase.from('attendance_logs').insert({
        'organization_member_id': memberId,
        'event_type': selectedAction,
        'event_time': nowUtc.toIso8601String(),
        'method': 'selfie',
        'location': locationMap, // ← Sekarang berisi photo_url!
        'raw_data': rawData,
      });

      debugPrint('Attendance log inserted with photo_url in location');

      // 4. Submit ke AttendanceService untuk update records
      switch (selectedAction) {
        case 'check_in':
          await _attendanceService.checkIn(
            organizationMemberId: memberId,
            photoUrl: photoUrl,
            method: 'selfie',
            organizationTimezone: 'Asia/Jakarta',
            location: locationMap,
            deviceId: locationData['type'] == 'device'
                ? int.tryParse(
                    (locationData['selectedDevice'] as AttendanceDevice?)?.id ??
                        '',
                  )
                : null,
            rawData: rawData,
          );
          break;
        case 'check_out':
          await _attendanceService.checkOut(
            organizationMemberId: memberId,
            photoUrl: photoUrl,
            method: 'selfie',
            organizationTimezone: 'Asia/Jakarta',
            location: locationMap,
            deviceId: locationData['type'] == 'device'
                ? int.tryParse(
                    (locationData['selectedDevice'] as AttendanceDevice?)?.id ??
                        '',
                  )
                : null,
            rawData: rawData,
          );
          break;
        case 'break_start':
          await _attendanceService.breakOut(
            organizationMemberId: memberId,
            photoUrl: photoUrl,
            method: 'selfie',
            organizationTimezone: 'Asia/Jakarta',
            location: locationMap,
            deviceId: locationData['type'] == 'device'
                ? int.tryParse(
                    (locationData['selectedDevice'] as AttendanceDevice?)?.id ??
                        '',
                  )
                : null,
            rawData: rawData,
          );
          break;
        case 'break_end':
          await _attendanceService.breakIn(
            organizationMemberId: memberId,
            photoUrl: photoUrl,
            method: 'selfie',
            organizationTimezone: 'Asia/Jakarta',
            location: locationMap,
            deviceId: locationData['type'] == 'device'
                ? int.tryParse(
                    (locationData['selectedDevice'] as AttendanceDevice?)?.id ??
                        '',
                  )
                : null,
            rawData: rawData,
          );
          break;
      }

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Show success message
      if (mounted) {
        final locationName = locationData['type'] == 'device'
            ? _getDeviceDisplayName(locationData['selectedDevice'])
            : AppLanguage.tr('attendance.selfie.current_location');

        await _showSuccessOverlay(
          photoPath: photoPath,
          locationName: locationName,
          time: DateFormat('hh:mm aa').format(DateTime.now()),
          memberName: _getMemberName(member),
          shiftName:
              selectedShift?['name'] ??
              AppLanguage.tr('attendance.selfie.non_scheduled'),
          action: selectedAction,
        );
      }
    } catch (e) {
      debugPrint('Error submitting selfie attendance: $e');

      // Close loading dialog if open
      if (mounted) Navigator.pop(context);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${AppLanguage.tr('attendance.selfie.error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _showSuccessOverlay({
    required String photoPath,
    required String locationName,
    required String time,
    required String action,
    String? memberName,
    String? shiftName,
  }) async {
    if (!mounted) return;

    final dialogFuture = showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.file(File(photoPath), fit: BoxFit.cover),
              ),
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: Container(color: Colors.black.withOpacity(0.6)),
                ),
              ),
              Center(
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.85,
                  padding: const EdgeInsets.symmetric(
                    vertical: 40,
                    horizontal: 24,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1B2E).withOpacity(0.95),
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 40,
                        offset: const Offset(0, 20),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: const BoxDecoration(
                          color: Color(0xFF8B5CF6),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        AppLanguage.tr('attendance.selfie.attendance_success'),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 32),
                      _buildInfoRow(
                        icon: Icons.person_rounded,
                        label: AppLanguage.tr('attendance.selfie.member'),
                        value: memberName ?? 'Unknown',
                      ),
                      const SizedBox(height: 12),
                      _buildInfoRow(
                        icon: Icons.access_time_filled_rounded,
                        label: AppLanguage.tr('attendance.selfie.time'),
                        value: time,
                      ),
                      const SizedBox(height: 12),
                      _buildInfoRow(
                        icon: Icons.calendar_today_rounded,
                        label: AppLanguage.tr('attendance.selfie.shift'),
                        value:
                            shiftName ??
                            AppLanguage.tr('attendance.selfie.non_scheduled'),
                      ),
                      const SizedBox(height: 12),
                      _buildInfoRow(
                        icon: Icons.location_on_rounded,
                        label: AppLanguage.tr('attendance.selfie.location'),
                        value: locationName,
                      ),
                      const SizedBox(height: 12),
                      _buildInfoRow(
                        icon: Icons.info_outline_rounded,
                        label: AppLanguage.tr('attendance.selfie.action'),
                        value: _getActionDisplayName(action),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    });

    return dialogFuture;
  }

  String _getActionDisplayName(String action) {
    switch (action) {
      case 'check_in':
        return AppLanguage.tr('attendance.selfie.in');
      case 'check_out':
        return AppLanguage.tr('attendance.selfie.out');
      case 'break_start':
        return AppLanguage.tr('attendance.selfie.break_in');
      case 'break_end':
        return AppLanguage.tr('attendance.selfie.break_out');
      default:
        return action.toUpperCase();
    }
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF8B5CF6).withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFFA78BFA), size: 18),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 14,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  String _getDeviceDisplayName(dynamic device) {
    if (device is AttendanceDevice) {
      if (device.location != null && device.location!.isNotEmpty) {
        return device.location!;
      }
      return device.deviceName;
    }
    return AppLanguage.tr('attendance.selfie.unknown_location');
  }

  Future<String> _uploadPhoto(String photoPath, int memberId) async {
    try {
      final photoFile = File(photoPath);
      if (!await photoFile.exists()) {
        throw Exception('Photo file not found at $photoPath');
      }

      final publicUrl = await _storageService.uploadAttendancePhoto(
        photoFile,
        memberId,
        'selfie',
      );

      debugPrint('Photo uploaded via storage service: $publicUrl');
      return publicUrl;
    } catch (e) {
      debugPrint('Error uploading photo via storage service: $e');
      throw Exception('Failed to upload photo: $e');
    }
  }

  String _getMemberName(Map<String, dynamic> member) {
    final userProfile = member['user_profiles'] as Map<String, dynamic>?;

    if (userProfile != null) {
      final displayName = userProfile['display_name'] as String?;
      if (displayName != null && displayName.isNotEmpty) {
        return displayName;
      }

      final firstName = userProfile['first_name'] as String? ?? '';
      final lastName = userProfile['last_name'] as String? ?? '';
      final fullName = '$firstName $lastName'.trim();
      if (fullName.isNotEmpty) return fullName;
    }

    if (member['employee_id'] != null) return 'Member ${member['employee_id']}';
    return 'Member #${member['id']}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
            ),
            const SizedBox(height: 16),
            Text(
              AppLanguage.tr('attendance.selfie.preparing'),
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}

class ActionSelectionBottomSheet extends StatelessWidget {
  final String? autoAction;
  final bool canBreakOut;
  final bool canBreakIn;
  final String? breakHint;

  const ActionSelectionBottomSheet({
    super.key,
    this.autoAction,
    this.canBreakOut = true,
    this.canBreakIn = true,
    this.breakHint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Color(0xFF1F2937),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () => Navigator.pop(context, 'check_in'),
                  child: Text(
                    AppLanguage.tr('attendance.selfie.in'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () => Navigator.pop(context, 'check_out'),
                  child: Text(
                    AppLanguage.tr('attendance.selfie.out'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.white.withOpacity(0.1),
                    disabledForegroundColor: Colors.white.withOpacity(0.5),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: canBreakOut
                      ? () => Navigator.pop(context, 'break_start')
                      : null,
                  child: Text(
                    AppLanguage.tr('attendance.selfie.break_in'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.white.withOpacity(0.1),
                    disabledForegroundColor: Colors.white.withOpacity(0.5),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: canBreakIn
                      ? () => Navigator.pop(context, 'break_end')
                      : null,
                  child: Text(
                    AppLanguage.tr('attendance.selfie.break_out'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (breakHint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                breakHint!,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.orange.shade700,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
