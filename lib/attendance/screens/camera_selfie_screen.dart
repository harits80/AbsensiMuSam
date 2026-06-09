// attendance/screens/camera_selfie_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import '../../helpers/language_helper.dart';
import '../../services/camera_service.dart';

class CameraSelfieScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraSelfieScreen({super.key, required this.cameras});

  @override
  State<CameraSelfieScreen> createState() => _CameraSelfieScreenState();
}

class _CameraSelfieScreenState extends State<CameraSelfieScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isInitialized = false;
  bool _isCapturing = false;
  int _selectedCameraIndex = 0;

  // Theme colors matching dashboard
  static const Color primaryColor = Color(0xFF6366F1); // Purple
  static const Color backgroundColor = Color(0xFF1F2937); // Dark gray

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedCameraIndex = CameraService.getPreferredCameraIndex();
    _initializeController();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeController();
    }
  }

  Future<void> _initializeController() async {
    try {
      if (widget.cameras.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLanguage.tr('attendance.selfie.no_cameras')),
            ),
          );
        }
        return;
      }

      final camera = widget.cameras[_selectedCameraIndex];
      await _controller?.dispose();

      _controller = CameraController(
        camera,
        ResolutionPreset.ultraHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();
      await _controller!.setFlashMode(FlashMode.off);
      final size = _controller!.value.previewSize;
      debugPrint('Foto resolusi: ${size?.width} x ${size?.height}');

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('Error initializing selfie camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${AppLanguage.tr('attendance.selfie.failed_init_camera')}: $e',
            ),
          ),
        );
      }
    }
  }

  Future<void> _takePicture() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isCapturing) {
      return;
    }

    final currentCamera = widget.cameras[_selectedCameraIndex];

    setState(() {
      _isCapturing = true;
    });

    try {
      final XFile photo = await _controller!.takePicture();

      // Generate filename for attendance photo
      final userId = 'user_${DateTime.now().millisecondsSinceEpoch}';
      final fileName = CameraService.generateAttendancePhotoName(
        userId,
        'selfie',
      );

      // Save to specific path
      final savedPath = await CameraService.takePictureToPath(
        _controller!,
        fileName,
      );

      // Flip image horizontally if using front camera (to avoid mirror effect)
      if (currentCamera.lensDirection == CameraLensDirection.front) {
        await _flipImageHorizontally(savedPath);
      }

      // Log file size for monitoring
      final fileSizeBytes = await File(savedPath).length();
      final fileSizeKb = (fileSizeBytes / 1024).toStringAsFixed(0);
      debugPrint('Attendance photo saved: $savedPath ($fileSizeKb KB)');

      if (mounted) {
        Navigator.pop(context, savedPath);
      }
    } catch (e) {
      debugPrint('Error taking picture: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${AppLanguage.tr('attendance.selfie.camera_error')}: $e',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
    }
  }

  Widget _buildCameraPreview() {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Container(
        width: double.infinity,
        height: double.infinity,
        color: backgroundColor,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
              ),
              const SizedBox(height: 16),
              Text(
                AppLanguage.tr('attendance.selfie.initializing_camera'),
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    final size = MediaQuery.of(context).size;
    final isLandscape = size.width > size.height;

    // Get preview size
    final previewSize = _controller!.value.previewSize!;

    // Swap dimensions based on orientation
    final previewWidth = isLandscape ? previewSize.width : previewSize.height;
    final previewHeight = isLandscape ? previewSize.height : previewSize.width;

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: previewWidth,
          height: previewHeight,
          child: CameraPreview(_controller!),
        ),
      ),
    );
  }

  Future<void> _flipImageHorizontally(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;

      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return;

      final flipped = img.flipHorizontal(image);
      final encoded = img.encodeJpg(flipped, quality: 90);
      await file.writeAsBytes(encoded, flush: true);
    } catch (e) {
      debugPrint('Failed to flip selfie image: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Full Screen Camera Preview
          Positioned.fill(child: _buildCameraPreview()),

          // 2. Bottom Controls (Premium Style)
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 40,
            left: 0,
            right: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Cancel Button (X)
                  _buildSideButton(
                    icon: Icons.close_rounded,
                    onTap: () => Navigator.pop(context),
                    isOutline: true,
                  ),

                  // Capture Button (Main)
                  _buildCaptureButton(),

                  // Flip Camera Button
                  _buildSideButton(
                    icon: Icons.cameraswitch_rounded,
                    onTap: _toggleCamera,
                    isFill: true,
                  ),
                ],
              ),
            ),
          ),

          // 5. Capturing Overlay
          if (_isCapturing)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: const Center(
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 3,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSideButton({
    required IconData icon,
    required VoidCallback onTap,
    bool isOutline = false,
    bool isFill = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isFill ? Colors.white : Colors.black.withOpacity(0.2),
          border: isOutline
              ? Border.all(color: Colors.white.withOpacity(0.5), width: 1.5)
              : null,
        ),
        child: Icon(
          icon,
          color: isFill ? primaryColor : Colors.white,
          size: 28,
        ),
      ),
    );
  }

  Widget _buildCaptureButton() {
    return GestureDetector(
      onTap: _isCapturing ? null : _takePicture,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: primaryColor.withOpacity(0.8), width: 4),
          boxShadow: [
            BoxShadow(
              color: primaryColor.withOpacity(0.4),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Future<void> _toggleCamera() async {
    if (widget.cameras.length < 2) return;
    setState(() {
      _isInitialized = false;
      _selectedCameraIndex = (_selectedCameraIndex + 1) % widget.cameras.length;
    });
    await _initializeController();
  }
}
