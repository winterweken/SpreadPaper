import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Combine
import AVFoundation

// MARK: - Data Models

struct DynamicWallpaperInfo: Identifiable, Hashable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let path: URL
    let frameCount: Int
    let type: DynamicType
    let previewImage: NSImage?
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
    
    static func == (lhs: DynamicWallpaperInfo, rhs: DynamicWallpaperInfo) -> Bool {
        lhs.path == rhs.path
    }
}

enum DynamicType: Sendable {
    case solar       // Time/location based
    case appearance  // Light/dark mode
    case video       // Video-based wallpapers converted to dynamic HEIC
    case unknown
}

struct DynamicFrame: @unchecked Sendable {
    let image: CGImage
    nonisolated(unsafe) let metadata: NSDictionary
}

// MARK: - Manager

@MainActor
class DynamicWallpaperManager: ObservableObject {
    @Published var systemWallpapers: [DynamicWallpaperInfo] = []
    
    init() {
        discoverSystemWallpapers()
    }
    
    // MARK: - Discovery
    
    func discoverSystemWallpapers() {
        // Perform heavy I/O work off the main actor
        Task.detached { [weak self] in
            guard let self else { return }
            
            print("🔍 Starting dynamic wallpaper discovery...")
            
            // Check user's home directory too
            let userLibrary = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            var basePaths = [
                "/System/Library/Desktop Pictures",
                "/Library/Desktop Pictures",
                "/System/Library/Screen Savers/Default Collections",
                "/Library/Application Support/com.apple.idleassetsd/Customer",
                "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS"
            ]
            if let userLib = userLibrary {
                basePaths.append(userLib.appendingPathComponent("Desktop Pictures").path)
                basePaths.append(userLib.appendingPathComponent("Application Support/com.apple.idleassetsd/Customer").path)
            }
            
            let heicExt = "heic"
            let videoExts: Set<String> = ["mp4", "mov", "m4v"]
            
            print("📍 Searching in \(basePaths.count) locations")
            
            // First, collect all file URLs synchronously to avoid async enumeration issues
            let fileURLs: [URL] = basePaths.flatMap { basePath -> [URL] in
                let baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
                let fileManager = FileManager.default
                
                print("📂 Checking directory: \(basePath)")
                
                // Check if directory exists
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: basePath, isDirectory: &isDirectory)
                print("   Exists: \(exists), Is Directory: \(isDirectory.boolValue)")
                
                guard let enumerator = fileManager.enumerator(
                    at: baseURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .nameKey, .isPackageKey],
                    options: []  // Don't skip anything - search everything
                ) else {
                    print("   ❌ Failed to create enumerator for \(basePath)")
                    return []
                }
                
                var urls: [URL] = []
                var fileCount = 0
                // Collect all URLs first without any async operations
                for case let itemURL as URL in enumerator {
                    fileCount += 1
                    let ext = itemURL.pathExtension.lowercased()
                    
                    // Check for video and HEIC files
                    if ext == heicExt || videoExts.contains(ext) {
                        print("   ✅ Found: \(itemURL.path.replacingOccurrences(of: basePath + "/", with: ""))")
                        urls.append(itemURL)
                    }
                    
                    // Also check inside .wallpaper bundles
                    if itemURL.pathExtension.lowercased() == "wallpaper" {
                        print("   🎁 Found wallpaper bundle: \(itemURL.lastPathComponent)")
                        // Look inside the bundle for video files
                        if let bundleContents = try? fileManager.contentsOfDirectory(at: itemURL, includingPropertiesForKeys: nil) {
                            for bundleFile in bundleContents {
                                let bundleExt = bundleFile.pathExtension.lowercased()
                                if videoExts.contains(bundleExt) {
                                    print("      ✅ Found video in bundle: \(bundleFile.lastPathComponent)")
                                    urls.append(bundleFile)
                                }
                            }
                        }
                    }
                }
                print("   Scanned \(fileCount) total items, found \(urls.count) matching files in \(basePath)")
                return urls
            }
            
