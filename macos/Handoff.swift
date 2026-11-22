import AppKit
import SwiftUI

struct HandoffCard: Decodable, Identifiable {
    enum Stage: String, Decodable {
        case planning, review, execution, copyedit, complete

        var label: String {
            switch self {
            case .planning: return "等待构思"
            case .review: return "待你确认"
            case .execution: return "待 Codex 执行"
            case .copyedit: return "待 Gemini 润色"
            case .complete: return "定稿已完成"
            }
        }

        var index: Int {
            switch self {
            case .planning: return 0
            case .review: return 1
            case .execution: return 2
            case .copyedit: return 3
            case .complete: return 4
            }
        }

        var clipboardAction: String {
            switch self {
            case .planning: return "复制 Gemini 构思指令"
            case .execution: return "复制 Codex 执行指令"
            case .copyedit: return "复制 Gemini 润色指令"
            case .complete: return "复制定稿"
            case .review: return ""
            }
        }
    }

    let id: String
    let stage: Stage
    let title: String
    let goal: String
    let scope: [String]
    let draft: String?
    let digest: String?
    let report: String?
    let polish: String?
    let prompt: String?
    let client: String?
}

final class HandoffStore: ObservableObject {
    private static let workspaceKey = "handoffWorkspace"
    @Published private(set) var workspace = UserDefaults.standard.url(forKey: workspaceKey)
    @Published private(set) var cards: [HandoffCard] = []
    @Published var selected: String?
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    @Published private(set) var notice = ""

