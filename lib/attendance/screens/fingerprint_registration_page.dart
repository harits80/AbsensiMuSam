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
    with TickerProviderStateMixin {
  final FingerprintService _fingerprintService = FingerprintService();
  final BiometricService _biometricService = BiometricService();

  String _instructionText = 'Menghubungkan ke scanner...';
  String _subInstructionText = 'Mohon tunggu sebentar';
  Uint8List? _currentImage;
  bool _isScannerStarted = false;
  bool _isRegistering = false;
  bool _isConnecting = true;
  bool _isCompleted = false;
  bool _hasError = false;
  int _registrationStep = 0;

  late AnimationController _pulseController;
  late AnimationController _successController;
  late AnimationController _stepTransitionController;
  late Animation<double> _successScaleAnim;
  late Animation<double> _stepFadeAnim;

  StreamSubscription? _statusSubscription;
  StreamSubscription? _imageSubscription;
  StreamSubscription? _registerSubscription;

  static const Color _primaryColor = Color(0xFF4A1E79);
  static const Color _primaryLight = Color(0xFF7B3FBE);
  static const Color _successColor = Color(0xFF22C55E);
  static const Color _bgColor = Color(0xFFF8F7FA);
  static const Color _cardColor = Colors.white;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _successScaleAnim = CurvedAnimation(
      parent: _successController,
      curve: Curves.elasticOut,
    );

    _stepTransitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: 1.0,
    );
    _stepFadeAnim = CurvedAnimation(
      parent: _stepTransitionController,
      curve: Curves.easeIn,
    );

    _initScanner();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _imageSubscription?.cancel();
    _registerSubscription?.cancel();
    _pulseController.dispose();
    _successController.dispose();
    _stepTransitionController.dispose();
    _fingerprintService.stopScanner();
    _fingerprintService.dispose();
    super.dispose();
  }

  Future<void> _initScanner() async {
    if (!mounted) return;
    setState(() {
      _isScannerStarted = false;
      _isConnecting = true;
      _hasError = false;
      _instructionText = 'Menghubungkan ke scanner...';
      _subInstructionText = 'Mohon tunggu sebentar';
    });

    try {
      final hasPermission = await _fingerprintService.requestPermission();

      if (!hasPermission) {
        if (mounted) {
          setState(() {
            _isConnecting = false;
            _hasError = true;
            _instructionText = 'Izin USB Ditolak';
            _subInstructionText =
            'Cabut dan colok kembali kabel USB lalu coba lagi';
          });
        }
        return;
      }

      _statusSubscription?.cancel();
      _statusSubscription =
          _fingerprintService.statusStream.listen((status) {
            if (mounted) setState(() => _handleStatusUpdates(status));
          });

      _imageSubscription?.cancel();
      _imageSubscription =
          _fingerprintService.imageStream.listen((image) {
            if (mounted) setState(() => _currentImage = image);
          });

      _registerSubscription?.cancel();
      _registerSubscription = _fingerprintService.registerSuccessStream
          .listen((template) async {
        if (mounted) {
          setState(() {
            _registrationStep = 3;
            _isRegistering = false;
            _isCompleted = true;
            _instructionText = 'Registrasi Berhasil!';
            _subInstructionText = 'Sidik jari berhasil disimpan';
          });
          _successController.forward();
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
            _isConnecting = false;
            _hasError = false;
          });
          _startRegistration();
        }
      } else {
        if (mounted) {
          setState(() {
            _isScannerStarted = false;
            _isConnecting = false;
            _hasError = true;
            _instructionText =
            result == 'timeout' ? 'Koneksi Timeout' : 'Gagal Terhubung';
            _subInstructionText = result == 'timeout'
                ? 'Pastikan Anda sudah menekan OK pada pop-up USB'
                : 'Periksa kabel OTG dan scanner Anda';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isScannerStarted = false;
          _isConnecting = false;
          _hasError = true;
          _instructionText = 'Terjadi Kesalahan';
          _subInstructionText = 'Error: $e';
        });
      }
    }
  }

  void _handleStatusUpdates(String status) {
    final lowerStatus = status.toLowerCase();

    if (_isRegistering &&
        (lowerStatus.contains('capture error') ||
            lowerStatus.contains('extract error'))) {
      if (lowerStatus.contains('not found')) {
        _hasError = true;
        _instructionText = 'Scanner Terputus';
        _subInstructionText = 'Pastikan kabel terpasang dengan benar';
        _isRegistering = false;
      }
      return;
    }

    if (status.contains('Press finger')) {
      _hasError = false;
      if (status.contains('1/3')) {
        _animateStepChange(() {
          _registrationStep = 1;
          _instructionText = 'Tempelkan Jari Anda';
          _subInstructionText = 'Scan ke-1 dari 3';
        });
      } else if (status.contains('2/3')) {
        _animateStepChange(() {
          _registrationStep = 2;
          _instructionText = 'Tempelkan Jari Lagi';
          _subInstructionText = 'Scan ke-2 dari 3';
        });
      } else if (status.contains('3/3')) {
        _animateStepChange(() {
          _registrationStep = 3;
          _instructionText = 'Satu Kali Lagi';
          _subInstructionText = 'Scan ke-3 dari 3 — hampir selesai';
        });
      } else {
        if (_registrationStep == 0) _registrationStep = 1;
        _instructionText = 'Tempelkan Jari Anda';
        _subInstructionText = 'Letakkan jari pada scanner';
      }
    } else if (status.contains('Lift finger')) {
      _instructionText = 'Angkat Jari Anda';
      _subInstructionText = 'Scan diterima, siapkan untuk langkah berikutnya';
    } else if (status.contains('Registration successful')) {
      _isCompleted = true;
      _instructionText = 'Registrasi Berhasil!';
      _subInstructionText = 'Sidik jari berhasil direkam';
      _registrationStep = 3;
    } else if (status.contains('already enrolled')) {
      _hasError = true;
      _instructionText = 'Sidik Jari Sudah Terdaftar';
      _subInstructionText = 'Anggota ini sudah memiliki data sidik jari';
      _isRegistering = false;
    } else if (status.contains('Please press same finger')) {
      _hasError = true;
      _instructionText = 'Jari Tidak Sama';
      _subInstructionText = 'Gunakan jari yang sama di setiap langkah';
      _isRegistering = false;
      _registrationStep = 0;
    } else if (lowerStatus.contains('failed')) {
      if (lowerStatus.contains('enroll') ||
          lowerStatus.contains('merge') ||
          lowerStatus.contains('save')) {
        _hasError = true;
        _instructionText = 'Registrasi Gagal';
        _subInstructionText = 'Silakan coba proses registrasi kembali';
        _isRegistering = false;
        _registrationStep = 0;
      }
    }
  }

  void _animateStepChange(VoidCallback updateState) {
    _stepTransitionController.reverse().then((_) {
      if (mounted) {
        setState(updateState);
        _stepTransitionController.forward();
      }
    });
  }

  Future<void> _startRegistration() async {
    if (!_isScannerStarted) return;
    setState(() {
      _isRegistering = true;
      _isCompleted = false;
      _hasError = false;
      _registrationStep = 1;
      _instructionText = 'Tempelkan Jari Anda';
      _subInstructionText = 'Scan ke-1 dari 3';
    });
    await _fingerprintService.register(widget.organizationMemberId.toString());
  }

  Future<void> _retryRegistration() async {
    setState(() {
      _registrationStep = 0;
      _hasError = false;
      _isCompleted = false;
      _currentImage = null;
    });
    _successController.reset();
    await _startRegistration();
  }

  Future<void> _saveFingerprintTemplate(String templateData) async {
    try {
      setState(() => _subInstructionText = 'Menyimpan data sidik jari...');
      await _biometricService.registerFingerprintTemplate(
        organizationMemberId: widget.organizationMemberId,
        templateBase64: templateData,
      );
      if (mounted) _showSuccessDialog();
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _isCompleted = false;
          _instructionText = 'Gagal Menyimpan Data';
          _subInstructionText = 'Error: $e';
        });
      }
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            Navigator.of(context).pop();
            Navigator.of(context).pop(true);
          }
        });
        return Dialog(
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: _successColor.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      color: _successColor, size: 40),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Registrasi Berhasil!',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A2E)),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sidik jari telah berhasil disimpan',
                  style:
                  TextStyle(fontSize: 14, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Stack(
          children: [
            // Watermark — bottom-center, tidak bersaing dengan scanner
            Positioned(
              bottom: -30,
              left: 0,
              right: 0,
              child: Center(
                child: Opacity(
                  opacity: 0.05,
                  child: Image.asset(
                    'assets/logo/app_logo_new.png',
                    width: 260,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),

            // Foreground layout
            Column(
              children: [
                // ── ZONE 1: Scanner (45% layar) ──────────────────
                SizedBox(
                  height: screenHeight * 0.45,
                  child: Center(child: _buildScannerArea()),
                ),

                // ── ZONE 2: Instruksi langsung di bawah scanner ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: _buildInstructionText(),
                ),

                const SizedBox(height: 28),

                // ── Divider tipis ─────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Divider(
                    height: 1,
                    color: Colors.grey.withOpacity(0.15),
                  ),
                ),

                const SizedBox(height: 24),

                // ── ZONE 3: Step indicator slim ───────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: _buildStepIndicator(),
                ),

                const Spacer(),

                // ── ZONE 4: Retry button (hanya saat error) ───────
                if (_hasError && !_isConnecting)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _buildRetryButton(),
                  ),

                const SizedBox(height: 24),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────
  // WIDGETS
  // ─────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Column(
        children: [
          const Text(
            'Registrasi Sidik Jari',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 17,
              color: Color(0xFF1A1A2E),
            ),
          ),
          if (widget.memberName != null)
            Text(
              widget.memberName!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: _primaryColor.withOpacity(0.7),
              ),
            ),
        ],
      ),
      backgroundColor: _bgColor,
      foregroundColor: _primaryColor,
      elevation: 0,
      centerTitle: true,
      toolbarHeight: widget.memberName != null ? 64 : 56,
      leading: IconButton(
        icon: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _cardColor,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 16, color: _primaryColor),
        ),
        onPressed: () => Navigator.pop(context),
      ),
    );
  }

  /// Scanner besar sebagai focal point utama (240px)
  Widget _buildScannerArea() {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseController, _successController]),
      builder: (context, child) {
        final pulse =
        (_isRegistering && !_isCompleted) ? _pulseController.value : 0.0;
        final successScale =
        _isCompleted ? _successScaleAnim.value : 1.0;

        final Color ringColor = _isCompleted
            ? _successColor
            : _hasError
            ? Colors.red.shade400
            : _isRegistering
            ? _primaryColor
            : Colors.grey.shade300;

        return Transform.scale(
          scale: successScale,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Pulse ring terluar
              if (_isRegistering && !_isCompleted)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: 270 + (pulse * 36),
                  height: 270 + (pulse * 36),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                    _primaryColor.withOpacity(0.03 + (pulse * 0.03)),
                  ),
                ),

              // Pulse ring tengah
              if (_isRegistering && !_isCompleted)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: 258 + (pulse * 20),
                  height: 258 + (pulse * 20),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                    _primaryColor.withOpacity(0.04 + (pulse * 0.04)),
                  ),
                ),

              // Lingkaran utama scanner — 240px
              Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _cardColor,
                  border: Border.all(
                    color: ringColor.withOpacity(
                        _isRegistering ? (0.35 + pulse * 0.45) : 0.25),
                    width: _isRegistering ? 3.5 : 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                      ringColor.withOpacity(0.08 + (pulse * 0.14)),
                      blurRadius: 28 + (pulse * 24),
                      spreadRadius: 2 + (pulse * 6),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: _isCompleted
                      ? _buildSuccessOverlay()
                      : _currentImage != null
                      ? Image.memory(_currentImage!, fit: BoxFit.cover)
                      : _buildFingerprintIcon(pulse),
                ),
              ),

              // Badge "Scanning..." di bawah lingkaran
              if (_isRegistering && !_isCompleted && _registrationStep > 0)
                Positioned(
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: _primaryColor,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: _primaryColor.withOpacity(0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: _pulseController,
                          builder: (_, __) => Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.white
                                  .withOpacity(0.5 + pulse * 0.5),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Scanning...',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFingerprintIcon(double pulse) {
    return Center(
      child: Icon(
        Icons.fingerprint_rounded,
        size: 120,
        color: _isConnecting
            ? Colors.grey.shade200
            : _hasError
            ? Colors.red.shade300
            : _isRegistering
            ? _primaryColor.withOpacity(0.45 + pulse * 0.45)
            : _primaryColor.withOpacity(0.25),
      ),
    );
  }

  Widget _buildSuccessOverlay() {
    return Container(
      color: _successColor.withOpacity(0.07),
      child: const Center(
        child: Icon(Icons.check_circle_rounded, size: 96, color: _successColor),
      ),
    );
  }

  /// Instruksi center-aligned, tanpa card — langsung di bawah scanner
  Widget _buildInstructionText() {
    final Color textColor = _isCompleted
        ? _successColor
        : _hasError
        ? Colors.red.shade500
        : const Color(0xFF1A1A2E);

    return FadeTransition(
      opacity: _stepFadeAnim,
      child: Column(
        children: [
          // Status spinner saat connecting
          if (_isConnecting)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: _primaryColor.withOpacity(0.6),
                ),
              ),
            ),

          Text(
            _instructionText,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: textColor,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _subInstructionText,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.grey.shade500,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  /// Step indicator slim — tanpa card, tanpa shadow
  Widget _buildStepIndicator() {
    const steps = ['Scan 1', 'Scan 2', 'Scan 3'];

    return Row(
      children: List.generate(steps.length * 2 - 1, (i) {
        if (i.isOdd) {
          // Connector line
          final stepIndex = i ~/ 2;
          final isDone = _registrationStep > stepIndex + 1 || _isCompleted;
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              height: 3,
              decoration: BoxDecoration(
                gradient: isDone
                    ? const LinearGradient(
                    colors: [_primaryColor, _primaryLight])
                    : null,
                color: isDone ? null : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }

        final stepIndex = i ~/ 2;
        final isCompleted =
            (_registrationStep > stepIndex + 1) || _isCompleted;
        final isCurrent =
            _registrationStep == stepIndex + 1 && !_isCompleted;
        final isActive = isCompleted || isCurrent;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 350),
              width: isCurrent ? 36 : 32,
              height: isCurrent ? 36 : 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isCompleted
                    ? _primaryColor
                    : isCurrent
                    ? _primaryColor.withOpacity(0.1)
                    : Colors.grey.shade100,
                border: isCurrent
                    ? Border.all(color: _primaryColor, width: 2)
                    : null,
              ),
              child: Center(
                child: isCompleted
                    ? const Icon(Icons.check_rounded,
                    color: Colors.white, size: 16)
                    : Text(
                  '${stepIndex + 1}',
                  style: TextStyle(
                    fontSize: isCurrent ? 15 : 13,
                    fontWeight: FontWeight.w700,
                    color: isActive
                        ? _primaryColor
                        : Colors.grey.shade400,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              steps[stepIndex],
              style: TextStyle(
                fontSize: 11,
                fontWeight:
                isCurrent ? FontWeight.w700 : FontWeight.w500,
                color: isActive ? _primaryColor : Colors.grey.shade400,
                letterSpacing: 0.2,
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildRetryButton() {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: OutlinedButton.icon(
        onPressed:
        _hasError && _isScannerStarted ? _retryRegistration : _initScanner,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: Text(
          _isScannerStarted ? 'Coba Registrasi Ulang' : 'Hubungkan Ulang',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: _primaryColor,
          side: const BorderSide(color: _primaryColor, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}