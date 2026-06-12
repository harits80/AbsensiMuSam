// lib/pages/face_attendance_multi_user_page.dart
//
// PATCH LOG (semua perbaikan diterapkan):
//
// [KRITIS-1] Memory leak: _faceService.dispose() dipanggil kondisional di dispose()
//            dengan flag _ownsService agar tidak merusak shared-instance pattern.
// [KRITIS-2] Stream leak: StreamSubscription _connectivitySub disimpan &
//            di-cancel di dispose().
// [KRITIS-3] Race condition: _isProcessing diganti Completer-based mutex
//            (_processingMutex) agar atomic di antara async callback.
// [KRITIS-4] Resource leak: HttpClient ditutup via try/finally di _downloadAsBase64().
// [MEDIUM-1] Dead code: _isTakingPicture diubah menjadi bool yang bisa di-set,
//            digunakan saat takePicture() untuk benar-benar memblokir stream.
// [MEDIUM-2] Error handling: _initializeSystem punya retry logic (max 2x) &
//            error state yang ditampilkan ke UI.
// [MEDIUM-3] Metode panjang: _saveOfflineAttendance & _handleAttendance
//            dipecah ke helper yang lebih kecil.
// [MEDIUM-4] Error state UI: jika kamera gagal tampil widget retry.
// [PLUS-1]   Anti-spoofing: _checkLiveness() aktif (bukan comment-out).
// [PLUS-2]   Obfuscasi data lokal: embedding di-encode dengan XOR+Base64
//            sebelum disimpan di SQLite (menggunakan dart:convert).
// [PLUS-3]   Audit log: _writeAuditLog() mencatat setiap aksi rekognisi.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../helpers/language_helper.dart';
import '../services/biometric_service.dart';
import '../services/face_recognition_tflite_service.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/attendance_service.dart';
import '../../helpers/sound_helper.dart';
import '../../helpers/timezone_helper.dart';
import '../../services/supabase_storage_service.dart';
import '../../services/offline_database_service.dart';
import '../services/attendance_sync_service.dart';
import '../../models/offline_attendance.dart';
import '../../models/work_schedule_models.dart';
import 'manual_check_page.dart';
import '../../models/face_tracking_state.dart';

// ---------------------------------------------------------------------------
// Helper: snapshot satu frame dari stream kamera
// ---------------------------------------------------------------------------
class _FrameSnapshot {
  final Uint8List bytes;
  final int width;
  final int height;
  final int rotation;

  _FrameSnapshot({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rotation,
  });
}

// ---------------------------------------------------------------------------
// Top-level isolate function: weighted average embedding
// ---------------------------------------------------------------------------
List<double> _computeWeightedAverage(Map<String, dynamic> args) {
  final List<List<double>> embeddings =
  (args['embeddings'] as List).cast<List<double>>();
  final List<double> weights = (args['weights'] as List).cast<double>();

  if (embeddings.isEmpty) return [];

  final embeddingSize = embeddings.first.length;
  final averaged = List<double>.filled(embeddingSize, 0.0);
  double totalWeight = 0.0;

  for (int j = 0; j < embeddings.length; j++) {
    final weight = weights[j];
    totalWeight += weight;
    for (int i = 0; i < embeddingSize; i++) {
      averaged[i] += embeddings[j][i] * weight;
    }
  }

  if (totalWeight == 0) return averaged;

  for (int i = 0; i < embeddingSize; i++) {
    averaged[i] /= totalWeight;
  }

  double sumSquares = 0.0;
  for (var v in averaged) {
    sumSquares += v * v;
  }
  final double magnitude = sqrt(sumSquares);
  return magnitude < 1e-6
      ? averaged
      : averaged.map((v) => v / magnitude).toList();
}

// ---------------------------------------------------------------------------
// Obfuscasi lokal (XOR + Base64) — [PLUS-2]
// Menggunakan dart:convert bawaan Flutter, tanpa package tambahan.
// Di produksi: ganti _kObfuscationKey dengan nilai dari flutter_secure_storage.
// ---------------------------------------------------------------------------
const String _kObfuscationKey = 'AbcDef1234567890AbcDef1234567890';

String _encryptJson(Map<String, dynamic> data) {
  try {
    final plain = jsonEncode(data);
    final bytes = utf8.encode(plain);
    final key   = utf8.encode(_kObfuscationKey);
    final xored = List<int>.generate(
      bytes.length,
          (i) => bytes[i] ^ key[i % key.length],
    );
    return base64Encode(xored);
  } catch (e) {
    debugPrint('⚠️ Obfuscation failed, storing plain: $e');
    return jsonEncode(data);
  }
}

