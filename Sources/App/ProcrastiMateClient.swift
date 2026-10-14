import Foundation
import Security
import UIKit

struct ProcrastiMateCredentials: Equatable, Sendable {
	var apiURL: URL
	var token: String
}

enum ProcrastiMateLinkStatus: Equatable, Sendable {
	case linked(ProcrastiMateCredentials)
	case unavailable(MemoTaskLinkProblem)
}

enum ProcrastiMateError: LocalizedError, Equatable {
	case unauthorized
	case http(Int)
	case invalidResponse

	var errorDescription: String? {
		switch self {
		case .unauthorized: "ProcrastiMate is signed out."
		case let .http(status): "ProcrastiMate answered with status \(status)."
		case .invalidResponse: "ProcrastiMate sent a response this app could not read."
		}
	}
}

/// ProcrastiMate's memo task routes (`docs/decisions/integrations.md` in the ProcrastiMate repository).
struct ProcrastiMateClient: Sendable {
	var status: @MainActor @Sendable () -> ProcrastiMateLinkStatus
	var put: @Sendable (ProcrastiMateCredentials, MemoTasksRequest) async throws -> [RemoteMemoTask]
	var list: @Sendable (ProcrastiMateCredentials, UUID) async throws -> [RemoteMemoTask]
	var delete: @Sendable (ProcrastiMateCredentials, UUID) async throws -> Void

	@MainActor static var live: Self {
		let device = ProcrastiMateLink.deviceID()
		return Self(
			status: { ProcrastiMateLink.status() },
			put: { credentials, request in
				let body = try JSONEncoder().encode(request)
				return try await send("PUT", path: "api/memo-tasks", credentials: credentials, device: device, body: body)
			},
			list: { credentials, memoID in
				try await send("GET", path: "api/memo-tasks", memoID: memoID, credentials: credentials, device: device)
			},
			delete: { credentials, memoID in
				_ = try await data("DELETE", path: "api/memo-tasks", memoID: memoID, credentials: credentials, device: device)
			})
	}

	private static func send(_ method: String, path: String, memoID: UUID? = nil, credentials: ProcrastiMateCredentials,
		device: String, body: Data? = nil) async throws -> [RemoteMemoTask] {
		let payload = try await data(method, path: path, memoID: memoID, credentials: credentials, device: device, body: body)
		return try ProcrastiMateWire.tasks(from: payload)
	}

	private static func data(_ method: String, path: String, memoID: UUID?, credentials: ProcrastiMateCredentials,
		device: String, body: Data? = nil) async throws -> Data {
		var url = credentials.apiURL.appending(path: path)
		if let memoID { url.append(queryItems: [URLQueryItem(name: "memoId", value: memoID.uuidString.lowercased())]) }
		var request = URLRequest(url: url, timeoutInterval: 20)
		request.httpMethod = method
		request.httpBody = body
		request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
		request.setValue(device, forHTTPHeaderField: "x-procrastimate-device")
		request.setValue("Voice memo", forHTTPHeaderField: "x-procrastimate-device-name")
		if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let status = (response as? HTTPURLResponse)?.statusCode else { throw ProcrastiMateError.invalidResponse }
		if status == 401 { throw ProcrastiMateError.unauthorized }
		guard (200..<300).contains(status) else { throw ProcrastiMateError.http(status) }
		return data
	}
}

enum ProcrastiMateWire {
	private struct Response: Decodable {
		struct Task: Decodable {
			var key: String
			var id: String
			var title: String
			var completedAt: Int64?
			var due: RemoteMemoTask.Due?
			var event: TaskEvent?
		}
		var tasks: [Task]
	}

	static func tasks(from data: Data) throws -> [RemoteMemoTask] {
		try JSONDecoder().decode(Response.self, from: data).tasks.map { task in
			guard let key = UUID(uuidString: task.key) else { throw ProcrastiMateError.invalidResponse }
			return RemoteMemoTask(key: key, id: task.id, title: task.title,
				completedAt: task.completedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }, due: task.due, event: task.event)
		}
	}
}

/// Whether ProcrastiMate can take tasks right now: installed, and signed in through the shared keychain item it keeps.
@MainActor
enum ProcrastiMateLink {
	static let service = "procrastimate-link"
	static let account = "default"
	static let accessGroup = "FNYFHG5SV7.com.stefan.shared"
	static let taskURLScheme = "procrastimate"

	static func status() -> ProcrastiMateLinkStatus {
		#if DEBUG
		if let override = debugOverride() { return override }
		#endif
		guard UIApplication.shared.canOpenURL(URL(string: "\(taskURLScheme)://")!) else { return .unavailable(.notInstalled) }
		guard let data = keychainData(), let credentials = credentials(from: data) else { return .unavailable(.signedOut) }
		return .linked(credentials)
	}

	nonisolated static func credentials(from data: Data) -> ProcrastiMateCredentials? {
		struct Item: Decodable { var apiURL: String; var token: String }
		guard let item = try? JSONDecoder().decode(Item.self, from: data), !item.token.isEmpty,
			let url = URL(string: item.apiURL), url.scheme == "https" || url.scheme == "http" else { return nil }
		return ProcrastiMateCredentials(apiURL: url, token: item.token)
	}

	static func taskURL(_ id: String) -> URL? {
		URL(string: "\(taskURLScheme)://task/\(id)")
	}

	static func deviceID(defaults: UserDefaults = .standard) -> String {
		let key = "procrastimate-device-id"
		if let saved = defaults.string(forKey: key) { return saved }
		let id = "voicememo-\(UUID().uuidString.lowercased())"
		defaults.set(id, forKey: key)
		return id
	}

	private static func keychainData() -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecAttrAccessGroup as String: accessGroup,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var result: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
		return result as? Data
	}

	#if DEBUG
	/// `-procrastimate-link '{"apiURL":…,"token":…}'` stands in for an installed, signed-in ProcrastiMate;
	/// `-procrastimate-link not-installed` or `signed-out` simulates the other states.
	private static func debugOverride() -> ProcrastiMateLinkStatus? {
		let arguments = ProcessInfo.processInfo.arguments
		guard let index = arguments.firstIndex(of: "-procrastimate-link"), arguments.indices.contains(index + 1) else { return nil }
		switch arguments[index + 1] {
		case "not-installed": return .unavailable(.notInstalled)
		case "signed-out": return .unavailable(.signedOut)
		case let value: return credentials(from: Data(value.utf8)).map(ProcrastiMateLinkStatus.linked) ?? .unavailable(.signedOut)
		}
	}
	#endif
}
