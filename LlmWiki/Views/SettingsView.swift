import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var owner = AppConfig.shared.giteeOwner
    @State private var repo = AppConfig.shared.giteeRepo
    @State private var branch = AppConfig.shared.giteeBranch
    @State private var giteeUser = AppConfig.shared.giteeUser
    @State private var giteeToken = AppConfig.shared.giteeToken
    @State private var deepseekKey = AppConfig.shared.deepseekKey
    @State private var deepseekModel = AppConfig.shared.deepseekModel

    var body: some View {
        NavigationStack {
            Form {
                Section("gitee 数据源") {
                    TextField("owner", text: $owner)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("repo", text: $repo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("branch", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名", text: $giteeUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("私人令牌（仓库为私有才需要）", text: $giteeToken)
                }

                Section("DeepSeek（云端问答）") {
                    SecureField("API Key", text: $deepseekKey)
                    TextField("模型", text: $deepseekModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button("保存设置") { save() }
                    Button(model.busy ? "同步中…" : "立即同步") {
                        Task { await model.syncNow() }
                    }
                    .disabled(model.busy)
                }

                Section("同步状态") {
                    if let state = model.state {
                        LabeledContent("本地版本", value: String(state.version.prefix(8)))
                        LabeledContent("已缓存页数", value: "\(state.pageCount)")
                        LabeledContent("上次同步", value: format(state.syncedAt))
                    } else {
                        Text("尚未同步过").foregroundColor(.secondary)
                    }
                    if !model.status.isEmpty {
                        Text(model.status).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("说明") {
                    Text("数据源为 gitee 仓库的 app-wiki 分支；检索在 iPad 本地完成（bge-small-zh-v1.5 int8）；问答走 DeepSeek API。同步与检索不依赖电脑。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置与同步")
        }
    }

    private func save() {
        let config = AppConfig.shared
        config.giteeOwner = owner
        config.giteeRepo = repo
        config.giteeBranch = branch
        config.giteeUser = giteeUser
        config.giteeToken = giteeToken
        config.deepseekKey = deepseekKey
        config.deepseekModel = deepseekModel
        model.status = "设置已保存到本机"
    }

    private func format(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "（无）" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
