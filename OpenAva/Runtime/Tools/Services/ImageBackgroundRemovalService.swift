import CoreImage
import Foundation
import OpenClawKit
import Vision

final class ImageBackgroundRemovalService {
    func removeBackground(
        params: OpenClawImageRemoveBackgroundParams,
        fileSystemService: FileSystemService
    ) async throws -> OpenClawImageRemoveBackgroundPayload {
        guard #available(iOS 17.0, *) else {
            throw NSError(domain: "ImageBackgroundRemoval", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "UNAVAILABLE: foreground masking requires iOS 17 or later",
            ])
        }

        let inputMetadata = try await fileSystemService.pathMetadata(path: params.inputPath)
        let inputData = try await fileSystemService.readData(path: params.inputPath)
        let outputPath = Self.defaultOutputPath(
            fromResolvedInputPath: inputMetadata.resolvedPath,
            requestedOutputPath: params.outputPath
        )

        let rendered = try await Task.detached(priority: .userInitiated) {
            try Self.renderForegroundOnlyPNG(from: inputData)
        }.value

        let writeResult = try await fileSystemService.writeData(path: outputPath, data: rendered.pngData)
        let outputMetadata = try await fileSystemService.pathMetadata(path: outputPath)

        return OpenClawImageRemoveBackgroundPayload(
            inputPath: inputMetadata.resolvedPath,
            outputPath: outputMetadata.resolvedPath,
            format: "png",
            width: rendered.width,
            height: rendered.height,
            bytes: writeResult.size
        )
    }

    private static func defaultOutputPath(
        fromResolvedInputPath inputPath: String,
        requestedOutputPath: String?
    ) -> String {
        if let requestedOutputPath {
            let trimmed = requestedOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let outputName = inputURL.deletingPathExtension().lastPathComponent + "-nobg.png"
        return inputURL.deletingLastPathComponent().appendingPathComponent(outputName).path
    }

    @available(iOS 17.0, *)
    private static func renderForegroundOnlyPNG(from inputData: Data) throws -> (pngData: Data, width: Int, height: Int) {
        guard let sourceImage = CIImage(data: inputData, options: [.applyOrientationProperty: true]) else {
            throw NSError(domain: "ImageBackgroundRemoval", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "INVALID_IMAGE: failed to decode input image",
            ])
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: sourceImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            throw NSError(domain: "ImageBackgroundRemoval", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "NO_SUBJECT_FOUND: could not detect a foreground subject",
            ])
        }

        let subjectInstances = observation.allInstances
        guard !subjectInstances.isEmpty else {
            throw NSError(domain: "ImageBackgroundRemoval", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "NO_SUBJECT_FOUND: could not detect a foreground subject",
            ])
        }

        // Scale the Vision mask back to image resolution before compositing transparency.
        let maskBuffer = try observation.generateScaledMaskForImage(forInstances: subjectInstances, from: handler)
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        let transparentBackground = CIImage(color: .clear).cropped(to: sourceImage.extent)
        let composited = sourceImage
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputMaskImageKey: maskImage,
                kCIInputBackgroundImageKey: transparentBackground,
            ])
            .cropped(to: sourceImage.extent)

        let context = CIContext(options: nil)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let pngData = context.pngRepresentation(of: composited, format: .RGBA8, colorSpace: colorSpace) else {
            throw NSError(domain: "ImageBackgroundRemoval", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "PNG_ENCODE_FAILED: failed to encode background-removed image",
            ])
        }

        return (
            pngData,
            Int(composited.extent.width.rounded()),
            Int(composited.extent.height.rounded())
        )
    }
}
