import 'dart:io';
import 'package:flutter/material.dart';
import '../services/export_service.dart';

class ExportReportScreen extends StatefulWidget {
  const ExportReportScreen({super.key});

  @override
  State<ExportReportScreen> createState() => _ExportReportScreenState();
}

class _ExportReportScreenState extends State<ExportReportScreen> {
  final ExportService _exportService = ExportService();

  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now();
  String _selectedFormat = 'PDF';
  bool _isLoading = false;
  List<Map<String, dynamic>> _attendanceData = [];
  String? _errorMessage;

  final List<String> _formats = ['PDF', 'Excel'];

  Future<void> _selectStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _startDate) {
      setState(() => _startDate = picked);
    }
  }

  Future<void> _selectEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _endDate) {
      setState(() => _endDate = picked);
    }
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final data = await _exportService.getAttendanceData(
        startDate: _startDate,
        endDate: _endDate,
      );
      setState(() {
        _attendanceData = data;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _exportReport() async {
    if (_attendanceData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tidak ada data untuk diexport'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      File? file;

      if (_selectedFormat == 'PDF') {
        file = await _exportService.generatePDF(
          startDate: _startDate,
          endDate: _endDate,
          data: _attendanceData,
          title: 'Laporan Absensi',
        );
      } else {
        file = await _exportService.generateExcel(
          startDate: _startDate,
          endDate: _endDate,
          data: _attendanceData,
          title: 'Laporan Absensi',
        );
      }

      setState(() => _isLoading = false);

      if (file != null) {
        await _exportService.shareFile(file, file.path.split('/').last);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('File $_selectedFormat berhasil dibuat!'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        throw Exception('Gagal membuat file');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF121212)
          : const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Export Laporan'),
        centerTitle: true,
        backgroundColor: const Color.fromARGB(255, 196, 39, 235),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Start Date
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.calendar_today,
                  color: Color.fromARGB(255, 196, 39, 235),
                ),
                title: const Text('Tanggal Mulai'),
                subtitle: Text(
                  '${_startDate.day}/${_startDate.month}/${_startDate.year}',
                ),
                onTap: _selectStartDate,
              ),
            ),
            const SizedBox(height: 12),

            // End Date
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.calendar_today,
                  color: Color.fromARGB(255, 196, 39, 235),
                ),
                title: const Text('Tanggal Selesai'),
                subtitle: Text(
                  '${_endDate.day}/${_endDate.month}/${_endDate.year}',
                ),
                onTap: _selectEndDate,
              ),
            ),
            const SizedBox(height: 12),

            // Format
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedFormat,
                  decoration: const InputDecoration(
                    labelText: 'Format File',
                    border: InputBorder.none,
                  ),
                  items: _formats.map((format) {
                    return DropdownMenuItem(
                      value: format,
                      child: Row(
                        children: [
                          Icon(
                            format == 'PDF'
                                ? Icons.picture_as_pdf
                                : Icons.table_chart,
                            color: const Color.fromARGB(255, 196, 39, 235),
                          ),
                          const SizedBox(width: 8),
                          Text(format),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() => _selectedFormat = value!);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Load Data Button
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _loadData,
              icon: const Icon(Icons.search),
              label: const Text('Cari Data'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 196, 39, 235),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Info Data
            if (_attendanceData.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green),
                    const SizedBox(width: 8),
                    Text(
                      '${_attendanceData.length} data ditemukan',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],

            if (_errorMessage != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_errorMessage!)),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Export Button
            SizedBox(
              height: 54,
              child: ElevatedButton.icon(
                onPressed: _isLoading || _attendanceData.isEmpty
                    ? null
                    : _exportReport,
                icon: _isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        _selectedFormat == 'PDF'
                            ? Icons.picture_as_pdf
                            : Icons.table_chart,
                      ),
                label: Text(
                  _isLoading ? 'Memproses...' : 'Export ke $_selectedFormat',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color.fromARGB(255, 196, 39, 235),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
