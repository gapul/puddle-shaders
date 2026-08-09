// topographic — Metal fragment for Puddle's texture (shader) wallpaper renderer.
// Fragment-only: Puddle prepends the preamble (WallpaperUniforms / WallpaperVertexOut /
// wallpaperVertex) per Puddle docs/wallpaper-source-contract.md. Ported from topographic.html.
// user[0] = focused workspace (see configs/wallpaper/inputs, written by omniwm-event.sh).

// Topographic wallpaper — MSL port of topographic.html WebGL2 fragment shader.
// Preamble (WallpaperUniforms, WallpaperVertexOut, wallpaperVertex) is prepended
// by Puddle — do NOT redeclare it here.
//
// Single pass, no ping-pong / feedback: h(x,y,t) is a pure function of pixel + time.
//
// Two source uniforms could not be reproduced 1:1 and are handled below:
//   - uDpr: Puddle gives drawable pixels only, no backing-scale. Fixed DPR knob.
//   - time-of-day tint (uBright/uWarm/uBg*): source reads the real wall clock
//     (new Date().getHours()). No wall clock in the shader → pinned to midday.

// ponytail: DPR is a taste knob (device-px → point-space frequency of the terrain).
// Source clamped devicePixelRatio to 1.5; matched here. Bump if terrain looks too coarse.
constant float DPR  = 1.5;
constant float SPAN = 1.4;   // contours placed in -SPAN..SPAN (source `span`)

// undulation drift: source did `undulation += 0.0008` per ~30fps frame (FRAME_MS=33).
// rate = 0.0008 * (1000/33) ≈ 0.024242 per real second.
constant float UNDULATION_RATE = 0.024242;

// ── Rosé Pine colors used by the tint math (0..255) ──
constant float3 RP_base    = float3(25, 23, 36);
constant float3 RP_surface = float3(31, 29, 46);
constant float3 RP_gold    = float3(246, 193, 119);
// Light appearance = Rosé Pine Dawn (system-theme.js `light`).
constant float3 RP_base_l    = float3(250, 244, 237);
constant float3 RP_surface_l = float3(255, 250, 243);
constant float3 RP_gold_l    = float3(234, 157, 52);

// ── Fixed "midday" time-of-day state (no wall clock available) ──
// Source computeTimeShift() at hr=12: sunness=1, golden=0.
//   brightness = 0.78 + 0.27*sunness = 1.05
//   warmth     = 0 (→ contour gold shift uWarm = warmth*0.30 = 0)
//   bgLift     = sunness = 1
constant float U_BRIGHT   = 1.05;  // uBright
constant float U_WARM     = 0.0;   // uWarm  (contour gold shift)
constant float BG_LIFT    = 1.0;   // t.bgLift
constant float BG_WARM_T  = 0.0;   // t.warmth (feeds tintBg's gold term)

// ── Per-workspace palette table (from PALETTES in topographic.html) ──
// Indexed by integer workspace: index 0 = key '0', index 1..9 = keys '1'..'9'.
// Key 'S' (scratch) is not integer-addressable via user[0] and is dropped.
//   lo/hi   : contour colors (0..255), lerped lo→hi by elevation
//   levels  : contour count      scale : noise coarseness
struct WSParam { float3 lo; float3 hi; float levels; float scale; };

constant WSParam WS[10] = {
  // '0' — muted → subtle, quiet monochrome
  { float3(110,106,134), float3(144,140,170), 6.0,  0.0020 },
  // '1' — pine → iris  (default)
  { float3(49,116,143),  float3(196,167,231), 7.0,  0.0022 },
  // '2' — pine → foam  (fine)
  { float3(49,116,143),  float3(156,207,216), 10.0, 0.0034 },
  // '3' — rose → gold  (gentle)
  { float3(235,188,186), float3(246,193,119), 6.0,  0.0018 },
  // '4' — iris → love  (dense)
  { float3(196,167,231), float3(235,111,146), 9.0,  0.0030 },
  // '5' — foam → pine
  { float3(156,207,216), float3(49,116,143),  7.0,  0.0024 },
  // '6' — love → iris
  { float3(235,111,146), float3(196,167,231), 8.0,  0.0027 },
  // '7' — foam → iris  (very gentle)
  { float3(156,207,216), float3(196,167,231), 6.0,  0.0016 },
  // '8' — gold → love
  { float3(246,193,119), float3(235,111,146), 9.0,  0.0031 },
  // '9' — iris → foam
  { float3(196,167,231), float3(156,207,216), 7.0,  0.0025 },
};

// Dawn lo/hi contour colors, same row order as WS (levels/scale unchanged).
// followSystemTheme swaps RP before PALETTES derive from it in the HTML.
constant float3 WS_LIGHT[10][2] = {
  { float3(152,147,165), float3(121,117,147) }, // '0' muted -> subtle
  { float3(40,105,131),  float3(144,122,169) }, // '1' pine -> iris
  { float3(40,105,131),  float3(86,148,159)  }, // '2' pine -> foam
  { float3(215,130,126), float3(234,157,52)  }, // '3' rose -> gold
  { float3(144,122,169), float3(180,99,122)  }, // '4' iris -> love
  { float3(86,148,159),  float3(40,105,131)  }, // '5' foam -> pine
  { float3(180,99,122),  float3(144,122,169) }, // '6' love -> iris
  { float3(86,148,159),  float3(144,122,169) }, // '7' foam -> iris
  { float3(234,157,52),  float3(180,99,122)  }, // '8' gold -> love
  { float3(144,122,169), float3(86,148,159)  }, // '9' iris -> foam
};

