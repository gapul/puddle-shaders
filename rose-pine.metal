// rose-pine.metal — MSL contract-v2 FEEDBACK port of rose-pine.html (WebGL2).
// Puddle prepends the preamble (WallpaperUniforms / WallpaperVertexOut /
// wallpaperVertex). Do NOT redeclare them here. This wallpaper declares
// `feedback`, so wallpaperMain uses the v2 feedback signature (prev texture).
//
// The HTML is flow-field advection feedback: 200 CPU particles walk a 2-octave
// Perlin angle field (per-workspace scale/twist/speed/drift), leaving 0.7-alpha
// streaks into a ping-pong FBO that is faded toward the (time-of-day tinted)
// base color every frame. Trails = accumulation + fade.
//
// Port strategy (per contract "reformulate procedurally"):
//   * Trails via texture-space semi-Lagrangian advection: the accumulator is
//     sampled one flow-step upstream each frame, so injected ink travels along
//     the exact same curved fbm field lines the HTML particles integrate, then
//     fades toward bg — same flowing/fading streak signature.
//   * Particles -> hash-seeded grid emitters (~1 per 86 css px cell ≈ the
//     HTML's 200 over an initial window) that inject a one-frame stroke
//     (segment of length `speed`, radius width/2, alpha 0.7) colored by the
//     same noise-mixed workspace pair. Emitters relocate on hashed epochs
//     (~150-350 sim frames), like the HTML respawn.
//   * computeTimeShift() needs a wall clock the shader lacks: optional hour in
//     user[2] (constellation.metal convention), else noon.
//   * Coordinates: HTML sim runs in CSS px, y-DOWN (top-left origin) — same
//     orientation as Metal's in.position, so NO y-flip is needed for the sim;
//     the HTML's own y-flips only converted CSS->GL. DPR assumed 1.5 (HTML
//     caps devicePixelRatio there); wrong DPR only rescales the pattern.
//   * u.frame == 0 (fresh black accumulator): return the HTML's seed vertical
//     gradient (surface top -> base bottom); later frames fade it toward flat
//     tinted base exactly like the HTML.
//
// Inputs (gapul convention, guarded by u.userCount):
//   user[0] = focused workspace (0..9; 'S' has no float form -> falls back to 1)
//   user[1] = covered flag (Puddle's quality hint; unused here)
//   user[2] = OPTIONAL wall-clock hour 0..24 for the day/night shift; absent -> noon
// Appearance (v2): u._reserved.x 0=dark 1=light selects the Rosé Pine
// main/dawn palettes (mirrors system-theme.js).

constant float RPDPR = 1.5;      // HTML: min(devicePixelRatio, 1.5)
// ponytail: fade/advect assume Puddle renders ~60fps vs the HTML's 30fps
// (steps halved); expose a rate uniform if tiers make trails visibly slow.
constant float FPS_RATIO = 0.5;  // HTML-frames per rendered frame
constant float CELL = 86.0;      // css px per emitter cell (~200 on a laptop screen)

// Rosé Pine palettes, 0..255 (main = dark, dawn = light; system-theme.js).
// Index: 0 base 1 surface 2 overlay 3 muted 4 subtle 5 text
//        6 love 7 gold 8 rose 9 pine 10 foam 11 iris
constant float3 RP_DARK[12] = {
    float3(25, 23, 36),    float3(31, 29, 46),    float3(38, 35, 58),
    float3(110, 106, 134), float3(144, 140, 170), float3(224, 222, 244),
    float3(235, 111, 146), float3(246, 193, 119), float3(235, 188, 186),
    float3(49, 116, 143),  float3(156, 207, 216), float3(196, 167, 231),
};
constant float3 RP_LIGHT[12] = {
    float3(250, 244, 237), float3(255, 250, 243), float3(242, 233, 225),
    float3(152, 147, 165), float3(121, 117, 147), float3(87, 82, 121),
    float3(180, 99, 122),  float3(234, 157, 52),  float3(215, 130, 126),
    float3(40, 105, 131),  float3(86, 148, 159),  float3(144, 122, 169),
};

