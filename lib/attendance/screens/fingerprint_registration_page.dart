// lib/attendance/screens/fingerprint_registration_page.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/fingerprint_service.dart';
import '../services/biometric_service.dart';
import '../../helpers/language_helper.dart';

class FingerprintRegistrationPage extends StatefulWidget {
  final int organizationMemberId;
  final String? memberName;

  const FingerprintRegistrationPage({
    super.key,
    required this.organizationMemberId,
    this.memberName,
  });

  @override
  State<FingerprintRegistrationPage> createState() =>
      _FingerprintRegistrationPageState();
}

class _FingerprintRegistrationPageState
    extends State<FingerprintRegistrationPage>
    with SingleTickerProviderStateMixin {
  final FingerprintService _fingerprintService = FingerprintService();
  final BiometricService _biometricService = BiometricService();

  String _instructionText = AppLanguage.tr(
    'attendance.fingerprint.start_instruction',
  );
  Uint8List? _currentImage;
  bool _isScannerStarted = false;
  bool _isRegistering = false;
  int _registrationStep = 0; // 0: Idle, 1, 2, 3: Scans

  AnimationController? _pulseController;
  StreamSubscription? _statusSubscription;
  StreamSubscription? _imageSubscription;
  StreamSubscription? _registerSubscription;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _initScanner();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _imageSubscription?.cancel();
    _registerSubscription?.cancel();
    _pulseController?.dispose();
    _fingerprintService.stopScanner();
    _fingerprintService.dispose();
    super.dispose();
  }

  Future<void> _initScanner() async {
    if (!mounted) return;
    setState(() {
      _isScannerStarted = false;
      _instructionText = "Menghubungkan ke scanner...";
    });

    try {
      debugPrint('🔌 Requesting USB Permission...');
      final hasPermission = await _fingerprintService.requestPermission();
      
      if (!hasPermission) {
        if (mounted) {
          setState(() {
            _instructionText = "❌ Izin USB ditolak. Cabut dan colok kembali USB.";
          });
        }
        return;
      }

      _statusSubscription?.cancel();
      _statusSubscription = _fingerprintService.statusStream.listen((status) {
        if (mounted) {
          debugPrint('🔍 Fingerprint Status: $status');
          setState(() => _handleStatusUpdates(status));
        }
      });

      _imageSubscription?.cancel();
      _imageSubscription = _fingerprintService.imageStream.listen((image) {
        if (mounted) setState(() => _currentImage = image);
      });

      _registerSubscription?.cancel();
      _registerSubscription = _fingerprintService.registerSuccessStream.listen((template) async {
        if (mounted) {
          setState(() {
            _registrationStep = 3;
            _isRegistering = false;
            _instructionText = AppLanguage.tr('attendance.fingerprint.berhasil_selesai');
          });
          await _saveFingerprintTemplate(template);
        }
      });

      debugPrint('🎬 Starting Fingerprint Scanner Hardware...');
      final result = await _fingerprintService.startScanner().timeout(
        const Duration(seconds: 5),
        onTimeout: () => 'timeout',
      );

      if (result == 'success') {
        if (mounted) {
          setState(() {
            _isScannerStarted = true;
            _instructionText = "Scanner Siap. Silakan klik Mulai.";
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isScannerStarted = false;
            _instructionText = result == 'timeout' 
              ? "⏳ Koneksi melambat. Pastikan Anda sudah klik 'OK' pada pop-up USB." 
              : "❌ Gagal: $result. Cek kabel OTG.";
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isScannerStarted = false;
          _instructionText = "❌ Error sistem: $e";
        });
      }
    }
  }

  void _handleStatusUpdates(String status) {
    final lowerStatus = status.toLowerCase();

    // Ignore transient capture/extract errors during active registration unless terminal
    if (_isRegistering &&
        (lowerStatus.contains('capture error') ||
            lowerStatus.contains('extract error'))) {
      if (lowerStatus.contains('not found')) {
        _instructionText = 'Scanner terputus. Pastikan kabel terpasang.';
        _isRegistering = false;
      }
      return;
    }

    if (status.contains('Press finger')) {
      if (status.contains('1/3')) {
        _registrationStep = 1;
        _instructionText = AppLanguage.tr('attendance.fingerprint.step_1');
      } else if (status.contains('2/3')) {
        _registrationStep = 2;
        _instructionText = AppLanguage.tr('attendance.fingerprint.step_2');
      } else if (status.contains('3/3')) {
        _registrationStep = 3;
        _instructionText = AppLanguage.tr('attendance.fingerprint.step_3');
      } else {
        if (_registrationStep == 0) _registrationStep = 1;
        _instructionText = AppLanguage.tr(
          'attendance.fingerprint.place_finger',
        );
      }
    } else if (status.contains('Lift finger')) {
      _instructionText = AppLanguage.tr('attendance.fingerprint.lift_finger');
    } else if (status.contains('Registration successful')) {
      _instructionText = AppLanguage.tr(
        'attendance.fingerprint.berhasil_selesai',
      );
      _registrationStep = 3;
    } else if (status.contains('already enrolled')) {
      _instructionText = AppLanguage.tr(
        'attendance.fingerprint.already_enrolled',
      );
      _isRegistering = false;
    } else if (status.contains('Please press same finger')) {
      _instructionText = AppLanguage.tr(
        'attendance.fingerprint.not_same_finger',
      );
      _isRegistering = false;
      _registrationStep = 0;
    } else if (lowerStatus.contains('failed')) {
      if (lowerStatus.contains('enroll') ||
          lowerStatus.contains('merge') ||
          lowerStatus.contains('save')) {
        _instructionText = AppLanguage.tr(
          'attendance.fingerprint.registration_failed',
        );
        _isRegistering = false;
        _registrationStep = 0;
      }
    }
  }

  Future<void> _startRegistration() async {
    if (!_isScannerStarted) return;
    setState(() {
      _isRegistering = true;
      _registrationStep = 1;
      _instructionText = 'Scan jari anda pada scanner (Langkah 1 dari 3)';
    });
    await _fingerprintService.register(widget.organizationMemberId.toString());
  }

  Future<void> _saveFingerprintTemplate(String templateData) async {
    try {
      setState(
        () =>
            _instructionText = AppLanguage.tr('attendance.fingerprint.saving'),
      );
      await _biometricService.registerFingerprintTemplate(
        organizationMemberId: widget.organizationMemberId,
        templateBase64: templateData,
      );
      if (mounted) _showSuccessDialog();
    } catch (e) {
      if (mounted) {
        setState(
          () => _instructionText =
              '${AppLanguage.tr('attendance.fingerprint.registration_failed')}: $e',
        );
      }
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        // Auto close after 2 seconds
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            Navigator.of(context).pop(); // Close dialog
            Navigator.of(
              context,
            ).pop(true); // Return to previous page with success
          }
        });

        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Center(
            child: Text(
              AppLanguage.tr('attendance.fingerprint.success'),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 22,
                color: Colors.green,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          AppLanguage.tr('attendance.fingerprint.registration_title'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF4A1E79),
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            children: [
              const SizedBox(height: 10),
              if (widget.memberName != null)
                Text(
                  widget.memberName!,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2D1152),
                  ),
                ),

              const Spacer(),

              // STEP INDICATOR
              if (_isRegistering) _buildStepIndicator(),

              const SizedBox(height: 10),

              // FINGERPRINT PREVIEW AREA
              _buildFpPreview(),

              const SizedBox(height: 15),

              // INSTRUCTION TEXT (Large & Bold)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A1E79).withOpacity(0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFF4A1E79).withOpacity(0.1),
                  ),
                ),
                child: Text(
                  _instructionText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF4A1E79),
                  ),
                ),
              ),

              if (!_isScannerStarted && !_isRegistering)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextButton.icon(
                    onPressed: _initScanner,
                    icon: const Icon(Icons.refresh, color: Color(0xFF4A1E79)),
                    label: const Text("Coba Sambungkan Lagi", style: TextStyle(color: Color(0xFF4A1E79))),
                  ),
                ),

              const Spacer(),

              // ACTION BUTTON
              SizedBox(
                width: double.infinity,
                height: 60,
                child: ElevatedButton(
                  onPressed: (_isScannerStarted && !_isRegistering)
                      ? _startRegistration
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A1E79),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 4,
                    shadowColor: const Color(0xFF4A1E79).withOpacity(0.4),
                  ),
                  child: Text(
                    _isRegistering
                        ? AppLanguage.tr('attendance.fingerprint.processing')
                        : AppLanguage.tr('attendance.fingerprint.begin_scan'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 15),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  AppLanguage.tr('attendance.fingerprint.cancel'),
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Column(
      children: [
        Text(
          "${AppLanguage.tr('attendance.fingerprint.step_label')} $_registrationStep ${AppLanguage.tr('attendance.fingerprint.step_from')}",
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF4A1E79),
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            bool active = index < _registrationStep;
            bool current = index == (_registrationStep - 1);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: current ? 32 : 12,
              height: 12,
              decoration: BoxDecoration(
                color: active ? const Color(0xFF4A1E79) : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildFpPreview() {
    return AnimatedBuilder(
      animation: _pulseController!,
      builder: (context, child) {
        double pulse = _isRegistering ? _pulseController!.value : 0.0;
        return Container(
          width: 180,
          height: 180,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF4A1E79).withOpacity(0.1 + (pulse * 0.2)),
                blurRadius: 15 + (pulse * 20),
                spreadRadius: 2 + (pulse * 5),
              ),
            ],
            border: Border.all(
              color: const Color(
                0xFF4A1E79,
              ).withOpacity(_isRegistering ? 0.5 : 0.1),
              width: 4,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: ClipOval(
              child: _currentImage != null
                  ? Image.memory(_currentImage!, fit: BoxFit.cover)
                  : Center(
                      child: Icon(
                        Icons.fingerprint,
                        size: 90,
                        color: _isRegistering
                            ? const Color(0xFF4A1E79)
                            : Colors.grey.shade300,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}
