import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart' as geolocator;
import '../../models/attendance_record.dart';
import '../../models/work_schedule_models.dart';
import '../../helpers/timezone_helper.dart';
import '../../services/offline_database_service.dart';

class AttendanceService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();

  // -- Schedule Logic Start --

  /// Determines the effective schedule for a member on a specific date (default: today)
  Future<DailySchedule> getTodaySchedule(
    int organizationMemberId, {
    DateTime? date,
    String? organizationTimezone,
  }) async {
    try {
      final orgTimezone = organizationTimezone ?? 'Asia/Jakarta';
      final targetDate =
          date ??
          TimezoneHelper.getCurrentUtcTime(); // Use UTC or handle offset?
      // Better: Convert targetDate to Organization's "Date String" YYYY-MM-DD
      // For simplicity, let's assume we need the YYYY-MM-DD in Org Timezone
      final dateStr = TimezoneHelper.getCurrentDateInOrgTimezone(
        orgTimezone,
      ); // This gets TODAY's date string

      // 1. Check Shift Assignments (Highest Priority)
      // "Is there a specific override for today?"
      Map<String, dynamic>? shiftAssignmentRes;
      try {
        shiftAssignmentRes = await _supabase
            .from('shift_assignments')
            .select('*, shifts(*)')
            .eq('organization_member_id', organizationMemberId)
            .eq('assignment_date', dateStr)
            .maybeSingle();
      } catch (e) {
        debugPrint('🌐 Offline/Error getting shift assignments: $e');
      }

      if (shiftAssignmentRes != null) {
        final assignment = ShiftAssignment.fromJson(shiftAssignmentRes);
        if (assignment.shift != null) {
          final result = DailySchedule(
            isWorkingDay: true,
            startTime: assignment.shift!.startTime,
            endTime: assignment.shift!.endTime,
            breakStart: assignment.shift!.breakStart,
            breakEnd: assignment.shift!.breakEnd,
            source: 'shift_assignment',
            scheduleName: assignment.shift!.name,
            shiftId: assignment.shift!.id,
            isOvernight: assignment.shift!.overnight,
          );
          // Cache successful result
          _offlineDb.cacheSchedule(organizationMemberId, result.toJson());
          return result;
        }
      }

      // 2. Check Member Schedules (Long-term assignment)
      // "What is their regular roster?"
      Map<String, dynamic>? memberScheduleRes;
      try {
        memberScheduleRes = await _supabase
            .from('member_schedules')
            .select('*, shifts(*), work_schedules(*)')
            .eq('organization_member_id', organizationMemberId)
            .lte('effective_date', dateStr)
            .or(
              'end_date.is.null,end_date.gte.$dateStr',
            ) // Open-ended or valid range
            .order('effective_date', ascending: false) // Get most recent
            .limit(1)
            .maybeSingle();
      } catch (e) {
        debugPrint('🌐 Offline/Error getting member schedules: $e');
      }

      if (memberScheduleRes != null) {
        final memberSchedule = MemberSchedule.fromJson(memberScheduleRes);

        // 2a. Assigned to a specific Shift (e.g. "Night Crew" - always same hours)
        if (memberSchedule.shiftId != null &&
            memberScheduleRes['shifts'] != null) {
          final shift = Shift.fromJson(memberScheduleRes['shifts']);
          final result = DailySchedule(
            isWorkingDay: true,
            startTime: shift.startTime,
            endTime: shift.endTime,
            breakStart: shift.breakStart,
            breakEnd: shift.breakEnd,
            source: 'member_shift',
            scheduleName: shift.name,
            shiftId: shift.id,
            isOvernight: shift.overnight,
          );
          // Cache successful result
          _offlineDb.cacheSchedule(organizationMemberId, result.toJson());
          return result;
        }

        // 2b. Assigned to a Work Schedule (e.g. "Regular 9-5", "Roster A")
        if (memberSchedule.workScheduleId != null) {
          final result = await _getScheduleDetailForDate(
            memberSchedule.workScheduleId!,
            DateTime.parse(dateStr).weekday,
            'member_schedule',
          );
          // Cache successful result
          _offlineDb.cacheSchedule(organizationMemberId, result.toJson());
          return result;
        }
      }

      // 3. Check Default Schedule (Fallback)
      // "What is the general office hour?"
      try {
        final memberData = await _supabase
            .from('organization_members')
            .select('organization_id')
            .eq('id', organizationMemberId)
            .single();

        final organizationId = memberData['organization_id'] as int;

        final defaultScheduleRes = await _supabase
            .from('work_schedules')
            .select()
            .eq('organization_id', organizationId)
            .eq('is_default', true)
            .maybeSingle();

        if (defaultScheduleRes != null) {
          final schedule = WorkSchedule.fromJson(defaultScheduleRes);
          final result = await _getScheduleDetailForDate(
            schedule.id,
            DateTime.parse(dateStr).weekday,
            'default_schedule',
          );
          // Cache successful result
          _offlineDb.cacheSchedule(organizationMemberId, result.toJson());
          return result;
        }
      } catch (e) {
        debugPrint('🌐 Offline/Error getting default schedule: $e');
      }

      // 4. No Online Schedule found or Offline -> Try Cache
      final cached = await _offlineDb.getCachedSchedule(organizationMemberId);
      if (cached != null) {
        debugPrint('💾 Using cached schedule for member $organizationMemberId');
        return DailySchedule.fromJson(cached);
      }

      // 5. No Schedule
      return DailySchedule.unscheduled();
    } catch (e) {
      debugPrint('⚠️ Error determining schedule: $e');

      // Attempt cache even on unknown error
      try {
        final cached = await _offlineDb.getCachedSchedule(organizationMemberId);
        if (cached != null) return DailySchedule.fromJson(cached);
      } catch (_) {}

      return DailySchedule.unscheduled();
    }
  }

  /// Helper to get detail for a specific weekday from a schedule
  Future<DailySchedule> _getScheduleDetailForDate(
    int scheduleId,
    int weekday, // Flutter DateTime: 1 (Mon) to 7 (Sun). SQL often 0-6.
    String sourceName,
  ) async {
    // SQL: "day_of_week INT CHECK (between 0 and 6)"
    // Typically 0=Sunday, 1=Monday... 6=Saturday.
    // Flutter: 1=Monday... 7=Sunday.
    // Mapping: Flutter % 7. (7%7=0 Sunday, 1%7=1 Monday).
    final dbDayOfWeek = weekday % 7;

    final detailRes = await _supabase
        .from('work_schedule_details')
        .select('*, work_schedules(name)')
        .eq('work_schedule_id', scheduleId)
        .eq('day_of_week', dbDayOfWeek)
        .maybeSingle();

    if (detailRes != null) {
      final detail = WorkScheduleDetail.fromJson(detailRes);

      if (!detail.isWorkingDay) {
        return DailySchedule(
          isWorkingDay: false,
          source: sourceName,
          scheduleName: detailRes['work_schedules']['name'],
          workScheduleId: scheduleId,
        );
      }

      return DailySchedule(
        isWorkingDay: true,
        startTime: detail.startTime,
        endTime: detail.endTime,
        breakStart: detail.breakStart,
        breakEnd: detail.breakEnd,
        source: sourceName,
        scheduleName: detailRes['work_schedules']['name'],
        workScheduleId: scheduleId,
      );
    }

    // Detail missing for this day? Treat as Off? Or Default to 9-5?
    // Usually implies "Off" or "Day not configured".
    return DailySchedule(
      isWorkingDay: false,
      source: sourceName,
      workScheduleId: scheduleId,
      scheduleName: 'Day Not Configured',
    );
  }

  // -- Schedule Logic End --

  // Check in attendance
  Future<AttendanceRecord> checkIn({
    required int organizationMemberId,
    required String photoUrl,
    required String method,
    String? organizationTimezone,
    Map<String, dynamic>? location,
    int? deviceId,
    String? ipAddress,
    String? userAgent,
    int? applicationId,
    Map<String, dynamic>? rawData,
  }) async {
    debugPrint(
      '🌐 AttendanceService: Starting online Check-In for member $organizationMemberId',
    );
    try {
      // Use organization timezone for date calculation, or default to device timezone
      final orgTimezone = organizationTimezone ?? 'Asia/Jakarta';
      // Get current UTC time (universal, represents "now")
      // Use offline_timestamp if available for manual sync
      final nowUtc = (rawData != null && rawData['offline_timestamp'] != null)
          ? DateTime.parse(rawData['offline_timestamp']).toUtc()
          : TimezoneHelper.getCurrentUtcTime();

      final todayStr = TimezoneHelper.getDateInOrgTimezone(nowUtc, orgTimezone);

      final locationWithPhoto = _decorateLocationWithPhoto(location, photoUrl);

      // --- [VALIDATION START] ---
      // Get Schedule for today
      final schedule = await getTodaySchedule(
        organizationMemberId,
        organizationTimezone: orgTimezone,
      );

      // (Optional) Calculate Late Minutes
      int lateMinutes = 0;
      if (schedule.isWorkingDay &&
          schedule.startTime != null &&
          schedule.startTime!.isNotEmpty) {
        try {
          // 1. Get Current Time in Org Timezone
          // final nowUtc = TimezoneHelper.getCurrentUtcTime(); // Already defined above
          final nowInOrg = TimezoneHelper.convertUtcToOrgTimezone(
            nowUtc,
            orgTimezone,
          );

          // 2. Parse Schedule Start Time (HH:mm:ss)
          final parts = schedule.startTime!.split(':');
          final startHour = int.parse(parts[0]);
          final startMinute = int.parse(parts[1]);

          // 3. Construct Schedule DateTime for "Today"
          // IMPORTANT: nowInOrg is a UTC-based DateTime shifted by the timezone offset.
          // We MUST use DateTime.utc to create scheduleTime to prevent Flutter from
          // adding/subtracting the device's local timezone offset during comparison.
          final scheduleTime = DateTime.utc(
            nowInOrg.year,
            nowInOrg.month,
            nowInOrg.day,
            startHour,
            startMinute,
          );

          // 4. Calculate Difference
          final diff = nowInOrg.difference(scheduleTime).inMinutes;
          if (diff > 0) {
            lateMinutes = diff;
          }
        } catch (e) {
          debugPrint('⚠️ Late calculation error: $e');
          // Ignore time calc errors strictly
        }
      }

      // We do NOT block Check-In even if isWorkingDay is false (as per user request "Budi tetap BISA Absen")
      // We just log the context.
      // --- [VALIDATION END] ---

      // Cek apakah sudah ada record hari ini
      final existingRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('attendance_date', todayStr)
          .maybeSingle();

      Map<String, dynamic> recordData;

      if (existingRecord != null) {
        // ✅ MULTI-SHIFT: Allow multiple check-ins per day
        // If already checked in, just create a new log instead of updating record
        if (existingRecord['actual_check_in'] != null) {
          debugPrint(
            '📋 Multiple check-in detected - creating log only (shift ${existingRecord['id']})',
          );

          // Create attendance log for this additional check-in
          await _createAttendanceLog(
            organizationMemberId: organizationMemberId,
            attendanceRecordId: existingRecord['id'],
            eventType: 'check_in',
            method: method,
            location: locationWithPhoto,
            deviceId: deviceId,
            ipAddress: ipAddress,
            userAgent: userAgent,
            applicationId: applicationId,
            rawData: {
              ...?rawData,
              'schedule_source': schedule.source, // Log schedule context
              'schedule_name': schedule.scheduleName,
              'late_minutes': lateMinutes,
              'is_working_day': schedule.isWorkingDay,
            },
          );

          // Return the existing record without modification
          return AttendanceRecord.fromJson(existingRecord);
        }
        // Update existing record (save as UTC)
        recordData = {
          'actual_check_in': TimezoneHelper.formatUtcForSupabase(nowUtc),
          'check_in_method': method,
          'check_in_photo_url': photoUrl,
          'check_in_location': locationWithPhoto,
          'status': 'present',
          'late_minutes': lateMinutes,
          'updated_at': TimezoneHelper.formatUtcForSupabase(nowUtc),
        };

        await _supabase
            .from('attendance_records')
            .update(recordData)
            .eq('id', existingRecord['id']);

        recordData['id'] = existingRecord['id'];
        recordData['organization_member_id'] = organizationMemberId;
        recordData['attendance_date'] = todayStr;
      } else {
        // Create new record
        recordData = {
          'organization_member_id': organizationMemberId,
          'attendance_date': todayStr,
          'actual_check_in': TimezoneHelper.formatUtcForSupabase(nowUtc),
          'check_in_method': method,
          'check_in_photo_url': photoUrl,
          'check_in_location': locationWithPhoto,
          'status': lateMinutes > 0 ? 'late' : 'present',
          'late_minutes': lateMinutes,
          'validation_status': 'pending',
        };

        final result = await _supabase
            .from('attendance_records')
            .insert(recordData)
            .select()
            .single();

        recordData = result;
      }

      // Create attendance log
      await _createAttendanceLog(
        organizationMemberId: organizationMemberId,
        attendanceRecordId: recordData['id'],
        eventType: 'check_in',
        method: method,
        location: locationWithPhoto,
        deviceId: deviceId,
        ipAddress: ipAddress,
        userAgent: userAgent,
        applicationId: applicationId,
        rawData: {
          ...?rawData,
          'schedule_source': schedule.source,
          'schedule_name': schedule.scheduleName,
          'late_minutes': lateMinutes,
          'is_working_day': schedule.isWorkingDay,
        },
      );

      debugPrint(
        '✅ AttendanceService: Online Check-In success (Record ID: ${recordData['id']})',
      );
      return AttendanceRecord.fromJson(recordData);
    } catch (e) {
      debugPrint('❌ AttendanceService: Online Check-In failed: $e');
      throw Exception('Failed to check in: $e');
    }
  }

  // Check out attendance
  Future<AttendanceRecord> checkOut({
    required int organizationMemberId,
    required String photoUrl,
    required String method,
    String? organizationTimezone,
    Map<String, dynamic>? location,
    int? deviceId,
    String? ipAddress,
    String? userAgent,
    int? applicationId,
    Map<String, dynamic>? rawData,
  }) async {
    debugPrint(
      '🌐 AttendanceService: Starting online Check-Out for member $organizationMemberId',
    );
    try {
      // Use organization timezone for date calculation, or default to device timezone
      final orgTimezone = organizationTimezone ?? 'Asia/Jakarta';
      // Get current UTC time (universal, represents "now")
      // Use offline_timestamp if available for manual sync
      final nowUtc = (rawData != null && rawData['offline_timestamp'] != null)
          ? DateTime.parse(rawData['offline_timestamp']).toUtc()
          : TimezoneHelper.getCurrentUtcTime();

      final todayStr = TimezoneHelper.getDateInOrgTimezone(nowUtc, orgTimezone);

      final locationWithPhoto = _decorateLocationWithPhoto(location, photoUrl);

      // --- [VALIDATION START] ---
      // Get Schedule for context logging (e.g. Early Leave calc in future)
      final schedule = await getTodaySchedule(
        organizationMemberId,
        organizationTimezone: orgTimezone,
      );
      // --- [VALIDATION END] ---

      // Cari record hari ini
      final existingRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('attendance_date', todayStr)
          .maybeSingle();

      if (existingRecord == null) {
        throw Exception('No check-in record found for today');
      }

      if (existingRecord['actual_check_in'] == null) {
        throw Exception('Please check in first');
      }

      // ✅ MULTI-SHIFT: Allow multiple check-outs per day
      if (existingRecord['actual_check_out'] != null) {
        debugPrint(
          '📋 Multiple check-out detected - creating log only (shift ${existingRecord['id']})',
        );

        // Create attendance log for this additional check-out
        await _createAttendanceLog(
          organizationMemberId: organizationMemberId,
          attendanceRecordId: existingRecord['id'],
          eventType: 'check_out',
          method: method,
          location: locationWithPhoto,
          deviceId: deviceId,
          ipAddress: ipAddress,
          userAgent: userAgent,
          applicationId: applicationId,
          rawData: {
            ...?rawData,
            'schedule_source': schedule.source,
            'schedule_name': schedule.scheduleName,
            'is_working_day': schedule.isWorkingDay,
          },
        );

        // Return the existing record without modification
        return AttendanceRecord.fromJson(existingRecord);
      }

      // Calculate work duration
      final checkInTime = DateTime.parse(existingRecord['actual_check_in']);
      final workDuration = nowUtc.difference(checkInTime).inMinutes;

      // --- [CALCULATION START] ---
      int earlyLeaveMinutes = 0;
      int overtimeMinutes = 0;

      if (schedule.isWorkingDay &&
          schedule.endTime != null &&
          schedule.endTime!.isNotEmpty) {
        try {
          // 1. Get Current Time (Check Out Time) in Org Timezone
          final nowInOrg = TimezoneHelper.convertUtcToOrgTimezone(
            nowUtc,
            orgTimezone,
          );

          // 2. Parse Schedule End Time (HH:mm:ss)
          final parts = schedule.endTime!.split(':');
          final endHour = int.parse(parts[0]);
          final endMinute = int.parse(parts[1]);

          // 3. Construct Schedule End DateTime for "Today"
          // Use .utc to match nowInOrg's representation (shifted UTC)
          final scheduleEndTime = DateTime.utc(
            nowInOrg.year,
            nowInOrg.month,
            nowInOrg.day,
            endHour,
            endMinute,
          );

          // 4. Calculate Difference
          final diff = nowInOrg.difference(scheduleEndTime).inMinutes;

          if (diff < 0) {
            // Negative difference means Checked Out BEFORE Schedule End -> Early Leave
            earlyLeaveMinutes = diff.abs();
          } else if (diff > 0) {
            // Positive difference means Checked Out AFTER Schedule End -> Overtime
            overtimeMinutes = diff;
          }
        } catch (e) {
          debugPrint('⚠️ Time calc error: $e');
        }
      }
      // --- [CALCULATION END] ---

      // Update record
      final recordData = {
        'actual_check_out': TimezoneHelper.formatUtcForSupabase(nowUtc),
        'check_out_method': method,
        'check_out_photo_url': photoUrl,
        'check_out_location': locationWithPhoto,
        'work_duration_minutes': workDuration,
        'early_leave_minutes': earlyLeaveMinutes,
        'overtime_minutes': overtimeMinutes,
        'updated_at': TimezoneHelper.formatUtcForSupabase(nowUtc),
      };

      await _supabase
          .from('attendance_records')
          .update(recordData)
          .eq('id', existingRecord['id']);

      // Create attendance log
      await _createAttendanceLog(
        organizationMemberId: organizationMemberId,
        attendanceRecordId: existingRecord['id'],
        eventType: 'check_out',
        method: method,
        location: locationWithPhoto,
        deviceId: deviceId,
        ipAddress: ipAddress,
        userAgent: userAgent,
        applicationId: applicationId,
        rawData: {
          ...?rawData,
          'schedule_source': schedule.source,
          'schedule_name': schedule.scheduleName,
          'is_working_day': schedule.isWorkingDay,
          'early_leave_minutes': earlyLeaveMinutes,
          'overtime_minutes': overtimeMinutes,
        },
      );

      final updatedRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('id', existingRecord['id'])
          .single();

      debugPrint(
        '✅ AttendanceService: Online Check-Out success (Record ID: ${updatedRecord['id']})',
      );
      return AttendanceRecord.fromJson(updatedRecord);
    } catch (e) {
      debugPrint('❌ AttendanceService: Online Check-Out failed: $e');
      throw Exception('Failed to check out: $e');
    }
  }

  // Break Out (Start Break)
  Future<AttendanceRecord> breakOut({
    required int organizationMemberId,
    required String photoUrl,
    required String method,
    String? organizationTimezone,
    Map<String, dynamic>? location,
    int? deviceId,
    String? ipAddress,
    String? userAgent,
    int? applicationId,
    Map<String, dynamic>? rawData,
  }) async {
    debugPrint(
      '🌐 AttendanceService: Starting online Break-Out for member $organizationMemberId',
    );
    try {
      final orgTimezone = organizationTimezone ?? 'Asia/Jakarta';

      // Use offline_timestamp if available for manual sync
      final nowUtc = (rawData != null && rawData['offline_timestamp'] != null)
          ? DateTime.parse(rawData['offline_timestamp']).toUtc()
          : TimezoneHelper.getCurrentUtcTime();

      final todayStr = TimezoneHelper.getDateInOrgTimezone(nowUtc, orgTimezone);

      final locationWithPhoto = _decorateLocationWithPhoto(location, photoUrl);

      // Find record for today
      final existingRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('attendance_date', todayStr)
          .maybeSingle();

      if (existingRecord == null) {
        throw Exception(
          'No attendance record found for today. Please check in first.',
        );
      }

      // Update record with break start
      final recordData = {
        'actual_break_start': TimezoneHelper.formatUtcForSupabase(nowUtc),
        'break_out_method': method,
        'break_out_device_id': deviceId,
        'updated_at': TimezoneHelper.formatUtcForSupabase(nowUtc),
      };

      await _supabase
          .from('attendance_records')
          .update(recordData)
          .eq('id', existingRecord['id']);

      // Create attendance log
      await _createAttendanceLog(
        organizationMemberId: organizationMemberId,
        attendanceRecordId: existingRecord['id'],
        eventType: 'break_start',
        method: method,
        location: locationWithPhoto,
        deviceId: deviceId,
        ipAddress: ipAddress,
        userAgent: userAgent,
        applicationId: applicationId,
        rawData: rawData,
      );

      final updatedRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('id', existingRecord['id'])
          .single();

      debugPrint('✅ AttendanceService: Online Break-Out success');
      return AttendanceRecord.fromJson(updatedRecord);
    } catch (e) {
      debugPrint('❌ AttendanceService: Online Break-Out failed: $e');
      throw Exception('Failed to record break out: $e');
    }
  }

  // Break In (End Break)
  Future<AttendanceRecord> breakIn({
    required int organizationMemberId,
    required String photoUrl,
    required String method,
    String? organizationTimezone,
    Map<String, dynamic>? location,
    int? deviceId,
    String? ipAddress,
    String? userAgent,
    int? applicationId,
    Map<String, dynamic>? rawData,
  }) async {
    debugPrint(
      '🌐 AttendanceService: Starting online Break-In for member $organizationMemberId',
    );
    try {
      final orgTimezone = organizationTimezone ?? 'Asia/Jakarta';

      // Use offline_timestamp if available for manual sync
      final nowUtc = (rawData != null && rawData['offline_timestamp'] != null)
          ? DateTime.parse(rawData['offline_timestamp']).toUtc()
          : TimezoneHelper.getCurrentUtcTime();

      final todayStr = TimezoneHelper.getDateInOrgTimezone(nowUtc, orgTimezone);

      final locationWithPhoto = _decorateLocationWithPhoto(location, photoUrl);

      // Find record for today
      final existingRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('attendance_date', todayStr)
          .maybeSingle();

      if (existingRecord == null) {
        throw Exception(
          'No attendance record found for today. Please check in first.',
        );
      }

      // Update record with break end
      final recordData = {
        'actual_break_end': TimezoneHelper.formatUtcForSupabase(nowUtc),
        'break_in_method': method,
        'break_in_device_id': deviceId,
        'updated_at': TimezoneHelper.formatUtcForSupabase(nowUtc),
      };

      await _supabase
          .from('attendance_records')
          .update(recordData)
          .eq('id', existingRecord['id']);

      // Create attendance log
      await _createAttendanceLog(
        organizationMemberId: organizationMemberId,
        attendanceRecordId: existingRecord['id'],
        eventType: 'break_end',
        method: method,
        location: locationWithPhoto,
        deviceId: deviceId,
        ipAddress: ipAddress,
        userAgent: userAgent,
        applicationId: applicationId,
        rawData: rawData,
      );

      final updatedRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('id', existingRecord['id'])
          .single();

      debugPrint('✅ AttendanceService: Online Break-In success');
      return AttendanceRecord.fromJson(updatedRecord);
    } catch (e) {
      debugPrint('❌ AttendanceService: Online Break-In failed: $e');
      throw Exception('Failed to record break in: $e');
    }
  }

  // Get today's attendance
  Future<AttendanceRecord?> getTodayAttendance(
    int organizationMemberId, {
    String? organizationTimezone,
  }) async {
    try {
      // Use organization timezone for date calculation, or default to device timezone
      final orgTimezone = organizationTimezone ?? 'Asia/Jakarta';
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(orgTimezone);

      final record = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('attendance_date', todayStr)
          .maybeSingle();

      if (record == null) return null;

      return AttendanceRecord.fromJson(record);
    } catch (e) {
      throw Exception('Failed to get today attendance: $e');
    }
  }

  // Get attendance history
  Future<List<AttendanceRecord>> getAttendanceHistory({
    required int organizationMemberId,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
  }) async {
    try {
      var query = _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId);

      if (startDate != null) {
        query = query.gte(
          'attendance_date',
          startDate.toIso8601String().split('T')[0],
        );
      }

      if (endDate != null) {
        query = query.lte(
          'attendance_date',
          endDate.toIso8601String().split('T')[0],
        );
      }

      final records = await query
          .order('attendance_date', ascending: false)
          .limit(limit);

      return (records as List)
          .map((record) => AttendanceRecord.fromJson(record))
          .toList();
    } catch (e) {
      throw Exception('Failed to get attendance history: $e');
    }
  }

  // Create attendance log
  Future<void> _createAttendanceLog({
    required int organizationMemberId,
    required int attendanceRecordId,
    required String eventType,
    required String method,
    Map<String, dynamic>? location,
    int? deviceId,
    String? ipAddress,
    String? userAgent,
    int? applicationId,
    Map<String, dynamic>? rawData,
  }) async {
    try {
      // Use offline timestamp if available
      DateTime eventTime = TimezoneHelper.getCurrentUtcTime();
      if (rawData != null && rawData.containsKey('offline_timestamp')) {
        try {
          eventTime = DateTime.parse(rawData['offline_timestamp']).toUtc();
        } catch (e) {
          debugPrint('⚠️ Failed to parse offline timestamp for log: $e');
        }
      }

      final logData = {
        'organization_member_id': organizationMemberId,
        'attendance_record_id': attendanceRecordId,
        'event_type': eventType,
        'event_time': TimezoneHelper.formatUtcForSupabase(eventTime),
        'method': method,
        'location': location,
        'device_id': deviceId,
        'ip_address': ipAddress,
        'user_agent': userAgent,
        'application_id': applicationId,
        'raw_data': rawData,
        'is_verified':
            method == 'face_recognition' ||
            method == 'face_recognition_kiosk' ||
            method == 'fingerprint',
        'verification_method': method.contains('face_recognition')
            ? 'face_recognition'
            : (method == 'fingerprint' ? 'fingerprint' : null),
      };

      await _supabase.from('attendance_logs').insert(logData);
    } catch (e) {
      // Log error tapi jangan throw exception
      debugPrint('Failed to create attendance log: $e');
    }
  }

  Future<Map<String, int>> getOrganizationTodayStats(
    int organizationId, {
    String? organizationTimezone,
  }) async {
    // Use organization timezone for date calculation, or default to device timezone
    final orgTimezone = organizationTimezone ?? 'Asia/Jakarta';
    final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(orgTimezone);

    try {
      final records = await _supabase
          .from('attendance_records')
          .select('''
            id,
            actual_check_in,
            actual_check_out,
            validation_status,
            late_minutes,
            organization_members!inner(organization_id)
          ''')
          .eq('attendance_date', todayStr)
          .eq('organization_members.organization_id', organizationId);

      int checkedIn = 0;
      int checkedOut = 0;
      int pending = 0;
      int late = 0;

      for (final record in records as List<dynamic>) {
        final data = record as Map<String, dynamic>;

        if (data['actual_check_in'] != null) {
          checkedIn++;
        }

        if (data['actual_check_out'] != null) {
          checkedOut++;
        }

        if ((data['validation_status'] as String?) == 'pending') {
          pending++;
        }

        final lateMinutes = data['late_minutes'];
        if (lateMinutes is int && lateMinutes > 0) {
          late++;
        }
      }

      return {
        'checked_in': checkedIn,
        'checked_out': checkedOut,
        'pending': pending,
        'late': late,
      };
    } catch (e) {
      throw Exception('Failed to load organization stats: $e');
    }
  }

  // Modifikasi di attendance_service.dart
  Future<List<Map<String, dynamic>>> getOrganizationRecentActivities({
    required int organizationId,
    int limit = 10,
  }) async {
    try {
      final logs = await _supabase
          .from('attendance_logs')
          .select('''
          id,
          event_type,
          event_time,
          method,
          raw_data,
          organization_member_id,
          attendance_record_id,
          organization_members!inner(
            id,
            organization_id,
            department_id,
            user_profiles!inner(
              display_name,
              first_name,
              last_name,
              profile_photo_url
            ),
            departments!organization_members_department_id_fkey(
              name
            )
          ),
          attendance_records!left(
            id,
            attendance_date,
            status
          )
        ''')
          .eq('organization_members.organization_id', organizationId)
          .inFilter('method', [
            'face_recognition',
            'FACERECOGNITION', // Backward compatibility for old data
            'face_recognition_kiosk',
            'rfid_card',
            'rfid_card_mobile',
            'manual',
            'selfie',
            'fingerprint',
          ])
          .order('event_time', ascending: false)
          .limit(limit * 2); // Ambil lebih banyak untuk filter

      // Filter hanya yang masih punya attendance_records
      final filteredLogs = (logs as List)
          .where((log) => log['attendance_records'] != null)
          .take(limit)
          .toList();

      return List<Map<String, dynamic>>.from(filteredLogs);
    } catch (e) {
      throw Exception('Failed to load recent activities: $e');
    }
  }

  Map<String, dynamic>? _decorateLocationWithPhoto(
    Map<String, dynamic>? location,
    String photoUrl,
  ) {
    if (photoUrl.trim().isEmpty) {
      return location;
    }

    final updatedLocation = location != null
        ? Map<String, dynamic>.from(location)
        : <String, dynamic>{};

    updatedLocation['photo_url'] = photoUrl;
    return updatedLocation;
  }

  // ================== LOCATION SERVICES ==================

  /// Get current GPS location with permission handling
  Future<geolocator.Position> getCurrentLocation() async {
    try {
      // Check if location services are enabled
      bool serviceEnabled =
          await geolocator.Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception(
          'Location services are disabled. Please enable them in your device settings.',
        );
      }

      // Check and request permission
      geolocator.LocationPermission permission =
          await geolocator.Geolocator.checkPermission();
      if (permission == geolocator.LocationPermission.denied) {
        permission = await geolocator.Geolocator.requestPermission();
        if (permission == geolocator.LocationPermission.denied) {
          throw Exception(
            'Location permission is required for attendance. Please allow location access.',
          );
        }
      }

      if (permission == geolocator.LocationPermission.deniedForever) {
        throw Exception(
          'Location access is permanently denied. Please enable it in Settings > App Permissions.',
        );
      }

      geolocator.Position? position;
      try {
        position = await geolocator.Geolocator.getCurrentPosition(
          desiredAccuracy: geolocator.LocationAccuracy.high,
          timeLimit: const Duration(seconds: 30),
        );
        debugPrint('Got location with accuracy: ${position.accuracy}m');
      } catch (e) {
        debugPrint('High accuracy failed: $e, trying medium accuracy...');

        // Fallback to medium accuracy if high accuracy fails
        position = await geolocator.Geolocator.getCurrentPosition(
          desiredAccuracy: geolocator.LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 20),
        );
        debugPrint('Got location with medium accuracy: ${position.accuracy}m');
      }

      return position;
    } catch (e) {
      debugPrint('Error getting current location: $e');
      rethrow;
    }
  }

  // ================== RFID SERVICES ==================

  /// Register or update an RFID card for a member
  Future<void> registerRfidCard({
    required int organizationMemberId,
    required String cardNumber,
  }) async {
    try {
      final normalizedCard = cardNumber.trim();
      if (normalizedCard.isEmpty) {
        throw Exception('Nomor kartu tidak boleh kosong');
      }

      // 1. Get member's organization_id
      final memberData = await _supabase
          .from('organization_members')
          .select('organization_id')
          .eq('id', organizationMemberId)
          .single();

      final int organizationId = memberData['organization_id'] as int;

      // 2. Check if this card is already assigned to ANYONE in the SAME organization
      final existingCard = await _supabase
          .from('rfid_cards')
          .select(
            'id, organization_member_id, organization_members!inner(organization_id)',
          )
          .eq('card_number', normalizedCard)
          .eq('organization_members.organization_id', organizationId)
          .maybeSingle();

      if (existingCard != null) {
        final existingMemberId = existingCard['organization_member_id'] as int;
        if (existingMemberId != organizationMemberId) {
          throw Exception(
            'Kartu ini sudah terdaftar untuk anggota lain di organisasi ini',
          );
        }
        // If it's already registered to the SAME member and active, do nothing
        await _supabase
            .from('rfid_cards')
            .update({
              'is_active': true,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', existingCard['id']);
        return;
      }

      // 3. Deactivate any OLD cards for THIS member (optional policy, usually 1 card per member)
      await _supabase
          .from('rfid_cards')
          .update({'is_active': false})
          .eq('organization_member_id', organizationMemberId);

      // 4. Insert new card
      await _supabase.from('rfid_cards').insert({
        'organization_member_id': organizationMemberId,
        'card_number': normalizedCard,
        'is_active': true,
      });
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Gagal mendaftarkan kartu RFID: $e');
    }
  }
  // --- Fingerprint Attendance Methods ---

  Future<AttendanceRecord> checkInFingerprint({
    required int organizationMemberId,
    String? organizationTimezone,
    Map<String, dynamic>? location,
    int? deviceId,
    Map<String, dynamic>? rawData,
  }) async {
    return checkIn(
      organizationMemberId: organizationMemberId,
      photoUrl: '', // No photo for fingerprint
      method: 'fingerprint',
      organizationTimezone: organizationTimezone,
      location: location,
      deviceId: deviceId,
      rawData: {...?rawData, 'verification_type': 'fingerprint'},
    );
  }

  Future<AttendanceRecord> checkOutFingerprint({
    required int organizationMemberId,
    String? organizationTimezone,
    Map<String, dynamic>? location,
    int? deviceId,
    Map<String, dynamic>? rawData,
  }) async {
    return checkOut(
      organizationMemberId: organizationMemberId,
      photoUrl: '',
      method: 'fingerprint',
      organizationTimezone: organizationTimezone,
      location: location,
      deviceId: deviceId,
      rawData: {...?rawData, 'verification_type': 'fingerprint'},
    );
  }

  Future<AttendanceRecord> breakOutFingerprint({
    required int organizationMemberId,
    String? organizationTimezone,
    Map<String, dynamic>? location,
    int? deviceId,
    Map<String, dynamic>? rawData,
  }) async {
    return breakOut(
      organizationMemberId: organizationMemberId,
      photoUrl: '',
      method: 'fingerprint',
      organizationTimezone: organizationTimezone,
      location: location,
      deviceId: deviceId,
      rawData: {...?rawData, 'verification_type': 'fingerprint'},
    );
  }

  Future<AttendanceRecord> breakInFingerprint({
    required int organizationMemberId,
    String? organizationTimezone,
    Map<String, dynamic>? location,
    int? deviceId,
    Map<String, dynamic>? rawData,
  }) async {
    return breakIn(
      organizationMemberId: organizationMemberId,
      photoUrl: '',
      method: 'fingerprint',
      organizationTimezone: organizationTimezone,
      location: location,
      deviceId: deviceId,
      rawData: {...?rawData, 'verification_type': 'fingerprint'},
    );
  }
}
