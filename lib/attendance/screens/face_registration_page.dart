// lib/pages/face_registration_page.dart
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../services/face_recognition_tflite_service.dart';
import '../services/biometric_service.dart';
import '../../services/supabase_storage_service.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import '../../helpers/voice_helper.dart'; 
import '../../helpers/language_helper.dart'; // ✅ Added this to fix AppLanguage error

class FaceRegistrationPage extends StatefulWidget {
  final int organizationMemberId;

  const FaceRegistrationPage({super.key, required this.organizationMemberId});

  @override
  State<FaceRegistrationPage> createState() => _FaceRegistrationPageState();
}

enum CaptureAngle { front, left, right, complete }

class _FaceRegistrationPageState extends State<FaceRegistrationPage> {
  CameraController? _cameraController;
  final FaceRecognitionTFLiteService _faceService =
      FaceRecognitionTFLiteService();
  final BiometricService _biometricService = BiometricService();
  final SupabaseStorageService _storageService = SupabaseStorageService();

  bool _isLoading = false;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _isTakingPicture = false;
  bool _isModelInitialized = false;
  String? _errorMessage;
  String _currentStep = 'Loading model...';
  String _guidanceMessage = '';
  Color _overlayColor = Colors.white;

  // State variables for ImageStream
  bool _isStreaming = false;
  int _consecutiveValidFrames = 0;
  final int _requiredValidFrames = 3;
  bool _isRegistrationComplete = false;

  // Multi-Angle Registration Logic
  CaptureAngle _currentAngle = CaptureAngle.front;
  final Map<CaptureAngle, Map<String, dynamic>> _capturedTemplates = {};
  String? _frontImagePath;

  // Guidance and UI
  List<Map<String, dynamic>> _painterFaces = []; 
  bool _isFaceInTargetArea = false; // ✅ Track if face is in silhouette
  DateTime? _lastProcessTime; 
  DateTime? _lastGuidanceUpdate;
  DateTime? _lastVoiceTime; 
  String? _lastSpokenMessage; // ✅ Prevent repeating same message too quickly
  Timer? _errorTimer;

  @override
  void initState() {
    super.initState();
    _initializeModel();
  }

  @override
  void dispose() {
    _stopStream();
    _errorTimer?.cancel();
    _cameraController?.dispose();
    _faceService.dispose();
    super.dispose();
  }

  // Helper for debouncing guidance messages
  void _updateGuidance(String message, Color color) {
    final now = DateTime.now();
    
    // UI Update logic (Fast for responsiveness)
    bool shouldUpdateUI = _lastGuidanceUpdate == null ||
        now.difference(_lastGuidanceUpdate!) > const Duration(milliseconds: 300) ||
        message != _guidanceMessage;

    if (shouldUpdateUI && mounted) {
      setState(() {
        _guidanceMessage = message;
        _overlayColor = color;
        _lastGuidanceUpdate = now;
      });
    }

    // ✅ VOICE LOGIC: Professional & Humanized
    // 1. Clean message
    String cleanMessage = message
        .replaceAll('← ', '')
        .replaceAll(' →', '')
        .replaceAll('!', '')
        .trim();

    if (cleanMessage.isEmpty) return;

    // 2. Identification
    bool isStepChange = message.contains('Tahap') || 
                        message.contains('Selesai') || 
                        message.contains('berhasil') ||
                        message.contains('Bagus') ||
                        message.contains('Sempurna');

    // ✅ PRIORITY MESSAGES: Langsung bunyi tanpa nunggu jeda
    bool isPriority = cleanMessage.contains('Tahan') || 
                      cleanMessage.contains('Oke');

    // 3. Spoken Debounce Logic
    bool isNewMessage = cleanMessage != _lastSpokenMessage;
    
    // Gap check: Don't speak different things too fast (wait at least 2.5s)
    bool hasGap = _lastVoiceTime == null || 
                 now.difference(_lastVoiceTime!) > const Duration(milliseconds: 2500);

    // Repeat check: Don't repeat the same thing too often (wait 7s)
    bool shouldRepeat = !isNewMessage && (_lastVoiceTime == null || 
                 now.difference(_lastVoiceTime!) > const Duration(seconds: 7));

    if (isStepChange || isPriority || (isNewMessage && hasGap) || shouldRepeat) {
      // Avoid speaking "Tahan posisi" too much - only if it's a new state
      if (cleanMessage.contains('Tahan') && !isNewMessage) return;

      VoiceHelper.speak(cleanMessage, force: isStepChange || isPriority);
      _lastVoiceTime = now;
      _lastSpokenMessage = cleanMessage;
    }
  }

