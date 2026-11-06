# 知识库 iPad 客户端（方案 C）

与 Android 端功能对齐：**同步 + 阅读/检索 + 询问回答**，不含上传。
检索下沉到 iPad 本地（bge-small-zh-v1.5 int8 ONNX），问答走云端 DeepSeek，同步从公网 gitee 直拉——**不依赖电脑**。

## 与 Android 端的对应关系

| 能力 | Android | iPad（本工程） |
| --- | --- | --- |
| 同步源 | JGit 直拉 gitee `app-wiki` | gitee OpenAPI v5（`branches` → `git/trees` → `contents`），同一分支 |
| 私有仓库认证 | 用户名 + 私人令牌（JGit CredentialsProvider） | 私人令牌（`access_token` 查询参数） |
| 端侧嵌入 | onnxruntime-android + 自实现 WordPiece | onnxruntime-objc + 自实现 WordPiece（口径一致） |
| 向量索引 | `files/index/vectors.bin` | `Documents/index/vectors.bin`（同一二进制布局） |
| 检索 | 点积即余弦，topK=5 | 同上 |
| 问答 | DeepSeek `/chat/completions` SSE | 同上（URLSession `AsyncBytes` 逐行解析） |
| 存储 | Room | 文件（`Documents/wiki/**` + `manifest.json` + `sync_state.json`） |
| UI | Jetpack Compose | SwiftUI |

选择 REST 而不是在 iPad 上集成 libgit2：iOS 上 libgit2 需要额外编译与签名，REST 只依赖 URLSession，且同样能拿到 git blob sha 做增量比对。

## 环境要求

- macOS + Xcode 15 及以上
- Homebrew（用于装 xcodegen / cocoapods）
- 真机运行需要 Apple ID（免费账号即可，7 天签名）或开发者账号

```bash
brew install xcodegen cocoapods
```

## 构建步骤

```bash
cd D:/dev2/llm-wiki-ios          # 在 Mac 上换成实际路径
xcodegen generate                 # 生成 LlmWiki.xcodeproj
pod install                       # 拉 onnxruntime-objc（≈27MB，需联网）
open LlmWiki.xcworkspace          # 注意打开 workspace，不是 xcodeproj
```

然后在 Xcode：

1. 选中 `LlmWiki` target → Signing & Capabilities → 选择自己的 Team（或先改 `project.yml` 里的 `DEVELOPMENT_TEAM`）；
2. 若 Bundle ID 冲突，改 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 后重新 `xcodegen generate` + `pod install`；
3. 选择 iPad 设备运行。

## 首次使用配置

打开 App →「设置与同步」：

| 字段 | 值 |
| --- | --- |
| owner | `czjsuper` |
| repo | `llmwiki-kb` |
| branch | `app-wiki` |
| 用户名 | `czjsuper` |
| 私人令牌 | gitee → 设置 → 安全设置 → 私人令牌（`projects` 读权限） |
| DeepSeek API Key | 自备 |
| 模型 | `deepseek-chat`（或 `deepseek-v4-flash`） |

点「保存设置」→「立即同步」。首次会拉 712 个 md（约 1.7MB，8 并发），完成后显示页数。

首次检索/问答会触发端侧建索引（712 页切块后逐块推理），iPad 上大约需要数十秒到两分钟，之后索引落盘复用。

## 目录

```
LlmWiki/
  LlmWikiApp.swift          App 入口
  AppModel.swift            依赖容器 + 状态（@MainActor ObservableObject）
  Config.swift              UserDefaults 配置
  Models.swift              领域模型
  Storage.swift             文件存储 / manifest / 同步状态 / 会话
  Sync/GiteeSyncManager.swift   gitee REST 同步（增量比对 blob sha）
  NLP/BertTokenizer.swift   WordPiece 分词（对齐 tokenizers 口径）
  NLP/OnnxEmbedder.swift    ORT 推理（batch 8、动态 padding、CLS+L2）
  NLP/LocalSearchIndex.swift    切块 / 建索引 / 落盘 / 余弦检索
  Chat/DeepSeekClient.swift     SSE 流式
  Chat/ChatService.swift        端侧 RAG 编排
  Views/                    知识库 / 问答 / 设置
  Resources/model/          bge-small-zh-int8.onnx（23.8MB）+ vocab.txt
```

## 已知未验证项

本工程是在 Windows 上生成的源码，**没有经过 Xcode 编译**（当前环境无 macOS）。首次在 Mac 上构建时可能需要处理：

- `onnxruntime-objc` 的 pod 版本与接口名（`ORTValue(tensorData:elementType:shape:)`、`session.run(withInputs:outputNames:runOptions:)`）以实际 pod 头文件为准；
- gitee `git/trees` 接口是否忽略 `page` 参数（代码已做去重与提前停止，重复请求不会造成脏数据）；
- iPad 上首次建索引的耗时（如过慢，可把 `OnnxEmbedder.batchSize` 调大或把切块上限从 400 降到 300）。

这些都属于构建期可快速修正的参数/接口问题，不涉及架构改动。
