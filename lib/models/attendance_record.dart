// lib/models/attendance_record.dart
import '../helpers/timezone_helper.dart';

class AttendanceRecord {
  final int id;
  final int organizationMemberId;
  final String attendanceDate;
  final int? scheduledShiftId;
  final String? scheduledStart;
  final String? scheduledEnd;
  final DateTime? actualCheckIn;
  final DateTime? actualCheckOut;
  final int? checkInDeviceId;
  final int? checkOutDeviceId;
  final String? checkInMethod;
  final String? checkOutMethod;
  final Map<String, dynamic>? checkInLocation;
  final Map<String, dynamic>? checkOutLocation;
  final String? checkInPhotoUrl;
  final String? checkOutPhotoUrl;
  final int? workDurationMinutes;
  final int? breakDurationMinutes;
  final int? overtimeMinutes;
  final int? lateMinutes;
  final int? earlyLeaveMinutes;
  final String? status;
  final String? validationStatus;
  final String? validatedBy;
  final DateTime? validatedAt;
  final String? validationNote;
  final int? applicationId;
  final Map<String, dynamic>? rawData;
  final DateTime createdAt;
  final DateTime updatedAt;

  // New break fields
  final DateTime? actualBreakStart;
  final DateTime? actualBreakEnd;
  final int? breakInDeviceId;
  final int? breakOutDeviceId;
  final String? breakInMethod;
  final String? breakOutMethod;

  AttendanceRecord({
    required this.id,
    required this.organizationMemberId,
    required this.attendanceDate,
    this.scheduledShiftId,
    this.scheduledStart,
    this.scheduledEnd,
    this.actualCheckIn,
    this.actualCheckOut,
    this.checkInDeviceId,
    this.checkOutDeviceId,
    this.checkInMethod,
    this.checkOutMethod,
    this.checkInLocation,
    this.checkOutLocation,
    this.checkInPhotoUrl,
    this.checkOutPhotoUrl,
    this.workDurationMinutes,
    this.breakDurationMinutes,
    this.overtimeMinutes,
    this.lateMinutes,
    this.earlyLeaveMinutes,
    this.status,
    this.validationStatus,
    this.validatedBy,
    this.validatedAt,
    this.validationNote,
    this.applicationId,
    this.rawData,
    required this.createdAt,
    required this.updatedAt,
    this.actualBreakStart,
    this.actualBreakEnd,
    this.breakInDeviceId,
    this.breakOutDeviceId,
    this.breakInMethod,
    this.breakOutMethod,
  });

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    return AttendanceRecord(
      id: json['id'] as int,
      organizationMemberId: json['organization_member_id'] as int,
      attendanceDate: json['attendance_date'] as String,
      scheduledShiftId: json['scheduled_shift_id'] as int?,
      scheduledStart: json['scheduled_start'] as String?,
      scheduledEnd: json['scheduled_end'] as String?,
      actualCheckIn: json['actual_check_in'] != null
          ? DateTime.parse(json['actual_check_in'])
          : null,
      actualCheckOut: json['actual_check_out'] != null
          ? DateTime.parse(json['actual_check_out'])
          : null,
      checkInDeviceId: json['check_in_device_id'] as int?,
      checkOutDeviceId: json['check_out_device_id'] as int?,
      checkInMethod: json['check_in_method'] as String?,
      checkOutMethod: json['check_out_method'] as String?,
      checkInLocation: json['check_in_location'] as Map<String, dynamic>?,
      checkOutLocation: json['check_out_location'] as Map<String, dynamic>?,
      checkInPhotoUrl: json['check_in_photo_url'] as String?,
      checkOutPhotoUrl: json['check_out_photo_url'] as String?,
      workDurationMinutes: json['work_duration_minutes'] as int?,
      breakDurationMinutes: json['break_duration_minutes'] as int?,
      overtimeMinutes: json['overtime_minutes'] as int?,
      lateMinutes: json['late_minutes'] as int?,
      earlyLeaveMinutes: json['early_leave_minutes'] as int?,
      status: json['status'] as String?,
      validationStatus: json['validation_status'] as String?,
      validatedBy: json['validated_by'] as String?,
      validatedAt: json['validated_at'] != null
          ? DateTime.parse(json['validated_at'])
          : null,
      validationNote: json['validation_note'] as String?,
      applicationId: json['application_id'] as int?,
      rawData: json['raw_data'] as Map<String, dynamic>?,
      createdAt: DateTime.parse(json['created_at']),
      updatedAt: DateTime.parse(json['updated_at']),
      actualBreakStart: json['actual_break_start'] != null
          ? DateTime.parse(json['actual_break_start'])
          : null,
      actualBreakEnd: json['actual_break_end'] != null
          ? DateTime.parse(json['actual_break_end'])
          : null,
      breakInDeviceId: json['break_in_device_id'] as int?,
      breakOutDeviceId: json['break_out_device_id'] as int?,
      breakInMethod: json['break_in_method'] as String?,
      breakOutMethod: json['break_out_method'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_member_id': organizationMemberId,
      'attendance_date': attendanceDate,
      'scheduled_shift_id': scheduledShiftId,
      'scheduled_start': scheduledStart,
      'scheduled_end': scheduledEnd,
      'actual_check_in': actualCheckIn != null
          ? TimezoneHelper.formatUtcForSupabase(actualCheckIn!)
          : null,
      'actual_check_out': actualCheckOut != null
          ? TimezoneHelper.formatUtcForSupabase(actualCheckOut!)
          : null,
      'check_in_device_id': checkInDeviceId,
      'check_out_device_id': checkOutDeviceId,
      'check_in_method': checkInMethod,
      'check_out_method': checkOutMethod,
      'check_in_location': checkInLocation,
      'check_out_location': checkOutLocation,
      'check_in_photo_url': checkInPhotoUrl,
      'check_out_photo_url': checkOutPhotoUrl,
      'work_duration_minutes': workDurationMinutes,
      'break_duration_minutes': breakDurationMinutes,
      'overtime_minutes': overtimeMinutes,
      'late_minutes': lateMinutes,
      'early_leave_minutes': earlyLeaveMinutes,
      'status': status,
      'validation_status': validationStatus,
      'validated_by': validatedBy,
      'validated_at': validatedAt != null
          ? TimezoneHelper.formatUtcForSupabase(validatedAt!)
          : null,
      'validation_note': validationNote,
      'application_id': applicationId,
      'raw_data': rawData,
      'created_at': TimezoneHelper.formatUtcForSupabase(createdAt),
      'updated_at': TimezoneHelper.formatUtcForSupabase(updatedAt),
      'actual_break_start': actualBreakStart != null
          ? TimezoneHelper.formatUtcForSupabase(actualBreakStart!)
          : null,
      'actual_break_end': actualBreakEnd != null
          ? TimezoneHelper.formatUtcForSupabase(actualBreakEnd!)
          : null,
      'break_in_device_id': breakInDeviceId,
      'break_out_device_id': breakOutDeviceId,
      'break_in_method': breakInMethod,
      'break_out_method': breakOutMethod,
    };
  }