  // Helper for auto-clearing errors
  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
    });

    _errorTimer?.cancel();
    _errorTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _errorMessage = null;
        });
      }
    });
  }

  Future<void> _initializeModel() async {
    try {
      setState(() {
        _currentStep = 'Loading model...';
      });

      await _faceService.initialize();

      setState(() {
        _isModelInitialized = true;
        _currentStep = 'Model ready';
      });

      await _initializeCamera();
    } catch (e) {
      if (mounted) {
        _showError('Failed to load model: $e');
        setState(() {
          _currentStep = 'Model initialization failed';
        });
      }
    }
  }

  Future<void> _initializeCamera() async {
    try {
      setState(() {
        _currentStep = 'Starting camera...';
      });

      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      
      // ✅ Speed up capture by disabling flash
      await _cameraController!.setFlashMode(FlashMode.off);

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _currentStep = '${AppLanguage.tr('attendance.face.step')} 1 ${AppLanguage.tr('common.of')} 3';
          _guidanceMessage = AppLanguage.tr('attendance.face.look_straight');
        });
        
        // ✅ VOICE GUIDANCE (Localized) - Force initial guidance
        VoiceHelper.speak(AppLanguage.tr('attendance.face.look_straight'), force: true);

        // Start silent stream instead of polling timer
        _startImageStream();
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to initialize camera: $e');
      }
    }
  }

  void _startImageStream() {
    if (_cameraController == null || _isStreaming) return;

    try {
      _isStreaming = true;
      _cameraController!.startImageStream((CameraImage image) {
        _processCameraFrame(image);
      });
    } catch (e) {
      debugPrint('Error starting stream: $e');
      _isStreaming = false;
    }
  }

  Future<void> _stopStream() async {
    if (_cameraController != null && _isStreaming) {
      try {
        await _cameraController!.stopImageStream();
      } catch (e) {
        debugPrint('Error stopping stream: $e');
      }
      _isStreaming = false;
    }
  }

  Future<void> _processCameraFrame(CameraImage image) async {
    // 🚀 THROTTLING: Max ~10 FPS for detection
    final now = DateTime.now();
    if (_lastProcessTime != null &&
        now.difference(_lastProcessTime!) < const Duration(milliseconds: 100)) {
      return;
    }

    if (_isProcessing || _isTakingPicture || _isRegistrationComplete) return;
    _isProcessing = true;
    _lastProcessTime = now;

    try {
      // 1. Convert to InputImage
      final inputImage = await _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      // 2. Detect Faces
      final faces = await _faceService.detectFacesFromInputImage(inputImage);

      if (!mounted) return;

      if (faces.isEmpty) {
        _consecutiveValidFrames = 0;
        setState(() {
          _painterFaces = [];
          _overlayColor = Colors.transparent;
          _guidanceMessage = AppLanguage.tr('attendance.face.start_instruction');
        });
      } else {
        final face = faces.first;
        final validation = _validateFace(
          face,
          Size(image.width.toDouble(), image.height.toDouble()),
        );

        if (mounted) {
          setState(() {
            // Update silhouette state based on validation
            _isFaceInTargetArea = validation['isValid'] == true;

            _painterFaces = faces
                .map(
                  (f) => {
                    'rect': f.boundingBox,
                    'color': validation['isValid'] == true
                        ? Colors.green
                        : Colors.orange,
                    'name': validation['message'],
                  },
                )
                .toList();
          });
        }

        if (validation['isValid'] == true) {
          _consecutiveValidFrames++;
          _updateGuidance(AppLanguage.tr('attendance.face.perfect_hold'), Colors.green.withOpacity(0.3));

          // Check stability before capturing
          if (_consecutiveValidFrames >= _requiredValidFrames &&
              !_isTakingPicture) {
            _isTakingPicture = true; // Lock
            await _stopStream(); // Await stop stream before capture

            // Trigger capture
            setState(() {
              _guidanceMessage = 'Sedang mengambil foto...';
              _currentStep = 'Capturing...';
              _painterFaces = []; // Clear brackets during freeze-frame capture
            });

            final XFile file = await _cameraController!.takePicture();
            await _processCapturedAngle(file.path);
          }
        } else {
          _consecutiveValidFrames = 0;
          _updateGuidance(
            validation['message'] ?? 'Sesuaikan posisi',
            Colors.orange.withOpacity(0.3),
          );
        }
      }
    } catch (e) {
      debugPrint('Stream process error: $e');
      _isTakingPicture = false;
      _startImageStream();
    } finally {
      _isProcessing = false;
    }
  }
  
  // Reuse the validation logic but adapted for Face object
  Map<String, dynamic> _validateFace(dynamic face, Size imageSize) {
    // 1. Basic validation: Eyes must be open
    final double leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final double rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;

    if (leftEyeOpen < 0.35 || rightEyeOpen < 0.35) {
      return {'isValid': false, 'message': AppLanguage.tr('attendance.face.open_eyes')};
    }

    // 2. Position Validation: Face must be large enough (not too far)
    final rect = face.boundingBox;
    final double faceSizeRatio = rect.width / imageSize.width;
    if (faceSizeRatio < 0.3) {
      return {'isValid': false, 'message': AppLanguage.tr('attendance.face.too_far')};
    }
    if (faceSizeRatio > 0.8) {
      return {'isValid': false, 'message': AppLanguage.tr('attendance.face.too_close')};
    }

    // 3. Angle Validation
    final double headY = face.headEulerAngleY ?? 0.0; // Left/Right
    final double headX = face.headEulerAngleX ?? 0.0; // Up/Down
    final double headZ = (face.headEulerAngleZ ?? 0.0).abs(); // Tilt

    // Anti-tilt: Jangan miringkan kepala
    if (headZ > 30.0) {
      return {
        'isValid': false,
        'message': AppLanguage.tr('attendance.face.keep_straight'),
      }; 
    }

    switch (_currentAngle) {
      case CaptureAngle.front:
        // Front pose needs to be relatively straight
        // Increased tolerance from 10 to 18 degrees for better UX
        if (headY.abs() > 18.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr('attendance.face.look_straight'),
          }; 
        }
        if (headX.abs() > 18.0) {
          return {'isValid': false, 'message': AppLanguage.tr('attendance.face.align_face')};
        }
        break;

      case CaptureAngle.left:
        // User needs to turn head to their LEFT
        // Threshold: 15 to 45 degrees
        if (headY < 15.0) {
          return {'isValid': false, 'message': AppLanguage.tr('attendance.face.turn_left')};
        }
        if (headY > 50.0) {
          return {'isValid': false, 'message': AppLanguage.tr('attendance.face.too_far')};
        }
        break;

      case CaptureAngle.right:
        // User needs to turn head to their RIGHT
        // Threshold: -15 to -45 degrees
        if (headY > -15.0) {
          return {'isValid': false, 'message': AppLanguage.tr('attendance.face.turn_right')};
        }
        if (headY < -50.0) {
          return {'isValid': false, 'message': AppLanguage.tr('attendance.face.too_far')};
        }
        break;
      default:
        break;
    }

    return {'isValid': true, 'message': AppLanguage.tr('attendance.face.perfect_hold')};
  }

  Future<void> _processCapturedAngle(String imagePath) async {
    try {
      const successMsg = 'Oke';

      setState(() {
        _overlayColor = Colors.green;
        _guidanceMessage = successMsg;
        _currentStep = 'Memproses...';
      });

      // ✅ VOICE GUIDANCE - Simple feedback
      VoiceHelper.speak(successMsg, force: true);

      // Extract features for this angle
      final faceTemplate = await _faceService.extractFaceFeatures(
        imagePath,
        allowSidePose: _currentAngle != CaptureAngle.front,
      );

      // ✅ HIGH STANDARD VALIDATION: Mandatory thresholds
      double qualityScore =
          (faceTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;

      // 🚀 User Requirement: "Kalau tidak memenuhi standart itu tidak bisa register"
      double minQuality = _currentAngle == CaptureAngle.front ? 0.90 : 0.65;

      if (qualityScore < minQuality) {
        setState(() {
          _overlayColor = Colors.red; // More urgent than orange
        });
        _updateGuidance(
          '${AppLanguage.tr('attendance.face.low_quality')} (${(qualityScore * 100).toInt()}%). ${AppLanguage.tr('attendance.face.need_lighting')}',
          Colors.red,
        );
        
        // ✅ VOICE GUIDANCE (Localized) - Force alert
        VoiceHelper.speak(AppLanguage.tr('attendance.face.low_quality'), force: true);

        await Future.delayed(const Duration(seconds: 2));
        await File(imagePath).delete();
        _isTakingPicture = false;
        _startImageStream();
        return;
      }

      // Store template
      _capturedTemplates[_currentAngle] = faceTemplate;

      if (_currentAngle == CaptureAngle.front) {
        _frontImagePath = imagePath; // Keep front image
      } else {
        await File(imagePath).delete(); // Delete others
      }

      // PROGRESS LOGIC
      if (_currentAngle == CaptureAngle.front) {
        _currentAngle = CaptureAngle.left;
        _resetStreamForAngle(
          '${AppLanguage.tr('attendance.face.step')} 2 ${AppLanguage.tr('common.of')} 3',
          AppLanguage.tr('attendance.face.turn_left'),
        );
      } else if (_currentAngle == CaptureAngle.left) {
        _currentAngle = CaptureAngle.right;
        _resetStreamForAngle(
          '${AppLanguage.tr('attendance.face.step')} 3 ${AppLanguage.tr('common.of')} 3',
          AppLanguage.tr('attendance.face.turn_right'),
        );
      } else {
        // Complete
        setState(() {
          _guidanceMessage = 'Selesai! Menyimpan...';
          _isRegistrationComplete = true;
          _currentStep = 'Menyimpan Data...';
        });
        await _finalizeMultiAngleRegistration();
      }
    } catch (e) {
      debugPrint('Error processing angle: $e');
      _isTakingPicture = false;
      _startImageStream();
      _showError('Gagal memproses: $e');
    }
  }

  void _resetStreamForAngle(String stepName, String msg) {
    _consecutiveValidFrames = 0;
    _isTakingPicture = false;
    _startImageStream();
    setState(() {
      _currentStep = stepName;
      _guidanceMessage = msg;
      _overlayColor = Colors.blue;
    });
    
    // ✅ VOICE GUIDANCE - Force step instructions
    VoiceHelper.speak(msg.replaceAll('← ', '').replaceAll(' →', ''), force: true);
  }

  Future<void> _finalizeMultiAngleRegistration() async {
    setState(() {
      _isLoading = true;
      _currentStep = 'Menyimpan...';
    });
    
    // ✅ VOICE GUIDANCE
    VoiceHelper.speak("Sedang menyimpan data");

    try {
      // 1. Combine templates
      final List<Map<String, dynamic>> combinedList = [];
      if (_capturedTemplates.containsKey(CaptureAngle.front)) {
        combinedList.add(_capturedTemplates[CaptureAngle.front]!);
      }
      if (_capturedTemplates.containsKey(CaptureAngle.left)) {
        combinedList.add(_capturedTemplates[CaptureAngle.left]!);
      }
      if (_capturedTemplates.containsKey(CaptureAngle.right)) {
        combinedList.add(_capturedTemplates[CaptureAngle.right]!);
      }

      final multiTemplate = {
        'version': 4, // Aligned with high-standard container version
        'templates': combinedList,
        'totalAngles': combinedList.length,
        'enrollmentDate': DateTime.now().toIso8601String(),
      };

      // 2. Upload Front Photo
      if (_frontImagePath != null) {
        final imageFile = File(_frontImagePath!);
        final processedFile = await _processImage(imageFile);
        await _storageService.uploadFaceTemplate(
          processedFile,
          widget.organizationMemberId,
        );

        // Clean up
        if (await imageFile.exists()) await imageFile.delete();
        if (processedFile.path != imageFile.path) {
          final pf = File(processedFile.path);
          if (await pf.exists()) await pf.delete();
        }
      }

      // 3. Register to Database
      await _biometricService.registerFaceTemplate(
        organizationMemberId: widget.organizationMemberId,
        faceTemplate: multiTemplate,
      );

      if (mounted) {
        _showSuccessDialog();
        // ✅ VOICE GUIDANCE (Localized)
        VoiceHelper.speak(AppLanguage.tr('attendance.face.registration_success'));
      }
    } catch (e) {
      _showError('Gagal registrasi: $e');
      setState(() {
        _isLoading = false;
        _isRegistrationComplete = false;
      });
      _currentAngle = CaptureAngle.front; // Reset
      _startImageStream();
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (context) => Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 48),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, color: Colors.white, size: 44),
              ),
              const SizedBox(height: 24),
              const Text(
                'Registrasi Selesai!',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Akurasi pengenalan wajah kini lebih tinggi dengan multi-angle.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) {
        Navigator.of(context).pop();
        Navigator.of(context).pop(true);
      }
    });
  }

  Future<File> _processImage(File imageFile) async {
    try {
      final imageBytes = await imageFile.readAsBytes();
      final image = img.decodeImage(imageBytes);

      if (image == null) {
        return imageFile;
      }

      var enhanced = img.adjustColor(image, brightness: 1.1, contrast: 1.15);

      final flipped = img.flipHorizontal(enhanced);

      final resized = img.copyResize(
        flipped,
        width: 800,
        interpolation: img.Interpolation.average,
      );

      final compressedBytes = img.encodeJpg(resized, quality: 90);

      final tempDir = await Directory.systemTemp.createTemp();
      final processedFile = File('${tempDir.path}/processed_face.jpg');
      await processedFile.writeAsBytes(compressedBytes);

      return processedFile;
    } catch (e) {
      return imageFile;
    }
  }

  // Helper for CameraImage -> InputImage
  Future<InputImage?> _inputImageFromCameraImage(CameraImage image) async {
    if (_cameraController == null) return null;

    final camera = _cameraController!.description;
    final sensorOrientation = camera.sensorOrientation;

    // Determine rotation
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotation.rotation0deg;
    } else if (Platform.isAndroid) {
      var rotationCompensation =
          _orientations[_cameraController!.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        // Front camera
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        // Back camera
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    // Format
    InputImageFormat? format = InputImageFormatValue.fromRawValue(
      image.format.raw,
    );
    if (format == null) return null;

    // Bytes
    final Uint8List bytes;
    int bytesPerRow;

    if (Platform.isAndroid && image.format.group == ImageFormatGroup.yuv420) {
      // ✅ OPTIMIZATION: Run heavy conversion in background isolate
      try {
        final planesData = image.planes
            .map(
              (p) => _PlaneData(
                bytes: p.bytes,
                bytesPerRow: p.bytesPerRow,
                bytesPerPixel: p.bytesPerPixel,
              ),
            )
            .toList();

        bytes = await compute(
          _yuv420ToNv21Compute,
          _NV21ConvertParams(
            width: image.width,
            height: image.height,
            planes: planesData,
          ),
        );

        format = InputImageFormat.nv21;
        bytesPerRow = image.width;
      } catch (e) {
        debugPrint('Error in NV21 conversion: $e');
        return null;
      }
    } else {
      // Regular concatenation for other formats
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      bytes = allBytes.done().buffer.asUint8List();
      bytesPerRow = image.planes.first.bytesPerRow;
    }

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: bytesPerRow,
      ),
    );
  }

  static final Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Register Face',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: Stack(
        children: [
          // 1. FULL CAMERA BACKGROUND
          if (_isCameraInitialized && _cameraController != null)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _cameraController!.value.previewSize?.height ?? 1,
                  height: _cameraController!.value.previewSize?.width ?? 1,
                  child: CameraPreview(_cameraController!),
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator(color: Colors.white)),

          // ✅ 2. SILHOUETTE GUIDE (Always on top of preview)
          Positioned.fill(
            child: CustomPaint(
              painter: SilhouettePainter(
                isActive: _isFaceInTargetArea,
              ),
            ),
          ),

          // 3. DYNAMIC FACE BRACKETS (Optimized CustomPainter)
          if (_painterFaces.isNotEmpty &&
              _cameraController != null &&
              _cameraController!.value.previewSize != null)
            Positioned.fill(
              child: CustomPaint(
                painter: FaceDetectorPainter(
                  absoluteImageSize: Size(
                    _cameraController!.value.previewSize!.height,
                    _cameraController!.value.previewSize!.width,
                  ),
                  faces: _painterFaces,
                  isFrontCamera: true,
                ),
              ),
            ),
          // 4. PROGRESS CARD
          if (_isCameraInitialized && _isModelInitialized)
            Positioned(
              left: 20,
              right: 20,
              bottom: 30, // Positioned slightly lower
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 28,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF8938DF), // Light Purple from Dashboard
                      Color(0xFF4A1E79), // Dark Purple from Dashboard
                    ],
                  ),
                  borderRadius: BorderRadius.circular(36),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 25,
                      offset: const Offset(0, 15),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _guidanceMessage.isNotEmpty
                          ? _guidanceMessage
                          : 'Scanning your face...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22, // Slightly larger like mockup
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _currentStep,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text(
                          'PROGRESS',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.8,
                          ),
                        ),
                        Text(
                          '${_getProgressPercentage().toInt()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        height: 7, // Thinner progress bar
                        width: double.infinity,
                        color: Colors.white.withOpacity(0.15),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: _getProgressPercentage() / 100,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Error message overlay
          if (_errorMessage != null)
            Positioned(
              top: 10,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Loading overlay
          if (_isLoading)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.7),
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  double _getProgressPercentage() {
    if (_isRegistrationComplete) return 100;

    double base = 0;
    switch (_currentAngle) {
      case CaptureAngle.front:
        base = 0;
        break;
      case CaptureAngle.left:
        base = 33;
        break;
      case CaptureAngle.right:
        base = 66;
        break;
      default:
        return 100;
    }

    // Add small visual progress for validation success
    if (_isTakingPicture) return base + 30; // Almost done with step
    if (_consecutiveValidFrames > 0) return base + 15; // Validating

    return base + 5; // Started step
  }

  // Helper for progress percentage removed as it's defined elsewhere if needed
  // ...
}

