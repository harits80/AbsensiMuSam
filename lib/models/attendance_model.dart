// models/attendance_model.dart - Updated with toJson methods

class UserProfile {
  final String id;
  final String? employeeCode;
  final String firstName;
  final String? middleName;
  final String lastName;
  final String? displayName;
  final String? phone;
  final String? mobile;
  final DateTime? dateOfBirth;
  final String? gender;
  final String? nationality;
  final String? nationalId;
  final String? profilePhotoUrl;
  final Map<String, dynamic>? emergencyContact;
  final bool isActive;

  UserProfile({
    required this.id,
    this.employeeCode,
    required this.firstName,
    this.middleName,
    required this.lastName,
    this.displayName,
    this.phone,
    this.mobile,
    this.dateOfBirth,
    this.gender,
    this.nationality,
    this.nationalId,
    this.profilePhotoUrl,
    this.emergencyContact,
    required this.isActive,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'],
      employeeCode: json['employee_code'],
      firstName: json['first_name'] ?? '',
      middleName: json['middle_name'],
      lastName: json['last_name'] ?? '',
      displayName: json['display_name'],
      phone: json['phone'],
      mobile: json['mobile'],
      dateOfBirth: json['date_of_birth'] != null ? DateTime.parse(json['date_of_birth']) : null,
      gender: json['gender'],
      nationality: json['nationality'],
      nationalId: json['national_id'],
      profilePhotoUrl: json['profile_photo_url'],
      emergencyContact: json['emergency_contact'] as Map<String, dynamic>?,
      isActive: json['is_active'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'employee_code': employeeCode,
      'first_name': firstName,
      'middle_name': middleName,
      'last_name': lastName,
      'display_name': displayName,
      'phone': phone,
      'mobile': mobile,
      'date_of_birth': dateOfBirth?.toIso8601String().split('T')[0],
      'gender': gender,
      'nationality': nationality,
      'national_id': nationalId,
      'profile_photo_url': profilePhotoUrl,
      'emergency_contact': emergencyContact,
      'is_active': isActive,
    };
  }

  String get fullName => '$firstName ${middleName ?? ''} $lastName'.replaceAll('  ', ' ').trim();

  @override
  String toString() {
    return 'UserProfile(id: $id, firstName: $firstName, lastName: $lastName, displayName: $displayName)';
  }
}

class Organization {
  final String id;
  final String code;
  final String name;
  final String? legalName;
  final String? taxId;
  final String? industry;
  final String? sizeCategory;
  final String timezone;
  final String currencyCode;
  final String countryCode;
  final String? address;
  final String? city;
  final String? stateProvince;
  final String? postalCode;
  final String? phone;
  final String? email;
  final String? website;
  final String? logoUrl;
  final bool isActive;

  Organization({
    required this.id,
    required this.code,
    required this.name,
    this.legalName,
    this.taxId,
    this.industry,
    this.sizeCategory,
    this.timezone = 'UTC',
    this.currencyCode = 'USD',
    required this.countryCode,
    this.address,
    this.city,
    this.stateProvince,
    this.postalCode,
    this.phone,
    this.email,
    this.website,
    this.logoUrl,
    this.isActive = true,
  });

  factory Organization.fromJson(Map<String, dynamic> json) {
    return Organization(
      id: json['id']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      legalName: json['legal_name'],
      taxId: json['tax_id'],
      industry: json['industry'],
      sizeCategory: json['size_category'],
      timezone: json['timezone'] ?? 'UTC',
      currencyCode: json['currency_code'] ?? 'USD',
      countryCode: json['country_code'] ?? 'ID',
      address: json['address'],
      city: json['city'],
      stateProvince: json['state_province'],
      postalCode: json['postal_code'],
      phone: json['phone'],
      email: json['email'],
      website: json['website'],
      logoUrl: json['logo_url'],
      isActive: json['is_active'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'code': code,
      'name': name,
      'legal_name': legalName,
      'tax_id': taxId,
      'industry': industry,
      'size_category': sizeCategory,
      'timezone': timezone,
      'currency_code': currencyCode,
      'country_code': countryCode,
      'address': address,
      'city': city,
      'state_province': stateProvince,
      'postal_code': postalCode,
      'phone': phone,
      'email': email,
      'website': website,
      'logo_url': logoUrl,
      'is_active': isActive,
    };
  }

  @override
  String toString() {
    return 'Organization(id: $id, name: $name, code: $code)';
  }
}

class Department {
  final String id;
  final String organizationId;
  final String? parentDepartmentId;
  final String code;
  final String name;
  final String? description;
  final String? headMemberId;
  final bool isActive;

