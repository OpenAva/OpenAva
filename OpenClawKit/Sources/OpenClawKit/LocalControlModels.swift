import Foundation

public enum LocalControlRole: String, Codable, Sendable {
    case controller
    case host
}

public enum LocalControlEvent: String, Codable, Sendable {
    case pairChallenge = "pair.challenge"
    case pairApproved = "pair.approved"
}

public enum LocalControlCommand: String, Codable, Sendable {
    case listAgents = "remote.agent.list"
    case selectAgent = "remote.agent.select"
    case sendMessage = "remote.message.send"
}

public struct LocalControlHello: Codable, Sendable {
    public var type: String
    public var role: LocalControlRole
    public var instanceId: String
    public var displayName: String
    public var platform: String
    public var deviceFamily: String
    public var modelIdentifier: String?
    public var appVersion: String?
    public var appBuild: String?
    public var protocolVersion: Int

    public init(
        type: String = "hello",
        role: LocalControlRole,
        instanceId: String,
        displayName: String,
        platform: String,
        deviceFamily: String,
        modelIdentifier: String? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        protocolVersion: Int = 1
    ) {
        self.type = type
        self.role = role
        self.instanceId = instanceId
        self.displayName = displayName
        self.platform = platform
        self.deviceFamily = deviceFamily
        self.modelIdentifier = modelIdentifier
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.protocolVersion = protocolVersion
    }
}

public struct LocalControlPairRequest: Codable, Sendable {
    public var type: String
    public var controller: LocalControlHello

    public init(type: String = "pair-request", controller: LocalControlHello) {
        self.type = type
        self.controller = controller
    }
}

public struct LocalControlPairChallengePayload: Codable, Sendable {
    public var expiresAtMs: Int64

    public init(expiresAtMs: Int64) {
        self.expiresAtMs = expiresAtMs
    }
}

public struct LocalControlPairApproveParams: Codable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

public struct LocalControlPairApprovedPayload: Codable, Sendable {
    public var token: String
    public var host: LocalControlHello

    public init(token: String, host: LocalControlHello) {
        self.token = token
        self.host = host
    }
}

public struct LocalControlAgentSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var emoji: String
    public var isActive: Bool

    public init(id: String, name: String, emoji: String, isActive: Bool) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.isActive = isActive
    }
}

public struct LocalControlListAgentsPayload: Codable, Sendable, Equatable {
    public var agents: [LocalControlAgentSummary]
    public var activeAgentID: String?

    public init(agents: [LocalControlAgentSummary], activeAgentID: String?) {
        self.agents = agents
        self.activeAgentID = activeAgentID
    }
}

public struct LocalControlSelectAgentParams: Codable, Sendable, Equatable {
    public var agentID: String

    public init(agentID: String) {
        self.agentID = agentID
    }
}

public struct LocalControlSelectAgentPayload: Codable, Sendable, Equatable {
    public var activeAgentID: String

    public init(activeAgentID: String) {
        self.activeAgentID = activeAgentID
    }
}

public struct LocalControlSendMessageParams: Codable, Sendable, Equatable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public struct LocalControlSendMessagePayload: Codable, Sendable, Equatable {
    public var enqueued: Bool

    public init(enqueued: Bool) {
        self.enqueued = enqueued
    }
}

public struct LocalControlDiscoveredService: Sendable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var domain: String

    public init(id: String, name: String, host: String, port: Int, domain: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.domain = domain
    }

    public var endpointURL: URL? {
        URL(string: "ws://\(host):\(port)/local-control")
    }
}
