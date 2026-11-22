import AppKit
import SwiftUI

struct HandoffCard: Decodable, Identifiable {
    enum Stage: String, Decodable, CaseIterable {
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
    @Published private(set) var selected: String?
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

    func select(_ card: HandoffCard) {
        if selected != card.id {
            selected = card.id
            notice = ""
        }
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

private extension HandoffCard.Stage {
    var step: String {
        switch self {
        case .planning: return "Gemini 构思"
        case .review: return "范围确认"
        case .execution: return "Codex 执行"
        case .copyedit: return "Gemini 润色"
        case .complete: return "定稿"
        }
    }

    var icon: String {
        switch self {
        case .planning: return "lightbulb"
        case .review: return "checkmark.shield"
        case .execution: return "terminal"
        case .copyedit: return "pencil.line"
        case .complete: return "doc.text"
        }
    }

    var marker: Color {
        switch self {
        case .planning: return Color(nsColor: .systemIndigo)
        case .review: return Color(nsColor: .systemOrange)
        case .execution: return Color(nsColor: .systemBlue)
        case .copyedit: return Color(nsColor: .systemPurple)
        case .complete: return Color(nsColor: .systemTeal)
        }
    }

    var nextStep: String {
        switch self {
        case .planning: return "将构思指令粘贴到同一工作区的 Gemini 会话。"
        case .review: return "核对 Gemini 初稿和可修改的文件，再确认执行。"
        case .execution: return "将执行指令粘贴到同一工作区的 Codex 会话。"
        case .copyedit: return "将润色指令粘贴到同一工作区的 Gemini 会话。"
        case .complete: return "定稿已回到交接卡，可以直接复制。"
        }
    }
}

struct HandoffPane: View {
    @ObservedObject var store: HandoffStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var composing = false
    @State private var confirming: HandoffCard?
    @State private var title = ""
    @State private var goal = ""
    @State private var paths = ""

    private let accent = Color(red: 0.04, green: 0.38, blue: 0.34)
    private let heroInk = Color(red: 0.07, green: 0.15, blue: 0.17)
    private let heroMint = Color(red: 0.72, green: 0.93, blue: 0.83)

    private var accentInk: Color { colorScheme == .dark ? heroMint : accent }
    private var paper: Color { Color(nsColor: .controlBackgroundColor) }
    private var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    private var sidebarColor: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.13, blue: 0.14)
            : Color(red: 0.94, green: 0.96, blue: 0.95)
    }
    private var line: Color { Color.primary.opacity(0.10) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if let card = store.current {
                details(card).id(card.id)
            } else {
                empty
            }
        }
        .background(canvas)
        .tint(accent)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(heroMint)
                    .frame(width: 36, height: 36)
                    .background(heroInk, in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                Text("交接工作台").font(.system(size: 16, weight: .semibold))
            }
            .padding(.bottom, 24)

