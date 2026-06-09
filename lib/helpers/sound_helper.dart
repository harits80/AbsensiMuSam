import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SoundHelper {
  static final AudioPlayer _audioPlayer = AudioPlayer();

  /// Play success sound from assets
  static Future<void> playSuccessSound() async {
    try {
      await _audioPlayer.play(AssetSource('sounds/succes.mp3'));
    } catch (e) {
      debugPrint('Error playing success sound: $e');
      // Fallback to system sound if asset fails
      await SystemSound.play(SystemSoundType.click);
    }
  }

  /// Play error sound from assets
  static Future<void> playErrorSound() async {
    try {
      await _audioPlayer.play(AssetSource('sounds/error.mp3'));
    } catch (e) {
      debugPrint('Error playing error sound: $e');
      // Fallback to system sound if asset fails
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  /// Dispose audio player resources
  static Future<void> dispose() async {
    await _audioPlayer.dispose();
  }
}
