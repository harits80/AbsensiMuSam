// lib/helpers/rfid_mode_helper.dart

import 'package:shared_preferences/shared_preferences.dart';

class RfidModeHelper {
  static const String _rfidModeKey = 'rfid_attendance_mode'; // Legacy: bool
  static const String _attendanceModeKey = 'selected_attendance_mode'; // New: String ('face', 'rfid', 'fingerprint')
  static const String _rfidModeOrgKey = 'rfid_attendance_mode_org_id';

  // Get current attendance mode ('face' is default)
  static Future<String> getAttendanceMode(int organizationId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedOrgId = prefs.getInt(_rfidModeOrgKey);
      
      if (savedOrgId == organizationId) {
        // First try the new string-based mode
        final mode = prefs.getString(_attendanceModeKey);
        if (mode != null) return mode;
        
        // Fallback to legacy bool mode if string mode is not yet set
        final isRfid = prefs.getBool(_rfidModeKey) ?? false;
        return isRfid ? 'rfid' : 'face';
      }
      
      return 'face'; // Default
    } catch (e) {
      return 'face';
    }
  }

  // Save current attendance mode
  static Future<void> saveAttendanceMode(int organizationId, String mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_attendanceModeKey, mode);
      await prefs.setInt(_rfidModeOrgKey, organizationId);
      
      // Update legacy key for backward compatibility
      await prefs.setBool(_rfidModeKey, mode == 'rfid');
    } catch (e) {
      // Silently fail
    }
  }

  // Get saved RFID mode (Proxy for backward compatibility)
  static Future<bool> getRfidMode(int organizationId) async {
    final mode = await getAttendanceMode(organizationId);
    return mode == 'rfid';
  }

  // Save RFID mode (Proxy for backward compatibility)
  static Future<void> saveRfidMode(int organizationId, bool enabled) async {
    await saveAttendanceMode(organizationId, enabled ? 'rfid' : 'face');
  }

  // Clear all attendance settings
  static Future<void> clearAttendanceSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_rfidModeKey);
      await prefs.remove(_attendanceModeKey);
      await prefs.remove(_rfidModeOrgKey);
    } catch (e) {
      // Silently fail
    }
  }
}

