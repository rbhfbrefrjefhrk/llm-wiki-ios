import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var model: AppModel

    @State private var input = ""
    @State private var sending = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if !model.streamingText.isEmpty {
                                MessageBubble(
                                    message: ChatMessage(
                                        role: "assistant",
                                        content: model.streamingText,
                                        sources: model.streamingSources
                                    )
                                )
                                .id("streaming")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.messages.count) { _ in scrollToBottom(proxy) }
                    .onChange(of: model.streamingText) { _ in scrollToBottom(proxy) }
                    .onAppear { scrollToBottom(proxy) }
                }

                Divider()

                HStack(spacing: 8) {
                    TextField("输入你的问题…", text: $input, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)

                    if sending {
                        Button("停止") {
                            task?.cancel()
                            sending = false
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("发送") { send() }
                            .buttonStyle(.borderedProminent)
                            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
            }
            .navigationTitle("问答")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { model.clearChat() }
                        .disabled(model.messages.isEmpty)
                }
            }
        }
    }

    private func send() {
        let question = input
        input = ""
        sending = true
        task = Task {
            await model.send(question)
            await MainActor.run { sending = false }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if !model.streamingText.isEmpty {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = model.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == "user" ? "你" : "助手")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(message.content)
                .padding(10)
                .background(
                    message.role == "user"
                    ? Color.accentColor.opacity(0.15)
                    : Color.secondary.opacity(0.12)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("引用").font(.caption2).foregroundColor(.secondary)
                    ForEach(message.sources, id: \.path) { source in
                        Text("· \(source.name)  \(String(format: "%.2f", source.score))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
