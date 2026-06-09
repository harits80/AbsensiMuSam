// services/camera_service.dart
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';

class CameraService {
  static List<CameraDescription>? _cameras;
  static bool _isInitialized = false;
  static CameraController? _controller;

  // ================== INITIALIZATION ==================

  /// Initialize cameras with lazy initialization
  static Future<List<CameraDescription>> initializeCameras() async {
    if (_isInitialized && _cameras != null) {
      print('Cameras already initialized - returning cached');
      return _cameras!;
    }

    try {
      print('Initializing cameras...');
      _cameras = await availableCameras();
      _isInitialized = true;

      print('Cameras initialized: ${_cameras!.length} cameras found');
      return _cameras!;
    } catch (e) {
      print('Error initializing cameras: $e');
      _isInitialized = false;
      throw CameraException(
        'initialization_failed',
        'Failed to initialize cameras: $e',
      );
    }
  }

  static bool get isInitialized => _isInitialized && _cameras != null;

  static List<CameraDescription> get cameras {
    if (!isInitialized) {
      throw CameraException('not_initialized', 'Cameras not initialized');
    }
    return _cameras!;
  }

  static void reset() {
    _cameras = null;
    _isInitialized = false;
    _controller?.dispose();
    _controller = null;
    print('Camera service reset');
  }

  // ================== CAMERA INFORMATION ==================

  static int get cameraCount => isInitialized ? _cameras!.length : 0;
  static bool get hasCameras => cameraCount > 0;

  static CameraDescription? get frontCamera {
    if (!isInitialized) return null;
    try {
      return _cameras!.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
      );
    } catch (e) {
      return null;
    }
  }

  static CameraDescription? get backCamera {
    if (!isInitialized) return null;
    try {
      return _cameras!.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
    } catch (e) {
      return null;
    }
  }

  static bool get hasFrontCamera => frontCamera != null;
  static bool get hasBackCamera => backCamera != null;

  static CameraDescription? getCameraByIndex(int index) {
    if (!isInitialized || index < 0 || index >= _cameras!.length) {
      return null;
    }
    return _cameras![index];
  }

  static int getPreferredCameraIndex() {
    if (!isInitialized || _cameras!.isEmpty) return 0;

    final frontIndex = _cameras!.indexWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
    );

    return frontIndex >= 0 ? frontIndex : 0;
  }

  static int? getCameraIndexByDirection(CameraLensDirection direction) {
    if (!isInitialized) return null;

    final index = _cameras!.indexWhere(
      (camera) => camera.lensDirection == direction,
    );

    return index >= 0 ? index : null;
  }

  // ================== CAMERA CONTROLLER ==================

  static Future<CameraController> createController(
    CameraDescription camera, {
    ResolutionPreset resolutionPreset = ResolutionPreset.medium,
    bool enableAudio = false,
  }) async {
    try {
      print('Creating camera controller for: ${camera.name}');

      final controller = CameraController(
        camera,
        resolutionPreset,
        enableAudio: enableAudio,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();
      print('Camera controller initialized');

      return controller;
    } catch (e) {
      print('Error creating camera controller: $e');
      throw CameraException(
        'controller_creation_failed',
        'Failed to create camera controller: $e',
      );
    }
  }

  static Future<CameraController> getDefaultController({
    ResolutionPreset resolutionPreset = ResolutionPreset.medium,
    bool enableAudio = false,
  }) async {
    if (!isInitialized) {
      throw CameraException('not_initialized', 'Cameras not initialized');
    }

    final preferredIndex = getPreferredCameraIndex();
    final camera = _cameras![preferredIndex];

    return await createController(
      camera,
      resolutionPreset: resolutionPreset,
      enableAudio: enableAudio,
    );
  }

  // ================== PHOTO OPERATIONS ==================

  static Future<XFile> takePicture(CameraController controller) async {
    try {
      if (!controller.value.isInitialized) {
        throw CameraException(
          'controller_not_initialized',
          'Camera controller not initialized',
        );
      }

      print('Taking picture...');
      final XFile photo = await controller.takePicture();

      print('Picture taken: ${photo.path}');
      return photo;
    } catch (e) {
      print('Error taking picture: $e');
      throw CameraException('capture_failed', 'Failed to take picture: $e');
    }
  }

  static Future<String> takePictureToPath(
    CameraController controller,
    String fileName,
  ) async {
    try {
      final photo = await takePicture(controller);

      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String dirPath = '${appDocDir.path}/attendance_photos';

      final Directory photoDir = Directory(dirPath);
      if (!await photoDir.exists()) {
        await photoDir.create(recursive: true);
      }

      final String filePath = '$dirPath/$fileName';
      await File(photo.path).copy(filePath);

      try {
        await File(photo.path).delete();
      } catch (e) {
        print('Warning: Could not delete temp file: $e');
      }

      print('Picture saved to: $filePath');
      return filePath;
    } catch (e) {
      print('Error taking picture to path: $e');
      throw CameraException('save_failed', 'Failed to save picture: $e');
    }
  }

  // ================== UTILITY METHODS ==================

  static List<ResolutionPreset> getAvailableResolutions() {
    return [
      ResolutionPreset.low,
      ResolutionPreset.medium,
      ResolutionPreset.high,
      ResolutionPreset.veryHigh,
      ResolutionPreset.ultraHigh,
      ResolutionPreset.max,
    ];
  }

  static ResolutionPreset getRecommendedResolution() {
    return ResolutionPreset.medium;
  }

  static String generateAttendancePhotoName(String userId, String type) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${userId}_${type}_$timestamp.jpg';
  }

  static bool validateCameraSetup() {
    if (!isInitialized) {
      print('Camera validation failed: Not initialized');
      return false;
    }

    if (!hasCameras) {
      print('Camera validation failed: No cameras available');
      return false;
    }

    if (!hasFrontCamera && !hasBackCamera) {
      print('Camera validation failed: No usable cameras found');
      return false;
    }

    print('Camera setup validation passed');
    return true;
  }

  static String getCameraInfoString() {
    if (!isInitialized) {
      return 'Cameras not initialized';
    }

    final buffer = StringBuffer();
    buffer.writeln('Camera Service Info:');
    buffer.writeln('- Total cameras: $cameraCount');
    buffer.writeln('- Has front camera: $hasFrontCamera');
    buffer.writeln('- Has back camera: $hasBackCamera');
    buffer.writeln('- Preferred index: ${getPreferredCameraIndex()}');

    return buffer.toString();
  }

  // ================== ERROR HANDLING ==================

  static String getErrorMessage(dynamic error) {
    if (error is CameraException) {
      switch (error.code) {
        case 'not_initialized':
          return 'Kamera belum diinisialisasi';
        case 'initialization_failed':
          return 'Gagal menginisialisasi kamera';
        case 'controller_creation_failed':
          return 'Gagal membuat controller kamera';
        case 'controller_not_initialized':
          return 'Controller kamera belum diinisialisasi';
        case 'capture_failed':
          return 'Gagal mengambil foto';
        case 'save_failed':
          return 'Gagal menyimpan foto';
        default:
          return 'Error kamera: ${error.description}';
      }
    }

    return 'Error tidak dikenal: $error';
  }
}
