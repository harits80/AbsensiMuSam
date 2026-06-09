// lib/services/attendance_sync_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../models/offline_attendance.dart';
import '../../services/offline_database_service.dart';
import 'attendance_service.dart';
import '../../services/supabase_storage_service.dart';

class AttendanceSyncService {
  static final AttendanceSyncService _instance =
      AttendanceSyncService._internal();
  factory AttendanceSyncService() => _instance;
  AttendanceSyncService._internal();

  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseStorageService _storageService = SupabaseStorageService();
  final SupabaseClient _supabase = Supabase.instance.client;

  Timer? _autoSyncTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isSyncing = false;
  Completer<SyncResult>? _activeSyncCompleter;
  int _currentIntervalSeconds = 10;
  static const int _baseIntervalSeconds = 10;
  static const int _maxIntervalSeconds = 600; // 10 minutes

  // Track active sync state for late-attaching UI
  List<OfflineAttendance>? _activeSyncRecords;
  int _activeSyncProgress = 0;
  int _activeSyncTotal = 0;

  final _syncStatusController = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get syncStatusStream => _syncStatusController.stream;

  // Get current sync state for UI attachment
  SyncStatus? get currentStatus {
    if (!_isSyncing) return null;
    return SyncStatus(
      isLoading: true,
      message: _activeSyncRecords == null
          ? 'Initializing sync...'
          : 'Syncing... ($_activeSyncProgress/$_activeSyncTotal)',
      progress: _activeSyncProgress,
      total: _activeSyncTotal,
      records: _activeSyncRecords,
    );
  }

