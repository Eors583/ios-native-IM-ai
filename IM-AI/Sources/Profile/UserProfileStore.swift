import Combine
import Foundation

struct UserProfile: Codable, Equatable {
    var avatarUri: String = ""
    var username: String = ""
    var email: String = ""
    var gender: String = ""
    var phone: String = ""
}

@MainActor
final class UserProfileStore: ObservableObject {
    private let key = "aiim.user_profile.v1"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Published private(set) var profile: UserProfile

    init() {
        self.profile = Self.loadFromDefaults(defaults: defaults, key: key, decoder: decoder) ?? .init()
    }

    func load() -> UserProfile {
        profile
    }

    func save(_ newProfile: UserProfile) {
        profile = newProfile
        if let data = try? encoder.encode(newProfile) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadFromDefaults(defaults: UserDefaults, key: String, decoder: JSONDecoder) -> UserProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(UserProfile.self, from: data)
    }
}

