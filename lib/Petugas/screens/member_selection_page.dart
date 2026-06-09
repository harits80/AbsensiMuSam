import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/language_helper.dart';
import 'package:cached_network_image/cached_network_image.dart';

class MemberSelectionPage extends StatefulWidget {
  final int organizationId;
  final String organizationName;

  const MemberSelectionPage({
    super.key,
    required this.organizationId,
    required this.organizationName,
  });

  @override
  State<MemberSelectionPage> createState() => _MemberSelectionPageState();
}

class _MemberSelectionPageState extends State<MemberSelectionPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  // Pagination State
  static const int _pageSize = 20;
  int _currentPage = 0;
  bool _hasMore = true;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String _lastSearchQuery = '';

  List<Map<String, dynamic>> _members = [];
  // _filteredMembers no longer needed as we'll filter server-side

  static const Color primaryColor = Color(0xFF9333EA);
  static const Color accentColor = Color(0xFFEC4899);
  static const Color pageBackground = Color(0xFFF8FAFC);
  static const Color titleColor = Color(0xFF1E293B);
  static const Color subtitleColor = Color(0xFF64748B);
  static const Color searchBarBg = Color(0xFFF1F5F9);

  @override
  void initState() {
    super.initState();
    _loadMembers(refresh: true);
    _scrollController.addListener(_onScroll);
    // Remove _filterMembers listener, search will be handled by TextField's onChanged/onSubmitted
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;

    // Trigger load more when user is 200px from the bottom
    if (currentScroll >= (maxScroll - 200) &&
        !_isLoadingMore &&
        !_isLoading &&
        _hasMore) {
      _loadMembers(refresh: false);
    }
  }

  // Debounce timer for search
  Timer? _searchDebounce;

  void _handleSearch(String query) {
    debugPrint('Search input: $query');
    if (_searchDebounce?.isActive ?? false) _searchDebounce!.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      if (_lastSearchQuery != query) {
        debugPrint('Debounce complete, triggering load: $query');
        _lastSearchQuery = query;
        _loadMembers(refresh: true);
      }
    });
  }

  Future<void> _loadMembers({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _isLoading = true;
        _currentPage = 0;
        _hasMore = true;
        _members = [];
      });
    } else {
      setState(() => _isLoadingMore = true);
    }

    try {
      final start = _currentPage * _pageSize;
      final end = start + _pageSize - 1;

      var query = _supabase
          .from('organization_members')
          .select('''
            id,
            employee_id,
            user_id,
            user_profiles!inner(
              display_name,
              first_name,
              last_name,
              profile_photo_url
            ),
            departments!organization_members_department_id_fkey(
              name
            )
          ''')
          .eq('organization_id', widget.organizationId)
          .eq('is_active', true);

      // Server-side filtering if search query exists
      if (_lastSearchQuery.isNotEmpty) {
        final searchTerm = '%$_lastSearchQuery%';
        // Note: PostgREST doesn't support cross-table OR easily with dots in one string.
        // We focus on searching name components in the joined user_profiles table.
        // User requested search only by name.
        query = query.or(
          'display_name.ilike.$searchTerm,'
          'first_name.ilike.$searchTerm,'
          'last_name.ilike.$searchTerm',
          referencedTable: 'user_profiles',
        );
      }

      debugPrint(
        'Fetching members for page $_currentPage, search: "$_lastSearchQuery"',
      );

      final response = await query
          .order('id', ascending: true) // Consistent order for pagination
          .range(start, end);

      final newMembers = List<Map<String, dynamic>>.from(response);
      debugPrint('Successfully loaded ${newMembers.length} members');

      if (mounted) {
        setState(() {
          if (refresh) {
            _members = newMembers;
          } else {
            _members.addAll(newMembers);
          }

          _isLoading = false;
          _isLoadingMore = false;
          _hasMore = newMembers.length == _pageSize;
          _currentPage++;
        });
      }

      debugPrint(
        'Loaded ${newMembers.length} members (Total: ${_members.length})',
      );
    } catch (e) {
      debugPrint('Error loading members: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load members: $e')));
      }
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
      });
    }
  }

  void _selectMember(Map<String, dynamic> member) {
    Navigator.of(context).pop(member);
  }

  String _getMemberName(Map<String, dynamic> member) {
    final userProfile = member['user_profiles'] as Map<String, dynamic>?;
    if (userProfile == null) return 'Unknown';

    final displayName = userProfile['display_name'] as String?;
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }

    final firstName = userProfile['first_name'] as String? ?? '';
    final lastName = userProfile['last_name'] as String? ?? '';
    return '$firstName $lastName'.trim();
  }

  String? _getMemberPhotoUrl(Map<String, dynamic> member) {
    final userProfile = member['user_profiles'] as Map<String, dynamic>?;
    final photoPath = userProfile?['profile_photo_url'] as String?;

    if (photoPath == null || photoPath.trim().isEmpty) return null;

    if (photoPath.startsWith('http')) return photoPath;

    // Construct Supabase storage URL
    return _supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  String _getMemberDepartment(Map<String, dynamic> member) {
    final department = member['departments'] as Map<String, dynamic>?;
    return department?['name'] as String? ?? '';
  }

  String _getMemberPosition(Map<String, dynamic> member) {
    // Positions removed from query to avoid PostgreSQL conflicts
    // Position info is not critical for member selection
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          AppLanguage.tr('attendance.selfie.select_member'),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: titleColor,
          ),
        ),
        backgroundColor: Colors.white,
        foregroundColor: titleColor,
        elevation: 0,
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: titleColor),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading ? _buildLoadingView() : _buildMemberList(),
      resizeToAvoidBottomInset: true,
    );
  }

  Widget _buildLoadingView() =>
      const Center(child: CircularProgressIndicator());

  Widget _buildMemberList() {
    return Container(
      color: pageBackground,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.organizationName,
                    style: const TextStyle(
                      color: titleColor,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildSearchBar(),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            sliver: _members.isEmpty && !_isLoading
                ? SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(40),
                        child: Text(
                          _lastSearchQuery.isEmpty
                              ? AppLanguage.tr('attendance.selfie.no_members')
                              : AppLanguage.tr(
                                  'attendance.selfie.no_members_match',
                                ).replaceAll('{query}', _lastSearchQuery),
                          style: const TextStyle(color: subtitleColor),
                        ),
                      ),
                    ),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      if (index < _members.length) {
                        return _buildMemberCard(_members[index]);
                      } else {
                        return _buildLoadMoreIndicator();
                      }
                    }, childCount: _members.length + (_hasMore ? 1 : 0)),
                  ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
        ],
      ),
    );
  }

  Widget _buildLoadMoreIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: _isLoadingMore
            ? Column(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        primaryColor.withOpacity(0.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Loading more...',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: searchBarBg,
        borderRadius: BorderRadius.circular(30),
      ),
      child: TextField(
        controller: _searchController,
        onChanged: _handleSearch,
        style: const TextStyle(color: titleColor, fontSize: 15),
        decoration: InputDecoration(
          hintText: AppLanguage.tr('attendance.selfie.search_member'),
          hintStyle: const TextStyle(color: subtitleColor, fontSize: 15),
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: 12, right: 8),
            child: Icon(Icons.search, color: primaryColor, size: 24),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: subtitleColor, size: 20),
                  onPressed: () {
                    _searchController.clear();
                    _handleSearch('');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _buildMemberCard(Map<String, dynamic> member) {
    final memberName = _getMemberName(member).toUpperCase();
    final photoUrl = _getMemberPhotoUrl(member);
    final department = _getMemberDepartment(member);
    final employeeId = member['employee_id'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _selectMember(member),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                // Avatar / Profile Photo
                photoUrl != null && photoUrl.isNotEmpty
                    ? Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFE2E8F0),
                            width: 1.5,
                          ),
                        ),
                        child: ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: photoUrl,
                            fit: BoxFit.cover,
                            placeholder: (context, url) =>
                                Container(color: Colors.grey.shade50),
                            errorWidget: (context, url, error) => Icon(
                              Icons.person,
                              color: Colors.grey.shade400,
                              size: 26,
                            ),
                          ),
                        ),
                      )
                    : Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFA855F7), Color(0xFFEC4899)],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFFA855F7,
                              ).withValues(alpha: 0.3),
                              blurRadius: 6,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.person,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                const SizedBox(width: 14),
                // Member Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        memberName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (employeeId.isNotEmpty)
                        Text(
                          'ID: $employeeId',
                          style: const TextStyle(
                            fontSize: 12,
                            color: subtitleColor,
                          ),
                        ),
                      if (department.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            department,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: primaryColor.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Forward Arrow
                const Icon(
                  Icons.chevron_right,
                  color: Color(0xFFE2E8F0),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