  // Start auto sync with dynamic interval
  void startAutoSync() {
    stopAutoSync();
    _currentIntervalSeconds = _baseIntervalSeconds;

    // Fire once immediately
    _triggerSync(reason: 'startup');

    _scheduleNextSync();

    // Listen to connectivity so the queue ships immediately after back online
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      if (results.isNotEmpty && !results.contains(ConnectivityResult.none)) {
        // Reset interval when coming back online
        _currentIntervalSeconds = _baseIntervalSeconds;
        _triggerSync(reason: 'connectivity');
      }
    });
  }

  void _scheduleNextSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(
      Duration(seconds: _currentIntervalSeconds),
      () async {
        final success = await _triggerSync(reason: 'timer');

        // Update interval based on success
        if (success) {
          _currentIntervalSeconds = _baseIntervalSeconds;
        } else {
          _currentIntervalSeconds = (_currentIntervalSeconds + 10).clamp(
            _baseIntervalSeconds,
            _maxIntervalSeconds,
          );
        }

        _scheduleNextSync();
      },
    );
  }

  // Stop auto sync
  void stopAutoSync() {
    _autoSyncTimer?.cancel();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  // Check internet connectivity
  Future<bool> _checkConnectivity() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult.isEmpty || connectivityResult.contains(ConnectivityResult.none)) {
        return false;
      }

      // Additional check: try to reach Supabase
      final result = await InternetAddress.lookup(
        'supabase.co',
      ).timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (e) {
      debugPrint('Connectivity check failed: $e');
      return false;
    }
  }

  // Safe guard to prevent overlapping syncs and skip when queue empty
  // Returns true if sync was successful or skipped (nothing to sync), false if it failed
  Future<bool> _triggerSync({String reason = 'timer'}) async {
    if (_isSyncing) return true;

    final pending = await _offlineDb.getUnsyncedCount();
    if (pending == 0) {
      return true; // Nothing to sync, consider success to keep interval low
    }

    final isOnline = await _checkConnectivity();
    if (!isOnline) {
      debugPrint(
        '⏸️ Sync skipped ($reason) - offline. Current interval: $_currentIntervalSeconds s',
      );
      return false; // Failed to send because offline
    }

    debugPrint(
      '🚚 Triggering sync ($reason), pending: $pending. Interval: $_currentIntervalSeconds s',
    );
    final result = await syncPendingAttendances();

    // If some records failed to sync, consider it a failure for backoff purposes
    return result.success && result.failedCount == 0;
  }

  // Sync all pending attendances
  Future<SyncResult> syncPendingAttendances({bool showProgress = false}) async {
    if (_isSyncing) {
      if (_activeSyncCompleter != null) return _activeSyncCompleter!.future;
      return SyncResult(
        success: false,
        message: 'Sync already in progress',
        syncedCount: 0,
        failedCount: 0,
      );
    }

    _isSyncing = true;
    _activeSyncCompleter = Completer<SyncResult>();

    try {
      // Get unsynced records FIRST so we can show them even if offline
      final unsyncedRecords = await _offlineDb.getUnsyncedAttendances();
      _activeSyncRecords = List.from(unsyncedRecords);
      _activeSyncTotal = unsyncedRecords.length;
      _activeSyncProgress = 0;

      _syncStatusController.add(
        SyncStatus(
          isLoading: true,
          message: 'Syncing pending attendances...',
          records: _activeSyncRecords,
        ),
      );

      if (unsyncedRecords.isEmpty) {
        if (showProgress) {
          _syncStatusController.add(
            SyncStatus(
              isLoading: false,
              message: 'No pending data to sync',
              records: [],
            ),
          );
        }
        final result = SyncResult(
          success: true,
          message: 'No pending data to sync',
          syncedCount: 0,
          failedCount: 0,
        );
        _activeSyncCompleter?.complete(result);
        return result;
      }

      if (showProgress) {
        _syncStatusController.add(
          SyncStatus(
            isLoading: true,
            message: 'Checking connectivity...',
            records: _activeSyncRecords,
          ),
        );
      }

      // Check connectivity
      final isOnline = await _checkConnectivity();
      if (!isOnline) {
        if (showProgress) {
          _syncStatusController.add(
            SyncStatus(
              isLoading: false,
              message: 'No internet connection',
              isError: true,
              records: _activeSyncRecords,
            ),
          );
        }
        final result = SyncResult(
          success: false,
          message: 'No internet connection',
          syncedCount: 0,
          failedCount: 0,
        );
        _activeSyncCompleter?.complete(result);
        return result;
      }

      // ✅ Auto-Cleanup: Prune old records (older than 7 days)
      await _offlineDb.pruneOldRecords(days: 7);

      _syncStatusController.add(
        SyncStatus(
          isLoading: true,
          message: 'Syncing ${unsyncedRecords.length} records...',
          progress: 0,
          total: unsyncedRecords.length,
          records: _activeSyncRecords,
        ),
      );

      int syncedCount = 0;
      int failedCount = 0;
      final List<String> errors = [];

      for (int i = 0; i < unsyncedRecords.length; i++) {
        final record = unsyncedRecords[i];

        debugPrint(
          '🔄 [${i + 1}/${unsyncedRecords.length}] Syncing record ID: ${record.id}, Method: ${record.method}',
        );

        try {
          final updatedName = await _syncSingleRecord(record);
          syncedCount++;

          // Update the local record list if name was fetched
          if (updatedName != null) {
            _activeSyncRecords![i] = _activeSyncRecords![i].copyWith(
              userName: updatedName,
            );
          }

          await _offlineDb.updateSyncStatus(
            id: record.id!,
            isSynced: true,
            syncError: null,
          );

          await _offlineDb.deleteAttendance(record.id!);

          _activeSyncProgress = i + 1;

          _syncStatusController.add(
            SyncStatus(
              isLoading: true,
              message: 'Syncing... ($syncedCount/${unsyncedRecords.length})',
              progress: _activeSyncProgress,
              total: _activeSyncTotal,
              records: _activeSyncRecords,
            ),
          );
        } catch (e) {
          final errorMessage = e.toString();

          final isDuplicate =
              errorMessage.contains('Already checked') ||
              errorMessage.contains('already') ||
              errorMessage.toLowerCase().contains('duplicate');

          final isFatal =
              errorMessage.contains('No check-in record found') ||
              errorMessage.contains('No attendance record found') ||
              errorMessage.contains('No-Check-In');

          if (isDuplicate || isFatal) {
            debugPrint(
              '⚠️ ${isFatal ? "FATAL" : "DUPLICATE"} record ${record.id}: $errorMessage',
            );
            try {
              await _offlineDb.updateSyncStatus(
                id: record.id!,
                isSynced: true,
                syncError:
                    '${isFatal ? "FATAL: " : "Duplicate: "}$errorMessage',
              );

              if (isDuplicate) {
                await _offlineDb.deleteAttendance(record.id!);
              }
            } catch (updateError) {
              debugPrint('❌ Update failed: $updateError');
            }
            syncedCount++;
          } else {
            failedCount++;
            errors.add('Failed: ${record.userName ?? record.cardNumber} - $e');
            debugPrint('❌ Sync failed for record ${record.id}: $e');

            await _offlineDb.updateSyncStatus(
              id: record.id!,
              isSynced: false,
              syncError: errorMessage,
            );
          }
        }
      }

      if (syncedCount > 0) {
        await _offlineDb.deleteSuccessfullySyncedAttendances();
      }

      final summaryMessage = syncedCount > 0
          ? 'Synced: $syncedCount${failedCount > 0 ? ", Failed: $failedCount" : ""}'
          : 'All syncs failed';

      if (showProgress) {
        _syncStatusController.add(
          SyncStatus(
            isLoading: false,
            message: summaryMessage,
            isError: failedCount > 0 && syncedCount == 0,
            records: _activeSyncRecords,
            progress: _activeSyncProgress,
            total: _activeSyncTotal,
          ),
        );
      }

      final result = SyncResult(
        success: syncedCount > 0,
        message: summaryMessage,
        syncedCount: syncedCount,
        failedCount: failedCount,
        errors: errors.isEmpty ? null : errors,
      );
      _activeSyncCompleter?.complete(result);
      return result;
    } catch (e) {
      debugPrint('General sync error: $e');
      if (showProgress) {
        _syncStatusController.add(
          SyncStatus(
            isLoading: false,
            message: 'Error: $e',
            isError: true,
            records: _activeSyncRecords,
          ),
        );
      }
      final result = SyncResult(
        success: false,
        message: 'Error: $e',
        syncedCount: 0,
        failedCount: 0,
      );
      _activeSyncCompleter?.complete(result);
      return result;
    } finally {
      _isSyncing = false;
      _activeSyncCompleter = null;
      _syncStatusController.add(
        SyncStatus(
          isLoading: false,
          message: 'Sync finished',
          records: _activeSyncRecords,
          progress: _activeSyncProgress,
          total: _activeSyncTotal,
        ),
      );
    }
  }

  // Sync single record
  Future<String?> _syncSingleRecord(OfflineAttendance record) async {
    int memberId;
    String? updatedName;

    // For RFID: Find member by card number
    if (record.method == 'rfid_card_mobile') {
      final cardData = await _supabase
          .from('rfid_cards')
          .select('''
          id, card_number, organization_member_id,
          organization_members!inner(
            id, organization_id, user_id, department_id,
            user_profiles (display_name, first_name, last_name, profile_photo_url),
            departments!organization_members_department_id_fkey (id, name)
          )
        ''')
          .eq('card_number', record.cardNumber)
          .eq('is_active', true)
          .maybeSingle();

      if (cardData == null) {
        debugPrint(
          '🗑️ Card ${record.cardNumber} not found in server, deleting offline record ${record.id}',
        );
        await _offlineDb.deleteAttendance(record.id!);
        throw Exception('RFID card not found: ${record.cardNumber}');
      }

      memberId = cardData['organization_member_id'] as int;

      // Update cache with latest member data
      await _offlineDb.cacheMemberData(cardData);

      // Update the record with latest member info
      final memberInfo =
          cardData['organization_members'] as Map<String, dynamic>?;
      if (memberInfo != null) {
        final profile = memberInfo['user_profiles'] as Map<String, dynamic>?;
        if (profile != null) {
          final displayName = profile['display_name'] as String?;
          final firstName = profile['first_name'] as String?;
          final lastName = profile['last_name'] as String?;
          updatedName = (displayName?.isNotEmpty == true)
              ? displayName
              : '$firstName $lastName'.trim();

          if (updatedName != null && updatedName.isNotEmpty) {
            await _offlineDb.updateAttendanceUserName(record.id!, updatedName);
          }
        }
      }
    }
    // For Face Recognition: Use stored member ID (or derive from FACE_{id}) and update member data
    else if (record.method == 'FACERECOGNITION' ||
        record.method == 'face_recognition') {
      if (record.organizationMemberId != null) {
        memberId = record.organizationMemberId!;
      } else {
        memberId = _extractMemberIdFromFaceCard(record.cardNumber);
      }

      debugPrint(
        '🔄 Syncing face recognition attendance for member ID: $memberId',
      );

      // Fetch latest member data and update cache
      try {
        final memberData = await _supabase
            .from('organization_members')
            .select('''
            id, organization_id, user_id, department_id,
            user_profiles (display_name, first_name, last_name, profile_photo_url),
            departments!organization_members_department_id_fkey (id, name)
          ''')
            .eq('id', memberId)
            .eq('is_active', true)
            .maybeSingle();

        if (memberData == null) {
          throw Exception(
            'Organization member not found or inactive: $memberId',
          );
        }

        debugPrint('✅ Found member data for ID: $memberId');

        // Create card-like structure for caching (skip if card_number is null to avoid cache errors)
        try {
          final cardData = {
            'id': 'face_recognition_$memberId',
            'card_number': record.cardNumber, // Use the FACE_$memberId format
            'organization_member_id': memberId,
            'organization_members': memberData,
          };

          await _offlineDb.cacheMemberData(cardData);
          debugPrint('✅ Cached member data for face recognition');
        } catch (cacheError) {
          debugPrint(
            '⚠️ Failed to cache member data (non-critical): $cacheError',
          );
          // Continue even if cache fails
        }

        // Update the record with latest member info
        final profile = memberData['user_profiles'] as Map<String, dynamic>?;
        if (profile != null) {
          final displayName = profile['display_name'] as String?;
          final firstName = profile['first_name'] as String?;
          final lastName = profile['last_name'] as String?;
          updatedName = (displayName?.isNotEmpty == true)
              ? displayName
              : '$firstName $lastName'.trim();

          if (updatedName != null && updatedName.isNotEmpty) {
            await _offlineDb.updateAttendanceUserName(record.id!, updatedName);
            debugPrint('✅ Updated attendance user name: $updatedName');
          }
        } else {
          debugPrint('⚠️ No user profile found for member ID: $memberId');
        }
      } catch (e) {
        debugPrint('❌ Error fetching member data for face recognition: $e');
        rethrow;
      }
    } else if (record.method == 'manual' || record.method == 'fingerprint') {
      memberId = record.organizationMemberId!;
      debugPrint(
        '🔄 Syncing ${record.method} attendance for member ID: $memberId',
      );

      // Update cache
      try {
        final memberData = await _supabase
            .from('organization_members')
            .select('''
            id, organization_id, user_id, department_id,
            user_profiles (display_name, first_name, last_name, profile_photo_url),
            departments!organization_members_department_id_fkey (id, name)
          ''')
            .eq('id', memberId)
            .eq('is_active', true)
            .maybeSingle();

        if (memberData != null) {
          final cardData = {
            'id': '${record.method}_$memberId',
            'card_number': record.cardNumber,
            'organization_member_id': memberId,
            'organization_members': memberData,
          };
          await _offlineDb.cacheMemberData(cardData);

          // Update local name if needed
          final profile = memberData['user_profiles'] as Map<String, dynamic>?;
          if (profile != null) {
            final displayName = profile['display_name'] as String?;
            final firstName = profile['first_name'] as String?;
            final lastName = profile['last_name'] as String?;
            updatedName = (displayName?.isNotEmpty == true)
                ? displayName
                : '$firstName $lastName'.trim();
            if (updatedName != null && updatedName.isNotEmpty) {
              await _offlineDb.updateAttendanceUserName(
                record.id!,
                updatedName,
              );
            }
          }
        }
      } catch (e) {
        debugPrint('⚠️ Non-critical error fetching member data: $e');
      }
    } else {
      throw Exception(
        'Cannot determine organization member ID. Method: ${record.method}, CardNumber: ${record.cardNumber}',
      );
    }

    // Upload photo if exists (use saved file or base64 fallback)
    String photoUrl = '';
    File? tempPhotoFile;
    try {
      File? photoFile;
      if (record.photoPath != null && record.photoPath!.isNotEmpty) {
        final file = File(record.photoPath!);
        if (await file.exists()) {
          photoFile = file;
        }
      }

      // Fallback to captured base64 if no file available
      if (photoFile == null && record.capturedPhotoBase64?.isNotEmpty == true) {
        final bytes = base64Decode(record.capturedPhotoBase64!);
        final tempPath =
            '${Directory.systemTemp.path}/offline_face_${record.id ?? DateTime.now().millisecondsSinceEpoch}.jpg';
        tempPhotoFile = File(tempPath);
        await tempPhotoFile.writeAsBytes(bytes, flush: true);
        photoFile = tempPhotoFile;
        debugPrint(
          '🗂️ Recreated photo from base64 for member $memberId at $tempPath',
        );
      }

      if (photoFile != null) {
        try {
          debugPrint('📸 Uploading photo for member $memberId...');
          photoUrl = await _storageService.uploadAttendancePhoto(
            photoFile,
            memberId,
            record.eventType,
          );
          debugPrint('✅ Photo uploaded successfully: $photoUrl');
        } catch (e) {
          debugPrint(
            '⚠️ Failed to upload photo (continuing without photo): $e',
          );
        }
      } else {
        debugPrint('ℹ️ No photo available for member $memberId');
      }
    } finally {
      // Clean up temporary file created from base64
      if (tempPhotoFile != null) {
        try {
          await tempPhotoFile.delete();
        } catch (_) {}
      }
    }

    // Prepare location data
    Map<String, dynamic>? locationData;
    if (record.latitude != null && record.longitude != null) {
      locationData = {
        'latitude': record.latitude,
        'longitude': record.longitude,
      };
    }

    // Prepare raw data with parsing logic for multi-shift
    Map<String, dynamic> rawData = {
      'synced_from_offline': true,
      'offline_timestamp': record.timestamp,
      'work_time_mode': record.workTimeMode,
      'notes': record.notes, // Include notes if available
    };

    // Try to parse encoded shift details
    if (record.workTimeMode != null &&
        record.workTimeMode!.trim().startsWith('{')) {
      try {
        final parsed = jsonDecode(record.workTimeMode!) as Map<String, dynamic>;
        rawData['shift_details'] = parsed;
        if (parsed.containsKey('mode_code')) {
          rawData['work_time_mode'] = parsed['mode_code'];
        }
      } catch (e) {
        debugPrint('⚠️ Failed to parse workTimeMode JSON: $e');
      }
    }

    if (record.method == 'rfid_card_mobile') {
      rawData['card_number'] = record.cardNumber;
    }
    if (record.method == 'FACERECOGNITION' ||
        record.method == 'face_recognition') {
      rawData['face_recognition'] = true;
    }
    if (record.method == 'fingerprint') {
      rawData['verification_type'] = 'fingerprint';
    }

    // Sync to Supabase
    debugPrint(
      '🔄 Syncing ${record.eventType} to Supabase for member $memberId...',
    );
    try {
      if (record.eventType == 'check_in') {
        await _attendanceService.checkIn(
          organizationMemberId: memberId,
          photoUrl: photoUrl,
          method: record.method,
          location: locationData,
          rawData: rawData,
        );
        debugPrint('✅ Successfully synced check_in for member $memberId');
      } else if (record.eventType == 'check_out') {
        await _attendanceService.checkOut(
          organizationMemberId: memberId,
          photoUrl: photoUrl,
          method: record.method,
          location: locationData,
          rawData: rawData,
        );
        debugPrint('✅ Successfully synced check_out for member $memberId');
      } else if (record.eventType == 'break_out' ||
          record.eventType == 'break_start') {
        await _attendanceService.breakOut(
          organizationMemberId: memberId,
          photoUrl: photoUrl,
          method: record.method,
          location: locationData,
          rawData: rawData,
        );
        debugPrint(
          '✅ Successfully synced ${record.eventType} (break_start) for member $memberId',
        );
      } else if (record.eventType == 'break_in' ||
          record.eventType == 'break_end') {
        await _attendanceService.breakIn(
          organizationMemberId: memberId,
          photoUrl: photoUrl,
          method: record.method,
          location: locationData,
          rawData: rawData,
        );
        debugPrint(
          '✅ Successfully synced ${record.eventType} (break_end) for member $memberId',
        );
      }
    } catch (e) {
      debugPrint('❌ Error syncing attendance to Supabase: $e');
      rethrow;
    }

    return updatedName;
  }

  // Add method for manual sync all
  Future<SyncResult> syncAllPendingAttendances() async {
    return await syncPendingAttendances(showProgress: true);
  }

  // Clean up duplicate records that are already marked as synced
  Future<int> cleanupDuplicateRecords() async {
    try {
      debugPrint('🧹 Cleaning up duplicate records...');
      final deletedCount = await _offlineDb.deleteDuplicateRecords();
      debugPrint('✅ Cleaned up $deletedCount duplicate records');
      return deletedCount;
    } catch (e) {
      debugPrint('❌ Error cleaning up duplicate records: $e');
      return 0;
    }
  }

  // Get sync statistics
  Future<Map<String, int>> getSyncStats() async {
    final unsyncedCount = await _offlineDb.getUnsyncedCount();
    final allRecords = await _offlineDb.getAllAttendances();
    final syncedCount = allRecords.where((r) => r.isSynced).length;
    final failedCount = allRecords
        .where((r) => !r.isSynced && r.syncError != null)
        .length;

    return {
      'total': allRecords.length,
      'synced': syncedCount,
      'pending': unsyncedCount,
      'failed': failedCount,
    };
  }

  void dispose() {
    stopAutoSync();
    _syncStatusController.close();
  }

  int _extractMemberIdFromFaceCard(String cardNumber) {
    try {
      if (cardNumber.startsWith('FACE_')) {
        final idPart = cardNumber.replaceFirst('FACE_', '');
        return int.parse(idPart);
      }
    } catch (_) {
      // fallthrough
    }
    throw Exception('Invalid face card number: $cardNumber');
  }
}

// Sync status model
class SyncStatus {
  final bool isLoading;
  final String message;
  final bool isError;
  final int? progress;
  final int? total;
  final List<OfflineAttendance>? records;

  SyncStatus({
    required this.isLoading,
    required this.message,
    this.isError = false,
    this.progress,
    this.total,
    this.records,
  });
}

// Sync result model
class SyncResult {
  final bool success;
  final String message;
  final int syncedCount;
  final int failedCount;
  final List<String>? errors;

  SyncResult({
    required this.success,
    required this.message,
    required this.syncedCount,
    required this.failedCount,
    this.errors,
  });
}
