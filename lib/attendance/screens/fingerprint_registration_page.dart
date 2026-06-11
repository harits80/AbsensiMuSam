// lib/attendance/screens/fingerprint_registration_page.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../services/fingerprint_service.dart';
import '../services/biometric_service.dart';
import '../../helpers/language_helper.dart';
import '../../helpers/voice_helper.dart';

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
    with TickerProviderStateMixin {
  final FingerprintService _fingerprintService = FingerprintService();
  final BiometricService _biometricService = BiometricService();

  String _instructionText = 'Menyiapkan scanner...';
  String _currentStepText = 'Inisialisasi';
  Uint8List? _currentImage;
  bool _isScannerStarted = false;
  bool _isRegistering = false;
  int _registrationStep = 0; // 0: Idle, 1, 2, 3: Scans

  // Animation controllers
  late AnimationController _pulseController;
  late AnimationController _scanLineController;
  late Animation<double> _scanLineAnimation;

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

    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
    
    _scanLineAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _scanLineController, curve: Curves.easeInOut),
    );

    _initScanner();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _imageSubscription?.cancel();
    _registerSubscription?.cancel();
    _pulseController.dispose();
    _scanLineController.dispose();
    _fingerprintService.stopScanner();
    _fingerprintService.dispose();
    super.dispose();
  }

  Future<void> _initScanner() async {
    if (!mounted) return;
    setState(() {
      _isScannerStarted = false;
      _instructionText = "Menghubungkan ke hardware...";
    });

    try {
      final hasPermission = await _fingerprintService.requestPermission();
      
      if (!hasPermission) {
        if (mounted) {
          setState(() {
            _instructionText = "Izin USB ditolak";
          });
        }
        return;
      }

      _statusSubscription?.cancel();
      _statusSubscription = _fingerprintService.statusStream.listen((status) {
        if (mounted) {
          _handleStatusUpdates(status);
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
            _instructionText = 'Selesai!';
          });
          await _saveFingerprintTemplate(template);
        }
      });

      final result = await _fingerprintService.startScanner().timeout(
        const Duration(seconds: 5),
        onTimeout: () => 'timeout',
      );

      if (result == 'success') {
        if (mounted) {
          setState(() {
            _isScannerStarted = true;
          });
          // ✅ AUTO-START: Langsung mulai scan tanpa klik tombol
          _startRegistration();
        }
      } else {
        if (mounted) {
          setState(() {
            _isScannerStarted = false;
            _instructionText = "Gagal terhubung ke scanner";
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isScannerStarted = false;
          _instructionText = "Error sistem";
        });
      }
    }
  }

  void _handleStatusUpdates(String status) {
    final lowerStatus = status.toLowerCase();

    if (status.contains('Press finger')) {
      if (status.contains('1/3')) {
        _registrationStep = 1;
        _instructionText = 'Tempelkan jari Anda (1/3)';
        _currentStepText = 'Tahap 1 dari 3';
      } else if (status.contains('2/3')) {
        _registrationStep = 2;
        _instructionText = 'Tempelkan jari lagi (2/3)';
        _currentStepText = 'Tahap 2 dari 3';
      } else if (status.contains('3/3')) {
        _registrationStep = 3;
        _instructionText = 'Satu kali lagi (3/3)';
        _currentStepText = 'Tahap 3 dari 3';
      } else {
        _instructionText = 'Tempelkan jari Anda';
      }
      VoiceHelper.speak(_instructionText);
    } else if (status.contains('Lift finger')) {
      _instructionText = 'Angkat jari Anda';
      VoiceHelper.speak(_instructionText);
    } else if (status.contains('Registration successful')) {
      _instructionText = 'Registrasi Berhasil';
      _registrationStep = 3;
    } else if (status.contains('already enrolled')) {
      _instructionText = 'Sidik jari sudah terdaftar';
      _isRegistering = false;
      VoiceHelper.speak(_instructionText, force: true);
    } else if (status.contains('Please press same finger')) {
      _instructionText = 'Gunakan jari yang sama';
      _isRegistering = false;
      _registrationStep = 0;
      VoiceHelper.speak(_instructionText, force: true);
      // Restart auto-scan after a delay
      Future.delayed(const Duration(seconds: 2), _startRegistration);
    }

    setState(() {});
  }

  Future<void> _startRegistration() async {
    if (!_isScannerStarted) return;
    setState(() {
      _isRegistering = true;
      _registrationStep = 1;
    });
    await _fingerprintService.register(widget.organizationMemberId.toString());
  }

  Future<void> _saveFingerprintTemplate(String templateData) async {
    try {
      setState(() => _instructionText = 'Menyimpan data...');
      await _biometricService.registerFingerprintTemplate(
        organizationMemberId: widget.organizationMemberId,
        templateBase64: templateData,
      );
      if (mounted) _showSuccessDialog();
    } catch (e) {
      if (mounted) {
        setState(() => _instructionText = 'Gagal menyimpan');
      }
    }
  }

  void _showSuccessDialog() {
    VoiceHelper.speak("Registrasi Berhasil", force: true);
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
                'Data sidik jari anggota kini telah aktif untuk absensi.',
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
        title: const Text(
          'Register Fingerprint',
          style: TextStyle(
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
          // 1. BACKGROUND GRADIENT
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1A0B2E), Colors.black],
              ),
            ),
          ),

          // 2. MAIN CONTENT
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 40),
                if (widget.memberName != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      widget.memberName!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                
                const Spacer(),

                // FINGERPRINT PREVIEW AREA
                _buildFpPreview(),

                const Spacer(flex: 2),

                // BOTTOM PROGRESS CARD
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
                  child: _buildProgressCard(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFpPreview() {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseController, _scanLineController]),
      builder: (context, child) {
        double pulse = _isRegistering ? _pulseController.value : 0.0;
        return Stack(
          alignment: Alignment.center,
          children: [
            // Outer Glowing Rings
            Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF8938DF).withOpacity(0.1 + (pulse * 0.1)),
                  width: 2,
                ),
              ),
            ),
            Container(
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF8938DF).withOpacity(0.05),
                border: Border.all(
                  color: const Color(0xFF8938DF).withOpacity(0.2 + (pulse * 0.2)),
                  width: 1,
                ),
              ),
            ),

            // Scanner Image or Icon
            Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF8938DF).withOpacity(0.2 + (pulse * 0.3)),
                    blurRadius: 20 + (pulse * 20),
                    spreadRadius: 2 + (pulse * 5),
                  ),
                ],
                border: Border.all(
                  color: const Color(0xFF8938DF).withOpacity(0.5),
                  width: 2,
                ),
              ),
              child: ClipOval(
                child: _currentImage != null
                    ? Image.memory(_currentImage!, fit: BoxFit.cover)
                    : Center(
                        child: Icon(
                          Icons.fingerprint_rounded,
                          size: 80,
                          color: _isRegistering
                              ? const Color(0xFFAD6FEF)
                              : Colors.grey.withOpacity(0.3),
                        ),
                      ),
              ),
            ),

            // Scan Line Animation
            if (_isRegistering && _currentImage != null)
              Positioned(
                top: 30 + (_scanLineAnimation.value * 100),
                child: Container(
                  width: 140,
                  height: 2,
                  decoration: BoxDecoration(
                    color: const Color(0xFFAD6FEF),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFAD6FEF).withOpacity(0.8),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildProgressCard() {
    double progress = _registrationStep / 3;
    
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
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _instructionText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _currentStepText,
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
                    '${(progress * 100).toInt()}%',
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
                    widthFactor: progress,
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
}

