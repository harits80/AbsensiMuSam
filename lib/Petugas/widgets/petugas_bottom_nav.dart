import 'package:flutter/material.dart';
import '../../helpers/language_helper.dart';

class PetugasBottomNav extends StatelessWidget {
  final int currentIndex;
  final Function(int) onNavigationTap;
  final VoidCallback?
  onAttendanceTap; // Opsional - null jika tidak ada tombol attendance

  const PetugasBottomNav({
    super.key,
    required this.currentIndex,
    required this.onNavigationTap,
    this.onAttendanceTap, // Opsional
    this.isDarkMode = false,
    this.attendanceMode = 'face',
  });

  final bool isDarkMode;
  final String attendanceMode;

  IconData _getAttendanceIcon() {
    switch (attendanceMode.toLowerCase()) {
      case 'rfid':
        return Icons.copy_all_rounded;
      case 'fingerprint':
        return Icons.fingerprint_rounded;
      case 'selfie':
        return Icons.camera_alt_rounded;
      case 'face':
      default:
        return Icons.face_retouching_natural_rounded;
    }
  }

  Color _getAttendanceColor() {
    switch (attendanceMode.toLowerCase()) {
      case 'fingerprint':
        return const Color(0xFF9333EA);
      case 'rfid':
        return const Color(0xFF1E88E5);
      case 'selfie':
        return const Color(0xFFE91E63);
      case 'face':
      default:
        return const Color(0xFF4A1E79);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final hasAttendanceButton = onAttendanceTap != null;

    return Container(
      height: 70 + bottomPadding,
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1F0B38) : Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.1),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Bottom Navigation Items
          Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 2,
              bottom: 2 + bottomPadding,
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
                _buildNavItem(
                  context,
                  Icons.people_rounded,
                  AppLanguage.tr('members'),
                  1,
                ),
                // Spacer untuk tombol attendance di tengah (hanya jika ada)
                if (hasAttendanceButton) const SizedBox(width: 80),
                _buildNavItem(
                  context,
                  Icons.list_alt_rounded,
                  AppLanguage.tr('report'),
                  2,
                ),
                _buildNavItem(
                  context,
                  Icons.person_rounded,
                  AppLanguage.tr('profile'),
                  3,
                ),
              ],
            ),
          ),
          // Attendance Button di tengah yang timbul (hanya jika onAttendanceTap != null)
          if (hasAttendanceButton)
            Positioned(
              left: MediaQuery.of(context).size.width / 2 - 35,
              top: -32,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onAttendanceTap,
                  borderRadius: BorderRadius.circular(35),
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? _getAttendanceColor().withOpacity(0.8)
                          : _getAttendanceColor(),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDarkMode
                            ? const Color(0xFF1F0B38)
                            : Colors.white,
                        width: 5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _getAttendanceColor().withValues(
                            alpha: isDarkMode ? 0.3 : 0.4,
                          ),
                          blurRadius: 15,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      _getAttendanceIcon(),
                      color: Colors.white,
                      size: 30,
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
          onTap: () => onNavigationTap(index),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Top Indicator Line
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 3,
                width: isSelected ? 24 : 0,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: isDarkMode && isSelected
                      ? [
                          BoxShadow(
                            color: accentColor.withValues(alpha: 0.3),
                            blurRadius: 3,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              Stack(
                alignment: Alignment.center,
                children: [
                  if (isDarkMode && isSelected)
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withValues(alpha: 0.15),
                            blurRadius: 15,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                    ),
                  Icon(
                    icon,
                    color: isSelected
                        ? accentColor
                        : (isDarkMode ? Colors.white54 : Colors.grey.shade600),
                    size: 24,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    color: isSelected
                        ? accentColor
                        : (isDarkMode ? Colors.white54 : Colors.grey.shade600),
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
