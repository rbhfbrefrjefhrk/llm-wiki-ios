import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var model: AppModel

    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("语义检索，如「方阵和行列式的关系」", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.search)
                            .onSubmit { runSearch() }
                        Button("搜索") { runSearch() }
                            .buttonStyle(.borderedProminent)
                            .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if searching {
                    Section { ProgressView("端侧检索中…") }
                }

                if let searchError {
                    Section { Text("搜索失败：\(searchError)").foregroundColor(.red) }
                }

                if !results.isEmpty {
                    Section("检索结果（\(results.count)）· 离线端侧语义检索") {
                        ForEach(results) { hit in
                            NavigationLink(value: summary(of: hit.path)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(hit.path.replacingOccurrences(of: "wiki/", with: ""))
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(String(format: "%.2f", hit.score))
                                            .font(.caption)
                                            .foregroundColor(.accentColor)
                                    }
                                    Text(hit.content.replacingOccurrences(of: "\n", with: " "))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                if model.categories.allSatisfy({ $0.pages.isEmpty }) {
                    Section {
                        Text("本地暂无页面。请到「设置与同步」页点击「立即同步」，从 gitee 拉取知识库。")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(model.categories) { category in
                        if !category.pages.isEmpty {
                            Section("\(category.title)（\(category.pages.count)）") {
                                ForEach(category.pages) { page in
                                    NavigationLink(value: page) {
                                        Text(page.name).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("知识库")
            .navigationDestination(for: WikiPageSummary.self) { page in
                PageDetailView(page: page)
            }
        }
    }

    private func summary(of path: String) -> WikiPageSummary {
        WikiPageSummary(
            name: (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""),
            path: path
        )
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        searchError = nil
        Task {
            do {
                let hits = try await model.search(q)
                await MainActor.run {
                    results = hits
                    searching = false
                }
            } catch {
                await MainActor.run {
                    searchError = error.localizedDescription
                    searching = false
                }
            }
        }
    }
}

struct PageDetailView: View {
    @EnvironmentObject private var model: AppModel
    let page: WikiPageSummary

    var body: some View {
        ScrollView {
            Text(model.pageContent(page.path))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(page.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
