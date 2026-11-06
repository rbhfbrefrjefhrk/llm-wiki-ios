import Foundation

/// 本地配置（UserDefaults）。令牌与 Key 仅存本机。
final class AppConfig {
    static let shared = AppConfig()
    private let d = UserDefaults.standard

    private enum Key {
        static let giteeOwner = "gitee_owner"
        static let giteeRepo = "gitee_repo"
        static let giteeBranch = "gitee_branch"
        static let giteeToken = "gitee_token"
        static let giteeUser = "gitee_user"
        static let dsKey = "deepseek_api_key"
        static let dsModel = "deepseek_model"
        static let topK = "top_k"
    }

    var giteeOwner: String {
        get { d.string(forKey: Key.giteeOwner) ?? "czjsuper" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.giteeOwner) }
    }

    var giteeRepo: String {
        get { d.string(forKey: Key.giteeRepo) ?? "llmwiki-kb" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.giteeRepo) }
    }

    var giteeBranch: String {
        get { d.string(forKey: Key.giteeBranch) ?? "app-wiki" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.giteeBranch) }
    }

    var giteeToken: String {
        get { d.string(forKey: Key.giteeToken) ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.giteeToken) }
    }

    var giteeUser: String {
        get { d.string(forKey: Key.giteeUser) ?? "czjsuper" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.giteeUser) }
    }

    var deepseekKey: String {
        get { d.string(forKey: Key.dsKey) ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.dsKey) }
    }

    var deepseekModel: String {
        get {
            let v = d.string(forKey: Key.dsModel) ?? ""
            return v.isEmpty ? "deepseek-chat" : v
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            d.set(v.isEmpty ? "deepseek-chat" : v, forKey: Key.dsModel)
        }
    }

    var topK: Int {
        get {
            let v = d.integer(forKey: Key.topK)
            return v == 0 ? 5 : v
        }
        set { d.set(newValue, forKey: Key.topK) }
    }
}
