import 'package:flutter/material.dart';
import '../../services/timezone_service.dart';

class TimezoneSettingsScreen extends StatefulWidget {
  final String? currentTimezone;

  const TimezoneSettingsScreen({super.key, this.currentTimezone});

  @override
  State<TimezoneSettingsScreen> createState() => _TimezoneSettingsScreenState();
}

class _TimezoneSettingsScreenState extends State<TimezoneSettingsScreen> {
  String _searchQuery = '';
  bool _autoDetect = true;
  String _currentTimezone = 'Asia/Jakarta';
  String _timezoneDisplay = 'Jakarta (WIB)';
  final TimezoneService _timezoneService = TimezoneService();
  bool _isSaving = false; // ← TAMBAHKAN

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final initialTimezone = widget.currentTimezone;

    final autoDetect = await _timezoneService.isAutoDetectEnabled();
    String tz;
    if (initialTimezone != null && initialTimezone.isNotEmpty) {
      tz = initialTimezone;
      await _timezoneService.setSelectedTimezone(tz);
    } else {
      tz = await _timezoneService.getSelectedTimezone();
    }

    final info = TimezoneService.getTimezoneInfo(tz);
    if (mounted) {
      setState(() {
        _autoDetect = autoDetect;
        _currentTimezone = tz;
        _timezoneDisplay = info?['display'] ?? tz;
      });
    }
  }

  Future<void> _setAutoDetect(bool value) async {
    await _timezoneService.setAutoDetectEnabled(value);
    if (mounted) {
      setState(() {
        _autoDetect = value;
      });
    }
  }

  Future<void> _setTimezone(String tzName, String display) async {
    if (_isSaving) return; // ← TAMBAHKAN

    setState(() => _isSaving = true); // ← TAMBAHKAN

    try {
      await _timezoneService.setSelectedTimezone(tzName);

      if (mounted) {
        // Kirim data kembali ke UserProfilePage
        Navigator.pop(context, {'timezone': tzName, 'display': display});
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  List<Map<String, String>> get _filteredTimezones {
    if (_searchQuery.isEmpty) {
      return TimezoneService.availableTimezones;
    }
    return TimezoneService.availableTimezones.where((tz) {
      final display = tz['display']?.toLowerCase() ?? '';
      final name = tz['name']?.toLowerCase() ?? '';
      final gmt = tz['gmt']?.toLowerCase() ?? '';
      final query = _searchQuery.toLowerCase();
      return display.contains(query) ||
          name.contains(query) ||
          gmt.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF121212)
          : const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Pengaturan Timezone'),
        centerTitle: true,
        backgroundColor: const Color(0xFF9333EA),
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
      ),
      body: Column(
        children: [
          // Current Time Preview
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF9333EA), Color(0xFF6B21A8)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                const Text(
                  'Waktu Saat Ini',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 8),
                StreamBuilder(
                  stream: Stream.periodic(const Duration(seconds: 1)),
                  builder: (context, snapshot) {
                    return FutureBuilder<DateTime>(
                      future: _timezoneService.getCurrentTimeInTimezone(),
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          final time = snapshot.data!;
                          final hour = time.hour.toString().padLeft(2, '0');
                          final minute = time.minute.toString().padLeft(2, '0');
                          final second = time.second.toString().padLeft(2, '0');
                          return Column(
                            children: [
                              Text(
                                '$hour:$minute:$second',
                                style: const TextStyle(
                                  fontSize: 36,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _timezoneDisplay,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          );
                        }
                        return const CircularProgressIndicator(
                          color: Colors.white,
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),

          // Auto Detect Switch
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.location_on,
                      color: _autoDetect ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Deteksi Otomatis',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                Switch(
                  value: _autoDetect,
                  onChanged: (value) async {
                    await _setAutoDetect(value);
                  },
                  activeTrackColor: const Color(
                    0xFF9333EA,
                  ).withValues(alpha: 0.5),
                  activeThumbColor: const Color(0xFF9333EA),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Search Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: InputDecoration(
                hintText: 'Cari timezone...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: isDark
                    ? const Color(0xFF2C2C2C)
                    : const Color(0xFFF0F0F0),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Timezone List
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _filteredTimezones.length,
              itemBuilder: (context, index) {
                final tz = _filteredTimezones[index];
                final isSelected = _currentTimezone == tz['name'];

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFF9333EA)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isSelected
                          ? const Color(0xFF9333EA)
                          : Colors.grey.shade200,
                      child: Text(
                        tz['gmt']
                                ?.replaceAll('GMT', '')
                                .replaceAll('+', '')
                                .replaceAll('-', '') ??
                            '',
                        style: TextStyle(
                          fontSize: 10,
                          color: isSelected ? Colors.white : Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      tz['display'] ?? '',
                      style: TextStyle(
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected ? const Color(0xFF9333EA) : null,
                      ),
                    ),
                    subtitle: Text('${tz['gmt']} - ${tz['name']}'),
                    trailing: isSelected
                        ? const Icon(
                            Icons.check_circle,
                            color: Color(0xFF9333EA),
                          )
                        : null,
                    onTap: () async {
                      await _setTimezone(tz['name']!, tz['display'] ?? '');
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
