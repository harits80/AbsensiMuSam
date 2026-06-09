import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:device_info_plus/device_info_plus.dart';

class LocationService {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (!_initialized) {
      tz_data.initializeTimeZones();
      _initialized = true;
    }
  }

  /// Get device timezone accurately
  static String getDeviceTimezone() {
    try {
      if (!_initialized) initialize();
      return tz.local.name;
    } catch (e) {
      // Fallback ke Jakarta
      return 'Asia/Jakarta';
    }
  }

  /// Get timezone offset in hours
  static int getTimezoneOffsetHour(String timezone) {
    final now = DateTime.now().toUtc();
    final location = tz.getLocation(timezone);
    final tzDateTime = tz.TZDateTime.from(now, location);
    return tzDateTime.timeZoneOffset.inHours;
  }

  /// Validate if timezone string is valid
  static bool isValidTimezone(String timezone) {
    try {
      tz.getLocation(timezone);
      return true;
    } catch (e) {
      return false;
    }
  }
}
