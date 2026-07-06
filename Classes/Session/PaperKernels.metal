//
//  PaperKernels.metal
//  Simple Comic
//
//  Core Image Metal kernel that overlays an organic paper texture on an
//  already tone-mapped page. It models real printed paper two ways at once:
//
//    * a subtle MULTIPLY "body" that gives the light paper stock its tooth
//      (and barely touches dense ink), and
//    * a SCREEN "show-through": the cream paper fibres peeking THROUGH the
//      ink, which lightens dark / saturated areas the most and leaves the
//      light stock almost untouched — the charm of a printed comic.
//
//  Built with -fcikernel (compile) + -cikernel (metallib link); see the target
//  build settings. Loaded via CIKernel(functionName:fromMetalLibraryData:).
//

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

static inline float sc_hash(float2 p)
{
	p = fract(p * float2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

static inline float sc_valueNoise(float2 p)
{
	float2 i = floor(p);
	float2 f = fract(p);
	float2 u = f * f * (3.0 - 2.0 * f);
	float a = sc_hash(i);
	float b = sc_hash(i + float2(1.0, 0.0));
	float c = sc_hash(i + float2(0.0, 1.0));
	float d = sc_hash(i + float2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float sc_fbm(float2 p)
{
	float n = 0.0;
	float amp = 0.5;
	// Rotate every octave — including the first, strongest one — so the
	// value-noise lattice is never axis-aligned. This removes the
	// horizontal/vertical seams and gives an even, directionless grain.
	const float2x2 rot = float2x2(0.80, 0.60, -0.60, 0.80);
	p = rot * (p + 4.7);
	for (int i = 0; i < 5; i++) {
		n += amp * sc_valueNoise(p);
		p = rot * (p * 2.02);
		amp *= 0.5;
	}
	return n;
}

extern "C" float4 paperTexture(coreimage::sampler src,
							   float grainStrength,   // MULTIPLY body on the light stock
							   float peekStrength,    // SCREEN paper peeking through ink
							   float scale,           // fibre size in pixels
							   float3 paperTint,      // cream colour of the peek-through
							   coreimage::destination dest)
{
	float4 c = src.sample(src.coord());
	float2 p = dest.coord() / max(scale, 0.5);

	// Even, directionless paper grain (no horizontal or vertical bias) — the
	// per-octave rotation in sc_fbm keeps the lattice off-axis so there are no
	// seams in any direction.
	float fibre = clamp(sc_fbm(p), 0.0, 1.0);

	float L = dot(c.rgb, float3(0.299, 0.587, 0.114));
	float3 rgb = c.rgb;

	// (a) Paper body — subtle darkening, mostly on the light stock.
	float bodyW = smoothstep(0.10, 0.55, L);
	rgb *= 1.0 + (fibre - 0.5) * grainStrength * bodyW;

	// (b) Paper peeking through — screen the cream fibre highlights.
	float peak = pow(fibre, 2.2);
	float3 s = paperTint * (peak * peekStrength);
	rgb = 1.0 - (1.0 - rgb) * (1.0 - s);

	return float4(clamp(rgb, 0.0, 1.0), c.a);
}
