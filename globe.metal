// globe — Metal fragment for Puddle's texture (shader) wallpaper renderer.
// Fragment-only: Puddle prepends the contract preamble (WallpaperUniforms /
// WallpaperVertexOut / wallpaperVertex) per docs/wallpaper-source-contract.md.
//
// The worldmap coastlines wrapped on a globe: same baked field, same lights
// running along the outlines, projected onto a sphere that turns toward the
// pointer. **Requires contract v3** (Puddle 2.19+) for `u.cursor`; on an older
// Puddle the preamble has no such field and the shader will not compile.
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

#include "globe-tables.metal"


static inline Pal palette(int ws, bool light) {
    Pal p;
    if (light) {
        float3 a = WS_LIGHT[ws] / 255.0;
        p.bg    = float3(250, 244, 237) / 255.0;                  // Dawn base
        p.ocean = mix(float3(255, 250, 243) / 255.0, a, 0.07);
        p.land  = float3(255, 250, 243) / 255.0;
        p.line  = mix(a, float3( 87,  82, 121) / 255.0, 0.25);
        p.spark = mix(a, a / max3(a.r, a.g, a.b), 0.75);          // high chroma: ink reads, mud doesn't
        p.grat  = mix(p.ocean, float3(152, 147, 165) / 255.0, 0.35);
        p.rim   = mix(p.bg, a, 0.30);
    } else {
        float3 a = WS_DARK[ws] / 255.0;
        p.bg    = float3( 16,  15,  25) / 255.0;
        p.ocean = float3( 26,  24,  38) / 255.0;
        p.land  = mix(float3( 32,  30,  47) / 255.0, a, 0.08);
        p.line  = a * 0.85;
        p.spark = mix(a, float3(1.0), 0.35);
        p.grat  = mix(p.ocean, float3(110, 106, 134) / 255.0, 0.40);
        p.rim   = a;
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

    float R = min(res.x, res.y) * GLOBE_R;
    float2 centre = res * 0.5;
    float2 sp = (px - centre) / R;                // sphere units, y still down
    float rr = dot(sp, sp);

    // ---- the cursor turns the globe (contract v3; without it, it just spins) ----
    // Closed form in (time, cursor): Puddle smooths the cursor itself, so the
    // globe eases after the pointer instead of snapping to it.
    float2 cur = (u.version >= 3) ? (u.cursor - centre) / R : float2(0.0);
    float near = 1.0 - smoothstep(REACH * 0.4, REACH, length(cur));
    float2 pull = clamp(cur, -1.5, 1.5) * near * PULL;

    float spin = (u.time * SPIN_V + pull.x) * 6.283185307;
    float tilt = TILT + pull.y * 1.6;
    tilt = clamp(tilt, -1.2, 1.2);

    float3 col = P.bg;

    // faint stars / paper grain outside the globe, and the limb glow
    float limb = exp(-max(0.0, sqrt(max(rr, 0.0)) - 1.0) * 34.0);
    col = mix(col, P.rim, limb * (light ? 0.14 : 0.30) * step(1.0, rr));

    if (rr < 1.0) {
        // Point on the unit sphere facing the viewer, then rotated into the
        // globe's frame: tilt about x, spin about y.
        float3 v = float3(sp.x, -sp.y, sqrt(1.0 - rr));
        float ct = cos(tilt), st = sin(tilt);
        float3 q = float3(v.x, ct * v.y + st * v.z, -st * v.y + ct * v.z);

        float lat = asin(clamp(q.y, -1.0, 1.0)) * 57.2957795;
        float lon = atan2(q.x, q.z) * 57.2957795 + spin * 57.2957795;
        float2 tc = float2(fract(lon / 360.0 + 0.5) * float(SDF_W),
                           (90.0 - lat) / 180.0 * float(SDF_H));
        float2 tp = float2(fract(lon / 360.0 + 0.5) * float(PH_W),
                           (90.0 - lat) / 180.0 * float(PH_H));

        // Pixels per table cell, from the derivative of the *surface point*
        // rather than of the sampled field: the sphere position is smooth, so
        // this scale has none of the quantisation noise the field carries, and
        // it shrinks correctly as the surface tilts away toward the limb.
        // One cell of the distance field is 360/SDF_W degrees of arc.
        float arcPerPx = max(length(dfdx(q)), length(dfdy(q)));
        float cellPx = (6.283185307 / float(SDF_W)) / max(arcPerPx, 1e-6);

        float sd = sdfSample(tc);
        float dpx = sd * cellPx + SHRINK * pxPerPt;   // signed distance in pixels
        float dAbs = abs(dpx);
        // Below a couple of pixels per cell the coastline is past what the
        // table can resolve, so soften the edges rather than let them alias.
        float aa = max(1.0 * pxPerPt, 0.9 * cellPx);
        // Curvature reads as shading on a dark globe; on paper the same ramp
        // just turns the sphere grey, so it stays nearly flat there.
        float shade = light ? (0.90 + 0.10 * v.z) : (0.35 + 0.65 * v.z);

        col = mix(col, P.ocean * shade, 1.0);

        // graticule. Degrees per pixel comes from the same arc scale, with the
        // meridians converging as cos(lat).
        float degPerPx = arcPerPx * 57.2957795;
        float gw = 1.1 * pxPerPt * degPerPx;
        float dLon = abs(fract(lon / GRAT_LON + 0.5) - 0.5) * GRAT_LON * max(cos(lat / 57.2957795), 0.05);
        float dLat = abs(fract(lat / GRAT_LAT + 0.5) - 0.5) * GRAT_LAT;
        float grat = max(1.0 - smoothstep(0.0, gw, dLon),
                         1.0 - smoothstep(0.0, gw, dLat));
        col = mix(col, P.grat * shade, grat * 0.55);

        // Curvature gate for the lights: the laplacian of a distance field is
        // the reciprocal radius of curvature, so this measures how tight a
        // feature is and fades the lights off specks that would just flicker.
        // The probe is deliberately wide — the stored field is quantised, and a
        // short baseline turns that quantisation into laplacian noise, which
        // reads as hair along every coast.
        const float e = 12.0;
        float lap = (sdfBilinear(tc + float2(e, 0)) + sdfBilinear(tc - float2(e, 0))
                   + sdfBilinear(tc + float2(0, e)) + sdfBilinear(tc - float2(0, e))
                   - 4.0 * sdfBilinear(tc)) / (e * e);
        float big = 1.0 - smoothstep(0.05, 0.15, abs(lap));

        // Where a cell is smaller than a pixel — near the limb — the coastline
        // is finer than the frame can hold, so fade the stroke instead of
        // letting it alias.
        float detail = smoothstep(0.35, 0.9, cellPx);

        // land, coastline halo, coastline stroke
        float landMask = 1.0 - smoothstep(-aa, aa, dpx);
        col = mix(col, P.land * shade, landMask);
        col = mix(col, P.line, exp(-dAbs / (HALO_R * cellPx)) * (light ? 0.12 : 0.22) * shade);
        float lw = max(0.5 * pxPerPt, LINE_W * cellPx);
        float line = 1.0 - smoothstep(lw, lw + aa, dAbs);
        col = mix(col, P.line * mix(0.55, 1.0, shade),
                  line * detail * (light ? 0.90 : 0.80));

        // ---- lights running along the outline ----
        float glow = 0.0;
        if (dAbs < 6.0 * LIGHT_W * cellPx) {
            float ph = phaseSample(tp);
            float a = exp(-(1.0 - fract(ph       - u.time * PULSE_V )) * TAIL_K);
            float b = exp(-(1.0 - fract(ph * 2.0 - u.time * PULSE_V2)) * TAIL_K * 1.5);
            float lwPx = LIGHT_W * cellPx;
            float across = exp(-dAbs / lwPx)
                         * (1.0 - smoothstep(1.5 * lwPx, 3.0 * lwPx, dAbs));
            // Fade the lights out at the limb, where a whole cycle collapses
            // into a couple of pixels and would just strobe.
            glow = (a + 0.35 * b) * big * across * smoothstep(0.10, 0.35, v.z);
        }

        float core = smoothstep(0.55, 1.0, glow);
        if (light) {
            // The bloom does no work on paper, so the tail needs lifting to
            // stay as long as it looks in the dark palette — but lifting the
            // whole field also inks every faint value, which beads the
            // coastline and drags the phase field's wedges out into hairs.
            // Lift the comet, floor the rest.
            float g = smoothstep(0.08, 0.70, glow);
            col = mix(col, P.spark, clamp(g * 1.15, 0.0, 1.0));
            col = mix(col, mix(P.spark, float3(1.0), 0.55), core * 0.85);
        } else {
            col += P.spark * glow * 1.5;
            col = mix(col, float3(1.0), core * 0.45);
        }

        // the cursor leaves a soft highlight on the surface it is turning
        if (u.version >= 3) {
            float touch = exp(-length(sp - cur) * 3.0) * near;
            col = light ? mix(col, P.spark, touch * 0.12)
                        : col + P.rim * touch * 0.10;
        }

        // terminator-ish darkening at the very edge of the disc
        col *= 1.0 - (light ? 0.10 : 0.45) * smoothstep(0.86, 1.0, sqrt(rr));
    }

    return float4(col, 1.0);
}
