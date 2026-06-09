import 'dart:async';
import 'package:flutter/services.dart';

class FingerprintService {
  static const MethodChannel _channel = MethodChannel(
    'com.absensimassal/fingerprint',
  );

  final _statusController = StreamController<String>.broadcast();
  final _imageController = StreamController<Uint8List>.broadcast();
  final _identifyResultController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _registerSuccessController = StreamController<String>.broadcast();

  Stream<String> get onStatusUpdate => _statusController.stream;
  Stream<Uint8List> get onImageCaptured => _imageController.stream;
  Stream<Map<String, dynamic>> get onIdentificationResult =>
      _identifyResultController.stream;
  Stream<String> get onRegisterSuccess => _registerSuccessController.stream;

  // Aliases for Registration Page (to prevent breaking if already used)
  Stream<String> get statusStream => _statusController.stream;
  Stream<Uint8List> get imageStream => _imageController.stream;
  Stream<String> get registerSuccessStream => _registerSuccessController.stream;

  FingerprintService() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  Future<dynamic> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'status':
        _statusController.add(call.arguments as String);
        break;
      case 'onImage':
        _imageController.add(call.arguments as Uint8List);
        break;
      case 'onIdentifyResult':
        _identifyResultController.add(
          Map<String, dynamic>.from(call.arguments),
        );
        break;
      case 'onRegisterSuccess':
        _registerSuccessController.add(call.arguments as String);
        break;
    }
  }

  Future<bool> requestPermission() async {
    final bool? result = await _channel.invokeMethod<bool>('requestPermission');
    return result ?? false;
  }

  Future<String?> startScanner() async {
    return await _channel.invokeMethod<String>('startScanner');
  }

  Future<String?> stopScanner() async {
    return await _channel.invokeMethod<String>('stopScanner');
  }

  Future<String?> register(String userId) async {
    return await _channel.invokeMethod<String>('register', {'userId': userId});
  }

  Future<String?> startIdentification() async {
    return await _channel.invokeMethod<String>('identify');
  }

  Future<String?> loadTemplates(List<Map<String, dynamic>> templates) async {
    return await _channel.invokeMethod<String>('loadTemplates', {
      'templates': templates,
    });
  }

  Future<String?> deleteUser(String userId) async {
    return await _channel.invokeMethod<String>('delete', {'userId': userId});
  }

  Future<String?> clearAll() async {
    return await _channel.invokeMethod<String>('clear');
  }

  Future<String?> scanUSB() async {
    return await _channel.invokeMethod<String>('scanDevices');
  }

  void dispose() {
    _statusController.close();
    _imageController.close();
    _identifyResultController.close();
    _registerSuccessController.close();
  }
}
