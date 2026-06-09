import 'package:objectbox/objectbox.dart';

@Entity()
class BiometricEntity {
  @Id()
  int id = 0; // Internal ObjectBox ID

  @Index()
  int supabaseId; // Original ID from Supabase

  @Index()
  int organizationMemberId;

  @Index()
  int organizationId;

  String biometricType; // 'face_recognition' or 'fingerprint'

  // ✅ AI OPTIMIZED: Store embedding as primitive list for 10x speed
  List<double>? embedding;

  String? templateData; // Extra JSON data (version, quality, etc)
  
  @Property(type: PropertyType.date)
  DateTime enrollmentDate;
  
  @Property(type: PropertyType.date)
  DateTime? lastUsedAt;
  
  bool isActive;

  // Cached user info for instant display
  String? userName;
  String? departmentName;
  String? profilePhotoUrl;

  BiometricEntity({
    this.supabaseId = 0,
    required this.organizationMemberId,
    required this.organizationId,
    required this.biometricType,
    this.embedding,
    this.templateData,
    required this.enrollmentDate,
    this.isActive = true,
    this.userName,
    this.departmentName,
    this.profilePhotoUrl,
  });
}