/// ✅ SYNC: Optimized Custom Painter for all faces (matching attendance page)
class FaceDetectorPainter extends CustomPainter {
  final Size absoluteImageSize;
  final List<Map<String, dynamic>> faces;
  final bool isFrontCamera;

  FaceDetectorPainter({
    required this.absoluteImageSize,
    required this.faces,
    required this.isFrontCamera,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (absoluteImageSize.width == 0 || absoluteImageSize.height == 0) return;

    final double scaleX = size.width / absoluteImageSize.width;
    final double scaleY = size.height / absoluteImageSize.height;

    final Paint bracketPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    final Paint boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final face in faces) {
      final rect = face['rect'] as Rect;
      final color = face['color'] as Color;
      final nameLabel = face['name'] as String?;

      // Apply scaling and mirroring
      double left, right;
      if (isFrontCamera) {
        left = (absoluteImageSize.width - rect.right) * scaleX;
        right = (absoluteImageSize.width - rect.left) * scaleX;
      } else {
        left = rect.left * scaleX;
        right = rect.right * scaleX;
      }
      final top = rect.top * scaleY;
      final bottom = rect.bottom * scaleY;

      final mappedRect = Rect.fromLTRB(left, top, right, bottom);

      // 1. Draw main rounded box with low opacity
      boxPaint.color = color.withOpacity(0.4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(mappedRect, const Radius.circular(12)),
        boxPaint,
      );

      // 2. Draw Brackets
      bracketPaint.color = color;
      const bSize = 20.0;

      // Top-Left
      canvas.drawLine(
        Offset(left, top + bSize),
        Offset(left, top),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(left, top),
        Offset(left + bSize, top),
        bracketPaint,
      );

      // Top-Right
      canvas.drawLine(
        Offset(right - bSize, top),
        Offset(right, top),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(right, top),
        Offset(right, top + bSize),
        bracketPaint,
      );

      // Bottom-Left
      canvas.drawLine(
        Offset(left, bottom - bSize),
        Offset(left, bottom),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(left, bottom),
        Offset(left + bSize, bottom),
        bracketPaint,
      );

      // Bottom-Right
      canvas.drawLine(
        Offset(right - bSize, bottom),
        Offset(right, bottom),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(right, bottom),
        Offset(right, bottom - bSize),
        bracketPaint,
      );

      // 3. Draw Name/Status Label (if present)
      if (nameLabel != null && nameLabel.isNotEmpty) {
        final textSpan = TextSpan(
          text: nameLabel,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            shadows: [Shadow(blurRadius: 2, color: Colors.black)],
          ),
        );
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        )..layout();

        final labelBgPaint = Paint()..color = color.withOpacity(0.8);
        final labelRect = Rect.fromLTWH(
          left,
          top - textPainter.height - 8,
          textPainter.width + 12,
          textPainter.height + 4,
        );

        canvas.drawRRect(
          RRect.fromRectAndRadius(labelRect, const Radius.circular(6)),
          labelBgPaint,
        );
        textPainter.paint(
          canvas,
          Offset(left + 6, top - textPainter.height - 6),
        );
      }
    }
  }

  @override
  bool shouldRepaint(FaceDetectorPainter oldDelegate) =>
      oldDelegate.faces != faces ||
      oldDelegate.absoluteImageSize != absoluteImageSize;
}

