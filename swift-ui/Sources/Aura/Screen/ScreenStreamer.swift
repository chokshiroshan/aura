import Foundation
import CoreGraphics
import ImageIO
import AppKit

/// Continuous screen capture at 1-2fps for live vision streaming.
///
/// This is Aura's key differentiator — because tokens are unlimited
/// via Codex OAuth, we can push frames to the vision model continuously.
/// Nobody else can afford this.
///
/// Frames are saved as temp PNGs and fed into Codex turns as LocalImage inputs.
final class ScreenStreamer {
    
    var onFrame: ((URL) -> Void)?
    
    private let maxImageWidth: CGFloat = 1024  // Balance quality vs bandwidth
    private var timer: Timer?
    private var fps: Double = 1.0  // 1 frame per second
    private let tempDir: URL
    private var frameCount = 0
    
    init() {
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-frames")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    // MARK: - Control
    
    func start(fps: Double = 1.0) {
        stop()
        self.fps = max(0.5, min(fps, 3.0))  // Clamp 0.5–3 fps
        
        print("👁️ Screen streaming started at \(self.fps) fps")
        
        // Capture first frame immediately
        captureAndEmit()
        
        timer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / self.fps,
            repeats: true
        ) { [weak self] _ in
            self?.captureAndEmit()
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        print("👁️ Screen streaming stopped (\(frameCount) frames captured)")
        frameCount = 0
    }
    
    /// Capture a single frame on-demand
    func captureNow() -> URL? {
        guard let image = captureScreen() else { return nil }
        return saveFrame(image)
    }
    
    // MARK: - Private
    
    private func captureAndEmit() {
        guard let image = captureScreen() else { return }
        guard let url = saveFrame(image) else { return }
        frameCount += 1
        onFrame?(url)
    }
    
    private func captureScreen() -> CGImage? {
        guard let screen = NSScreen.screenWithMouse ?? NSScreen.main else { return nil }
        
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
            return nil
        }
        
        return CGDisplayCreateImage(displayID, rect: screen.frame)
    }
    
    private func saveFrame(_ image: CGImage) -> URL? {
        let resized = downscale(image)
        
        let filename = "frame_\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let url = tempDir.appendingPathComponent(filename)
        
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, resized, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        
        do {
            try (data as Data).write(to: url)
            return url
        } catch {
            return nil
        }
    }
    
    private func downscale(_ image: CGImage) -> CGImage {
        let srcWidth = CGFloat(image.width)
        let srcHeight = CGFloat(image.height)
        
        let scale = min(maxImageWidth / srcWidth, 1.0)
        let newWidth = Int(srcWidth * scale)
        let newHeight = Int(srcHeight * scale)
        
        guard let ctx = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        
        ctx.interpolationQuality = .medium  // Fast enough for streaming
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return ctx.makeImage() ?? image
    }
    
    /// Clean old frames to prevent disk buildup
    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
}

// MARK: - NSScreen Helper

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
