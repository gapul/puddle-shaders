// constellation — Metal fragment for Puddle's texture (shader) wallpaper renderer.
// Fragment-only: Puddle prepends the preamble (WallpaperUniforms / WallpaperVertexOut /
// wallpaperVertex) per Puddle docs/wallpaper-source-contract.md. Ported from constellation.html.
// user[0] = focused workspace (see configs/wallpaper/inputs, written by omniwm-event.sh).

// constellation.metal — MSL port of constellation.html (WebGL2)
// Puddle prepends the preamble (WallpaperUniforms / WallpaperVertexOut /
// wallpaperVertex). Do NOT redeclare them here.
//
// The HTML is NOT a fragment effect: it runs a CPU particle sim (up to 90 nodes
// drifting + bouncing off the window edges) and draws it with gl.LINES /
// gl.POINTS. The two GLSL fragments are trivial (bg gradient + vertex-color
// passthrough). To fit Puddle's single fullscreen-fragment contract, the whole
// sim is reimplemented per-pixel here.
//
// Faithfulness / single-pass:
//   * Node motion is reproduced in closed form from u.time (deterministic hash
//     init + analytic wall reflection), so NO feedback/ping-pong is needed.
//   * The HTML's cur->target color/dist crossfade on workspace change is dropped
//     (snap to target), exactly like aurora-gradient.metal.
//   * computeTimeShift() reads the OS wall clock; the shader has none, so the
//     day/night tint reads an optional wall-clock hour from user[2] (else noon).
//   * DPR: the HTML sizes (dist/radius) are CSS px at devicePixelRatio<=2. Puddle
//     gives drawable px, so we work in CSS-px space (res/DPR, DPR=2) to keep the
//     original density/proportions. Wrong DPR only rescales the look.
//
// Colors kept in 0..255 (as in the HTML), normalized at output.
//
// Inputs (gapul convention, guarded by u.userCount):
//   user[0] = focused workspace number (0..9). 'S' scratchpad has no float form
//             and maps to workspace 1 (unreachable via this input).
//   user[1] = covered flag (unused by this shader).
//   user[2] = OPTIONAL wall-clock hour (0..24, fractional) for the day/night
//             tint. Absent -> noon.

constant int MAX_N = 90;
constant float DPR = 2.0;            // assumed devicePixelRatio (HTML caps at 2)
constant float FPS = 1000.0 / 33.0;  // HTML FRAME_MS = 33 -> ~30.3 fps

// Rosé Pine palette (main/dark), 0..255.
constant float3 RP_BASE    = float3(25, 23, 36);
constant float3 RP_SURFACE = float3(31, 29, 46);
constant float3 RP_MUTED   = float3(110, 106, 134);
constant float3 RP_SUBTLE  = float3(144, 140, 170);
constant float3 RP_GOLD    = float3(246, 193, 119);
constant float3 RP_ROSE    = float3(235, 188, 186);
constant float3 RP_PINE    = float3(49, 116, 143);
constant float3 RP_FOAM    = float3(156, 207, 216);
constant float3 RP_IRIS    = float3(196, 167, 231);
constant float3 RP_LOVE    = float3(235, 111, 146);

// Per-workspace params (PALETTES in the HTML). Index = workspace number.
// a,b = gradient endpoints; count = nodes; dist = connect threshold(px); speed.
// 'S' has no numeric index; index 1 is the default fallback (applyWorkspace).
struct WSParams { float3 a; float3 b; float count; float dist; float speed; };
constant WSParams PAL[10] = {
  { RP_MUTED, RP_SUBTLE, 64.0, 144.0, 0.18 }, // 0 灰 静か
  { RP_IRIS,  RP_PINE,   72.0, 140.0, 0.30 }, // 1 紫→青 標準 (default)
  { RP_FOAM,  RP_PINE,   88.0, 120.0, 0.42 }, // 2 シアン→青 高密
  { RP_GOLD,  RP_ROSE,   60.0, 150.0, 0.24 }, // 3 金→ローズ 疎
  { RP_LOVE,  RP_IRIS,   84.0, 130.0, 0.46 }, // 4 紅→紫 活発
  { RP_PINE,  RP_FOAM,   70.0, 138.0, 0.32 }, // 5 青→シアン
  { RP_IRIS,  RP_LOVE,   78.0, 132.0, 0.36 }, // 6 紫→紅
  { RP_FOAM,  RP_IRIS,   62.0, 158.0, 0.22 }, // 7 シアン→紫 大網
  { RP_ROSE,  RP_LOVE,   82.0, 126.0, 0.40 }, // 8 ローズ→紅 密
  { RP_IRIS,  RP_FOAM,   74.0, 136.0, 0.34 }, // 9 紫→シアン
};

