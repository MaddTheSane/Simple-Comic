//
//  SCPaperFilter.swift
//  Simple Comic
//
//  Applies a "paper" look to comic pages: harsh blacks are lifted to a dark
//  warm grey, the white point is pulled towards a warm cream, and an organic
//  paper texture is laid over the page. The texture is applied two ways at
//  once (see PaperKernels.metal): a subtle MULTIPLY that gives the light stock
//  its tooth, and a SCREEN "show-through" so the cream paper fibres peek
//  through the ink — which is what makes a printed comic feel like paper.
//
//  All parameters are read live from NSUserDefaults so they can be tuned at
//  runtime (see the "Paper Effect Settings…" panel). The heavy lifting runs on
//  a Metal Core Image kernel; if that can not be loaded we fall back to a
//  pure Core Image approximation so the effect always works.
//
//  The effect is applied non-destructively at display time (see TSSTPageView);
//  the original NSImage is never modified.
//

import AppKit
import CoreImage
import Metal

@objc(SCPaperFilter)
final class SCPaperFilter: NSObject {

	/// Shared instance – keeps a single (Metal-backed) CIContext + kernel alive.
	/// `nonisolated(unsafe)` is safe here: the instance is immutable after init
	/// and CIContext is documented as thread-safe.
	@objc(sharedFilter)
	nonisolated(unsafe) static let shared = SCPaperFilter()

	// MARK: - User-defaults keys & registered defaults

	@objc static let enabledKey     = "SCPaperEffectEnabled"
	@objc static let showThroughKey = "SCPaperShowThrough"
	@objc static let grainKey       = "SCPaperGrain"
	@objc static let warmthKey      = "SCPaperWarmth"
	@objc static let blackLiftKey   = "SCPaperBlackLift"
	@objc static let fiberScaleKey  = "SCPaperFiberScale"

	/// Posted (on the main thread) whenever a parameter changes so views can
	/// drop their cached filtered image and redraw.
	@objc static let settingsChangedNotification = Notification.Name("SCPaperSettingsChanged")

	/// Registered so `-boolForKey:`/`-doubleForKey:` return sensible values.
	@objc static let registeredDefaults: [String: Any] = [
		enabledKey: false,
		showThroughKey: 0.38,
		grainKey: 0.14,
		warmthKey: 1.0,
		blackLiftKey: 1.0,
		fiberScaleKey: 2.0,
	]

	// MARK: - Rendering

	private let context: CIContext
	private let kernel: CIKernel?    // Metal paperTexture; nil => CI fallback.
	private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

	override init() {
		// NSNull working space => filters operate directly on the (sRGB encoded)
		// pixel values, giving intuitive "levels"-style tonal math.
		let options: [CIContextOption: Any] = [.workingColorSpace: NSNull()]
		if let device = MTLCreateSystemDefaultDevice() {
			context = CIContext(mtlDevice: device, options: options)
		} else {
			context = CIContext(options: options)
		}
		kernel = SCPaperFilter.loadKernel()
		super.init()
	}

	private static func loadKernel() -> CIKernel? {
		guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
			  let data = try? Data(contentsOf: url) else { return nil }
		return try? CIKernel(functionName: "paperTexture", fromMetalLibraryData: data)
	}

