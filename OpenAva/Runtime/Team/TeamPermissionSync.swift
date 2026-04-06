import Foundation

struct TeamPermissionRequest: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case pending
        case approved
        case rejected
    }

    let id: String
    let kind: String
    let workerID: String
    let workerName: String
    let teamName: String
    let toolName: String
    let description: String
    let inputJSON: String?
    var status: Status
    var resolvedBy: String?
    var resolvedAt: Date?
    var feedback: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case workerID = "workerId"
        case workerName
        case teamName
        case toolName
        case description
        case inputJSON = "inputJson"
        case status
        case resolvedBy
        case resolvedAt
        case feedback
        case createdAt
    }
}

struct TeamPermissionResolution {
    let status: TeamPermissionRequest.Status
    let resolvedBy: String
    let feedback: String?
}

enum TeamPermissionSync {
    @discardableResult
    static func writePending(teamDirectoryURL: URL, request: TeamPermissionRequest) throws -> TeamPermissionRequest {
        var requests = readAll(teamDirectoryURL: teamDirectoryURL)
        requests.removeAll { $0.id == request.id }
        requests.append(request)
        try writeAll(requests, teamDirectoryURL: teamDirectoryURL)
        return request
    }

    static func readAll(teamDirectoryURL: URL) -> [TeamPermissionRequest] {
        let url = permissionsURL(teamDirectoryURL: teamDirectoryURL)
        guard let data = try? Data(contentsOf: url),
              let requests = try? JSONDecoder().decode([TeamPermissionRequest].self, from: data)
        else {
            return []
        }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }

    static func readPending(teamDirectoryURL: URL) -> [TeamPermissionRequest] {
        readAll(teamDirectoryURL: teamDirectoryURL).filter { $0.status == .pending }
    }

    @discardableResult
    static func resolve(
        teamDirectoryURL: URL,
        requestID: String,
        resolution: TeamPermissionResolution
    ) throws -> TeamPermissionRequest? {
        var requests = readAll(teamDirectoryURL: teamDirectoryURL)
        guard let index = requests.firstIndex(where: { $0.id == requestID }) else {
            return nil
        }
        requests[index].status = resolution.status
        requests[index].resolvedBy = resolution.resolvedBy
        requests[index].resolvedAt = Date()
        requests[index].feedback = resolution.feedback
        try writeAll(requests, teamDirectoryURL: teamDirectoryURL)
        return requests[index]
    }

    private static func writeAll(_ requests: [TeamPermissionRequest], teamDirectoryURL: URL) throws {
        let directory = permissionsDirectoryURL(teamDirectoryURL: teamDirectoryURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(requests)
        try data.write(to: permissionsURL(teamDirectoryURL: teamDirectoryURL), options: [.atomic])
    }

    private static func permissionsURL(teamDirectoryURL: URL) -> URL {
        permissionsDirectoryURL(teamDirectoryURL: teamDirectoryURL).appendingPathComponent("requests.json", isDirectory: false)
    }

    private static func permissionsDirectoryURL(teamDirectoryURL: URL) -> URL {
        teamDirectoryURL.appendingPathComponent("permissions", isDirectory: true)
    }
}
