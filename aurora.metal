// aurora — Metal fragment for Puddle's texture (shader) wallpaper renderer.
// Fragment-only: Puddle prepends the contract preamble (WallpaperUniforms /
// WallpaperVertexOut / wallpaperVertex). Ported from aurora.html (WebGL2).
// Contract v2 FEEDBACK shader: declare `feedback` in the per-wallpaper config.
//
// Pipeline (same shape as the HTML's ping-pong FBO):
//   1) fade: mix prev frame toward the time-tinted bg (trailAlpha 0.08 @30fps)
//   2) inject: this frame's particle stroke segments (round-cap line SDF,
//      stroke alpha 0.75), alpha-blended source-over on top.
// The HTML integrates 200 CPU flow-field particles; here each particle is a
// hash-seeded trajectory integrated from its spawn through the same noise
// field, so trails accumulate in the feedback texture exactly like the HTML.
//
// Inputs (gapul convention, configs/wallpaper/inputs):
//   user[0] = focused workspace ('0'..'9'; 'S' unreachable and omitted)
//   user[1] = covered hint (read by Puddle, not by this shader)
//   user[2] = optional fractional hour 0..24 for the time-of-day tint
//             (wall clock isn't available in-shader; defaults to noon)
// Appearance: u._reserved.x when u.version >= 2 (0 dark / 1 light) selects
// the LIGHT_PALETTES backgrounds from the HTML.
//
// Coordinates: the HTML runs its field/particles in CSS top-left y-down
// coords and only flips when emitting GL vertices. Metal's in.position is
// already top-left y-down, so using it directly reproduces the exact screen
// placement — no y-flip is needed (we never sample prev anywhere but in.uv).

struct WSPal {
    float3 bgDark;   // DARK_PALETTES bg, 0..255
    float3 bgLight;  // LIGHT_PALETTES bg (tint = ws % 3: JS enumerates the integer-like keys '0'..'9' in ascending numeric order)
    float  hueBase;
    float  hueRange;
};

// Index = numeric workspace. 'S' is unreachable through numeric user[0].
constant WSPal WS_TABLE[10] = {
    { float3( 6,  6, 10), float3(250, 244, 237),   0.0,  0.0 }, // '0' mono
    { float3(10, 10, 20), float3(255, 250, 243), 270.0, 60.0 }, // '1' violet/blue
    { float3( 6, 18, 14), float3(242, 233, 225), 140.0, 50.0 }, // '2' green/teal
    { float3(20, 12,  6), float3(250, 244, 237),  30.0, 30.0 }, // '3' orange/amber
    { float3(22,  8, 14), float3(255, 250, 243), 340.0, 40.0 }, // '4' crimson/magenta
    { float3( 6, 12, 24), float3(242, 233, 225), 210.0, 40.0 }, // '5' blue/cyan
    { float3(14,  8, 28), float3(250, 244, 237), 250.0, 50.0 }, // '6' lavender
    { float3( 6, 18, 12), float3(255, 250, 243), 160.0, 40.0 }, // '7' forest
    { float3(20, 10,  8), float3(242, 233, 225), 350.0, 30.0 }, // '8' rose
    { float3(16,  6, 22), float3(250, 244, 237), 290.0, 50.0 }, // '9' pink/violet
};

// ---- tuning (HTML values, in drawable px; density matches 200 particles
// over the HTML's initial window at DPR 1.5) ----
constant float CELL    = 256.0;  // particle bin size; max drift must stay <= CELL for the 3x3 gather
constant int   PPC     = 4;      // particles per cell -> 1 per ~128^2 px, HTML-equivalent density
constant int   NSTEP   = 10;     // straight sub-steps per trajectory
constant float SPEED   = 1.4;    // px per virtual (30fps) frame, HTML `speed`
constant float STROKE_A = 0.75;  // HTML stroke alpha
constant float RAD     = 0.55;   // line radius ~ HTML lineWidth 0.7 * DPR / 2
constant float AA      = 1.0;    // HTML uAA
constant float TRAIL   = 0.08;   // HTML TRAIL_ALPHA per 30fps frame

static inline float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}
static inline float2 hash22(float2 p) {
    return fract(sin(float2(dot(p, float2(127.1, 311.7)),
                            dot(p, float2(269.5, 183.3)))) * 43758.5453123);
}