    var current: HandoffCard? { cards.first { $0.id == selected } }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "选择交接卡工作区"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = workspace
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            self.workspace = url
            UserDefaults.standard.set(url, forKey: Self.workspaceKey)
            self.cards = []
            self.selected = nil
            self.notice = ""
            self.refresh()
        }
    }

    func refresh() {
        run(["list"])
    }

    func create(title: String, goal: String, paths: String) {
        var args = ["new", "--title", title, "--goal", goal]
        for path in paths.split(whereSeparator: \.isNewline) {
            let name = path.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { args += ["--scope", name] }
        }
        run(args, mutation: true)
    }

    func approve(_ card: HandoffCard) {
        guard let digest = card.digest else { return }
        run(["approve", card.id, "--digest", digest], mutation: true)
    }

    func copy(_ card: HandoffCard) {
        guard let content = card.prompt ?? card.polish else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        notice = card.client.map { "指令已复制。在同一工作区粘贴到 \($0)。" } ?? "已复制定稿。"
    }

    private func run(_ args: [String], mutation: Bool = false) {
        guard let workspace, !busy else { return }
        let prefix = ["--workspace", workspace.path]
        busy = true
        error = ""
        if mutation { notice = "" }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<(cards: [HandoffCard], selected: String?), Error> = Result {
                let output = try HandoffCommand.call(prefix + args)
                let decoder = JSONDecoder()
                if mutation {
                    let updated = try decoder.decode(HandoffCard.self, from: output)
                    return (cards: [updated], selected: updated.id)
                }
                return (cards: try decoder.decode([HandoffCard].self, from: output), selected: String?.none)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                do {
                    let (cards, preferred) = try result.get()
                    if let preferred, let updated = cards.first {
                        self.cards.removeAll { $0.id == preferred }
                        self.cards.insert(updated, at: 0)
                        self.selected = preferred
                    } else {
                        self.cards = cards
                        if !cards.contains(where: { $0.id == self.selected }) { self.selected = cards.first?.id }
                    }
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

struct HandoffPane: View {
    @ObservedObject var store: HandoffStore
    @State private var composing = false
    @State private var confirming: HandoffCard?
    @State private var title = ""
    @State private var goal = ""
    @State private var paths = ""
    private let steps = ["Gemini 构思", "你确认", "Codex 执行", "Gemini 润色", "定稿"]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if let card = store.current { details(card) }
            else { empty }
        }
        .onAppear(perform: store.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !composing && confirming == nil { store.refresh() }
        }
        .sheet(isPresented: $composing) { newCard }
        .alert("确认执行范围？", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming
        ) { card in
            Button("确认执行范围") { store.approve(card) }
            Button("取消", role: .cancel) {}
        } message: { card in
            Text(card.scope.isEmpty ? "此卡只授权交付文字。" : "可修改文件\n" + card.scope.joined(separator: "\n"))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("交接卡").font(.headline)
                Spacer()
                Button(action: store.refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新交接卡").accessibilityLabel("刷新交接卡")
                    .disabled(store.workspace == nil)
            }
            Button(action: store.chooseWorkspace) {
                Label(store.workspace?.lastPathComponent ?? "选择工作区…", systemImage: "folder")
                    .lineLimit(1)
            }
            .help(store.workspace?.path ?? "选择两个客户端都能访问的项目目录")
            .disabled(store.busy)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.cards) { card in
                        Button {
                            store.selected = card.id
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(card.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text(card.stage.label).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(store.selected == card.id ? Color.accentColor.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.selected == card.id ? .isSelected : [])
                    }
                }
            }
            Button {
                title = ""
                goal = ""
                paths = ""
                composing = true
            } label: {
                Label("新建交接卡…", systemImage: "plus")
            }
            .disabled(store.workspace == nil || store.busy)
        }
        .padding(18)
        .frame(width: 220)
        .background(.background.opacity(0.38))
    }

    private var empty: some View {
        VStack(spacing: 9) {
            Image(systemName: "arrow.left.arrow.right.square").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(store.workspace == nil ? "选择交接卡工作区" : "此工作区还没有交接卡").font(.headline)
            Text(store.workspace == nil ? "选择两个客户端都能访问的项目目录。" : "新建一张卡，写下目标和允许修改的文件。")
                .foregroundStyle(.secondary)
            if !store.error.isEmpty { Text(store.error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func details(_ card: HandoffCard) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title).font(.title2.weight(.semibold))
                Spacer()
                Text(card.stage.label).font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { item in
                    HStack(spacing: 4) {
                        if item.offset != 0 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(item.element)
                            .foregroundStyle(item.offset == card.stage.index ? Color.accentColor : Color.secondary)
                            .font(.caption.weight(item.offset == card.stage.index ? .semibold : .regular))
                    }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let polish = card.polish { block("Gemini 定稿", polish) }
                    if let report = card.report { block("Codex 执行报告", report) }
                    block("任务目标", card.goal)
                    block("允许修改的文件", card.scope.isEmpty ? "仅交付卡片内容" : card.scope.joined(separator: "\n"),
                          monospaced: !card.scope.isEmpty)
                    if let draft = card.draft { block("Gemini 构思与初稿", draft) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                primaryAction(card)
                let status = store.error.isEmpty ? store.notice : store.error
                Text(status)
                    .font(.callout)
                    .foregroundStyle(store.error.isEmpty ? Color.secondary : Color.red)
                    .lineLimit(3)
                Spacer(minLength: 0)
                Text(card.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func primaryAction(_ card: HandoffCard) -> some View {
        if card.stage == .review {
            Button("确认执行范围…") { confirming = card }
                .buttonStyle(.borderedProminent).disabled(store.busy)
        } else {
            Button { store.copy(card) } label: {
                Label(card.stage.clipboardAction, systemImage: "document.on.document")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func block(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold))
            Text(value).font(monospaced ? .callout.monospaced() : .callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.background.opacity(0.68), in: RoundedRectangle(cornerRadius: 10))
    }

    private var newCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建交接卡").font(.title2.weight(.semibold))
            TextField("任务标题", text: $title)
            Text("任务目标与验收条件").font(.subheadline.weight(.medium))
            TextEditor(text: $goal)
                .font(.body).frame(minHeight: 85)
                .border(Color.secondary.opacity(0.22)).accessibilityLabel("任务目标与验收条件")
            Text("Codex 允许修改的文件，每行一个相对路径").font(.subheadline.weight(.medium))
            TextEditor(text: $paths)
                .font(.body.monospaced()).frame(minHeight: 60)
                .border(Color.secondary.opacity(0.22)).accessibilityLabel("允许修改的相对路径")
            HStack {
                Spacer()
                Button("取消") { composing = false }.keyboardShortcut(.cancelAction)
                Button("创建交接卡") {
                    store.create(title: title, goal: goal, paths: paths)
                    composing = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 530, height: 366)
    }
}
