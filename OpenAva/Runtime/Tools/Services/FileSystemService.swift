import Foundation

/// File system service for reading and writing files
actor FileSystemService {
    private let fileManager = FileManager.default
    private let maxFileSize: Int
    private let maxReadChars: Int
    private let writableBaseDirectoryURL: URL?
    private let readableRootURLs: [URL]

    init(
        baseDirectoryURL: URL? = nil,
        additionalReadableRootURLs: [URL] = [],
        maxFileSize: Int = 10_000_000,
        maxReadChars: Int = 128_000
    ) { // 10MB default
        let standardizedBaseDirectoryURL = baseDirectoryURL?.standardizedFileURL
        writableBaseDirectoryURL = standardizedBaseDirectoryURL

        // Keep workspace writable, and optionally add read-only roots such as bundled Skills.
        var allReadableRoots: [URL] = []
        if let standardizedBaseDirectoryURL {
            allReadableRoots.append(standardizedBaseDirectoryURL)
        }
        for candidate in additionalReadableRootURLs.map(\.standardizedFileURL) {
            if allReadableRoots.contains(where: { $0.path == candidate.path }) {
                continue
            }
            allReadableRoots.append(candidate)
        }
        readableRootURLs = allReadableRoots
        self.maxFileSize = maxFileSize
        self.maxReadChars = maxReadChars
    }

    /// Read file content with optional line range
    func readFile(path: String, startLine: Int? = nil, endLine: Int? = nil) async throws -> FileReadResult {
        let url = try resolveReadablePath(path)

        // Check file exists
        guard fileManager.fileExists(atPath: url.path) else {
            throw FileSystemError.fileNotFound(path: path)
        }

        // Check file size
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int else {
            throw FileSystemError.cannotReadFile(path: path)
        }

        guard fileSize <= maxFileSize else {
            throw FileSystemError.fileTooLarge(path: path, size: fileSize, maxSize: maxFileSize)
        }

        // Read file content
        let data = try Data(contentsOf: url)
        guard var content = String(data: data, encoding: .utf8) else {
            throw FileSystemError.invalidEncoding(path: path)
        }

        // Apply line range if specified
        var actualStartLine = 0
        var actualEndLine = 0
        var message = "Read \(path)"
        if let start = startLine, let end = endLine {
            let lines = content.components(separatedBy: .newlines)
            let totalLines = lines.count

            // Tool API line numbers are 1-based for user-friendly usage.
            guard start >= 1, start <= totalLines else {
                throw FileSystemError.invalidLineNumber(line: start, maxLine: totalLines)
            }
            guard end >= start, end <= totalLines else {
                throw FileSystemError.invalidLineNumber(line: end, maxLine: totalLines)
            }

            let selectedLines = Array(lines[(start - 1) ... (end - 1)])
            content = selectedLines.joined(separator: "\n")
            actualStartLine = start
            actualEndLine = end
            message = "Read \(path) (lines \(start)-\(end))"
        }

        let totalChars = content.count
        var truncated = false
        if totalChars > maxReadChars {
            content = String(content.prefix(maxReadChars))
            truncated = true
            message += " (truncated to \(maxReadChars) chars)"
        }

        return FileReadResult(
            path: path,
            content: content,
            size: fileSize,
            encoding: "utf-8",
            startLine: startLine != nil ? actualStartLine : nil,
            endLine: endLine != nil ? actualEndLine : nil,
            truncated: truncated,
            totalChars: totalChars,
            message: message
        )
    }

    /// Write file content
    func writeFile(path: String, content: String, createDirectories: Bool = true) async throws -> FileWriteResult {
        let url = try resolveWritablePath(path)
        let fileExists = fileManager.fileExists(atPath: url.path)

        // Create parent directories if needed
        if createDirectories {
            let parentDir = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
        }

        // Write content
        guard let data = content.data(using: .utf8) else {
            throw FileSystemError.invalidEncoding(path: path)
        }

        try data.write(to: url, options: .atomic)

        let action = fileExists ? "Updated" : "Created"
        let message = "\(action) \(path)"

        return FileWriteResult(
            path: path,
            size: data.count,
            created: !fileExists,
            message: message
        )
    }

    /// Read raw file bytes for binary-safe operations such as image processing.
    func readData(path: String) async throws -> Data {
        let url = try resolveReadablePath(path)

        guard fileManager.fileExists(atPath: url.path) else {
            throw FileSystemError.fileNotFound(path: path)
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int else {
            throw FileSystemError.cannotReadFile(path: path)
        }

        guard fileSize <= maxFileSize else {
            throw FileSystemError.fileTooLarge(path: path, size: fileSize, maxSize: maxFileSize)
        }

        return try Data(contentsOf: url)
    }

    /// Write raw file bytes while preserving the same workspace access rules as text writes.
    func writeData(path: String, data: Data, createDirectories: Bool = true) async throws -> FileWriteResult {
        let url = try resolveWritablePath(path)
        let fileExists = fileManager.fileExists(atPath: url.path)

        if createDirectories {
            let parentDir = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
        }

        try data.write(to: url, options: .atomic)

        let action = fileExists ? "Updated" : "Created"
        let message = "\(action) \(path)"

        return FileWriteResult(
            path: path,
            size: data.count,
            created: !fileExists,
            message: message
        )
    }

    /// Replace text in file (string replacement)
    func replaceInFile(path: String, oldText: String, newText: String) async throws -> FileReplaceResult {
        let fileResult = try await readFile(path: path)

        // Find and replace
        guard fileResult.content.contains(oldText) else {
            throw FileSystemError.textNotFound(text: oldText)
        }

        let newContent = fileResult.content.replacingOccurrences(of: oldText, with: newText)
        let occurrences = fileResult.content.components(separatedBy: oldText).count - 1

        // Write back
        let writeResult = try await writeFile(path: path, content: newContent, createDirectories: false)

        let message = "Replaced \(occurrences) occurrence\(occurrences == 1 ? "" : "s") in \(path)"

        return FileReplaceResult(
            path: path,
            occurrences: occurrences,
            oldLength: oldText.count,
            newLength: newText.count,
            size: writeResult.size,
            message: message
        )
    }

    /// Append content to file
    func appendToFile(path: String, content: String) async throws -> FileAppendResult {
        let url = try resolveWritablePath(path)

        // Create parent directory and file on demand to match tool contract.
        let parentDir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let existingContent: String
        if fileManager.fileExists(atPath: url.path) {
            let existingData = try Data(contentsOf: url)
            guard let decoded = String(data: existingData, encoding: .utf8) else {
                throw FileSystemError.invalidEncoding(path: path)
            }
            existingContent = decoded
        } else {
            existingContent = ""
        }

        // Append new content
        let newContent = existingContent + content
        guard let newData = newContent.data(using: .utf8) else {
            throw FileSystemError.invalidEncoding(path: path)
        }

        try newData.write(to: url, options: .atomic)

        let message = "Appended to \(path)"

        return FileAppendResult(
            path: path,
            appendedSize: content.count,
            totalSize: newData.count,
            message: message
        )
    }

    /// List directory contents
    func listDirectory(path: String) async throws -> DirectoryListResult {
        let url = try resolveReadablePath(path)

        guard fileManager.fileExists(atPath: url.path) else {
            throw FileSystemError.directoryNotFound(path: path)
        }

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        let items = try contents.map { itemURL -> DirectoryItem in
            let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = resourceValues.isDirectory ?? false
            let size = resourceValues.fileSize

            return DirectoryItem(
                name: itemURL.lastPathComponent,
                path: itemURL.path,
                isDirectory: isDirectory,
                size: size
            )
        }
        // Keep directory listings stable and easy to scan.
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        // Generate human-readable message
        let message: String
        if items.isEmpty {
            message = "Directory is empty"
        } else {
            let fileCount = items.filter { !$0.isDirectory }.count
            let dirCount = items.filter(\.isDirectory).count
            var parts: [String] = []
            if dirCount > 0 {
                parts.append("\(dirCount) folder\(dirCount == 1 ? "" : "s")")
            }
            if fileCount > 0 {
                parts.append("\(fileCount) file\(fileCount == 1 ? "" : "s")")
            }
            message = "Found \(parts.joined(separator: ", "))"
        }

        return DirectoryListResult(
            path: path,
            items: items,
            count: items.count,
            message: message
        )
    }

    /// Create a directory.
    func makeDirectory(path: String, recursive: Bool = true, ifNotExists: Bool = true) async throws -> DirectoryCreateResult {
        let url = try resolveWritablePath(path)
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                if ifNotExists {
                    return DirectoryCreateResult(path: path, created: false, message: "Directory already exists: \(path)")
                }
                throw FileSystemError.directoryAlreadyExists(path: path)
            }
            throw FileSystemError.pathExistsAsFile(path: path)
        }

        try fileManager.createDirectory(at: url, withIntermediateDirectories: recursive)
        return DirectoryCreateResult(path: path, created: true, message: "Created directory \(path)")
    }

    /// Delete file or directory
    func delete(path: String) async throws -> FileDeleteResult {
        let url = try resolveWritablePath(path)

        guard fileManager.fileExists(atPath: url.path) else {
            throw FileSystemError.fileNotFound(path: path)
        }

        try fileManager.removeItem(at: url)

        let message = "Deleted \(path)"

        return FileDeleteResult(
            path: path,
            deleted: true,
            message: message
        )
    }

    /// Find files matching a glob pattern under `path`.
    /// Supports path-aware glob patterns such as `**`, `[]`, and `{a,b}`.
    func findFiles(glob: String, path: String = ".", recursive: Bool = true) async throws -> FindFilesResult {
        let rootURL = try resolveReadablePath(path)
        let matcher = try makeGlobMatcher(glob)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw FileSystemError.directoryNotFound(path: path)
        }

        var found: [DirectoryItem] = []

        if !isDirectory.boolValue {
            let parentURL = rootURL.deletingLastPathComponent()
            if matcher.matches(itemURL: rootURL, relativeTo: parentURL) {
                let resourceValues = try rootURL.resourceValues(forKeys: [.fileSizeKey])
                found.append(
                    DirectoryItem(
                        name: rootURL.lastPathComponent,
                        path: rootURL.path,
                        isDirectory: false,
                        size: resourceValues.fileSize
                    )
                )
            }
        } else {
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
            if !recursive {
                options.insert(.skipsSubdirectoryDescendants)
            }

            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: options
            ) else {
                throw FileSystemError.directoryNotFound(path: path)
            }

            for case let itemURL as URL in enumerator {
                let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = resourceValues.isDirectory ?? false
                if isDirectory { continue }

                if matcher.matches(itemURL: itemURL, relativeTo: rootURL) {
                    found.append(
                        DirectoryItem(
                            name: itemURL.lastPathComponent,
                            path: itemURL.path,
                            isDirectory: false,
                            size: resourceValues.fileSize
                        )
                    )
                }
            }
        }

        found.sort { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }

        let message = found.isEmpty
            ? "No files matching '\(glob)'"
            : "Found \(found.count) file\(found.count == 1 ? "" : "s") matching '\(glob)'"

        return FindFilesResult(
            path: path,
            pattern: glob,
            items: found,
            count: found.count,
            message: message
        )
    }

    /// Search file contents for a pattern (grep-like).
    /// If `isRegex` is false the pattern is treated as a literal string.
    /// Returns per-line matches with line numbers.
    func grep(pattern: String, path: String = ".", recursive: Bool = true, isRegex: Bool = true, caseInsensitive: Bool = true) async throws -> SearchResults {
        let rootURL = try resolveReadablePath(path)

        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: options
        ) else {
            throw FileSystemError.directoryNotFound(path: path)
        }

        let regex: NSRegularExpression
        if isRegex {
            var opts: NSRegularExpression.Options = []
            if caseInsensitive { opts.insert(.caseInsensitive) }
            regex = try NSRegularExpression(pattern: pattern, options: opts)
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            var opts: NSRegularExpression.Options = []
            if caseInsensitive { opts.insert(.caseInsensitive) }
            regex = try NSRegularExpression(pattern: escaped, options: opts)
        }

        var matches: [FindMatch] = []

        for case let itemURL as URL in enumerator {
            let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if resourceValues.isDirectory == true { continue }

            if let size = resourceValues.fileSize, size > maxFileSize { continue }

            let data = try Data(contentsOf: itemURL)
            guard let content = String(data: data, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let nsRange = NSRange(location: 0, length: line.utf16.count)
                if regex.firstMatch(in: line, options: [], range: nsRange) != nil {
                    matches.append(FindMatch(path: itemURL.path, lineNumber: index + 1, line: line))
                }
            }
        }

        let message = matches.isEmpty
            ? "No matches for '\(pattern)'"
            : "Found \(matches.count) match\(matches.count == 1 ? "" : "es") for '\(pattern)'"

        return SearchResults(
            pattern: pattern,
            matches: matches,
            count: matches.count,
            message: message
        )
    }

    /// Resolve user input path to canonical metadata for tool responses.
    func pathMetadata(path: String) throws -> FilePathMetadata {
        let resolvedURL = try resolveReadablePath(path)
        let baseURL = try matchedReadableRoot(for: resolvedURL)
        return FilePathMetadata(
            inputPath: path,
            resolvedPath: resolvedURL.standardized.path,
            baseDir: baseURL.standardized.path
        )
    }

    /// Resolve and validate a path for read-only operations.
    private func resolveReadablePath(_ path: String) throws -> URL {
        let workspaceURL = try writableWorkspaceDirectoryURL().standardizedFileURL
        let resolvedWorkspaceURL = resolveSymlinkAwarePath(workspaceURL)

        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let resolvedURL = resolveSymlinkAwarePath(url)
            guard (isWithinReadableRoots(url) || isPathWithinRoot(url, root: workspaceURL))
                && (isWithinReadableRoots(resolvedURL, resolveSymlinks: true) || isPathWithinRoot(resolvedURL, root: resolvedWorkspaceURL))
            else {
                throw FileSystemError.accessDenied(path: path)
            }
            return url
        }

        let url = workspaceURL.appendingPathComponent(path).standardizedFileURL
        let resolvedURL = resolveSymlinkAwarePath(url)
        guard (isWithinReadableRoots(url) || isPathWithinRoot(url, root: workspaceURL))
            && (isWithinReadableRoots(resolvedURL, resolveSymlinks: true) || isPathWithinRoot(resolvedURL, root: resolvedWorkspaceURL))
        else {
            throw FileSystemError.accessDenied(path: path)
        }
        return url
    }

    /// Resolve and validate a path for write operations.
    private func resolveWritablePath(_ path: String) throws -> URL {
        let workspaceURL = try writableWorkspaceDirectoryURL().standardizedFileURL
        let resolvedWorkspaceURL = resolveSymlinkAwarePath(workspaceURL)

        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            url = workspaceURL.appendingPathComponent(path).standardizedFileURL
        }

        guard isPathWithinRoot(url, root: workspaceURL) else {
            throw FileSystemError.accessDenied(path: path)
        }

        let resolvedURL = resolveSymlinkAwarePath(url)
        guard isPathWithinRoot(resolvedURL, root: resolvedWorkspaceURL) else {
            throw FileSystemError.accessDenied(path: path)
        }

        return url
    }

    private func writableWorkspaceDirectoryURL() throws -> URL {
        if let writableBaseDirectoryURL {
            return writableBaseDirectoryURL
        }

        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw FileSystemError.invalidPath(path: "workspace")
        }
        return documentsURL
    }

    private func matchedReadableRoot(for url: URL) throws -> URL {
        let normalizedURL = url.standardizedFileURL
        if let matched = readableRootURLs.first(where: { isPathWithinRoot(normalizedURL, root: $0.standardizedFileURL) }) {
            return matched
        }
        let workspaceURL = try writableWorkspaceDirectoryURL().standardizedFileURL
        if isPathWithinRoot(normalizedURL, root: workspaceURL) {
            return workspaceURL
        }
        throw FileSystemError.accessDenied(path: normalizedURL.path)
    }

    private func isWithinReadableRoots(_ url: URL, resolveSymlinks: Bool = false) -> Bool {
        let normalizedURL = resolveSymlinks ? resolveSymlinkAwarePath(url) : url.standardizedFileURL
        return readableRootURLs.contains { rootURL in
            let normalizedRootURL = resolveSymlinks ? resolveSymlinkAwarePath(rootURL) : rootURL.standardizedFileURL
            return isPathWithinRoot(normalizedURL, root: normalizedRootURL)
        }
    }

    private func resolveSymlinkAwarePath(_ url: URL) -> URL {
        var existingURL = url.standardizedFileURL
        var trailingComponents: [String] = []

        while !fileManager.fileExists(atPath: existingURL.path), existingURL.path != "/" {
            trailingComponents.insert(existingURL.lastPathComponent, at: 0)
            existingURL = existingURL.deletingLastPathComponent().standardizedFileURL
        }

        var resolvedURL = existingURL.resolvingSymlinksInPath().standardizedFileURL
        for component in trailingComponents {
            resolvedURL.appendPathComponent(component)
        }
        return resolvedURL.standardizedFileURL
    }

    private func isPathWithinRoot(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return zip(candidateComponents, rootComponents).allSatisfy { $0 == $1 }
    }

    /// Compile a glob matcher that can match either basenames or root-relative paths.
    private func makeGlobMatcher(_ glob: String) throws -> GlobMatcher {
        let normalized = normalizeGlobPattern(glob)
        let expandedPatterns = expandBraces(in: normalized)
        let compiledPatterns = try expandedPatterns.map { pattern in
            try CompiledGlobPattern(pattern: normalizeGlobPattern(pattern))
        }
        return GlobMatcher(patterns: compiledPatterns)
    }

    private func normalizeGlobPattern(_ glob: String) -> String {
        var normalized = glob.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        return normalized
    }

    /// Expand simple brace groups so patterns like `*.{swift,md}` behave as expected.
    private func expandBraces(in pattern: String) -> [String] {
        guard let braceRange = firstBraceRange(in: pattern) else {
            return [pattern]
        }

        let prefix = String(pattern[..<braceRange.lowerBound])
        let suffixStart = pattern.index(after: braceRange.upperBound)
        let suffix = String(pattern[suffixStart...])
        let inner = String(pattern[pattern.index(after: braceRange.lowerBound) ..< braceRange.upperBound])
        let options = splitBraceOptions(inner)
        guard options.count > 1 else {
            return [pattern]
        }

        return options.flatMap { option in
            expandBraces(in: prefix + option + suffix)
        }
    }

    private func firstBraceRange(in pattern: String) -> ClosedRange<String.Index>? {
        var depth = 0
        var startIndex: String.Index?
        var sawSeparator = false

        for index in pattern.indices {
            let character = pattern[index]
            switch character {
            case "{":
                if depth == 0 {
                    startIndex = index
                    sawSeparator = false
                }
                depth += 1
            case ",":
                if depth == 1 {
                    sawSeparator = true
                }
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let startIndex, sawSeparator {
                    return startIndex ... index
                }
            default:
                continue
            }
        }

        return nil
    }

    private func splitBraceOptions(_ input: String) -> [String] {
        var options: [String] = []
        var current = ""
        var depth = 0

        for character in input {
            switch character {
            case "{":
                depth += 1
                current.append(character)
            case "}":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                options.append(current)
                current.removeAll(keepingCapacity: true)
            default:
                current.append(character)
            }
        }

        options.append(current)
        return options
    }

    private struct GlobMatcher {
        let patterns: [CompiledGlobPattern]

        func matches(itemURL: URL, relativeTo rootURL: URL) -> Bool {
            let relativePath = normalizeRelativePath(for: itemURL, rootURL: rootURL)
            let basename = itemURL.lastPathComponent
            return patterns.contains { $0.matches(relativePath: relativePath, basename: basename) }
        }

        private func normalizeRelativePath(for itemURL: URL, rootURL: URL) -> String {
            let itemPath = itemURL.standardizedFileURL.path
            let rootPath = rootURL.standardizedFileURL.path

            guard itemPath.hasPrefix(rootPath) else {
                return itemURL.lastPathComponent
            }

            var relativePath = String(itemPath.dropFirst(rootPath.count))
            if relativePath.hasPrefix("/") {
                relativePath.removeFirst()
            }
            return relativePath.replacingOccurrences(of: "\\", with: "/")
        }
    }

    private struct CompiledGlobPattern {
        let matchesRelativePath: Bool
        let basenameRegex: NSRegularExpression?
        private let pathSegments: [PathSegment]

        init(pattern: String) throws {
            matchesRelativePath = pattern.contains("/")
            if matchesRelativePath {
                basenameRegex = nil
                pathSegments = try pattern
                    .split(separator: "/", omittingEmptySubsequences: false)
                    .map { try PathSegment(token: String($0)) }
            } else {
                basenameRegex = try Self.makeSegmentRegex(pattern)
                pathSegments = []
            }
        }

        func matches(relativePath: String, basename: String) -> Bool {
            if let basenameRegex {
                return Self.matchesSegment(basename, with: basenameRegex)
            }

            let segments = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var memo: [MatchState: Bool] = [:]
            return matchPath(patternIndex: 0, pathIndex: 0, pathSegments: segments, memo: &memo)
        }

        private func matchPath(
            patternIndex: Int,
            pathIndex: Int,
            pathSegments: [String],
            memo: inout [MatchState: Bool]
        ) -> Bool {
            let state = MatchState(patternIndex: patternIndex, pathIndex: pathIndex)
            if let cached = memo[state] {
                return cached
            }

            let result: Bool
            if patternIndex == pathSegmentsCount {
                result = pathIndex == pathSegments.count
            } else {
                switch pathSegmentsPattern[patternIndex] {
                case .recursiveWildcard:
                    if patternIndex == pathSegmentsCount - 1 {
                        result = true
                    } else {
                        result = (pathIndex ... pathSegments.count).contains { candidateIndex in
                            matchPath(
                                patternIndex: patternIndex + 1,
                                pathIndex: candidateIndex,
                                pathSegments: pathSegments,
                                memo: &memo
                            )
                        }
                    }
                case let .segment(regex):
                    guard pathIndex < pathSegments.count else {
                        result = false
                        memo[state] = result
                        return result
                    }
                    result = Self.matchesSegment(pathSegments[pathIndex], with: regex)
                        && matchPath(
                            patternIndex: patternIndex + 1,
                            pathIndex: pathIndex + 1,
                            pathSegments: pathSegments,
                            memo: &memo
                        )
                }
            }

            memo[state] = result
            return result
        }

        private static func makeSegmentRegex(_ segmentPattern: String) throws -> NSRegularExpression {
            try NSRegularExpression(
                pattern: "^" + makeRegexSource(for: segmentPattern) + "$",
                options: .caseInsensitive
            )
        }

        private static func makeRegexSource(for segmentPattern: String) -> String {
            var regex = ""
            let characters = Array(segmentPattern)
            var index = 0

            while index < characters.count {
                let character = characters[index]
                switch character {
                case "*":
                    regex += "[^/]*"
                case "?":
                    regex += "[^/]"
                case "[":
                    if let (characterClass, nextIndex) = makeCharacterClass(from: characters, startIndex: index) {
                        regex += characterClass
                        index = nextIndex
                    } else {
                        regex += "\\["
                    }
                default:
                    regex += NSRegularExpression.escapedPattern(for: String(character))
                }
                index += 1
            }

            return regex
        }

        private static func makeCharacterClass(
            from characters: [Character],
            startIndex: Int
        ) -> (String, Int)? {
            var index = startIndex + 1
            guard index < characters.count else { return nil }

            var characterClass = "["
            if characters[index] == "!" || characters[index] == "^" {
                characterClass += "^"
                index += 1
            }

            var hadContent = false
            while index < characters.count {
                let character = characters[index]
                if character == "]", hadContent {
                    characterClass += "]"
                    return (characterClass, index)
                }

                switch character {
                case "\\":
                    characterClass += "\\\\"
                case "]":
                    characterClass += "\\]"
                default:
                    characterClass.append(character)
                }

                hadContent = true
                index += 1
            }

            return nil
        }

        private static func matchesSegment(_ value: String, with regex: NSRegularExpression) -> Bool {
            let range = NSRange(location: 0, length: value.utf16.count)
            return regex.firstMatch(in: value, options: [], range: range) != nil
        }

        private var pathSegmentsCount: Int {
            pathSegments.count
        }

        private var pathSegmentsPattern: [PathSegment] {
            pathSegments
        }

        private enum PathSegment {
            case recursiveWildcard
            case segment(NSRegularExpression)

            init(token: String) throws {
                if token == "**" {
                    self = .recursiveWildcard
                } else {
                    self = try .segment(CompiledGlobPattern.makeSegmentRegex(token))
                }
            }
        }

        private struct MatchState: Hashable {
            let patternIndex: Int
            let pathIndex: Int
        }
    }

    enum FileSystemError: Error, LocalizedError {
        case fileNotFound(path: String)
        case directoryNotFound(path: String)
        case directoryAlreadyExists(path: String)
        case pathExistsAsFile(path: String)
        case cannotReadFile(path: String)
        case fileTooLarge(path: String, size: Int, maxSize: Int)
        case invalidEncoding(path: String)
        case invalidPath(path: String)
        case accessDenied(path: String)
        case textNotFound(text: String)
        case invalidLineNumber(line: Int, maxLine: Int)

        var errorDescription: String? {
            switch self {
            case let .fileNotFound(path):
                return "File not found: \(path)"
            case let .directoryNotFound(path):
                return "Directory not found: \(path)"
            case let .directoryAlreadyExists(path):
                return "Directory already exists: \(path)"
            case let .pathExistsAsFile(path):
                return "Path exists and is not a directory: \(path)"
            case let .cannotReadFile(path):
                return "Cannot read file: \(path)"
            case let .fileTooLarge(path, size, maxSize):
                return "File too large: \(path) (\(size) bytes, max \(maxSize) bytes)"
            case let .invalidEncoding(path):
                return "Invalid encoding: \(path)"
            case let .invalidPath(path):
                return "Invalid path: \(path)"
            case let .accessDenied(path):
                return "Access denied: \(path)"
            case let .textNotFound(text):
                return "Text not found: \(text.prefix(50))..."
            case let .invalidLineNumber(line, maxLine):
                return "Invalid line number: \(line) (max: \(maxLine))"
            }
        }
    }
}

