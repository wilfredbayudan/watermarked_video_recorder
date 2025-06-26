/// Represents a camera device with its properties
class CameraDescription {
  /// Unique identifier for the camera
  final String id;

  /// Direction the camera lens is facing
  final CameraLensDirection direction;

  /// Human-readable name for the camera
  final String label;

  const CameraDescription({required this.id, required this.direction, required this.label});

  @override
  String toString() {
    return 'CameraDescription(id: $id, direction: $direction, label: $label)';
  }
}

/// Direction the camera lens is facing
enum CameraLensDirection {
  /// Camera lens facing away from the user (rear camera)
  back,

  /// Camera lens facing toward the user (front camera)
  front,

  /// Camera lens facing external environment
  external,
}
