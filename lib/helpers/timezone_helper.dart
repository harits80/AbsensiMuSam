import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

class TimezoneHelper {
  static bool _initialized = false;

  /// Initialize timezone database (panggil sekali di main)
  static void _ensureInitialized() {
    if (!_initialized) {
      tz_data.initializeTimeZones();
      _initialized = true;
    }
  }

  /// Parse ISO string and convert to target timezone
  /// Returns DateTime in target timezone
  static DateTime? parseAndConvert(String? isoString, String targetTimezone) {
    if (isoString == null || isoString.isEmpty) {
      return null;
    }

    try {
      // Parse as UTC first
      final utcDateTime = DateTime.parse(isoString);
      // Convert UTC to target timezone with DST support
      return convertUtcToTargetTimezone(utcDateTime, targetTimezone);
    } catch (e) {
      return null;
    }
  }

  /// Get timezone offset with DST (Daylight Saving Time) support
  /// Returns offset in hours as double (supports half-hour like +5:30)
  static double getTimezoneOffsetWithDST(
    String timezone, [
    DateTime? dateTime,
  ]) {
    _ensureInitialized();

    final targetDate = dateTime ?? DateTime.now().toUtc();

    try {
      final location = tz.getLocation(timezone);
      final tzDateTime = tz.TZDateTime.from(targetDate, location);
      // Get offset in minutes, convert to hours (supports 5.5 for Kolkata)
      return tzDateTime.timeZoneOffset.inMinutes / 60.0;
    } catch (e) {
      // Fallback to manual mapping if timezone package fails
      return getTimezoneOffsetLegacy(timezone).toDouble();
    }
  }

  /// Get timezone offset in hours from UTC (Legacy - tanpa DST)
  static int getTimezoneOffsetLegacy(String timezone) {
    final tzLower = timezone.toLowerCase().trim();

    // Indonesia timezones
    if (tzLower.contains('jakarta') ||
        tzLower == 'wib' ||
        tzLower == 'asia/jakarta') {
      return 7;
    } else if (tzLower.contains('makassar') ||
        tzLower == 'wita' ||
        tzLower == 'asia/makassar') {
      return 8;
    } else if (tzLower.contains('jayapura') ||
        tzLower == 'wit' ||
        tzLower == 'asia/jayapura') {
      return 9;
    }
    // International timezones
    else if (tzLower == 'asia/bangkok') {
      return 7;
    } else if (tzLower == 'asia/dubai') {
      return 4;
    } else if (tzLower == 'asia/kolkata') {
      return 5;
    } else if (tzLower == 'asia/singapore') {
      return 8;
    } else if (tzLower == 'asia/tokyo') {
      return 9;
    } else if (tzLower == 'asia/seoul') {
      return 9;
    } else if (tzLower == 'asia/shanghai') {
      return 8;
    } else if (tzLower == 'europe/london') {
      return 0;
    } else if (tzLower == 'europe/paris') {
      return 1;
    } else if (tzLower == 'europe/berlin') {
      return 1;
    } else if (tzLower == 'europe/rome') {
      return 1;
    } else if (tzLower == 'america/new_york') {
      return -4;
    } else if (tzLower == 'america/los_angeles') {
      return -7;
    } else if (tzLower == 'america/chicago') {
      return -5;
    } else if (tzLower == 'utc' || tzLower == 'gmt' || tzLower == 'utc+0') {
      return 0;
    }

    // Try to parse offset from format like "UTC+7"
    if (tzLower.startsWith('utc+') || tzLower.startsWith('utc-')) {
      try {
        final offsetStr = tzLower
            .replaceAll('utc', '')
            .replaceAll('+', '')
            .replaceAll('-', '');
        final offset = int.parse(offsetStr);
        return tzLower.contains('-') ? -offset : offset;
      } catch (e) {}
    }

    // Default to WIB
    return 7;
  }

