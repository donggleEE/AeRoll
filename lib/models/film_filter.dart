import 'filter_transform.dart';

/// PNG 에셋 대신 감마 인코딩 sRGB의 고정 변환을 선택한다.
class FilmFilter {
  const FilmFilter({required this.id, required this.name});

  final String id;
  final String name;
  bool get isOriginal => id == 'original';
  FilterTransform get transform => filterTransformFor(id);
}

const filmFilters = <FilmFilter>[
  FilmFilter(id: 'original', name: '원본'),
  FilmFilter(id: 'warm', name: 'warm'),
  FilmFilter(id: 'cold', name: 'cold'),
];

const samplePhotoAsset = 'assets/images/example/example_image.jpg';
