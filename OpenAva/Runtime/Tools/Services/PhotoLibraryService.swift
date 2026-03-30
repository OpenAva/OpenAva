import Foundation
import OpenClawKit
import Photos
import UIKit

final class PhotoLibraryService: PhotosServicing {
    // Keep payloads below gateway transport limits to avoid websocket frame rejection.
    private static let maxTotalBytes = 255 * 1024
    private static let maxPerPhotoBytes = 225 * 1024

    func latest(params: OpenClawPhotosLatestParams) async throws -> PhotosLatestMediaPayload {
        let status = await Self.ensureAuthorization()
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Photos", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "PHOTOS_PERMISSION_REQUIRED: grant Photos permission",
            ])
        }

        let limit = max(1, min(params.limit ?? 1, 20))
        let fetchOptions = PHFetchOptions()
        fetchOptions.fetchLimit = limit
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        var results: [PhotoMediaPayload] = []
        var remainingBudget = Self.maxTotalBytes
        let maxWidth = params.maxWidth.flatMap { $0 > 0 ? $0 : nil } ?? 1600
        let quality = params.quality.map { max(0.1, min(1.0, $0)) } ?? 0.85
        let formatter = ISO8601DateFormatter()

        assets.enumerateObjects { asset, _, stop in
            if results.count >= limit { stop.pointee = true; return }
            if let payload = try? Self.renderAsset(
                asset,
                maxWidth: maxWidth,
                quality: quality,
                formatter: formatter
            ) {
                if payload.data.count > remainingBudget {
                    stop.pointee = true
                    return
                }
                remainingBudget -= payload.data.count
                results.append(payload)
            }
        }

        return PhotosLatestMediaPayload(photos: results)
    }

    private static func ensureAuthorization() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else {
            return status
        }

        // Request photo library permission before reading the latest assets.
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { updatedStatus in
                continuation.resume(returning: updatedStatus)
            }
        }
    }

    private static func renderAsset(
        _ asset: PHAsset,
        maxWidth: Int,
        quality: Double,
        formatter: ISO8601DateFormatter
    ) throws -> PhotoMediaPayload {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        let targetSize: CGSize = {
            guard maxWidth > 0 else { return PHImageManagerMaximumSize }
            let aspect = CGFloat(asset.pixelHeight) / CGFloat(max(1, asset.pixelWidth))
            let width = CGFloat(maxWidth)
            return CGSize(width: width, height: width * aspect)
        }()

        var image: UIImage?
        manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { result, _ in
            image = result
        }

        guard let image else {
            throw NSError(domain: "Photos", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "photo load failed",
            ])
        }

        let (data, finalImage) = try encodeJpegUnderBudget(
            image: image,
            quality: quality,
            maxBytes: maxPerPhotoBytes
        )

        let created = asset.creationDate.map { formatter.string(from: $0) }
        return PhotoMediaPayload(
            format: "jpeg",
            data: data,
            width: Int(finalImage.size.width),
            height: Int(finalImage.size.height),
            createdAt: created
        )
    }

    private static func encodeJpegUnderBudget(
        image: UIImage,
        quality: Double,
        maxBytes: Int
    ) throws -> (Data, UIImage) {
        var currentImage = image
        var currentQuality = max(0.1, min(1.0, quality))

        for _ in 0 ..< 10 {
            guard let data = currentImage.jpegData(compressionQuality: currentQuality) else {
                throw NSError(domain: "Photos", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "photo encode failed",
                ])
            }

            if data.count <= maxBytes {
                return (data, currentImage)
            }

            if currentQuality > 0.35 {
                currentQuality = max(0.25, currentQuality - 0.15)
                continue
            }

            let newWidth = max(240, currentImage.size.width * 0.75)
            if newWidth >= currentImage.size.width {
                break
            }
            currentImage = resize(image: currentImage, targetWidth: newWidth)
        }

        throw NSError(domain: "Photos", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "photo too large for gateway transport; try smaller maxWidth/quality",
        ])
    }

    private static func resize(image: UIImage, targetWidth: CGFloat) -> UIImage {
        let size = image.size
        if size.width <= 0 || size.height <= 0 || targetWidth <= 0 {
            return image
        }
        let scale = targetWidth / size.width
        let targetSize = CGSize(width: targetWidth, height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
