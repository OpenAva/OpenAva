import Foundation

struct ProjectWorkspaceProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var path: String
    var bookmarkData: Data?
    var createdAtMs: Int64
    var lastAccessedAtMs: Int64

    var url: URL {
        AgentProfile.resolveSandboxPath(path, isDirectory: true).standardizedFileURL
    }

    var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let lastPathComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return lastPathComponent.isEmpty ? "OpenAva" : lastPathComponent
    }

    var displayPath: String {
        url.path
    }

    init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        bookmarkData: Data? = nil,
        createdAtMs: Int64 = ProjectWorkspaceStore.currentTimeMs(),
        lastAccessedAtMs: Int64 = ProjectWorkspaceStore.currentTimeMs()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = url.standardizedFileURL.path
        self.bookmarkData = bookmarkData
        self.createdAtMs = createdAtMs
        self.lastAccessedAtMs = lastAccessedAtMs
    }
}

struct ProjectWorkspaceState: Equatable {
    var workspaces: [ProjectWorkspaceProfile]
    var activeWorkspaceID: UUID?

    var activeWorkspace: ProjectWorkspaceProfile? {
        guard let activeWorkspaceID else { return workspaces.first }
        return workspaces.first { $0.id == activeWorkspaceID } ?? workspaces.first
    }
}

enum ProjectWorkspaceStore {
    private struct Payload: Codable {
        var activeWorkspaceID: UUID?
        var workspaces: [ProjectWorkspaceProfile]
    }

    private enum Storage {
        static let defaultsKey = "openava.projectWorkspaces.v1"
    }