struct FileReadResult: Codable {
    let path: String
    let content: String
    let size: Int
    let encoding: String
    let startLine: Int?
    let endLine: Int?
    let truncated: Bool
    let totalChars: Int
    let message: String // Human-readable summary
}

struct FileWriteResult: Codable {
    let path: String
    let size: Int
    let created: Bool
    let message: String // Human-readable summary
}

struct FileReplaceResult: Codable {
    let path: String
    let occurrences: Int
    let oldLength: Int
    let newLength: Int
    let size: Int
    let message: String // Human-readable summary
}

struct FileAppendResult: Codable {
    let path: String
    let appendedSize: Int
    let totalSize: Int
    let message: String // Human-readable summary
}

struct DirectoryListResult: Codable {
    let path: String
    let items: [DirectoryItem]
    let count: Int
    let message: String // Human-readable summary for UI display
}

struct DirectoryItem: Codable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int?
}

struct DirectoryCreateResult: Codable {
    let path: String
    let created: Bool
    let message: String // Human-readable summary
}

struct FileDeleteResult: Codable {
    let path: String
    let deleted: Bool
    let message: String // Human-readable summary
}

/// Result for findFiles (glob) operation
struct FindFilesResult: Codable {
    let path: String
    let pattern: String
    let items: [DirectoryItem]
    let count: Int
    let message: String // Human-readable summary for UI display
}

/// Individual match from grep (per-line)
struct FindMatch: Codable {
    let path: String
    let lineNumber: Int
    let line: String
}

/// Aggregated search results for grep
struct SearchResults: Codable {
    let pattern: String
    let matches: [FindMatch]
    let count: Int
    let message: String // Human-readable summary for UI display
}

struct FilePathMetadata: Codable {
    let inputPath: String
    let resolvedPath: String
    let baseDir: String
}
