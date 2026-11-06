#include <flutter/runtime_effect.glsl>
uniform vec2 uSize;
uniform float uSlope;
uniform vec3 uOffsets;
uniform float uIntensity;
uniform sampler2D uInput;
out vec4 fragColor;
void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
  #endif
  vec4 source = texture(uInput, uv);
  vec3 straight = source.a > 0.0 ? source.rgb / source.a : vec3(0.0);
  vec3 filtered = clamp(straight * uSlope + uOffsets, 0.0, 1.0);
  vec3 mixed = mix(straight, filtered, uIntensity);
  mixed = floor(clamp(mixed, 0.0, 1.0) * 255.0 + 0.5) / 255.0;
  fragColor = vec4(mixed * source.a, source.a);
}