  /// Get timezone display name
  static String getTimezoneDisplayName(String timezone) {
    final tzLower = timezone.toLowerCase().trim();

    switch (tzLower) {
      case 'asia/jakarta':
        return 'WIB (UTC+7)';
      case 'asia/makassar':
        return 'WITA (UTC+8)';
      case 'asia/jayapura':
        return 'WIT (UTC+9)';
      case 'asia/bangkok':
        return 'Bangkok (UTC+7)';
      case 'asia/dubai':
        return 'Dubai (UTC+4)';
      case 'asia/kolkata':
        return 'Kolkata (UTC+5:30)';
      case 'asia/singapore':
        return 'Singapore (UTC+8)';
      case 'asia/tokyo':
        return 'Tokyo (UTC+9)';
      case 'europe/london':
        return 'London (UTC+0)';
      case 'europe/paris':
        return 'Paris (UTC+1)';
      case 'america/new_york':
        return 'New York (UTC-4)';
      default:
        return timezone;
    }
  }

  /// Get current UTC time
  static DateTime getCurrentUtcTime() {
    return DateTime.now().toUtc();
  }

  /// Get current time in specified timezone (DENGAN DST)
  static DateTime getCurrentTimeInTimezone(String timezone) {
    _ensureInitialized();

    final nowUtc = DateTime.now().toUtc();
    return convertUtcToTargetTimezone(nowUtc, timezone);
  }

  /// Convert UTC DateTime to target timezone DateTime (DENGAN DST - AKURAT!)
  static DateTime convertUtcToTargetTimezone(
    DateTime utcDateTime,
    String targetTimezone,
  ) {
    _ensureInitialized();

    try {
      final location = tz.getLocation(targetTimezone);
      final tzDateTime = tz.TZDateTime.from(utcDateTime, location);
      return tzDateTime;
    } catch (e) {
      // Fallback to legacy method if timezone not found
      final offset = getTimezoneOffsetLegacy(targetTimezone);
      return utcDateTime.add(Duration(hours: offset));
    }
  }

  /// Convert UTC DateTime to target timezone DateTime (ALIAS untuk kompatibilitas)
  static DateTime convertUtcToOrgTimezone(
    DateTime utcDateTime,
    String targetTimezone,
  ) {
    return convertUtcToTargetTimezone(utcDateTime, targetTimezone);
  }

  /// Convert target timezone DateTime to UTC DateTime
  static DateTime convertOrgTimezoneToUtc(
    DateTime orgDateTime,
    String targetTimezone,
  ) {
    _ensureInitialized();

    try {
      final location = tz.getLocation(targetTimezone);
      final utcDateTime = tz.TZDateTime.from(orgDateTime, location).toUtc();
      return utcDateTime;
    } catch (e) {
      final offset = getTimezoneOffsetLegacy(targetTimezone);
      return orgDateTime.subtract(Duration(hours: offset));
    }
  }

  /// Get current date in target timezone (YYYY-MM-DD)
  static String getCurrentDateInTimezone(String targetTimezone) {
    final timeInTz = getCurrentTimeInTimezone(targetTimezone);
    return '${timeInTz.year}-${timeInTz.month.toString().padLeft(2, '0')}-${timeInTz.day.toString().padLeft(2, '0')}';
  }

  /// Format DateTime with timezone consideration
  static String formatDateTime(DateTime dateTime, String format) {
    return DateFormat(format).format(dateTime);
  }

  /// Parse UTC ISO string, convert to target timezone, and format
  static String formatToLocalTime(
    String? isoString,
    String targetTimezone, {
    String format = 'HH:mm:ss',
  }) {
    final dateTime = parseAndConvert(isoString, targetTimezone);
    if (dateTime == null) return '--:--';
    return DateFormat(format).format(dateTime);
  }

  /// Format DateTime as UTC string without milliseconds/microseconds for Supabase
  static String formatUtcForSupabase(DateTime dateTime) {
    final utc = dateTime.toUtc();
    return '${DateFormat('yyyy-MM-dd HH:mm:ss').format(utc)}+00';
  }

  /// Get current date in organization timezone (YYYY-MM-DD)
  static String getCurrentDateInOrgTimezone(String organizationTimezone) {
    return getCurrentDateInTimezone(organizationTimezone);
  }