  Department({
    required this.id,
    required this.organizationId,
    this.parentDepartmentId,
    required this.code,
    required this.name,
    this.description,
    this.headMemberId,
    this.isActive = true,
  });

  factory Department.fromJson(Map<String, dynamic> json) {
    return Department(
      id: json['id']?.toString() ?? '',
      organizationId: json['organization_id']?.toString() ?? '',
      parentDepartmentId: json['parent_department_id']?.toString(),
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description'],
      headMemberId: json['head_member_id']?.toString(),
      isActive: json['is_active'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'parent_department_id': parentDepartmentId,
      'code': code,
      'name': name,
      'description': description,
      'head_member_id': headMemberId,
      'is_active': isActive,
    };
  }

  @override
  String toString() {
    return 'Department(id: $id, name: $name, code: $code, organizationId: $organizationId)';
  }
}

class Position {
  final String id;
  final String organizationId;
  final String code;
  final String title;
  final String? description;
  final int? level;
  final bool isActive;

  Position({
    required this.id,
    required this.organizationId,
    required this.code,
    required this.title,
    this.description,
    this.level,
    this.isActive = true,
  });

  factory Position.fromJson(Map<String, dynamic> json) {
    return Position(
      id: json['id']?.toString() ?? '',
      organizationId: json['organization_id']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description'],
      level: json['level'],
      isActive: json['is_active'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'code': code,
      'title': title,
      'description': description,
      'level': level,
      'is_active': isActive,
    };
  }

  @override
  String toString() {
    return 'Position(id: $id, title: $title, code: $code, organizationId: $organizationId)';
  }
}

class OrganizationMember {
  final String id;
  final String organizationId;
  final String userId;
  final String? employeeId;
  final String? departmentId;
  final String? positionId;
  final String? directManagerId;
  final DateTime hireDate;
  final DateTime? probationEndDate;
  final String? contractType;
  final String employmentStatus;
  final DateTime? terminationDate;
  final String? workLocation;
  final bool isActive;
  final Organization? organization;
  final Department? department;
  final Position? position;

  OrganizationMember({
    required this.id,
    required this.organizationId,
    required this.userId,
    this.employeeId,
    this.departmentId,
    this.positionId,
    this.directManagerId,
    required this.hireDate,
    this.probationEndDate,
    this.contractType,
    this.employmentStatus = 'active',
    this.terminationDate,
    this.workLocation,
    required this.isActive,
    this.organization,
    this.department,
    this.position,
  });

