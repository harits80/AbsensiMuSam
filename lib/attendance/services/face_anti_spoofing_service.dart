// lib/services/face_anti_spoofing_service.dart
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;
import 'package:image/image.dart' as img;

/// Service untuk deteksi liveness dan anti-spoofing menggunakan TFLite model
/// 
/// Implementasi berdasarkan paper:
/// - "Face Anti-Spoofing: Model Optimization and Deployment for Mobile Devices"
/// - Menggunakan Laplacian operator untuk sharpness detection
/// - Multi-output neural network untuk classification
class FaceAntiSpoofingService {
  static const String _modelFile = "assets/models/FaceAntiSpoofing.tflite";
  static const int _inputImageSize = 256; // Model input size
  static const double _spoofingThreshold = 0.2; // Score > threshold = spoofing attack
  static const double _laplacianThreshold = 1000; // Sharpness threshold
  static const int _laplaceThreshold = 50; // Individual pixel threshold
  
  tfl.Interpreter? _interpreter;
  bool _isInitialized = false;

  /// Initialize the anti-spoofing model
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('=== Initializing Anti-Spoofing Service ===');
      _interpreter = await tfl.Interpreter.fromAsset(_modelFile);
      debugPrint('✅ Anti-Spoofing model loaded: $_modelFile');
      _isInitialized = true;
    } catch (e) {
      debugPrint('❌ Failed to load anti-spoofing model: $e');
      rethrow;
    }
  }

  /// Detect liveness from a cropped face image
  /// 
  /// Returns a map with:
  /// - 'isLive': bool - true if real face, false if spoofing
  /// - 'livenessScore': double (0.0 - 1.0) - higher = more likely real
  /// - 'spoofingScore': double (0.0 - 1.0) - raw model output
  /// - 'sharpness': double - image sharpness score
  /// - 'method': String - detection method used
  Future<Map<String, dynamic>> detectLiveness(img.Image faceImage) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_interpreter == null) {
      throw Exception('Anti-spoofing model not initialized');
    }

    try {
      // Step 1: Check image sharpness using Laplacian
      final sharpness = _calculateLaplacian(faceImage);
      
      if (sharpness < _laplacianThreshold) {
        debugPrint('⚠️ Image too blurry (sharpness: $sharpness)');
        return {
          'isLive': false,
          'livenessScore': 0.0,
          'spoofingScore': 1.0,
          'sharpness': sharpness,
          'method': 'laplacian_filter',
          'reason': 'Image too blurry',
        };
      }

      // Step 2: Run anti-spoofing inference
      final spoofingScore = await _runAntiSpoofingInference(faceImage);
      
      // Convert spoofing score to liveness score (inverse)
      final livenessScore = 1.0 - spoofingScore;
      final isLive = spoofingScore < _spoofingThreshold;

      debugPrint('🔍 Liveness: ${isLive ? "REAL" : "FAKE"} (score: ${livenessScore.toStringAsFixed(3)}, sharpness: ${sharpness.toInt()})');

      return {
        'isLive': isLive,
        'livenessScore': livenessScore.clamp(0.0, 1.0),
        'spoofingScore': spoofingScore.clamp(0.0, 1.0),
        'sharpness': sharpness,
        'method': 'neural_network',
        'reason': isLive ? 'Real face detected' : 'Spoofing attack detected',
      };
    } catch (e) {
      debugPrint('❌ Error in liveness detection: $e');
      rethrow;
    }
  }

  /// Run the anti-spoofing neural network inference
  /// Returns a score where higher values indicate spoofing
  Future<double> _runAntiSpoofingInference(img.Image faceImage) async {
    // Resize to model input size
    final resized = img.copyResizeCropSquare(faceImage, size: _inputImageSize);
    
    // Normalize image to [-1, 1]
    final input = _normalizeImage(resized);
    final inputTensor = input.reshape([1, _inputImageSize, _inputImageSize, 3]);

    // Prepare outputs (model has 2 outputs: Identity and Identity_1)
    final classPrediction = List.generate(1, (index) => List.filled(8, 0.0));
    final leafNodeMask = List.generate(1, (index) => List.filled(8, 0.0));

    final outputs = <int, Object>{};
    outputs[_interpreter!.getOutputIndex("Identity")] = classPrediction;
    outputs[_interpreter!.getOutputIndex("Identity_1")] = leafNodeMask;

    // Run inference
    _interpreter!.runForMultipleInputs([inputTensor], outputs);

    // Calculate final score using leaf score algorithm
    final score = _calculateLeafScore(classPrediction, leafNodeMask);
    
    return score;
  }

  /// Normalize image pixels to [-1, 1] range
  Float32List _normalizeImage(img.Image image) {
    final h = image.height;
    final w = image.width;
    final normalized = Float32List(h * w * 3);
    
    const imageStd = 128.0;
    int pixelIndex = 0;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final pixel = image.getPixel(x, y);
        // Normalize: (pixel - 128) / 128 = range [-1, 1]
        normalized[pixelIndex++] = (pixel.r - imageStd) / imageStd;
        normalized[pixelIndex++] = (pixel.g - imageStd) / imageStd;
        normalized[pixelIndex++] = (pixel.b - imageStd) / imageStd;
      }
    }

    return normalized;
  }

  /// Calculate leaf score from model outputs
  /// This aggregates the 8-channel outputs using the mask
  double _calculateLeafScore(List<List<double>> classPred, List<List<double>> leafMask) {
    double score = 0.0;
    for (int i = 0; i < 8; i++) {
      final absValue = classPred[0][i].abs();
      score += absValue * leafMask[0][i];
    }
    return score;
  }

  /// Calculate image sharpness using Laplacian operator
  /// Higher values = sharper image
  double _calculateLaplacian(img.Image image) {
    // Resize for consistent measurement
    final resized = img.copyResizeCropSquare(image, size: _inputImageSize);
    
    // Convert to grayscale
    final grayscale = img.grayscale(resized);
    
    // Laplacian kernel (edge detection)
    const laplace = [
      [0, 1, 0],
      [1, -4, 1],
      [0, 1, 0]
    ];
    const size = 3;
    
    final height = grayscale.height;
    final width = grayscale.width;
    int score = 0;

    // Apply Laplacian filter
    for (int x = 0; x < height - size + 1; x++) {
      for (int y = 0; y < width - size + 1; y++) {
        int result = 0;
        
        // Convolution
        for (int i = 0; i < size; i++) {
          for (int j = 0; j < size; j++) {
            final pixel = grayscale.getPixel(x + i, y + j);
            result += (pixel.r.toInt()) * laplace[i][j];
          }
        }
        
        // Count significant edges
        if (result.abs() > _laplaceThreshold) {
          score++;
        }
      }
    }

    return score.toDouble();
  }

  /// Multi-frame liveness detection for better accuracy
  /// Analyzes multiple frames and returns aggregated result
  Future<Map<String, dynamic>> detectLivenessMultiFrame(List<img.Image> frames) async {
    if (frames.isEmpty) {
      throw ArgumentError('At least one frame is required');
    }

    final results = <Map<String, dynamic>>[];
    
    for (final frame in frames) {
      final result = await detectLiveness(frame);
      results.add(result);
    }

    // Aggregate results - majority voting
    final liveCount = results.where((r) => r['isLive'] == true).length;
    final avgLivenessScore = results.map((r) => r['livenessScore'] as double).reduce((a, b) => a + b) / results.length;
    final avgSharpness = results.map((r) => r['sharpness'] as double).reduce((a, b) => a + b) / results.length;

    final isLive = liveCount > frames.length / 2; // Majority vote

    return {
      'isLive': isLive,
      'livenessScore': avgLivenessScore,
      'sharpness': avgSharpness,
      'method': 'multi_frame',
      'frameCount': frames.length,
      'liveFrames': liveCount,
      'reason': isLive ? 'Real face (multi-frame verified)' : 'Spoofing detected (multi-frame)',
    };
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
    debugPrint('FaceAntiSpoofingService disposed');
  }
}