  /// Get current time in organization timezone
  static DateTime getCurrentTimeInOrgTimezone(String organizationTimezone) {
    return getCurrentTimeInTimezone(organizationTimezone);
  }

  /// Get date for a specific UTC time in organization timezone (YYYY-MM-DD)
  static String getDateInOrgTimezone(
    DateTime utcTime,
    String organizationTimezone,
  ) {
    final timeInOrgTz = convertUtcToTargetTimezone(
      utcTime.toUtc(),
      organizationTimezone,
    );
    return '${timeInOrgTz.year}-${timeInOrgTz.month.toString().padLeft(2, '0')}-${timeInOrgTz.day.toString().padLeft(2, '0')}';
  }

  /// ========== METHOD TAMBAHAN ==========

  /// Check if two dates are the same day in target timezone
  static bool isSameDayInTimezone(
    DateTime date1,
    DateTime date2,
    String timezone,
  ) {
    final d1 = convertUtcToTargetTimezone(date1.toUtc(), timezone);
    final d2 = convertUtcToTargetTimezone(date2.toUtc(), timezone);
    return d1.year == d2.year && d1.month == d2.month && d1.day == d2.day;
  }

  /// Get start of day in target timezone (as UTC)
  static DateTime getStartOfDayInTimezone(DateTime date, String timezone) {
    final orgTime = convertUtcToTargetTimezone(date.toUtc(), timezone);
    final startOfDayOrg = DateTime(orgTime.year, orgTime.month, orgTime.day);
    return convertOrgTimezoneToUtc(startOfDayOrg, timezone);
  }

  /// Get end of day in target timezone (as UTC)
  static DateTime getEndOfDayInTimezone(DateTime date, String timezone) {
    final startOfDay = getStartOfDayInTimezone(date, timezone);
    return startOfDay
        .add(const Duration(days: 1))
        .subtract(const Duration(microseconds: 1));
  }

  /// Format time with AM/PM (12-hour format)
  static String formatTime12Hour(DateTime time) {
    final hour = time.hour;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = hour < 12 ? 'AM' : 'PM';
    final hour12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$hour12:$minute $period';
  }

  /// Format date with full month name
  static String formatDateLong(DateTime date, {String? locale}) {
    final formatter = DateFormat('EEEE, dd MMMM yyyy', locale ?? 'id_ID');
    return formatter.format(date);
  }

  /// Get relative time string (e.g., "2 hours ago", "yesterday")
  static String getRelativeTimeString(DateTime dateTime, String timezone) {
    final now = getCurrentTimeInTimezone(timezone);
    final diff = now.difference(dateTime);

    if (diff.inDays > 365) {
      return '${(diff.inDays / 365).floor()} tahun lalu';
    } else if (diff.inDays > 30) {
      return '${(diff.inDays / 30).floor()} bulan lalu';
    } else if (diff.inDays > 7) {
      return '${(diff.inDays / 7).floor()} minggu lalu';
    } else if (diff.inDays > 0) {
      return diff.inDays == 1 ? 'Kemarin' : '${diff.inDays} hari lalu';
    } else if (diff.inHours > 0) {
      return '${diff.inHours} jam lalu';
    } else if (diff.inMinutes > 0) {
      return '${diff.inMinutes} menit lalu';
    } else {
      return 'Baru saja';
    }
  }

  /// ========== METHOD UNTUK VALIDASI ==========

  /// Check if timezone string is valid
  static bool isValidTimezone(String timezone) {
    _ensureInitialized();
    try {
      tz.getLocation(timezone);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Get list of all available timezones
  static List<String> getAllTimezones() {
    _ensureInitialized();
    return tz.timeZoneDatabase.locations.keys.toList();
  }

  /// Get current offset with DST information
  static String getCurrentOffsetString(String timezone) {
    final offset = getTimezoneOffsetWithDST(timezone);
    final sign = offset >= 0 ? '+' : '';
    final hours = offset.floor();
    final minutes = ((offset - hours) * 60).round();

    if (minutes == 0) {
      return 'UTC$sign$hours';
    } else {
      return 'UTC$sign$hours:$minutes';
    }
  }
}