  factory OrganizationMember.fromJson(Map<String, dynamic> json) {
    return OrganizationMember(
      id: json['id']?.toString() ?? '',
      organizationId: json['organization_id']?.toString() ?? '',
      userId: json['user_id']?.toString() ?? '',
      employeeId: json['employee_id']?.toString(),
      departmentId: json['department_id']?.toString(),
      positionId: json['position_id']?.toString(),
      directManagerId: json['direct_manager_id']?.toString(),
      hireDate: DateTime.parse(json['hire_date']),
      probationEndDate: json['probation_end_date'] != null ? DateTime.parse(json['probation_end_date']) : null,
      contractType: json['contract_type'],
      employmentStatus: json['employment_status'] ?? 'active',
      terminationDate: json['termination_date'] != null ? DateTime.parse(json['termination_date']) : null,
      workLocation: json['work_location'],
      isActive: json['is_active'] ?? true,
      organization: json['organizations'] != null
          ? Organization.fromJson(json['organizations'])
          : null,
      department: json['departments'] != null
          ? Department.fromJson(json['departments'])
          : null,
      position: json['positions'] != null
          ? Position.fromJson(json['positions'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'user_id': userId,
      'employee_id': employeeId,
      'department_id': departmentId,
      'position_id': positionId,
      'direct_manager_id': directManagerId,
      'hire_date': hireDate.toIso8601String().split('T')[0],
      'probation_end_date': probationEndDate?.toIso8601String().split('T')[0],
      'contract_type': contractType,
      'employment_status': employmentStatus,
      'termination_date': terminationDate?.toIso8601String().split('T')[0],
      'work_location': workLocation,
      'is_active': isActive,
      'organizations': organization?.toJson(),
      'departments': department?.toJson(),
      'positions': position?.toJson(),
    };
  }

  @override
  String toString() {
    return 'OrganizationMember(id: $id, organizationId: $organizationId, userId: $userId, employeeId: $employeeId)';
  }
}

class AttendanceDevice {
  final String id;
  final String organizationId;
  final String deviceTypeId;
  final String deviceCode;
  final String deviceName;
  final String? serialNumber;
  final String? ipAddress;
  final String? macAddress;
  final String? location;
  final double? latitude;
  final double? longitude;
  final int radiusMeters;
  final String? firmwareVersion;
  final DateTime? lastSyncAt;
  final bool isActive;
  final Map<String, dynamic>? configuration;

  AttendanceDevice({
    required this.id,
    required this.organizationId,
    required this.deviceTypeId,
    required this.deviceCode,
    required this.deviceName,
    this.serialNumber,
    this.ipAddress,
    this.macAddress,
    this.location,
    this.latitude,
    this.longitude,
    required this.radiusMeters,
    this.firmwareVersion,
    this.lastSyncAt,
    required this.isActive,
    this.configuration,
  });

  factory AttendanceDevice.fromJson(Map<String, dynamic> json) {
    return AttendanceDevice(
      id: json['id']?.toString() ?? '',
      organizationId: json['organization_id']?.toString() ?? '',
      deviceTypeId: json['device_type_id']?.toString() ?? '',
      deviceCode: json['device_code']?.toString() ?? '',
      deviceName: json['device_name']?.toString() ?? '',
      serialNumber: json['serial_number'],
      ipAddress: json['ip_address'],
      macAddress: json['mac_address'],
      location: json['location']?.toString(),
      latitude: _parseDouble(json['latitude']),
      longitude: _parseDouble(json['longitude']),
      radiusMeters: json['radius_meters'] ?? 100,
      firmwareVersion: json['firmware_version'],
      lastSyncAt: json['last_sync_at'] != null ? DateTime.parse(json['last_sync_at']) : null,
      isActive: json['is_active'] ?? true,
      configuration: json['configuration'] as Map<String, dynamic>?,
    );
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'device_type_id': deviceTypeId,
      'device_code': deviceCode,
      'device_name': deviceName,
      'serial_number': serialNumber,
      'ip_address': ipAddress,
      'mac_address': macAddress,
      'location': location,
      'latitude': latitude,
      'longitude': longitude,
      'radius_meters': radiusMeters,
      'firmware_version': firmwareVersion,
      'last_sync_at': lastSyncAt?.toIso8601String(),
      'is_active': isActive,
      'configuration': configuration,
    };
  }

  bool get hasValidCoordinates => latitude != null && longitude != null;

  @override
  String toString() {
    return 'AttendanceDevice(id: $id, deviceName: $deviceName, location: $location, hasValidCoordinates: $hasValidCoordinates)';
  }
}

class AttendanceRecord {
  final String id;
  final String organizationMemberId;
  final String attendanceDate;
  final String? scheduledShiftId;
  final String? scheduledStart;
  final String? scheduledEnd;
  final DateTime? actualCheckIn;
  final DateTime? actualCheckOut;
  final String? checkInDeviceId;
  final String? checkOutDeviceId;
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
  final String status;
  final String validationStatus;
  final String? validatedBy;
  final DateTime? validatedAt;
  final String? validationNote;

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
    required this.status,
    this.validationStatus = 'pending',
    this.validatedBy,
    this.validatedAt,
    this.validationNote,
  });

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    return AttendanceRecord(
      id: json['id']?.toString() ?? '',
      organizationMemberId: json['organization_member_id']?.toString() ?? '',
      attendanceDate: json['attendance_date']?.toString() ?? '',
      scheduledShiftId: json['scheduled_shift_id']?.toString(),
      scheduledStart: json['scheduled_start']?.toString(),
      scheduledEnd: json['scheduled_end']?.toString(),
      actualCheckIn: _parseDateTime(json['actual_check_in']),
      actualCheckOut: _parseDateTime(json['actual_check_out']),
      checkInDeviceId: json['check_in_device_id']?.toString(),
      checkOutDeviceId: json['check_out_device_id']?.toString(),
      checkInMethod: json['check_in_method'],
      checkOutMethod: json['check_out_method'],
      checkInLocation: json['check_in_location'] as Map<String, dynamic>?,
      checkOutLocation: json['check_out_location'] as Map<String, dynamic>?,
      checkInPhotoUrl: json['check_in_photo_url']?.toString(),
      checkOutPhotoUrl: json['check_out_photo_url']?.toString(),
      workDurationMinutes: json['work_duration_minutes'],
      breakDurationMinutes: json['break_duration_minutes'],
      overtimeMinutes: json['overtime_minutes'],
      lateMinutes: json['late_minutes'],
      earlyLeaveMinutes: json['early_leave_minutes'],
      status: json['status']?.toString() ?? 'absent',
      validationStatus: json['validation_status']?.toString() ?? 'pending',
      validatedBy: json['validated_by']?.toString(),
      validatedAt: _parseDateTime(json['validated_at']),
      validationNote: json['validation_note'],
    );
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_member_id': organizationMemberId,
      'attendance_date': attendanceDate,
      'scheduled_shift_id': scheduledShiftId,
      'scheduled_start': scheduledStart,
      'scheduled_end': scheduledEnd,
      'actual_check_in': actualCheckIn?.toIso8601String(),
      'actual_check_out': actualCheckOut?.toIso8601String(),
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
      'validated_at': validatedAt?.toIso8601String(),
      'validation_note': validationNote,
    };
  }

