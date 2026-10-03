import Foundation

/// Reads data from the running Steam client in Aqua's bottle. Steam's UI is Chromium; with
/// `-cef-enable-debugging` it serves the DevTools protocol on 127.0.0.1:8080, and its
/// `SharedJSContext` page holds the signed-in user's library. This needs no Web API key and
/// no access to steamcommunity.com. The port is loopback-only and exists only while Aqua's
/// Steam is running.
public final class SteamClientBridge: @unchecked Sendable {
    public static let port = 8080
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    struct Target: Decodable {
        let title: String?
        let url: String?
        let webSocketDebuggerUrl: String?
    }

    public var isAvailable: Bool {
        get async { (try? await sharedContext()) != nil }
    }

    func sharedContext() async throws -> URL {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/json")!)
        request.timeoutInterval = 3
        let (data, _) = try await session.data(for: request)
        let targets = try JSONDecoder().decode([Target].self, from: data)
        guard let target = targets.first(where: { $0.title == "SharedJSContext" || ($0.url ?? "").contains("steamloopback.host/index.html") }),
              let socket = target.webSocketDebuggerUrl.flatMap(URL.init(string:)),
              socket.host == "127.0.0.1" || socket.host == "localhost" else {
            throw AquaError("Steam's UI isn't ready yet.")
        }
        return socket
    }

    /// Evaluates JavaScript in Steam's SharedJSContext and returns the JSON-decoded value.
    public func evaluate(_ expression: String, timeout: TimeInterval = 15) async throws -> Any? {
        let socketURL = try await sharedContext()
        let task = session.webSocketTask(with: socketURL)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let message: [String: Any] = ["id": 1, "method": "Runtime.evaluate",
                                      "params": ["expression": expression, "returnByValue": true, "awaitPromise": true]]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        try await task.send(.string(payload))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let reply = try await task.receive()
            let text: String
            switch reply {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  (json["id"] as? Int) == 1 else { continue }
            if let error = json["error"] as? [String: Any] { throw AquaError("Steam: \(error["message"] ?? "error")") }
            let result = (json["result"] as? [String: Any])?["result"] as? [String: Any]
            if let details = (json["result"] as? [String: Any])?["exceptionDetails"] as? [String: Any] {
                throw AquaError("Steam script failed: \((details["exception"] as? [String: Any])?["description"] ?? details["text"] ?? "unknown")")
            }
            return result?["value"]
        }
        throw AquaError("Steam didn't answer in time.")
    }

    /// Games in the signed-in user's library (owned or family-shared), from Steam's own stores.
    static let ownedGamesScript = """
    (() => {
      const all = window.collectionStore?.allAppsCollection?.allApps ?? window.appStore?.allApps ?? null;
      if (!all) return { error: "library not loaded" };
      const games = all
        .filter(a => a && (a.app_type === 1 || a.app_type === 8 || a.app_type === undefined)) // games and demos; skips tools, soundtracks, servers
        .filter(a => typeof a.BIsOwned !== "function" || a.BIsOwned() || a.BIsShared?.())
        .map(a => ({ appid: String(a.appid), name: a.display_name ?? a.sort_as ?? "", minutes: a.minutes_playtime_forever ?? 0 }));
      return { games };
    })()
    """

    public func ownedGames() async throws -> [SteamOwnedGame] {
        guard let value = try await evaluate(Self.ownedGamesScript) as? [String: Any] else {
            throw AquaError("Unexpected reply from Steam.")
        }
        if let error = value["error"] as? String { throw AquaError("Steam: \(error). Make sure you're signed in.") }
        return Self.parseOwned(value["games"])
    }

    static func parseOwned(_ value: Any?) -> [SteamOwnedGame] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["appid"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "App \(id)"
            return SteamOwnedGame(appID: id, name: name, playtimeMinutes: (item["minutes"] as? NSNumber)?.intValue ?? 0)
        }
    }
}