    static func currentTimeMs(date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    static func load(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> ProjectWorkspaceState {
        var payload = loadPayload(defaults: defaults) ?? Payload(activeWorkspaceID: nil, workspaces: [])
        let defaultWorkspace = defaultWorkspaceProfile(fileManager: fileManager)

        if !payload.workspaces.contains(where: { samePath($0.url, defaultWorkspace.url) }) {
            payload.workspaces.insert(defaultWorkspace, at: 0)
        }

        if payload.activeWorkspaceID == nil || !payload.workspaces.contains(where: { $0.id == payload.activeWorkspaceID }) {
            payload.activeWorkspaceID = payload.workspaces.first?.id
        }

        payload.workspaces = normalizedWorkspaces(payload.workspaces)
        persist(payload, defaults: defaults)
        return ProjectWorkspaceState(workspaces: payload.workspaces, activeWorkspaceID: payload.activeWorkspaceID)
    }

    static func setActiveWorkspace(
        _ workspaceID: UUID,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> ProjectWorkspaceState {
        var payload = loadPayload(defaults: defaults) ?? Payload(activeWorkspaceID: nil, workspaces: [])
        let defaultWorkspace = defaultWorkspaceProfile(fileManager: fileManager)
        if !payload.workspaces.contains(where: { samePath($0.url, defaultWorkspace.url) }) {
            payload.workspaces.insert(defaultWorkspace, at: 0)
        }
        if let index = payload.workspaces.firstIndex(where: { $0.id == workspaceID }) {
            payload.workspaces[index].lastAccessedAtMs = currentTimeMs()
            payload.activeWorkspaceID = workspaceID
        }
        payload.workspaces = normalizedWorkspaces(payload.workspaces)
        persist(payload, defaults: defaults)
        return ProjectWorkspaceState(workspaces: payload.workspaces, activeWorkspaceID: payload.activeWorkspaceID)
    }

    @discardableResult
    static func importWorkspace(
        at workspaceURL: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> ProjectWorkspaceState {
        let standardizedURL = workspaceURL.standardizedFileURL
        return try withSecurityScopedAccess(to: standardizedURL) {
            try initializeWorkspace(at: standardizedURL, fileManager: fileManager)
            let bookmarkData = securityScopedBookmarkData(for: standardizedURL)
            let profile = ProjectWorkspaceProfile(
                name: defaultName(for: standardizedURL),
                url: standardizedURL,
                bookmarkData: bookmarkData
            )
            return upsert(profile, makeActive: true, defaults: defaults, fileManager: fileManager)
        }
    }

    @discardableResult
    static func createWorkspace(
        named rawName: String,
        inParentDirectory parentDirectoryURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> ProjectWorkspaceState {
        let name = sanitizedWorkspaceName(rawName)
        let parentURL = try resolvedCreationParentDirectory(parentDirectoryURL, fileManager: fileManager)
        return try withSecurityScopedAccess(to: parentURL) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            let workspaceURL = nextAvailableWorkspaceURL(named: name, in: parentURL, fileManager: fileManager)
            try initializeWorkspace(at: workspaceURL, fileManager: fileManager)
            let bookmarkData = securityScopedBookmarkData(for: workspaceURL)
            let profile = ProjectWorkspaceProfile(
                name: name,
                url: workspaceURL,
                bookmarkData: bookmarkData
            )
            return upsert(profile, makeActive: true, defaults: defaults, fileManager: fileManager)
        }
    }

    static func initializeWorkspace(at workspaceURL: URL, fileManager: FileManager = .default) throws {
        let standardizedURL = workspaceURL.standardizedFileURL
        try fileManager.createDirectory(at: standardizedURL, withIntermediateDirectories: true)
        let supportURL = AgentStore.supportDirectoryURL(workspaceRootURL: standardizedURL)
        try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        if OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: standardizedURL) == nil {
            OpenAvaProjectFile.persist(OpenAvaProjectState(), fileManager: fileManager, workspaceRootURL: standardizedURL)
        }
    }

    static func resolvedURL(for profile: ProjectWorkspaceProfile) -> URL {
        #if targetEnvironment(macCatalyst)
            if let bookmarkData = profile.bookmarkData {
                var bookmarkDataIsStale = false
                if let resolvedURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &bookmarkDataIsStale
                ) {
                    _ = resolvedURL.startAccessingSecurityScopedResource()
                    return resolvedURL.standardizedFileURL
                }
            }
        #endif
        return profile.url
    }

    private static func upsert(
        _ profile: ProjectWorkspaceProfile,
        makeActive: Bool,
        defaults: UserDefaults,
        fileManager: FileManager
    ) -> ProjectWorkspaceState {
        var payload = loadPayload(defaults: defaults) ?? Payload(activeWorkspaceID: nil, workspaces: [])
        let defaultWorkspace = defaultWorkspaceProfile(fileManager: fileManager)
        if !payload.workspaces.contains(where: { samePath($0.url, defaultWorkspace.url) }) {
            payload.workspaces.insert(defaultWorkspace, at: 0)
        }

        if let existingIndex = payload.workspaces.firstIndex(where: { samePath($0.url, profile.url) }) {
            let existingID = payload.workspaces[existingIndex].id
            payload.workspaces[existingIndex] = ProjectWorkspaceProfile(
                id: existingID,
                name: profile.name,
                url: profile.url,
                bookmarkData: profile.bookmarkData ?? payload.workspaces[existingIndex].bookmarkData,
                createdAtMs: payload.workspaces[existingIndex].createdAtMs,
                lastAccessedAtMs: currentTimeMs()
            )
            if makeActive {
                payload.activeWorkspaceID = existingID
            }
        } else {
            payload.workspaces.append(profile)
            if makeActive {
                payload.activeWorkspaceID = profile.id
            }
        }

        payload.workspaces = normalizedWorkspaces(payload.workspaces)
        persist(payload, defaults: defaults)
        return ProjectWorkspaceState(workspaces: payload.workspaces, activeWorkspaceID: payload.activeWorkspaceID)
    }

    private static func loadPayload(defaults: UserDefaults) -> Payload? {
        guard let data = defaults.data(forKey: Storage.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private static func persist(_ payload: Payload, defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        defaults.set(data, forKey: Storage.defaultsKey)
    }

    private static func defaultWorkspaceProfile(fileManager: FileManager) -> ProjectWorkspaceProfile {
        let workspaceURL = (try? AgentStore.workspaceRootDirectory(fileManager: fileManager))
            ?? fileManager.temporaryDirectory.appendingPathComponent("OpenAva", isDirectory: true)
        try? initializeWorkspace(at: workspaceURL, fileManager: fileManager)
        return ProjectWorkspaceProfile(name: "OpenAva", url: workspaceURL, bookmarkData: nil, createdAtMs: 0, lastAccessedAtMs: 0)
    }

    private static func normalizedWorkspaces(_ workspaces: [ProjectWorkspaceProfile]) -> [ProjectWorkspaceProfile] {
        var seenPaths: Set<String> = []
        return workspaces.compactMap { workspace in
            let path = workspace.url.path
            guard !seenPaths.contains(path) else { return nil }
            seenPaths.insert(path)
            return workspace
        }
        .sorted { lhs, rhs in
            if lhs.createdAtMs != rhs.createdAtMs {
                return lhs.createdAtMs < rhs.createdAtMs
            }
            return lhs.resolvedName.localizedStandardCompare(rhs.resolvedName) == .orderedAscending
        }
    }

    private static func resolvedCreationParentDirectory(_ parentDirectoryURL: URL?, fileManager: FileManager) throws -> URL {
        if let parentDirectoryURL {
            return parentDirectoryURL.standardizedFileURL
        }
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "ProjectWorkspaceStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Documents directory unavailable"]
            )
        }
        return documentsURL
    }

    private static func nextAvailableWorkspaceURL(named name: String, in parentURL: URL, fileManager: FileManager) -> URL {
        var candidateURL = parentURL.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = parentURL.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidateURL
    }

    private static func sanitizedWorkspaceName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "OpenAva" : trimmed
        let illegalCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let mappedScalars = fallback.unicodeScalars.map { scalar -> UnicodeScalar in
            illegalCharacters.contains(scalar) ? "_" : scalar
        }
        let sanitized = String(String.UnicodeScalarView(mappedScalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return sanitized.isEmpty ? "OpenAva" : sanitized
    }

    private static func defaultName(for url: URL) -> String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "OpenAva" : name
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private static func withSecurityScopedAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        #if targetEnvironment(macCatalyst)
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        #endif
        return try body()
    }

    private static func securityScopedBookmarkData(for url: URL) -> Data? {
        #if targetEnvironment(macCatalyst)
            return try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        #else
            return nil
        #endif
    }
}
