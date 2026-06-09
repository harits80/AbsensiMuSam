// lib/models/biometric_data.dart
class BiometricData {
  final int? id;
  final int organizationMemberId;
  final String biometricType;
  final String templateData;
  final int? deviceId;
  final DateTime? enrollmentDate;
  final DateTime? lastUsedAt;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  BiometricData({
    this.id,
    required this.organizationMemberId,
    required this.biometricType,
    required this.templateData,
    this.deviceId,
    this.enrollmentDate,
    this.lastUsedAt,
    this.isActive = true,
    this.createdAt,
    this.updatedAt,
  });

  factory BiometricData.fromJson(Map<String, dynamic> json) {
    return BiometricData(
      id: json['id'],
      organizationMemberId: json['organization_member_id'],
      biometricType: json['biometric_type'],
      templateData: json['template_data'],
      deviceId: json['device_id'],
      enrollmentDate: json['enrollment_date'] != null
          ? DateTime.parse(json['enrollment_date'])
          : null,
      lastUsedAt: json['last_used_at'] != null
          ? DateTime.parse(json['last_used_at'])
          : null,
      isActive: json['is_active'] ?? true,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_member_id': organizationMemberId,
      'biometric_type': biometricType,
      'template_data': templateData,
      'device_id': deviceId,
      'enrollment_date': enrollmentDate?.toIso8601String(),
      'last_used_at': lastUsedAt?.toIso8601String(),
      'is_active': isActive,
    };
  }
}