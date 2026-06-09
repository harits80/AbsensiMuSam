// helpers/cache_helper.dart
import 'dart:async';
import 'package:flutter/foundation.dart';

/// Cache helper untuk in-memory caching dengan TTL (Time To Live)
/// Optimized untuk low-end devices - menggunakan Map sederhana tanpa SQL
class CacheHelper {
  static final CacheHelper _instance = CacheHelper._internal();
  factory CacheHelper() => _instance;
  CacheHelper._internal();

  final Map<String, _CacheItem> _cache = {};
  Timer? _cleanupTimer;

  /// Initialize cache dengan auto cleanup
  void initialize() {
    // Cleanup setiap 5 menit untuk menghapus expired items
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _cleanupExpired();
    });
  }

  /// Set cache dengan TTL
  void set<T>(String key, T value, {Duration? ttl}) {
    final expirationTime = DateTime.now().add(ttl ?? const Duration(minutes: 10));
    _cache[key] = _CacheItem(value, expirationTime);
    
    // Limit cache size untuk low-end devices (max 50 items)
    if (_cache.length > 50) {
      _evictOldest();
    }
  }

  /// Get cache value
  T? get<T>(String key) {
    final item = _cache[key];
    if (item == null) return null;
    
    // Check if expired
    if (DateTime.now().isAfter(item.expirationTime)) {
      _cache.remove(key);
      return null;
    }
    
    return item.value as T?;
  }

  /// Check if key exists and is valid
  bool has(String key) {
    final item = _cache[key];
    if (item == null) return false;
    
    if (DateTime.now().isAfter(item.expirationTime)) {
      _cache.remove(key);
      return false;
    }
    
    return true;
  }

  /// Remove specific key
  void remove(String key) {
    _cache.remove(key);
  }

  /// Clear all cache
  void clear() {
    _cache.clear();
  }

  /// Clear cache by prefix
  void clearByPrefix(String prefix) {
    final keysToRemove = _cache.keys.where((key) => key.startsWith(prefix)).toList();
    for (final key in keysToRemove) {
      _cache.remove(key);
    }
  }

  /// Get cache size
  int get size => _cache.length;

  /// Cleanup expired items
  void _cleanupExpired() {
    final now = DateTime.now();
    final keysToRemove = <String>[];
    
    _cache.forEach((key, item) {
      if (now.isAfter(item.expirationTime)) {
        keysToRemove.add(key);
      }
    });
    
    for (final key in keysToRemove) {
      _cache.remove(key);
    }
    
    if (keysToRemove.isNotEmpty) {
      debugPrint('CacheHelper: Cleaned up ${keysToRemove.length} expired items');
    }
  }

  /// Evict oldest items when cache is full
  void _evictOldest() {
    if (_cache.isEmpty) return;
    
    // ✅ OPTIMIZATION: Tidak perlu sort semua items (expensive), cukup remove 10% random atau berdasarkan expiration
    // Find items that are close to expiration (within 1 minute)
    final now = DateTime.now();
    final itemsToRemove = <String>[];
    final targetRemoval = (_cache.length * 0.1).ceil();
    
    // ✅ OPTIMIZATION: Remove expired or near-expired items first (more efficient)
    _cache.forEach((key, item) {
      if (itemsToRemove.length >= targetRemoval) return;
      
      // Remove items that expire within 1 minute
      if (item.expirationTime.difference(now).inMinutes < 1) {
        itemsToRemove.add(key);
      }
    });
    
    // ✅ OPTIMIZATION: If not enough items found, remove random items (faster than sorting)
    if (itemsToRemove.length < targetRemoval) {
      final remaining = targetRemoval - itemsToRemove.length;
      final keys = _cache.keys.where((k) => !itemsToRemove.contains(k)).toList();
      keys.shuffle(); // ✅ Random shuffle is faster than sorting
      
      for (int i = 0; i < remaining && i < keys.length; i++) {
        itemsToRemove.add(keys[i]);
      }
    }
    
    // Remove selected items
    for (final key in itemsToRemove) {
      _cache.remove(key);
    }
    
    if (itemsToRemove.isNotEmpty) {
      debugPrint('CacheHelper: Evicted ${itemsToRemove.length} items (${(_cache.length / 50 * 100).toStringAsFixed(0)}% full)');
    }
  }

  /// Dispose cache
  void dispose() {
    _cleanupTimer?.cancel();
    _cache.clear();
  }
}

/// Cache item dengan expiration time
class _CacheItem {
  final dynamic value;
  final DateTime expirationTime;

  _CacheItem(this.value, this.expirationTime);
}

/// Cache keys untuk konsistensi
class CacheKeys {
  static const String userProfile = 'user_profile';
  static const String organizationMember = 'org_member';
  static const String organization = 'organization';
  static const String currentSchedule = 'current_schedule';
  static const String scheduleDetails = 'schedule_details';
  static const String attendanceDevice = 'attendance_device';
  static const String todayRecords = 'today_records';
  static const String todayLogs = 'today_logs';
  static const String recentRecords = 'recent_records';
  static const String attendanceStatus = 'attendance_status';
  static const String availableActions = 'available_actions';
  static const String breakInfo = 'break_info';
  static const String workLocation = 'work_location';
  
  /// Generate key dengan parameter
  static String userProfileKey(String userId) => '${userProfile}_$userId';
  static String orgMemberKey(String userId) => '${organizationMember}_$userId';
  static String orgKey(String orgId) => '${organization}_$orgId';
  static String scheduleKey(String memberId) => '${currentSchedule}_$memberId';
  static String scheduleDetailsKey(String scheduleId, int dayOfWeek) => 
      '${scheduleDetails}_${scheduleId}_$dayOfWeek';
  static String deviceKey(String orgId) => '${attendanceDevice}_$orgId';
  static String todayRecordsKey(String memberId) => '${todayRecords}_$memberId';
  static String todayLogsKey(String memberId) => '${todayLogs}_$memberId';
  static String recentRecordsKey(String memberId) => '${recentRecords}_$memberId';
  static String statusKey(String memberId) => '${attendanceStatus}_$memberId';
  static String actionsKey(String memberId) => '${availableActions}_$memberId';
  static String breakInfoKey(String memberId) => '${breakInfo}_$memberId';
  static String workLocationKey(String memberId) => '${workLocation}_$memberId';
}