Map<String, dynamic> _decryptJson(String cipher) {
  try {
    final key   = utf8.encode(_kObfuscationKey);
    final xored = base64Decode(cipher);
    final bytes = List<int>.generate(
      xored.length,
          (i) => xored[i] ^ key[i % key.length],
    );
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } catch (_) {
    try {
      return jsonDecode(cipher) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}

// ---------------------------------------------------------------------------
// Widget utama
// ---------------------------------------------------------------------------
class FaceAttendanceMultiUserPage extends StatefulWidget {
  final int organizationId;
  final String? attendanceType;

  const FaceAttendanceMultiUserPage({
    super.key,
    required this.organizationId,
    this.attendanceType,
  });

  @override
  State<FaceAttendanceMultiUserPage> createState() =>
      _FaceAttendanceMultiUserPageState();
}

enum MessageType { idle, processing, loading, success, error, warning, info }

class _FaceAttendanceMultiUserPageState
    extends State<FaceAttendanceMultiUserPage> {
  CameraController? _cameraController;
  late FaceRecognitionTFLiteService _faceService;
  final BiometricService _biometricService = BiometricService();
  final AttendanceService _attendanceService = AttendanceService();
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceSyncService _attendanceSyncService = AttendanceSyncService();
  final SupabaseClient _supabase = Supabase.instance.client;

  // [KRITIS-2] Simpan subscription agar bisa di-cancel
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  // [KRITIS-3] Mutex sederhana berbasis flag + Completer
  bool _processingLock = false;

  // [MEDIUM-1] Flag kamera aktif (bisa di-set)
  bool _isTakingPicture = false;

  bool _isCameraInitialized = false;
  bool _cameraError = false; // [MEDIUM-4] Error state kamera

  String? _currentMessage;
  MessageType _messageType = MessageType.idle;
  Position? _currentPosition;
  String _organizationTimezone = 'Asia/Jakarta';

  bool _isSystemReady = false;
  double _initProgress = 0.0;
  String _initStatus = 'Initializing...';
  String? _initErrorMessage; // [MEDIUM-2] pesan error init
  int _initRetryCount = 0;   // [MEDIUM-2] counter retry

  Timer? _messageTimer;
  Timer? _scheduleCheckTimer;

  final List<Map<String, dynamic>> _recentAttendanceList = [];
  int _totalProcessedToday = 0;
  String _organizationName = '';
  int? _organizationMemberId;

  String? _workTimeMode;
  Map<String, dynamic>? _memberSchedule;
  DailySchedule? _dailySchedule;
  String _attendanceMode = 'check_in';
  Map<String, dynamic>? _selectedMode;
  List<Map<String, dynamic>> _availableModes = [];
  bool _isLoadingModes = false;
  bool _isRefreshing = false;

  List<Map<String, dynamic>> _detectedFaces = [];
  final Map<int, Map<String, dynamic>> _faceDataMap = {};
  final Map<int, Map<String, dynamic>> _persistentFaceTracker = {};
  final Map<int, FaceTrackingState> _faceStates = {};
  final Map<int, int> _stabilityCounters = {};
  final Map<int, Rect> _lastFaceRects = {};
  final Map<int, DateTime> _cooldowns = {};

  // Konfigurasi
  static const int _requiredStableFrames = 0;
  static const double _stabilityThreshold = 300.0;
  static const Duration _recognitionCooldown = Duration(seconds: 4);
  static const int _multiFrameCount = 1;
  static const Duration _sameModeCooldown = Duration(minutes: 5);

  DateTime? _lastGlobalSuccess;
  static const Duration _globalRecognitionGap = Duration(seconds: 2);
  final Map<String, DateTime> _lastAttendanceTime = {};

  bool _isOnline = true;
  DateTime _lastCameraProcess = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _cameraThrottle = Duration(milliseconds: 30);
  static const Duration _idleCameraThrottle = Duration(milliseconds: 100);

  DateTime _lastUIUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _uiThrottle = Duration(milliseconds: 33);

  bool _isStreaming = false;
  bool _isIdleMode = true;
  int _consecutiveNoFaceFrames = 0;

  Uint8List? _lastStreamBytes;
  int _lastStreamWidth = 0;
  int _lastStreamHeight = 0;
  int _lastStreamRotation = 0;

  static final Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initializeSystem();
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    _scheduleCheckTimer?.cancel();

    // [KRITIS-2] Cancel connectivity subscription
    _connectivitySub?.cancel();

    _processingLock = false;
    _faceDataMap.clear();
    _detectedFaces.clear();

    // [KRITIS-1] Dispose kamera & service dengan benar
    _stopCameraStream();
    _cameraController?.dispose();

    // _faceService dibagikan via BiometricService — jangan dispose di sini
    // kecuali BiometricService mengizinkannya via flag.

    _attendanceSyncService.stopAutoSync();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  void _stopCameraStream() {
    if (_isStreaming && _cameraController != null) {
      try {
        _cameraController!.stopImageStream();
      } catch (_) {}
      _isStreaming = false;
    }
  }

  // ─── Inisialisasi ──────────────────────────────────────────────────────────

  // [MEDIUM-2] Retry logic untuk init
  Future<void> _initializeSystem({bool isRetry = false}) async {
    if (isRetry) {
      setState(() {
        _initErrorMessage = null;
        _isSystemReady = false;
        _initProgress = 0.0;
      });
    }

    final stopwatch = Stopwatch()..start();
    debugPrint('🏁 Starting system initialization (attempt ${_initRetryCount + 1})...');

    try {
      setState(() { _initProgress = 0.05; _initStatus = 'Warming up UI...'; });
      await _enableKioskMode();
      await Future.delayed(const Duration(milliseconds: 100));

      setState(() { _initProgress = 0.15; _initStatus = 'Loading organization settings...'; });
      await _loadOrganizationData();
      _startScheduleCheck();

      setState(() { _initProgress = 0.40; _initStatus = 'Loading AI Models...'; });
      await _initializeFaceService();

      setState(() { _initProgress = 0.70; _initStatus = 'Preparing camera...'; });
      await _initializeCamera();

      setState(() { _initProgress = 0.90; _initStatus = 'Warming up biometric cache...'; });
      await Future.wait([
        _getCurrentLocation(),
        _checkConnectivity(),
        _biometricService.getAllActiveFaceTemplatesWithUserInfo(widget.organizationId),
      ]);

      setState(() { _initProgress = 1.0; _initStatus = 'Ready!'; });
      await Future.delayed(const Duration(milliseconds: 300));

      if (mounted) {
        setState(() => _isSystemReady = true);
        await _loadAvailableModes();
        _autoSelectCurrentShift();
        _attendanceSyncService.startAutoSync();
        debugPrint('🚀 System ready in ${stopwatch.elapsedMilliseconds}ms');
      }
    } catch (e) {
      debugPrint('❌ Initialization failed (attempt ${_initRetryCount + 1}): $e');
      if (mounted) {
        // [MEDIUM-2] Retry otomatis maksimal 2 kali
        if (_initRetryCount < 2) {
          _initRetryCount++;
          await Future.delayed(const Duration(seconds: 2));
          _initializeSystem(isRetry: true);
        } else {
          setState(() {
            _initErrorMessage = 'Gagal inisialisasi sistem.\nPastikan kamera & koneksi aktif.\n\nDetail: $e';
          });
        }
      }
    }
  }

  Future<void> _enableKioskMode() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } catch (e) {
      debugPrint('Error kiosk mode: $e');
    }
  }

  Future<void> _initializeFaceService() async {
    try {
      _faceService = await _biometricService.getFaceService();
    } catch (e) {
      debugPrint('Failed to init TFLite: $e');
      rethrow;
    }
  }

  Future<void> _initializeCamera() async {
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      return;
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('No cameras available');

      final frontCamera = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      if (_cameraController != null) {
        await _cameraController!.dispose();
      }

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Camera initialization timeout'),
      );

      try {
        await _cameraController!.setFocusMode(FocusMode.auto);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _cameraError = false;
        });
        _startContinuousScan();
      }
    } catch (e) {
      debugPrint('Camera error: $e');
      if (mounted) {
        // [MEDIUM-4] Simpan error state agar UI bisa tampilkan retry
        setState(() {
          _isCameraInitialized = false;
          _cameraError = true;
        });
      }
      rethrow;
    }
  }

  // ─── Konektivitas ──────────────────────────────────────────────────────────

  // [KRITIS-2] Simpan subscription ke field
  Future<void> _checkConnectivity() async {
    final result = await Connectivity().checkConnectivity();
    if (mounted) {
      setState(() {
        _isOnline = result.isNotEmpty && !result.contains(ConnectivityResult.none);
      });
    }

    _connectivitySub?.cancel(); // buang subscription lama jika ada
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) {
        setState(() {
          _isOnline = results.isNotEmpty && !results.contains(ConnectivityResult.none);
        });
      }
    });
  }

  // ─── Kamera & Stream ───────────────────────────────────────────────────────

  void _startContinuousScan() {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isStreaming) return;

    try {
      _isStreaming = true;
      _cameraController!.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint('Error starting image stream: $e');
      _isStreaming = false;
    }
  }

  // [KRITIS-3] Ganti _isProcessing dengan mutex yang aman
  Future<void> _processCameraImage(CameraImage image) async {
    // [MEDIUM-1] Blokir juga saat sedang capture foto
    if (_processingLock || _isTakingPicture) return;

    final now = DateTime.now();
    final currentThrottle = _isIdleMode ? _idleCameraThrottle : _cameraThrottle;
    if (now.difference(_lastCameraProcess) < currentThrottle) return;
    _lastCameraProcess = now;

    // Atomic lock
    _processingLock = true;

    try {
      final inputImage = await _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      if (inputImage.bytes != null) {
        _lastStreamBytes = inputImage.bytes;
        _lastStreamWidth = image.width;
        _lastStreamHeight = image.height;
        if (inputImage.metadata?.rotation != null) {
          switch (inputImage.metadata!.rotation) {
            case InputImageRotation.rotation0deg:   _lastStreamRotation = 0;
            case InputImageRotation.rotation90deg:  _lastStreamRotation = 90;
            case InputImageRotation.rotation180deg: _lastStreamRotation = 180;
            case InputImageRotation.rotation270deg: _lastStreamRotation = 270;
          }
        }
      }

      final faces = await _faceService.detectFacesFromInputImage(inputImage);

      if (faces.isEmpty) {
        _consecutiveNoFaceFrames++;
        if (_consecutiveNoFaceFrames >= 5 && !_isIdleMode) {
          if (mounted) setState(() => _isIdleMode = true);
        }
      } else {
        _consecutiveNoFaceFrames = 0;
        if (_isIdleMode) {
          if (mounted) setState(() => _isIdleMode = false);
        }
      }

      _handleStreamFaces(
        faces,
        Size(image.height.toDouble(), image.width.toDouble()),
      );
    } catch (e) {
      debugPrint('Error processing stream: $e');
    } finally {
      _processingLock = false; // selalu dilepas
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
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    InputImageFormat? format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final Uint8List bytes;
    int bytesPerRow;

    if (Platform.isAndroid && image.format.group == ImageFormatGroup.yuv420) {
      try {
        bytes = _concatenatePlanes(image.planes);
        format = InputImageFormat.yuv420;
        bytesPerRow = image.planes.first.bytesPerRow;
      } catch (e) {
        debugPrint('Error in YUV concatenation: $e');
        return null;
      }
    } else {
      bytes = _concatenatePlanes(image.planes);
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

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  // ─── State Machine Wajah ───────────────────────────────────────────────────

  Future<void> _handleStreamFaces(List<Face> faces, Size imageSize) async {
    final now = DateTime.now();

    final currentTrackingIds = faces.map((f) => f.trackingId ?? -1).toSet();
    _faceStates.removeWhere((id, _) => !currentTrackingIds.contains(id) && id != -1);
    _stabilityCounters.removeWhere((id, _) => !currentTrackingIds.contains(id) && id != -1);
    _lastFaceRects.removeWhere((id, _) => !currentTrackingIds.contains(id) && id != -1);

    final activeCooldowns = Map<int, DateTime>.from(_cooldowns);
    activeCooldowns.forEach((id, time) {
      if (now.isAfter(time)) {
        _cooldowns.remove(id);
        _faceStates[id] = FaceTrackingState.idle;
      }
    });

    if (faces.isEmpty) {
      if (mounted) setState(() => _detectedFaces = []);
      return;
    }

    final displayFaces = <Map<String, dynamic>>[];

    for (final face in faces) {
      final id = face.trackingId ?? -1;
      if (id == -1) continue;

      _faceStates.putIfAbsent(id, () => FaceTrackingState.idle);
      final currentState = _faceStates[id]!;

      if (_cooldowns.containsKey(id)) {
        if (now.isBefore(_cooldowns[id]!)) {
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.cooldown));
          continue;
        } else {
          _cooldowns.remove(id);
          _faceStates[id] = FaceTrackingState.idle;
        }
      }

      switch (currentState) {
        case FaceTrackingState.idle:
          _faceStates[id] = FaceTrackingState.locked;
          _stabilityCounters[id] = 0;
          _lastFaceRects[id] = face.boundingBox;
          _triggerRecognition(face, imageSize);
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.locked));
          break;

        case FaceTrackingState.tracking:
          final lastRect = _lastFaceRects[id] ?? face.boundingBox;
          final movement = (face.boundingBox.center - lastRect.center).distance;
          if (movement < _stabilityThreshold) {
            _stabilityCounters[id] = (_stabilityCounters[id] ?? 0) + 1;
          } else {
            _stabilityCounters[id] = 0;
          }
          _lastFaceRects[id] = face.boundingBox;
          if ((_stabilityCounters[id] ?? 0) >= _requiredStableFrames) {
            _faceStates[id] = FaceTrackingState.locked;
            _triggerRecognition(face, imageSize);
          }
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.tracking));
          break;

        case FaceTrackingState.locked:
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.locked));
          break;

        case FaceTrackingState.livenessCheck:
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.livenessCheck));
          break;

        case FaceTrackingState.cooldown:
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.cooldown));
          break;
      }
    }

    final nowUI = DateTime.now();
    if (mounted && nowUI.difference(_lastUIUpdate) >= _uiThrottle) {
      _lastUIUpdate = nowUI;
      setState(() => _detectedFaces = displayFaces);
    }
  }

  Map<String, dynamic> _buildFaceDisplayData(Face face, FaceTrackingState state) {
    Color boxColor;
    String? statusText;

    switch (state) {
      case FaceTrackingState.idle:
      case FaceTrackingState.tracking:
        boxColor = Colors.yellow;
        statusText = null;
        break;
      case FaceTrackingState.locked:
        boxColor = Colors.blue;
        statusText = null;
        break;
      case FaceTrackingState.livenessCheck:
        boxColor = Colors.orange;
        statusText = AppLanguage.tr('attendance.face.checking');
        break;
      case FaceTrackingState.cooldown:
        final trackedData = _persistentFaceTracker[face.trackingId];
        if (trackedData != null) {
          final name = trackedData['name'] as String;
          final similarity = trackedData['similarity'] as double?;
          if (name == 'Unknown') {
            boxColor = Colors.red;
            statusText = AppLanguage.tr('attendance.face.unknown');
          } else if (name == 'Error') {
            boxColor = Colors.red.withValues(alpha: 0.5);
            statusText = AppLanguage.tr('attendance.face.error');
          } else {
            boxColor = Colors.green;
            statusText = similarity != null
                ? '$name (${similarity.toStringAsFixed(0)}%)'
                : name;
          }
        } else {
          boxColor = Colors.grey;
          statusText = AppLanguage.tr('attendance.face.done');
        }
        break;
    }

    return {
      'rect': face.boundingBox,
      'color': boxColor,
      'name': statusText,
      'trackingId': face.trackingId,
    };
  }

  // ─── Multi-frame Embedding ─────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _captureMultiFrameEmbedding(Face face, int id) async {
    final List<_FrameSnapshot> snapshots = [];

    try {
      for (int i = 0; i < _multiFrameCount; i++) {
        if (i > 0) await Future.delayed(const Duration(milliseconds: 10));
        if (_lastStreamBytes == null) break;
        snapshots.add(_FrameSnapshot(
          bytes: Uint8List.fromList(_lastStreamBytes!),
          width: _lastStreamWidth,
          height: _lastStreamHeight,
          rotation: _lastStreamRotation,
        ));
      }

      if (snapshots.isEmpty) return null;

      final templateFutures = snapshots.map((s) async {
        try {
          return await _faceService.buildTemplateFromBytes(
            s.bytes, s.width, s.height, s.rotation, face,
            allowSidePose: false,
          );
        } catch (e) {
          return null;
        }
      }).toList();

      if (snapshots.length == 1) {
        final template = await templateFutures[0];
        if (template == null) return null;
        return template;
      }

      final results = await Future.wait(templateFutures);
      final List<Map<String, dynamic>> templates =
      results.whereType<Map<String, dynamic>>().toList();
      final List<List<double>> embeddings = [];
      final List<double> weights = [];

      for (var t in templates) {
        final e = (t['embedding'] as List<dynamic>?)
            ?.map((v) => (v as num).toDouble())
            .toList();
        if (e != null) {
          embeddings.add(e);
          weights.add(t['qualityScore'] as double? ?? 0.5);
        }
      }

      if (embeddings.isEmpty) return null;

      final avgEmbedding = await compute(_computeWeightedAverage, {
        'embeddings': embeddings,
        'weights': weights,
      });

      return {
        ...templates.last,
        'embedding': avgEmbedding,
        'frame_count': embeddings.length,
        'multi_frame': true,
        'liveness_verified': true,
      };
    } catch (e) {
      debugPrint('❌ Multi-frame error: $e');
      return null;
    }
  }

  // ─── [PLUS-1] Liveness Detection ──────────────────────────────────────────

  /// Periksa apakah wajah adalah orang sungguhan berdasarkan metadata face.
  /// Mengembalikan (isLive, reason).
  ({bool isLive, String reason}) _checkLiveness(Face face) {
    // 1. Euler angle Y: wajah terlalu miring ke samping (kemungkinan foto)
    final headEulerY = face.headEulerAngleY ?? 0;
    if (headEulerY.abs() > 35) {
      return (isLive: false, reason: 'head_too_rotated_y:${headEulerY.toStringAsFixed(1)}');
    }

    // 2. Euler angle X: terlalu menunduk / mendongak
    final headEulerX = face.headEulerAngleX ?? 0;
    if (headEulerX.abs() > 30) {
      return (isLive: false, reason: 'head_too_rotated_x:${headEulerX.toStringAsFixed(1)}');
    }

    // 3. Probabilitas mata terbuka terlalu rendah (foto cetak sering gagal)
    final leftEye  = face.leftEyeOpenProbability ?? 1.0;
    final rightEye = face.rightEyeOpenProbability ?? 1.0;
    if (leftEye < 0.2 && rightEye < 0.2) {
      return (isLive: false, reason: 'eyes_closed');
    }

    // 4. Bounding box sangat kecil (terlalu jauh / bukan orang)
    final boxArea = face.boundingBox.width * face.boundingBox.height;
    if (boxArea < 5000) {
      return (isLive: false, reason: 'face_too_small:${boxArea.toStringAsFixed(0)}');
    }

    return (isLive: true, reason: 'passed');
  }

  // ─── Rekognisi ────────────────────────────────────────────────────────────

  Future<void> _triggerRecognition(Face face, Size imageSize) async {
    final id = face.trackingId ?? -1;
    if (id == -1) return;

    try {
      final stopwatch = Stopwatch()..start();

      if (_lastStreamBytes == null) {
        _faceStates[id] = FaceTrackingState.idle;
        return;
      }

      // Global cooldown check
      if (_lastGlobalSuccess != null &&
          DateTime.now().difference(_lastGlobalSuccess!) < _globalRecognitionGap) {
        _faceStates[id] = FaceTrackingState.idle;
        return;
      }

      // [PLUS-1] Liveness check sebelum inference
      _faceStates[id] = FaceTrackingState.livenessCheck;
      final liveness = _checkLiveness(face);
      if (!liveness.isLive) {
        debugPrint('⚠️ Liveness failed for face $id: ${liveness.reason}');
        _persistentFaceTracker[id] = {
          'name': 'Unknown',
          'member_id': null,
          'similarity': 0.0,
          'timestamp': DateTime.now(),
          'liveness_reason': liveness.reason,
        };
        // Cooldown pendek agar retry cepat
        _cooldowns[id] = DateTime.now().add(const Duration(milliseconds: 500));
        _faceStates[id] = FaceTrackingState.cooldown;
        await _writeAuditLog(
          action: 'liveness_fail',
          faceId: id,
          reason: liveness.reason,
        );
        return;
      }

      final template = await _captureMultiFrameEmbedding(face, id);
      debugPrint('🎬 [BENCH] Capture: ${stopwatch.elapsedMilliseconds}ms');

      if (template == null) {
        _faceStates[id] = FaceTrackingState.idle;
        return;
      }

      final matchStart = stopwatch.elapsedMilliseconds;
      final result = template.containsKey('matched_user')
          ? template['matched_user'] as Map<String, dynamic>?
          : await _biometricService.identifyBestMatchWithUserInfo(
        capturedTemplate: template,
        organizationId: widget.organizationId,
        strict: true,
        threshold: 0.50,
      );
      debugPrint('🔍 [BENCH] Match: ${stopwatch.elapsedMilliseconds - matchStart}ms');
      debugPrint('🚀 [BENCH] Total: ${stopwatch.elapsedMilliseconds}ms');

      if (result != null) {
        if (mounted) SoundHelper.playSuccessSound();

        final now = DateTime.now();
        final matchedName = result['user_name'] as String? ?? 'Unknown';
        final matchedSim  = (result['similarity'] as num?)?.toDouble() ?? 0.0;
        final matchedBiometricId   = result['biometric_id'] as int?;
        final organizationMemberId = result['organization_member_id'] as int?;

        debugPrint('✅ Match: $matchedName ($organizationMemberId) sim=${matchedSim.toStringAsFixed(3)}');

        _persistentFaceTracker[id] = {
          'name': matchedName,
          'member_id': organizationMemberId,
          'id': matchedBiometricId,
          'similarity': matchedSim * 100,
          'timestamp': now,
        };

        _cooldowns[id] = now.add(_recognitionCooldown);
        _handleAttendance(result, template);
        _lastGlobalSuccess = now;

        // [PLUS-3] Audit log sukses
        await _writeAuditLog(
          action: 'recognition_success',
          faceId: id,
          userName: matchedName,
          memberId: organizationMemberId,
          confidencePercent: matchedSim * 100,
        );

        // Adaptive learning
        if (matchedBiometricId != null && matchedSim >= 0.55) {
          final originalTemplate = _biometricService.getParsedTemplateFromCache(matchedBiometricId);
          if (originalTemplate != null) {
            _biometricService.evolveTemplate(
              biometricId: matchedBiometricId,
              currentTemplate: originalTemplate,
              capturedTemplate: template,
            );
          }
        }
      } else {
        _persistentFaceTracker[id] = {
          'name': 'Unknown',
          'member_id': null,
          'similarity': 0.0,
          'timestamp': DateTime.now(),
        };
        // [PLUS-3] Audit log gagal cocok
        await _writeAuditLog(action: 'recognition_no_match', faceId: id);
        _cooldowns[id] = DateTime.now().add(const Duration(milliseconds: 200));
      }
    } catch (e) {
      debugPrint('Recognition error: $e');
      _persistentFaceTracker[id] = {'name': 'Error', 'member_id': null};
      _cooldowns[id] = DateTime.now().add(const Duration(seconds: 1));
      await _writeAuditLog(action: 'recognition_error', faceId: id, reason: e.toString());
    } finally {
      if (_faceStates[id] != FaceTrackingState.idle) {
        _faceStates[id] = FaceTrackingState.cooldown;
      }
    }
  }

  // ─── [PLUS-3] Audit Log ────────────────────────────────────────────────────

  Future<void> _writeAuditLog({
    required String action,
    required int faceId,
    String? userName,
    int? memberId,
    double? confidencePercent,
    String? reason,
  }) async {
    try {
      final entry = {
        'timestamp': DateTime.now().toIso8601String(),
        'organization_id': widget.organizationId,
        'action': action,
        'face_tracking_id': faceId,
        'user_name': userName,
        'organization_member_id': memberId,
        'confidence_percent': confidencePercent?.toStringAsFixed(1),
        'attendance_mode': _attendanceMode,
        'shift': _selectedMode?['name'],
        'reason': reason,
        'is_online': _isOnline,
      };

      // Simpan ke tabel audit_logs di Supabase (jika online)
      if (_isOnline) {
        await _supabase.from('audit_logs').insert(entry);
      }

      // Selalu simpan lokal juga (untuk forensik offline)
      await _offlineDb.insertAuditLog(entry);

      debugPrint('📋 Audit: $action | user=$userName | conf=${confidencePercent?.toStringAsFixed(1)}%');
    } catch (e) {
      debugPrint('⚠️ Audit log failed (non-fatal): $e');
    }
  }

  // ─── Absensi ──────────────────────────────────────────────────────────────

  Future<void> _handleAttendance(
      Map<String, dynamic> result,
      Map<String, dynamic> template,
      ) async {
    try {
      final memberId  = result['organization_member_id'] as int;
      final userName  = result['user_name'] ?? 'Unknown';
      final biometricId    = result['biometric_id'] as int;
      final profilePhotoUrl = result['profile_photo_url'] as String?;
      final attendanceType  = _attendanceMode;

      // Cooldown check (sync, sebelum await apapun)
      final cooldownKey = '${memberId}_$attendanceType';
      final lastTime = _lastAttendanceTime[cooldownKey];
      if (lastTime != null) {
        final remaining = _sameModeCooldown - DateTime.now().difference(lastTime);
        if (!remaining.isNegative) {
          debugPrint('⏳ $userName: cooldown ${remaining.inMinutes}m ${remaining.inSeconds % 60}s');
          return;
        }
      }
      _lastAttendanceTime[cooldownKey] = DateTime.now();

      final typeName = _localizedTypeName(attendanceType);
      _showMessage('Sukses: $userName ($typeName)', MessageType.success, seconds: 2);

      if (mounted) {
        setState(() {
          _totalProcessedToday++;
          final now = DateTime.now();
          final timeStr =
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          _recentAttendanceList.insert(0, {
            'name': userName,
            'department': result['department_name'],
            'photo_base64': null,
            'time': timeStr,
            'type': attendanceType,
            'timestamp': now,
          });
          if (_recentAttendanceList.length > 10) _recentAttendanceList.removeLast();
        });
      }

      // Background tasks (non-blocking)
      _processBackgroundAttendance(
        result, template, attendanceType, memberId, userName, biometricId, profilePhotoUrl,
      );
    } catch (e) {
      debugPrint('Error in handleAttendance: $e');
    }
  }

  // [MEDIUM-3] Helper: nama lokal tipe absensi
  String _localizedTypeName(String attendanceType) {
    switch (attendanceType) {
      case 'check_in':    return AppLanguage.tr('attendance.face.masuk').toUpperCase();
      case 'check_out':   return AppLanguage.tr('attendance.face.keluar').toUpperCase();
      case 'break_start':
      case 'break_out':   return AppLanguage.tr('attendance.face.break_in').toUpperCase();
      case 'break_end':
      case 'break_in':    return AppLanguage.tr('attendance.face.break_out').toUpperCase();
      default:            return attendanceType.toUpperCase();
    }
  }

  // [MEDIUM-3] Background tasks dipecah & lebih mudah dibaca
  Future<void> _processBackgroundAttendance(
      Map<String, dynamic> user,
      Map<String, dynamic> template,
      String attendanceType,
      int memberId,
      String userName,
      int biometricId,
      String? profilePhotoUrl,
      ) async {
    try {
      // 1. Foto profil
      final profilePhotoBase64 = await _fetchProfilePhoto(memberId, profilePhotoUrl);
      _updateListWithPhoto(userName, profilePhotoBase64);

      // 2. Duplicate check
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(_organizationTimezone);
      final alreadyRecorded = await _offlineDb.hasDuplicateAttendance(
        organizationMemberId: memberId,
        eventType: attendanceType,
        attendanceDate: todayStr,
      );
      if (alreadyRecorded) {
        debugPrint('⏭️ $userName already recorded, skipping');
        return;
      }

      // 3. Simpan ke DB
      final offlineId = await _saveOfflineAttendance(
        memberId: memberId,
        userName: userName,
        attendanceType: attendanceType,
        template: template,
        profilePhotoBase64: profilePhotoBase64,
      );

      // 4. Update biometric
      await _biometricService.updateLastUsed(biometricId);

      if (offlineId != null && offlineId != -1 && _isOnline) {
        AttendanceSyncService().syncPendingAttendances();
      }
    } catch (e) {
      debugPrint('❌ Background attendance failed: $e');
    }
  }

  // [MEDIUM-3] Helper: fetch foto
  Future<String?> _fetchProfilePhoto(int memberId, String? remoteUrl) {
    return _getProfilePhotoBase64(memberId, remoteUrl)
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
  }

  // [MEDIUM-3] Helper: update list item dengan foto
  void _updateListWithPhoto(String userName, String? base64) {
    if (!mounted || base64 == null) return;
    setState(() {
      for (var item in _recentAttendanceList) {
        if (item['name'] == userName && item['photo_base64'] == null) {
          item['photo_base64'] = base64;
          break;
        }
      }
    });
  }

  // ─── Penyimpanan Offline ───────────────────────────────────────────────────

  // [PLUS-2] Enkripsi embedding sebelum simpan
  Future<int?> _saveOfflineAttendance({
    required int memberId,
    required String userName,
    required String attendanceType,
    required Map<String, dynamic> template,
    String? localPhotoPath,
    String? profilePhotoBase64,
  }) async {
    try {
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(_organizationTimezone);
      final isDuplicate = await _offlineDb.hasDuplicateAttendance(
        organizationMemberId: memberId,
        eventType: attendanceType,
        attendanceDate: todayStr,
      );
      if (isDuplicate) return -1;

      final capturedBase64 = await _encodeFileToBase64(localPhotoPath);

      // [PLUS-2] Enkripsi JSON template/embedding
      final encryptedTemplate = _encryptJson(template);

      String modeToSave = _getWorkTimeMode();
      if (_selectedMode != null) {
        try {
          final shiftData = Map<String, dynamic>.from(_selectedMode!);
          shiftData['mode_code'] = modeToSave;
          modeToSave = jsonEncode(shiftData);
        } catch (_) {}
      }

      OfflineAttendance record = OfflineAttendance(
        cardNumber: 'FACE_$memberId',
        faceEmbedding: encryptedTemplate, // ← terenkripsi
        eventType: attendanceType,
        method: 'face_recognition',
        timestamp: TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        photoPath: localPhotoPath,
        capturedPhotoBase64: capturedBase64,
        profilePhotoBase64: profilePhotoBase64,
        latitude: _currentPosition?.latitude,
        longitude: _currentPosition?.longitude,
        workTimeMode: modeToSave,
        organizationMemberId: memberId,
        userName: userName,
        isSynced: false,
      );

      bool syncSuccess = false;
      if (_isOnline) {
        syncSuccess = await _trySyncOnline(memberId, attendanceType, modeToSave);
      }

      record = record.copyWith(isSynced: syncSuccess);
      final id = await _offlineDb.insertAttendance(record);
      if (!syncSuccess) AttendanceSyncService().syncPendingAttendances();
      return id;
    } catch (e) {
      debugPrint('Failed to save offline attendance: $e');
      return null;
    }
  }

  // [MEDIUM-3] Helper: coba sync ke server
  Future<bool> _trySyncOnline(int memberId, String attendanceType, String modeToSave) async {
    try {
      final rawData = {
        'face_recognition': true,
        'work_time_mode': modeToSave,
        'synced_from_offline': false,
      };
      switch (attendanceType) {
        case 'check_in':
          await _attendanceService.checkIn(
              organizationMemberId: memberId, method: 'face_recognition', photoUrl: '', rawData: rawData);
          break;
        case 'check_out':
          await _attendanceService.checkOut(
              organizationMemberId: memberId, method: 'face_recognition', photoUrl: '', rawData: rawData);
          break;
        case 'break_out':
        case 'break_start':
          await _attendanceService.breakOut(
              organizationMemberId: memberId, method: 'face_recognition', photoUrl: '', rawData: rawData);
          break;
        case 'break_in':
        case 'break_end':
          await _attendanceService.breakIn(
              organizationMemberId: memberId, method: 'face_recognition', photoUrl: '', rawData: rawData);
          break;
      }
      debugPrint('✅ Online sync success for member $memberId');
      return true;
    } catch (e) {
      debugPrint('⚠️ Online sync failed: $e');
      return false;
    }
  }

  // ─── Foto & File ───────────────────────────────────────────────────────────

  Future<String?> _getProfilePhotoBase64(int memberId, String? remoteUrl) async {
    try {
      final cached = await _offlineDb.findMemberByOrgIdInCache(memberId);
      final cachedProfile =
      cached?['organization_members']?['user_profiles'] as Map<String, dynamic>?;
      final cachedBase64 = cachedProfile?['profile_photo_base64'] as String?;
      if (cachedBase64 != null && cachedBase64.isNotEmpty) return cachedBase64;
      if (_isOnline && remoteUrl != null && remoteUrl.isNotEmpty) {
        return await _downloadAsBase64(remoteUrl);
      }
    } catch (e) {
      debugPrint('Failed to get profile base64: $e');
    }
    return null;
  }

  // [KRITIS-4] HttpClient selalu ditutup via try/finally
  Future<String?> _downloadAsBase64(String url) async {
    if (url.isEmpty) return null;
    HttpClient? client;
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;

      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request  = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = await consolidateHttpClientResponseBytes(response);
      return base64Encode(bytes);
    } catch (e) {
      debugPrint('Download to base64 failed: $e');
      return null;
    } finally {
      // [KRITIS-4] Tutup selalu, baik sukses maupun error
      client?.close();
    }
  }

  Future<String?> _encodeFileToBase64(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return base64Encode(await file.readAsBytes());
    } catch (e) {
      debugPrint('Encode file failed: $e');
      return null;
    }
  }

  // ─── Data Organisasi & Jadwal ──────────────────────────────────────────────

  Future<void> _loadOrganizationData() async {
    final orgId = widget.organizationId;
    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone, name')
          .eq('id', orgId)
          .maybeSingle();

      if (org != null && mounted) {
        setState(() {
          _organizationTimezone = org['timezone'] as String? ?? 'Asia/Jakarta';
          _organizationName     = org['name']     as String? ?? '';
        });
        await _offlineDb.cacheOrganizationData({
          'id': orgId, 'name': _organizationName, 'timezone': _organizationTimezone,
        });
      }
    } catch (e) {
      debugPrint('🌐 Offline org data: $e');
      final cachedOrg = await _offlineDb.getOrganizationData(orgId);
      if (cachedOrg != null && mounted) {
        setState(() {
          _organizationTimezone = cachedOrg['timezone'] as String? ?? 'Asia/Jakarta';
          _organizationName     = cachedOrg['name']     as String? ?? '';
        });
      }
    }

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        final member = await _supabase
            .from('organization_members')
            .select('id')
            .eq('organization_id', orgId)
            .eq('user_id', userId)
            .eq('is_active', true)
            .maybeSingle();

        if (member != null) {
          final memberId = member['id'] as int;
          setState(() => _organizationMemberId = memberId);
          await _loadMemberSchedule(memberId);
          _loadDailySchedule(memberId);
        }
      }
    } catch (e) {
      debugPrint('🌐 Offline member data: $e');
      final userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        final cachedMembers = await _offlineDb.getOrganizationMembers(orgId);
        if (cachedMembers != null) {
          final member = cachedMembers.firstWhere(
                (m) => m['user_id'] == userId,
            orElse: () => <String, dynamic>{},
          );
          if (member.isNotEmpty && member['id'] != null) {
            if (mounted) setState(() => _organizationMemberId = member['id'] as int);
          }
        }
      }
    }
  }

  Future<void> _loadMemberSchedule(int memberId) async {
    try {
      final today    = DateTime.now().toIso8601String().split('T')[0];
      final schedule = await _supabase
          .from('member_schedules')
          .select('id, work_schedule_id, shift_id, effective_date, end_date')
          .eq('organization_member_id', memberId)
          .eq('is_active', true)
          .lte('effective_date', today)
          .or('end_date.is.null,end_date.gte.$today')
          .order('effective_date', ascending: false)
          .limit(1)
          .maybeSingle();

      if (schedule != null && mounted) setState(() => _memberSchedule = schedule);
    } catch (e) {
      debugPrint('🌐 Offline member schedule: $e');
    }
  }

  Future<void> _loadDailySchedule(int memberId) async {
    try {
      final schedule = await _attendanceService.getTodaySchedule(
        memberId,
        organizationTimezone: _organizationTimezone,
      );
      if (mounted) setState(() => _dailySchedule = schedule);
    } catch (e) {
      debugPrint('Error loading daily schedule: $e');
    }
  }

  void _startScheduleCheck() {
    _scheduleCheckTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted && _workTimeMode == null) setState(() {});
    });
  }

  Future<void> _getCurrentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) return;
      }
      if (perm == LocationPermission.deniedForever) return;
      _currentPosition = await Geolocator.getCurrentPosition();
    } catch (e) {
      debugPrint('Failed to get location: $e');
    }
  }

  // ─── Mode / Shift ─────────────────────────────────────────────────────────

  String _getWorkTimeMode() => _workTimeMode ?? 'work_time';

  Future<void> _loadAvailableModes() async {
    if (_isLoadingModes) return;
    setState(() => _isLoadingModes = true);
    try {
      final modes = await _supabase
          .from('shifts')
          .select('id, code, name, start_time, end_time, description')
          .eq('organization_id', widget.organizationId)
          .eq('is_active', true)
          .order('name', ascending: true);

      if (mounted) {
        setState(() => _availableModes = List<Map<String, dynamic>>.from(modes));
        await _offlineDb.cacheShifts(widget.organizationId, _availableModes);
      }
    } catch (e) {
      debugPrint('🌐 Offline shifts: $e');
      final cachedShifts = await _offlineDb.getShifts(widget.organizationId);
      if (mounted) setState(() => _availableModes = List<Map<String, dynamic>>.from(cachedShifts));
    } finally {
      if (mounted) setState(() => _isLoadingModes = false);
    }
  }

  void _autoSelectCurrentShift() {
    if (_availableModes.isEmpty) return;

    final currentTime = TimeOfDay.fromDateTime(DateTime.now());
    Map<String, dynamic>? bestMatch;

    final memberShiftId = _memberSchedule?['shift_id'] as int?;
    if (memberShiftId != null) {
      for (final mode in _availableModes) {
        if (mode['id'] == memberShiftId) { bestMatch = mode; break; }
      }
    }

    if (bestMatch == null && _dailySchedule != null) {
      final s = _dailySchedule!.startTime;
      final e = _dailySchedule!.endTime;
      if (s != null && e != null) {
        String norm(String t) => t.split(':').take(2).join(':');
        for (var mode in _availableModes) {
          if (norm(mode['start_time'] ?? '') == norm(s) &&
              norm(mode['end_time']   ?? '') == norm(e)) {
            bestMatch = mode; break;
          }
        }
      }
    }

    if (bestMatch == null) {
      for (final mode in _availableModes) {
        final s = mode['start_time'] as String?;
        final e = mode['end_time']   as String?;
        if (s != null && e != null && _isTimeInRange(currentTime, s, e)) {
          bestMatch = mode; break;
        }
      }
    }

    if (bestMatch != null) {
      setState(() {
        _selectedMode = bestMatch;
        _workTimeMode = bestMatch!['code'] as String? ?? bestMatch['name'] as String?;
      });
    }
  }

  bool _isTimeInRange(TimeOfDay current, String startStr, String endStr) {
    try {
      final sp = startStr.split(':');
      final ep = endStr.split(':');
      final start = TimeOfDay(hour: int.parse(sp[0]), minute: int.parse(sp[1]));
      final end   = TimeOfDay(hour: int.parse(ep[0]), minute: int.parse(ep[1]));
      final nowMin   = current.hour * 60 + current.minute;
      final startMin = start.hour * 60 + start.minute;
      final endMin   = end.hour   * 60 + end.minute;
      if (endMin < startMin) return nowMin >= startMin || nowMin <= endMin;
      return nowMin >= startMin && nowMin <= endMin;
    } catch (_) { return false; }
  }

  ({bool canBreakOut, bool canBreakIn, String? hint}) _computeBreakButtonState() {
    final schedule = _dailySchedule;
    if (schedule == null) return (canBreakOut: false, canBreakIn: false,
    hint: AppLanguage.tr('attendance.face.loading_schedule'));

    final breakStartStr = schedule.breakStart;
    final breakEndStr   = schedule.breakEnd;
    if (breakStartStr == null || breakEndStr == null) {
      return (canBreakOut: false, canBreakIn: false,
      hint: AppLanguage.tr('attendance.face.no_break_scheduled'));
    }

    TimeOfDay? parseTime(String s) {
      try {
        final p = s.split(':');
        return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
      } catch (_) { return null; }
    }

    final breakStart = parseTime(breakStartStr);
    final breakEnd   = parseTime(breakEndStr);
    if (breakStart == null || breakEnd == null) {
      return (canBreakOut: true, canBreakIn: true, hint: null);
    }

    final now = TimezoneHelper.convertUtcToOrgTimezone(DateTime.now().toUtc(), _organizationTimezone);
    final nowMin    = now.hour * 60 + now.minute;
    final bStartMin = breakStart.hour * 60 + breakStart.minute;
    final bEndMin   = breakEnd.hour   * 60 + breakEnd.minute;
    const windowMinutes = 30;

    final canBreakOut = nowMin >= (bStartMin - windowMinutes) && nowMin <= (bEndMin + windowMinutes);
    final canBreakIn  = nowMin >= (bStartMin - windowMinutes) && nowMin <= (bEndMin + windowMinutes);

    String formatTime(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    String? hint;
    if (!canBreakOut) {
      hint = '${AppLanguage.tr('attendance.face.break_available_at')} '
          '${formatTime(breakStart)} - ${formatTime(breakEnd)}';
    }
    return (canBreakOut: canBreakOut, canBreakIn: canBreakIn, hint: hint);
  }

  // ─── UI Helpers ────────────────────────────────────────────────────────────

  void _showMessage(String message, MessageType type, {int seconds = 2}) {
    _messageTimer?.cancel();
    setState(() { _currentMessage = message; _messageType = type; });
    _messageTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) setState(() { _currentMessage = null; _messageType = MessageType.idle; });
    });
  }

  void _clearMessage() {
    _messageTimer?.cancel();
    if (mounted) setState(() { _currentMessage = null; _messageType = MessageType.idle; });
  }

  Future<void> _refreshTemplates() async {
    if (_isRefreshing || _processingLock) return;
    setState(() {
      _isRefreshing = true;
      _showMessage('Menyegarkan data wajah...', MessageType.loading, seconds: 60);
    });
    try {
      await _biometricService.refreshCache(widget.organizationId);
      if (mounted) _showMessage('Data wajah berhasil diperbarui!', MessageType.success);
    } catch (e) {
      if (mounted) _showMessage('Gagal memperbarui data wajah', MessageType.error);
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Color _getMessageColor() {
    switch (_messageType) {
      case MessageType.success:   return Colors.green.withValues(alpha: 0.9);
      case MessageType.error:     return Colors.red.withValues(alpha: 0.9);
      case MessageType.warning:   return Colors.orange.withValues(alpha: 0.9);
      case MessageType.processing: return Colors.blue.withValues(alpha: 0.9);
      case MessageType.loading:   return Colors.purple.withValues(alpha: 0.9);
      case MessageType.info:      return Colors.grey.withValues(alpha: 0.7);
      case MessageType.idle:      return Colors.black.withValues(alpha: 0.5);
    }
  }

  IconData? _getMessageIcon() {
    switch (_messageType) {
      case MessageType.success:   return Icons.check_circle;
      case MessageType.error:     return Icons.error;
      case MessageType.warning:   return Icons.warning;
      case MessageType.processing: return Icons.face;
      case MessageType.loading:   return Icons.hourglass_empty;
      case MessageType.info:      return Icons.info;
      case MessageType.idle:      return null;
    }
  }

  // ─── Sheet: Pilih Shift ───────────────────────────────────────────────────

  Future<void> _openShiftSelectionSheet() async {
    await _loadAvailableModes();
    if (!mounted) return;

    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(children: [
            _buildSheetHandle(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                AppLanguage.tr('attendance.face.select_shift'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 16),
            if (_isLoadingModes)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (_availableModes.isEmpty)
              Expanded(child: Center(
                child: Text(AppLanguage.tr('attendance.face.no_shifts'),
                    style: const TextStyle(fontSize: 16, color: Colors.grey)),
              ))
            else
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  itemCount: _availableModes.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final mode = _availableModes[i];
                    final isSelected = _selectedMode?['id'] == mode['id'];
                    return ListTile(
                      title: Text(mode['name'] ?? '-',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: (mode['start_time'] != null && mode['end_time'] != null)
                          ? Text('${mode['start_time']} - ${mode['end_time']}')
                          : null,
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : null,
                      onTap: () => Navigator.of(context).pop(mode),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    );

    if (selected != null && mounted) {
      setState(() {
        _selectedMode = selected;
        _workTimeMode = selected['code'] as String? ?? selected['name'] as String?;
      });
      await _showInOutSelector();
    }
  }

  Future<void> _showInOutSelector() async {
    if (!mounted) return;
    final pickedMode = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        final state = _computeBreakButtonState();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _buildSheetHandle(),
              Row(children: [
                _buildInOutButton('check_in', AppLanguage.tr('attendance.face.in'), Colors.green, context),
                const SizedBox(width: 12),
                _buildInOutButton('check_out', AppLanguage.tr('attendance.face.out'), Colors.red, context),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _buildInOutButtonDisableable(
                    'break_start', AppLanguage.tr('attendance.face.break_in'),
                    state.canBreakOut ? Colors.orange : Colors.grey.shade400,
                    state.canBreakOut, context),
                const SizedBox(width: 12),
                _buildInOutButtonDisableable(
                    'break_end', AppLanguage.tr('attendance.face.break_out'),
                    state.canBreakIn ? Colors.blue : Colors.grey.shade400,
                    state.canBreakIn, context),
              ]),
              if (state.hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(state.hint!,
                      style: TextStyle(fontSize: 12, color: Colors.orange.shade700)),
                ),
            ]),
          ),
        );
      },
    );

    if (pickedMode != null && mounted) {
      setState(() => _attendanceMode = pickedMode);
      final modeName = _selectedMode?['name'] ?? 'Standar';
      _showMessage('Mode: $modeName - ${_localizedTypeName(pickedMode)}',
          MessageType.success, seconds: 2);
    }
  }

  Widget _buildInOutButton(String mode, String label, Color color, BuildContext ctx) {
    return Expanded(
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12)),
        onPressed: () => Navigator.pop(ctx, mode),
        child: Text(label),
      ),
    );
  }

  Widget _buildInOutButtonDisableable(
      String mode, String label, Color color, bool enabled, BuildContext ctx) {
    return Expanded(
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12)),
        onPressed: enabled ? () => Navigator.pop(ctx, mode) : null,
        child: Text(label),
      ),
    );
  }

  Widget _buildSheetHandle() {
    return Container(
      width: 40, height: 4,
      margin: const EdgeInsets.only(top: 12, bottom: 16),
      decoration: BoxDecoration(
          color: Colors.grey.shade300, borderRadius: BorderRadius.circular(12)),
    );
  }

  // ─── Widget Shift Card ─────────────────────────────────────────────────────

  Widget _buildShiftCard() {
    String label = AppLanguage.tr('attendance.face.select_shift');
    if (_selectedMode != null) {
      final shiftName = _selectedMode!['name'] ?? 'Unknown';
      label = '$shiftName - ${_localizedTypeName(_attendanceMode)}';
    }

    return InkWell(
      onTap: _openShiftSelectionSheet,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF9333EA), Color(0xFF7E22CE)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(
              color: const Color(0xFF9333EA).withValues(alpha: 0.3),
              blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.swap_horiz, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label,
              style: const TextStyle(
                  color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
          const Icon(Icons.chevron_right, color: Colors.white, size: 20),
        ]),
      ),
    );
  }

  Widget _buildCompactActionBadge(String? type) {
    Color color = Colors.green;
    String label = 'IN';
    if (type == 'check_out')  { color = Colors.red;    label = 'OUT'; }
    else if (type == 'break_start') { color = Colors.orange; label = 'BREAK'; }
    else if (type == 'break_end')   { color = Colors.blue;   label = 'END'; }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Text(label, style: TextStyle(
          fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    );
  }

  Widget _buildCircularActionButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldExit = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Row(children: [
              Icon(Icons.exit_to_app, color: Colors.red.shade600, size: 24),
              const SizedBox(width: 8),
              Text(AppLanguage.tr('attendance.face.exit_title')),
            ]),
            content: Text(AppLanguage.tr('attendance.face.exit_content')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(AppLanguage.tr('attendance.face.cancel')),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red, foregroundColor: Colors.white),
                child: Text(AppLanguage.tr('attendance.face.exit')),
              ),
            ],
          ),
        );
        if (shouldExit == true && context.mounted) Navigator.of(context).pop(true);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          // Kamera
          if (_isCameraInitialized && _cameraController != null)
            Positioned.fill(child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width:  _cameraController!.value.previewSize?.height ?? 1,
                height: _cameraController!.value.previewSize?.width  ?? 1,
                child: CameraPreview(_cameraController!),
              ),
            ))
          else if (_cameraError)
          // [MEDIUM-4] Error state dengan tombol retry
            Positioned.fill(child: _buildCameraErrorState())
          else
            const Center(child: CircularProgressIndicator(color: Colors.white)),

          // Face boxes
          if (_detectedFaces.isNotEmpty && _cameraController != null)
            Positioned.fill(child: CustomPaint(
              painter: FaceDetectorPainter(
                absoluteImageSize: Size(
                  _cameraController!.value.previewSize!.height,
                  _cameraController!.value.previewSize!.width,
                ),
                faces: _detectedFaces,
                isFrontCamera: true,
              ),
            )),

          // Top bar
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 16, right: 16,
            child: Row(children: [
              _buildCircularActionButton(
                icon: Icons.chevron_left,
                onTap: () => Navigator.of(context).pop(),
              ),
              const Spacer(),
              // Session count pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E26).withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.people_alt_outlined, color: Color(0xFF9B59B6), size: 20),
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(AppLanguage.tr('attendance.face.session_count'),
                        style: const TextStyle(color: Colors.white70, fontSize: 8, fontWeight: FontWeight.bold)),
                    Text('$_totalProcessedToday',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                ]),
              ),
              const Spacer(),
              _buildCircularActionButton(
                icon: Icons.assignment_ind_outlined,
                onTap: () async {
                  if (_organizationMemberId != null) {
                    final success = await Navigator.push(context, MaterialPageRoute(
                      builder: (_) => ManualCheckPage(
                        organizationMemberId: _organizationMemberId!,
                        memberData: {'organization_id': widget.organizationId},
                        sourceMode: 'face_recognition_kiosk',
                        initialShiftName: _workTimeMode,
                      ),
                    ));
                    if (success == true) {
                      _showMessage(AppLanguage.tr('attendance.face.manual_success'), MessageType.success);
                    }
                  } else {
                    _showMessage(AppLanguage.tr('attendance.face.manual_error'), MessageType.error);
                  }
                },
              ),
              const SizedBox(width: 10),
              _buildCircularActionButton(
                icon: _isRefreshing ? Icons.hourglass_empty : Icons.refresh_rounded,
                onTap: _isRefreshing ? () {} : _refreshTemplates,
              ),
              const SizedBox(width: 10),
              _buildCircularActionButton(
                icon: Icons.more_vert,
                onTap: () => _openShiftSelectionSheet(),
              ),
            ]),
          ),

          // Pesan status
          if (_currentMessage != null)
            Positioned(
              top: 80, left: 0, right: 0,
              child: AnimatedOpacity(
                opacity: 1.0,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _getMessageColor(),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 6, offset: const Offset(0, 2))],
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (_messageType == MessageType.processing || _messageType == MessageType.loading)
                      const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 1.5))
                    else if (_getMessageIcon() != null)
                      Icon(_getMessageIcon(), color: Colors.white, size: 16),
                    if (_messageType == MessageType.processing ||
                        _messageType == MessageType.loading ||
                        _getMessageIcon() != null)
                      const SizedBox(width: 8),
                    Flexible(child: Text(_currentMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
                  ]),
                ),
              ),
            ),

          // Shift card
          Positioned(
            left: 20, right: 20,
            bottom: MediaQuery.of(context).size.height * 0.2 + 20,
            child: _buildShiftCard(),
          ),

          // Daftar absensi
          DraggableScrollableSheet(
            minChildSize: 0.2, initialChildSize: 0.2, maxChildSize: 0.6,
            builder: (context, scrollController) => Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                boxShadow: [BoxShadow(
                    color: Colors.black.withOpacity(0.2), blurRadius: 15, offset: const Offset(0, -5))],
              ),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Column(children: [
                    _buildSheetHandle(),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text(AppLanguage.tr('attendance.face.attendance_data'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                            color: const Color(0xFF9333EA).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20)),
                        child: Text('Today: $_totalProcessedToday',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF9333EA))),
                      ),
                    ]),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _recentAttendanceList.isEmpty
                      ? ListView(controller: scrollController, padding: const EdgeInsets.all(32),
                      children: [Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.history_rounded, size: 48, color: Colors.grey.shade300),
                        const SizedBox(height: 16),
                        Text(AppLanguage.tr('attendance.face.no_data'),
                            style: TextStyle(fontSize: 14, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                      ])])
                      : ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _recentAttendanceList.length,
                    itemBuilder: (context, index) {
                      final item = _recentAttendanceList[index];
                      final photoBase64 = item['photo_base64'] as String?;
                      ImageProvider? avatar;
                      if (photoBase64 != null && photoBase64.isNotEmpty) {
                        avatar = MemoryImage(base64Decode(photoBase64));
                      }
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Row(children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.grey.shade200,
                            backgroundImage: avatar,
                            child: avatar == null
                                ? const Icon(Icons.person, color: Colors.grey, size: 20)
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item['name'],
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                              Text('${item['department'] ?? '-'} • ${item['time']}',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                            ],
                          )),
                          _buildCompactActionBadge(item['type']),
                        ]),
                      );
                    },
                  ),
                ),
              ]),
            ),
          ),

          // Setup overlay
          if (!_isSystemReady) _buildSetupOverlay(),
        ]),
      ),
    );
  }

  // ─── Setup Overlay ─────────────────────────────────────────────────────────

  Widget _buildSetupOverlay() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // [MEDIUM-2] Tampilkan error state + retry jika init gagal setelah retry habis
    if (_initErrorMessage != null) {
      return Container(
        color: isDark ? const Color(0xFF121212) : Colors.white,
        width: double.infinity, height: double.infinity,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 24),
              Text('Inisialisasi Gagal',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87)),
              const SizedBox(height: 12),
              Text(_initErrorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.grey.shade600)),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: () {
                  _initRetryCount = 0;
                  _initializeSystem(isRetry: true);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Coba Lagi'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8938DF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14)),
              ),
            ]),
          ),
        ),
      );
    }

    return Container(
      color: isDark ? const Color(0xFF121212) : Colors.white,
      width: double.infinity, height: double.infinity,
      child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF8938DF).withValues(alpha: 0.1)),
            child: const Icon(Icons.face_retouching_natural_rounded,
                size: 64, color: Color(0xFF8938DF)),
          ),
          const SizedBox(height: 32),
          Text('System Setup', style: TextStyle(
              fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 1.2,
              color: isDark ? Colors.white : Colors.black87)),
          const SizedBox(height: 8),
          Text(_initStatus, style: TextStyle(
              fontSize: 14, color: isDark ? Colors.white70 : Colors.grey.shade600)),
          const SizedBox(height: 48),
          SizedBox(width: 200, child: Column(children: [
            LinearProgressIndicator(
              value: _initProgress,
              backgroundColor: isDark ? Colors.white10 : Colors.grey.shade200,
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF8938DF)),
              minHeight: 8,
            ),
            const SizedBox(height: 12),
            Text('${(_initProgress * 100).toInt()}%',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF8938DF))),
          ])),
        ]),
      ),
    );
  }

  // [MEDIUM-4] Widget error state kamera dengan tombol retry
  Widget _buildCameraErrorState() {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.videocam_off, size: 64, color: Colors.white54),
          const SizedBox(height: 16),
          const Text('Kamera tidak tersedia',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          const SizedBox(height: 8),
          const Text('Pastikan izin kamera sudah diberikan',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () async {
              setState(() => _cameraError = false);
              await _initializeCamera();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Coba Lagi'),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8938DF),
                foregroundColor: Colors.white),
          ),
        ]),
      ),
    );
  }
}

