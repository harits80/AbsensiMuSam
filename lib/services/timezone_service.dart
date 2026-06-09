import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:shared_preferences/shared_preferences.dart';

class TimezoneService {
  static const String _selectedTimezoneKey = 'selected_timezone';
  static const String _autoDetectKey = 'auto_detect_timezone';

  // Daftar timezone yang tersedia
  static final List<Map<String, String>> availableTimezones = [
    {'name': 'Asia/Jakarta', 'display': 'Jakarta (WIB)', 'gmt': 'GMT+7'},
    {'name': 'Asia/Makassar', 'display': 'Makassar (WITA)', 'gmt': 'GMT+8'},
    {'name': 'Asia/Jayapura', 'display': 'Jayapura (WIT)', 'gmt': 'GMT+9'},
    {'name': 'Asia/Tokyo', 'display': 'Tokyo (JST)', 'gmt': 'GMT+9'},
    {'name': 'Asia/Seoul', 'display': 'Seoul (KST)', 'gmt': 'GMT+9'},
    {'name': 'Asia/Shanghai', 'display': 'Shanghai (CST)', 'gmt': 'GMT+8'},
    {'name': 'Asia/Singapore', 'display': 'Singapore', 'gmt': 'GMT+8'},
    {'name': 'Asia/Bangkok', 'display': 'Bangkok', 'gmt': 'GMT+7'},
    {'name': 'Asia/Dubai', 'display': 'Dubai', 'gmt': 'GMT+4'},
    {'name': 'Asia/Kolkata', 'display': 'Kolkata (IST)', 'gmt': 'GMT+5:30'},
    {'name': 'Europe/London', 'display': 'London (GMT)', 'gmt': 'GMT+0'},
    {'name': 'Europe/Paris', 'display': 'Paris (CET)', 'gmt': 'GMT+1'},
    {'name': 'America/New_York', 'display': 'New York (EST)', 'gmt': 'GMT-5'},
    {'name': 'America/Los_Angeles', 'display': 'Los Angeles (PST)', 'gmt': 'GMT-8'},
    {'name': 'Australia/Sydney', 'display': 'Sydney (AEDT)', 'gmt': 'GMT+11'},
  ];

  // Inisialisasi timezone database
  static void initialize() {
    tz_data.initializeTimeZones();
  }

  // Mendapatkan timezone yang dipilih
  Future<String> getSelectedTimezone() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_selectedTimezoneKey);
    if (saved != null && saved.isNotEmpty) {
      return saved;
    }
    // Default ke Asia/Jakarta
    return 'Asia/Jakarta';
  }

  // Mendapatkan status auto detect
  Future<bool> isAutoDetectEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoDetectKey) ?? true;
  }

  // Menyimpan timezone yang dipilih
  Future<void> setSelectedTimezone(String timezone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedTimezoneKey, timezone);
  }

  // Mengatur auto detect
  Future<void> setAutoDetectEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoDetectKey, enabled);
  }

  // Mendapatkan waktu sekarang berdasarkan timezone
  Future<DateTime> getCurrentTimeInTimezone() async {
    final timezone = await getSelectedTimezone();
    return getTimeInTimezone(timezone);
  }

  // Mendapatkan waktu di timezone tertentu
  static DateTime getTimeInTimezone(String timezoneName) {
    try {
      final location = tz.getLocation(timezoneName);
      final now = tz.TZDateTime.now(location);
      return now;
    } catch (e) {
      // Fallback ke UTC
      return DateTime.now().toUtc();
    }
  }

  // Mendapatkan info timezone (display name dan GMT)
  static Map<String, String>? getTimezoneInfo(String timezoneName) {
    try {
      return availableTimezones.firstWhere(
        (tz) => tz['name'] == timezoneName,
        orElse: () => {'name': 'Asia/Jakarta', 'display': 'Jakarta (WIB)', 'gmt': 'GMT+7'},
      );
    } catch (e) {
      return null;
    }
  }

  // Format waktu berdasarkan timezone
  Future<String> formatTime(DateTime time, {String format = 'HH:mm'}) async {
    final timezone = await getSelectedTimezone();
    final location = tz.getLocation(timezone);
    final tzTime = tz.TZDateTime.from(time, location);
    
    switch (format) {
      case 'HH:mm':
        return '${tzTime.hour.toString().padLeft(2, '0')}:${tzTime.minute.toString().padLeft(2, '0')}';
      case 'HH:mm:ss':
        return '${tzTime.hour.toString().padLeft(2, '0')}:${tzTime.minute.toString().padLeft(2, '0')}:${tzTime.second.toString().padLeft(2, '0')}';
      case 'dd/MM/yyyy':
        return '${tzTime.day.toString().padLeft(2, '0')}/${tzTime.month.toString().padLeft(2, '0')}/${tzTime.year}';
      case 'yyyy-MM-dd':
        return '${tzTime.year}-${tzTime.month.toString().padLeft(2, '0')}-${tzTime.day.toString().padLeft(2, '0')}';
      default:
        return '$tzTime';
    }
  }

  // Mendapatkan tanggal lengkap dengan nama hari
  Future<String> getFullDate() async {
    final now = await getCurrentTimeInTimezone();
    final weekdays = ['Minggu', 'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu'];
    final months = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 
                    'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'];
    
    return '${weekdays[now.weekday % 7]}, ${now.day} ${months[now.month - 1]} ${now.year}';
  }

  // Mendapatkan jam dengan AM/PM
  Future<String> getTimeWithAmPm() async {
    final now = await getCurrentTimeInTimezone();
    final hour = now.hour;
    final minute = now.minute;
    final period = hour >= 12 ? 'PM' : 'AM';
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$hour12:${minute.toString().padLeft(2, '0')} $period';
  }
}