// Perlin-style gradient noise, same structure as the HTML's noise2D
// (grad = +-x +-y picked by two hash bits, quintic fade). Range ~[-1, 1].
static inline float gradDot(float2 cell, float2 d) {
    int h = int(hash21(cell) * 4.0);
    float gx = (h & 1) ? -d.x : d.x;
    float gy = (h & 2) ? -d.y : d.y;
    return gx + gy;
}
static inline float noise2(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = gradDot(i,                  f);
    float b = gradDot(i + float2(1, 0),   f - float2(1, 0));
    float c = gradDot(i + float2(0, 1),   f - float2(0, 1));
    float d = gradDot(i + float2(1, 1),   f - float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// HTML flow field: noise2D(x*0.0018, y*0.0018 + frame*0.0008)
static inline float fieldNoise(float2 p, float F) {
    return noise2(float2(p.x * 0.0018, p.y * 0.0018 + F * 0.0008));
}

// HSL(deg, 0..100, 0..100) -> RGB 0..1, same formula as the HTML's hslToRgb.
static inline float3 hsl2rgb(float hue, float s, float l) {
    float h = fract(hue / 360.0);
    s *= 0.01; l *= 0.01;
    float a = s * min(l, 1.0 - l);
    float3 k = fmod(float3(0.0, 8.0, 4.0) + h * 12.0, 12.0);
    return l - a * clamp(min(k - 3.0, 9.0 - k), -1.0, 1.0);
}

static inline float segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

fragment float4 wallpaperMain(WallpaperVertexOut          in    [[stage_in]],
                              constant WallpaperUniforms& u     [[buffer(0)]],
                              constant float*             user  [[buffer(1)]],
                              texture2d<float>            prev  [[texture(0)]],
                              sampler                     prevSampler [[sampler(0)]])
{
    float2 pix = in.position.xy;  // top-left y-down, see coordinate note above

    // ---- workspace / appearance / hour ----
    int ws = (u.userCount > 0) ? clamp(int(user[0]), 0, 9) : 1;
    WSPal P = WS_TABLE[ws];
    float appearance = (u.version >= 2) ? u._reserved.x : 0.0;
    float3 palBg = (appearance >= 0.5) ? P.bgLight : P.bgDark;
    float hr = (u.userCount > 2) ? user[2] : 12.0;

    // ---- computeTimeShift (HTML, wall-clock hour -> user[2]) ----
    float sunness = 0.5 * (1.0 + cos((hr - 12.0) * M_PI_F / 12.0));
    float golden  = sin(abs(hr - 12.0) * M_PI_F / 12.0);
    float warmShift  = 25.0 * golden;
    float lightMult  = 0.65 + 0.05 * sunness;
    float satMult    = 1.0  + 0.6  * sunness;
    float bgWhiten   = 0.9  * sunness;
    float bgDarkness = 0.55 + 0.45 * sunness;

    // bgColor(): tinted background, 0..1
    float3 bg = (palBg * bgDarkness * (1.0 - bgWhiten) + 240.0 * bgWhiten) / 255.0;

    // ---- fade pass: prev toward bg (HTML runs at 30fps; scale the per-frame
    // fade by the average render interval so trail length survives 60fps) ----
    // ponytail: avg dt = time/frame lags after quality-tier rate changes; good enough for a fade factor
    float avgdt = (u.frame > 0) ? (u.time / float(u.frame)) : (1.0 / 30.0);
    float dF = clamp(avgdt * 30.0, 0.25, 4.0);       // virtual 30fps frames per render
    float trail = 1.0 - pow(1.0 - TRAIL, dF);
    float3 col = (u.frame == 0)
        ? bg                                          // fresh accumulator: seed with bg (HTML seedBase)
        : mix(prev.sample(prevSampler, in.uv).rgb, bg, trail);

    // ---- inject this frame's strokes ----
    float F = u.time * 30.0;                          // virtual 30fps frame counter
    float sat = (P.hueRange == 0.0) ? 0.0 : min(100.0, 65.0 * satMult);
    int2 c0 = int2(floor(pix / CELL));

    for (int dy = -1; dy <= 1; ++dy)
    for (int dx = -1; dx <= 1; ++dx) {
        float2 cellId = float2(c0 + int2(dx, dy));
        for (int k = 0; k < PPC; ++k) {
            float2 seed = cellId * 4.0 + float2(float(k), 7.0 * float(k));
            float2 h = hash22(seed);
            float L = 140.0 + 40.0 * h.x;             // life in frames; drift <= 252 < CELL
            float ft = F + h.y * 1000.0;              // phase-desynced clock
            float cyc = floor(ft / L);
            float age = ft - cyc * L;
            float2 spawn = (cellId + hash22(seed + cyc)) * CELL;

            // early out: head is within age*SPEED of spawn
            float reach = age * SPEED + 8.0;
            float2 rel = pix - spawn;
            if (dot(rel, rel) > reach * reach) continue;

            // integrate the trajectory through the flow field (NSTEP straight
            // pieces over the full life; the fed-back accumulator keeps the tail)
            float stepF = L / float(NSTEP);
            float2 p = spawn;
            float2 dir = float2(1.0, 0.0);
            float n = 0.0;
            float remaining = age;
            for (int s = 0; s < NSTEP; ++s) {
                n = fieldNoise(p, F);
                float ang = n * M_PI_F * 3.0;         // HTML: angle = n * PI * 3
                dir = float2(cos(ang), sin(ang));
                float adv = min(remaining, stepF);
                p += dir * adv * SPEED;
                remaining -= adv;
                if (remaining <= 0.0) break;
            }

            // this render's segment: what the head swept since the last frame
            float2 tail = p - dir * SPEED * min(dF, age);
            float d = segDist(pix, tail, p);
            float cov = 1.0 - smoothstep(RAD - AA, RAD + AA, d);
            if (cov <= 0.003) continue;

            // HTML color: same n drives hue and lightness
            float hue = P.hueBase + warmShift + n * P.hueRange;
            float lit = min(95.0, (60.0 + n * 10.0) * lightMult);
            float3 sc = hsl2rgb(hue, sat, lit);
            col = mix(col, sc, STROKE_A * cov);       // source-over
        }
    }

    return float4(col, 1.0);
}