  bool get hasCheckedIn => actualCheckIn != null;
  bool get hasCheckedOut => actualCheckOut != null;
  bool get canCheckOut => hasCheckedIn && !hasCheckedOut;

  @override
  String toString() {
    return 'AttendanceRecord(id: $id, date: $attendanceDate, status: $status, hasCheckedIn: $hasCheckedIn, hasCheckedOut: $hasCheckedOut)';
  }
}

class Shift {
  final String id;
  final String organizationId;
  final String code;
  final String name;
  final String? description;
  final String startTime;
  final String endTime;
  final bool overnight;
  final int breakDurationMinutes;
  final String? colorCode;
  final bool isActive;

  Shift({
    required this.id,
    required this.organizationId,
    required this.code,
    required this.name,
    this.description,
    required this.startTime,
    required this.endTime,
    required this.overnight,
    required this.breakDurationMinutes,
    this.colorCode,
    required this.isActive,
  });

  factory Shift.fromJson(Map<String, dynamic> json) {
    return Shift(
      id: json['id']?.toString() ?? '',
      organizationId: json['organization_id']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description'],
      startTime: json['start_time']?.toString() ?? '',
      endTime: json['end_time']?.toString() ?? '',
      overnight: json['overnight'] ?? false,
      breakDurationMinutes: json['break_duration_minutes'] ?? 0,
      colorCode: json['color_code'],
      isActive: json['is_active'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'code': code,
      'name': name,
      'description': description,
      'start_time': startTime,
      'end_time': endTime,
      'overnight': overnight,
      'break_duration_minutes': breakDurationMinutes,
      'color_code': colorCode,
      'is_active': isActive,
    };
  }

  @override
  String toString() {
    return 'Shift(id: $id, name: $name, code: $code, startTime: $startTime, endTime: $endTime)';
  }
}

class WorkSchedule {
  final String id;
  final String organizationId;
  final String code;
  final String name;
  final String? description;
  final String scheduleType;
  final bool isDefault;
  final bool isActive;