            Text("工作区")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 7)
            Button(action: store.chooseWorkspace) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(accentInk)
                    Text(store.workspace?.lastPathComponent ?? "选择工作区…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
                .padding(9)
                .background(paper, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.workspace?.path ?? "选择两个客户端都能访问的项目目录")
            .accessibilityLabel(store.workspace.map { "当前工作区：\($0.lastPathComponent)。点击切换" } ?? "选择工作区")
            .disabled(store.busy)
            .padding(.bottom, 24)

            HStack {
                Text("交接卡")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: store.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(accentInk)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("刷新交接卡")
                .accessibilityLabel("刷新交接卡")
                .disabled(store.workspace == nil || store.busy)
            }
            .padding(.bottom, 7)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(store.cards) { card in cardRow(card) }
                }
            }
            Divider().padding(.vertical, 12)
            Button(action: beginNewCard) {
                Label("新建交接卡", systemImage: "plus")
                    .foregroundStyle(accentInk)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(store.workspace == nil || store.busy)
        }
        .padding(16)
        .frame(width: 224)
        .background(sidebarColor)
    }

    private func cardRow(_ card: HandoffCard) -> some View {
        let selected = store.selected == card.id
        return Button { store.select(card) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: card.stage.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? accentInk : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(selected ? accentInk.opacity(0.12) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(card.title)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .lineLimit(2)
                    Label {
                        Text(card.stage.label).font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Circle().fill(card.stage.marker).frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(selected ? paper : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? accentInk.opacity(0.33) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(card.title)
        .contextMenu {
            Button("复制卡片 ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card.id, forType: .string)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: store.workspace == nil ? "folder" : "arrow.left.arrow.right")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(accentInk)
                .frame(width: 64, height: 64)
                .background(accentInk.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
            if store.busy {
                ProgressView().controlSize(.small).accessibilityLabel("正在读取交接卡")
            } else if !store.error.isEmpty {
                Text("读取交接卡失败").font(.title3.weight(.semibold))
                Text(store.error).foregroundStyle(.red).textSelection(.enabled)
                Button("重新读取", action: store.refresh)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            } else if store.workspace == nil {
                Text("选择交接卡工作区").font(.title3.weight(.semibold))
                Text("选一个 Gemini 和 Codex 都能访问的项目目录。").foregroundStyle(.secondary)
                Button("选择工作区…", action: store.chooseWorkspace)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            } else {
                Text("此工作区还没有交接卡").font(.title3.weight(.semibold))
                Text("写下任务目标和允许修改的文件，从 Gemini 构思开始。").foregroundStyle(.secondary)
                Button("新建交接卡", action: beginNewCard)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func details(_ card: HandoffCard) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(card)
                    if let polish = card.polish {
                        artifact("Gemini 定稿", text: polish, icon: "doc.text")
                    } else if let report = card.report {
                        artifact("Codex 执行报告", text: report, icon: "terminal")
                    }
                    brief(card)
                    if card.polish != nil, let report = card.report {
                        artifact("Codex 执行报告", text: report, icon: "terminal", collapsible: true)
                    }
                    if let draft = card.draft {
                        artifact("Gemini 构思与初稿", text: draft, icon: "lightbulb",
                                 collapsible: card.stage != .review)
                    }
                }
                .frame(maxWidth: 920)
                .padding(22)
                .frame(maxWidth: .infinity)
            }
            Divider()
            actionBar(card)
        }
    }

    private func header(_ card: HandoffCard) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Text(card.title)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Label(card.stage.label, systemImage: card.stage == .complete ? "checkmark.circle" : card.stage.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(heroMint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.10), in: Capsule())
                    .fixedSize()
            }
            Divider().overlay(.white.opacity(0.21))
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 7) {
                ForEach(HandoffCard.Stage.allCases, id: \.self) { stage in
                    if stage != .planning {
                        Capsule().fill(.white.opacity(0.20)).frame(height: 1)
                            .frame(minWidth: 4)
                            .padding(.top, 14)
                            .accessibilityHidden(true)
                    }
                    flowStep(stage, current: card.stage)
                }
            }
        }
        .padding(21)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [heroInk, Color(red: 0.10, green: 0.23, blue: 0.24)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private func flowStep(_ stage: HandoffCard.Stage, current: HandoffCard.Stage) -> some View {
        let active = stage == current
        let passed = stage.index < current.index || current == .complete && stage == .complete
        return VStack(spacing: 7) {
            Image(systemName: passed ? "checkmark" : stage.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 29, height: 29)
                .foregroundStyle(active ? heroInk : passed ? heroMint : .white.opacity(0.72))
                .background(active ? heroMint : .white.opacity(passed ? 0.14 : 0.07), in: Circle())
            Text(stage.step)
                .font(.caption.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? heroMint : .white.opacity(passed ? 0.94 : 0.72))
                .lineLimit(1)
        }
        .frame(minWidth: 61)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.step)
        .accessibilityValue(passed ? "已完成" : active ? "当前阶段" : "尚未开始")
    }

    private func brief(_ card: HandoffCard) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("任务目标", icon: "target")
                Text(card.goal)
                    .font(.callout)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("允许修改的文件", icon: "checkmark.shield")
                if card.scope.isEmpty {
                    Text("仅交付卡片内容").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(card.scope, id: \.self) { path in
                            Text(path)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .background(paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(line))
    }

    private func artifact(_ title: String, text: String, icon: String, collapsible: Bool = false) -> some View {
        Group {
            if collapsible {
                DisclosureGroup {
                    artifactBody(text)
                } label: {
                    sectionLabel(title, icon: icon)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel(title, icon: icon)
                    artifactBody(text)
                }
            }
        }
        .padding(15)
        .background(paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(line))
    }

    private func artifactBody(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 11)
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: icon).foregroundStyle(accentInk)
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
    }

    private func actionBar(_ card: HandoffCard) -> some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.stage == .complete ? "交付结果" : "下一步")
                    .font(.caption.weight(.semibold))
                if !store.error.isEmpty {
                    Text(store.error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if !store.notice.isEmpty {
                    Label(store.notice, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(accentInk)
                } else {
                    Text(card.stage.nextStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            primaryAction(card)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(paper)
    }

    @ViewBuilder
    private func primaryAction(_ card: HandoffCard) -> some View {
        if card.stage == .review {
            Button { confirming = card } label: {
                Label("确认执行范围…", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.busy)
        } else {
            Button { store.copy(card) } label: {
                Label(card.stage.clipboardAction, systemImage: "document.on.document")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(card.prompt == nil && card.polish == nil)
        }
    }

    private func beginNewCard() {
        title = ""
        goal = ""
        paths = ""
        composing = true
    }

    private var newCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("新建交接卡", systemImage: "square.and.pencil")
                .font(.title2.weight(.semibold))
                .foregroundStyle(accentInk)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 7) {
                Text("任务标题").font(.subheadline.weight(.semibold))
                TextField("例如：更新项目的安装指南", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .accessibilityLabel("任务标题")
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("任务目标与验收条件").font(.subheadline.weight(.semibold))
                editor($goal, label: "任务目标与验收条件", font: .body, height: 88)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("允许修改的文件").font(.subheadline.weight(.semibold))
                Text("每行填写一个相对路径。留空时，任务只交付卡片内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                editor($paths, label: "允许修改的相对路径", font: .body.monospaced(), height: 70)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { composing = false }
                    .keyboardShortcut(.cancelAction)
                Button("创建交接卡") {
                    store.create(title: title, goal: goal, paths: paths)
                    composing = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 540)
    }

    private func editor(_ value: Binding<String>, label: String, font: Font, height: CGFloat) -> some View {
        TextEditor(text: value)
            .font(font)
            .scrollContentBackground(.hidden)
            .frame(height: height)
            .padding(5)
            .background(paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(line))
            .accessibilityLabel(label)
    }
}