// ── Gradient (Perlin) noise — direct port of the GLSL helpers ──
static float hash(float2 c) {
  float2 p = fract(c * float2(0.1031, 0.1030));
  p += dot(p, p.yx + 33.33);
  return fract((p.x + p.y) * p.x);
}
// grid gradient (±1,±1) dotted with offset d
static float dotGrad(float2 c, float2 d) {
  float h  = hash(c);
  float sx = fract(h * 1.0) < 0.5 ? -1.0 : 1.0;
  float sy = fract(h * 7.0) < 0.5 ? -1.0 : 1.0;
  return sx * d.x + sy * d.y;
}
static float noise2D(float2 P) {
  float2 i = floor(P);
  float2 f = P - i;
  float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0); // quintic fade
  float a = dotGrad(i + float2(0.0, 0.0), f - float2(0.0, 0.0));
  float b = dotGrad(i + float2(1.0, 0.0), f - float2(1.0, 0.0));
  float c = dotGrad(i + float2(0.0, 1.0), f - float2(0.0, 1.0));
  float d = dotGrad(i + float2(1.0, 1.0), f - float2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static float fbm(float2 p) {
  return noise2D(p) * 0.65 + noise2D(p * 2.13 + float2(19.1, 7.3)) * 0.35;
}

// Background tint (port of tintBg): lift toward surface, then toward gold.
// surface/gold passed in so light appearance can retarget the tint.
static float3 tintBg(float3 c, float3 surface, float3 gold) {
  float lift = BG_LIFT * 0.22;
  float warm = BG_WARM_T * 0.10;
  float3 x = c + (surface - c) * lift;
  x = x + (gold - x) * warm;
  return x;
}

fragment float4 wallpaperMain(WallpaperVertexOut       in   [[stage_in]],
                              constant WallpaperUniforms& u  [[buffer(0)]],
                              constant float*             user [[buffer(1)]])
{
  // gl_FragCoord emulation (y-up), then to CSS-px / top-left like the source.
  float2 fragCoord = float2(in.position.x, u.resolution.y - in.position.y);
  float2 cssPx = float2(fragCoord.x, u.resolution.y - fragCoord.y) / DPR;
  float  uH    = u.resolution.y / DPR;   // CSS-px screen height

  // Workspace → palette params (recompute all workspace-derived uniforms here).
  int ws = (u.userCount > 0) ? int(user[0]) : 1;
  ws = clamp(ws, 0, 9);
  WSParam P = WS[ws];

  // Appearance (contract v2): 0 dark / 1 light.
  bool light = (u.version >= 2) && (u._reserved.x >= 0.5);
  if (light) { P.lo = WS_LIGHT[ws][0]; P.hi = WS_LIGHT[ws][1]; }
  float3 rpBase    = light ? RP_base_l    : RP_base;
  float3 rpSurface = light ? RP_surface_l : RP_surface;
  float3 rpGold    = light ? RP_gold_l    : RP_gold;

  float undulation = u.time * UNDULATION_RATE;

  // Height field h(x,y,t): x = px*scale, y = py*scale + undulation.
  float h = fbm(float2(cssPx.x * P.scale, cssPx.y * P.scale + undulation));

  // Background: surface (top) → base (from mid-height down).
  float gy = clamp(cssPx.y / (0.5 * uH), 0.0, 1.0);
  float3 bg = mix(tintBg(rpSurface, rpSurface, rpGold), tintBg(rpBase, rpSurface, rpGold), gy) / 255.0;
  float3 outc = bg;

  // Contours: map height to 0..(levels-1); integers are contour lines.
  float m  = (h + SPAN) / (2.0 * SPAN) * (P.levels - 1.0);
  float aa = max(fwidth(m), 1e-5);
  float k  = floor(m + 0.5);
  if (k >= 0.0 && k <= P.levels - 1.0) {
    float d   = abs(m - k);
    float dpx = d / aa;

    float kfrac = P.levels > 1.0 ? k / (P.levels - 1.0) : 0.0; // 0..1 elevation
    float lw    = 0.8 + 0.4 * kfrac;                            // line width px

    float cov = 1.0 - smoothstep(lw * 0.5 - 0.5, lw * 0.5 + 0.5, dpx);

    float3 col = mix(P.lo, P.hi, kfrac);
    col = mix(col, rpGold, U_WARM);
    col = min(float3(255.0), col * U_BRIGHT) / 255.0;

    float alpha = (0.32 + 0.30 * kfrac) * cov;
    outc = mix(outc, col, alpha);
  }

  return float4(outc, 1.0);
}