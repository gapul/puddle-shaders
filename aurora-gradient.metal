// aurora-gradient — Metal fragment for Puddle's texture (shader) wallpaper renderer.
// Fragment-only: Puddle prepends the preamble (WallpaperUniforms / WallpaperVertexOut /
// wallpaperVertex) per Puddle docs/wallpaper-source-contract.md. Ported from aurora-gradient.html.
// user[0] = focused workspace (see configs/wallpaper/inputs, written by omniwm-event.sh).

// aurora-gradient.metal — MSL port of aurora-gradient.html (WebGL2)
// Puddle prepends the preamble (WallpaperUniforms / WallpaperVertexOut /
// wallpaperVertex). Do NOT redeclare them here.
//
// Original: background + 6 additive blobs with Gaussian falloff exp(-3.2*x^2).
// All per-frame uniforms (blob pos/radius/color, bg tint, a0) were computed in
// JS and uploaded; here they are recomputed in-shader from u.time and ws.
//
// Colors are kept in 0..255 space (as in the HTML) and normalized at output.
//
// Inputs (gapul convention, guarded by u.userCount):
//   user[0] = focused workspace number (0..9). 'S' scratchpad -> pass 10.
//   user[1] = covered flag (unused by this shader).
//   user[2] = OPTIONAL wall-clock hour (0..24, fractional) for the time-of-day
//             tint. Absent -> defaults to noon (bright/clean). The shader has no
//             wall clock, so this is the only way to drive the day/night look.

constant int NB = 6;

// Per-workspace accent sets (Rosé Pine). Index = workspace number.
// Rows 2/4/0 use 2 colors (3rd slot unused); PAL_COUNT gives the real length.
// Blob i takes color[i % count], matching applyWorkspace's cycling.
constant float3 PAL_COLORS[11][3] = {
  { float3(110,106,134), float3(144,140,170), float3(144,140,170) }, // 0 muted,subtle
  { float3(196,167,231), float3(49,116,143),  float3(156,207,216) }, // 1 iris,pine,foam
  { float3(156,207,216), float3(49,116,143),  float3(49,116,143)  }, // 2 foam,pine
  { float3(246,193,119), float3(235,188,186), float3(235,111,146) }, // 3 gold,rose,love
  { float3(235,111,146), float3(196,167,231), float3(196,167,231) }, // 4 love,iris
  { float3(49,116,143),  float3(156,207,216), float3(196,167,231) }, // 5 pine,foam,iris
  { float3(196,167,231), float3(235,111,146), float3(235,188,186) }, // 6 iris,love,rose
  { float3(156,207,216), float3(196,167,231), float3(49,116,143)  }, // 7 foam,iris,pine
  { float3(235,188,186), float3(235,111,146), float3(246,193,119) }, // 8 rose,love,gold
  { float3(196,167,231), float3(156,207,216), float3(235,111,146) }, // 9 iris,foam,love
  { float3(49,116,143),  float3(196,167,231), float3(156,207,216) }, // 10 'S' pine,iris,foam
};
constant int PAL_COUNT[11] = { 2, 3, 2, 3, 2, 3, 3, 3, 3, 3, 3 };

// Light appearance = Rosé Pine Dawn (system-theme.js `light`). followSystemTheme
// swaps RP before PALETTES derive from it, so this is the same table Dawn-colored.
constant float3 PAL_COLORS_LIGHT[11][3] = {
  { float3(152,147,165), float3(121,117,147), float3(121,117,147) }, // 0 muted,subtle
  { float3(144,122,169), float3(40,105,131),  float3(86,148,159)  }, // 1 iris,pine,foam
  { float3(86,148,159),  float3(40,105,131),  float3(40,105,131)  }, // 2 foam,pine
  { float3(234,157,52),  float3(215,130,126), float3(180,99,122)  }, // 3 gold,rose,love
  { float3(180,99,122),  float3(144,122,169), float3(144,122,169) }, // 4 love,iris
  { float3(40,105,131),  float3(86,148,159),  float3(144,122,169) }, // 5 pine,foam,iris
  { float3(144,122,169), float3(180,99,122),  float3(215,130,126) }, // 6 iris,love,rose
  { float3(86,148,159),  float3(144,122,169), float3(40,105,131)  }, // 7 foam,iris,pine
  { float3(215,130,126), float3(180,99,122),  float3(234,157,52)  }, // 8 rose,love,gold
  { float3(144,122,169), float3(86,148,159),  float3(180,99,122)  }, // 9 iris,foam,love
  { float3(40,105,131),  float3(144,122,169), float3(86,148,159)  }, // 10 'S' pine,iris,foam
};

constant float3 RP_BASE    = float3(25, 23, 36);
constant float3 RP_SURFACE = float3(31, 29, 46);
constant float3 RP_GOLD    = float3(246, 193, 119);
constant float3 RP_BASE_L    = float3(250, 244, 237);
constant float3 RP_SURFACE_L = float3(255, 250, 243);
constant float3 RP_GOLD_L    = float3(234, 157, 52);

