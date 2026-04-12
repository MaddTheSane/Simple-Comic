//
//  TSSTImageView.swift
//  SimpleComic
//
//  Created by C.W. Betts on 10/26/15.
//
//

import Cocoa
#if canImport(VisionKit)
import VisionKit
import ImageIO
#endif

nonisolated(unsafe) private let stringAttributes: [NSAttributedString.Key: Any] = {
	let style = NSMutableParagraphStyle()
	style.lineBreakMode = .byTruncatingHead
	return [.font: NSFont.labelFont(ofSize: 14),
			.foregroundColor: NSColor.white,
			.paragraphStyle: style.copy()]
}()

class TSSTImageView: NSImageView {
	var imageName: String?
	var clears: Bool = false
	
	override func draw(_ dirtyRect: NSRect) {
		if clears {
			NSColor.clear.set()
			bounds.fill()
		}
		
		var imageRect = rectCentered(with: image?.size ?? .zero, in: bounds)
		//[NSGraphicsContext saveGraphicsState];
		//[[NSGraphicsContext currentContext] setImageInterpolation: NSImageInterpolationHigh];
		image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
		if let imageName = imageName {
			imageRect = imageRect.insetBy(dx: 10, dy: 10)
			var stringRect = imageName.boundingRect(with: imageRect.size, attributes: stringAttributes)
			stringRect = rectCentered(with: stringRect.size, in: imageRect);
			NSColor(calibratedWhite: 0, alpha: 0.8).set()
			NSBezierPath(roundedRect: stringRect.insetBy(dx: -5, dy: -5), cornerRadius: 10).fill()
			imageName.draw(in: stringRect, withAttributes: stringAttributes)
		}
		
		//[NSGraphicsContext restoreGraphicsState];
	}
}

extension NSBezierPath {
	@inlinable convenience init(roundedRect aRect: NSRect, cornerRadius radius: CGFloat) {
		self.init(roundedRect: aRect, xRadius: radius, yRadius: radius)
	}
}

@MainActor
@objcMembers
final class LiveTextOverlayCoordinator: NSObject {
	#if canImport(VisionKit)
	private weak var hostView: NSView?
	private weak var overlayContainer: NSView?
	private var overlays: [Int: NSView] = [:]
	private var requestTokens: [Int: Int] = [:]
	private var activeTasks: [Int: Task<Void, Never>] = [:]
	private var lastImageIDs: [Int: ObjectIdentifier] = [:]
	private var lastFrames: [Int: NSRect] = [:]
	private var lastOrientations: [Int: CGImagePropertyOrientation] = [:]
	#endif

	@objc static func isAvailable() -> Bool {
		#if canImport(VisionKit)
		if #available(macOS 13.0, *) {
			return ImageAnalyzer.isSupported
		}
		#endif
		return false
	}

	@objc init(hostView: NSView) {
		self.hostView = hostView
		super.init()
		#if canImport(VisionKit)
		if #available(macOS 13.0, *) {
			let container = NSView(frame: hostView.bounds)
			container.wantsLayer = true
			container.autoresizingMask = [.width, .height]
			hostView.addSubview(container)
			overlayContainer = container
		}
		#endif
	}

	@objc func updateContainer(frame: NSRect, transform: CGAffineTransform) {
		#if canImport(VisionKit)
		guard #available(macOS 13.0, *) else { return }
		guard let hostView else { return }
		let container: NSView
		if let existing = overlayContainer {
			container = existing
		} else {
			let newContainer = NSView(frame: frame)
			newContainer.wantsLayer = true
			newContainer.autoresizingMask = [.width, .height]
			hostView.addSubview(newContainer)
			overlayContainer = newContainer
			container = newContainer
		}

		container.frame = frame
		hostView.addSubview(container, positioned: .above, relativeTo: nil)
		container.layer?.setAffineTransform(transform)
		#endif
	}

	@objc func clearAll() {
		#if canImport(VisionKit)
		if #available(macOS 13.0, *) {
			for task in activeTasks.values {
				task.cancel()
			}
			for overlay in overlays.values {
				overlay.removeFromSuperview()
			}
			overlays.removeAll()
			requestTokens.removeAll()
			activeTasks.removeAll()
			lastImageIDs.removeAll()
			lastFrames.removeAll()
			lastOrientations.removeAll()
			overlayContainer?.removeFromSuperview()
			overlayContainer = nil
		}
		#endif
	}

	@objc func setImage(_ image: NSImage?, frame: NSRect, key: NSNumber, rotation: Int) {
		#if canImport(VisionKit)
		guard #available(macOS 13.0, *) else { return }
		guard let hostView else { return }
		let k = key.intValue
		let orientation = Self.imageOrientation(forPageRotation: rotation)
		let container: NSView
		if let existing = overlayContainer {
			container = existing
		} else {
			let newContainer = NSView(frame: hostView.bounds)
			newContainer.wantsLayer = true
			newContainer.autoresizingMask = [.width, .height]
			hostView.addSubview(newContainer)
			overlayContainer = newContainer
			container = newContainer
		}

		if image == nil {
			activeTasks[k]?.cancel()
			activeTasks.removeValue(forKey: k)
			overlays[k]?.removeFromSuperview()
			overlays.removeValue(forKey: k)
			requestTokens.removeValue(forKey: k)
			lastImageIDs.removeValue(forKey: k)
			lastFrames.removeValue(forKey: k)
			lastOrientations.removeValue(forKey: k)
			return
		}

		let overlay: ImageAnalysisOverlayView
		if let existing = overlays[k] as? ImageAnalysisOverlayView {
			overlay = existing
		} else {
			overlay = ImageAnalysisOverlayView(frame: frame)
			overlay.preferredInteractionTypes = .automatic
			overlays[k] = overlay
			container.addSubview(overlay)
		}

		let normalizedFrame = frame.integral
		overlay.frame = normalizedFrame
		container.addSubview(overlay, positioned: .above, relativeTo: nil)

		guard let sourceImage = image else { return }
		let imageID = ObjectIdentifier(sourceImage)
		let hasAnalysis = (overlay.analysis != nil)
		let sameImage = (lastImageIDs[k] == imageID)
		let sameFrame = (lastFrames[k] == normalizedFrame)
		let sameOrientation = (lastOrientations[k] == orientation)
		if sameImage && sameFrame && sameOrientation && (hasAnalysis || activeTasks[k] != nil) {
			return
		}

		lastImageIDs[k] = imageID
		lastFrames[k] = normalizedFrame
		lastOrientations[k] = orientation

		let token = (requestTokens[k] ?? 0) + 1
		requestTokens[k] = token
		activeTasks[k]?.cancel()

		let analyzer = ImageAnalyzer()
		let configuration = ImageAnalyzer.Configuration([.text])

		let task = Task { @MainActor in
			do {
				let analysis = try await analyzer.analyze(sourceImage, orientation: orientation, configuration: configuration)
				if !Task.isCancelled, requestTokens[k] == token {
					overlay.analysis = analysis
				}
			} catch {
				if requestTokens[k] == token {
					activeTasks[k] = nil
				}
				return
			}
			if requestTokens[k] == token {
				activeTasks[k] = nil
			}
		}
		activeTasks[k] = task
		#endif
	}

	#if canImport(VisionKit)
	private static func imageOrientation(forPageRotation rotation: Int) -> CGImagePropertyOrientation {
		switch rotation {
		case 1:
			return .right
		case 2:
			return .down
		case 3:
			return .left
		default:
			return .up
		}
	}
	#endif
}
