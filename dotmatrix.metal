// dotmatrix — Metal fragment for Puddle's texture (shader) wallpaper renderer.
// Fragment-only: Puddle prepends the preamble (WallpaperUniforms / WallpaperVertexOut /
// wallpaperVertex) per Puddle docs/wallpaper-source-contract.md. Ported from dotmatrix.html.
// user[0] = focused workspace (see configs/wallpaper/inputs, written by omniwm-event.sh).

// Dot-Matrix Ripple wallpaper, ported from dotmatrix.html (WebGL2).
// Per-workspace palette/params embedded below, indexed by user[0].
// The HTML's wave sources drifted on the CPU with random init + wall reflection;
// that is a closed-form function of elapsed time (triangle-wave reflection,
// deterministic hash for the random init), so this is single-pass.

struct WSParam {
    float3 a;          // accent color a  (0..255)
    float3 b;          // accent color b  (0..255)
    float  spacing;    // grid spacing (px)
    int    sources;    // number of wave sources
    float  speed;      // source drift speed
    float  freq;       // wave spatial frequency
    float  waveSpeed;  // wave temporal speed
};

// Rosé Pine palette (0..255):
//   iris 196,167,231  pine 49,116,143  foam 156,207,216  gold 246,193,119
//   rose 235,188,186  love 235,111,146  muted 110,106,134 subtle 144,140,170
// Index 0 = PALETTES['0'], indices 1..9 = PALETTES['1'..'9'].
// PALETTES['S'] is unreachable through a numeric user[0] and is omitted.
constant WSParam WS_TABLE[10] = {
    // 2026-08-06 v2: uniform 25pt spacing everywhere — per-workspace spacing (22-28)
    // read as "the dots change size when I switch workspace". Hue is the only
    // differentiator now: each workspace is a monochromatic pair (accent + 60% shade)
    // so its dominant hue is unmistakable (1=purple 2=teal 3=orange 4=pink 5=deep blue).
    // '0': muted -> subtle, quiet monochrome
    { float3(110,106,134), float3(144,140,170), 25.0, 2, 0.30, 0.018, 1.6 },
    // '1': iris (purple)
    { float3(196,167,231), float3(118,100,139), 25.0, 2, 0.40, 0.018, 2.4 },
    // '2': foam (teal)
    { float3(156,207,216), float3( 94,124,130), 25.0, 3, 0.70, 0.030, 3.2 },
    // '3': gold (orange)
    { float3(246,193,119), float3(148,116, 71), 25.0, 2, 0.35, 0.016, 2.0 },
    // '4': love (pink)
    { float3(235,111,146), float3(141, 67, 88), 25.0, 3, 0.80, 0.026, 3.6 },
    // '5': pine (deep blue)
    { float3( 49,116,143), float3(110,160,180), 25.0, 2, 0.50, 0.020, 2.6 },
    // '6': rose (salmon)
    { float3(235,188,186), float3(141,113,112), 25.0, 3, 0.60, 0.024, 3.0 },
    // '7': foam -> iris (teal-purple)
    { float3(156,207,216), float3(196,167,231), 25.0, 2, 0.30, 0.014, 1.8 },
    // '8': love -> rose (deep pink)
    { float3(235,111,146), float3(235,188,186), 25.0, 3, 0.70, 0.028, 3.3 },
    // '9': gold -> foam (orange-teal)
    { float3(246,193,119), float3(156,207,216), 25.0, 2, 0.50, 0.022, 2.8 },
};

constant float3 RP_BASE    = float3(25.0, 23.0, 36.0);   // background
constant float3 RP_SURFACE = float3(31.0, 29.0, 46.0);   // day tint target
constant float3 RP_GOLD    = float3(246.0, 193.0, 119.0);

// Light appearance = Rosé Pine Dawn (system-theme.js `light`). The HTML swaps the
// whole RP object before PALETTES derive from it, so every accent has a Dawn twin.
// Same row order as WS_TABLE; only the colors change (spacing/wave params don't).
constant float3 WS_LIGHT[10][2] = {
    // Same monochromatic pairs in Rosé Pine Dawn values.
    { float3(152,147,165), float3(121,117,147) }, // '0' muted
    { float3(144,122,169), float3( 86, 73,101) }, // '1' iris (purple)
    { float3( 86,148,159), float3( 52, 89, 95) }, // '2' foam (teal)
    { float3(234,157, 52), float3(140, 94, 31) }, // '3' gold (orange)
    { float3(180, 99,122), float3(108, 59, 73) }, // '4' love (pink)
    { float3( 40,105,131), float3( 90,150,170) }, // '5' pine (deep blue)
    { float3(215,130,126), float3(129, 78, 76) }, // '6' rose (salmon)
    { float3( 86,148,159), float3(144,122,169) }, // '7' foam -> iris
    { float3(180, 99,122), float3(215,130,126) }, // '8' love -> rose
    { float3(234,157, 52), float3( 86,148,159) }, // '9' gold -> foam
};
constant float3 RP_BASE_L    = float3(250.0, 244.0, 237.0);
constant float3 RP_SURFACE_L = float3(255.0, 250.0, 243.0);
constant float3 RP_GOLD_L    = float3(234.0, 157.0,  52.0);

static inline float hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

// Reflect a coordinate into [0,1] as if bouncing off both walls (triangle wave).
static inline float reflect01(float x) {
    float m = fmod(x, 2.0);
    if (m < 0.0) m += 2.0;
    return 1.0 - abs(1.0 - m);
}

