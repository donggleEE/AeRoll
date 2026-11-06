import 'package:flutter/material.dart';

import '../models/film_filter.dart';
import 'film_filter_effect.dart';

/// 공통 예시 사진에 카메라와 같은 고정 RGB 변환을 표시한다.
class FilmFilterSelector extends StatelessWidget {
  const FilmFilterSelector({
    super.key,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
    this.intensity = 1,
  });

  final FilmFilter selected;
  final ValueChanged<FilmFilter> onChanged;
  final bool enabled;
  final double intensity;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: Center(
      child: ListView.separated(
        shrinkWrap: true,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: filmFilters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final filter = filmFilters[index];
          final isSelected = selected.id == filter.id;
          return Semantics(
            button: true,
            selected: isSelected,
            label: '${filter.name} 필터 선택',
            child: Tooltip(
              message: filter.name,
              child: InkWell(
                key: ValueKey('filter-${filter.id}'),
                onTap: enabled ? () => onChanged(filter) : null,
                borderRadius: BorderRadius.circular(9),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 52,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSelected ? Colors.white : Colors.transparent,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: FilmFilterEffect(
                      filter: filter,
                      intensity: isSelected ? intensity : 1,
                      child: Image.asset(
                        samplePhotoAsset,
                        fit: BoxFit.cover,
                        cacheWidth: 240,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
