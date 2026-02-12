import Foundation

enum RepoURLParser {
    static func fullName(from urlString: String) -> String? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        let components = url.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard components.count >= 2 else {
            return nil
        }

        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        return "\(owner)/\(repo)"
    }
}
