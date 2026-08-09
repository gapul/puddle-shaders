// worldmap — Metal fragment for Puddle's texture (shader) wallpaper renderer.
// Fragment-only: Puddle prepends the contract preamble (WallpaperUniforms /
// WallpaperVertexOut / wallpaperVertex) per docs/wallpaper-source-contract.md.
//
// Coastline line art on an equirectangular world map, with lights running
// along the outlines. Single pass, no feedback texture: the lights are a
// closed form of the baked arc-length phase and the clock, so they neither
// drift nor change length when the quality tier changes the frame rate.
//
// Inputs (gapul convention, configs/wallpaper/inputs):
//   user[0] = focused workspace ('0'..'9') -> palette
//   user[1] = covered hint (read by Puddle, not by this shader)
// Appearance: u._reserved.x (0 dark = Rosé Pine, 1 light = Rosé Pine Dawn).
//
// The tables below are baked from Natural Earth 50m land polygons by
// tools/bake_world_sdf.py — regenerate them there, don't hand-edit.

constant uint  SDF_W     = 1024u;
constant uint  SDF_H     = 512u;
constant uint  PH_W      = 512u;
constant uint  PH_H      = 256u;
constant float SDF_RANGE = 20.0;   // SDF cells of arc
constant float SPACING   = 98.0;   // degrees of arc per pulse cycle

#include "worldmap-tables.metal"


static inline Pal palette(int ws, bool light) {
    Pal p;
    if (light) {
        float3 a = WS_LIGHT[ws] / 255.0;
        p.bg    = float3(250, 244, 237) / 255.0;                       // Dawn base
        p.land  = mix(float3(255, 250, 243) / 255.0, a, 0.10);
        p.line  = mix(a, float3( 87,  82, 121) / 255.0, 0.25);
        // On paper a pulse has to be a saturated, high-chroma hue: a darker
        // version of the stroke colour just reads as a smudge.
        p.spark = mix(a, a / max3(a.r, a.g, a.b), 0.75);
        p.grat  = mix(p.bg, float3(152, 147, 165) / 255.0, 0.30);
    } else {
        float3 a = WS_DARK[ws] / 255.0;
        p.bg    = float3( 21,  19,  32) / 255.0;                       // Rosé Pine base
        p.land  = mix(float3( 31,  29,  46) / 255.0, a, 0.05);
        p.line  = mix(a, float3(224, 222, 244) / 255.0, 0.10);
        p.spark = mix(a, float3(1.0), 0.35);
        p.grat  = mix(p.bg, float3(110, 106, 134) / 255.0, 0.35);
    }
    return p;
}

// ---- table lookups -------------------------------------------------------
// Cell (x, y): x = longitude, wrapping; y = latitude, row 0 at +90 deg. The
// distance field and the phase field have their own grids — sharpness lives in
// the distance field, while arc length varies slowly enough to stay coarse.
static inline uint tableByte(constant uint *table, uint w, uint h, int x, int y) {
    x = ((x % int(w)) + int(w)) % int(w);
    y = clamp(y, 0, int(h) - 1);
    uint idx = uint(y) * w + uint(x);
    return (table[idx >> 2] >> ((idx & 3u) * 8u)) & 0xffu;
}

// Signed distance to the coastline in SDF cells, negative on land.
static inline float sdfTexel(int x, int y) {
    return (float(tableByte(SDF_TABLE, SDF_W, SDF_H, x, y)) * (1.0 / 255.0) * 2.0 - 1.0) * SDF_RANGE;
}

static inline float sdfBilinear(float2 p) {
    float2 g = p - 0.5;
    float2 i = floor(g);
    float2 f = g - i;
    int x0 = int(i.x), y0 = int(i.y);
    return mix(mix(sdfTexel(x0, y0    ), sdfTexel(x0 + 1, y0    ), f.x),
               mix(sdfTexel(x0, y0 + 1), sdfTexel(x0 + 1, y0 + 1), f.x), f.y);
}

// Catmull-Rom, for the distance that actually draws the coastline. Bilinear
// reproduces a linear field exactly but leaves a kink at every cell border,
// which reads as scalloping along the contour; easing the interpolant
// (smoothstep) is worse still, because it bends the field toward the cell
// centres. Catmull-Rom is C1 across borders and stays exact on linear fields.
static inline float4 crWeights(float t) {
    float t2 = t * t, t3 = t2 * t;
    return 0.5 * float4(-t3 + 2.0 * t2 - t,
                        3.0 * t3 - 5.0 * t2 + 2.0,
                        -3.0 * t3 + 4.0 * t2 + t,
                        t3 - t2);
}