// Per-workspace flow params (PALETTES in the HTML). Index = workspace number;
// applyWorkspace falls back to '1'. a/b are palette indices above.
struct WSParams { int a; int b; float scale; float twist; float speed; float drift; float width; };
constant WSParams PAL[10] = {
    { 3, 4,  0.0016f, 2.0f, 1.0f, 0.0005f, 0.9f }, // 0 灰 静かなモノクロ
    { 11, 9, 0.0015f, 2.6f, 1.3f, 0.0007f, 0.9f }, // 1 紫→青 ゆったり大波
    { 10, 9, 0.0030f, 3.6f, 1.5f, 0.0011f, 0.7f }, // 2 シアン→青 細かい渦
    { 7, 8,  0.0020f, 2.4f, 1.2f, 0.0006f, 1.0f }, // 3 金→ローズ なだらか
    { 6, 11, 0.0026f, 4.0f, 1.6f, 0.0012f, 0.7f }, // 4 紅→紫 乱流
    { 9, 10, 0.0017f, 3.0f, 1.4f, 0.0009f, 0.8f }, // 5 青→シアン
    { 11, 6, 0.0024f, 3.4f, 1.5f, 0.0010f, 0.8f }, // 6 紫→紅
    { 10, 11, 0.0013f, 2.2f, 1.2f, 0.0006f, 1.1f }, // 7 シアン→紫 極ゆったり
    { 8, 6,  0.0028f, 3.8f, 1.5f, 0.0011f, 0.7f }, // 8 ローズ→紅
    { 11, 10, 0.0021f, 3.2f, 1.4f, 0.0009f, 0.8f }, // 9 紫→シアン
};

static inline float3 rpc(int i, bool light) {
    return (light ? RP_LIGHT[i] : RP_DARK[i]) / 255.0;
}

// ── hashes / Perlin fbm (stands in for the HTML's perm-table noise) ──
static inline float h21(float2 p) {
    return fract(sin(dot(p, float2(269.5, 183.3))) * 43758.5453);
}
static inline float2 h22(float2 p) {
    return fract(sin(float2(dot(p, float2(127.1, 311.7)),
                            dot(p, float2(269.5, 183.3)))) * 43758.5453);
}
// Diagonal-gradient corner dot, like the JS grad(h,x,y) = ±x ± y.
static inline float grad2(float2 cell, float2 d) {
    float h = fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
    return ((h < 0.5) ? d.x : -d.x) + ((fract(h * 7.13) < 0.5) ? d.y : -d.y);
}
static inline float pnoise(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);  // Perlin fade
    float a = grad2(i, f);
    float b = grad2(i + float2(1, 0), f - float2(1, 0));
    float c = grad2(i + float2(0, 1), f - float2(0, 1));
    float d = grad2(i + float2(1, 1), f - float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
// 2-octave fbm, exact weights/offsets of the HTML.
static inline float fbm2(float2 p) {
    return pnoise(p) * 0.65 + pnoise(p * 2.13 + float2(19.1, 7.3)) * 0.35;
}

static inline float segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6f), 0.0f, 1.0f);
    return length(pa - ba * h);
}

// ── computeTimeShift() (identical math; hr from user[2] or noon) ──
struct TimeShift { float brightness; float warmth; float bgLift; float trailAlpha; };
static inline TimeShift timeShift(float hr) {
    float sunness = 0.5 * (1.0 + cos((hr - 12.0) * M_PI_F / 12.0));
    float golden = sin(fabs(hr - 12.0) * M_PI_F / 12.0);
    TimeShift t;
    t.warmth = golden * min(1.0f, sunness * 1.6f);
    t.brightness = 0.78 + 0.27 * sunness;
    t.bgLift = sunness;
    t.trailAlpha = 0.06 + 0.03 * sunness;
    return t;
}
// tintBg(): lift toward surface by day, toward gold at golden hour.
static inline float3 tintBg(float3 c, TimeShift t, bool light) {
    float3 surface = rpc(1, light);
    float3 gold = rpc(7, light);
    c = mix(c, surface, t.bgLift * 0.22);
    return mix(c, gold, t.warmth * 0.10);
}

