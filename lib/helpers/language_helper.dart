import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LanguageHelper {
  static const String _languageKey = 'selected_language';

  // Supported languages
  static const String indonesian = 'id';
  static const String english = 'en';
  static const String arabic = 'ar';

  // Default language
  static const String defaultLanguage = indonesian;

  static String _currentLanguage = defaultLanguage;

  // ValueNotifier untuk notify perubahan bahasa ke semua halaman
  static final ValueNotifier<String> languageNotifier = ValueNotifier<String>(
    defaultLanguage,
  );

  static String get currentLanguage => _currentLanguage;

  // Global map to store all translations loaded from JSON files
  static Map<String, dynamic> _localizedValues = {};

  // Get saved language and load translations
  static Future<String> getSavedLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString(_languageKey);

    _currentLanguage = savedLang ?? defaultLanguage;
    languageNotifier.value = _currentLanguage;

    await loadTranslations(_currentLanguage);

    return _currentLanguage;
  }

  // Load all JSON translation files for the given language
  static Future<void> loadTranslations(String languageCode) async {
    _localizedValues = {};

    // List of translation categories and their files
    final Map<String, List<String>> structure = {
      '': ['auth', 'common'], // Root files
      'Petugas/': ['dashboard', 'members', 'attendance'], // Petugas subfolder
      'User/': ['dashboard', 'history', 'profile'], // User subfolder
      'attendance/': [
        'rfid',
        'face',
        'selfie',
        'device_selection',
        'fingerprint',
      ], // Attendance subfolder
    };

    for (String folder in structure.keys) {
      for (String file in structure[folder]!) {
        try {
          String path = 'assets/Lang/$languageCode/json/$folder$file.json';
          String jsonString = await rootBundle.loadString(path);
          Map<String, dynamic> jsonMap = json.decode(jsonString);

          // Store with key "folder.file" or just "file" for root
          String key = folder.isEmpty
              ? file
              : '$folder$file'.replaceAll('/', '.');
          _localizedValues[key] = jsonMap;
        } catch (e) {
          // Silent fail for missing files
        }
      }
    }
  }

  // Save language and reload translations
  static Future<void> saveLanguage(String languageCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, languageCode);
    _currentLanguage = languageCode;
    languageNotifier.value = languageCode;

    await loadTranslations(languageCode);
  }

  // Get translation by key (format: "filename.key" or "folder.filename.key")
  static String translate(String key, String languageCode) {
    if (_localizedValues.isEmpty) return key;

    List<String> parts = key.split('.');

    if (parts.length >= 2) {
      // Try to find the map by joining parts except the last one
      String mapKey = parts.sublist(0, parts.length - 1).join('.');
      String realKey = parts.last;

      if (_localizedValues.containsKey(mapKey)) {
        return _localizedValues[mapKey]?[realKey]?.toString() ?? key;
      }
    }

    // Fallback: search in common or auth if no prefix or prefix not found
    return _localizedValues['common']?[key]?.toString() ??
        _localizedValues['auth']?[key]?.toString() ??
        key;
  }
}

// Simple helper method to get translation with current language
class AppLanguage {
  static String _currentLang = LanguageHelper.defaultLanguage;

  static Future<void> init() async {
    _currentLang = await LanguageHelper.getSavedLanguage();
  }

  static String get currentLanguage => _currentLang;

  static Future<void> setLanguage(String languageCode) async {
    _currentLang = languageCode;
    await LanguageHelper.saveLanguage(languageCode);
  }

  static String tr(String key) {
    return LanguageHelper.translate(key, _currentLang);
  }
}
