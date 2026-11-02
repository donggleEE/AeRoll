/// PNG의 원래 알파를 유지하면서 사진 위에 합성하는 필름 필터.
class FilmFilter {
  const FilmFilter({required this.id, required this.name, this.assetPath});

  final String id;
  final String name;
  final String? assetPath;
}

const filmFilters = <FilmFilter>[
  FilmFilter(id: 'original', name: '원본'),
  FilmFilter(
    id: 'light',
    name: '라이트',
    assetPath: 'assets/images/filter/light.png',
  ),
  FilmFilter(
    id: 'cold',
    name: '콜드',
    assetPath: 'assets/images/filter/cold.png',
  ),
];

const samplePhotoAsset = 'assets/images/example/example_image.jpg';
