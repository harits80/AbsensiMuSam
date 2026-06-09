
enum ScheduleType { fixed, shift, flexible }

class WorkSchedule {
  final int id;
  final int organizationId;
  final String code;
  final String name;
  final String? description;
  final String scheduleType; // 'fixed', 'shift', 'flexible'
  final bool isDefault;
  final bool isActive;

  WorkSchedule({
    required this.id,
    required this.organizationId,
    required this.code,
    required this.name,
    this.description,
    required this.scheduleType,
    this.isDefault = false,
    this.isActive = true,
  });

  factory WorkSchedule.fromJson(Map<String, dynamic> json) {
    return WorkSchedule(
      id: json['id'],
      organizationId: json['organization_id'],
      code: json['code'],
      name: json['name'],
      description: json['description'],
      scheduleType: json['schedule_type'],
      isDefault: json['is_default'] ?? false,
      isActive: json['is_active'] ?? true,
    );
  }
}

class WorkScheduleDetail {
  final int id;
  final int workScheduleId;
  final int
  dayOfWeek; // 0=Sunday, 1=Monday, ... depending on DB convention (Postgres usually 0-6 or 1-7 check SQL) -> User SQL says 0-6
  final bool isWorkingDay;
  final String? startTime; // HH:mm:ss
  final String? endTime; // HH:mm:ss
  final String? breakStart;
  final String? breakEnd;
  final int? breakDurationMinutes;
  final bool flexibleHours;
  final double? minimumHours;

  WorkScheduleDetail({
    required this.id,
    required this.workScheduleId,
    required this.dayOfWeek,
    this.isWorkingDay = true,
    this.startTime,
    this.endTime,
    this.breakStart,
    this.breakEnd,
    this.breakDurationMinutes,
    this.flexibleHours = false,
    this.minimumHours,
  });

  factory WorkScheduleDetail.fromJson(Map<String, dynamic> json) {
    return WorkScheduleDetail(
      id: json['id'],
      workScheduleId: json['work_schedule_id'],
      dayOfWeek: json['day_of_week'],
      isWorkingDay: json['is_working_day'] ?? true,
      startTime: json['start_time'],
      endTime: json['end_time'],
      breakStart: json['break_start'],
      breakEnd: json['break_end'],
      breakDurationMinutes: json['break_duration_minutes'],
      flexibleHours: json['flexible_hours'] ?? false,
      minimumHours: json['minimum_hours'] != null
          ? (json['minimum_hours'] is int
                ? (json['minimum_hours'] as int).toDouble()
                : json['minimum_hours'])
          : null,
    );
  }
}

class Shift {
  final int id;
  final int organizationId;
  final String code;
  final String name;
  final String? description;
  final String startTime;
  final String endTime;
  final bool overnight;
  final int? breakDurationMinutes;
  final String? colorCode;
  final bool isActive;
  final String? breakStart;
  final String? breakEnd;

  Shift({
    required this.id,
    required this.organizationId,
    required this.code,
    required this.name,
    this.description,
    required this.startTime,
    required this.endTime,
    this.overnight = false,
    this.breakDurationMinutes,
    this.colorCode,
    this.isActive = true,
    this.breakStart,
    this.breakEnd,
  });

  factory Shift.fromJson(Map<String, dynamic> json) {
    return Shift(
      id: json['id'],
      organizationId: json['organization_id'],
      code: json['code'],
      name: json['name'],
      description: json['description'],
      startTime: json['start_time'],
      endTime: json['end_time'],
      overnight: json['overnight'] ?? false,
      breakDurationMinutes: json['break_duration_minutes'],
      colorCode: json['color_code'],
      isActive: json['is_active'] ?? true,
      breakStart: json['break_start'],
      breakEnd: json['break_end'],
    );
  }
}

class ShiftAssignment {
  final int id;
  final int organizationMemberId;
  final int shiftId;
  final String assignmentDate; // YYYY-MM-DD
  final Shift? shift; // Joined shift data

  ShiftAssignment({
    required this.id,
    required this.organizationMemberId,
    required this.shiftId,
    required this.assignmentDate,
    this.shift,
  });

  factory ShiftAssignment.fromJson(Map<String, dynamic> json) {
    return ShiftAssignment(
      id: json['id'],
      organizationMemberId: json['organization_member_id'],
      shiftId: json['shift_id'],
      assignmentDate: json['assignment_date'],
      shift: json['shifts'] != null ? Shift.fromJson(json['shifts']) : null,
    );
  }
}

class MemberSchedule {
  final int id;
  final int organizationMemberId;
  final int? workScheduleId;
  final int? shiftId;
  final String effectiveDate;
  final String? endDate;

  MemberSchedule({
    required this.id,
    required this.organizationMemberId,
    this.workScheduleId,
    this.shiftId,
    required this.effectiveDate,
    this.endDate,
  });

  factory MemberSchedule.fromJson(Map<String, dynamic> json) {
    return MemberSchedule(
      id: json['id'],
      organizationMemberId: json['organization_member_id'],
      workScheduleId: json['work_schedule_id'],
      shiftId: json['shift_id'],
      effectiveDate: json['effective_date'],
      endDate: json['end_date'],
    );
  }
}

/// Helper class to return the effective schedule for a specific day
class DailySchedule {
  final bool isWorkingDay;
  final String? startTime;
  final String? endTime;
  final String? breakStart;
  final String? breakEnd;
  final String
  source; // 'shift_assignment', 'member_shift', 'work_schedule', 'default', 'none'
  final String? scheduleName;
  final int? shiftId; // If derived from a Shift
  final int? workScheduleId; // If derived from a WorkSchedule (and detail)
  final bool isOvernight;

  DailySchedule({
    this.isWorkingDay = true,
    this.startTime,
    this.endTime,
    this.breakStart,
    this.breakEnd,
    required this.source,
    this.scheduleName,
    this.shiftId,
    this.workScheduleId,
    this.isOvernight = false,
  });

  factory DailySchedule.fromJson(Map<String, dynamic> json) {
    return DailySchedule(
      isWorkingDay: json['is_working_day'] ?? true,
      startTime: json['start_time'],
      endTime: json['end_time'],
      breakStart: json['break_start'],
      breakEnd: json['break_end'],
      source: json['source'] ?? 'none',
      scheduleName: json['schedule_name'],
      shiftId: json['shift_id'],
      workScheduleId: json['work_schedule_id'],
      isOvernight: json['is_overnight'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'is_working_day': isWorkingDay,
      'start_time': startTime,
      'end_time': endTime,
      'break_start': breakStart,
      'break_end': breakEnd,
      'source': source,
      'schedule_name': scheduleName,
      'shift_id': shiftId,
      'work_schedule_id': workScheduleId,
      'is_overnight': isOvernight,
    };
  }

  // Factory for "No Schedule"
  factory DailySchedule.unscheduled() {
    return DailySchedule(
      isWorkingDay: true, // Allow attendance
      source: 'none',
      scheduleName: 'Flexible / Unscheduled',
    );
  }
}
