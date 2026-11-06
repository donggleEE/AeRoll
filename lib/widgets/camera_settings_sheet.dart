import 'package:flutter/material.dart';

enum PhotoFrameRatio {
  wide('16:9', 9 / 16),
  classic('4:3', 3 / 4),
  square('1:1', 1);

  const PhotoFrameRatio(this.label, this.portraitRatio);
  final String label;
  final double portraitRatio;

  double forSize(Size size) =>
      size.width > size.height ? 1 / portraitRatio : portraitRatio;
}

class CameraSettingsSheet extends StatefulWidget {
  const CameraSettingsSheet({
    super.key,
    required this.gridEnabled,
    required this.levelEnabled,
    required this.frameRatio,
    required this.onGridChanged,
    required this.onLevelChanged,
    required this.onRatioChanged,
  });
  final bool gridEnabled;
  final bool levelEnabled;
  final PhotoFrameRatio frameRatio;
  final ValueChanged<bool> onGridChanged;
  final ValueChanged<bool> onLevelChanged;
  final ValueChanged<PhotoFrameRatio> onRatioChanged;

  @override
  State<CameraSettingsSheet> createState() => _CameraSettingsSheetState();
}

class _CameraSettingsSheetState extends State<CameraSettingsSheet> {
  late bool _grid = widget.gridEnabled;
  late bool _level = widget.levelEnabled;
  late PhotoFrameRatio _ratio = widget.frameRatio;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      key: const Key('camera-settings-sheet'),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .88),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      child: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          child: Theme(
            data: ThemeData.dark(useMaterial3: true),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 34,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white38,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '카메라 설정',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '설정 닫기',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
                SwitchListTile(
                  key: const Key('grid-switch'),
                  title: const Text('격자'),
                  subtitle: const Text('구도를 맞추는 3×3 안내선'),
                  value: _grid,
                  onChanged: (value) {
                    setState(() => _grid = value);
                    widget.onGridChanged(value);
                  },
                ),
                SwitchListTile(
                  key: const Key('level-switch'),
                  title: const Text('수평계'),
                  subtitle: const Text('기울기를 확인하고 수평을 맞춰요'),
                  value: _level,
                  onChanged: (value) {
                    setState(() => _level = value);
                    widget.onLevelChanged(value);
                  },
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: Text(
                    '사진 비율',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      for (final ratio in PhotoFrameRatio.values)
                        ChoiceChip(
                          key: ValueKey('ratio-${ratio.name}'),
                          label: Text(ratio.label),
                          selected: _ratio == ratio,
                          onSelected: (_) {
                            setState(() => _ratio = ratio);
                            widget.onRatioChanged(ratio);
                          },
                        ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    '동영상은 선택한 필름을 적용해 16:9 비율로 저장돼요.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
