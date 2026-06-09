import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import '../models/attendance_model.dart';
import '../helpers/cache_helper.dart';

class DeviceService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final CacheHelper _cache = CacheHelper();
  AttendanceDevice? _selectedDevice;

  static const String _selectedDeviceKey = 'selected_device_id';
  static const Duration _devicesCacheTTL = Duration(minutes: 10);

  AttendanceDevice? get selectedDevice => _selectedDevice;

  /// Load all devices for the given organization
  Future<List<AttendanceDevice>> loadDevices(
    String organizationId, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = 'devices_list_$organizationId';

    // Check cache first
    if (!forceRefresh) {
      final cached = _cache.get<List<AttendanceDevice>>(cacheKey);
      if (cached != null) {
        debugPrint('DeviceService: Devices loaded from cache');
        return cached;
      }
    }

    try {
      final response = await _supabase
          .from('attendance_devices')
          .select('''
            *,
            device_types(name, category)
          ''')
          .eq('organization_id', int.parse(organizationId))
          .eq('is_active', true)
          .eq('device_type_id', 7) // Filter for mobile devices only
          .order('device_name');

      final devices = List<Map<String, dynamic>>.from(
        response,
      ).map((json) => AttendanceDevice.fromJson(json)).toList();

      // Cache the result
      _cache.set(cacheKey, devices, ttl: _devicesCacheTTL);

      return devices;
    } catch (e) {
      throw Exception('Error loading devices: $e');
    }
  }

  /// Load a specific device by ID
  Future<AttendanceDevice?> loadDeviceById(
    String deviceId, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = 'device_$deviceId';

    // Check cache first
    if (!forceRefresh) {
      final cached = _cache.get<AttendanceDevice>(cacheKey);
      if (cached != null) {
        debugPrint('DeviceService: Device loaded from cache');
        return cached;
      }
    }

    try {
      debugPrint('DeviceService: Loading device by ID: $deviceId');
      final response = await _supabase
          .from('attendance_devices')
          .select('''
            *,
            device_types(name, category)
          ''')
          .eq('id', int.parse(deviceId))
          .eq('is_active', true)
          .maybeSingle();

      if (response != null) {
        final device = AttendanceDevice.fromJson(response);
        debugPrint(
          'DeviceService: Device found: ${device.deviceName} (ID: ${device.id}, OrgID: ${device.organizationId})',
        );

        // Cache the result
        _cache.set(cacheKey, device, ttl: _devicesCacheTTL);

        return device;
      }
      debugPrint('DeviceService: Device not found for ID: $deviceId');
      return null;
    } catch (e) {
      debugPrint('DeviceService: Error loading device: $e');
      throw Exception('Error loading device: $e');
    }
  }

  /// Set the selected device and save to preferences
  Future<void> setSelectedDevice(AttendanceDevice device) async {
    try {
      _selectedDevice = device;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedDeviceKey, device.id);

      debugPrint(
        'DeviceService: Device saved to preferences: ${device.deviceName} (ID: ${device.id})',
      );

      // Verify it was saved
      final savedId = prefs.getString(_selectedDeviceKey);
      debugPrint('DeviceService: Verified saved ID: $savedId');
    } catch (e) {
      debugPrint('DeviceService: Error setting selected device: $e');
      throw Exception('Error setting selected device: $e');
    }
  }

  /// Load the previously selected device from preferences
  Future<AttendanceDevice?> loadSelectedDevice(String organizationId) async {
    try {
      debugPrint(
        'DeviceService: Loading selected device for org: $organizationId',
      );

      // ALWAYS load from SharedPreferences first to ensure we get the latest saved device
      final prefs = await SharedPreferences.getInstance();
      final savedDeviceId = prefs.getString(_selectedDeviceKey);

      debugPrint(
        'DeviceService: Saved device ID in preferences: $savedDeviceId',
      );
      debugPrint(
        'DeviceService: Current cache: ${_selectedDevice?.deviceName} (ID: ${_selectedDevice?.id})',
      );

      if (savedDeviceId != null) {
        final device = await loadDeviceById(savedDeviceId);
        if (device != null) {
          debugPrint(
            'DeviceService: Loaded device org ID: ${device.organizationId}, requested org ID: $organizationId',
          );
          if (device.organizationId == organizationId) {
            _selectedDevice = device;
            debugPrint(
              'DeviceService: Device loaded and cached: ${device.deviceName}',
            );
            return device;
          } else {
            debugPrint(
              'DeviceService: WARNING - Device org ID mismatch! Device org: ${device.organizationId}, current org: $organizationId',
            );
            return null;
          }
        } else {
          debugPrint(
            'DeviceService: Device not found in database for saved ID: $savedDeviceId',
          );
          return null;
        }
      }

      debugPrint('DeviceService: No device saved in preferences');
      return null;
    } catch (e) {
      debugPrint('DeviceService: Error loading selected device: $e');
      throw Exception('Error loading selected device: $e');
    }
  }

  /// Clear the selected device
  Future<void> clearSelectedDevice() async {
    try {
      debugPrint('DeviceService: Clearing selected device');
      _selectedDevice = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_selectedDeviceKey);

      debugPrint(
        'DeviceService: Selected device cleared from cache and preferences',
      );
    } catch (e) {
      debugPrint('DeviceService: Error clearing selected device: $e');
      throw Exception('Error clearing selected device: $e');
    }
  }

  /// Check if a device selection is required for the organization
  Future<bool> isSelectionRequired(
    String organizationId, {
    bool forceRefresh = false,
  }) async {
    try {
      debugPrint(
        'DeviceService: Checking if selection required for org: $organizationId',
      );
      // ✅ OPTIMIZATION: Use cached devices if available
      final devices = await loadDevices(
        organizationId,
        forceRefresh: forceRefresh,
      );

      debugPrint('DeviceService: Found ${devices.length} devices');

      // If there are multiple devices, selection is required
      if (devices.length > 1) {
        debugPrint(
          'DeviceService: Multiple devices found - selection required',
        );
        return true;
      }

      // If there's exactly one device, auto-select it
      if (devices.length == 1) {
        debugPrint(
          'DeviceService: Single device found - auto-selecting: ${devices.first.deviceName}',
        );
        await setSelectedDevice(devices.first);
        return false;
      }

      // No devices available - selection not required
      debugPrint('DeviceService: No devices found');
      return false;
    } catch (e) {
      debugPrint('DeviceService: Error checking selection requirement: $e');
      throw Exception('Error checking selection requirement: $e');
    }
  }
}
