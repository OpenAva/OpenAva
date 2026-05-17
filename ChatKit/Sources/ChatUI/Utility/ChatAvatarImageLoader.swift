import Foundation
import UIKit

public enum ChatAvatarImageLoader {
    private nonisolated(unsafe) static let imageCache = NSCache<NSURL, UIImage>()

    public static func image(for url: URL) -> UIImage? {
        if let cached = imageCache.object(forKey: url as NSURL) {
            return cached
        }

        guard url.isFileURL,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)
        else {
            return nil
        }
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    @discardableResult
    public static func loadImage(from url: URL, completion: @escaping @MainActor (UIImage?) -> Void) -> URLSessionDataTask? {
        if let image = image(for: url) {
            Task { @MainActor in
                completion(image)
            }
            return nil
        }

        guard !url.isFileURL else {
            Task { @MainActor in
                completion(nil)
            }
            return nil
        }

        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(UIImage.init(data:))
            if let image {
                imageCache.setObject(image, forKey: url as NSURL)
            }
            Task { @MainActor in
                completion(image)
            }
        }
        task.resume()
        return task
    }
}
