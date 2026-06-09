// lib/models/attendance_log.dart
import '../helpers/timezone_helper.dart';

class AttendanceLog {
  final int? id;
  final int organizationMemberId;
  final int? attendanceRecordId;
  final String eventType;
  final DateTime eventTime;
  final int? deviceId;
  final String method;
  final Map<String, dynamic>? location;
  final String? ipAddress;
  final String? userAgent;
  final int? applicationId;
  final bool isVerified;
  final String? verificationMethod;
  final Map<String, dynamic>? rawData;
  final DateTime? createdAt;

  AttendanceLog({
    this.id,
    required this.organizationMemberId,
    this.attendanceRecordId,
    required this.eventType,
    required this.eventTime,
    this.deviceId,
    required this.method,
    this.location,
    this.ipAddress,
    this.userAgent,
    this.applicationId,
    this.isVerified = false,
    this.verificationMethod,
    this.rawData,
    this.createdAt,
  });

  factory AttendanceLog.fromJson(Map<String, dynamic> json) {
    return AttendanceLog(
      id: json['id'],
      organizationMemberId: json['organization_member_id'],
      attendanceRecordId: json['attendance_record_id'],
      eventType: json['event_type'],
      eventTime: DateTime.parse(json['event_time']),
      deviceId: json['device_id'],
      method: json['method'],
      location: json['location'],
      ipAddress: json['ip_address'],
      userAgent: json['user_agent'],
      applicationId: json['application_id'],
      isVerified: json['is_verified'] ?? false,
      verificationMethod: json['verification_method'],
      rawData: json['raw_data'],
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_member_id': organizationMemberId,
      'attendance_record_id': attendanceRecordId,
      'event_type': eventType,
      'event_time': TimezoneHelper.formatUtcForSupabase(eventTime),
      'device_id': deviceId,
      'method': method,
      'location': location,
      'ip_address': ipAddress,
      'user_agent': userAgent,
      'application_id': applicationId,
      'is_verified': isVerified,
      'verification_method': verificationMethod,
      'raw_data': rawData,
    };
  }
}