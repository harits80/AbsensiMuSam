import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ExportService {
  final SupabaseClient _supabase = Supabase.instance.client;

  // Format tanggal ke Indonesia
  String _formatDate(DateTime date) {
    final months = [
      'Januari',
      'Februari',
      'Maret',
      'April',
      'Mei',
      'Juni',
      'Juli',
      'Agustus',
      'September',
      'Oktober',
      'November',
      'Desember',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  // Ambil data absensi berdasarkan rentang tanggal
  Future<List<Map<String, dynamic>>> getAttendanceData({
    required DateTime startDate,
    required DateTime endDate,
    int? organizationId,
    String? department,
  }) async {
    try {
      var query = _supabase
          .from('attendance')
          .select('''
            *,
            users!inner(
              id,
              name,
              email,
              role,
              user_profiles!inner(
                display_name,
                first_name,
                last_name,
                department_id,
                phone_number
              )
            )
          ''')
          .gte('timestamp', startDate.toIso8601String())
          .lte('timestamp', endDate.toIso8601String())
          .order('timestamp', ascending: false);

      if (organizationId != null) {
        // Filter by organization
      }

      final response = await query;
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('Error getting attendance data: $e');
      return [];
    }
  }

  // Generate PDF
  Future<File?> generatePDF({
    required DateTime startDate,
    required DateTime endDate,
    required List<Map<String, dynamic>> data,
    String title = 'Laporan Absensi',
  }) async {
    try {
      final pdf = pw.Document();

      // Header
      final header = pw.Container(
        padding: const pw.EdgeInsets.all(20),
        decoration: pw.BoxDecoration(color: PdfColors.blue700),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(
                fontSize: 24,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              'Periode: ${_formatDate(startDate)} - ${_formatDate(endDate)}',
              style: pw.TextStyle(fontSize: 12, color: PdfColors.grey200),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Tanggal Export: ${_formatDate(DateTime.now())}',
              style: pw.TextStyle(fontSize: 12, color: PdfColors.grey200),
            ),
          ],
        ),
      );

      // Statistik
      final totalAttendance = data.length;
      final totalHadir = data.where((d) => d['status'] == 'Hadir').length;
      final totalIzin = data.where((d) => d['status'] == 'Izin').length;
      final totalSakit = data.where((d) => d['status'] == 'Sakit').length;
      final totalAlpha = data.where((d) => d['status'] == 'Alpha').length;

      final stats = pw.Container(
        padding: const pw.EdgeInsets.all(16),
        margin: const pw.EdgeInsets.all(16),
        decoration: pw.BoxDecoration(
          color: PdfColors.grey100,
          borderRadius: pw.BorderRadius.circular(8),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
          children: [
            _buildStatBox(
              'Total',
              totalAttendance.toString(),
              PdfColors.blue700,
            ),
            _buildStatBox('Hadir', totalHadir.toString(), PdfColors.green),
            _buildStatBox('Izin', totalIzin.toString(), PdfColors.orange),
            _buildStatBox('Sakit', totalSakit.toString(), PdfColors.red),
            _buildStatBox('Alpha', totalAlpha.toString(), PdfColors.grey),
          ],
        ),
      );

      // Tabel
      final headers = ['No', 'Tanggal', 'Nama', 'Status', 'Metode', 'Waktu'];
      final rows = <List<pw.Widget>>[];

      for (int i = 0; i < data.length; i++) {
        final item = data[i];
        final timestamp = DateTime.parse(item['timestamp']);
        final user = item['users'] as Map<String, dynamic>?;
        final userName = user?['name'] ?? 'Unknown';

        rows.add([
          pw.Text((i + 1).toString()),
          pw.Text('${timestamp.day}/${timestamp.month}/${timestamp.year}'),
          pw.Text(userName),
          pw.Text(item['status'] ?? '-'),
          pw.Text(item['method'] ?? '-'),
          pw.Text(
            '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}',
          ),
        ]);
      }

      final table = pw.Table(
        border: pw.TableBorder.all(),
        columnWidths: {
          0: pw.FixedColumnWidth(30),
          1: pw.FixedColumnWidth(80),
          2: pw.FlexColumnWidth(),
          3: pw.FixedColumnWidth(60),
          4: pw.FixedColumnWidth(60),
          5: pw.FixedColumnWidth(60),
        },
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: PdfColors.blue100),
            children: headers
                .map(
                  (h) => pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(
                      h,
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                )
                .toList(),
          ),
          ...rows.map(
            (row) => pw.TableRow(
              children: row
                  .map(
                    (cell) => pw.Padding(
                      padding: const pw.EdgeInsets.all(8),
                      child: cell,
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      );

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          build: (context) => [header, stats, pw.SizedBox(height: 20), table],
        ),
      );

      // Simpan file
      final directory = await getApplicationDocumentsDirectory();
      final fileName =
          'laporan_absensi_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(await pdf.save());

      return file;
    } catch (e) {
      debugPrint('Error generating PDF: $e');
      return null;
    }
  }

  pw.Widget _buildStatBox(String label, String value, PdfColor color) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      child: pw.Column(
        children: [
          pw.Text(
            value,
            style: pw.TextStyle(
              fontSize: 20,
              fontWeight: pw.FontWeight.bold,
              color: color,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            label,
            style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
          ),
        ],
      ),
    );
  }

  // Generate Excel
  Future<File?> generateExcel({
    required DateTime startDate,
    required DateTime endDate,
    required List<Map<String, dynamic>> data,
    String title = 'Laporan Absensi',
  }) async {
    try {
      final excel = Excel.createExcel();
      final sheet = excel['Laporan Absensi'];

      // Header title
      sheet.appendRow([
        TextCellValue(title),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue(''),
      ]);
      sheet.appendRow([
        TextCellValue(
          'Periode: ${_formatDate(startDate)} - ${_formatDate(endDate)}',
        ),
      ]);
      sheet.appendRow([
        TextCellValue('Tanggal Export: ${_formatDate(DateTime.now())}'),
      ]);
      sheet.appendRow([]); // Empty row

      // Header kolom
      final headers = [
        'No',
        'Tanggal',
        'Nama',
        'Email',
        'Status',
        'Metode',
        'Jam Masuk',
        'Jam Keluar',
      ];
      sheet.appendRow(headers.map((h) => TextCellValue(h)).toList());

      // Data
      for (int i = 0; i < data.length; i++) {
        final item = data[i];
        final timestamp = DateTime.parse(item['timestamp']);
        final user = item['users'] as Map<String, dynamic>?;
        final userName = user?['name'] ?? 'Unknown';
        final userEmail = user?['email'] ?? '-';

        sheet.appendRow([
          TextCellValue((i + 1).toString()),
          TextCellValue(
            '${timestamp.day}/${timestamp.month}/${timestamp.year}',
          ),
          TextCellValue(userName),
          TextCellValue(userEmail),
          TextCellValue(item['status'] ?? '-'),
          TextCellValue(item['method'] ?? '-'),
          TextCellValue(
            '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}',
          ),
          TextCellValue('-'), // Check out time bisa ditambah nanti
        ]);
      }

      // Statistik
      sheet.appendRow([]);
      sheet.appendRow([TextCellValue('STATISTIK')]);
      final totalHadir = data.where((d) => d['status'] == 'Hadir').length;
      final totalIzin = data.where((d) => d['status'] == 'Izin').length;
      final totalSakit = data.where((d) => d['status'] == 'Sakit').length;
      final totalAlpha = data.where((d) => d['status'] == 'Alpha').length;

      sheet.appendRow([
        TextCellValue('Total Hadir:'),
        TextCellValue(totalHadir.toString()),
      ]);
      sheet.appendRow([
        TextCellValue('Total Izin:'),
        TextCellValue(totalIzin.toString()),
      ]);
      sheet.appendRow([
        TextCellValue('Total Sakit:'),
        TextCellValue(totalSakit.toString()),
      ]);
      sheet.appendRow([
        TextCellValue('Total Alpha:'),
        TextCellValue(totalAlpha.toString()),
      ]);

      // Simpan file
      final directory = await getApplicationDocumentsDirectory();
      final fileName =
          'laporan_absensi_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(excel.encode()!);

      return file;
    } catch (e) {
      debugPrint('Error generating Excel: $e');
      return null;
    }
  }

  // Share file
  Future<void> shareFile(File file, String fileName) async {
    final params = ShareParams(
      text: 'Berikut laporan absensi periode ${_formatDate(DateTime.now())}',
      files: [XFile(file.path, mimeType: 'application/pdf')],
    );
    await SharePlus.instance.share(params);
  }
}