  // Helper methods
  bool get hasCheckedIn => actualCheckIn != null;
  bool get hasCheckedOut => actualCheckOut != null;
  bool get isComplete => hasCheckedIn && hasCheckedOut;

  String get statusDisplay {
    if (status == null) return 'Unknown';
    return status!.replaceAll('_', ' ').toUpperCase();
  }

  AttendanceRecord copyWith({
    int? id,
    int? organizationMemberId,
    String? attendanceDate,
    int? scheduledShiftId,
    String? scheduledStart,
    String? scheduledEnd,
    DateTime? actualCheckIn,
    DateTime? actualCheckOut,
    int? checkInDeviceId,
    int? checkOutDeviceId,
    String? checkInMethod,
    String? checkOutMethod,
    Map<String, dynamic>? checkInLocation,
    Map<String, dynamic>? checkOutLocation,
    String? checkInPhotoUrl,
    String? checkOutPhotoUrl,
    int? workDurationMinutes,
    int? breakDurationMinutes,
    int? overtimeMinutes,
    int? lateMinutes,
    int? earlyLeaveMinutes,
    String? status,
    String? validationStatus,
    String? validatedBy,
    DateTime? validatedAt,
    String? validationNote,
    int? applicationId,
    Map<String, dynamic>? rawData,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? actualBreakStart,
    DateTime? actualBreakEnd,
    int? breakInDeviceId,
    int? breakOutDeviceId,
    String? breakInMethod,
    String? breakOutMethod,
  }) {
    return AttendanceRecord(
      id: id ?? this.id,
      organizationMemberId: organizationMemberId ?? this.organizationMemberId,
      attendanceDate: attendanceDate ?? this.attendanceDate,
      scheduledShiftId: scheduledShiftId ?? this.scheduledShiftId,
      scheduledStart: scheduledStart ?? this.scheduledStart,
      scheduledEnd: scheduledEnd ?? this.scheduledEnd,
      actualCheckIn: actualCheckIn ?? this.actualCheckIn,
      actualCheckOut: actualCheckOut ?? this.actualCheckOut,
      checkInDeviceId: checkInDeviceId ?? this.checkInDeviceId,
      checkOutDeviceId: checkOutDeviceId ?? this.checkOutDeviceId,
      checkInMethod: checkInMethod ?? this.checkInMethod,
      checkOutMethod: checkOutMethod ?? this.checkOutMethod,
      checkInLocation: checkInLocation ?? this.checkInLocation,
      checkOutLocation: checkOutLocation ?? this.checkOutLocation,
      checkInPhotoUrl: checkInPhotoUrl ?? this.checkInPhotoUrl,
      checkOutPhotoUrl: checkOutPhotoUrl ?? this.checkOutPhotoUrl,
      workDurationMinutes: workDurationMinutes ?? this.workDurationMinutes,
      breakDurationMinutes: breakDurationMinutes ?? this.breakDurationMinutes,
      overtimeMinutes: overtimeMinutes ?? this.overtimeMinutes,
      lateMinutes: lateMinutes ?? this.lateMinutes,
      earlyLeaveMinutes: earlyLeaveMinutes ?? this.earlyLeaveMinutes,
      status: status ?? this.status,
      validationStatus: validationStatus ?? this.validationStatus,
      validatedBy: validatedBy ?? this.validatedBy,
      validatedAt: validatedAt ?? this.validatedAt,
      validationNote: validationNote ?? this.validationNote,
      applicationId: applicationId ?? this.applicationId,
      rawData: rawData ?? this.rawData,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      actualBreakStart: actualBreakStart ?? this.actualBreakStart,
      actualBreakEnd: actualBreakEnd ?? this.actualBreakEnd,
      breakInDeviceId: breakInDeviceId ?? this.breakInDeviceId,
      breakOutDeviceId: breakOutDeviceId ?? this.breakOutDeviceId,
      breakInMethod: breakInMethod ?? this.breakInMethod,
      breakOutMethod: breakOutMethod ?? this.breakOutMethod,
    );
  }
}