/// ✅ SILHOUETTE PAINTER: Professional Blur Cutout style (Reference: Apple/Banking UI)
class SilhouettePainter extends CustomPainter {
  final bool isActive;

  SilhouettePainter({
    required this.isActive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double width = size.width;
    final double height = size.height;
    final double centerX = width / 2;
    final double centerY = height * 0.42;

    // 1. Define the oval area
    final double ovalWidth = width * 0.72;
    final double ovalHeight = ovalWidth * 1.35;
    final Rect ovalRect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: ovalWidth,
      height: ovalHeight,
    );

    // 2. DRAW BLURRED OVERLAY
    // We draw a large rectangle covering the screen with a hole in the middle
    final Paint overlayPaint = Paint()
      ..color = Colors.black.withOpacity(0.65)
      ..style = PaintingStyle.fill;

    // Create a path with a hole
    final Path backgroundPath = Path()..addRect(Rect.fromLTWH(0, 0, width, height));
    final Path holePath = Path()..addOval(ovalRect);
    final Path combinedPath = Path.combine(
      PathOperation.difference,
      backgroundPath,
      holePath,
    );

    canvas.drawPath(combinedPath, overlayPaint);

    // 3. DRAW SOFT GLOW/BLUR EDGE
    // This creates the "blurred" transition effect around the cutout
    final Paint glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 45.0 
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 25.0) 
      ..color = Colors.black.withOpacity(0.85);