	/// Returns a new NSImage with the paper effect applied, or `nil` if the
	/// image can not be rendered.
	@objc(paperImageFromImage:)
	func paperImage(from image: NSImage) -> NSImage? {
		var proposed = NSRect(origin: .zero, size: image.size)
		guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
			return nil
		}
		let input = CIImage(cgImage: source)
		let output = applyPaperEffect(to: input)
		guard let rendered = context.createCGImage(output,
												   from: input.extent,
												   format: .RGBA8,
												   colorSpace: outputColorSpace) else {
			return nil
		}
		return NSImage(cgImage: rendered,
					   size: NSSize(width: rendered.width, height: rendered.height))
	}

	// MARK: - Parameters (read live from user defaults)

	private struct Params {
		var showThrough, grain, warmth, blackLift, fiberScale: CGFloat
	}

	private func currentParams() -> Params {
		let d = UserDefaults.standard
		func value(_ key: String, _ fallback: Double) -> CGFloat {
			d.object(forKey: key) == nil ? CGFloat(fallback) : CGFloat(d.double(forKey: key))
		}
		return Params(showThrough: value(Self.showThroughKey, 0.38),
					  grain:       value(Self.grainKey, 0.14),
					  warmth:      value(Self.warmthKey, 1.0),
					  blackLift:   value(Self.blackLiftKey, 1.0),
					  fiberScale:  max(value(Self.fiberScaleKey, 2.0), 0.5))
	}

	/// Interpolates the tonal endpoints between a neutral grey paper (warmth 0)
	/// and a warm cream stock (warmth 1); `blackLift` scales how far pure black
	/// is raised (0 = pure black / high contrast, 1 = full soft lift).
	private func tones(warmth: CGFloat, blackLift: CGFloat)
		-> (floor: CIVector, ceil: CIVector, tint: CIVector) {
		func lerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: CGFloat)
			-> (Double, Double, Double) {
			let tt = Double(t)
			return (a.0 + (b.0 - a.0) * tt, a.1 + (b.1 - a.1) * tt, a.2 + (b.2 - a.2) * tt)
		}
		let neutralFloor = (0.145, 0.145, 0.145), warmFloor = (0.16, 0.14, 0.11)
		let neutralCeil  = (0.93, 0.93, 0.93),    warmCeil  = (0.96, 0.92, 0.82)
		let neutralTint  = (0.92, 0.92, 0.92),    warmTint  = (0.95, 0.90, 0.78)

		let fl = lerp(neutralFloor, warmFloor, warmth)
		let ce = lerp(neutralCeil,  warmCeil,  warmth)
		let ti = lerp(neutralTint,  warmTint,  warmth)
		let bl = Double(blackLift)
		return (CIVector(x: fl.0 * bl, y: fl.1 * bl, z: fl.2 * bl),
				CIVector(x: ce.0, y: ce.1, z: ce.2),
				CIVector(x: ti.0, y: ti.1, z: ti.2))
	}

	// MARK: - Pipeline

	private func applyPaperEffect(to input: CIImage) -> CIImage {
		let p = currentParams()
		let t = tones(warmth: p.warmth, blackLift: p.blackLift)

		// 1. Compress tonal range + tint: out = in * (ceil - floor) + floor.
		let sR = t.ceil.x - t.floor.x, sG = t.ceil.y - t.floor.y, sB = t.ceil.z - t.floor.z
		var toned = input.applyingFilter("CIColorMatrix", parameters: [
			"inputRVector": CIVector(x: sR, y: 0, z: 0, w: 0),
			"inputGVector": CIVector(x: 0, y: sG, z: 0, w: 0),
			"inputBVector": CIVector(x: 0, y: 0, z: sB, w: 0),
			"inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
			"inputBiasVector": CIVector(x: t.floor.x, y: t.floor.y, z: t.floor.z, w: 0),
		])
		// 2. Gentle desaturation + soft contrast for a matte, printed feel.
		toned = toned.applyingFilter("CIColorControls", parameters: [
			kCIInputSaturationKey: 0.92,
			kCIInputContrastKey: 0.96,
		])

		// 3. Organic paper texture (Metal), with a Core Image fallback.
		if let kernel = kernel {
			let textured = kernel.apply(extent: input.extent,
										roiCallback: { _, rect in rect },
										arguments: [toned, p.grain, p.showThrough, p.fiberScale, t.tint])
			if let textured = textured {
				return textured.cropped(to: input.extent)
			}
		}
		return fallbackTexture(on: toned, tint: t.tint, grain: p.grain, showThrough: p.showThrough)
			.cropped(to: input.extent)
	}

	/// Pure Core Image approximation used when the Metal kernel is unavailable:
	/// a softened multiply grain for the body + a screen highlight for show-through.
	private func fallbackTexture(on toned: CIImage, tint: CIVector,
								 grain: CGFloat, showThrough: CGFloat) -> CIImage {
		let extent = toned.extent
		guard let gen = CIFilter(name: "CIRandomGenerator")?.outputImage else { return toned }
		var fiber = gen.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
		fiber = fiber.transformed(by: CGAffineTransform(scaleX: 2.0, y: 1.0))
		fiber = fiber.clampedToExtent()
			.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.1])
			.cropped(to: extent)

		let m = grain
		let mult = fiber.applyingFilter("CIColorMatrix", parameters: [
			"inputRVector": CIVector(x: m, y: 0, z: 0, w: 0),
			"inputGVector": CIVector(x: 0, y: m, z: 0, w: 0),
			"inputBVector": CIVector(x: 0, y: 0, z: m, w: 0),
			"inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
			"inputBiasVector": CIVector(x: 1 - m, y: 1 - m, z: 1 - m, w: 1),
		])
		var out = mult.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: toned])

		let peaks = fiber.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.2])
		let s = showThrough
		let peek = peaks.applyingFilter("CIColorMatrix", parameters: [
			"inputRVector": CIVector(x: tint.x * s, y: 0, z: 0, w: 0),
			"inputGVector": CIVector(x: 0, y: tint.y * s, z: 0, w: 0),
			"inputBVector": CIVector(x: 0, y: 0, z: tint.z * s, w: 0),
			"inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
			"inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
		])
		out = out.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: peek])
		return out
	}
}
