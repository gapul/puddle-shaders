// audio-bars — system-audio spectrum wallpaper (Puddle contract v4).
// Fragment-only: Puddle prepends the preamble. Enable "Audio (system sound
// spectrum)" on this wallpaper — the FFT arrives as texture(1):
//   row 0 (y=0.25) = log-binned magnitudes 0..1, row 1 (y=0.75) = waveform.
// Rosé Pine bars on the base background, dark/light aware, waveform ghost line.

constant float3 RP_BASE_D  = float3( 25.0,  23.0,  36.0) / 255.0;
constant float3 RP_BASE_L  = float3(250.0, 244.0, 237.0) / 255.0;
// low -> high frequency: pine, foam, gold, love
constant float3 GRAD_D[4] = {
    float3( 49.0, 116.0, 143.0) / 255.0,
    float3(156.0, 207.0, 216.0) / 255.0,
    float3(246.0, 193.0, 119.0) / 255.0,
    float3(235.0, 111.0, 146.0) / 255.0,
};
constant float3 GRAD_L[4] = {
    float3( 40.0, 105.0, 131.0) / 255.0,
    float3( 86.0, 148.0, 159.0) / 255.0,
    float3(234.0, 157.0,  52.0) / 255.0,
    float3(180.0,  99.0, 122.0) / 255.0,
};

static inline float3 gradientAt(float t, bool light) {
    float x = clamp(t, 0.0, 1.0) * 3.0;
    int i = int(x);
    float f = fract(x);
    return light ? mix(GRAD_L[i], GRAD_L[min(i + 1, 3)], f)
                 : mix(GRAD_D[i], GRAD_D[min(i + 1, 3)], f);
}

fragment float4 wallpaperMain(WallpaperVertexOut          in    [[stage_in]],
                              constant WallpaperUniforms& u     [[buffer(0)]],
                              constant float*             user  [[buffer(1)]],
                              texture2d<float>            audio [[texture(1)]],
                              sampler                     audioSampler [[sampler(1)]])
{
    bool light = (u.version >= 2) && (u._reserved.x >= 0.5);
    float3 bg = light ? RP_BASE_L : RP_BASE_D;

    float2 uv = in.uv;

    // 96 bars across the width, mirrored spectrum (bass in the middle).
    float bars = 96.0;
    float slot = floor(uv.x * bars);
    float t = abs((slot + 0.5) / bars - 0.5) * 2.0;   // 0 centre -> 1 edges
    float magnitude = audio.sample(audioSampler, float2(t, 0.25)).r;

    // Bars grow from the bottom; leave breathing room at the top.
    float barHeight = magnitude * 0.55;
    float y = 1.0 - uv.y;                              // 0 at the bottom
    float inBar = step(y, barHeight);

    // Slot gaps + soft tip.
    float gap = smoothstep(0.0, 0.08, fract(uv.x * bars)) * smoothstep(1.0, 0.92, fract(uv.x * bars));
    float tip = smoothstep(barHeight, barHeight - 0.02, y);

    float3 barColor = gradientAt(t, light);
    float3 color = mix(bg, barColor, inBar * gap * (0.35 + 0.65 * tip));

    // Waveform ghost line across the upper area.
    float wave = audio.sample(audioSampler, float2(uv.x, 0.75)).r;
    float waveY = 0.78 + wave * 0.08;
    float line = smoothstep(0.006, 0.0, abs(uv.y - waveY));
    color = mix(color, gradientAt(uv.x, light), line * 0.35);

    return float4(color, 1.0);
}