    canvas.drawOval(ovalRect.inflate(22), glowPaint);

    // 4. DRAW DASHED BORDER
    final Color borderColor = isActive ? const ui.Color(0xFF10B981) : Colors.white;
    final Paint dashPaint = Paint()
      ..color = borderColor.withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    _drawDashedOval(canvas, ovalRect, dashPaint);
  }

  void _drawDashedOval(Canvas canvas, Rect rect, Paint paint) {
    const double dashWidth = 14.0;
    const double dashSpace = 10.0;
    final double circumference = math.pi * (rect.width + rect.height) / 2;
    final int dashCount = (circumference / (dashWidth + dashSpace)).floor();
    final double angleStep = (2 * math.pi) / dashCount;

    for (int i = 0; i < dashCount; i++) {
      final double startAngle = i * angleStep;
      final double sweepAngle = (dashWidth / circumference) * (2 * math.pi);
      canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
    }
  }

  @override
  bool shouldRepaint(SilhouettePainter oldDelegate) => 
      oldDelegate.isActive != isActive;
}

// ✅ ISOLATE WRAPPERS (Top-Level)
class _PlaneData {
  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
  _PlaneData({
    required this.bytes,
    required this.bytesPerRow,
    this.bytesPerPixel,
  });
}

class _NV21ConvertParams {
  final int width;
  final int height;
  final List<_PlaneData> planes;
  _NV21ConvertParams({
    required this.width,
    required this.height,
    required this.planes,
  });
}

