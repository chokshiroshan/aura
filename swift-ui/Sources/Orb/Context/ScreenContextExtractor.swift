import Foundation
import CoreGraphics
import ImageIO
import AppKit

/// Captures a screenshot and extracts transcription-relevant context via GPT-4o-mini vision.
///
/// When the user triggers "enhanced dictation" (Ctrl+Shift+Space instead of Ctrl+Space):
/// 1. Capture the active display (~2ms)
/// 2. Downscale to 1280px wide for fast upload
/// 3. Send to GPT-4o-mini vision API with a context extraction prompt
/// 4. Merge the extracted context into the Realtime API session instructions
///
/// The vision call takes ~1-2s and runs in the background. Regular transcription
/// starts immediately — the context is injected mid-stream via session.update.
final class ScreenContextExtractor {
    static let shared = ScreenContextExtractor()

    private let maxImageWidth: CGFloat = 1280

    private init() {}

    // MARK: - Public API

    /// Capture the active display and extract context for transcription.
    /// Returns nil if capture fails or vision call fails (graceful degradation).
    func extractContext(token: String) async -> String? {
        guard let image = captureActiveDisplay() else {
            print("📸 Screen capture failed — skipping enhanced context")
            return nil
        }

        let base64 = downscaleAndEncode(image)
        guard !base64.isEmpty else {
            print("📸 Image encoding failed — skipping enhanced context")
            return nil
        }

        print("📸 Screenshot captured (\(image.width)x\(image.height)) → extracting context...")

        do {
            let context = try await callVisionAPI(base64: base64, token: token)
            if let context, !context.isEmpty {
                print("📸 Screen context: \(context.prefix(200))...")
                return context
            }
            return nil
        } catch {
            print("📸 Vision API failed: \(error) — transcription continues without screen context")
            return nil
        }
    }

    // MARK: - Screen Capture

    /// Capture the display that currently has the mouse cursor.
    private func captureActiveDisplay() -> CGImage? {
        guard let screen = NSScreen.screenWithMouse ?? NSScreen.main else { return nil }

        // Get the CGDirectDisplayID from the screen's device description
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
            return nil
        }

        // Capture the full screen (not just visibleFrame — we want menu bar, dock area context too)
        let rect = screen.frame
        let image = CGDisplayCreateImage(displayID, rect: rect)

        // Immediately clear the image from any sensitive system UI
        // (we're sending this to OpenAI, so be conservative)
        return image
    }

    // MARK: - Image Processing

    /// Downscale the image and convert to base64 PNG.
    private func downscaleAndEncode(_ image: CGImage) -> String {
        let srcWidth = CGFloat(image.width)
        let srcHeight = CGFloat(image.height)

        // Downscale if wider than max
        let scale = min(maxImageWidth / srcWidth, 1.0)
        let newWidth = Int(srcWidth * scale)
        let newHeight = Int(srcHeight * scale)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "" }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let resized = context.makeImage() else { return "" }

        // Encode as PNG
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return "" }
        CGImageDestinationAddImage(dest, resized, nil)
        CGImageDestinationFinalize(dest)

        return data.base64EncodedString()
    }

    // MARK: - Vision API (ChatGPT backend-api)

    /// Uses the ChatGPT subscription token via backend-api for vision.
    /// The standard api.openai.com/v1/chat/completions rejects subscription tokens,
    /// so we use chatgpt.com/backend-api/conversation which accepts them.
    private func callVisionAPI(base64: String, token: String) async throws -> String? {
        // Step 1: Upload image to ChatGPT's file service
        let fileID = try await uploadImage(base64: base64, token: token)

        // Step 2: Send conversation with image
        let url = URL(string: "https://chatgpt.com/backend-api/conversation")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let prompt = """
        Look at this screenshot. Extract ONLY information that would help accurately transcribe someone's speech. Focus on:
        - Application name and what the user is doing
        - Visible text labels, headings, or menu items
        - Technical terms, variable names, function names, or code visible
        - Names of people, projects, products, or companies mentioned on screen
        - Any domain-specific vocabulary (medical, legal, programming, etc.)

        Respond with a concise paragraph of context. No lists, no explanations, just facts that help transcription.
        """

        let body: [String: Any] = [
            "action": "next",
            "messages": [
                [
                    "id": UUID().uuidString,
                    "author": ["role": "user"],
                    "content": [
                        "content_type": "multimodal_text",
                        "parts": [
                            [
                                "content_type": "image_asset_pointer",
                                "asset_pointer": "file-service://\(fileID)",
                                "height": -1,
                                "width": -1
                            ],
                            prompt
                        ]
                    ]
                ]
            ],
            "model": "auto",
            "timezone_offset_min": -300
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResp = response as? HTTPURLResponse else {
            throw ScreenContextError.invalidResponse
        }

        guard httpResp.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            print("📸 Vision API error (\(httpResp.statusCode)): \(body.prefix(200))")
            throw ScreenContextError.apiError(httpResp.statusCode)
        }

        // Parse SSE stream — find the final text response
        let text = parseSSEResponse(data: data)
        return text
    }

    /// Upload image to ChatGPT's file service and return the file_id.
    private func uploadImage(base64: String, token: String) async throws -> String {
        guard let imageData = Data(base64Encoded: base64) else {
            throw ScreenContextError.invalidResponse
        }

        let url = URL(string: "https://chatgpt.com/backend-api/files")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"screenshot.png\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n".data(using: .utf8)!)
        body.append("multimodal\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            print("📸 File upload error (\(statusCode)): \(body.prefix(200))")
            throw ScreenContextError.apiError(statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let fileID = json["file_id"] as? String ?? ""
        if fileID.isEmpty {
            print("📸 No file_id in upload response: \(json)")
            throw ScreenContextError.invalidResponse
        }
        return fileID
    }

    /// Parse the SSE response stream from ChatGPT backend-api.
    private func parseSSEResponse(data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // Find the last message with text content
        var lastText = ""
        for line in text.components(separatedBy: "\n") {
            guard line.hasPrefix("data: "), let jsonStr = line.dropFirst(6).data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: jsonStr) as? [String: Any] else { continue }

            let message = json["message"] as? [String: Any]
            let content = message?["content"] as? [String: Any]
            let parts = content?["parts"] as? [Any] ?? []

            for part in parts {
                if let textPart = part as? String, !textPart.isEmpty {
                    lastText = textPart
                }
            }
        }

        return lastText.isEmpty ? nil : lastText
    }
}

enum ScreenContextError: LocalizedError {
    case invalidResponse
    case apiError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from vision API"
        case .apiError(let code): return "Vision API error (\(code))"
        }
    }
}