static inline float sdfSample(float2 p) {
    float2 g = p - 0.5;
    float2 i = floor(g);
    float2 f = g - i;
    float4 wx = crWeights(f.x), wy = crWeights(f.y);
    int x0 = int(i.x) - 1, y0 = int(i.y) - 1;
    float s = 0.0;
    for (int j = 0; j < 4; j++) {
        float row = 0.0;
        for (int k = 0; k < 4; k++) {
            row += wx[k] * sdfTexel(x0 + k, y0 + j);
        }
        s += wy[j] * row;
    }
    return s;
}

// Cyclic arc length along the nearest coastline, in cycles.
static inline float phaseTexel(int x, int y) {
    return float(tableByte(PHASE_TABLE, PH_W, PH_H, x, y)) * (1.0 / 256.0);
}

// The phase wraps at 1.0, so the corners are unwrapped onto a common branch
// before interpolating — otherwise every contour carries a permanent seam
// where 0.99 meets 0.01.
static inline float phaseSample(float2 p) {
    float2 g = p - 0.5;
    float2 i = floor(g);
    float2 f = g - i;
    int x0 = int(i.x), y0 = int(i.y);
    float a = phaseTexel(x0, y0);
    float b = phaseTexel(x0 + 1, y0    );  b += round(a - b);
    float c = phaseTexel(x0,     y0 + 1);  c += round(a - c);
    float d = phaseTexel(x0 + 1, y0 + 1);  d += round(a - d);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

fragment float4 wallpaperMain(WallpaperVertexOut          in   [[stage_in]],
                              constant WallpaperUniforms& u    [[buffer(0)]],
                              constant float*             user [[buffer(1)]])
{
    float2 res = u.resolution;
    float2 px  = in.position.xy;                  // top-left origin, y down
    float  pxPerPt = (u.version >= 2 && u._reserved.y > 0.0) ? u._reserved.y : 1.0;
    bool   light   = (u.version >= 2) && (u._reserved.x >= 0.5);
    int    ws      = (u.userCount > 0) ? clamp(int(user[0]), 0, 9) : 1;
    Pal    P       = palette(ws, light);

    // ---- screen -> map -> table ----
#if PROJECTION == 0
    float latSpan = LAT_TOP - LAT_BOT;
    float aspect  = 360.0 / latSpan;              // map width / height
#else
    float latSpan = 180.0;
    float aspect  = 2.0;                          // the Mollweide ellipse is 2:1
#endif
    float mapW = min(res.x, res.y * aspect) * MAP_FILL;
    float mapH = mapW / aspect;
    float2 mp = (px - (res - float2(mapW, mapH)) * 0.5) / float2(mapW, mapH);

    float lat, lon, onMap;
#if PROJECTION == 0
    lat = LAT_TOP - mp.y * latSpan;
    lon = mp.x * 360.0 - 180.0 + CENTER_LON;
    onMap = step(0.0, mp.x) * step(mp.x, 1.0) * step(0.0, mp.y) * step(mp.y, 1.0);
#else
    // Mollweide inverse, closed form: v is the auxiliary angle's sine, and the
    // parallels' spacing comes from 2θ + sin 2θ = π sin(lat).
    float2 e = float2(mp.x * 2.0 - 1.0, 1.0 - mp.y * 2.0);   // ellipse coords, -1..1
    float theta = asin(clamp(e.y, -1.0, 1.0));
    lat = asin(clamp((2.0 * theta + sin(2.0 * theta)) / M_PI_F, -1.0, 1.0)) * 57.2957795;
    float ct = max(cos(theta), 1e-4);
    lon = 180.0 * e.x / ct;
    onMap = step(dot(e, e), 1.0) * step(abs(lon), 180.0);
    lon += CENTER_LON;
#endif

    float2 tc = float2(fract(lon / 360.0 + 0.5) * float(SDF_W),
                       (90.0 - lat) / 180.0 * float(SDF_H));
    float2 tp = float2(fract(lon / 360.0 + 0.5) * float(PH_W),
                       (90.0 - lat) / 180.0 * float(PH_H));

    // Pixels per table cell, from the derivative of the point on the sphere
    // rather than of the sampled field: it is smooth under any projection, so
    // the stroke keeps an even weight where the projection compresses.
    float rlat = lat / 57.2957795, rlon = lon / 57.2957795;
    float3 q = float3(cos(rlat) * cos(rlon), sin(rlat), cos(rlat) * sin(rlon));
    float cellPx = (6.283185307 / float(SDF_W)) / max(max(length(dfdx(q)), length(dfdy(q))), 1e-6);

    float d = sdfSample(tc) * cellPx + SHRINK * pxPerPt;   // pixels, negative on land
    float dAbs = abs(d);

    // ---- base map ----
    float3 col = P.bg;

    // graticule, under everything
    float degPerPx = (360.0 / float(SDF_W)) / cellPx;
    float gw = 0.9 * pxPerPt * degPerPx;
    float gLon = 1.0 - smoothstep(0.0, gw, abs(fract(lon / GRAT_LON + 0.5) - 0.5) * GRAT_LON * max(cos(rlat), 0.05));
    float gLat = 1.0 - smoothstep(0.0, gw, abs(fract(lat / GRAT_LAT + 0.5) - 0.5) * GRAT_LAT);
    col = mix(col, P.grat, max(gLon, gLat) * 0.5 * onMap);

    // Near the poles the projection squeezes a whole cell into less than a
    // pixel, so the coastline is finer than the frame can hold and a hard
    // stroke there turns into streaks. Fade the stroke out as that happens and
    // soften the fill's edge instead — polar coasts read as shapes, not hair.
    float detail = smoothstep(0.35, 0.9, cellPx);
    float aa = mix(6.0, 1.2, detail) * pxPerPt;

    // land fill, coastline halo, coastline stroke
    float landMask = (1.0 - smoothstep(-aa, aa, d)) * onMap;
    col = mix(col, P.land, landMask);
    float halo = exp(-dAbs / (GLOW_R * pxPerPt)) * onMap;
    col = mix(col, P.line, halo * (light ? 0.10 : 0.16));
    float lw = LINE_W * pxPerPt;
    float line = (1.0 - smoothstep(lw, lw + aa, dAbs)) * onMap * detail;
    col = mix(col, P.line, line * (light ? 0.85 : 0.90));

    // ---- lights running along the outline ----
    // The baked phase is arc length along the nearest coastline in cycles, so
    // `fract(phase - speed * time)` is a light's position within its comet
    // (1 = head, 0 = end of tail) and the whole train slides along the coast as
    // time passes. Closed form: no feedback buffer, no drift, identical at any
    // frame rate. The second train runs at twice the density and a different
    // speed, so the two drift through each other instead of marching in step.
    // Only integer multiples of the phase stay continuous around a contour.
    float glow = 0.0;
    if (dAbs < 6.0 * LIGHT_W * pxPerPt && onMap > 0.5) {
        float ph = phaseSample(tp);
        float a = exp(-(1.0 - fract(ph        - u.time * PULSE_V )) * TAIL_K);
        float b = exp(-(1.0 - fract(ph * 2.0  - u.time * PULSE_V2)) * TAIL_K * 1.5);
        // Curvature gate. The laplacian of a distance field is the reciprocal
        // radius of curvature, so this fades the lights out on specks and
        // shredded archipelagos (which would otherwise flicker like a starfield,
        // one light per islet) and keeps them on coastlines worth following.
        const float e = 12.0;
        float lap = (sdfBilinear(tc + float2(e, 0)) + sdfBilinear(tc - float2(e, 0))
                   + sdfBilinear(tc + float2(0, e)) + sdfBilinear(tc - float2(0, e))
                   - 4.0 * sdfBilinear(tc)) / (e * e);
        float big = 1.0 - smoothstep(0.05, 0.15, abs(lap));
        // Away from the coast the phase is the nearest coast point's, which
        // fans into wedges where two stretches of coast meet. Fading the bloom
        // out well before that distance keeps it a halo instead of star rays.
        float across = exp(-dAbs / (LIGHT_W * pxPerPt))
                     * (1.0 - smoothstep(1.5 * LIGHT_W * pxPerPt, 3.0 * LIGHT_W * pxPerPt, dAbs));
        glow = (a + 0.35 * b) * big * across * detail;
    }

    float core = smoothstep(0.55, 1.0, glow);
    if (light) {
        // Additive light is invisible on paper: the pulse reads as ink instead,
        // deepening and saturating the stroke as it passes.
        // The bloom does no work on paper, so the tail needs lifting to stay as
        // long as it looks in the dark palette — but lifting the whole field
        // also inks every faint value, which beads the coastline and drags the
        // phase field's wedges out into hairs. Lift the comet, floor the rest.
        float g = smoothstep(0.08, 0.70, glow);
        col = mix(col, P.spark, clamp(g * 1.15, 0.0, 1.0));
        col = mix(col, mix(P.spark, float3(1.0), 0.55), core * 0.85);
    } else {
        col += P.spark * glow * 0.95;
        col = mix(col, float3(1.0), core * 0.30);
    }

    // vignette, so the centre of the map reads first
    float2 vig = (px / res - 0.5) * float2(res.x / res.y, 1.0);
    col *= 1.0 - 0.18 * smoothstep(0.35, 0.95, length(vig)) * (light ? 0.4 : 1.0);

    return float4(col, 1.0);
}