Uint8List _yuv420ToNv21Compute(_NV21ConvertParams params) {
  final int width = params.width;
  final int height = params.height;
  final List<_PlaneData> planes = params.planes;

  final int ySize = width * height;
  final int uvSize = width * height ~/ 2;
  final Uint8List nv21 = Uint8List(ySize + uvSize);

  // Y Plane
  final _PlaneData yData = planes[0];
  final Uint8List yBytes = yData.bytes;
  final int yStride = yData.bytesPerRow;

  for (int y = 0; y < height; y++) {
    final int srcPos = y * yStride;
    final int dstPos = y * width;
    for (int x = 0; x < width; x++) {
      nv21[dstPos + x] = yBytes[srcPos + x];
    }
  }

  // UV Planes
  final _PlaneData uData = planes[1];
  final _PlaneData vData = planes[2];
  final Uint8List uBytes = uData.bytes;
  final Uint8List vBytes = vData.bytes;
  final int uStride = uData.bytesPerRow;
  final int vStride = vData.bytesPerRow;
  final int pixelStride = uData.bytesPerPixel ?? 1;

  int uvIndex = ySize;
  for (int y = 0; y < height ~/ 2; y++) {
    for (int x = 0; x < width ~/ 2; x++) {
      final int uIndex = y * uStride + x * pixelStride;
      final int vIndex = y * vStride + x * pixelStride;

      if (vIndex < vBytes.length && uIndex < uBytes.length) {
        nv21[uvIndex++] = vBytes[vIndex];
        nv21[uvIndex++] = uBytes[uIndex];
      }
    }
  }
  return nv21;
}
