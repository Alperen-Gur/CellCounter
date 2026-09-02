import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum WorkspaceAnimationError: LocalizedError, Equatable {
    case insufficientKeyframes
    case invalidFrameRate
    case tooManyFrames(Int)
    case sourceDecodeFailed(String)
    case destinationCreationFailed
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case .insufficientKeyframes: return "Animation requires at least two keyframes or source images."
        case .invalidFrameRate: return "Choose a frame rate between 1 and 60 frames per second."
        case .tooManyFrames(let count): return "The animation would contain \(count) frames; the local limit is 3,600."
        case .sourceDecodeFailed(let name): return "Could not decode animation source “\(name)”."
        case .destinationCreationFailed: return "Could not create the animation file."
        case .finalizeFailed: return "The animation file could not be finalized."
        }
    }
}

enum WorkspaceAnimationService {
    nonisolated static func frameStates(for plan: WorkspaceAnimationPlan) throws -> [WorkspaceAnimationFrameState] {
        guard plan.framesPerSecond >= 1, plan.framesPerSecond <= 60 else {
            throw WorkspaceAnimationError.invalidFrameRate
        }
        let keyframes = plan.keyframes.sorted { $0.timeSeconds < $1.timeSeconds }
        guard keyframes.count >= 2,
              let first = keyframes.first, let last = keyframes.last,
              last.timeSeconds > first.timeSeconds else {
            throw WorkspaceAnimationError.insufficientKeyframes
        }
        let frameCount = Int(ceil((last.timeSeconds - first.timeSeconds) * Double(plan.framesPerSecond))) + 1
        guard frameCount <= 3_600 else { throw WorkspaceAnimationError.tooManyFrames(frameCount) }
        var states: [WorkspaceAnimationFrameState] = []
        states.reserveCapacity(frameCount)
        var segment = 0
        for frame in 0..<frameCount {
            let time = min(last.timeSeconds,
                           first.timeSeconds + Double(frame) / Double(plan.framesPerSecond))
            while segment + 1 < keyframes.count - 1,
                  time > keyframes[segment + 1].timeSeconds { segment += 1 }
            let start = keyframes[segment]
            let end = keyframes[min(segment + 1, keyframes.count - 1)]
            let span = max(1e-9, end.timeSeconds - start.timeSeconds)
            var t = min(max((time - start.timeSeconds) / span, 0), 1)
            if plan.easing == .easeInOut { t = t * t * (3 - 2 * t) }
            var indices: [UUID: Int] = [:]
            for axisID in Set(start.position.indices.keys).union(end.position.indices.keys) {
                let a = Double(start.position.indices[axisID, default: 0])
                let b = Double(end.position.indices[axisID, default: Int(a)])
                indices[axisID] = Int((a + (b - a) * t).rounded())
            }
            states.append(WorkspaceAnimationFrameState(
                frameNumber: frame, timeSeconds: time,
                position: WorkspacePosition(indices: indices),
                zoom: start.zoom + (end.zoom - start.zoom) * t,
                center: WorkspaceCoordinate(
                    x: start.center.x + (end.center.x - start.center.x) * t,
                    y: start.center.y + (end.center.y - start.center.y) * t,
                    z: interpolate(start.center.z, end.center.z, t)),
                visibleLayerIDs: t < 0.5 ? start.visibleLayerIDs : end.visibleLayerIDs))
        }
        return states
    }

    nonisolated static func exportGIF(imageURLs: [URL], outputURL: URL,
                                      framesPerSecond: Int = 8,
                                      maxDimension: Int = 1600,
                                      loop: Bool = true) throws {
        guard imageURLs.count >= 2 else { throw WorkspaceAnimationError.insufficientKeyframes }
        guard framesPerSecond >= 1, framesPerSecond <= 60 else {
            throw WorkspaceAnimationError.invalidFrameRate
        }
        guard imageURLs.count <= 3_600 else { throw WorkspaceAnimationError.tooManyFrames(imageURLs.count) }
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, imageURLs.count, nil) else {
            throw WorkspaceAnimationError.destinationCreationFailed
        }
        if loop {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
        }
        let delay = 1.0 / Double(framesPerSecond)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
        ] as CFDictionary
        for url in imageURLs {
            var added = false
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                    kCGImageSourceShouldCache: false,
                ] as CFDictionary),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(64, maxDimension),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary) else { return }
                CGImageDestinationAddImage(destination, image, frameProperties)
                added = true
            }
            guard added else {
                throw WorkspaceAnimationError.sourceDecodeFailed(url.lastPathComponent)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            throw WorkspaceAnimationError.finalizeFailed
        }
    }

    nonisolated static func exportGIF(frames: [CGImage], outputURL: URL,
                                      framesPerSecond: Int = 8,
                                      loop: Bool = true) throws {
        guard frames.count >= 2 else { throw WorkspaceAnimationError.insufficientKeyframes }
        guard framesPerSecond >= 1, framesPerSecond <= 60 else {
            throw WorkspaceAnimationError.invalidFrameRate
        }
        guard frames.count <= 3_600 else { throw WorkspaceAnimationError.tooManyFrames(frames.count) }
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw WorkspaceAnimationError.destinationCreationFailed
        }
        if loop {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
        }
        let properties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / Double(framesPerSecond)]
        ] as CFDictionary
        for image in frames { CGImageDestinationAddImage(destination, image, properties) }
        guard CGImageDestinationFinalize(destination) else { throw WorkspaceAnimationError.finalizeFailed }
    }

    private nonisolated static func interpolate(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let value?, nil), (nil, let value?): return value
        case (let first?, let second?): return first + (second - first) * t
        }
    }
}