// Light appearance = Rosé Pine Dawn (system-theme.js `light`). followSystemTheme
// swaps the RP object before PALETTES derive from it in the HTML.
constant float3 RPL_BASE    = float3(250, 244, 237);
constant float3 RPL_SURFACE = float3(255, 250, 243);
constant float3 RPL_MUTED   = float3(152, 147, 165);
constant float3 RPL_SUBTLE  = float3(121, 117, 147);
constant float3 RPL_GOLD    = float3(234, 157, 52);
constant float3 RPL_ROSE    = float3(215, 130, 126);
constant float3 RPL_PINE    = float3(40, 105, 131);
constant float3 RPL_FOAM    = float3(86, 148, 159);
constant float3 RPL_IRIS    = float3(144, 122, 169);
constant float3 RPL_LOVE    = float3(180, 99, 122);

// Dawn a/b gradient endpoints, same row order as PAL (count/dist/speed unchanged).
constant float3 PAL_LIGHT[10][2] = {
  { RPL_MUTED, RPL_SUBTLE }, // 0
  { RPL_IRIS,  RPL_PINE   }, // 1
  { RPL_FOAM,  RPL_PINE   }, // 2
  { RPL_GOLD,  RPL_ROSE   }, // 3
  { RPL_LOVE,  RPL_IRIS   }, // 4
  { RPL_PINE,  RPL_FOAM   }, // 5
  { RPL_IRIS,  RPL_LOVE   }, // 6
  { RPL_FOAM,  RPL_IRIS   }, // 7
  { RPL_ROSE,  RPL_LOVE   }, // 8
  { RPL_IRIS,  RPL_FOAM   }, // 9
};

// Deterministic per-node hash, stands in for Math.random() at load.
static inline float h11(float i, float seed) {
  return fract(sin(i * 127.1 + seed * 311.7) * 43758.5453);
}

// Fold p into [0, L] by mirror reflection == the HTML's wall-bounce integration.
static inline float foldReflect(float p, float L) {
  float m = fmod(p, 2.0 * L);
  if (m < 0.0) m += 2.0 * L;
  return (m > L) ? (2.0 * L - m) : m;
}

// Distance from point p to segment a-b.
static inline float segDist(float2 p, float2 a, float2 b) {
  float2 pa = p - a, ba = b - a;
  float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
  return length(pa - ba * h);
}

