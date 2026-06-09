// lib/models/offline_attendance.dart
import '../helpers/timezone_helper.dart';

class OfflineAttendance {
  final int? id;
  final String cardNumber; // For RFID
  final String? faceEmbedding; // For Face Recognition (JSON string)
  final String eventType; // 'check_in' or 'check_out'
  final String method; // 'rfid_card_mobile' or 'face_recognition_kiosk'
  final String timestamp; // ISO8601 string
  final String? photoPath; // Local file path
  final String?
  capturedPhotoBase64; // Local photo in base64 for sync/offline UI
  final String?
  profilePhotoBase64; // Cached profile photo base64 for offline UI
  final double? latitude;
  final double? longitude;
  final String? workTimeMode; // 'work_time' or 'break_time'
  final int? organizationMemberId; // Only for face recognition
  final String? userName; // For display
  final bool isSynced;
  final String? syncError;
  final String? notes; // Added for manual attendance notes
  final DateTime createdAt;

  OfflineAttendance({
    this.id,
    required this.cardNumber,
    this.faceEmbedding,
    required this.eventType,
    required this.method,
    required this.timestamp,
    this.photoPath,
    this.capturedPhotoBase64,
    this.profilePhotoBase64,
    this.latitude,
    this.longitude,
    this.workTimeMode,
    this.organizationMemberId,
    this.userName,
    this.isSynced = false,
    this.syncError,
    this.notes,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'card_number': cardNumber,
      'face_embedding': faceEmbedding,
      'event_type': eventType,
      'method': method,
      'timestamp': timestamp,
      'photo_path': photoPath,
      'captured_photo_base64': capturedPhotoBase64,
      'profile_photo_base64': profilePhotoBase64,
      'latitude': latitude,
      'longitude': longitude,
      'work_time_mode': workTimeMode,
      'organization_member_id': organizationMemberId,
      'user_name': userName,
      'is_synced': isSynced ? 1 : 0,
      'sync_error': syncError,
      'notes': notes,
      'created_at': TimezoneHelper.formatUtcForSupabase(createdAt),
    };
  }

  factory OfflineAttendance.fromMap(Map<String, dynamic> map) {
    return OfflineAttendance(
      id: map['id'] as int?,
      cardNumber: map['card_number'] as String,
      faceEmbedding: map['face_embedding'] as String?,
      eventType: map['event_type'] as String,
      method: map['method'] as String,
      timestamp: map['timestamp'] as String,
      photoPath: map['photo_path'] as String?,
      capturedPhotoBase64: map['captured_photo_base64'] as String?,
      profilePhotoBase64: map['profile_photo_base64'] as String?,
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      workTimeMode: map['work_time_mode'] as String?,
      organizationMemberId: map['organization_member_id'] as int?,
      userName: map['user_name'] as String?,
      isSynced: (map['is_synced'] as int) == 1,
      syncError: map['sync_error'] as String?,
      notes: map['notes'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  OfflineAttendance copyWith({
    int? id,
    String? cardNumber,
    String? faceEmbedding,
    String? eventType,
    String? method,
    String? timestamp,
    String? photoPath,
    String? capturedPhotoBase64,
    String? profilePhotoBase64,
    double? latitude,
    double? longitude,
    String? workTimeMode,
    int? organizationMemberId,
    String? userName,
    bool? isSynced,
    String? syncError,
    String? notes,
    DateTime? createdAt,
  }) {
    return OfflineAttendance(
      id: id ?? this.id,
      cardNumber: cardNumber ?? this.cardNumber,
      faceEmbedding: faceEmbedding ?? this.faceEmbedding,
      eventType: eventType ?? this.eventType,
      method: method ?? this.method,
      timestamp: timestamp ?? this.timestamp,
      photoPath: photoPath ?? this.photoPath,
      capturedPhotoBase64: capturedPhotoBase64 ?? this.capturedPhotoBase64,
      profilePhotoBase64: profilePhotoBase64 ?? this.profilePhotoBase64,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      workTimeMode: workTimeMode ?? this.workTimeMode,
      organizationMemberId: organizationMemberId ?? this.organizationMemberId,
      userName: userName ?? this.userName,
      isSynced: isSynced ?? this.isSynced,
      syncError: syncError ?? this.syncError,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