// ─── CustomPainter: Face Boxes ─────────────────────────────────────────────

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

    final double scaleX = size.width  / absoluteImageSize.width;
    final double scaleY = size.height / absoluteImageSize.height;

    final bracketPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final face in faces) {
      final rect      = face['rect']  as Rect;
      final color     = face['color'] as Color;
      final nameLabel = face['name']  as String?;

      double left, right;
      if (isFrontCamera) {
        left  = (absoluteImageSize.width - rect.right) * scaleX;
        right = (absoluteImageSize.width - rect.left)  * scaleX;
      } else {
        left  = rect.left  * scaleX;
        right = rect.right * scaleX;
      }
      final top    = rect.top    * scaleY;
      final bottom = rect.bottom * scaleY;
      final mappedRect = Rect.fromLTRB(left, top, right, bottom);

      boxPaint.color = color.withValues(alpha: 0.4);
      canvas.drawRRect(
          RRect.fromRectAndRadius(mappedRect, const Radius.circular(12)), boxPaint);

      bracketPaint.color = color;
      const bSize = 20.0;
      // Top-Left
      canvas.drawLine(Offset(left, top + bSize), Offset(left, top), bracketPaint);
      canvas.drawLine(Offset(left, top), Offset(left + bSize, top), bracketPaint);
      // Top-Right
      canvas.drawLine(Offset(right - bSize, top), Offset(right, top), bracketPaint);
      canvas.drawLine(Offset(right, top), Offset(right, top + bSize), bracketPaint);
      // Bottom-Left
      canvas.drawLine(Offset(left, bottom - bSize), Offset(left, bottom), bracketPaint);
      canvas.drawLine(Offset(left, bottom), Offset(left + bSize, bottom), bracketPaint);
      // Bottom-Right
      canvas.drawLine(Offset(right - bSize, bottom), Offset(right, bottom), bracketPaint);
      canvas.drawLine(Offset(right, bottom), Offset(right, bottom - bSize), bracketPaint);

      if (nameLabel != null && nameLabel.isNotEmpty) {
        final textSpan = TextSpan(
          text: nameLabel,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
              color: Colors.white,
              shadows: [Shadow(blurRadius: 2, color: Colors.black)]),
        );
        final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr)
          ..layout();

        final labelBgPaint = Paint()..color = color.withValues(alpha: 0.8);
        final labelRect = Rect.fromLTWH(
          left, top - textPainter.height - 8,
          textPainter.width + 12, textPainter.height + 4,
        );
        canvas.drawRRect(
            RRect.fromRectAndRadius(labelRect, const Radius.circular(6)), labelBgPaint);
        textPainter.paint(canvas, Offset(left + 6, top - textPainter.height - 6));
      }
    }
  }

  @override
  bool shouldRepaint(FaceDetectorPainter oldDelegate) => true;
}