import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geolocator;
import '../../helpers/language_helper.dart';
import '../../models/attendance_model.dart';
import '../../services/device_service.dart';
import '../../attendance/services/attendance_service.dart';
import '../widgets/attendance_map_widget.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DeviceSelectionScreen extends StatefulWidget {
  final String organizationId;
  final String organizationName;
  final bool isRequired;
  final bool allowCurrentLocation;
  final int? memberId;

  const DeviceSelectionScreen({
    super.key,
    required this.organizationId,
    required this.organizationName,
    this.isRequired = false,
    this.allowCurrentLocation = true,
    this.memberId,
  });

  @override
  State<DeviceSelectionScreen> createState() => _DeviceSelectionScreenState();
}

class _DeviceSelectionScreenState extends State<DeviceSelectionScreen> {
  final DeviceService _deviceService = DeviceService();
  final AttendanceService _attendanceService = AttendanceService();
  final TextEditingController _searchController = TextEditingController();

  List<AttendanceDevice> _devices = [];
  List<AttendanceDevice> _filteredDevices = [];
  List<Map<String, dynamic>> _shifts = [];
  AttendanceDevice? _selectedDevice;
  AttendanceDevice? _previouslySelectedDevice;
  Map<String, dynamic>? _selectedShift;
  bool _isLoading = true;
  bool _isLoadingShifts = false;
  bool _isSelecting = false;
  geolocator.Position? _currentPosition;
  Map<String, double> _distances = {};