fragment float4 wallpaperMain(WallpaperVertexOut       in   [[stage_in]],
                              constant WallpaperUniforms& u  [[buffer(0)]],
                              constant float*             user [[buffer(1)]])
{
  // CSS-px working space (HTML W,H = window px at DPR).
  float2 W = u.resolution / DPR;

  // GLSL gl_FragCoord (bottom-left, y-up), then to CSS px.
  float2 fragCoord = float2(in.position.x, u.resolution.y - in.position.y);
  float2 fc = fragCoord / DPR;   // y-up, [0,W]

  // workspace -> params (PALETTES[ws] || PALETTES['1']).
  int ws = (u.userCount > 0) ? int(user[0]) : 1;
  if (ws < 0 || ws > 9) ws = 1;
  WSParams pal = PAL[ws];

  // appearance (contract v2): 0 dark / 1 light
  bool light = (u.version >= 2) && (u._reserved.x >= 0.5);
  if (light) { pal.a = PAL_LIGHT[ws][0]; pal.b = PAL_LIGHT[ws][1]; }
  float3 rpBase    = light ? RPL_BASE    : RP_BASE;
  float3 rpSurface = light ? RPL_SURFACE : RP_SURFACE;
  float3 rpGold    = light ? RPL_GOLD    : RP_GOLD;

  // time-of-day shift (HTML computeTimeShift); no wall clock -> user[2] else noon.
  float hr = (u.userCount > 2) ? user[2] : 12.0;
  float sunness    = 0.5 * (1.0 + cos((hr - 12.0) * M_PI_F / 12.0));
  float golden     = sin(fabs(hr - 12.0) * M_PI_F / 12.0);
  float warmth     = golden * min(1.0, sunness * 1.6);
  float brightness = 0.78 + 0.27 * sunness;
  float bgLift     = sunness;
  float warmC      = warmth * 0.30;  // colAt gold shift (tick: t.warmth*0.30)

  // tintBg(c): x = c + (surface-c)*lift; x = x + (gold-x)*warmBg.
  float lift   = bgLift * 0.22;
  float warmBg = warmth * 0.10;

  // Background: top half surface->base vertical, bottom half base (bg fragment).
  // yy: 0 at top, 1 at bottom (fc.y is y-up).
  float yy = 1.0 - fc.y / W.y;
  float k  = clamp(yy / 0.5, 0.0, 1.0);
  float3 top = rpSurface + (rpGold - rpSurface) * warmBg;              // tintBg(surface): lift term = 0
  float3 bot = rpBase + (rpSurface - rpBase) * lift;
  bot = bot + (rpGold - bot) * warmBg;                                 // tintBg(base)
  float3 color = mix(top, bot, k) / 255.0;

  // Node positions (deterministic; span CSS space, reflect at walls).
  int N = clamp(int(pal.count), 10, MAX_N);
  float2 pos[MAX_N];
  float  rad[MAX_N];
  float  drift = pal.speed * FPS * u.time;   // CSS px displaced by t (per-frame *fps)
  for (int i = 0; i < N; i++) {
    float fi = float(i);
    float x0 = h11(fi, 1.0) * W.x;
    float y0 = h11(fi, 2.0) * W.y;
    float vx = h11(fi, 3.0) * 2.0 - 1.0;
    float vy = h11(fi, 4.0) * 2.0 - 1.0;
    rad[i]   = 1.5 + h11(fi, 5.0) * 1.0;
    pos[i]   = float2(foldReflect(x0 + vx * drift, W.x),
                      foldReflect(y0 + vy * drift, W.y));
  }

  // Connection lines (O(n^2), i<j). alpha = (1-d/dist)*0.45, color at midpoint x.
  float dist  = pal.dist;
  float dist2 = dist * dist;
  for (int i = 0; i < N; i++) {
    for (int j = i + 1; j < N; j++) {
      float2 a = pos[i], b = pos[j];
      float2 d = a - b;
      float d2 = dot(d, d);
      if (d2 >= dist2) continue;
      float dd = sqrt(d2);
      float alpha = (1.0 - dd / dist) * 0.45;
      float sd = segDist(fc, a, b);
      float cov = 1.0 - smoothstep(0.0, 1.0, sd);   // ~1px AA line (CSS px)
      if (cov <= 0.0) continue;
      float kk = clamp(((a.x + b.x) * 0.5) / W.x, 0.0, 1.0);
      float3 c = mix(pal.a, pal.b, kk);
      c = c + (rpGold - c) * warmC;
      c = min(float3(255.0), c * brightness) / 255.0;
      color = mix(color, c, alpha * cov);
    }
  }
  // ponytail: O(n^2) per pixel (up to ~88 nodes -> ~3.8k segment tests/pixel).
  // Faithful to the HTML's O(n^2) link build; if it chugs at 4K/30fps, cap N or
  // spatially bucket nodes. Wallpaper at ~30fps, so left naive.

  // Nodes (gl.POINTS, round mask). alpha 0.85 * smoothstep(0.5,0.4, r/size).
  for (int i = 0; i < N; i++) {
    float2 p = pos[i];
    float r  = rad[i];
    float rn = length(fc - p) / (2.0 * r);   // normalized like gl_PointCoord
    float mask = smoothstep(0.5, 0.4, rn);
    if (mask <= 0.0) continue;
    float kk = clamp(p.x / W.x, 0.0, 1.0);
    float3 c = mix(pal.a, pal.b, kk);
    c = c + (rpGold - c) * warmC;
    c = min(float3(255.0), c * brightness) / 255.0;
    color = mix(color, c, 0.85 * mask);
  }

  return float4(color, 1.0);
}