  WorkSchedule({
    required this.id,
    required this.organizationId,
    required this.code,
    required this.name,
    this.description,
    required this.scheduleType,
    required this.isDefault,
    required this.isActive,
  });

  factory WorkSchedule.fromJson(Map<String, dynamic> json) {
    return WorkSchedule(
      id: json['id']?.toString() ?? '',
      organizationId: json['organization_id']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString(),
      scheduleType: json['schedule_type']?.toString() ?? '',
      isDefault: json['is_default'] ?? false,
      isActive: json['is_active'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'code': code,
      'name': name,
      'description': description,
      'schedule_type': scheduleType,
      'is_default': isDefault,
      'is_active': isActive,
    };
  }

  @override
  String toString() {
    return 'WorkSchedule(id: $id, name: $name, code: $code, scheduleType: $scheduleType)';
  }
}

class WorkScheduleDetails {
  final String id;
  final String workScheduleId;
  final int dayOfWeek;
  final bool isWorkingDay;
  final String? startTime;
  final String? endTime;
  final String? breakStart;
  final String? breakEnd;
  final int? breakDurationMinutes;
  final bool flexibleHours;
  final String? coreHoursStart;
  final String? coreHoursEnd;
  final double? minimumHours;

  WorkScheduleDetails({
    required this.id,
    required this.workScheduleId,
    required this.dayOfWeek,
    required this.isWorkingDay,
    this.startTime,
    this.endTime,
    this.breakStart,
    this.breakEnd,
    this.breakDurationMinutes,
    required this.flexibleHours,
    this.coreHoursStart,
    this.coreHoursEnd,
    this.minimumHours,
  });

  factory WorkScheduleDetails.fromJson(Map<String, dynamic> json) {
    return WorkScheduleDetails(
      id: json['id']?.toString() ?? '',
      workScheduleId: json['work_schedule_id']?.toString() ?? '',
      dayOfWeek: json['day_of_week'] ?? 0,
      isWorkingDay: json['is_working_day'] ?? true,
      startTime: json['start_time']?.toString(),
      endTime: json['end_time']?.toString(),
      breakStart: json['break_start']?.toString(),
      breakEnd: json['break_end']?.toString(),
      breakDurationMinutes: json['break_duration_minutes'],
      flexibleHours: json['flexible_hours'] ?? false,
      coreHoursStart: json['core_hours_start']?.toString(),
      coreHoursEnd: json['core_hours_end']?.toString(),
      minimumHours: json['minimum_hours']?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'work_schedule_id': workScheduleId,
      'day_of_week': dayOfWeek,
      'is_working_day': isWorkingDay,
      'start_time': startTime,
      'end_time': endTime,
      'break_start': breakStart,
      'break_end': breakEnd,
      'break_duration_minutes': breakDurationMinutes,
      'flexible_hours': flexibleHours,
      'core_hours_start': coreHoursStart,
      'core_hours_end': coreHoursEnd,
      'minimum_hours': minimumHours,
    };
  }

