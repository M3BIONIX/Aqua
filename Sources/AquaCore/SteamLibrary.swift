import Foundation
import Security

public struct SteamOwnedGame: Codable, Hashable, Sendable {
    public let appID: String
    public let name: String
    public let playtimeMinutes: Int
}

/// Where the Steam owned-games list came from, for the UI to explain gaps.
public enum SteamLibrarySource: String, Codable, Sendable {
    case webAPI, steamClient, publicProfile, cache
}

public struct SteamLibraryResult: Sendable {
    public let games: [SteamOwnedGame]
    public let source: SteamLibrarySource
    public let fetched: Date
}

/// The Windows Steam client doesn't keep a readable list of owned games on disk, so the
/// list comes from, in order:
/// 1. `IPlayerService/GetOwnedGames` with the user's own Web API key, if they added one.
/// 2. The running Steam client in Aqua's bottle (no key needed; see `SteamClientBridge`).
/// 3. The public profile's games XML (needs public "Game details" and steamcommunity.com).
/// The last good result is cached so the library shows while Steam is closed.
public final class SteamLibrary: @unchecked Sendable {
    let steam: SteamStore
    let session: URLSession
    let client: SteamClientBridge

    public init(steam: SteamStore, session: URLSession = .shared) {
        self.steam = steam
        self.session = session
        self.client = SteamClientBridge(session: session)
    }

    var cacheFile: URL { steam.bottle.root.appendingPathComponent("owned-games.json") }

    struct Cache: Codable {
        let steamID: String
        let source: SteamLibrarySource
        let fetched: Date
        let games: [SteamOwnedGame]
    }

    public func cached() -> SteamLibraryResult? {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.steamID == steam.steamID64 else { return nil }
        return SteamLibraryResult(games: cache.games, source: .cache, fetched: cache.fetched)
    }

    public func fetch() async throws -> SteamLibraryResult {
        guard let steamID = steam.steamID64 else {
            throw AquaError("Sign in to Steam in Aqua's Steam window first.")
        }
        var failures: [String] = []
        if let key = SteamAPIKey.load() {
            do {
                return try save(SteamLibraryResult(games: try await fetchWebAPI(steamID: steamID, key: key), source: .webAPI, fetched: Date()), steamID: steamID)
            } catch {
                failures.append("Steam Web API: \(error.localizedDescription)")
            }
        }
        do {
            let games = try await client.ownedGames()
            if !games.isEmpty {
                return try save(SteamLibraryResult(games: games, source: .steamClient, fetched: Date()), steamID: steamID)
            }
            failures.append("Steam client: no games reported yet")
        } catch {
            failures.append("Steam client: \(error.localizedDescription)")
        }
        do {
            return try save(SteamLibraryResult(games: try await fetchPublicProfile(steamID: steamID), source: .publicProfile, fetched: Date()), steamID: steamID)
        } catch {
            failures.append("Public profile: \(error.localizedDescription)")
        }
        if let cached = cached() { return cached }
        throw AquaError("Couldn't load your Steam library.\n" + failures.joined(separator: "\n")
            + "\nOpen Aqua's Steam and sign in, or add a Steam Web API key in Accounts.")
    }

    private func save(_ result: SteamLibraryResult, steamID: String) throws -> SteamLibraryResult {
        let cache = Cache(steamID: steamID, source: result.source, fetched: result.fetched, games: result.games)
        try JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
        return result
    }

    func fetchWebAPI(steamID: String, key: String) async throws -> [SteamOwnedGame] {
        var components = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "steamid", value: steamID),
            URLQueryItem(name: "include_appinfo", value: "1"),
            URLQueryItem(name: "include_played_free_games", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AquaError(http.statusCode == 401 || http.statusCode == 403 ? "the API key was rejected" : "HTTP \(http.statusCode)")
        }
        return try Self.parseWebAPI(data)
    }

    static func parseWebAPI(_ data: Data) throws -> [SteamOwnedGame] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any] else { throw AquaError("unexpected response") }
        // A private profile with a valid key still returns `{"response":{}}`.
        guard let games = response["games"] as? [[String: Any]] else {
            if response.isEmpty { throw AquaError("Steam returned no games (is the profile's Game details private?)") }
            return []
        }
        return games.compactMap { game in
            guard let id = (game["appid"] as? NSNumber)?.stringValue else { return nil }
            return SteamOwnedGame(appID: id, name: game["name"] as? String ?? "App \(id)",
                                  playtimeMinutes: (game["playtime_forever"] as? NSNumber)?.intValue ?? 0)
        }
    }

    func fetchPublicProfile(steamID: String) async throws -> [SteamOwnedGame] {
        let url = URL(string: "https://steamcommunity.com/profiles/\(steamID)/games?tab=all&xml=1")!
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw AquaError("HTTP \(http.statusCode)") }
        return try Self.parseProfileXML(data)
    }

    static func parseProfileXML(_ data: Data) throws -> [SteamOwnedGame] {
        let parser = ProfileGamesParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw AquaError("unreadable profile response") }
        if let error = parser.error { throw AquaError(error) }
        guard parser.sawGamesList else { throw AquaError("profile is private or unavailable") }
        return parser.games
    }

    private final class ProfileGamesParser: NSObject, XMLParserDelegate {
        var games: [SteamOwnedGame] = []
        var error: String?
        var sawGamesList = false
        private var text = ""
        private var appID: String?
        private var name: String?
        private var hours = 0

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if element == "gamesList" { sawGamesList = true }
            if element == "game" { appID = nil; name = nil; hours = 0 }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "appID": appID = value
            case "name": name = value
            case "hoursOnRecord": hours = Int((Double(value.replacingOccurrences(of: ",", with: "")) ?? 0) * 60)
            case "error": error = value
            case "game":
                if let appID { games.append(SteamOwnedGame(appID: appID, name: name ?? "App \(appID)", playtimeMinutes: hours)) }
            default: break
            }
            text = ""
        }
    }
}

/// The user's Steam Web API key, kept in the login Keychain rather than Aqua's settings file.
public enum SteamAPIKey {
    static let service = "app.aqua.launcher.steam-web-api"

    public static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ key: String?) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        guard key.count == 32, key.allSatisfy(\.isHexDigit) else { throw AquaError("A Steam Web API key is 32 hexadecimal characters.") }
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AquaError("Couldn't save the key to the Keychain (\(status)).") }
    }
}
