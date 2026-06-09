import 'package:flutter/material.dart';
import '../../helpers/language_helper.dart';

class CustomBottomNav extends StatelessWidget {
  final int currentIndex;
  final Function(int)? onTap;
  final VoidCallback? onAttendanceTap;
  final bool isDarkMode;
  final String attendanceMode;

  const CustomBottomNav({
    super.key,
    required this.currentIndex,
    this.onTap,
    this.onAttendanceTap,
    this.isDarkMode = false,
    this.attendanceMode = 'selfie',
  });

  IconData _getAttendanceIcon() {
    switch (attendanceMode.toLowerCase()) {
      case 'rfid':
        return Icons.copy_all_rounded;
      case 'fingerprint':
        return Icons.fingerprint_rounded;
      case 'face':
        return Icons.face_retouching_natural_rounded;
      case 'selfie':
      default:
        return Icons.camera_alt_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final hasAttendanceButton = onAttendanceTap != null;

    return Container(
      height: 60 + bottomPadding, // 🔥 DIPERKECIL dari 70
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1F0B38) : Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20), // 🔥 DIPERKECIL dari 24
          topRight: Radius.circular(20),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.05),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Navigation Items
          Padding(
            padding: EdgeInsets.only(
              left: 12, // 🔥 KURANGI dari 16
              right: 12, // 🔥 KURANGI dari 16
              top: 4, // 🔥 KURANGI dari 8
              bottom: 4 + bottomPadding, // 🔥 KURANGI dari 8
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(
                  context,
                  Icons.home_rounded,
                  AppLanguage.tr('home'),
                  0,
                ),
                if (hasAttendanceButton)
                  const SizedBox(width: 70), // 🔥 KURANGI dari 80
                _buildNavItem(
                  context,
                  Icons.person_rounded,
                  AppLanguage.tr('profile'),
                  1,
                ),
              ],
            ),
          ),
          // Floating Attendance Button
          if (hasAttendanceButton)
            Positioned(
              left:
                  MediaQuery.of(context).size.width / 2 -
                  30, // 🔥 DIPERKECIL dari 35
              top: -28, // 🔥 DIPERKECIL dari -32
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onAttendanceTap,
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    width: 60, // 🔥 DIPERKECIL dari 70
                    height: 60, // 🔥 DIPERKECIL dari 70
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? const Color(0xFF9E77F1)
                          : const Color(0xFF4A1E79),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDarkMode
                            ? const Color(0xFF1F0B38)
                            : Colors.white,
                        width: 4, // 🔥 KURANGI dari 5
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              (isDarkMode
                                      ? const Color(0xFF9E77F1)
                                      : const Color(0xFF4A1E79))
                                  .withValues(alpha: isDarkMode ? 0.3 : 0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Icon(
                      _getAttendanceIcon(),
                      color: Colors.white,
                      size: 26, // 🔥 DIPERKECIL dari 30
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    IconData icon,
    String label,
    int index,
  ) {
    final isSelected = currentIndex == index;
    final accentColor = isDarkMode
        ? const Color(0xFFD0BCFF)
        : const Color(0xFF4A1E79);

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onTap?.call(index),
          borderRadius: BorderRadius.circular(10),
          child: Column(
            mainAxisSize: MainAxisSize.min, // 🔥 TAMBAHKAN INI
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Indicator Line
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 2, // 🔥 DIPERKECIL dari 3
                width: isSelected ? 20 : 0, // 🔥 DIPERKECIL dari 24
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 6), // 🔥 KURANGI dari 8
              Icon(
                icon,
                color: isSelected
                    ? accentColor
                    : (isDarkMode ? Colors.white54 : Colors.grey.shade600),
                size: 22, // 🔥 DIPERKECIL dari 26
              ),
              const SizedBox(height: 2), // 🔥 KURANGI dari 4
              Text(
                label,
                style: TextStyle(
                  fontSize: 10, // 🔥 DIPERKECIL dari 12
                  color: isSelected
                      ? accentColor
                      : (isDarkMode ? Colors.white54 : Colors.grey.shade600),
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
