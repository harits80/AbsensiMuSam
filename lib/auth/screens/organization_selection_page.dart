import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:absenmusam/Petugas/screens/petugas_dashboard.dart';
import 'package:absenmusam/User/screens/user_dashboard.dart';
import 'package:absenmusam/auth/services/role_service.dart';

class OrganizationSelectionPage extends StatelessWidget {
  final List<Map<String, dynamic>> memberships;
  final RoleService _roleService = RoleService();

  OrganizationSelectionPage({super.key, required this.memberships});

  void _handleOrganizationSelect(
    BuildContext context,
    Map<String, dynamic> membership,
  ) {
    final organizationMemberId = membership['id'] as int;

    if (_roleService.isPetugas(membership)) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => PetugasDashboardPage(
            organizationMemberId: organizationMemberId,
            memberData: membership,
          ),
        ),
      );
    } else {
      // Default to User Dashboard for other roles
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => UserDashboardPage(
            organizationMemberId: organizationMemberId,
            memberData: membership,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              Text(
                'Select Organization',
                style: GoogleFonts.montserrat(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF1F2937),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You are a member of multiple organizations.\nPlease select one to continue.',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: ListView.separated(
                  itemCount: memberships.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final membership = memberships[index];
                    final organization = membership['organizations'];
                    final roleName = _roleService.getRoleName(membership);
                    final isPetugas = _roleService.isPetugas(membership);

                    return InkWell(
                      onTap: () =>
                          _handleOrganizationSelect(context, membership),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade200),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            // Organization Logo Placeholder
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: isPetugas
                                    ? const Color(0xFF6366F1).withOpacity(0.1)
                                    : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Center(
                                child: Icon(
                                  Icons.business,
                                  color: isPetugas
                                      ? const Color(0xFF6366F1)
                                      : Colors.grey.shade600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    organization['name'] ??
                                        'Unknown Organization',
                                    style: GoogleFonts.roboto(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: const Color(0xFF1F2937),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isPetugas
                                          ? Colors.blue.shade50
                                          : Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      roleName.toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: isPetugas
                                            ? Colors.blue.shade700
                                            : Colors.grey.shade700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_ios,
                              size: 16,
                              color: Colors.grey.shade400,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
