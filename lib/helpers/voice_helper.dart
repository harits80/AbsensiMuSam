import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/foundation.dart';
import 'language_helper.dart'; // ✅ Added for dynamic language detection

class VoiceHelper {
  static final FlutterTts _flutterTts = FlutterTts();
  static bool _isInitialized = false;
  static bool _isSpeaking = false;
  static String _currentLanguage = '';
  static Future<void> _init() async {
    // Ambil bahasa yang sedang dipilih user di aplikasi
    final String activeLang = LanguageHelper.languageNotifier.value; // 'id', 'en', or 'ar'
    
    String ttsLang;
    switch (activeLang) {
      case 'ar':
        ttsLang = 'ar-SA'; // Arabic (Saudi Arabia)
        break;
      case 'en':
        ttsLang = 'en-US';
        break;
      default:
        ttsLang = 'id-ID';
    }

    if (_isInitialized && _currentLanguage == ttsLang) return;
    
    try {
      // Setup listeners  for completion
      _flutterTts.setCompletionHandler(() {
        _isSpeaking = false;
      });
      _flutterTts.setErrorHandler((msg) {
        _isSpeaking = false;
      });
      _flutterTts.setCancelHandler(() {
        _isSpeaking = false;
      });

      bool isInstalled = await _flutterTts.isLanguageInstalled(ttsLang);
      
      if (!isInstalled) {
        debugPrint('⚠️ TTS: Bahasa $ttsLang belum terinstall di HP ini.');
      }

      await _flutterTts.setLanguage(ttsLang);
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setVolume(1.0);
      
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _flutterTts.setQueueMode(0);
      }
      
      _isInitialized = true;
      _currentLanguage = ttsLang;
      debugPrint('✅ TTS: Voice Helper Initialized with $ttsLang');
    } catch (e) {
      debugPrint('❌ TTS: Initialization Error: $e');
    }
  }

  static Future<void> speak(String text, {bool force = false}) async {
    try {
      await _init(); 

      if (!force && _isSpeaking) {
        debugPrint('🔇 TTS: Busy speaking, skipping: $text');
        return;
      }

      await _flutterTts.stop();
      _isSpeaking = true;
      await _flutterTts.speak(text);
      debugPrint('🗣️ TTS Speaking ($_currentLanguage): $text');
    } catch (e) {
      _isSpeaking = false;
      debugPrint('⚠️ TTS Error: $e');
    }
  }

  static Future<void> stop() async {
    await _flutterTts.stop();
  }
}
