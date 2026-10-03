import Foundation

/// Steam's download queue as its own Downloads page sees it.
public struct SteamDownloadState: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let appID: String
        public let active: Bool
        public let paused: Bool
        public let completed: Bool
        public let queueIndex: Int
    }

    /// The app Steam is transferring right now, if any.
    public var activeAppID: String?
    public var networkBytesPerSecond: Double
    public var diskBytesPerSecond: Double
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var secondsRemaining: Int?
    public var paused: Bool
    public var items: [Item]

    public static let empty = SteamDownloadState(activeAppID: nil, networkBytesPerSecond: 0, diskBytesPerSecond: 0,
                                                 bytesDone: 0, bytesTotal: 0, secondsRemaining: nil, paused: false, items: [])
}

/// Controls Steam's downloads through `SteamClient.Downloads` in the running client.
extension SteamStore {
    /// Subscribes once per Steam session and returns the latest overview and queue.
    static let downloadStateScript = """
    (() => {
      if (!window.__aquaDownloads) {
        window.__aquaDownloads = { overview: null, items: [] };
        SteamClient.Downloads.RegisterForDownloadOverview(o => { window.__aquaDownloads.overview = o; });
        SteamClient.Downloads.RegisterForDownloadItems((active, items) => { window.__aquaDownloads.items = items || []; });
      }
      const o = window.__aquaDownloads.overview || {};
      const phases = (o.progress || []).filter(p => p.bytes_total > 0);
      return {
        appid: o.update_appid ? String(o.update_appid) : null,
        network: o.update_network_bytes_per_second || 0,
        disk: o.update_disc_bytes_per_second || 0,
        done: phases.reduce((n, p) => n + p.bytes_in_progress, 0),
        total: phases.reduce((n, p) => n + p.bytes_total, 0),
        eta: o.overall_estimated_time_remaining_sec ?? -1,
        paused: !!o.paused,
        items: window.__aquaDownloads.items.map(i => ({
          appid: String(i.appid), active: !!i.active, paused: !!i.paused, completed: !!i.completed,
          queue: typeof i.queue_index === "number" ? i.queue_index : -1
        }))
      };
    })()
    """

    public func downloadState(bridge: SteamClientBridge = SteamClientBridge()) async throws -> SteamDownloadState {
        guard let json = try await bridge.evaluate(Self.downloadStateScript, timeout: 5) as? [String: Any] else { return .empty }
        let items = (json["items"] as? [[String: Any]] ?? []).compactMap { item -> SteamDownloadState.Item? in
            guard let appID = item["appid"] as? String else { return nil }
            return .init(appID: appID, active: item["active"] as? Bool ?? false, paused: item["paused"] as? Bool ?? false,
                         completed: item["completed"] as? Bool ?? false, queueIndex: item["queue"] as? Int ?? -1)
        }
        let eta = (json["eta"] as? NSNumber)?.intValue ?? -1
        return SteamDownloadState(
            activeAppID: json["appid"] as? String,
            networkBytesPerSecond: (json["network"] as? NSNumber)?.doubleValue ?? 0,
            diskBytesPerSecond: (json["disk"] as? NSNumber)?.doubleValue ?? 0,
            bytesDone: (json["done"] as? NSNumber)?.int64Value ?? 0,
            bytesTotal: (json["total"] as? NSNumber)?.int64Value ?? 0,
            secondsRemaining: eta >= 0 ? eta : nil,
            paused: json["paused"] as? Bool ?? false,
            items: items)
    }

    public func pauseDownload(appID: String) async throws { try await downloadCommand("PauseAppUpdate(\(try Self.number(appID)))") }
    public func resumeDownload(appID: String) async throws { try await downloadCommand("ResumeAppUpdate(\(try Self.number(appID)))") }
    /// Moves a game to the front of Steam's queue.
    public func prioritizeDownload(appID: String) async throws {
        let id = try Self.number(appID)
        try await downloadCommand("SetQueueIndex(\(id), 0); SteamClient.Downloads.ResumeAppUpdate(\(id))")
    }
    /// Takes a game off the queue. Steam keeps what was downloaded so far.
    public func cancelDownload(appID: String) async throws { try await downloadCommand("RemoveFromDownloadList(\(try Self.number(appID)))") }

    private func downloadCommand(_ call: String) async throws {
        _ = try await SteamClientBridge().evaluate("SteamClient.Downloads.\(call); true", timeout: 5)
    }

    private static func number(_ appID: String) throws -> Int {
        guard let id = Int(appID) else { throw AquaError("Invalid Steam app ID \(appID).") }
        return id
    }

    /// The account signed in to the running client, or nil when Steam shows its sign-in window.
    public func signedInAccount(bridge: SteamClientBridge = SteamClientBridge()) async -> String? {
        let script = "(window.App && App.BHasCurrentUser && App.BHasCurrentUser()) ? (App.m_CurrentUser.strAccountName || null) : null"
        return (try? await bridge.evaluate(script, timeout: 4)) as? String
    }

    /// Steam's own record of a remembered sign-in; it signs in by itself on its next start.
    public var remembersAccount: Bool {
        recentLogin?.entry["RememberPassword"]?.string == "1"
    }
}
