// lib/models/face_tracking_state.dart

/// State machine for reliable face recognition
enum FaceTrackingState {
  idle,          // No processing, face just detected
  tracking,      // Tracking face movement
  locked,        // Face locked for processing
  livenessCheck, // ✅ NEW: Running anti-spoofing liveness detection
  cooldown,      // Waiting before next recognition
}
