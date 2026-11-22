import AppKit
import SwiftUI

struct HandoffCard: Decodable, Identifiable {
    enum Stage: String, Decodable, CaseIterable {
        case planning, review, execution, copyedit, complete

        var index: Int {
            switch self {
            case .planning: return 0
            case .review: return 1
            case .execution: return 2
            case .copyedit: return 3
            case .complete: return 4
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
    enum CopyNotice {
        case prompt(client: String)
        case finalText

        func message(in language: WorkbenchLanguage) -> String {
            switch self {
            case .prompt(let client): return language.text("notice.prompt", client)
            case .finalText: return language.text("notice.final")
            }
        }
    }

    private static let workspaceKey = "handoffWorkspace"
    @Published private(set) var workspace = UserDefaults.standard.url(forKey: workspaceKey)
    @Published private(set) var cards: [HandoffCard] = []
    @Published private(set) var selected: String?
    @Published private(set) var busy = false
    @Published private(set) var error: Error?
    @Published private(set) var notice: CopyNotice?

    var current: HandoffCard? { cards.first { $0.id == selected } }

    func chooseWorkspace(in language: WorkbenchLanguage) {
        let panel = NSOpenPanel()
        panel.title = language.text("workspace.picker")
        panel.prompt = language.text("workspace.select")
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
            self.notice = nil
            self.refresh()
        }
    }

    func refresh() {
        run(["list"])
    }

    func select(_ card: HandoffCard) {
        if selected != card.id {
            selected = card.id
            notice = nil
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
        notice = card.client.map { .prompt(client: $0) } ?? .finalText
    }

    private func run(_ args: [String], mutation: Bool = false) {
        guard let workspace, !busy else { return }
        let prefix = ["--workspace", workspace.path]
        busy = true
        error = nil
        if mutation { notice = nil }
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
                    self.error = error
                }
            }
        }
    }
}

private extension HandoffCard.Stage {
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
}

struct HandoffPane: View {
    @ObservedObject var store: HandoffStore
    @AppStorage("handoffLanguage") private var language = WorkbenchLanguage.preferred
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
        .environment(\.locale, language.locale)
        .tint(accent)
        .onAppear(perform: store.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !composing && confirming == nil { store.refresh() }
        }
        .sheet(isPresented: $composing) { newCard }
        .alert(language.text("approval.title"), isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming
        ) { card in
            Button(language.text("approval.action")) { store.approve(card) }
            Button(language.text("action.cancel"), role: .cancel) {}
        } message: { card in
            Text(card.scope.isEmpty ? language.text("approval.writingOnly")
                 : ([language.text("approval.files")] + card.scope).joined(separator: "\n"))
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
                Text(language.text("workbench")).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
                languageMenu
            }
            .padding(.bottom, 24)