  @override
  String toString() {
    return 'WorkScheduleDetails(id: $id, workScheduleId: $workScheduleId, dayOfWeek: $dayOfWeek, isWorkingDay: $isWorkingDay, startTime: $startTime, endTime: $endTime)';
  }
}

class MemberSchedule {
  final String id;
  final String organizationMemberId;
  final String? workScheduleId;
  final String? shiftId;
  final DateTime effectiveDate;
  final DateTime? endDate;
  final bool isActive;
  final WorkSchedule? workSchedule;
  final Shift? shift;

  MemberSchedule({
    required this.id,
    required this.organizationMemberId,
    this.workScheduleId,
    this.shiftId,
    required this.effectiveDate,
    this.endDate,
    required this.isActive,
    this.workSchedule,
    this.shift,
  });

  factory MemberSchedule.fromJson(Map<String, dynamic> json) {
    return MemberSchedule(
      id: json['id']?.toString() ?? '',
      organizationMemberId: json['organization_member_id']?.toString() ?? '',
      workScheduleId: json['work_schedule_id']?.toString(),
      shiftId: json['shift_id']?.toString(),
      effectiveDate: DateTime.parse(json['effective_date']),
      endDate: json['end_date'] != null ? DateTime.parse(json['end_date']) : null,
      isActive: json['is_active'] ?? true,
      workSchedule: json['work_schedules'] != null
          ? WorkSchedule.fromJson(json['work_schedules'])
          : null,
      shift: json['shifts'] != null ? Shift.fromJson(json['shifts']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_member_id': organizationMemberId,
      'work_schedule_id': workScheduleId,
      'shift_id': shiftId,
      'effective_date': effectiveDate.toIso8601String(),
      'end_date': endDate?.toIso8601String(),
      'is_active': isActive,
      'work_schedules': workSchedule?.toJson(),
      'shifts': shift?.toJson(),
    };
  }

  @override
  String toString() {
    return 'MemberSchedule(id: $id, workScheduleId: $workScheduleId, shiftId: $shiftId, effectiveDate: $effectiveDate)';
  }
}

class AttendanceLog {
  final String id;
  final String organizationMemberId;
  final String? attendanceRecordId;
  final String eventType;
  final DateTime eventTime;
  final String? deviceId;
  final String method;
  final Map<String, dynamic>? location;
  final String? ipAddress;
  final String? userAgent;
  final bool isVerified;
  final String? verificationMethod;

  AttendanceLog({
    required this.id,
    required this.organizationMemberId,
    this.attendanceRecordId,
    required this.eventType,
    required this.eventTime,
    this.deviceId,
    required this.method,
    this.location,
    this.ipAddress,
    this.userAgent,
    required this.isVerified,
    this.verificationMethod,
  });

  factory AttendanceLog.fromJson(Map<String, dynamic> json) {
    return AttendanceLog(
      id: json['id']?.toString() ?? '',
      organizationMemberId: json['organization_member_id']?.toString() ?? '',
      attendanceRecordId: json['attendance_record_id']?.toString(),
      eventType: json['event_type']?.toString() ?? '',
      eventTime: DateTime.parse(json['event_time']),
      deviceId: json['device_id']?.toString(),
      method: json['method']?.toString() ?? '',
      location: json['location'] as Map<String, dynamic>?,
      ipAddress: json['ip_address'],
      userAgent: json['user_agent'],
      isVerified: json['is_verified'] ?? false,
      verificationMethod: json['verification_method'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_member_id': organizationMemberId,
      'attendance_record_id': attendanceRecordId,
      'event_type': eventType,
      'event_time': eventTime.toIso8601String(),
      'device_id': deviceId,
      'method': method,
      'location': location,
      'ip_address': ipAddress,
      'user_agent': userAgent,
      'is_verified': isVerified,
      'verification_method': verificationMethod,
    };
  }

  @override
  String toString() {
    return 'AttendanceLog(id: $id, eventType: $eventType, eventTime: $eventTime, isVerified: $isVerified)';
  }
}