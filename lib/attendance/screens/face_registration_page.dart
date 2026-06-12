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
import '../../helpers/language_helper.dart';

class FaceRegistrationPage extends StatefulWidget {
  final int organizationMemberId;

  const FaceRegistrationPage({super.key, required this.organizationMemberId});

  @override
  State<FaceRegistrationPage> createState() => _FaceRegistrationPageState();
}

enum CaptureAngle { front, left, right, complete }

class _FaceRegistrationPageState extends State<FaceRegistrationPage>
    with TickerProviderStateMixin {
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
  bool _isFaceInTargetArea = false;
  DateTime? _lastProcessTime;
  DateTime? _lastGuidanceUpdate;
  DateTime? _lastVoiceTime;
  String? _lastSpokenMessage;
  Timer? _errorTimer;

  // ✅ NEW: Animation controllers for silhouette pulse & scan line
  late AnimationController _pulseController;
  late AnimationController _scanLineController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _scanLineAnimation;

  @override
  void initState() {
    super.initState();

    // Pulse animation for the oval border glow
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Scan line animation (top → bottom of oval)
    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    _scanLineAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _scanLineController, curve: Curves.easeInOut),
    );

    _initializeModel();
  }

  @override
  void dispose() {
    _stopStream();
    _pulseController.dispose();
    _scanLineController.dispose();
    _errorTimer?.cancel();
    _cameraController?.dispose();
    _cameraController = null; // ✅ NEW: Clear controller reference
    _faceService.dispose();
    super.dispose();
  }

  // Helper for debouncing guidance messages
  void _updateGuidance(String message, Color color) {
    final now = DateTime.now();

    bool shouldUpdateUI = _lastGuidanceUpdate == null ||
        now.difference(_lastGuidanceUpdate!) >
            const Duration(milliseconds: 300) ||
        message != _guidanceMessage;

    if (shouldUpdateUI && mounted) {
      setState(() {
        _guidanceMessage = message;
        _overlayColor = color;
        _lastGuidanceUpdate = now;
      });
    }

    String cleanMessage = message
        .replaceAll('← ', '')
        .replaceAll(' →', '')
        .replaceAll('!', '')
        .trim();

    if (cleanMessage.isEmpty) return;

    bool isStepChange = message.contains('Tahap') ||
        message.contains('Selesai') ||
        message.contains('berhasil') ||
        message.contains('Bagus') ||
        message.contains('Sempurna');

    bool isPriority =
        cleanMessage.contains('Tahan') || cleanMessage.contains('Oke');

    bool isNewMessage = cleanMessage != _lastSpokenMessage;

    bool hasGap = _lastVoiceTime == null ||
        now.difference(_lastVoiceTime!) > const Duration(milliseconds: 2500);

    bool shouldRepeat = !isNewMessage &&
        (_lastVoiceTime == null ||
            now.difference(_lastVoiceTime!) > const Duration(seconds: 7));

    if (isStepChange ||
        isPriority ||
        (isNewMessage && hasGap) ||
        shouldRepeat) {
      if (cleanMessage.contains('Tahan') && !isNewMessage) return;

      VoiceHelper.speak(cleanMessage, force: isStepChange || isPriority);
      _lastVoiceTime = now;
      _lastSpokenMessage = cleanMessage;
    }
  }

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
      await _cameraController!.setFlashMode(FlashMode.off);

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _currentStep =
          '${AppLanguage.tr('attendance.face.step')} 1 ${AppLanguage.tr('common.of')} 3';
          _guidanceMessage = AppLanguage.tr('attendance.face.look_straight');
        });

        VoiceHelper.speak(AppLanguage.tr('attendance.face.look_straight'),
            force: true);
        _startImageStream();
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to initialize camera: $e');
      }
    }
  }

  void _startImageStream() {
    // ✅ IMPROVED: Robust safety checks
    if (!mounted ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isStreaming) {
      return;
    }

    try {
      _isStreaming = true;
      _cameraController!.startImageStream((CameraImage image) {
        if (!mounted) return;
        _processCameraFrame(image);
      });
    } catch (e) {
      debugPrint('Error starting stream: $e');
      _isStreaming = false;
    }
  }

  Future<void> _stopStream() async {
    // ✅ IMPROVED: Check initialization status
    if (_cameraController != null &&
        _cameraController!.value.isInitialized &&
        _isStreaming) {
      try {
        await _cameraController!.stopImageStream();
      } catch (e) {
        debugPrint('Error stopping stream: $e');
      }
      _isStreaming = false;
    }
  }

  Future<void> _processCameraFrame(CameraImage image) async {
    final now = DateTime.now();
    if (_lastProcessTime != null &&
        now.difference(_lastProcessTime!) < const Duration(milliseconds: 100)) {
      return;
    }

    if (_isProcessing || _isTakingPicture || _isRegistrationComplete) return;
    _isProcessing = true;
    _lastProcessTime = now;

    try {
      final inputImage = await _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      final faces = await _faceService.detectFacesFromInputImage(inputImage);

      if (!mounted) return;

      if (faces.isEmpty) {
        _consecutiveValidFrames = 0;
        setState(() {
          _painterFaces = [];
          _overlayColor = Colors.transparent;
          _guidanceMessage =
              AppLanguage.tr('attendance.face.start_instruction');
          _isFaceInTargetArea = false;
        });
      } else {
        final face = faces.first;
        final validation = _validateFace(
          face,
          Size(image.width.toDouble(), image.height.toDouble()),
        );

        if (mounted) {
          setState(() {
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
          _updateGuidance(
              AppLanguage.tr('attendance.face.perfect_hold'),
              Colors.green.withOpacity(0.3));

          if (_consecutiveValidFrames >= _requiredValidFrames &&
              !_isTakingPicture) {
            _isTakingPicture = true;
            await _stopStream();

            setState(() {
              _guidanceMessage = AppLanguage.tr('attendance.face.capturing_photo');
              _currentStep = 'Capturing...';
              _painterFaces = [];
            });

            if (!mounted) return;
            final XFile file = await _cameraController!.takePicture();
            if (!mounted) return;
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
      if (mounted) _startImageStream();
    } finally {
      _isProcessing = false;
    }
  }

  Map<String, dynamic> _validateFace(dynamic face, Size imageSize) {
    final double leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final double rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;

    if (leftEyeOpen < 0.35 || rightEyeOpen < 0.35) {
      return {
        'isValid': false,
        'message': AppLanguage.tr('attendance.face.open_eyes')
      };
    }

    final rect = face.boundingBox;
    final double faceSizeRatio = rect.width / imageSize.width;
    if (faceSizeRatio < 0.3) {
      return {
        'isValid': false,
        'message': AppLanguage.tr('attendance.face.too_far')
      };
    }
    if (faceSizeRatio > 0.8) {
      return {
        'isValid': false,
        'message': AppLanguage.tr('attendance.face.too_close')
      };
    }

    final double headY = face.headEulerAngleY ?? 0.0;
    final double headX = face.headEulerAngleX ?? 0.0;
    final double headZ = (face.headEulerAngleZ ?? 0.0).abs();

    if (headZ > 30.0) {
      return {
        'isValid': false,
        'message': AppLanguage.tr('attendance.face.keep_straight'),
      };
    }

    switch (_currentAngle) {
      case CaptureAngle.front:
        if (headY.abs() > 18.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr('attendance.face.look_straight'),
          };
        }
        if (headX.abs() > 18.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr('attendance.face.align_face')
          };
        }
        break;

      case CaptureAngle.left:
        if (headY < 15.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr('attendance.face.turn_left')
          };
        }
        if (headY > 50.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr('attendance.face.too_far')
          };
        }
        break;

      case CaptureAngle.right:
        if (headY > -15.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr('attendance.face.turn_right')
          };
        }
        if (headY < -50.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr('attendance.face.too_far')
          };
        }
        break;
      default:
        break;
    }

    return {
      'isValid': true,
      'message': AppLanguage.tr('attendance.face.perfect_hold')
    };
  }

  Future<void> _processCapturedAngle(String imagePath) async {
    try {
      const successMsg = 'Oke';

      setState(() {
        _overlayColor = Colors.green;
        _guidanceMessage = successMsg;
        _currentStep = 'Memproses...';
      });

      VoiceHelper.speak(successMsg, force: true);

      final faceTemplate = await _faceService.extractFaceFeatures(
        imagePath,
        allowSidePose: _currentAngle != CaptureAngle.front,
      );

      if (!mounted) return;

      double qualityScore =
          (faceTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;
      double minQuality = _currentAngle == CaptureAngle.front ? 0.90 : 0.65;

      if (qualityScore < minQuality) {
        setState(() {
          _overlayColor = Colors.red;
        });
        _updateGuidance(
          '${AppLanguage.tr('attendance.face.low_quality')} (${(qualityScore * 100).toInt()}%). ${AppLanguage.tr('attendance.face.need_lighting')}',
          Colors.red,
        );

        VoiceHelper.speak(AppLanguage.tr('attendance.face.low_quality'),
            force: true);

        await Future.delayed(const Duration(seconds: 2));
        await File(imagePath).delete();
        _isTakingPicture = false;
        _startImageStream();
        return;
      }

      _capturedTemplates[_currentAngle] = faceTemplate;

      if (_currentAngle == CaptureAngle.front) {
        _frontImagePath = imagePath;
      } else {
        await File(imagePath).delete();
      }

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
        setState(() {
          _guidanceMessage = '${AppLanguage.tr('attendance.face.done')} ${AppLanguage.tr('attendance.face.saving_data')}';
          _isRegistrationComplete = true;
          _currentStep = AppLanguage.tr('attendance.face.saving_data');
        });
        await _finalizeMultiAngleRegistration();
      }
    } catch (e) {
      debugPrint('Error processing angle: $e');
      _isTakingPicture = false;
      if (mounted) _startImageStream();
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

    VoiceHelper.speak(
        msg.replaceAll('← ', '').replaceAll(' →', ''),
        force: true);
  }

  Future<void> _finalizeMultiAngleRegistration() async {
    setState(() {
      _isLoading = true;
      _currentStep = AppLanguage.tr('attendance.face.saving_data');
    });

    VoiceHelper.speak(AppLanguage.tr('attendance.face.saving_data'));

    try {
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
        'version': 4,
        'templates': combinedList,
        'totalAngles': combinedList.length,
        'enrollmentDate': DateTime.now().toIso8601String(),
      };

      if (_frontImagePath != null) {
        final imageFile = File(_frontImagePath!);
        final processedFile = await _processImage(imageFile);
        if (!mounted) return;
        await _storageService.uploadFaceTemplate(
          processedFile,
          widget.organizationMemberId,
        );

        if (!mounted) return;
        if (await imageFile.exists()) await imageFile.delete();
        if (processedFile.path != imageFile.path) {
          final pf = File(processedFile.path);
          if (await pf.exists()) await pf.delete();
        }
      }

      await _biometricService.registerFaceTemplate(
        organizationMemberId: widget.organizationMemberId,
        faceTemplate: multiTemplate,
      );

      if (!mounted) return;
      if (mounted) {
        _showSuccessDialog();
        VoiceHelper.speak(
            AppLanguage.tr('attendance.face.registration_success'));
      }
    } catch (e) {
      _showError('Gagal registrasi: $e');
      setState(() {
        _isLoading = false;
        _isRegistrationComplete = false;
      });
      _currentAngle = CaptureAngle.front;
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
              Text(
                AppLanguage.tr('attendance.face.registration_complete'),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppLanguage.tr('attendance.face.accuracy_improvement_info'),
                textAlign: TextAlign.center,
                style: const TextStyle(
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

      if (image == null) return imageFile;

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

  Future<InputImage?> _inputImageFromCameraImage(CameraImage image) async {
    if (_cameraController == null) return null;

    final camera = _cameraController!.description;
    final sensorOrientation = camera.sensorOrientation;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotation.rotation0deg;
    } else if (Platform.isAndroid) {
      var rotationCompensation =
      _orientations[_cameraController!.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    InputImageFormat? format =
    InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final Uint8List bytes;
    int bytesPerRow;

    if (Platform.isAndroid && image.format.group == ImageFormatGroup.yuv420) {
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

  // ─────────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.35),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: const Icon(Icons.close, color: Colors.white, size: 18),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          AppLanguage.tr('attendance.face.register_face'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // ── 1. CAMERA BACKGROUND ──────────────────────────────────
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
            const Center(
                child: CircularProgressIndicator(color: Colors.white)),

          // ── 2. ANIMATED BLUR SILHOUETTE ───────────────────────────
          if (_isCameraInitialized)
            Positioned.fill(
              child: AnimatedBuilder(
                animation: Listenable.merge(
                    [_pulseAnimation, _scanLineAnimation]),
                builder: (context, child) {
                  return _BlurSilhouetteWidget(
                    isActive: _isFaceInTargetArea,
                    isTakingPicture: _isTakingPicture,
                    currentAngle: _currentAngle,
                    pulseValue: _pulseAnimation.value,
                    scanLineValue: _scanLineAnimation.value,
                    consecutiveFrames: _consecutiveValidFrames,
                    requiredFrames: _requiredValidFrames,
                  );
                },
              ),
            ),

          // ── 3. FACE BRACKETS ─────────────────────────────────────
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

          // ── 4. BOTTOM PROGRESS CARD ───────────────────────────────
          if (_isCameraInitialized && _isModelInitialized)
            Positioned(
              left: 20,
              right: 20,
              bottom: 30,
              child: _buildProgressCard(),
            ),

          // ── 5. ERROR BANNER ───────────────────────────────────────
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

          // ── 6. LOADING OVERLAY ────────────────────────────────────
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

  Widget _buildProgressCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(36),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF8938DF).withOpacity(0.82),
                const Color(0xFF4A1E79).withOpacity(0.92),
              ],
            ),
            borderRadius: BorderRadius.circular(36),
            border: Border.all(
              color: Colors.white.withOpacity(0.15),
              width: 1,
            ),
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
                    : AppLanguage.tr('attendance.face.scanning_face'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
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
                  Text(
                    AppLanguage.tr('attendance.face.progress').toUpperCase(),
                    style: const TextStyle(
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
                  height: 7,
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

    if (_isTakingPicture) return base + 30;
    if (_consecutiveValidFrames > 0) return base + 15;

    return base + 5;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  ✅ SILHOUETTE WIDGET — Dribbble style
//  • Full camera visible (no background blur/dim)
//  • White dashed oval border
//  • Purple corner brackets (app brand color)
//  • Purple validation arc filling as face locks in
//  • Capture flash on shutter
// ─────────────────────────────────────────────────────────────────────────────

// App brand purple (matching progress card gradient)
const Color _kPurplePrimary = Color(0xFF8938DF);
const Color _kPurpleLight  = Color(0xFFAD6FEF);

class _BlurSilhouetteWidget extends StatelessWidget {
  final bool isActive;
  final bool isTakingPicture;
  final CaptureAngle currentAngle;
  final double pulseValue;    // 0.6 → 1.0
  final double scanLineValue; // 0.0 → 1.0
  final int consecutiveFrames;
  final int requiredFrames;

  const _BlurSilhouetteWidget({
    required this.isActive,
    required this.isTakingPicture,
    required this.currentAngle,
    required this.pulseValue,
    required this.scanLineValue,
    required this.consecutiveFrames,
    required this.requiredFrames,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SilhouetteOverlayPainter(
        isActive: isActive,
        isTakingPicture: isTakingPicture,
        currentAngle: currentAngle,
        pulseValue: pulseValue,
        scanLineValue: scanLineValue,
        consecutiveFrames: consecutiveFrames,
        requiredFrames: requiredFrames,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SILHOUETTE OVERLAY PAINTER
// ─────────────────────────────────────────────────────────────────────────────
class _SilhouetteOverlayPainter extends CustomPainter {
  final bool isActive;
  final bool isTakingPicture;
  final CaptureAngle currentAngle;
  final double pulseValue;
  final double scanLineValue;
  final int consecutiveFrames;
  final int requiredFrames;

  _SilhouetteOverlayPainter({
    required this.isActive,
    required this.isTakingPicture,
    required this.currentAngle,
    required this.pulseValue,
    required this.scanLineValue,
    required this.consecutiveFrames,
    required this.requiredFrames,
  });

  Rect _ovalRect(Size size) {
    final double centerX = size.width / 2;
    final double centerY = size.height * 0.42;
    final double ovalWidth = size.width * 0.72;
    final double ovalHeight = ovalWidth * 1.35;
    return Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: ovalWidth,
      height: ovalHeight,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final oval = _ovalRect(size);

    // 1. White dashed oval border (always visible)
    _drawDashedOvalBorder(canvas, oval);

    // 2. Purple corner brackets (4 corners of the oval)
    _drawCornerBrackets(canvas, oval);

    // 3. Purple validation arc (grows as face locks in)
    if (consecutiveFrames > 0 && !isTakingPicture) {
      _drawValidationArc(canvas, oval);
    }

    // 4. Capture flash
    if (isTakingPicture) {
      _drawCaptureFlash(canvas, oval);
    }
  }

  // ── 1. White dashed oval ───────────────────────────────────────────
  void _drawDashedOvalBorder(Canvas canvas, Rect oval) {
    final Paint dashPaint = Paint()
      ..color = Colors.white.withOpacity(isActive ? 0.95 : 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    const double dashLen = 12.0;
    const double gapLen  = 8.0;
    final double circumference = math.pi * (oval.width + oval.height) / 2;
    final int count = (circumference / (dashLen + gapLen)).floor();
    final double angleStep = (2 * math.pi) / count;
    final double sweepAngle = (dashLen / circumference) * 2 * math.pi;

    // Slight rotation offset while active (gives a "locking" spin feel)
    final double offset = isActive ? scanLineValue * 2 * math.pi * 0.08 : 0.0;

    for (int i = 0; i < count; i++) {
      canvas.drawArc(
        oval,
        i * angleStep + offset,
        sweepAngle,
        false,
        dashPaint,
      );
    }
  }

  // ── 2. Purple corner brackets ──────────────────────────────────────
  //  4 L-shaped brackets placed at the top-left, top-right,
  //  bottom-left, bottom-right of the oval's bounding box,
  //  with a small circular dot at each bracket tip (matching Dribbble ref).
  void _drawCornerBrackets(Canvas canvas, Rect oval) {
    // Bracket color: purple when idle/valid, bright purple on valid
    final Color bracketColor = isActive
        ? _kPurpleLight.withOpacity(pulseValue)
        : _kPurplePrimary.withOpacity(0.9);

    final Paint linePaint = Paint()
      ..color = bracketColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final Paint dotPaint = Paint()
      ..color = bracketColor
      ..style = PaintingStyle.fill;

    // Length of each bracket arm
    const double arm = 32.0;
    // How far inset from the exact corner of the bounding oval (along arc)
    const double inset = 14.0;

    // We place brackets at 4 approximate oval "corners":
    // They sit slightly outside the oval edge for clarity.
    const double pad = 6.0; // gap outside the oval

    // Top-Left corner area  (~315° / -45° on the oval)
    _drawOneBracket(
      canvas, linePaint, dotPaint,
      corner: Offset(oval.left + inset, oval.top + inset),
      dx1: arm, dy1: 0,  // horizontal arm →
      dx2: 0,  dy2: arm, // vertical arm ↓
      pad: pad,
    );

    // Top-Right corner (~45°)
    _drawOneBracket(
      canvas, linePaint, dotPaint,
      corner: Offset(oval.right - inset, oval.top + inset),
      dx1: -arm, dy1: 0,
      dx2: 0,   dy2: arm,
      pad: pad,
    );

    // Bottom-Left corner (~225°)
    _drawOneBracket(
      canvas, linePaint, dotPaint,
      corner: Offset(oval.left + inset, oval.bottom - inset),
      dx1: arm, dy1: 0,
      dx2: 0,  dy2: -arm,
      pad: pad,
    );

    // Bottom-Right corner (~135°)
    _drawOneBracket(
      canvas, linePaint, dotPaint,
      corner: Offset(oval.right - inset, oval.bottom - inset),
      dx1: -arm, dy1: 0,
      dx2: 0,   dy2: -arm,
      pad: pad,
    );
  }

  void _drawOneBracket(
      Canvas canvas,
      Paint linePaint,
      Paint dotPaint, {
        required Offset corner,
        required double dx1,
        required double dy1,
        required double dx2,
        required double dy2,
        required double pad,
      }) {
    final Offset end1 = corner + Offset(dx1, dy1);
    final Offset end2 = corner + Offset(dx2, dy2);

    canvas.drawLine(corner, end1, linePaint);
    canvas.drawLine(corner, end2, linePaint);

    // Small circular dot at the corner tip (Dribbble detail)
    canvas.drawCircle(corner, 4.5, dotPaint);
  }

  // ── 3. Purple validation arc ───────────────────────────────────────
  void _drawValidationArc(Canvas canvas, Rect oval) {
    final double progress =
    (consecutiveFrames / requiredFrames).clamp(0.0, 1.0);

    // Subtle glow underneath
    final Paint glowPaint = Paint()
      ..color = _kPurplePrimary.withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0)
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      oval,
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      glowPaint,
    );

    // Solid arc on top
    final Paint arcPaint = Paint()
      ..color = _kPurpleLight
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      oval,
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      arcPaint,
    );
  }

  // ── 4. Capture flash ───────────────────────────────────────────────
  void _drawCaptureFlash(Canvas canvas, Rect oval) {
    final flashPaint = Paint()
      ..color = Colors.white.withOpacity(0.22)
      ..style = PaintingStyle.fill;

    canvas.save();
    canvas.clipPath(Path()..addOval(oval));
    canvas.drawRect(oval.inflate(50), flashPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SilhouetteOverlayPainter old) =>
      old.isActive != isActive ||
          old.isTakingPicture != isTakingPicture ||
          old.pulseValue != pulseValue ||
          old.scanLineValue != scanLineValue ||
          old.consecutiveFrames != consecutiveFrames ||
          old.currentAngle != currentAngle;
}

// ─────────────────────────────────────────────────────────────────────────────
//  FACE DETECTOR PAINTER (unchanged)
// ─────────────────────────────────────────────────────────────────────────────
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

      boxPaint.color = color.withOpacity(0.4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(mappedRect, const Radius.circular(12)),
        boxPaint,
      );

      bracketPaint.color = color;
      const bSize = 20.0;

      canvas.drawLine(Offset(left, top + bSize), Offset(left, top), bracketPaint);
      canvas.drawLine(Offset(left, top), Offset(left + bSize, top), bracketPaint);
      canvas.drawLine(Offset(right - bSize, top), Offset(right, top), bracketPaint);
      canvas.drawLine(Offset(right, top), Offset(right, top + bSize), bracketPaint);
      canvas.drawLine(Offset(left, bottom - bSize), Offset(left, bottom), bracketPaint);
      canvas.drawLine(Offset(left, bottom), Offset(left + bSize, bottom), bracketPaint);
      canvas.drawLine(Offset(right - bSize, bottom), Offset(right, bottom), bracketPaint);
      canvas.drawLine(Offset(right, bottom), Offset(right, bottom - bSize), bracketPaint);

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
        final textPainter =
        TextPainter(text: textSpan, textDirection: TextDirection.ltr)
          ..layout();

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
        textPainter.paint(canvas, Offset(left + 6, top - textPainter.height - 6));
      }
    }
  }

  @override
  bool shouldRepaint(FaceDetectorPainter oldDelegate) =>
      oldDelegate.faces != faces ||
          oldDelegate.absoluteImageSize != absoluteImageSize;
}

// ─────────────────────────────────────────────────────────────────────────────
//  ISOLATE WRAPPERS (unchanged)
// ─────────────────────────────────────────────────────────────────────────────
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