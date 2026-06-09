// BiometricService handles both face recognition and fingerprint templates in Supabase.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/biometric_data.dart';
import 'face_recognition_tflite_service.dart';
import '../../services/offline_database_service.dart';
import '../../helpers/timezone_helper.dart';
import '../../main.dart'; // ✅ To access global objectBox
import '../../models/biometric_entity.dart';
import '../../objectbox.g.dart';

class BiometricService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  
  // ✅ ObjectBox shortcut
  final Box<BiometricEntity> _box = objectBox.biometricBox;

  static const double defaultThreshold =
      0.3; // ✅ Aligned with Wajah project (was 0.65)
  // ✅ PERFORMANCE: Static instances to persist across multiple BiometricService creations
  // This prevents reloading the heavy TFLite model and Isolate on every match
  static FaceRecognitionTFLiteService? _persistentFaceService;

  // ✅ NEW: Expose shared service to prevent multiple model loads in memory
  Future<FaceRecognitionTFLiteService> getFaceService() async {
    if (_persistentFaceService == null) {
      // debugPrint('🚀 Initializing shared persistent face service...');
      _persistentFaceService = FaceRecognitionTFLiteService();
      await _persistentFaceService!.initialize();
    }
    return _persistentFaceService!;
  }

  static List<Map<String, dynamic>>? _memoryTemplateCache;
  static Map<int, Map<String, dynamic>>? _parsedTemplateCache;
  static int? _cachedOrganizationId;
  static DateTime? _cacheTimestamp;
  static const Duration _cacheExpiry = Duration(minutes: 30);

  // ✅ LOGGER Helper
  static void _logMatch(
    String? name,
    double similarity,
    double threshold,
    bool accepted,
  ) {
    final emoji = accepted ? '✅' : '❌';
    debugPrint(
      '$emoji MATCH: ${name ?? "Unknown"} (${(similarity * 100).toStringAsFixed(1)}% vs ${(threshold * 100).toInt()}%)',
    );
  }

  /// ✅ NEW: Safely get template from cache for evolution
  Map<String, dynamic>? getParsedTemplateFromCache(int biometricId) {
    return _parsedTemplateCache?[biometricId];
  }

  Future<BiometricData> registerFaceTemplate({
    required int organizationMemberId,
    required Map<String, dynamic> faceTemplate,
  }) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      final templateJson = jsonEncode(faceTemplate);

      // Version is stored INSIDE the JSON, not as separate column
      final version = faceTemplate['version'] ?? 3;
      /*
      // \u2705 NEW: Log ISO compliance features for version 3.1
      if (version == 3.1) {
        debugPrint('\u2705 ISO/IEC Compliant Template:');
        debugPrint('  - Biometric Metrics: ${faceTemplate['biometricMetrics'] != null}');
        debugPrint('  - Quality Metrics: ${faceTemplate['qualityMetrics'] != null}');
        debugPrint('  - Liveness Detection: ${faceTemplate['livenessDetection'] != null}');
        debugPrint('  - Pose Information: ${faceTemplate['poseInformation'] != null}');
      }
      */

      /*
      // Check if this is multi-template (version 4)
      final isMultiTemplate = version == 4;
      if (isMultiTemplate) {
        final templates = faceTemplate['templates'] as List?;
        debugPrint('Multi-template registration: ${templates?.length ?? 0} templates');
      }
      */

      // Deactivate old templates (both 'face' and 'face_recognition')
      final existingTemplates = await _supabase
          .from('biometric_data')
          .select('id')
          .eq('organization_member_id', organizationMemberId)
          .filter('biometric_type', 'in', ['face', 'face_recognition'])
          .eq('is_active', true);

      if (existingTemplates != null && (existingTemplates as List).isNotEmpty) {
        for (var t in existingTemplates) {
          await _supabase
              .from('biometric_data')
              .update({'is_active': false})
              .eq('id', t['id']);
        }
      }

      // Insert new template (NO template_version column)
      final biometricData = {
        'organization_member_id': organizationMemberId,
        'biometric_type': 'face_recognition',
        'template_data': templateJson, // Version is inside this JSON
        'enrollment_date': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        'is_active': true,
        // ❌ REMOVED: 'template_version': version,
      };

      final result = await _supabase
          .from('biometric_data')
          .insert(biometricData)
          .select()
          .single();

      // debugPrint('✅ Face template registered with version $version');

      // ✅ Cache Invalidation: Clear cache so next identification fetches new data
      _memoryTemplateCache = null;
      _parsedTemplateCache = null;

      return BiometricData.fromJson(result);
    } catch (e) {
      throw Exception('Failed to register face template: $e');
    }
  }

  Future<BiometricData?> getActiveFaceTemplate(int organizationMemberId) async {
    try {
      final result = await _supabase
          .from('biometric_data')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .maybeSingle();

      if (result == null) return null;

      return BiometricData.fromJson(result);
    } catch (e) {
      debugPrint('Error getting face template: $e');
      return null;
    }
  }

  // === FINGERPRINT METHODS ===

  Future<BiometricData> registerFingerprintTemplate({
    required int organizationMemberId,
    required String templateBase64,
  }) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      // Deactivate old fingerprint templates
      final existingTemplate = await _supabase
          .from('biometric_data')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'fingerprint')
          .eq('is_active', true)
          .maybeSingle();

      if (existingTemplate != null) {
        await _supabase
            .from('biometric_data')
            .update({'is_active': false})
            .eq('id', existingTemplate['id']);
      }

      // Insert new template
      final biometricData = {
        'organization_member_id': organizationMemberId,
        'biometric_type': 'fingerprint',
        'template_data': templateBase64,
        'enrollment_date': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        'is_active': true,
      };

      final result = await _supabase
          .from('biometric_data')
          .insert(biometricData)
          .select()
          .single();

      return BiometricData.fromJson(result);
    } catch (e) {
      throw Exception('Failed to register fingerprint template: $e');
    }
  }

  Future<BiometricData?> getActiveFingerprintTemplate(
    int organizationMemberId,
  ) async {
    try {
      final result = await _supabase
          .from('biometric_data')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'fingerprint')
          .eq('is_active', true)
          .maybeSingle();

      if (result == null) return null;

      return BiometricData.fromJson(result);
    } catch (e) {
      debugPrint('Error getting fingerprint template: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAllActiveFingerprintTemplates(
    int organizationId,
  ) async {
    // Step 1: Try to load from local SQLite cache first (instant, works offline)
    List<Map<String, dynamic>> cachedTemplates = [];
    try {
      cachedTemplates = await _offlineDb.getAllBiometricDataWithUserInfo(
        organizationId: organizationId,
        biometricType: 'fingerprint',
      );
      if (cachedTemplates.isNotEmpty) {
        debugPrint(
          '📦 Loaded ${cachedTemplates.length} fingerprint templates from SQLite cache',
        );
      }
    } catch (e) {
      debugPrint('⚠️ Failed to read SQLite cache: $e');
    }

    // Step 2: Background sync from Supabase to keep cache fresh
    _syncFingerprintsFromSupabase(organizationId);

    // Step 3: Return cached data immediately if available
    if (cachedTemplates.isNotEmpty) {
      return cachedTemplates;
    }

    // Step 4: If cache is empty (first run), wait for the Supabase fetch
    debugPrint('📴 SQLite cache empty, waiting for Supabase fetch...');
    try {
      final results = await _fetchFingerprintsFromSupabase(organizationId);
      return results;
    } catch (e) {
      debugPrint('❌ Supabase fetch also failed: $e');
      return [];
    }
  }

  /// Fetch fingerprints from Supabase and sync to SQLite
  Future<List<Map<String, dynamic>>> _fetchFingerprintsFromSupabase(
    int organizationId,
  ) async {
    final results = await _supabase
        .from('biometric_data')
        .select('''
          id,
          organization_member_id,
          template_data,
          organization_members!inner (
            id,
            user_id,
            organization_id,
            employee_id,
            department_id,
            user_profiles!inner (
              id,
              first_name,
              last_name,
              display_name,
              profile_photo_url
            ),
            departments!organization_members_department_id_fkey (
              id,
              name
            )
          )
        ''')
        .eq('biometric_type', 'fingerprint')
        .eq('is_active', true)
        .eq('organization_members.organization_id', organizationId);

    return List<Map<String, dynamic>>.from(results);
  }

  /// Background sync: fetch from Supabase and update SQLite (handles deletions)
  void _syncFingerprintsFromSupabase(int organizationId) {
    Future(() async {
      try {
        debugPrint('🔄 Background fingerprint sync for org $organizationId...');
        final templates = await _fetchFingerprintsFromSupabase(organizationId);

        // Full replace: removes deleted entries from SQLite too
        await _offlineDb.syncBiometricData(
          templates,
          biometricType: 'fingerprint',
          organizationId: organizationId,
        );

        // Cache member info for name/photo display
        for (var template in templates) {
          unawaited(
            _offlineDb.cacheMemberData({
              'organization_member_id': template['organization_member_id'],
              'card_number': 'FINGER_${template['organization_member_id']}',
              'organization_members': template['organization_members'],
            }),
          );
        }

        debugPrint(
          '✅ Background fingerprint sync done: ${templates.length} templates cached',
        );
      } catch (e) {
        debugPrint('⚠️ Background sync skipped (offline?): $e');
      }
    });
  }

  Future<bool> hasRegisteredFingerprint(int organizationMemberId) async {
    try {
      final result = await _supabase
          .from('biometric_data')
          .select('id')
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'fingerprint')
          .eq('is_active', true)
          .maybeSingle();

      return result != null;
    } catch (e) {
      debugPrint('!!! Supabase FINGER Error (ID $organizationMemberId): $e');
      return false;
    }
  }

  Future<void> deactivateFingerprintTemplate(int biometricId) async {
    try {
      await _supabase
          .from('biometric_data')
          .update({'is_active': false})
          .eq('id', biometricId);
    } catch (e) {
      throw Exception('Failed to deactivate fingerprint template: $e');
    }
  }

  // === FACE RECOGNITION METHODS ===

  Future<List<Map<String, dynamic>>> getAllActiveFaceTemplatesWithUserInfo(
    int organizationId,
  ) async {
    try {
      // 1. Check ObjectBox first (Lightning fast local cache)
      final query = _box.query(
        BiometricEntity_.organizationId.equals(organizationId)
        .and(BiometricEntity_.isActive.equals(true))
        .and(BiometricEntity_.biometricType.equals('face_recognition'))
      ).build();
      
      final localData = query.find();
      
      if (localData.isNotEmpty && (_cacheTimestamp != null && DateTime.now().difference(_cacheTimestamp!) < _cacheExpiry)) {
        // debugPrint('🚀 ObjectBox: Loaded ${localData.length} templates instantly');
        return localData.map((e) => {
          'id': e.supabaseId,
          'organization_member_id': e.organizationMemberId,
          'template_data': e.templateData,
          'embedding': e.embedding, 
          'organization_members': {
            'organization_id': e.organizationId,
            'user_profiles': {
              'display_name': e.userName,
              'profile_photo_url': e.profilePhotoUrl,
            }
          }
        }).toList();
      }

      // 2. Refresh from Supabase if cache is empty or expired
      final results = await _supabase
          .from('biometric_data')
          .select('''
            id, organization_member_id, template_data, enrollment_date,
            organization_members!inner (
              organization_id,
              user_profiles!inner (di  splay_name, first_name, profile_photo_url)
            )
          ''')
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .eq('organization_members.organization_id', organizationId);

      // 3. Sync to ObjectBox for future use
      final List<BiometricEntity> entities = [];
      for (var item in results) {
        final orgMember = item['organization_members'];
        final userProfile = orgMember['user_profiles'];
        final templateStr = item['template_data'] as String;
        
        List<double>? embedding;
        try {
          final decoded = jsonDecode(templateStr);
          if (decoded['embedding'] != null) {
            embedding = (decoded['embedding'] as List).map((v) => (v as num).toDouble()).toList();
          }
        } catch (e) {}

        entities.add(BiometricEntity(
          supabaseId: item['id'],
          organizationMemberId: item['organization_member_id'],
          organizationId: organizationId,
          biometricType: 'face_recognition',
          embedding: embedding,
          templateData: templateStr,
          enrollmentDate: DateTime.parse(item['enrollment_date'] ?? DateTime.now().toIso8601String()),
          userName: userProfile['display_name'] ?? userProfile['first_name'],
          profilePhotoUrl: userProfile['profile_photo_url'],
        ));
      }
      
      if (entities.isNotEmpty) {
        _box.putMany(entities);
        _cacheTimestamp = DateTime.now();
      }

      return List<Map<String, dynamic>>.from(results);
    } catch (e) {
      debugPrint('Error in ObjectBox/Supabase sync: $e');
      return [];
    }
  }

  // ✅ NEW: Manual cache refresh
  Future<void> refreshCache(int organizationId) async {
    _memoryTemplateCache = null;
    _parsedTemplateCache = null;
    _cacheTimestamp = null;
    await getAllActiveFaceTemplatesWithUserInfo(organizationId);
  }

  Future<Map<String, dynamic>?> identifyBestMatchWithUserInfo({
    required Map<String, dynamic> capturedTemplate,
    required int organizationId,
    required double threshold,
    bool strict = false,
  }) async {
    try {
      final startTime = DateTime.now();
      // debugPrint('=== IDENTIFYING BEST MATCH (OPTIMIZED) ===');

      // 1. Initialize Service ONCE
      final faceService = await getFaceService();

      // 2. Load and Cache Templates ONCE (per session/org)
      if (_memoryTemplateCache == null ||
          _cachedOrganizationId != organizationId) {
        _memoryTemplateCache = await getAllActiveFaceTemplatesWithUserInfo(
          organizationId,
        );
        _cachedOrganizationId = organizationId;

        // Pre-parse JSON to avoid decoding in the loop
        _parsedTemplateCache = {};
        for (var template in _memoryTemplateCache!) {
          try {
            _parsedTemplateCache![template['id']] = jsonDecode(
              template['template_data'],
            );
          } catch (e) {
            debugPrint('⚠️ Error parsing template ${template['id']}: $e');
          }
        }
      }

      final capturedVersion =
          (capturedTemplate['version'] as num?)?.toInt() ?? 3;
      final capturedQuality =
          (capturedTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;

      // ✅ CRITICAL: Raw Cosine Threshold (Ideal ~0.45)
      // ✅ PROFESSIONAL SECURITY TUNING
      // Raise standard threshold to 0.60 to prevent False Positives.
      double effectiveThreshold = 0.60; 

      // ✅ Phase 4: Dynamic Thresholding
      if (capturedQuality < 0.50) {
        if (capturedQuality < 0.35) {
          debugPrint('❌ Match rejected: extremely low quality');
          return null;
        }
        // For lower quality but still visible, we stay strict
        effectiveThreshold = 0.62; 
      }

      if (_memoryTemplateCache!.isEmpty) {
        debugPrint('No registered faces found in cache');
        return null;
      }

      Map<String, dynamic>? bestMatch;
      double highestSimilarity = -1.0; // Init to -1.0 for cosine
      double secondHighestSimilarity = -1.0;
      String? secondBestName;
      int? bestMemberId;

      // 3. Fast Comparison Loop
      for (var template in _memoryTemplateCache!) {
        final registeredTemplate = _parsedTemplateCache![template['id']];
        if (registeredTemplate == null) continue;
        
        final currentMemberId = template['organization_member_id'] as int?;

        // --- Version Check ---
        final templateVersion =
            (registeredTemplate['version'] as num?)?.toInt() ?? 2;
        bool isW600K(int v) => v >= 4; // v4+ are W600K
        if (isW600K(capturedVersion) != isW600K(templateVersion)) continue;

        double similarity = -1.0;
        int bestTemplateIdx = -1;

        // ✅ MAX SCORE STRATEGY (Multi-Template)
        if (templateVersion == 4 && registeredTemplate['templates'] != null) {
          final templates = registeredTemplate['templates'] as List;
          double maxSimilarity = -1.0;
          for (int i = 0; i < templates.length; i++) {
            final storedTemplate = templates[i];
            final templateSim = faceService.compareFaces(
              capturedTemplate,
              storedTemplate,
            );
            if (templateSim > maxSimilarity) {
              maxSimilarity = templateSim;
              bestTemplateIdx = i;
            }
          }
          similarity = maxSimilarity; // Take the BEST match, not average
        } else if (capturedVersion == 4 &&
            capturedTemplate['templates'] != null) {
          // Reverse case (Multi-capture vs Single DB) - Rare but same logic
          final capturedTemplates = capturedTemplate['templates'] as List;
          double maxSimilarity = -1.0;
          for (int i = 0; i < capturedTemplates.length; i++) {
            final capTemplate = capturedTemplates[i];
            final templateSim = faceService.compareFaces(
              capTemplate,
              registeredTemplate,
            );
            if (templateSim > maxSimilarity) maxSimilarity = templateSim;
          }
          similarity = maxSimilarity;
        } else {
          similarity = faceService.compareFaces(
            capturedTemplate,
            registeredTemplate,
          );
        }

        // Track Top 2 Candidates (DIFFERENT members only)
        if (similarity > highestSimilarity) {
          if (currentMemberId != bestMemberId) {
            secondHighestSimilarity = highestSimilarity;
            secondBestName = bestMatch?['user_name'];
          }
          
          highestSimilarity = similarity;
          bestMemberId = currentMemberId;

          if (similarity >= effectiveThreshold) {
            final orgMember = template['organization_members'];
            final userProfile = orgMember['user_profiles'];
            final dept = orgMember['departments'] is List
                ? (orgMember['departments'].isNotEmpty
                      ? orgMember['departments'].first
                      : null)
                : orgMember['departments'];

            String? combinedDept = dept?['name'];

            final angles = ['Front', 'Left', 'Right', 'Up', 'Down'];
            final matchedAngle =
                bestTemplateIdx != -1 && bestTemplateIdx < angles.length
                ? angles[bestTemplateIdx]
                : (bestTemplateIdx != -1 ? 'Angle $bestTemplateIdx' : 'Single');

            bestMatch = {
              'organization_member_id': template['organization_member_id'],
              'biometric_id': template['id'],
              'similarity': similarity,
              'organization_id': orgMember['organization_id'],
              'user_id': orgMember['user_id'],
              'employee_id': orgMember['employee_id'],
              'user_name':
                  (userProfile['display_name'] ?? '').toString().isEmpty
                  ? '${userProfile['first_name']} ${userProfile['last_name']}'
                  : userProfile['display_name'],
              'first_name': userProfile['first_name'],
              'last_name': userProfile['last_name'],
              'profile_photo_url': userProfile['profile_photo_url'],
              'department_name': combinedDept,
              'template_version': templateVersion,
              'threshold': effectiveThreshold,
              'matched_angle': matchedAngle,
              'second_similarity': secondHighestSimilarity,
            };
          }
        } else if (similarity > secondHighestSimilarity) {
          if (currentMemberId != bestMemberId) {
            secondHighestSimilarity = similarity;
            final orgMember = template['organization_members'];
            final userProfile = orgMember['user_profiles'];
            secondBestName = userProfile['display_name'] ?? '${userProfile['first_name']}';
          }
        }
      }

      // 4. Final Verification
      if (bestMatch != null) {
        _logMatch(
          bestMatch['user_name'],
          highestSimilarity,
          effectiveThreshold,
          true,
        );

        if (highestSimilarity < effectiveThreshold) {
          debugPrint('❌ Rejected: Below threshold');
          return null;
        }

        // ✅ RE-ENABLED AMBIGUITY CHECK: Prevent multiple people matching similar features
        if (secondHighestSimilarity > -1.0) {
          final similarityGap = highestSimilarity - secondHighestSimilarity;
          
          // PROFESSIONAL GAP: Skor harus minimal 10% lebih tinggi dari orang kedua
          double requiredGap = 0.10; 
          
          if (similarityGap < requiredGap) {
             debugPrint('⚠️ SECURITY ALERT: Ambiguous match detected!');
             debugPrint('1st: $highestSimilarity (${bestMatch['user_name']})');
             debugPrint('2nd: $secondHighestSimilarity ($secondBestName)');
             debugPrint('Gap: $similarityGap < $requiredGap. REJECTED for safety.');
             return null;
          }
        }
      } else {
        debugPrint('❌ No match found.');
      }

      return bestMatch;
    } catch (e) {
      debugPrint('!!! ERROR in identifyBestMatchWithUserInfo: $e');
      return null;
    }
  }

  Future<void> updateLastUsed(int biometricId) async {
    try {
      await _supabase
          .from('biometric_data')
          .update({
            'last_used_at': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
          })
          .eq('id', biometricId);

      // debugPrint('✅ Updated last_used_at for biometric_id: $biometricId');
    } catch (e) {
      debugPrint('Failed to update last used: $e');
    }
  }

  Future<void> deactivateFaceTemplate(int biometricId) async {
    try {
      await _supabase
          .from('biometric_data')
          .update({'is_active': false})
          .eq('id', biometricId);

      // debugPrint('✅ Deactivated biometric template: $biometricId');
    } catch (e) {
      throw Exception('Failed to deactivate face template: $e');
    }
  }

  /// ✅ NEW: Adaptive Learning (Template Evolution)
  /// Merges new high-confidence embedding into the existing profile.
  Future<void> evolveTemplate({
    required int biometricId,
    required Map<String, dynamic> currentTemplate,
    required Map<String, dynamic> capturedTemplate,
    double learningRate = 0.1, // 10% new data, 90% old data
  }) async {
    try {
      final currentEmbedding = List<double>.from(
        currentTemplate['embedding'] ?? [],
      );
      final newEmbedding = List<double>.from(
        capturedTemplate['embedding'] ?? [],
      );

      if (currentEmbedding.isEmpty || newEmbedding.isEmpty) return;
      if (currentEmbedding.length != newEmbedding.length) return;

      // debugPrint('🧬 Evolving template $biometricId (LR: $learningRate)...');

      // 1. Weighted Average Evolution
      final nextEmbedding = List<double>.filled(currentEmbedding.length, 0.0);
      for (int i = 0; i < currentEmbedding.length; i++) {
        nextEmbedding[i] =
            (currentEmbedding[i] * (1.0 - learningRate)) +
            (newEmbedding[i] * learningRate);
      }

      // 2. Normalize unit vector (Very Important for Cosine Similarity)
      double sumSquares = 0.0;
      for (var value in nextEmbedding) {
        sumSquares += value * value;
      }
      final magnitude = math.sqrt(sumSquares);
      final normalizedEmbedding = magnitude < 1e-6
          ? nextEmbedding
          : nextEmbedding.map((v) => v / magnitude).toList();

      // 3. Prepare updated JSON data
      final updatedTemplate = Map<String, dynamic>.from(currentTemplate);
      updatedTemplate['embedding'] = normalizedEmbedding;
      updatedTemplate['evolution_count'] =
          (updatedTemplate['evolution_count'] ?? 0) + 1;
      updatedTemplate['last_evolved_at'] = DateTime.now().toIso8601String();

      final jsonString = jsonEncode(updatedTemplate);

      // 4. Update Database (Supabase) - Fire and forget for speed
      _supabase
          .from('biometric_data')
          .update({
            'template_data': jsonString,
            'last_used_at': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
          })
          .eq('id', biometricId)
          .then((_) {
            // debugPrint('✅ Supabase template evolved successfully');
          })
          .catchError((e) {
            debugPrint('⚠️ Supabase evolution update failed: $e');
          });

      // 5. Update Local Cache (Fire and forget)
      _offlineDb
          .updateBiometricTemplate(
            biometricId: biometricId,
            templateData: jsonString,
          )
          .then((_) {
            // debugPrint('✅ Local cache template evolved successfully');
            // Update in-memory cache too
            _parsedTemplateCache?[biometricId] = updatedTemplate;
          });
    } catch (e) {
      debugPrint('⚠️ Failed to evolve template: $e');
    }
  }

  Future<bool> hasRegisteredFace(int organizationMemberId) async {
    try {
      final result = await _supabase
          .from('biometric_data')
          .select('id')
          .eq('organization_member_id', organizationMemberId)
          .filter('biometric_type', 'in', ['face', 'face_recognition'])
          .eq('is_active', true)
          .maybeSingle();

      return result != null;
    } catch (e) {
      debugPrint('!!! Supabase FACE Error (ID $organizationMemberId): $e');
      return false;
    }
  }

  Future<Map<String, int>> getOrganizationStats(int organizationId) async {
    try {
      // debugPrint('=== FETCHING ORGANIZATION STATS ===');

      final registeredData = await _supabase
          .from('biometric_data')
          .select('''
            id,
            template_data,
            organization_members!inner(
              organization_id
            )
          ''')
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .eq('organization_members.organization_id', organizationId);

      final registeredCount = registeredData.length;

      // Count by version (read from JSON)
      final versionCounts = <int, int>{};
      for (final record in registeredData) {
        try {
          final templateData = jsonDecode(record['template_data']);
          final version = (templateData['version'] as num?)?.toInt() ?? 2;
          versionCounts[version] = (versionCounts[version] ?? 0) + 1;
        } catch (e) {
          debugPrint('Error parsing template: $e');
        }
      }

      final totalMembersData = await _supabase
          .from('organization_members')
          .select('id')
          .eq('organization_id', organizationId)
          .eq('is_active', true);

      final totalMembers = totalMembersData.length;

      /*
      debugPrint('Registered faces: $registeredCount');
      debugPrint('Version breakdown: $versionCounts');
      debugPrint('Total members: $totalMembers');
      */

      return {
        'registered_faces': registeredCount,
        'total_members': totalMembers,
        'pending_registration': totalMembers - registeredCount,
        'w600k_templates':
            (versionCounts[4] ?? 0) +
            (versionCounts[5] ?? 0) +
            (versionCounts[6] ?? 0) +
            (versionCounts[7] ?? 0) +
            (versionCounts[8] ?? 0),
        'tflite_templates': versionCounts[3] ?? 0,
        'mlkit_templates': versionCounts[2] ?? 0,
      };
    } catch (e) {
      debugPrint('Error getting organization stats: $e');
      return {
        'registered_faces': 0,
        'total_members': 0,
        'pending_registration': 0,
      };
    }
  }

  /// Migrate old templates by marking them as inactive
  Future<int> migrateToTFLite(int organizationId) async {
    try {
      // debugPrint('=== CHECKING OLD TEMPLATES ===');

      final allData = await _supabase
          .from('biometric_data')
          .select('''
            id,
            organization_member_id,
            template_data,
            organization_members!inner(
              organization_id
            )
          ''')
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .eq('organization_members.organization_id', organizationId);

      int oldCount = 0;
      for (final record in allData) {
        try {
          final templateData = jsonDecode(record['template_data']);
          final version = (templateData['version'] as num?)?.toInt() ?? 2;
          // v4 through v8 are considered modern W600K templates
          bool isModern = version >= 4 && version <= 8;

          if (!isModern) {
            oldCount++;
            // Optionally mark as inactive
            // await _supabase.from('biometric_data')
            //   .update({'is_active': false})
            //   .eq('id', record['id']);
          }
        } catch (e) {
          debugPrint('Error parsing template: $e');
        }
      }

      // debugPrint('Found $oldCount old templates (version != 5)');
      return oldCount;
    } catch (e) {
      debugPrint('Error in migration check: $e');
      return 0;
    }
  }

  Future<bool> hasRegisteredRfid(int organizationMemberId) async {
    try {
      final result = await _supabase
          .from('rfid_cards')
          .select('id')
          .eq('organization_member_id', organizationMemberId)
          .eq('is_active', true)
          .maybeSingle();

      return result != null;
    } catch (e) {
      debugPrint('!!! Supabase RFID Error (ID $organizationMemberId): $e');
      return false;
    }
  }

  void dispose() {
    debugPrint('BiometricService disposed');
  }
}
