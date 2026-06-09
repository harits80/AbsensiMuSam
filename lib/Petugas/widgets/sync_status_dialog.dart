import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../attendance/services/attendance_sync_service.dart';
import '../../helpers/language_helper.dart';

class SyncStatusDialog extends StatefulWidget {
  final bool isDarkMode;

  const SyncStatusDialog({super.key, this.isDarkMode = false});

  @override
  State<SyncStatusDialog> createState() => _SyncStatusDialogState();

  static Future<void> show(BuildContext context, {bool isDarkMode = false}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => SyncStatusDialog(isDarkMode: isDarkMode),
    );
  }
}

class _SyncStatusDialogState extends State<SyncStatusDialog>
    with TickerProviderStateMixin {
  final AttendanceSyncService _syncService = AttendanceSyncService();
  SyncStatus? _currentStatus;
  bool _isFinished = false;

  late AnimationController _rotationController;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _currentStatus = _syncService.currentStatus;
    _startSync();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _startSync() async {
    _syncService.syncStatusStream.listen((status) {
      if (mounted) {
        setState(() {
          _currentStatus = status;
          if (!status.isLoading && status.message.contains('finished')) {
            _isFinished = true;
            _rotationController.stop();
            _pulseController.stop();
          }
        });
      }
    });

    await _syncService.syncAllPendingAttendances();

    if (mounted) {
      setState(() {
        _isFinished = true;
        _rotationController.stop();
        _pulseController.stop();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = _currentStatus?.isLoading ?? true;
    final isError = _currentStatus?.isError ?? false;
    final records = _currentStatus?.records;
    final progress = _currentStatus?.progress ?? 0;
    final total = _currentStatus?.total ?? 0;

    final Color accentColor = const Color(0xFF6C47FF);
    final Color successColor = const Color(0xFF22C55E);
    final Color errorColor = const Color(0xFFEF4444);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      snap: true,
      snapSizes: const [0.5, 0.75, 0.92],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: widget.isDarkMode
                ? const Color(0xFF1A1A2E)
                : const Color(0xFFFAFAFC),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 30,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Row(
                  children: [
                    _buildStatusIcon(
                      isLoading: isLoading,
                      isError: isError,
                      accentColor: accentColor,
                      successColor: successColor,
                      errorColor: errorColor,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLanguage.tr('Syncing Data'),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: widget.isDarkMode
                                  ? Colors.white
                                  : const Color(0xFF0F0F23),
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isLoading
                                ? (total > 0
                                      ? '$progress of $total records'
                                      : AppLanguage.tr('Initializing...'))
                                : isError
                                ? AppLanguage.tr('Sync failed')
                                : AppLanguage.tr('All data synchronized'),
                            style: TextStyle(
                              fontSize: 13,
                              color: isLoading
                                  ? accentColor
                                  : isError
                                  ? errorColor
                                  : successColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_isFinished)
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.close,
                            size: 18,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Progress bar
              if (isLoading) ...[
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(100),
                    child: LinearProgressIndicator(
                      value: total > 0 ? progress / total : null,
                      minHeight: 6,
                      backgroundColor: accentColor.withOpacity(0.1),
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    ),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: isError
                          ? errorColor.withOpacity(0.2)
                          : successColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: 1.0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: isError ? errorColor : successColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // Records section header
              if (records != null && records.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Text(
                        'Records',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: widget.isDarkMode
                              ? Colors.white60
                              : Colors.grey.shade500,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: accentColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: Text(
                          '${records.length}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: accentColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                // Records list
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: records.length,
                    itemBuilder: (context, index) {
                      final record = records[index];
                      final isSynced = index < progress;
                      return _buildRecordTile(
                        record: record,
                        isSynced: isSynced,
                        isLoading: isLoading && index == progress,
                        accentColor: accentColor,
                        successColor: successColor,
                        isDarkMode: widget.isDarkMode,
                      );
                    },
                  ),
                ),
              ] else if (!isLoading && !isError) ...[
                // Empty state
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: successColor.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.check_rounded,
                            color: successColor,
                            size: 36,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          AppLanguage.tr('All caught up!'),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: widget.isDarkMode
                                ? Colors.white
                                : const Color(0xFF0F0F23),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          AppLanguage.tr('No pending data to sync'),
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: const SizedBox(height: 60),
                  ),
                ),
              ],

              // Close button (bottom safe area)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isFinished
                          ? () => Navigator.of(context).pop()
                          : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: _isFinished
                            ? accentColor
                            : Colors.grey.shade200,
                        disabledBackgroundColor: Colors.grey.shade200,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        _isFinished
                            ? AppLanguage.tr('Done')
                            : AppLanguage.tr('Syncing...'),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: _isFinished
                              ? Colors.white
                              : Colors.grey.shade500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatusIcon({
    required bool isLoading,
    required bool isError,
    required Color accentColor,
    required Color successColor,
    required Color errorColor,
  }) {
    if (isLoading) {
      return ScaleTransition(
        scale: _pulseAnimation,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: accentColor.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: AnimatedBuilder(
              animation: _rotationController,
              builder: (context, child) {
                return Transform.rotate(
                  angle: _rotationController.value * 2 * math.pi,
                  child: Icon(Icons.sync_rounded, color: accentColor, size: 22),
                );
              },
            ),
          ),
        ),
      );
    }

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: isError
            ? errorColor.withOpacity(0.1)
            : successColor.withOpacity(0.1),
        shape: BoxShape.circle,
      ),
      child: Icon(
        isError ? Icons.error_outline_rounded : Icons.check_rounded,
        color: isError ? errorColor : successColor,
        size: 22,
      ),
    );
  }

  Widget _buildRecordTile({
    required dynamic record,
    required bool isSynced,
    required bool isLoading,
    required Color accentColor,
    required Color successColor,
    required bool isDarkMode,
  }) {
    final name = record.userName ?? 'Member ${record.organizationMemberId}';
    final eventType = record.eventType.replaceAll('_', ' ');
    final method = record.method.toLowerCase();
    final timeStr = _formatTime(record.timestamp);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isDarkMode ? Colors.white.withOpacity(0.05) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSynced
              ? successColor.withOpacity(0.2)
              : Colors.grey.shade100,
          width: 1,
        ),
        boxShadow: isDarkMode
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 1),
                ),
              ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDarkMode
                          ? Colors.white
                          : const Color(0xFF0F0F23),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _eventBadge(eventType),
                      const SizedBox(width: 6),
                      Text(
                        method,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade400,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Status indicator: spinner or dot
            if (isLoading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: accentColor,
                ),
              )
            else
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isSynced ? successColor : Colors.grey.shade300,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _eventBadge(String eventType) {
    Color color;
    if (eventType.contains('check in') || eventType.contains('check_in')) {
      color = const Color(0xFF22C55E);
    } else if (eventType.contains('check out') ||
        eventType.contains('check_out')) {
      color = const Color(0xFFEF4444);
    } else if (eventType.contains('break')) {
      color = const Color(0xFFF59E0B);
    } else {
      color = const Color(0xFF6B7280);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        eventType,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  String _formatTime(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      return DateFormat('HH:mm').format(dt);
    } catch (e) {
      return '--:--';
    }
  }
}
