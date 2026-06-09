import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RoleService {
  final SupabaseClient _supabase = Supabase.instance.client;

  /// Get organization member with role information
  Future<Map<String, dynamic>?> getOrganizationMemberWithRole(
    String userId,
  ) async {
    try {
      // print('=== FETCHING ORGANIZATION MEMBER WITH ROLE ===');
      // print('User ID: $userId');

      final List<dynamic> responseList = await _supabase
          .from('organization_members')
          .select('''
            id,
            organization_id,
            user_id,
            employee_id,
            is_active,
            role_id,
            system_roles!organization_members_role_id_fkey (
              id,
              code,
              name,
              description,
              is_system
            )
          ''')
          .eq('user_id', userId)
          .eq('is_active', true);

      if (responseList.isEmpty) {
        // print('❌ No organization member found');
        return null;
      }

      // Return the first one as a fallback, full multi-org should use getAllOrganizationMembersWithRoles
      return responseList.first;
    } catch (e) {
      debugPrint('!!! ERROR fetching organization member: $e');
      rethrow;
    }
  }

  /// Check if user has admin role
  bool isAdmin(Map<String, dynamic>? memberData) {
    if (memberData == null) {
      // print('❌ isAdmin: memberData is null');
      return false;
    }

    if (memberData['system_roles'] == null) {
      // print('❌ isAdmin: system_roles is null');
      return false;
    }

    final roleCode = memberData['system_roles']['code'] as String?;
    // print('🔍 isAdmin check: roleCode = $roleCode');

    // Admin role codes: A001 (Admin), SA001 (Petugas)
    final result = roleCode == 'A001' || roleCode == 'SA001';
    // print('   Result: $result');
    return result;
  }

  /// Check if user has petugas role
  bool isPetugas(Map<String, dynamic>? memberData) {
    if (memberData == null) {
      // print('❌ isPetugas: memberData is null');
      return false;
    }

    if (memberData['system_roles'] == null) {
      // print('❌ isPetugas: system_roles is null');
      return false;
    }

    final roleCode = memberData['system_roles']['code'] as String?;
    // print('🔍 isPetugas check: roleCode = $roleCode');

    // Petugas role code: P001
    final result = roleCode == 'P001';
    // print('   Result: $result');
    return result;
  }

  /// Check if user has user role
  bool isUser(Map<String, dynamic>? memberData) {
    if (memberData == null) {
      // print('❌ isUser: memberData is null');
      return false;
    }

    if (memberData['system_roles'] == null) {
      // print('❌ isUser: system_roles is null');
      return false;
    }

    final roleCode = memberData['system_roles']['code'] as String?;
    // print('🔍 isUser check: roleCode = $roleCode');

    // User role code: US001
    final result = roleCode == 'US001';
    // print('   Result: $result');
    return result;
  }

  /// Get role display name
  String getRoleName(Map<String, dynamic>? memberData) {
    if (memberData == null || memberData['system_roles'] == null) {
      return 'Unknown';
    }

    return memberData['system_roles']['name'] as String? ?? 'Unknown';
  }

  /// Get role code
  String getRoleCode(Map<String, dynamic>? memberData) {
    if (memberData == null || memberData['system_roles'] == null) {
      return 'UNKNOWN';
    }

    return memberData['system_roles']['code'] as String? ?? 'UNKNOWN';
  }

  /// Get all active roles
  Future<List<Map<String, dynamic>>> getAllRoles() async {
    try {
      final response = await _supabase
          .from('system_roles')
          .select('id, code, name, description')
          .order('name');

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('!!! ERROR fetching roles: $e');
      return [];
    }
  }

  /// Get ALL organization memberships for a user
  Future<List<Map<String, dynamic>>> getAllOrganizationMembersWithRoles(
    String userId,
  ) async {
    try {
      final List<dynamic> response = await _supabase
          .from('organization_members')
          .select('''
            id,
            organization_id,
            user_id,
            employee_id,
            is_active,
            role_id,
            organizations!organization_members_organization_id_fkey (
              id,
              name,
              logo_url,
              address
            ),
            system_roles!organization_members_role_id_fkey (
              id,
              code,
              name,
              description,
              is_system
            ),
            user_profiles!inner(
              id,
              display_name,
              first_name,
              last_name,
              profile_photo_url
            )
          ''')
          .eq('user_id', userId)
          .eq('is_active', true);

      debugPrint('RAW MEMBERSHIPS RESPONSE: $response');

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('!!! ERROR fetching all organization memberships: $e');
      return [];
    }
  }
}
