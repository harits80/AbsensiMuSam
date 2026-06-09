import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

class AttendanceMapWidget extends StatefulWidget {
  final Position? userPosition;
  final Position? officePosition;
  final String? userPhotoUrl;
  final String? officePhotoUrl;
  final String userName;
  final String officeName;
  final double radiusMeters;
  final bool showRadius;
  final bool hideOverlays;

  const AttendanceMapWidget({
    super.key,
    required this.userPosition,
    required this.officePosition,
    this.userPhotoUrl,
    this.officePhotoUrl,
    required this.userName,
    required this.officeName,
    required this.radiusMeters,
    this.showRadius = true,
    this.hideOverlays = false,
  });

  @override
  State<AttendanceMapWidget> createState() => AttendanceMapWidgetState();
}

class AttendanceMapWidgetState extends State<AttendanceMapWidget>
    with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _fitBounds());
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // Public methods to allow external control if needed
  void zoomIn() => _mapController.move(
    _mapController.camera.center,
    _mapController.camera.zoom + 1,
  );
  void zoomOut() => _mapController.move(
    _mapController.camera.center,
    _mapController.camera.zoom - 1,
  );
  void recenter() => _fitBounds();

  void _fitBounds() {
    if (widget.userPosition == null && widget.officePosition == null) return;

    if (widget.userPosition != null && widget.officePosition != null) {
      final bounds = LatLngBounds(
        LatLng(
          math.min(
            widget.userPosition!.latitude,
            widget.officePosition!.latitude,
          ),
          math.min(
            widget.userPosition!.longitude,
            widget.officePosition!.longitude,
          ),
        ),
        LatLng(
          math.max(
            widget.userPosition!.latitude,
            widget.officePosition!.latitude,
          ),
          math.max(
            widget.userPosition!.longitude,
            widget.officePosition!.longitude,
          ),
        ),
      );

      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(120)),
      );
    } else {
      final pos = widget.userPosition ?? widget.officePosition!;
      _mapController.move(LatLng(pos.latitude, pos.longitude), 16);
    }
  }

  List<CircleMarker> _buildCircles() {
    if (!widget.showRadius || widget.officePosition == null) return [];
    return [
      CircleMarker(
        point: LatLng(
          widget.officePosition!.latitude,
          widget.officePosition!.longitude,
        ),
        radius: widget.radiusMeters,
        useRadiusInMeter: true,
        color: const Color(0xFF2DD4BF).withValues(alpha: 0.1),
        borderColor: const Color(0xFF2DD4BF).withValues(alpha: 0.3),
        borderStrokeWidth: 2,
      ),
    ];
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];

    if (widget.officePosition != null) {
      markers.add(
        Marker(
          point: LatLng(
            widget.officePosition!.latitude,
            widget.officePosition!.longitude,
          ),
          width: 80,
          height: 80,
          child: _buildOfficeMarker(),
        ),
      );
    }

    if (widget.userPosition != null) {
      markers.add(
        Marker(
          point: LatLng(
            widget.userPosition!.latitude,
            widget.userPosition!.longitude,
          ),
          width: 80,
          height: 80,
          child: AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, _) => Transform.scale(
              scale: _pulseAnimation.value,
              child: _buildUserMarker(),
            ),
          ),
        ),
      );
    }

    return markers;
  }

  Widget _buildUserMarker() {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Glow Effect
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF6366F1).withValues(alpha: 0.1),
          ),
        ),
        // Outer Border
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
        ),
        // Avatar
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF6366F1), Color(0xFFA855F7)],
            ),
          ),
          child: ClipOval(
            child:
                widget.userPhotoUrl != null && widget.userPhotoUrl!.isNotEmpty
                ? Image.network(
                    widget.userPhotoUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.person, color: Colors.white, size: 22),
                  )
                : const Icon(Icons.person, color: Colors.white, size: 22),
          ),
        ),
        // Status Dot
        Positioned(
          top: 14,
          right: 14,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF10B981),
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOfficeMarker() {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Glow Effect
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF2DD4BF).withValues(alpha: 0.1),
          ),
        ),
        // Main Container
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF2DD4BF),
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF2DD4BF).withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(
            Icons.apartment_rounded,
            color: Colors.white,
            size: 24,
          ),
        ),
      ],
    );
  }

  Widget _buildDefaultUserIcon() => Container(
    color: const Color(0xFF6366F1).withOpacity(0.1),
    child: const Icon(Icons.person, color: Color(0xFF6366F1), size: 20),
  );

  Widget _buildDefaultOfficeIcon() => Container(
    color: const Color(0xFF10B981).withOpacity(0.1),
    child: const Icon(Icons.business, color: Color(0xFF10B981), size: 20),
  );

  double? _calculateDistance() {
    if (widget.userPosition == null || widget.officePosition == null) {
      return null;
    }
    return Geolocator.distanceBetween(
      widget.userPosition!.latitude,
      widget.userPosition!.longitude,
      widget.officePosition!.latitude,
      widget.officePosition!.longitude,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.userPosition == null && widget.officePosition == null) {
      return _buildEmptyState();
    }

    final distance = _calculateDistance();
    final isWithinRadius = distance != null && distance <= widget.radiusMeters;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: widget.userPosition != null
                    ? LatLng(
                        widget.userPosition!.latitude,
                        widget.userPosition!.longitude,
                      )
                    : LatLng(
                        widget.officePosition!.latitude,
                        widget.officePosition!.longitude,
                      ),
                initialZoom: 16,
                maxZoom: 22,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
                backgroundColor: Colors.grey.shade100,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.absensimassal',
                  maxZoom: 22,
                  maxNativeZoom: 19,
                ),
                CircleLayer(circles: _buildCircles()),
                MarkerLayer(markers: _buildMarkers()),
              ],
            ),
            if (distance != null && !widget.hideOverlays)
              _buildDistanceOverlay(distance, isWithinRadius),
            if (!widget.hideOverlays) _buildControlButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildDistanceOverlay(double distance, bool isWithinRadius) {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: isWithinRadius
                    ? const Color(0xFF10B981)
                    : const Color(0xFFF59E0B),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isWithinRadius ? 'Dalam Jangkauan' : 'Di Luar Jangkauan',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isWithinRadius
                          ? const Color(0xFF10B981)
                          : const Color(0xFFF59E0B),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    distance < 1000
                        ? '${distance.toInt()} meter dari lokasi'
                        : '${(distance / 1000).toStringAsFixed(1)} kilometer dari lokasi',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButtons() {
    return Positioned(
      right: 12,
      bottom: 12,
      child: Column(
        children: [
          _buildControlButton(Icons.my_location, _fitBounds, 'Lokasi Saya'),
          const SizedBox(height: 6),
          _buildControlButton(Icons.add, () {
            _mapController.move(
              _mapController.camera.center,
              _mapController.camera.zoom + 1,
            );
          }, 'Perbesar'),
          const SizedBox(height: 6),
          _buildControlButton(Icons.remove, () {
            _mapController.move(
              _mapController.camera.center,
              _mapController.camera.zoom - 1,
            );
          }, 'Perkecil'),
        ],
      ),
    );
  }

  Widget _buildControlButton(
    IconData icon,
    VoidCallback onPressed,
    String tooltip,
  ) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        elevation: 2,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: const Color(0xFF6366F1)),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() => Container(
    height: 300,
    decoration: BoxDecoration(
      color: Colors.grey.shade100,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.location_off, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            'Lokasi tidak tersedia',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
          ),
        ],
      ),
    ),
  );
}
