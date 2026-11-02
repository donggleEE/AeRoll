class SavedPhoto {
  const SavedPhoto({
    required this.id,
    required this.path,
    required this.createdAt,
    required this.filterName,
  });

  final String id;
  final String path;
  final DateTime createdAt;
  final String filterName;

  Map<String, Object> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'filterName': filterName,
  };

  factory SavedPhoto.fromJson(
    Map<String, dynamic> json, {
    required String path,
  }) {
    return SavedPhoto(
      id: json['id'] as String,
      path: path,
      createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
      filterName: json['filterName'] as String,
    );
  }
}
