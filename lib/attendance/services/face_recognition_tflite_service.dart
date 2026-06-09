// lib/services/face_recognition_tflite_service.dart
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'isolate_inference_service.dart';
import '../../helpers/timezone_helper.dart';

class FaceRecognitionTFLiteService {
  late final FaceDetector _faceDetector;
  final IsolateInferenceService _inferenceService = IsolateInferenceService();
  bool _isInitialized = false;

  // W600K MBF optimized model config
  int inputSize = 160;
  int embeddingSize = 512;

  // ✅ OPTIMIZED: Realistic Quality Thresholds for Mobile Attendance
  static const double minFaceQualityScore = 0.28; // Lowered from 0.35
  static const double minEyeOpenProbability = 0.30; // Lowered from 0.40/0.50
  static const double maxHeadRotation = 25.0; // Increased from 20.0

  FaceRecognitionTFLiteService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.05,
      ),
    );
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('=== Initializing Face Recognition Service ===');
      await _inferenceService.initialize();
      debugPrint(
        '✅ Face Recognition Service initialized (matching wajah project)',
      );
      _isInitialized = true;
    } catch (e) {
      debugPrint('!!! Failed to initialize Face Recognition Service: $e');
      rethrow;
    }
  }

  Future<List<Face>> detectFaces(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    return await detectFacesFromInputImage(inputImage);
  }

  Future<List<Face>> detectFacesFromInputImage(InputImage inputImage) async {
    return await _faceDetector.processImage(inputImage);
  }

  // ✅ IMPROVED: L2 Normalization Helper
  List<double> l2Normalize(List<double> vector) {
    if (vector.isEmpty) return [];
    double sum = 0.0;
    for (var x in vector) {
      sum += x * x;
    }
    final norm = sqrt(sum);
    if (norm == 0) return vector;
    return vector.map((x) => x / norm).toList();
  }

  // ✅ CALCULATE: Face Quality Score
  double calculateFaceQuality(Face face) {
    double qualityScore = 1.0;

    // Eye openness (40% weight)
    final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
    final eyeScore = (leftEyeOpen + rightEyeOpen) / 2.0;
    qualityScore *= (0.6 + eyeScore * 0.4);

    // Head rotation (30% weight)
    final headY = (face.headEulerAngleY ?? 0.0).abs();
    final headZ = (face.headEulerAngleZ ?? 0.0).abs();
    final rotationPenalty = (headY + headZ) / 100.0;
    qualityScore *= (1.0 - rotationPenalty.clamp(0.0, 0.3));

    // Face size (30% weight)
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    final sizeScore = (faceArea / 100000.0).clamp(0.0, 1.0);
    qualityScore *= (0.7 + sizeScore * 0.3);

    return qualityScore.clamp(0.0, 1.0);
  }

  bool isValidFaceForRecognition(Face face, {bool allowSidePose = false}) {
    // 1. Check eye openness
    final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;

    // Relaxed threshold for real-world usage
    if (leftEyeOpen < minEyeOpenProbability ||
        rightEyeOpen < minEyeOpenProbability) {
      debugPrint(
        '❌ Face rejected: Eyes closed (L:${leftEyeOpen.toStringAsFixed(2)}, R:${rightEyeOpen.toStringAsFixed(2)}) < $minEyeOpenProbability',
      );
      return false;
    }

    // 2. Check head rotation
    final headY = (face.headEulerAngleY ?? 0.0).abs();
    final headZ = (face.headEulerAngleZ ?? 0.0).abs();

    if (!allowSidePose) {
      if (headY > maxHeadRotation || headZ > maxHeadRotation) {
        debugPrint(
          '❌ Face rejected: Bad Rotation (Y:${headY.toStringAsFixed(1)}, Z:${headZ.toStringAsFixed(1)}) > $maxHeadRotation',
        );
        return false;
      }
    } else {
      // Slightly more lenient for turbo/side checks if enabled
      if (headZ > maxHeadRotation * 1.5 || headY > 50.0) {
        return false;
      }
    }

    // 3. Check face size (Dynamic Area)
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    // Assuming standard preview ~ 720x1280 = 921,600. 4% = ~36,000.
    // Absolute minimum fallback 2000 for dist.
    if (faceArea < 2000) {
      debugPrint('❌ Face REJECTED: Too far/small (Area: ${faceArea.toInt()})');
      return false;
    }

    // 4. Overall Quality Score
    final quality = calculateFaceQuality(face);
    if (quality < minFaceQualityScore) {
      debugPrint(
        '❌ Face REJECTED: Low quality (${(quality * 100).toInt()}%) < ${(minFaceQualityScore * 100).toInt()}%',
      );
      return false;
    }

    return true;
  }

  // ... (extractFaceFeatures remains mostly same, just calls enhanced methods) ...

  Future<Map<String, dynamic>> extractFaceFeatures(
    String imagePath, {
    bool allowSidePose = false,
  }) async {
    final faces = await detectFaces(imagePath);
    if (faces.isEmpty) throw Exception('No face detected');
    if (faces.length > 1) throw Exception('Multiple faces detected');

    final face = faces.first;
    if (!isValidFaceForRecognition(face, allowSidePose: allowSidePose)) {
      throw Exception(
        'Face quality insufficient. Open eyes and look straight.',
      );
    }

    return buildTemplateFromFace(face, imagePath, allowSidePose: allowSidePose);
  }

  Future<Map<String, dynamic>> buildTemplateFromBytes(
    Uint8List imageBytes,
    int width,
    int height,
    int rotation,
    Face face, {
    bool allowSidePose = false,
    String? debugPath,
  }) async {
    if (!_isInitialized) await initialize();

    final landmarks = <String, dynamic>{};
    void addLandmark(FaceLandmarkType type, String key) {
      final l = face.landmarks[type];
      if (l != null) {
        landmarks[key] = {
          'x': l.position.x.toDouble(),
          'y': l.position.y.toDouble(),
        };
      }
    }

    // Add essential landmarks
    for (var t in [
      FaceLandmarkType.leftEye,
      FaceLandmarkType.rightEye,
      FaceLandmarkType.noseBase,
      FaceLandmarkType.bottomMouth,
      FaceLandmarkType.leftMouth,
      FaceLandmarkType.rightMouth,
    ]) {
      addLandmark(t, t.toString().split('.').last);
    }

    final faceData = {
      'boundingBox': {
        'left': face.boundingBox.left,
        'top': face.boundingBox.top,
        'width': face.boundingBox.width,
        'height': face.boundingBox.height,
      },
      'landmarks': landmarks,
    };

    final response = await _inferenceService.processFaceFromBytes(
      imageBytes: imageBytes,
      width: width,
      height: height,
      rotation: rotation,
      faceData: faceData,
      allowSidePose: allowSidePose,
      debugPath: debugPath,
    );

    if (response.error != null) throw Exception(response.error);
    if (response.embedding == null) {
      throw Exception('Failed to generate embedding');
    }

    // ✅ CRITICAL: L2 Normalize embedding immediately
    final normalizedEmbedding = l2Normalize(response.embedding!);

    return _buildTemplate(
      face,
      normalizedEmbedding, // Use IS L2 Normalized
      landmarks,
      "stream_capture",
    );
  }

  Future<Map<String, dynamic>> buildTemplateFromFace(
    Face face,
    String imagePath, {
    bool allowSidePose = false,
  }) async {
    if (!_isInitialized) await initialize();

    final landmarks = <String, dynamic>{};
    // ... [Same landmark extraction logic can be simplified or delegated] ...
    void addLandmark(FaceLandmarkType type, String key) {
      final l = face.landmarks[type];
      if (l != null) {
        landmarks[key] = {
          'x': l.position.x.toDouble(),
          'y': l.position.y.toDouble(),
        };
      }
    }

    addLandmark(FaceLandmarkType.leftEye, 'leftEye');
    addLandmark(FaceLandmarkType.rightEye, 'rightEye');
    addLandmark(FaceLandmarkType.noseBase, 'noseBase');
    addLandmark(FaceLandmarkType.bottomMouth, 'bottomMouth');
    addLandmark(FaceLandmarkType.leftMouth, 'leftMouth');
    addLandmark(FaceLandmarkType.rightMouth, 'rightMouth');

    final faceData = {
      'boundingBox': {
        'left': face.boundingBox.left,
        'top': face.boundingBox.top,
        'width': face.boundingBox.width,
        'height': face.boundingBox.height,
      },
      'landmarks': landmarks,
    };

    final response = await _inferenceService.processFace(
      imagePath: imagePath,
      faceData: faceData,
      allowSidePose: allowSidePose,
    );

    if (response.error != null) throw Exception(response.error);
    if (response.embedding == null) {
      throw Exception('Failed to generate embedding');
    }

    // ✅ CRITICAL: L2 Normalize embedding immediately
    final normalizedEmbedding = l2Normalize(response.embedding!);

    return _buildTemplate(face, normalizedEmbedding, landmarks, imagePath);
  }

  // ... [Keep helper methods: _calculateIPD, _calculateBiometricMetrics, _detectOcclusion, _detectPassiveLiveness, _calculateImageQualityMetrics] ...

  double _calculateIPD(Map<String, dynamic> landmarks) {
    if (landmarks['leftEye'] != null && landmarks['rightEye'] != null) {
      final leftEye = landmarks['leftEye'] as Map<String, dynamic>;
      final rightEye = landmarks['rightEye'] as Map<String, dynamic>;
      final dx = (rightEye['x'] as double) - (leftEye['x'] as double);
      final dy = (rightEye['y'] as double) - (leftEye['y'] as double);
      return sqrt(dx * dx + dy * dy);
    }
    return 0.0;
  }

  /* 3D Depth Score Logic Removed for speed parity with wajah project */

  // Helpers for completeness (retained from original file to ensure no breaking changes)
  Map<String, dynamic> _calculateBiometricMetrics(
    Rect boundingBox,
    Map<String, dynamic> landmarks,
  ) {
    final ipd = _calculateIPD(landmarks);
    final faceWidth = boundingBox.width;
    final faceHeight = boundingBox.height;
    final aspectRatio = faceHeight > 0 ? faceWidth / faceHeight : 0.0;
    return {
      'interPupillaryDistance': ipd,
      'faceWidth': faceWidth,
      'faceHeight': faceHeight,
      'faceAspectRatio': aspectRatio,
      'faceShape': aspectRatio > 0.85
          ? 'round'
          : (aspectRatio < 0.75 ? 'long/oval' : 'oval'),
    };
  }

  Map<String, dynamic> _detectOcclusion(Face face) {
    final leftEye = face.leftEyeOpenProbability ?? 0.0;
    final rightEye = face.rightEyeOpenProbability ?? 0.0;
    bool isOccluded = (leftEye < 0.05 && rightEye < 0.05);
    return {'isOccluded': isOccluded, 'confidence': isOccluded ? 0.8 : 0.1};
  }

  Map<String, dynamic> _detectPassiveLiveness(Face face) {
    final leftEye = face.leftEyeOpenProbability ?? 0.0;
    final rightEye = face.rightEyeOpenProbability ?? 0.0;
    final eyeSymmetry = 1.0 - (leftEye - rightEye).abs();
    return {
      'isLive': eyeSymmetry > 0.5,
      'livenessScore': eyeSymmetry,
      'method': 'passive',
    };
  }

  Map<String, dynamic> _calculateImageQualityMetrics(
    Face face,
    Rect boundingBox,
  ) {
    final faceArea = boundingBox.width * boundingBox.height;
    final sharpness = (faceArea / 50000.0).clamp(0.0, 1.0);
    return {'overallQuality': sharpness, 'sharpness': sharpness};
  }

  // Helper for liveness (retained)
  /* Liveness Validation Delegate Removed for speed parity with wajah project */

  Map<String, dynamic> _buildTemplate(
    Face face,
    List<double> embedding,
    Map<String, dynamic> landmarks,
    String imagePath,
  ) {
    final qualityScore = calculateFaceQuality(face);
    final biometricMetrics = _calculateBiometricMetrics(
      face.boundingBox,
      landmarks,
    );
    final livenessDetection = _detectPassiveLiveness(face);
    final occlusion = _detectOcclusion(face);

    return {
      'version': 5.0,
      'embedding': embedding,
      'embeddingSize': embedding.length,
      'qualityScore': qualityScore,
      'boundingBox': {
        'left': face.boundingBox.left,
        'top': face.boundingBox.top,
        'width': face.boundingBox.width,
        'height': face.boundingBox.height,
      },
      'landmarks': landmarks,
      'biometricMetrics': biometricMetrics,
      'livenessDetection': livenessDetection,
      'qualityScores': {
        'leftEyeOpen': face.leftEyeOpenProbability ?? 0.0,
        'rightEyeOpen': face.rightEyeOpenProbability ?? 0.0,
      },
      'poseInformation': {
        'yaw': face.headEulerAngleY ?? 0.0,
        'roll': face.headEulerAngleZ ?? 0.0,
        'pitch': face.headEulerAngleX ?? 0.0,
      },
      'advancedAttributes': {'occlusion': occlusion},
      'captureMetadata': {
        'captureDate': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        'captureDevice': 'Mobile Camera',
      },
    };
  }

  // ✅ CRITICAL REFACTOR: RAW COSINE SIMILARITY [-1.0, 1.0]
  // ⛔ NO MORE SCALING to [0,1]
  // ⛔ NO MORE LANDMARK comparisons in Identity
  double compareFaces(
    Map<String, dynamic> template1,
    Map<String, dynamic> template2,
  ) {
    final embedding1 = List<double>.from(template1['embedding'] ?? []);
    final embedding2 = List<double>.from(template2['embedding'] ?? []);

    if (embedding1.isEmpty || embedding2.isEmpty) return -1.0;

    // Dot Product & Norms
    double dotProduct = 0.0;
    double norm1 = 0.0;
    double norm2 = 0.0;

    // Vectors should already be L2 normalized from _buildTemplate,
    // but we re-calculate safety denominators to be sure.
    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
      norm1 += embedding1[i] * embedding1[i];
      norm2 += embedding2[i] * embedding2[i];
    }

    final mag = sqrt(norm1) * sqrt(norm2);
    if (mag == 0) return -1.0; // Error / Orthogonal default

    // ✅ return RAW Cosine (-1.0 to 1.0)
    return (dotProduct / mag).clamp(-1.0, 1.0);
  }

  // Legacy helper if needed, but redirects to proper logic
  double calculateSimilarity(List<double> e1, List<double> e2) {
    if (e1.isEmpty || e2.isEmpty) return -1.0;

    double dot = 0.0, n1 = 0.0, n2 = 0.0;
    for (int i = 0; i < e1.length; i++) {
      dot += e1[i] * e2[i];
      n1 += e1[i] * e1[i];
      n2 += e2[i] * e2[i];
    }
    final mag = sqrt(n1) * sqrt(n2);
    if (mag == 0) return -1.0;

    return (dot / mag).clamp(-1.0, 1.0);
  }

  // ... (validatePhotoQuality same as above, keep logic) ...
  Future<bool> validatePhotoQuality(String imagePath) async {
    final faces = await detectFaces(imagePath);
    if (faces.isEmpty) throw Exception('No face detected');
    if (faces.length > 1) throw Exception('Multiple faces detected');

    final face = faces.first;
    if (!isValidFaceForRecognition(face, allowSidePose: false)) {
      throw Exception('Face quality insufficient');
    }

    final imageFile = File(imagePath);
    final decoded = img.decodeImage(await imageFile.readAsBytes());
    if (decoded != null) {
      final faceArea = face.boundingBox.width * face.boundingBox.height;
      final imgArea = decoded.width * decoded.height;
      if (faceArea / imgArea < 0.05) throw Exception('Face too small');
    }
    return true;
  }

  Map<String, dynamic> getModelInfo() {
    return {'status': 'initialized', 'domain': 'Raw Cosine [-1,1]'};
  }

  void dispose() {
    _faceDetector.close();
    _inferenceService.dispose();
    _isInitialized = false;
  }
}
