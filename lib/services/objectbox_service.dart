import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../objectbox.g.dart'; // This file will be generated in the next step
import '../models/biometric_entity.dart';

class ObjectBoxService {
  /// The Store of this app.
  late final Store store;

  /// A Box of BiometricEntity.
  late final Box<BiometricEntity> biometricBox;

  ObjectBoxService._create(this.store) {
    biometricBox = Box<BiometricEntity>(store);
  }

  /// Create an instance of ObjectBox to use throughout the app.
  static Future<ObjectBoxService> create() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final store = await openStore(directory: p.join(docsDir.path, "obx-absen"));
    return ObjectBoxService._create(store);
  }
}