fragment float4 wallpaperMain(WallpaperVertexOut       in   [[stage_in]],
                              constant WallpaperUniforms& u  [[buffer(0)]],
                              constant float*             user [[buffer(1)]])
{
    // GLSL gl_FragCoord equivalent (y-up), per contract.
    float2 fragCoord = float2(in.position.x, u.resolution.y - in.position.y);

    // ---- workspace -> params ----
    int ws = (u.userCount > 0) ? int(user[0]) : 1;
    ws = clamp(ws, 0, 9);
    WSParam P = WS_TABLE[ws];

    // ---- appearance (contract v2): 0 dark / 1 light ----
    bool light = (u.version >= 2) && (u._reserved.x >= 0.5);
    if (light) { P.a = WS_LIGHT[ws][0]; P.b = WS_LIGHT[ws][1]; }
    float3 rpBase    = light ? RP_BASE_L    : RP_BASE;
    float3 rpSurface = light ? RP_SURFACE_L : RP_SURFACE;
    float3 rpGold    = light ? RP_GOLD_L    : RP_GOLD;

    // ---- time-of-day tint (computeTimeShift / tintBg) ----
    // Original read the wall clock; that isn't available in-shader, so accept an
    // optional fractional hour at user[2] (0..24), else default to noon.
    // v3: time of day comes from the header; user[2] kept as a legacy override, noon as last resort.
    float hr = (u.version >= 3) ? u._reserved2.x
             : (u.userCount > 2) ? user[2] : 12.0;
    float sunness = 0.5 * (1.0 + cos((hr - 12.0) * M_PI_F / 12.0)); // noon=1, midnight=0
    float golden  = sin(abs(hr - 12.0) * M_PI_F / 12.0);           // dawn/dusk=1
    float warmth  = golden * min(1.0, sunness * 1.6);
    float bright  = 0.78 + 0.27 * sunness;
    float bgLift  = sunness;
    float warmMix = warmth * 0.35;

    // tintBg(base): base + (surface-base)*lift, then toward gold by warm
    float lift = bgLift * 0.22;
    float warm = warmth * 0.10;
    float3 bg255 = rpBase + (rpSurface - rpBase) * lift;
    bg255 = bg255 + (rpGold - bg255) * warm;
    float3 bg = bg255 / 255.0;

    // ---- grid geometry (uOrigin / uSp / uMaxR) ----
    // No DPR in the contract; work directly in drawable pixels (DPR = 1).
    float2 res = u.resolution;
    // Contract v2: _reserved.y = pixels per point (quality tier × backing scale).
    // Spacing is defined in points, so dot pitch stays visually constant when the
    // reduced tier lowers the drawable resolution (and on Retina).
    float  pxPerPt = (u.version >= 2 && u._reserved.y > 0.0) ? u._reserved.y : 1.0;
    float  sp  = P.spacing * pxPerPt;
    float  maxR = sp * 0.46;
    float  cols = ceil(res.x / sp);
    float  rows = ceil(res.y / sp);
    float2 origin = float2((res.x - (cols - 1.0) * sp) * 0.5,
                           (res.y - (rows - 1.0) * sp) * 0.5);

    // GLSL: cssPx = (fragCoord.x, uRes.y - fragCoord.y) / uDpr
    float2 px = float2(fragCoord.x, res.y - fragCoord.y);
    float2 cell   = floor((px - origin) / sp + 0.5);
    float2 center = origin + cell * sp;

    // ---- wave field at cell center ----
    float t = u.time;
    int n = P.sources;
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        if (i >= n) break;
        float seed = float(ws) * 17.0 + float(i) * 3.0;
        float x0    = hash11(seed + 0.1);
        float y0    = hash11(seed + 0.2);
        float ang   = hash11(seed + 0.3) * 6.28318530718;
        float phase = hash11(seed + 0.4) * 6.28318530718;
        float vx = cos(ang) * P.speed;
        float vy = sin(ang) * P.speed;
        // moveSources: s.x += vx*dt*0.05 accumulated -> vx*0.05*t, bounced into [0,1]
        float2 srcN = float2(reflect01(x0 + vx * 0.05 * t),
                             reflect01(y0 + vy * 0.05 * t));
        float2 src = srcN * res;

        float2 d = center - src;
        float dist = length(d);
        float atten = 1.0 / (1.0 + dist * 0.0016);
        sum += sin(dist * P.freq - t * P.waveSpeed + phase) * atten;
    }
    float v = 0.5 + 0.5 * (sum / float(n));

    if (v < 0.12) {
        return float4(bg, 1.0);
    }

    // color: a->b by v, warm toward gold, then brightness
    float3 col = mix(P.a, P.b, v);
    col = mix(col, rpGold, warmMix);
    col = min(float3(255.0), col * bright) / 255.0;

    float dd = length(px - center);
    float radius = maxR * v;
    float dot = 1.0 - smoothstep(radius - 1.0, radius + 1.0, dd);
    float alpha = (0.12 + 0.85 * v) * dot;
    float3 outc = mix(bg, col, alpha);

    // bright cells get an inner core (terminal-glyph stand-in)
    if (v > 0.55) {
        float core = 1.0 - smoothstep(radius * 0.5 - 1.0, radius * 0.5 + 1.0, dd);
        outc = mix(outc, col, core * 0.25);
    }
    return float4(outc, 1.0);
}