  static const Color primaryColor = Color(0xFF9333EA);
  static const Color pageBackground = Color(0xFFF8FAFC);
  static const Color titleColor = Color(0xFF1E293B);
  static const Color subtitleColor = Color(0xFF64748B);
  static const Color searchBarBg = Color(0xFFFFFFFF);
  static const Color cardBg = Color(0xFFFFFFFF);

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _loadShifts();
    _getCurrentLocation();
    _searchController.addListener(_filterDevices);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterDevices() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredDevices = List.from(_devices);
      } else {
        _filteredDevices = _devices.where((device) {
          return (device.location?.toLowerCase().contains(query) ?? false) ||
              device.deviceName.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  Future<void> _loadShifts() async {
    if (widget.memberId == null) return;

    try {
      setState(() => _isLoadingShifts = true);

      final supabase = Supabase.instance.client;
      final response = await supabase
          .from('shifts')
          .select()
          .eq('organization_id', widget.organizationId)
          .eq('is_active', true)
          .order('name', ascending: true);

      if (mounted) {
        final shiftList = List<Map<String, dynamic>>.from(response);
        Map<String, dynamic>? autoSelected = await _findUserAssignedShift(
          supabase,
          shiftList,
        );

        autoSelected ??= _findShiftForCurrentTime(shiftList);
        autoSelected ??= shiftList.isNotEmpty ? shiftList.first : null;

        setState(() {
          _shifts = shiftList;
          _selectedShift = autoSelected;
          _isLoadingShifts = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading shifts: $e');
      if (mounted) {
        setState(() => _isLoadingShifts = false);
      }
    }
  }

  Future<Map<String, dynamic>?> _findUserAssignedShift(
    dynamic supabase,
    List<Map<String, dynamic>> shiftList,
  ) async {
    if (widget.memberId == null || shiftList.isEmpty) return null;
    try {
      final today = DateTime.now();
      final todayStr = today.toIso8601String().split('T')[0];
      final memberSched = await supabase
          .from('member_schedules')
          .select('shift_id, work_schedule_id')
          .eq('organization_member_id', widget.memberId!)
          .eq('is_active', true)
          .lte('effective_date', todayStr)
          .or('end_date.is.null,end_date.gte.$todayStr')
          .order('effective_date', ascending: false)
          .limit(1)
          .maybeSingle();

      if (memberSched == null) return null;

      final assignedShiftId = memberSched['shift_id'] as int?;
      if (assignedShiftId != null) {
        for (final s in shiftList) {
          if (s['id'] == assignedShiftId) return s;
        }
      }

      final workScheduleId = memberSched['work_schedule_id'] as int?;
      if (workScheduleId != null) {
        final dayOfWeek = today.weekday % 7;
        final detail = await supabase
            .from('work_schedule_details')
            .select('start_time, end_time')
            .eq('work_schedule_id', workScheduleId)
            .eq('day_of_week', dayOfWeek)
            .maybeSingle();

        if (detail != null) {
          final sTime = detail['start_time'] as String?;
          final eTime = detail['end_time'] as String?;
          if (sTime != null && eTime != null) {
            for (final s in shiftList) {
              String norm(String t) => t.split(':').take(2).join(':');
              if (norm(s['start_time'] ?? '') == norm(sTime) &&
                  norm(s['end_time'] ?? '') == norm(eTime)) {
                return s;
              }
            }
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error finding user assigned shift: $e');
      return null;
    }
  }

  Map<String, dynamic>? _findShiftForCurrentTime(
    List<Map<String, dynamic>> shiftList,
  ) {
    try {
      final now = DateTime.now();
      final currentMinutes = now.hour * 60 + now.minute;

      for (var shift in shiftList) {
        final startStr = shift['start_time'] as String?;
        final endStr = shift['end_time'] as String?;
        if (startStr == null || endStr == null) continue;

        final startParts = startStr.split(':');
        final endParts = endStr.split(':');
        if (startParts.length < 2 || endParts.length < 2) continue;

        final startMinutes =
            int.parse(startParts[0]) * 60 + int.parse(startParts[1]);
        final endMinutes = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);

        if (endMinutes > startMinutes) {
          if (currentMinutes >= startMinutes && currentMinutes <= endMinutes) {
            return shift;
          }
        } else {
          if (currentMinutes >= startMinutes || currentMinutes <= endMinutes) {
            return shift;
          }
        }
      }
    } catch (e) {
      debugPrint('Error finding shift for current time: $e');
    }
    return null;
  }

  void _checkShiftAndProceed(VoidCallback onProceed) {
    if (_shifts.isNotEmpty && _selectedShift == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLanguage.tr('attendance.device_selection.no_shift_selected'),
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }
    onProceed();
  }

  Future<void> _handleRefresh() async {
    await Future.wait([_loadDevices(), _loadShifts(), _getCurrentLocation()]);
  }

  Future<void> _loadDevices() async {
    try {
      setState(() => _isLoading = true);

      final devices = await _deviceService.loadDevices(widget.organizationId);
      final selectedDevice = await _deviceService.loadSelectedDevice(
        widget.organizationId,
      );

      setState(() {
        _devices = devices;
        _filteredDevices = List.from(devices);
        _selectedDevice = selectedDevice;
        _previouslySelectedDevice = selectedDevice;
        _isLoading = false;
      });

      _calculateDistances();
      debugPrint('Loaded ${devices.length} devices');
    } catch (e) {
      debugPrint('Error loading devices: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load locations: $e')));
      }
      setState(() => _isLoading = false);
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      debugPrint('Getting current location...');
      _currentPosition = await _attendanceService.getCurrentLocation();
      _calculateDistances();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Failed to get current location: $e');
    }
  }

  void _calculateDistances() {
    if (_currentPosition == null || _devices.isEmpty) return;

    final newDistances = <String, double>{};
    for (final device in _devices) {
      if (device.hasValidCoordinates) {
        final distance = geolocator.Geolocator.distanceBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          device.latitude!,
          device.longitude!,
        );
        newDistances[device.id] = distance;
      }
    }

    setState(() {
      _distances = newDistances;
    });
  }

  Future<void> _selectDevice(AttendanceDevice device) async {
    if (_isSelecting) return;

    final distance = _distances[device.id];
    if (distance != null && distance > device.radiusMeters) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Anda berada di luar jangkauan (${_formatDistance(distance)}). Jarak maksimal adalah ${device.radiusMeters.toInt()}m.',
            ),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
      return;
    }

    setState(() {
      _isSelecting = true;
      _selectedDevice = device;
    });

    try {
      await _deviceService.setSelectedDevice(device);

      await Future.delayed(const Duration(milliseconds: 400));

      final deviceChanged = _previouslySelectedDevice?.id != device.id;

      if (mounted) {
        Navigator.of(context).pop({
          'success': true,
          'type': 'device',
          'deviceChanged': deviceChanged,
          'selectedDevice': device,
          'previousDevice': _previouslySelectedDevice,
          'selectedShift': _selectedShift,
          'latitude': device.latitude,
          'longitude': device.longitude,
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save location: $e')));
      }
      setState(() {
        _selectedDevice = _previouslySelectedDevice;
      });
    } finally {
      if (mounted) setState(() => _isSelecting = false);
    }
  }

  Future<void> _selectCurrentLocation() async {
    if (_isSelecting || _currentPosition == null) return;

    setState(() => _isSelecting = true);

    try {
      await Future.delayed(const Duration(milliseconds: 300));

      if (mounted) {
        Navigator.of(context).pop({
          'success': true,
          'type': 'current_location',
          'deviceChanged': false,
          'selectedDevice': null,
          'previousDevice': _previouslySelectedDevice,
          'latitude': _currentPosition!.latitude,
          'longitude': _currentPosition!.longitude,
          'accuracy': _currentPosition!.accuracy,
          'reason': null,
          'selectedShift': _selectedShift,
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to use current location: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSelecting = false);
    }
  }

  Future<bool?> _showMapPreviewDialog({
    required geolocator.Position? userPosition,
    required AttendanceDevice? officePosition,
    required String officeName,
  }) async {
    if (!mounted) return false;

    final GlobalKey<AttendanceMapWidgetState> mapKey =
        GlobalKey<AttendanceMapWidgetState>();

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        final double distance = userPosition != null && officePosition != null
            ? geolocator.Geolocator.distanceBetween(
                userPosition.latitude,
                userPosition.longitude,
                officePosition.latitude ?? 0,
                officePosition.longitude ?? 0,
              )
            : 0;
        final bool isInRange =
            officePosition != null && distance <= officePosition.radiusMeters;

        return Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          child: SizedBox.expand(
            child: Stack(
              children: [
                Positioned.fill(
                  child: AttendanceMapWidget(
                    key: mapKey,
                    userPosition: userPosition,
                    officePosition: officePosition != null
                        ? geolocator.Position(
                            latitude: officePosition.latitude ?? 0,
                            longitude: officePosition.longitude ?? 0,
                            timestamp: DateTime.now(),
                            accuracy: 0,
                            altitude: 0,
                            heading: 0,
                            speed: 0,
                            speedAccuracy: 0,
                            altitudeAccuracy: 0,
                            headingAccuracy: 0,
                          )
                        : null,
                    userName: 'Anda',
                    officeName: officeName,
                    radiusMeters:
                        officePosition?.radiusMeters.toDouble() ?? 100,
                    showRadius: officePosition != null,
                    hideOverlays: true,
                  ),
                ),
                Positioned(
                  top: MediaQuery.of(context).padding.top + 20,
                  left: 20,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3E8FF),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.map_rounded,
                            color: primaryColor,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppLanguage.tr(
                                  'attendance.device_selection.verification_title',
                                ),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: titleColor,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                AppLanguage.tr(
                                  'attendance.device_selection.verification_subtitle',
                                ),
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: subtitleColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Color(0xFF94A3B8),
                          ),
                          onPressed: () => Navigator.pop(context, false),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: MediaQuery.of(context).padding.top + 104,
                  left: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: isInRange
                                ? const Color(0xFF2DD4BF)
                                : Colors.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isInRange
                                  ? AppLanguage.tr(
                                      'attendance.device_selection.within_range',
                                    )
                                  : AppLanguage.tr(
                                      'attendance.device_selection.out_of_range',
                                    ),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isInRange
                                    ? const Color(0xFF2DD4BF)
                                    : Colors.orange,
                                letterSpacing: 0.5,
                              ),
                            ),
                            Text(
                              '${distance.toInt()} ${AppLanguage.tr('attendance.device_selection.distance_from_target')}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: subtitleColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 20,
                  bottom: 120,
                  child: Column(
                    children: [
                      _buildFloatingControl(
                        icon: Icons.my_location_rounded,
                        onPressed: () => mapKey.currentState?.recenter(),
                        color: primaryColor,
                      ),
                      const SizedBox(height: 12),
                      _buildFloatingControl(
                        icon: Icons.add,
                        onPressed: () => mapKey.currentState?.zoomIn(),
                      ),
                      const SizedBox(height: 12),
                      _buildFloatingControl(
                        icon: Icons.remove,
                        onPressed: () => mapKey.currentState?.zoomOut(),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  bottom: MediaQuery.of(context).padding.bottom + 20,
                  left: 20,
                  right: 20,
                  child: ElevatedButton(
                    onPressed: (officePosition != null && !isInRange)
                        ? null
                        : () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: (officePosition != null && !isInRange)
                          ? Colors.grey
                          : primaryColor,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          (officePosition != null && !isInRange)
                              ? AppLanguage.tr(
                                  'attendance.device_selection.out_of_range',
                                )
                              : AppLanguage.tr(
                                  'attendance.device_selection.confirm_use_location',
                                ),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (officePosition == null || isInRange) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.chevron_right, size: 20),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFloatingControl({
    required IconData icon,
    required VoidCallback onPressed,
    Color color = const Color(0xFF64748B),
  }) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Icon(icon, color: color, size: 22),
        ),
      ),
    );
  }

  String _formatDistance(double distanceInMeters) {
    if (distanceInMeters < 1000) {
      return '${distanceInMeters.toInt()}m';
    } else {
      return '${(distanceInMeters / 1000).toStringAsFixed(1)}km';
    }
  }

  String _getDeviceDisplayName(AttendanceDevice device) {
    if (device.location?.isNotEmpty ?? false) {
      return device.location!;
    }
    return device.deviceName;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pageBackground,
      appBar: AppBar(
        title: Text(
          AppLanguage.tr('attendance.device_selection.title'),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: titleColor,
          ),
        ),
        backgroundColor: pageBackground,
        foregroundColor: titleColor,
        elevation: 0,
        centerTitle: false,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.chevron_left,
                  color: titleColor,
                  size: 28,
                ),
                onPressed: widget.isRequired
                    ? null
                    : () => Navigator.of(context).pop(null),
              ),
            ),
          ),
        ),
      ),
      body: _buildDeviceList(),
      resizeToAvoidBottomInset: true,
    );
  }

  Widget _buildDeviceList() {
    return RefreshIndicator(
      onRefresh: _handleRefresh,
      color: primaryColor,
      backgroundColor: Colors.white,
      displacement: 20,
      strokeWidth: 2,
      child: CustomScrollView(
        slivers: [
          if (_isLoading || _isLoadingShifts)
            SliverToBoxAdapter(
              child: LinearProgressIndicator(
                backgroundColor: primaryColor.withValues(alpha: 0.1),
                color: primaryColor,
                minHeight: 3,
              ),
            ),
          if (widget.memberId != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: _buildShiftSection(),
              ),
            ),
          SliverToBoxAdapter(
            child: SafeArea(
              bottom: false,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.only(top: 16, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildSearchBar(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.allowCurrentLocation && _currentPosition != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: _buildCurrentLocationCard(),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    AppLanguage.tr('attendance.device_selection.nearby_header'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF94A3B8),
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
            sliver: _devices.isEmpty
                ? SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildEmptyState(),
                  )
                : _filteredDevices.isEmpty
                ? SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildNoResultsContent(),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) =>
                          _buildDeviceCard(_filteredDevices[index]),
                      childCount: _filteredDevices.length,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentLocationCard() {
    if (_currentPosition == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            AppLanguage.tr(
              'attendance.device_selection.current_location_header',
            ),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF94A3B8),
              letterSpacing: 0.5,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _selectedDevice == null
                  ? primaryColor
                  : Colors.transparent,
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              onTap: _isSelecting
                  ? null
                  : () => _checkShiftAndProceed(_selectCurrentLocation),
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF8B5CF6), Color(0xFFA78BFA)],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF8B5CF6,
                            ).withValues(alpha: 0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.my_location,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLanguage.tr(
                              'attendance.device_selection.live_location',
                            ),
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: titleColor,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF10B981),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'ACCURACY: ${_currentPosition!.accuracy.toStringAsFixed(1)}M',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF10B981),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.map_outlined,
                        color: Color(0xFF94A3B8),
                        size: 24,
                      ),
                      onPressed: () => _showMapPreviewDialog(
                        userPosition: _currentPosition,
                        officePosition: null,
                        officeName: AppLanguage.tr(
                          'attendance.device_selection.live_location',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (value) => _filterDevices(),
        style: const TextStyle(color: titleColor, fontSize: 15),
        decoration: InputDecoration(
          hintText: AppLanguage.tr(
            'attendance.device_selection.search_placeholder',
          ),
          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 15),
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: 16, right: 12),
            child: Icon(Icons.search, color: Color(0xFF8B5CF6), size: 24),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: subtitleColor, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    _filterDevices();
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildDeviceCard(AttendanceDevice device) {
    final distance = _distances[device.id];
    final isSelected = _selectedDevice?.id == device.id;
    final displayName = _getDeviceDisplayName(device);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isSelected ? primaryColor : Colors.transparent,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: _isSelecting
              ? null
              : () => _checkShiftAndProceed(() => _selectDevice(device)),
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.location_on,
                    color: isSelected ? primaryColor : const Color(0xFF94A3B8),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        device.location ?? 'No address',
                        style: const TextStyle(
                          fontSize: 13,
                          color: subtitleColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildBadge(
                            '${(device.radiusMeters).toInt()}m ${AppLanguage.tr('attendance.device_selection.radius')}',
                            const Color(0xFFA855F7),
                          ),
                          if (distance != null)
                            _buildBadge(
                              distance <= device.radiusMeters
                                  ? '${_formatDistance(distance)} ${AppLanguage.tr('attendance.device_selection.away')}'
                                  : '${AppLanguage.tr('attendance.device_selection.out_of_range')} (${_formatDistance(distance)})',
                              distance <= device.radiusMeters
                                  ? const Color(0xFF10B981)
                                  : const Color(0xFFEF4444),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.map_outlined,
                    color: Color(0xFF94A3B8),
                    size: 24,
                  ),
                  onPressed: () => _showMapPreviewDialog(
                    userPosition: _currentPosition,
                    officePosition: device,
                    officeName: _getDeviceDisplayName(device),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBadge(String text, Color dotColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF64748B),
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: Text(
        AppLanguage.tr('attendance.device_selection.no_locations_available'),
      ),
    ),
  );

  Widget _buildNoResultsContent() => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: Text(
        AppLanguage.tr('attendance.device_selection.no_locations_found'),
      ),
    ),
  );

  Widget _buildShiftSection() {
    if (_shifts.isEmpty && _isLoadingShifts) return const SizedBox.shrink();
    if (_shifts.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF9333EA), Color(0xFF7E22CE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF9333EA).withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: _showShiftPicker,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.swap_horiz,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _selectedShift != null
                            ? '${_selectedShift!['name']}'
                            : AppLanguage.tr(
                                'attendance.device_selection.select_shift_prompt',
                              ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_selectedShift != null)
                        Text(
                          '${_selectedShift!['start_time']} - ${_selectedShift!['end_time']}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 13,
                          ),
                        ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showShiftPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                AppLanguage.tr(
                  'attendance.device_selection.select_shift_prompt',
                ),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: titleColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppLanguage.tr(
                  'attendance.device_selection.shift_picker_subtitle',
                ),
                style: TextStyle(fontSize: 14, color: subtitleColor),
              ),
              const SizedBox(height: 24),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.6,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _shifts.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final shift = _shifts[index];
                    final isSelected = _selectedShift?['id'] == shift['id'];

                    return Container(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? primaryColor.withOpacity(0.05)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isSelected
                              ? primaryColor
                              : const Color(0xFFF1F5F9),
                          width: 2,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              _selectedShift = shift;
                            });
                            Navigator.pop(context);
                          },
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.access_time_filled_rounded,
                                  color: isSelected
                                      ? primaryColor
                                      : subtitleColor,
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        shift['name'] ?? 'Unknown',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                          color: isSelected
                                              ? primaryColor
                                              : titleColor,
                                        ),
                                      ),
                                      Text(
                                        '${shift['start_time']} - ${shift['end_time']}',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: isSelected
                                              ? primaryColor.withOpacity(0.7)
                                              : subtitleColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (isSelected)
                                  const Icon(
                                    Icons.check_circle,
                                    color: primaryColor,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