fragment float4 wallpaperMain(WallpaperVertexOut          in    [[stage_in]],
                              constant WallpaperUniforms& u     [[buffer(0)]],
                              constant float*             user  [[buffer(1)]],
                              texture2d<float>            prev  [[texture(0)]],
                              sampler                     prevSampler [[sampler(0)]])
{
    // Inputs (guarded).
    int ws = 1;
    if (u.userCount >= 1) {
        int w = int(rint(user[0]));
        ws = (w >= 0 && w <= 9) ? w : 1;
    }
    float hr = (u.userCount >= 3) ? clamp(user[2], 0.0f, 24.0f) : 12.0;
    bool light = (u.version >= 2) && (u._reserved.x >= 0.5);

    constant WSParams& P = PAL[ws];
    TimeShift t = timeShift(hr);
    float3 tintedBase = tintBg(rpc(0, light), t, light);
    float simFrame = u.time * 30.0;                 // HTML runs ~30fps
    float2 cssPos = in.position.xy / RPDPR;         // css px, y-down like the HTML sim

    // Flow field at this pixel (angle = fbm * PI * twist, drift scrolls y).
    float n = fbm2(float2(cssPos.x * P.scale, cssPos.y * P.scale + simFrame * P.drift));
    float ang = n * M_PI_F * P.twist;
    float2 dir = float2(cos(ang), sin(ang));

    // 1) Advect: sample prev one flow-step upstream (ink rides the field),
    // then 2) fade toward tinted base (the HTML's fade pass).
    float3 col;
    if (u.frame == 0) {
        // Fresh black accumulator: seed the HTML's vertical gradient
        // (top half -> surface, bottom half -> base).
        float glT = 1.0 - in.position.y / u.resolution.y;   // 1 = screen top
        float f = clamp((glT - 0.5) / 0.5, 0.0f, 1.0f);
        col = mix(tintedBase, tintBg(rpc(1, light), t, light), f);
    } else {
        float2 upstream = in.position.xy - dir * (P.speed * RPDPR * FPS_RATIO);
        col = prev.sample(prevSampler, upstream / u.resolution).rgb;
    }
    float fadeK = 1.0 - pow(1.0 - t.trailAlpha, FPS_RATIO);  // per-rendered-frame fade
    col = mix(col, tintedBase, fadeK);

    // 3) Inject this frame's strokes: hashed grid emitters, one-frame segment
    // along the local flow, noise-mixed workspace colors, alpha 0.7.
    float3 ca = rpc(P.a, light), cb = rpc(P.b, light), gold = rpc(7, light);
    float rad = P.width * RPDPR * 0.5;              // device px (HTML uRad)
    float2 baseCell = floor(cssPos / CELL);
    for (int cy = -1; cy <= 1; cy++)
    for (int cx = -1; cx <= 1; cx++) {
        float2 cell = baseCell + float2(cx, cy);
        // Epoch respawn ≈ the HTML's life = 150 + rand*200..350 frames.
        float len = 150.0 + h21(cell + 7.7) * 200.0;
        float ep = floor(simFrame / len + h21(cell + 3.3));
        float2 e = (cell + h22(cell * 1.37 + float2(ep * 0.61, ep * 1.29))) * CELL;

        // Emitter's own field sample -> heading + color (as the HTML per particle).
        float ne = fbm2(float2(e.x * P.scale, e.y * P.scale + simFrame * P.drift));
        float ea = ne * M_PI_F * P.twist;
        float2 ed = float2(cos(ea), sin(ea));
        float2 b = e + ed * P.speed;                 // one HTML frame of motion

        float d = segDist(cssPos, e, b) * RPDPR;     // device px
        float cov = 1.0 - smoothstep(rad - 1.0, rad + 1.0, d);
        if (cov <= 0.0) continue;

        float m = (ne + 1.0) * 0.5;
        float3 ec = mix(ca, cb, m);
        ec = mix(ec, gold, t.warmth * 0.35);         // golden-hour pull
        ec = min(ec * t.brightness, 1.0);            // time-of-day brightness
        col = mix(col, ec, 0.7 * cov);               // HTML stroke alpha 0.7
    }

    return float4(col, 1.0);
}
