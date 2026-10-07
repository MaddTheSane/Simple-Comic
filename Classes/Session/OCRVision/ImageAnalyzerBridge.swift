import Foundation
import AppKit
#if canImport(VisionKit)
import VisionKit
import ImageIO
#endif

@objc final class ImageAnalyzerBridge: NSObject {
    @objc static func isAvailable() -> Bool {
        #if canImport(VisionKit)
        if #available(macOS 13.0, *) {
            return ImageAnalyzer.isSupported
        }
        #endif
        return false
    }

    @objc @MainActor func analyzeImage(_ image: NSImage, completion: @escaping (NSString?, NSError?) -> Void) {
        #if canImport(VisionKit)
        guard #available(macOS 13.0, *) else {
            completion(nil, nil)
            return
        }

        Task {
            let analyzer = ImageAnalyzer()
            let configuration = ImageAnalyzer.Configuration([.text])
            let orientations: [CGImagePropertyOrientation] = [.up, .left, .right]

            var bestTranscript = ""
            var lastError: Error?

            for orientation in orientations {
                do {
                    let analysis = try await analyzer.analyze(image, orientation: orientation, configuration: configuration)
                    let transcript = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if transcript.count > bestTranscript.count {
                        bestTranscript = transcript
                    }
                } catch {
                    lastError = error
                }
            }

            completion(bestTranscript as NSString, lastError as NSError?)
        }
        #else
        completion(nil, nil)
        #endif
    }
}