            Text(language.text("workspace"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 7)
            Button { store.chooseWorkspace(in: language) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(accentInk)
                    Text(store.workspace?.lastPathComponent ?? language.text("workspace.choose"))
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
            .help(store.workspace?.path ?? language.text("workspace.hint"))
            .accessibilityLabel(store.workspace.map { language.text("workspace.chosen", $0.lastPathComponent) }
                                ?? language.text("workspace.picker"))
            .disabled(store.busy)
            .padding(.bottom, 24)

            HStack {
                Text(language.text("cards"))
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
                .help(language.text("cards.refresh"))
                .accessibilityLabel(language.text("cards.refresh"))
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
                Label(language.text("cards.new"), systemImage: "plus")
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

    private var languageMenu: some View {
        Menu {
            ForEach(WorkbenchLanguage.allCases, id: \.self) { option in
                Button { language = option } label: {
                    if option == language {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "globe")
                .font(.callout.weight(.medium))
                .foregroundStyle(accentInk)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(language.text("interface.language"))
        .accessibilityLabel(language.text("interface.language"))
        .accessibilityValue(language.displayName)
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
                        Text(language.text("stage.\(card.stage.rawValue).status")).font(.caption).foregroundStyle(.secondary)
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
            Button(language.text("card.copyID")) {
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
                ProgressView().controlSize(.small).accessibilityLabel(language.text("cards.loading"))
            } else if let error = store.error {
                Text(language.text("error.load")).font(.title3.weight(.semibold))
                errorMessage(error).foregroundStyle(.red)
                Button(language.text("action.retry"), action: store.refresh)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            } else if store.workspace == nil {
                Text(language.text("workspace.picker")).font(.title3.weight(.semibold))
                Text(language.text("workspace.hint")).foregroundStyle(.secondary)
                Button(language.text("workspace.choose")) { store.chooseWorkspace(in: language) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            } else {
                Text(language.text("cards.empty")).font(.title3.weight(.semibold))
                Text(language.text("cards.empty.hint")).foregroundStyle(.secondary)
                Button(language.text("cards.new"), action: beginNewCard)
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
                        artifact(language.text("artifact.final"), text: polish, icon: "doc.text")
                    } else if let report = card.report {
                        artifact(language.text("artifact.report"), text: report, icon: "terminal")
                    }
                    brief(card)
                    if card.polish != nil, let report = card.report {
                        artifact(language.text("artifact.report"), text: report, icon: "terminal", collapsible: true)
                    }
                    if let draft = card.draft {
                        artifact(language.text("artifact.draft"), text: draft, icon: "lightbulb",
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
                Label(language.text("stage.\(card.stage.rawValue).status"), systemImage: card.stage == .complete ? "checkmark.circle" : card.stage.icon)
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
            Text(language.text("stage.\(stage.rawValue).step"))
                .font(.caption.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? heroMint : .white.opacity(passed ? 0.94 : 0.72))
                .lineLimit(1)
        }
        .frame(minWidth: 61)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("stage.\(stage.rawValue).step"))
        .accessibilityValue(language.text(passed ? "status.done" : active ? "status.current" : "status.pending"))
    }

    private func brief(_ card: HandoffCard) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel(language.text("card.goal"), icon: "target")
                Text(card.goal)
                    .font(.callout)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                sectionLabel(language.text("card.files"), icon: "checkmark.shield")
                if card.scope.isEmpty {
                    Text(language.text("card.files.none")).font(.callout).foregroundStyle(.secondary)
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
                Text(language.text(card.stage == .complete ? "action.result" : "action.next"))
                    .font(.caption.weight(.semibold))
                if let error = store.error {
                    errorMessage(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let notice = store.notice {
                    Label(notice.message(in: language), systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(accentInk)
                } else {
                    Text(language.text("stage.\(card.stage.rawValue).next"))
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

    private func errorMessage(_ error: Error) -> some View {
        let message: String
        if case HandoffCommand.Failure.pythonUnavailable? = error as? HandoffCommand.Failure {
            message = language.text("error.python")
        } else {
            message = language.text("error.operation")
        }
        return Text(message)
            .help(error.localizedDescription)
            .accessibilityHint(error.localizedDescription)
    }

    @ViewBuilder
    private func primaryAction(_ card: HandoffCard) -> some View {
        if card.stage == .review {
            Button { confirming = card } label: {
                Label(language.text("approval.open"), systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.busy)
        } else {
            Button { store.copy(card) } label: {
                Label(language.text("stage.\(card.stage.rawValue).copy"), systemImage: "document.on.document")
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
            Label(language.text("cards.new"), systemImage: "square.and.pencil")
                .font(.title2.weight(.semibold))
                .foregroundStyle(accentInk)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 7) {
                Text(language.text("card.title")).font(.subheadline.weight(.semibold))
                TextField(language.text("card.title.placeholder"), text: $title)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .accessibilityLabel(language.text("card.title"))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(language.text("card.criteria")).font(.subheadline.weight(.semibold))
                editor($goal, label: language.text("card.criteria"), font: .body, height: 88)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(language.text("card.files")).font(.subheadline.weight(.semibold))
                Text(language.text("card.files.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                editor($paths, label: language.text("card.files.input"), font: .body.monospaced(), height: 70)
            }
            Divider()
            HStack {
                Spacer()
                Button(language.text("action.cancel")) { composing = false }
                    .keyboardShortcut(.cancelAction)
                Button(language.text("cards.create")) {
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