// Baked blob orbit params (HTML randomized these at startup within these ranges:
// cx/cy[.2,.8] ax/ay[.12,.30] px/py[0,2pi] tx[22,46] ty[26,52]
// r0[.34,.52] rBreath[.06,.12] pr[0,2pi] tr[14,30]). Fixed spread here.
struct Blob { float cx, cy, ax, ay, px, py, tx, ty, r0, rBreath, pr, tr; };
constant Blob BLOBS[6] = {
  { 0.30, 0.35, 0.18, 0.15, 0.0, 1.2, 24, 30, 0.40, 0.08, 0.5, 16 },
  { 0.65, 0.30, 0.22, 0.20, 2.1, 3.4, 34, 42, 0.46, 0.10, 1.8, 22 },
  { 0.45, 0.60, 0.15, 0.25, 4.0, 0.7, 28, 48, 0.36, 0.07, 3.2, 18 },
  { 0.75, 0.70, 0.25, 0.18, 5.5, 2.5, 40, 36, 0.50, 0.11, 4.7, 26 },
  { 0.25, 0.65, 0.20, 0.22, 1.0, 5.0, 30, 52, 0.42, 0.09, 0.9, 14 },
  { 0.55, 0.45, 0.28, 0.14, 3.3, 4.2, 46, 26, 0.52, 0.06, 5.9, 30 },
};

constant float TWO_PI = 6.283185307179586;

fragment float4 wallpaperMain(WallpaperVertexOut       in   [[stage_in]],
                              constant WallpaperUniforms& u  [[buffer(0)]],
                              constant float*             user [[buffer(1)]])
{
  float W = u.resolution.x;
  float H = u.resolution.y;
  float minSide = min(W, H);
  float sec = u.time;

  // GLSL gl_FragCoord (bottom-left) per contract, then the HTML's own conversion
  // back to top-left CSS px (dpr==1). Net result is in.position.xy.
  float2 fragCoord = float2(in.position.x, u.resolution.y - in.position.y);
  float2 cssPx = float2(fragCoord.x, u.resolution.y - fragCoord.y);

  // workspace -> palette row
  int ws = (u.userCount > 0) ? int(user[0]) : 1;
  ws = clamp(ws, 0, 10);
  int count = PAL_COUNT[ws];

  // appearance (contract v2): 0 dark / 1 light
  bool light = (u.version >= 2) && (u._reserved.x >= 0.5);
  float3 rpBase    = light ? RP_BASE_L    : RP_BASE;
  float3 rpSurface = light ? RP_SURFACE_L : RP_SURFACE;
  float3 rpGold    = light ? RP_GOLD_L    : RP_GOLD;

  // time-of-day shift (HTML computeTimeShift). No wall clock in-shader: read
  // optional user[2] hour, else noon.
  float hr = (u.userCount > 2) ? user[2] : 12.0;
  float sunness    = 0.5 * (1.0 + cos((hr - 12.0) * M_PI_F / 12.0));
  float golden     = sin(fabs(hr - 12.0) * M_PI_F / 12.0);
  float warmth     = golden * min(1.0, sunness * 1.6);
  float brightness = 0.78 + 0.27 * sunness;
  float bgLift     = sunness;

  // tintBg(base): lift toward surface, then toward gold.
  float lift = bgLift * 0.18;
  float warmBg = warmth * 0.08;
  float3 bg = rpBase + (rpSurface - rpBase) * lift;
  bg = bg + (rpGold - bg) * warmBg;

  float a0 = 0.22 + 0.14 * sunness;
  float warmC = warmth * 0.30; // blob gold-shift (distinct from bg's 0.08)

  float3 sum = bg;
  for (int i = 0; i < NB; i++) {
    Blob b = BLOBS[i];

    // color: snap to target (single-pass; HTML's cur->tgt crossfade dropped).
    float3 col = light ? PAL_COLORS_LIGHT[ws][i % count] : PAL_COLORS[ws][i % count];
    col = col + (rpGold - col) * warmC;       // gold shift at dawn/dusk
    col = min(float3(255.0), col * brightness); // brightness multiply

    float x = (b.cx + b.ax * cos(sec * (TWO_PI / b.tx) + b.px)) * W;
    float y = (b.cy + b.ay * sin(sec * (TWO_PI / b.ty) + b.py)) * H;
    float r = (b.r0 + b.rBreath * sin(sec * (TWO_PI / b.tr) + b.pr)) * minSide;

    float d = length(cssPx - float2(x, y));
    float xn = d / r;
    float falloff = exp(-3.2 * xn * xn);
    sum += col * (a0 * falloff);
  }

  return float4(min(float3(255.0), sum) / 255.0, 1.0);
}