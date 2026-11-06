import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../models/film_filter.dart';
import '../models/filter_transform.dart';

/// 최종 클리핑된 필터와 원본을 혼합한다. 배경·격자는 감싸지 않는다.
class FilmFilterEffect extends StatefulWidget {
  const FilmFilterEffect({
    super.key,
    required this.filter,
    required this.child,
    this.enabled = true,
    this.intensity = 1,
    this.opaque = false,
  });
  final FilmFilter filter;
  final Widget child;
  final bool enabled;
  final double intensity;

  /// 불투명 카메라 Texture의 비Impeller 호환 경로에 사용한다.
  final bool opaque;

  @override
  State<FilmFilterEffect> createState() => _FilmFilterEffectState();
}

class _FilmFilterEffectState extends State<FilmFilterEffect> {
  static Future<ui.FragmentProgram>? _program;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (ui.ImageFilter.isShaderFilterSupported) _load();
  }

  Future<void> _load() async {
    try {
      final program = await (_program ??= ui.FragmentProgram.fromAsset(
        'assets/shaders/film_filter.frag',
      ));
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (error, stack) {
      // 로딩 실패 때도 같은 혼합식을 쓰는 호환 경로를 유지한다.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'AeRoll 필터',
        ),
      );
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intensity = widget.intensity;
    FilterTransform.validateIntensity(intensity);
    if (!widget.enabled || widget.filter.isOriginal || intensity == 0) {
      return widget.child;
    }
    final transform = widget.filter.transform;
    final full = ColorFilter.matrix(transform.colorMatrix);
    final shader = _shader;
    if (shader != null) {
      shader.setFloat(2, transform.slope);
      final offsets = transform.offsets;
      for (var i = 0; i < 3; i++) {
        shader.setFloat(3 + i, offsets[i]);
      }
      shader.setFloat(6, intensity);
      return ImageFiltered(
        imageFilter: ui.ImageFilter.shader(shader),
        child: widget.child,
      );
    }
    if (intensity == 1) {
      return ColorFiltered(colorFilter: full, child: widget.child);
    }
    if (widget.opaque) {
      // 같은 controller의 불투명 Texture만 다시 그리며 재초기화하지 않는다.
      return Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: intensity,
                child: ColorFiltered(colorFilter: full, child: widget.child),
              ),
            ),
          ),
        ],
      );
    }
    return _RasterFilterMix(
      colorFilter: full,
      intensity: intensity,
      child: widget.child,
    );
  }
}

/// 비Impeller의 일반 이미지·래스터 자식용. 알파를 가중 합산해 보존한다.
class _RasterFilterMix extends SingleChildRenderObjectWidget {
  const _RasterFilterMix({
    required this.colorFilter,
    required this.intensity,
    required super.child,
  });
  final ColorFilter colorFilter;
  final double intensity;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRasterFilterMix(colorFilter, intensity);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRasterFilterMix renderObject,
  ) {
    renderObject.update(colorFilter, intensity);
  }
}

class _RenderRasterFilterMix extends RenderProxyBox {
  _RenderRasterFilterMix(this._filter, this._intensity);
  ColorFilter _filter;
  double _intensity;

  void update(ColorFilter filter, double intensity) {
    if (_filter == filter && _intensity == intensity) return;
    _filter = filter;
    _intensity = intensity;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final canvas = context.canvas;
    final bounds = offset & size;
    canvas.saveLayer(bounds, Paint());
    canvas.saveLayer(
      bounds,
      Paint()..color = Color.fromRGBO(255, 255, 255, 1 - _intensity),
    );
    context.paintChild(child!, offset);
    canvas.restore();
    canvas.saveLayer(
      bounds,
      Paint()
        ..color = Color.fromRGBO(255, 255, 255, _intensity)
        ..blendMode = BlendMode.plus,
    );
    canvas.saveLayer(bounds, Paint()..colorFilter = _filter);
    context.paintChild(child!, offset);
    canvas.restore();
    canvas.restore();
    canvas.restore();
  }
}