            print("📊 Total files found: \(fileURLs.count)")
            
            // FALLBACK: Manually check known video wallpaper locations
            // macOS often hides these in specific subdirectories
            let knownVideoLocations = [
                "/System/Library/Desktop Pictures/Hello.mov",
                "/System/Library/Desktop Pictures/Reflection.mov",
                "/System/Library/Desktop Pictures/Drift.mov",
                "/System/Library/Desktop Pictures/Underwater.mov"
            ]
            
            var additionalVideos: [URL] = []
            for path in knownVideoLocations {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) && !fileURLs.contains(url) {
                    print("📌 Found video at known location: \(path)")
                    additionalVideos.append(url)
                }
            }
            
            let allFiles = fileURLs + additionalVideos
            print("📊 Total files including fallback: \(allFiles.count)")
            
            // Now process the collected URLs asynchronously
            var wallpapers: [DynamicWallpaperInfo] = []
            
            for itemURL in allFiles {
                let ext = itemURL.pathExtension.lowercased()
                if ext == heicExt {
                    print("🖼️  Processing HEIC: \(itemURL.lastPathComponent)")
                    let frames = self.extractFrames(from: itemURL)
                    print("   Extracted \(frames.count) frames")
                    guard frames.count > 1 else {
                        print("   ⚠️  Skipping (needs > 1 frame)")
                        continue
                    }
                    let name = itemURL.deletingPathExtension().lastPathComponent
                    let type = self.detectDynamicType(from: frames)
                    let preview = self.createPreviewImage(from: frames.first?.image)
                    wallpapers.append(DynamicWallpaperInfo(
                        name: name,
                        path: itemURL,
                        frameCount: frames.count,
                        type: type,
                        previewImage: preview
                    ))
                    print("   ✅ Added: \(name)")
                } else if videoExts.contains(ext) {
                    print("🎥 Processing Video: \(itemURL.lastPathComponent)")
                    let name = itemURL.deletingPathExtension().lastPathComponent
                    
                    // Try to load the asset first to verify it's accessible
                    let asset = AVURLAsset(url: itemURL)
                    
                    // Check if the file is actually readable
                    guard FileManager.default.isReadableFile(atPath: itemURL.path) else {
                        print("   ❌ File is not readable, skipping")
                        continue
                    }
                    
                    // Generate preview (can fail gracefully)
                    let preview = self.generateVideoPreview(url: itemURL)
                    if preview != nil {
                        print("   ✅ Preview generated")
                    } else {
                        print("   ⚠️  Preview generation failed, using placeholder")
                    }
                    
                    // Load duration asynchronously to avoid deprecated property access
                    do {
                        let duration = try await asset.load(.duration)
                        let durationSeconds = CMTimeGetSeconds(duration)
                        
                        if durationSeconds.isFinite && durationSeconds > 0 {
                            let estimatedCount = max(2, Int(durationSeconds.rounded(.up)))
                            wallpapers.append(DynamicWallpaperInfo(
                                name: name,
                                path: itemURL,
                                frameCount: estimatedCount,
                                type: .video,
                                previewImage: preview
                            ))
                            print("   ✅ Added: \(name) (duration: \(String(format: "%.1f", durationSeconds))s, \(estimatedCount) frames)")
                        } else {
                            print("   ⚠️  Invalid duration: \(durationSeconds), using fallback")
                            wallpapers.append(DynamicWallpaperInfo(
                                name: name,
                                path: itemURL,
                                frameCount: 10,
                                type: .video,
                                previewImage: preview
                            ))
                            print("   ⚠️  Added with fallback (10 frames)")
                        }
                    } catch {
                        print("   ⚠️  Failed to load duration: \(error.localizedDescription)")
                        // Fallback: if duration fails to load, still add it with an estimate
                        wallpapers.append(DynamicWallpaperInfo(
                            name: name,
                            path: itemURL,
                            frameCount: 10,
                            type: .video,
                            previewImage: preview
                        ))
                        print("   ⚠️  Added with fallback (10 frames)")
                    }
                }
            }

            print("✅ Discovery complete: \(wallpapers.count) dynamic wallpapers found")
            
            // Update on main actor
            await MainActor.run { [wallpapers] in
                self.systemWallpapers = wallpapers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                print("📱 UI updated with \(wallpapers.count) wallpapers")
            }
        }
    }
    
    // MARK: - Frame Extraction
    
    nonisolated func extractFrames(from url: URL) -> [DynamicFrame] {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("      ❌ File not readable: \(url.path)")
            return []
        }
        
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            print("      ❌ Failed to create image source for: \(url.lastPathComponent)")
            return []
        }
        
        let frameCount = CGImageSourceGetCount(imageSource)
        print("      Found \(frameCount) frame(s) in image source")
        
        var frames: [DynamicFrame] = []
        
        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else {
                print("      ⚠️  Failed to extract frame \(index)")
                continue
            }
            
            let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as NSDictionary? ?? NSDictionary()
            
            frames.append(DynamicFrame(image: cgImage, metadata: metadata))
        }
        
        return frames
    }
    
    // MARK: - Dynamic Type Detection
    
    private nonisolated func detectDynamicType(from frames: [DynamicFrame]) -> DynamicType {
        // Check first frame's metadata for solar or appearance hints
        guard let firstMetadata = frames.first?.metadata else {
            return .unknown
        }
        
        // Solar wallpapers typically have "Apple Desktop" metadata with solar azimuth/altitude
        if let appleDesktop = firstMetadata["Apple Desktop"] as? NSDictionary {
            if appleDesktop["solar"] != nil {
                return .solar
            }
        }
        
        // Appearance-based wallpapers usually have 2 frames (light/dark)
        if frames.count == 2 {
            return .appearance
        }
        
        // More than 2 frames typically indicates solar/time-based
        if frames.count > 2 {
            return .solar
        }
        
        return .unknown
    }
    
    // MARK: - Preview Generation
    
    private nonisolated func createPreviewImage(from cgImage: CGImage?) -> NSImage? {
        guard let cgImage = cgImage else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return nsImage
    }
    
    private nonisolated func generateVideoPreview(url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 400, height: 400) // Limit size for thumbnails
        
        // Try multiple time points to get a frame
        let times: [CMTime] = [
            CMTime(seconds: 0.5, preferredTimescale: 600),
            CMTime(seconds: 1.0, preferredTimescale: 600),
            CMTime.zero
        ]
        
        for time in times {
            // Use a semaphore to make async method synchronous for preview generation
            let semaphore = DispatchSemaphore(value: 0)
            var resultImage: NSImage?
            var generateError: Error?
            
            imageGenerator.generateCGImageAsynchronously(for: time) { cgImage, actualTime, error in
                if let cgImage = cgImage {
                    resultImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                } else {
                    generateError = error
                }
                semaphore.signal()
            }
            
            // Wait up to 2 seconds for the preview
            _ = semaphore.wait(timeout: .now() + 2.0)
            
            if let image = resultImage {
                return image
            } else if let error = generateError {
                print("      Preview generation failed at \(time.seconds)s: \(error.localizedDescription)")
            }
        }
        
        return nil
    }

    nonisolated func sampleVideoFrames(url: URL, interval: CMTime) async throws -> [DynamicFrame] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite && durationSeconds > 0 else { return [] }

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        // Set the request options to use a higher priority queue for image generation
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var frames: [DynamicFrame] = []
        var current = CMTime.zero
        let end = duration

        while current <= end {
            do {
                let cg = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                    imageGenerator.generateCGImageAsynchronously(for: current) { cgImage, actualTime, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let cgImage = cgImage {
                            continuation.resume(returning: cgImage)
                        } else {
                            continuation.resume(throwing: NSError(domain: "DynamicWallpaperManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate image"]))
                        }
                    }
                }
                frames.append(DynamicFrame(image: cg, metadata: NSDictionary()))
            } catch {
                // Skip frames that fail to generate
            }
            current = current + interval
        }

        if frames.count < 2 {
            // Try to ensure at least two frames by sampling start and end
            do {
                let startImg = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                    imageGenerator.generateCGImageAsynchronously(for: .zero) { cgImage, actualTime, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let cgImage = cgImage {
                            continuation.resume(returning: cgImage)
                        } else {
                            continuation.resume(throwing: NSError(domain: "DynamicWallpaperManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate start image"]))
                        }
                    }
                }
                frames.append(DynamicFrame(image: startImg, metadata: NSDictionary()))
            } catch {}
            do {
                let endImg = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                    imageGenerator.generateCGImageAsynchronously(for: end) { cgImage, actualTime, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let cgImage = cgImage {
                            continuation.resume(returning: cgImage)
                        } else {
                            continuation.resume(throwing: NSError(domain: "DynamicWallpaperManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate end image"]))
                        }
                    }
                }
                frames.append(DynamicFrame(image: endImg, metadata: NSDictionary()))
            } catch {}
        }

        return frames
    }
    
    // MARK: - Frame Cropping
    
    nonisolated func cropFrame(_ sourceImage: CGImage, screenFrame: CGRect, totalCanvas: CGRect, offset: CGSize, imageScale: CGFloat, previewScale: CGFloat, isFlipped: Bool) -> CGImage? {
        let deviceScale: CGFloat = 2.0 // Assume retina for generated wallpapers
        let widthPx = Int(screenFrame.width * deviceScale)
        let heightPx = Int(screenFrame.height * deviceScale)
        
        guard let context = CGContext(
            data: nil,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        // Same math as WallpaperManager.renderAndSet
        let originalWidth = CGFloat(sourceImage.width)
        let originalHeight = CGFloat(sourceImage.height)
        
        let realOffsetX_Px = (offset.width / previewScale) * deviceScale
        let realOffsetY_Px = (offset.height / previewScale) * deviceScale
        let drawnImgWidthPx = originalWidth * imageScale * deviceScale
        let drawnImgHeightPx = originalHeight * imageScale * deviceScale
        let totalCanvasWidthPx = totalCanvas.width * deviceScale
        let totalCanvasHeightPx = totalCanvas.height * deviceScale
        let centeringX_Px = (totalCanvasWidthPx - drawnImgWidthPx) / 2.0
        let centeringY_Px = (totalCanvasHeightPx - drawnImgHeightPx) / 2.0
        let relativeScreenX = screenFrame.origin.x - totalCanvas.origin.x
        let relativeScreenY = screenFrame.origin.y - totalCanvas.origin.y
        
        let drawX = centeringX_Px + realOffsetX_Px - (relativeScreenX * deviceScale)
        let drawY = centeringY_Px - realOffsetY_Px - (relativeScreenY * deviceScale)
        
        let drawRect = CGRect(x: drawX, y: drawY, width: drawnImgWidthPx, height: drawnImgHeightPx)
        
        context.interpolationQuality = .high
        
        // Flip logic
        if isFlipped {
            context.saveGState()
            context.translateBy(x: drawRect.midX, y: drawRect.midY)
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: -drawRect.midX, y: -drawRect.midY)
        }
        
        context.draw(sourceImage, in: drawRect)
        
        if isFlipped {
            context.restoreGState()
        }
        
        return context.makeImage()
    }
    
    // MARK: - Dynamic HEIC Creation
    
    nonisolated func createDynamicHEIC(frames: [DynamicFrame], destinationURL: URL) -> Bool {
        guard !frames.isEmpty else { return false }
        
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.heic.identifier as CFString,
            frames.count,
            nil
        ) else { return false }
        
        // Add all frames with their metadata
        for frame in frames {
            CGImageDestinationAddImage(destination, frame.image, frame.metadata as CFDictionary)
        }
        
        return CGImageDestinationFinalize(destination)
    }
    
    // MARK: - Apply Video Wallpaper with Cropping
    
    func applyVideoWallpaper(
        sourceURL: URL,
        screens: [DisplayInfo],
        totalCanvas: CGRect,
        offset: CGSize,
        scale: CGFloat,
        previewScale: CGFloat,
        isFlipped: Bool,
        wallpapersDirectory: URL
    ) async -> Bool {
        print("🎬 Starting video wallpaper application for \(screens.count) screens")
        
        let asset = AVURLAsset(url: sourceURL)
        
        // Verify the video is readable
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            print("❌ Failed to load video track")
            return false
        }
        
        let naturalSize = try? await videoTrack.load(.naturalSize)
        let videoSize = naturalSize ?? CGSize(width: 1920, height: 1080)
        
        print("📐 Video size: \(videoSize.width)x\(videoSize.height)")
        
        // Process each screen
        for (index, displayInfo) in screens.enumerated() {
            print("🖥️  Processing screen \(index + 1)/\(screens.count): \(displayInfo.screen.localizedName)")
            
            // Calculate crop rect for this screen
            let cropRect = calculateVideoCropRect(
                videoSize: videoSize,
                screenFrame: displayInfo.frame,
                totalCanvas: totalCanvas,
                offset: offset,
                scale: scale,
                previewScale: previewScale,
                isFlipped: isFlipped
            )
            
            print("   Crop rect: \(cropRect)")
            
            // Create output URL
            let screenName = sanitizeScreenName(displayInfo.screen.localizedName)
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let filename = "spreadpaper_video_\(screenName)_\(timestamp).mov"
            let outputURL = wallpapersDirectory.appendingPathComponent(filename)
            
            // Export cropped video
            let success = await exportCroppedVideo(
                sourceAsset: asset,
                cropRect: cropRect,
                outputURL: outputURL,
                isFlipped: isFlipped
            )
            
            if success {
                // Apply the cropped video as wallpaper
                do {
                    try NSWorkspace.shared.setDesktopImageURL(outputURL, for: displayInfo.screen, options: [:])
                    print("   ✅ Applied cropped video to \(displayInfo.screen.localizedName)")
                } catch {
                    print("   ❌ Failed to set wallpaper: \(error.localizedDescription)")
                }
            } else {
                print("   ❌ Failed to export cropped video")
            }
        }
        
        return true
    }
    
    // Calculate the crop rectangle for a video to match the positioning
    private func calculateVideoCropRect(
        videoSize: CGSize,
        screenFrame: CGRect,
        totalCanvas: CGRect,
        offset: CGSize,
        scale: CGFloat,
        previewScale: CGFloat,
        isFlipped: Bool
    ) -> CGRect {
        // Convert preview offset to actual video coordinates
        let realOffsetX = offset.width / previewScale
        let realOffsetY = offset.height / previewScale
        
        // Calculate where the image would be drawn in the total canvas
        let scaledVideoWidth = videoSize.width * scale
        let scaledVideoHeight = videoSize.height * scale
        
        // Center the scaled video in the canvas
        let centeringX = (totalCanvas.width - scaledVideoWidth) / 2.0
        let centeringY = (totalCanvas.height - scaledVideoHeight) / 2.0
        
        // Position with offset
        let videoX = centeringX + realOffsetX
        let videoY = centeringY - realOffsetY
        
        // Calculate screen's position relative to canvas
        let relativeScreenX = screenFrame.origin.x - totalCanvas.origin.x
        let relativeScreenY = screenFrame.origin.y - totalCanvas.origin.y
        
        // Calculate what part of the video is visible on this screen
        let visibleX = relativeScreenX - videoX
        let visibleY = relativeScreenY - videoY
        
        // Convert to video coordinates (unscaled)
        let cropX = visibleX / scale
        let cropY = visibleY / scale
        let cropWidth = screenFrame.width / scale
        let cropHeight = screenFrame.height / scale
        
        // Clamp to video bounds
        let clampedX = max(0, min(cropX, videoSize.width))
        let clampedY = max(0, min(cropY, videoSize.height))
        let clampedWidth = min(cropWidth, videoSize.width - clampedX)
        let clampedHeight = min(cropHeight, videoSize.height - clampedY)
        
        return CGRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }
    
    // Export a cropped and scaled version of the video
    private func exportCroppedVideo(
        sourceAsset: AVAsset,
        cropRect: CGRect,
        outputURL: URL,
        isFlipped: Bool
    ) async -> Bool {
        print("   🎬 Exporting cropped video...")
        print("      Source: \(sourceAsset)")
        print("      Crop: \(cropRect)")
        print("      Output: \(outputURL.lastPathComponent)")
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        // For system files, use a simpler approach with AVAssetReader/Writer
        // to avoid SIP issues with AVAssetExportSession
        var useReaderWriter = false
        if let urlAsset = sourceAsset as? AVURLAsset {
            let sourcePath = urlAsset.url.path
            if sourcePath.hasPrefix("/System/") || sourcePath.hasPrefix("/Library/") {
                print("      ℹ️  Detected system file, using reader/writer approach")
                useReaderWriter = true
            }
        }
        
        if useReaderWriter {
            return await exportUsingReaderWriter(
                sourceAsset: sourceAsset,
                cropRect: cropRect,
                outputURL: outputURL,
                isFlipped: isFlipped
            )
        }
        
        // Standard export for non-system files
        return await exportUsingComposition(
            sourceAsset: sourceAsset,
            cropRect: cropRect,
            outputURL: outputURL,
            isFlipped: isFlipped
        )
    }
    
    // Export using AVAssetReader/Writer (for system files)
    private func exportUsingReaderWriter(
        sourceAsset: AVAsset,
        cropRect: CGRect,
        outputURL: URL,
        isFlipped: Bool
    ) async -> Bool {
        print("      📖 Using AVAssetReader/Writer method...")
        
        guard let videoTrack = try? await sourceAsset.loadTracks(withMediaType: .video).first else {
            print("      ❌ No video track found")
            return false
        }
        
        let duration = try? await sourceAsset.load(.duration)
        let naturalSize = try? await videoTrack.load(.naturalSize)
        
        // Create reader
        guard let reader = try? AVAssetReader(asset: sourceAsset) else {
            print("      ❌ Failed to create asset reader")
            return false
        }
        
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        reader.add(readerOutput)
        
        // Create writer
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
            print("      ❌ Failed to create asset writer")
            return false
        }
        
        let writerInputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(cropRect.width),
            AVVideoHeightKey: Int(cropRect.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerInputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)
        
        // Create pixel buffer adaptor for cropping
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(cropRect.width),
            kCVPixelBufferHeightKey as String: Int(cropRect.height)
        ]
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        
        // Start reading and writing
        guard reader.startReading() else {
            print("      ❌ Failed to start reading")
            return false
        }
        
        guard writer.startWriting() else {
            print("      ❌ Failed to start writing: \(writer.error?.localizedDescription ?? "unknown")")
            return false
        }
        
        writer.startSession(atSourceTime: .zero)
        
        // Process video frames
        let processingQueue = DispatchQueue(label: "video.processing")
        var frameCount = 0
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: processingQueue) {
                while writerInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    
                    // Get image buffer from sample
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        continue
                    }
                    
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    
                    // Create cropped pixel buffer
                    if let croppedBuffer = self.cropPixelBuffer(
                        imageBuffer,
                        cropRect: cropRect,
                        isFlipped: isFlipped
                    ) {
                        adaptor.append(croppedBuffer, withPresentationTime: presentationTime)
                        frameCount += 1
                    }
                }
            }
        }
        
        print("      ✅ Processed \(frameCount) frames")
        
        // Finish writing
        await writer.finishWriting()
        
        if writer.status == .completed {
            print("      ✅ Export completed successfully")
            return true
        } else {
            print("      ❌ Export failed: \(writer.error?.localizedDescription ?? "unknown")")
            return false
        }
    }
    
    // Helper to crop a pixel buffer
    private func cropPixelBuffer(
        _ sourceBuffer: CVPixelBuffer,
        cropRect: CGRect,
        isFlipped: Bool
    ) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)
        
        // Clamp crop rect to source bounds
        let clampedX = Int(max(0, min(cropRect.origin.x, CGFloat(sourceWidth))))
        let clampedY = Int(max(0, min(cropRect.origin.y, CGFloat(sourceHeight))))
        let clampedWidth = Int(min(cropRect.width, CGFloat(sourceWidth - clampedX)))
        let clampedHeight = Int(min(cropRect.height, CGFloat(sourceHeight - clampedY)))
        
        // Create output buffer
        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            clampedWidth,
            clampedHeight,
            kCVPixelFormatType_32BGRA,
            nil,
            &outputBuffer
        )
        
        guard status == kCVReturnSuccess, let output = outputBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        
        defer {
            CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        
        guard let sourceData = CVPixelBufferGetBaseAddress(sourceBuffer),
              let destData = CVPixelBufferGetBaseAddress(output) else {
            return nil
        }
        
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(sourceBuffer)
        let destBytesPerRow = CVPixelBufferGetBytesPerRow(output)
        
        // Copy cropped region
        for y in 0..<clampedHeight {
            let sourceOffset = (clampedY + y) * sourceBytesPerRow + (clampedX * 4)
            let destOffset = y * destBytesPerRow
            memcpy(destData + destOffset, sourceData + sourceOffset, clampedWidth * 4)
        }
        
        // TODO: Handle flip if needed (would require per-pixel manipulation)
        
        return output
    }
    
    // Export using composition (for non-system files)
    private func exportUsingComposition(
        sourceAsset: AVAsset,
        cropRect: CGRect,
        outputURL: URL,
        isFlipped: Bool
    ) async -> Bool {
        print("      🎬 Using composition method...")
        
        guard let videoTrack = try? await sourceAsset.loadTracks(withMediaType: .video).first else {
            print("      ❌ No video track found")
            return false
        }
        
        // Create composition
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            print("      ❌ Failed to create composition track")
            return false
        }
        
        do {
            let duration = try await sourceAsset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try compositionTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        } catch {
            print("      ❌ Failed to insert time range: \(error)")
            return false
        }
        
        // Create video composition with crop and scale
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: cropRect.width, height: cropRect.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: compositionTrack.timeRange.duration)
        
        let transformer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        
        // Apply crop transform
        var transform = CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)
        
        // Apply flip if needed
        if isFlipped {
            transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1))
            transform = transform.concatenating(CGAffineTransform(translationX: cropRect.width, y: 0))
        }
        
        transformer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [transformer]
        videoComposition.instructions = [instruction]
        
        // Add audio track if present
        if let audioTrack = try? await sourceAsset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            do {
                let duration = try await sourceAsset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
                print("      🔊 Audio track added")
            } catch {
                print("      ⚠️  Failed to add audio: \(error)")
            }
        }
        
        // Export with appropriate preset for better compatibility
        // Use High quality instead of Highest to reduce encoding issues
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            print("      ❌ Failed to create export session")
            return false
        }
        
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = false
        
        // Set metadata to mark this as a wallpaper
        let metadataItem = AVMutableMetadataItem()
        metadataItem.identifier = .commonIdentifierDescription
        metadataItem.value = "SpreadPaper Wallpaper" as NSString
        metadataItem.extendedLanguageTag = "und"
        exportSession.metadata = [metadataItem]
        
        do {
            if #available(macOS 15.0, *) {
                // Use new API for macOS 15.0+
                try await exportSession.export(to: outputURL, as: .mov, isolation: .none)
                print("      ✅ Export completed successfully")
                return true
            } else {
                // Fallback for older macOS versions
                exportSession.outputURL = outputURL
                exportSession.outputFileType = .mov
                
                await exportSession.export()
                
                if exportSession.status == .completed {
                    print("      ✅ Export completed successfully")
                    return true
                } else {
                    print("      ❌ Export failed: \(exportSession.error?.localizedDescription ?? "Unknown error")")
                    return false
                }
            }
        } catch {
            print("      ❌ Export failed: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Apply Dynamic Wallpaper to Screens
    
    func applyDynamicWallpaper(
        sourceURL: URL,
        screens: [DisplayInfo],
        totalCanvas: CGRect,
        offset: CGSize,
        scale: CGFloat,
        previewScale: CGFloat,
        isFlipped: Bool,
        wallpapersDirectory: URL
    ) async -> Bool {
        // Extract screen information on the main actor before entering detached task
        struct ScreenData: @unchecked Sendable {
            let frame: CGRect
            let name: String
            let screen: NSScreen
        }
        
        let screenData: [ScreenData] = screens.map { display in
            ScreenData(
                frame: display.frame,
                name: display.screen.localizedName,
                screen: display.screen
            )
        }
        
        // Determine source type and obtain frames on current actor
        let ext = sourceURL.pathExtension.lowercased()
        let sourceFrames: [DynamicFrame]
        if ext == "mp4" || ext == "mov" {
            // Sample video frames at 1-second intervals
            do {
                sourceFrames = try await self.sampleVideoFrames(url: sourceURL, interval: CMTime(seconds: 1.0, preferredTimescale: 600))
            } catch {
                print("Failed to sample video frames from \(sourceURL): \(error)")
                return false
            }
        } else {
            sourceFrames = self.extractFrames(from: sourceURL)
        }
        
        guard !sourceFrames.isEmpty else {
            print("Failed to extract frames from \(sourceURL)")
            return false
        }
        
        // Capture frame data (image + metadata) before entering detached task
        // This ensures we don't access actor-isolated properties later
        let frameData: [(image: CGImage, metadata: NSDictionary)] = sourceFrames.map { frame in
            (image: frame.image, metadata: frame.metadata)
        }
        
        // Perform all heavy processing on a background queue with appropriate QoS
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return false }
            
            // For each screen, crop all frames and create a new HEIC
            for screenInfo in screenData {
                var croppedFrames: [DynamicFrame] = []
                
                for (sourceImage, sourceMetadata) in frameData {
                    guard let croppedImage = self.cropFrame(
                        sourceImage,
                        screenFrame: screenInfo.frame,
                        totalCanvas: totalCanvas,
                        offset: offset,
                        imageScale: scale,
                        previewScale: previewScale,
                        isFlipped: isFlipped
                    ) else {
                        print("Failed to crop frame for screen \(screenInfo.name)")
                        continue
                    }
                    
                    croppedFrames.append(DynamicFrame(
                        image: croppedImage,
                        metadata: sourceMetadata
                    ))
                }
                
                // Save as dynamic HEIC
                let screenName = self.sanitizeScreenName(screenInfo.name)
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let filename = "spreadpaper_wall_\(screenName)_\(timestamp).heic"
                let destinationURL = wallpapersDirectory.appendingPathComponent(filename)
                
                guard self.createDynamicHEIC(frames: croppedFrames, destinationURL: destinationURL) else {
                    print("Failed to create dynamic HEIC for screen \(screenInfo.name)")
                    continue
                }
                
                // Set as wallpaper on main actor since NSWorkspace should be called from main thread
                await MainActor.run {
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(destinationURL, for: screenInfo.screen, options: [:])
                    } catch {
                        print("Failed to set wallpaper for \(screenInfo.name): \(error)")
                    }
                }
            }
            
            return true
        }.value
    }
    
    // MARK: - Helpers
    
    private nonisolated func sanitizeScreenName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return name.unicodeScalars.filter { allowed.contains($0) }.map { String($0) }.joined()
    }
}

