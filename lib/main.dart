import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:absenmusam/helpers/language_helper.dart';
import 'package:absenmusam/auth/screens/login.dart';
import 'package:absenmusam/auth/screens/join_organization_screen.dart';
import 'package:absenmusam/Petugas/screens/petugas_dashboard.dart';
import 'package:absenmusam/User/screens/user_dashboard.dart';
import 'package:absenmusam/auth/services/role_service.dart';
import 'package:absenmusam/auth/services/location_service.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:absenmusam/providers/timezone_provider.dart';
import 'package:absenmusam/providers/theme_provider.dart';
import 'package:absenmusam/attendance/services/attendance_sync_service.dart';
import 'package:absenmusam/services/objectbox_service.dart'; // ✅ Added ObjectBox Service
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite/sqflite.dart';

// ✅ Global instance of ObjectBox for simplified access
late ObjectBoxService objectBox;

// ==============================================
// FUNGSI UNTUK MENGHAPUS DATABASE LAMA
// ==============================================3
Future<void> forceDeleteDatabase() async {
  try {
    // Dapatkan direktori database
    var databasesPath = await getDatabasesPath();

    // Path ke file database (sesuaikan dengan nama database yang Anda gunakan)
    String path = p.join(databasesPath, 'attendance.db');

    // Cek apakah file database ada
    final dbFile = File(path);
    if (await dbFile.exists()) {
      // Hapus database dengan aman menggunakan sqflite
      await deleteDatabase(path);
      debugPrint('✅ Database LAMA berhasil DIHAPUS!');
    } else {
      debugPrint('ℹ️ Tidak ada database lama yang ditemukan');
    }

    // Hapus juga kemungkinan database dengan nama lain
    String pathV2 = p.join(databasesPath, 'attendance_v2.db');
    final dbFileV2 = File(pathV2);
    if (await dbFileV2.exists()) {
      await deleteDatabase(pathV2);
      debugPrint('✅ Database attendance_v2.db juga dihapus');
    }
  } catch (e) {
    debugPrint('⚠️ Error saat hapus database: $e');
  }
}

// ==============================================
// MAIN FUNCTION
// ==============================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ INITIALIZE OBJECTBOX (Fastest DB)
  objectBox = await ObjectBoxService.create();

  // HAPUS DATABASE LAMA SEBELUM APLIKASI JALAN
  await forceDeleteDatabase();

  // Backend API atau bisa juga inisialisasi supobase
  await Supabase.initialize(
    url: 'https://yjmjyqewlemqzmwjrfqk.supabase.co',
    anonKey:
        'sb_publishable_i_xmrVVgZBXvE-IxgLN6-g_rSG8vGWY',
  );
  await AppLanguage.init();
  await initializeDateFormatting('id_ID', null);
  await initializeDateFormatting('en_US', null);

  // Start background sync service globally
  AttendanceSyncService().startAutoSync();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => TimezoneProvider()..loadSettings(),
        ),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

// ==============================================
// MY APP
// ==============================================
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return ValueListenableBuilder<String>(
      valueListenable: LanguageHelper.languageNotifier,
      builder: (context, languageCode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Absensi',
          locale: Locale(languageCode),
          themeMode: themeProvider.isDarkMode
              ? ThemeMode.dark
              : ThemeMode.light,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6366F1),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            fontFamily: 'Roboto',
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6366F1),
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
            fontFamily: 'Roboto',
          ),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [
            Locale('id', 'ID'),
            Locale('en', 'US'),
            Locale('ar', 'SA'),
          ],
          home: const SplashScreen(),
        );
      },
    );
  }
}

// ==============================================
// SPLASH SCREEN
// ==============================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  final RoleService _roleService = RoleService();

  @override
  void initState() {
    super.initState();

    // Initialize animations
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeIn),
      ),
    );

    _animationController.forward();
    _navigateToNextScreen();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  // ==============================================
  // CEK AUTH DAN NAVIGASI (SUDAH DIPERBAIKI)
  // ==============================================
  Future<void> _checkAuthAndNavigate() async {
    if (!mounted) return;

    final session = Supabase.instance.client.auth.currentSession;

    // Jika tidak ada session, arahkan ke Login
    if (session == null) {
      debugPrint('❌ No active session - navigating to Login');
      if (!mounted) return;
      // ✅ DIPERBAIKI: menggunakan pushReplacement dengan context langsung
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
      );
      return;
    }

    try {
      final userId = session.user.id;
      debugPrint('✅ Active session found for user: $userId');

      // Fetch ALL memberships
      final memberships = await _roleService.getAllOrganizationMembersWithRoles(
        userId,
      );

      if (!mounted) return;

      if (memberships.isEmpty) {
        // No memberships -> Join Organization
        // ✅ DIPERBAIKI: menggunakan pushReplacement dengan context langsung
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const JoinOrganizationScreen(),
          ),
        );
      } else {
        // If 1 or more memberships, pick the first one and go to dashboard
        final memberData = memberships.first;
        _navigateToDashboard(memberData);
      }
    } catch (e) {
      debugPrint('❌ Error checking organization membership: $e');
      if (!mounted) return;
      // ✅ DIPERBAIKI: menggunakan pushReplacement dengan context langsung
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
      );
    }
  }

  // ==============================================
  // NAVIGASI KE DASHBOARD (SUDAH DIPERBAIKI)
  // ==============================================
  void _navigateToDashboard(Map<String, dynamic> memberData) {
    final organizationMemberId = memberData['id'] as int;

    final roleCode = _roleService.getRoleCode(memberData);
    if (_roleService.isPetugas(memberData) || roleCode == 'SA001') {
      // ✅ DIPERBAIKI: menggunakan pushReplacement dengan context langsung
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => PetugasDashboardPage(
            organizationMemberId: organizationMemberId,
            memberData: memberData,
            isDarkMode: false,
          ),
        ),
      );
    } else {
      // Default to User Dashboard for other roles
      // ✅ DIPERBAIKI: menggunakan pushReplacement dengan context langsung
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => UserDashboardPage(
            organizationMemberId: organizationMemberId,
            memberData: memberData,
            isDarkMode: false,
          ),
        ),
      );
    }
  }

  Future<void> _navigateToNextScreen() async {
    await Future.delayed(const Duration(milliseconds: 2500));
    if (!mounted) return;
    await _checkAuthAndNavigate();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ScaleTransition(
                scale: _scaleAnimation,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Image.asset(
                      'assets/logo/app_icon_new.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Column(
                children: [
                  Text(
                    'ABSENSI MASSAL',
                    style: GoogleFonts.montserrat(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFF1F2937),
                      letterSpacing: 4.0,
                      height: 1.2,
                      shadows: const [
                        BoxShadow(
                          color: Colors.black12,
                          offset: Offset(2, 2),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Text(
                      'Smart Attendance System',
                      style: GoogleFonts.montserrat(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF6366F1),
                        letterSpacing: 2.0,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 80),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    const Color(0xFF6366F1).withValues(alpha: 0.8),
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
