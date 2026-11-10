//
//  LiveTextOverlayCoordinator.swift
//  Simple Comic
//
//  Native Live Text (VisionKit) selection over comic pages.
//  Idea and initial approach from MaddTheSane/Simple-Comic#148 by ZHANG Cheng.
//

import Cocoa
import VisionKit
import ImageIO

/// Owns one `ImageAnalysisOverlayView` per visible page (key 0 = first page, 1 = second)
/// and keeps each one in sync with the page's image and on-screen rect.
@MainActor
@objcMembers
final class LiveTextOverlayCoordinator: NSObject {
	private weak var hostView: NSView?
	private var overlays: [Int: ImageAnalysisOverlayView] = [:]
	private var tasks: [Int: Task<Void, Never>] = [:]
	private var tokens: [Int: Int] = [:]
	private var latestFrames: [Int: NSRect] = [:]
	// Strong refs: comparing ObjectIdentifiers lets a freed image's address be reused by the next
	// page's image, which skipped re-analysis and left the previous page's text on the overlay.
	private var lastImages: [Int: NSImage] = [:]
	private var lastOrientations: [Int: CGImagePropertyOrientation] = [:]

	/// True when Live Text can run on this machine.
	static func isAvailable() -> Bool {
		ImageAnalyzer.isSupported
	}

	init(hostView: NSView) {
		self.hostView = hostView
		super.init()
	}

	/// Shows (or updates) the overlay for a page. `frame` is the page's rect in the host view's
	/// coordinates *after* any page rotation; `rotation` is the page rotation (0-3).
	/// Cheap to call repeatedly: analysis only restarts when the image or rotation changes.
	func setImage(_ image: NSImage?, frame: NSRect, key: Int, rotation: Int) {
		guard hostView != nil, let image else {
			remove(key: key)
			return
		}
		let orientation = Self.orientation(forPageRotation: rotation)
		latestFrames[key] = frame

		if lastImages[key] === image, lastOrientations[key] == orientation {
			// Same page: just follow its rect. (The overlay only exists once analysis finished.)
			if let overlay = overlays[key], overlay.frame != frame {
				overlay.frame = frame
			}
			return
		}

		// New page: drop the old overlay entirely. Reusing one overlay across pages left it with a
		// stale/blank interaction state (button flashed then vanished, selection dead).
		remove(key: key)
		latestFrames[key] = frame
		lastImages[key] = image
		lastOrientations[key] = orientation

		let token = (tokens[key] ?? 0) + 1
		tokens[key] = token

		tasks[key] = Task { [weak self] in
			let analyzer = ImageAnalyzer()
			let configuration = ImageAnalyzer.Configuration([.text])
			let analysis = try? await analyzer.analyze(image, orientation: orientation, configuration: configuration)
			guard let self, !Task.isCancelled, self.tokens[key] == token,
				  let analysis, let hostView = self.hostView else { return }
			let overlay = ImageAnalysisOverlayView(frame: self.latestFrames[key] ?? .zero)
			overlay.preferredInteractionTypes = .automatic
			overlay.analysis = analysis
			hostView.addSubview(overlay)
			self.overlays[key] = overlay
			self.tasks[key] = nil
		}
	}

	/// True while the user has text selected in any page's overlay.
	var hasActiveTextSelection: Bool {
		overlays.values.contains { $0.hasActiveTextSelection }
	}

	/// Removes every overlay and cancels pending analysis.
	func clear() {
		for key in Array(overlays.keys) {
			remove(key: key)
		}
	}

	private func remove(key: Int) {
		tasks[key]?.cancel()
		tasks[key] = nil
		tokens[key] = (tokens[key] ?? 0) + 1
		overlays[key]?.removeFromSuperview()
		overlays[key] = nil
		lastImages[key] = nil
		lastOrientations[key] = nil
		latestFrames[key] = nil
	}

	private static func orientation(forPageRotation rotation: Int) -> CGImagePropertyOrientation {
		switch rotation {
		case 1: return .right
		case 2: return .down
		case 3: return .left
		default: return .up
		}
	}
}
