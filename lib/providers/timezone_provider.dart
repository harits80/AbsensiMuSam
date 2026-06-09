import 'package:flutter/material.dart';
import '../services/timezone_service.dart';

class TimezoneProvider extends ChangeNotifier {
  String _currentTimezone = 'Asia/Jakarta';
  bool _autoDetect = true;
  DateTime? _currentTime;

  String get currentTimezone => _currentTimezone;
  bool get autoDetect => _autoDetect;
  DateTime? get currentTime => _currentTime;

  final TimezoneService _service = TimezoneService();

  Future<void> loadSettings() async {
    _currentTimezone = await _service.getSelectedTimezone();
    _autoDetect = await _service.isAutoDetectEnabled();
    notifyListeners();
  }

  Future<void> setTimezone(String timezone) async {
    _currentTimezone = timezone;
    await _service.setSelectedTimezone(timezone);
    notifyListeners();
  }

  Future<void> setAutoDetect(bool value) async {
    _autoDetect = value;
    await _service.setAutoDetectEnabled(value);
    notifyListeners();
  }

  Future<void> updateCurrentTime() async {
    _currentTime = await _service.getCurrentTimeInTimezone();
    notifyListeners();
  }

  String getTimezoneDisplay() {
    final info = TimezoneService.getTimezoneInfo(_currentTimezone);
    if (info != null) {
      return '${info['display']} (${info['gmt']})';
    }
    return _currentTimezone;
  }

  String getGMTOffset() {
    final info = TimezoneService.getTimezoneInfo(_currentTimezone);
    return info?['gmt'] ?? 'GMT+7';
  }
}
