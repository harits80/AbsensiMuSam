// lib/widgets/sync_dialog.dart
import 'package:flutter/material.dart';
import '../attendance/services/attendance_sync_service.dart';

class _SyncDialog extends StatefulWidget {
  final Map<String, int> stats;
  final AttendanceSyncService syncService;
  final VoidCallback onSyncComplete;

  const _SyncDialog({
    required this.stats,
    required this.syncService,
    required this.onSyncComplete,
  });

  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  bool _isSyncing = false;
  String _message = '';
  int _progress = 0;
  int _total = 0;

  @override
  Widget build(BuildContext context) {
    final pendingCount = widget.stats['pending'] ?? 0;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isSyncing ? Icons.sync : Icons.cloud_upload,
                size: 40,
                color: Colors.blue,
              ),
            ),
            const SizedBox(height: 20),

            // Title
            const Text(
              'Sinkronisasi Data',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // Stats
            if (!_isSyncing)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _buildStatRow('Total Data', '${widget.stats['total']}'),
                    const SizedBox(height: 8),
                    _buildStatRow('Tersinkron', '${widget.stats['synced']}'),
                    const SizedBox(height: 8),
                    _buildStatRow(
                      'Belum Tersinkron',
                      '$pendingCount',
                      color: Colors.orange,
                    ),
                  ],
                ),
              ),

            // Progress
            if (_isSyncing)
              Column(
                children: [
                  LinearProgressIndicator(
                    value: _total > 0 ? _progress / _total : null,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _message,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
                  ),
                ],
              ),

            const SizedBox(height: 24),

            // Buttons
            if (!_isSyncing)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Tutup'),
                    ),
                  ),
                  if (pendingCount > 0) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _startSync,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'Sinkronkan',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value, {Color? color}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color ?? Colors.black87,
          ),
        ),
      ],
    );
  }

  Future<void> _startSync() async {
    setState(() {
      _isSyncing = true;
      _message = 'Memulai sinkronisasi...';
    });

    // Listen to sync status
    final subscription = widget.syncService.syncStatusStream.listen((status) {
      if (mounted) {
        setState(() {
          _message = status.message;
          _progress = status.progress ?? 0;
          _total = status.total ?? 0;
        });
      }
    });

    try {
      final result = await widget.syncService.syncPendingAttendances(
        showProgress: true,
      );

      if (mounted) {
        Navigator.of(context).pop();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: result.success ? Colors.green : Colors.red,
          ),
        );

        widget.onSyncComplete();
      }
    } finally {
      await subscription.cancel();
    }
  }
}
