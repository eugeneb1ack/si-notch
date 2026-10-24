import SwiftUI
import AppKit
import SINotchCore

private struct SessionHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension AgentStatus {
    var label: String {
        switch self { case .idle: return L10n.tr("На связи"); case .working: return L10n.tr("В работе"); case .waiting: return L10n.tr("Ждёт ответа"); case .approval: return L10n.tr("Нужно разрешение"); case .completed: return L10n.tr("Готово"); case .failed: return L10n.tr("Ошибка"); case .ended: return L10n.tr("Завершена") }
    }
    var tint: Color {
        switch self { case .working: return Color(red: 0.40, green: 0.89, blue: 0.56); case .approval, .waiting: return .orange; case .failed: return Color(red: 1, green: 0.47, blue: 0.43); case .completed: return Color(red: 0.48, green: 0.79, blue: 1); default: return .gray }
    }
    var symbol: String {
        switch self { case .idle: return "circle.dotted"; case .working: return "waveform"; case .waiting: return "bubble.left"; case .approval: return "hand.raised"; case .completed: return "checkmark"; case .failed: return "exclamationmark.triangle"; case .ended: return "stop" }
    }
}

struct IslandView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appLanguage") var appLanguage = "auto"
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage("showCompanion") var showCompanion = true
    @AppStorage("shortcutModifier") var shortcutModifier = "ctrlAlt"
    @AppStorage("shortcutEnabled") var shortcutEnabled = true
    var shortcutLabel: String { shortcutEnabled ? L10n.tr(shortcutModifier == "ctrlShiftAlt" ? "settings.shortcut.ctrlShiftAlt" : "settings.shortcut.ctrlAlt") : "" }
    var body: some View {
        let _ = appLanguage
        GeometryReader { viewport in
            let compactHeight = model.compactHeight
            let compactWidth = model.cameraWidth + model.compactWingWidth + model.compactStatusWidth + 2 * model.compactShoulderWidth
            let expansion = Self.revealProgress(viewport: viewport.size, compactWidth: compactWidth,
                                                expandedWidth: model.expandedPanelWidth)
            let droplet = reduceMotion ? 0 : sin(expansion * .pi)
            let reveal = min(1, max(0, (expansion - 0.12) / 0.60))
            let contentOpacity = reveal * reveal * (3 - 2 * reveal)
            ZStack(alignment: model.trailingSurface ? .topTrailing : .top) {
                // The native frame includes one point of top bleed. Do not keep
                // the expanded hierarchy alive for that compact-only pixel.
                if model.expanded || viewport.size.height > compactHeight + 1.5 {
                    // Lay out the content once at its destination width. The native
                    // window reveals it; shrinking text during the transition causes
                    // line wrapping and makes the header visibly jump.
                    expandedContent
                        .frame(width: model.expandedPanelWidth, height: model.expandedPanelHeight, alignment: .top)
                        .opacity(contentOpacity)
                        .allowsHitTesting(model.expanded)
                        .accessibilityHidden(!model.expanded)
                }
                if !model.expanded || expansion < 0.72 {
                    compactContent.frame(width: compactWidth, height: compactHeight)
                        .opacity(1 - contentOpacity)
                        .allowsHitTesting(!model.expanded)
                        .accessibilityHidden(model.expanded)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
            .clipped()
            .foregroundStyle(.white)
            .background(IslandAppearanceSurface())
            .overlay(alignment: .bottom) { if model.paused { Rectangle().fill(.orange).frame(height: 2) } }
            // The silhouette follows the same live geometry as the window.
            // Switching these radii with the boolean state caused a corner pop
            // before the first animation frame and again on fast reversal.
            .clipShape(IslandSilhouette(shoulder: model.compactShoulderWidth + (14 - model.compactShoulderWidth) * expansion,
                                       bottomRadius: model.floatingSurface ? 15 + 9 * expansion : 13 + 11 * expansion + 6 * droplet,
                                       droplet: droplet * 0.5, floating: model.floatingSurface))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: L10n.language))
        .onExitCommand { model.setExpanded(false) }
        .onMoveCommand { direction in
            if direction == .down { model.moveSelection(1) }
            else if direction == .up { model.moveSelection(-1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("si-notch, %@", L10n.count("sessions", model.sessions.count)))
    }

    static func revealProgress(viewport: CGSize, compactWidth: CGFloat, expandedWidth: CGFloat) -> CGFloat {
        // Width tracks compact ↔ expanded motion. Height also changes while an
        // already open group/card resizes; using it would reopen the outline and
        // fade the content every time the destination height changes.
        min(1, max(0, (viewport.width - compactWidth) / max(1, expandedWidth - compactWidth)))
    }

    var compactContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if model.paused {
                    Image(systemName: "pause.fill").foregroundStyle(.orange)
                } else if showCompanion {
                    CompanionView(status: model.dominantStatus, size: 20, interactive: false).allowsHitTesting(false)
                } else {
                    Image(systemName: model.dominantStatus.symbol).foregroundStyle(model.dominantStatus.tint)
                }
            }.padding(.horizontal, 3).frame(width: model.compactWingWidth)
            Color.clear.frame(width: model.cameraWidth)
            Group {
                if model.sessions.isEmpty { Circle().fill(model.dominantStatus.tint).frame(width: 5, height: 5) }
                else {
                    Text(model.sessions.count > 99 ? "99+" : "\(model.sessions.count)")
                        .monospacedDigit().font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.dominantStatus.tint).lineLimit(1).minimumScaleFactor(0.8)
                }
            }.frame(width: model.compactStatusWidth)
        }
        .padding(.horizontal, model.compactShoulderWidth)
        .font(.system(size: 11))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.setExpanded(true) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("Открыть si-notch, %@, %@", L10n.count("sessions", model.sessions.count), model.dominantStatus.label))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.setExpanded(true) }
        .help(shortcutLabel)
    }

    var expandedContent: some View {
        VStack(spacing: 0) {
            HStack {
                if model.showAgents {
                    Text(L10n.tr("agents.title")).font(.system(size: 11, weight: .medium)).foregroundStyle(NotchDesign.secondary)
                } else if !model.sessions.isEmpty {
                    HStack(spacing: 6) {
                        if showCompanion { CompanionView(status: model.dominantStatus, size: 22) }
                        Text(model.paused ? L10n.tr("Приём событий на паузе") : L10n.count("sessions", model.sessions.count))
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }.foregroundStyle(NotchDesign.secondary)
                }
                Spacer(minLength: model.cameraWidth)
                Button { model.openUsage?(nil) } label: { Image(systemName: "chart.bar").font(.system(size: 12)) }
                    .buttonStyle(IslandGlassButtonStyle()).controlSize(.small).help(L10n.tr("settings.usage")).accessibilityLabel(L10n.tr("settings.usage"))
                Button { model.openSettings?() } label: { Image(systemName: "gearshape").font(.system(size: 12)) }.buttonStyle(IslandGlassButtonStyle()).controlSize(.small).help(L10n.tr("Настройки")).accessibilityLabel(L10n.tr("Настройки"))
                Button { model.setExpanded(false) } label: { Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)) }.buttonStyle(IslandGlassButtonStyle()).controlSize(.small).padding(.leading, 4).help(L10n.tr("Свернуть")).accessibilityLabel(L10n.tr("Свернуть панель"))
            }
            .frame(height: model.headerHeight).padding(.horizontal, 20)
            // Navigation stays at the top while either tab adapts its height.
            navigation
            if let error = model.serverError {
                Label(error.text, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 22).padding(.bottom, 10)
            }
            VStack(spacing: 0) {
                if model.showAgents { agentsList } else {
                    if !model.showingHistory && (model.sessions.count > 3 || !model.search.isEmpty) {
                        TextField(L10n.tr("Поиск сессий"), text: $model.search).textFieldStyle(.plain).font(.system(size: 12)).padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 20).padding(.bottom, 10)
                    }
                    HStack(spacing: 5) {
                        ForEach(["Все", "В работе", "Внимание", "Готово", "history.title"], id: \.self) { filter in
                            Button { model.activeFilter = filter } label: {
                                Text(L10n.tr(filter)).font(.system(size: 10, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(model.activeFilter == filter ? .white.opacity(0.14) : .clear, in: Capsule())
                                    .foregroundStyle(model.activeFilter == filter ? .white : NotchDesign.secondary)
                            }.buttonStyle(.plain).accessibilityAddTraits(model.activeFilter == filter ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 20).padding(.bottom, 10)
                    if model.showingHistory { HistoryView(history: model.history, usage: model.usage, openUsage: { model.openUsage?($0) }) }
                    else if model.sessions.isEmpty { emptyState }
                    else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(model.filtered) { session in
                                    SessionCard(session: session, model: model)
                                        .background(GeometryReader { geometry in
                                            Color.clear.preference(key: SessionHeightPreferenceKey.self,
                                                value: [session.id: geometry.size.height])
                                        })
                                }
                                if model.filtered.isEmpty { Text(L10n.tr("Здесь пока нет сессий")).font(.system(size: 12)).foregroundStyle(.secondary).padding(30) }
                            }.padding(.horizontal, 16).padding(.bottom, 14)
                        }.scrollIndicators(.hidden)
                        .id(model.activeFilter + "\0" + model.search)
                        .onPreferenceChange(SessionHeightPreferenceKey.self) { model.measureSessionCards($0) }
                    }
                    if !model.showingHistory && (model.quiet || model.sessions.contains(where: { $0.status == .completed || $0.status == .failed })) {
                        HStack(spacing: 6) {
                            if model.quiet { Label(L10n.tr("Тихий режим"), systemImage: "moon.fill").font(.system(size: 10)) }
                            Spacer()
                            if model.sessions.contains(where: { $0.status == .completed || $0.status == .failed }) {
                                Button { model.clearFinished() } label: { Text(L10n.tr("Убрать готовые")).font(.system(size: 11)) }.buttonStyle(.plain)
                            }
                        }.foregroundStyle(NotchDesign.muted).padding(.horizontal, 22).padding(.bottom, 12)
                    }
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        }
    }
    var navigation: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 20)
            HStack(spacing: 4) {
                navigationTab(title: L10n.tr("agents.sessions"), symbol: "list.bullet", agents: false)
                navigationTab(title: L10n.tr("agents.title"), symbol: "terminal", agents: true)
            }.padding(.horizontal, 16).frame(height: 39)
        }
    }
    func navigationTab(title: String, symbol: String, agents: Bool) -> some View {
        Button {
            model.selectAgents(agents)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                if agents {
                    Text(L10n.tr("agents.onlineCount", model.agents.filter { $0.state == .online }.count))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(NotchDesign.muted)
                        .help(L10n.tr("agents.presenceHelp"))
                }
            }.font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 27)
                .foregroundStyle(model.showAgents == agents ? .white : NotchDesign.secondary)
                .background(model.showAgents == agents ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(model.showAgents == agents ? .isSelected : [])
    }
    var agentsList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.agents.filter { $0.connectorID == nil }) { agent in agentRow(agent) }
                    ForEach(model.remoteConnections.connections.filter(\.showInAgents)) { connection in
                        let profiles = model.agents.filter { $0.connectorID == connection.id }
                        DisclosureGroup(isExpanded: Binding(get: { model.expandedConnectors.contains(connection.id) }, set: {
                            model.setConnectorExpanded(connection.id, $0)
                        })) {
                            VStack(spacing: 0) {
                                ForEach(profiles) { agent in agentRow(agent).padding(.leading, 12) }
                                if profiles.isEmpty {
                                    Text(L10n.tr("remote.noProfiles")).font(.system(size: 11))
                                        .foregroundStyle(NotchDesign.secondary).frame(height: 32)
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "network").frame(width: 16)
                                Text(connection.displayName).fontWeight(.medium).lineLimit(1)
                                Spacer()
                                Text(L10n.tr("remote.sshState", model.remoteConnections.state(connection.id).label))
                                    .foregroundStyle(NotchDesign.secondary)
                                Text("\(profiles.count)").foregroundStyle(NotchDesign.secondary)
                                Button { model.openRemoteConnections?() } label: { Image(systemName: "gearshape") }
                                    .buttonStyle(.plain).help(L10n.tr("remote.settingsTab"))
                                Circle().fill(model.remoteConnections.state(connection.id) == .connected ? Color.green : Color.gray.opacity(0.5))
                                    .frame(width: 5, height: 5)
                            }.font(.system(size: 11)).frame(height: 32)
                        }.padding(.horizontal, 24).tint(NotchDesign.secondary)
                            .transaction { $0.animation = nil; $0.disablesAnimations = true }
                            .accessibilityIdentifier("agent-connection-" + connection.id.uuidString)
                    }
                    if model.agents.isEmpty && !model.remoteConnections.connections.contains(where: \.showInAgents) {
                        Text(L10n.tr("agents.empty")).font(.system(size: 12)).foregroundStyle(NotchDesign.secondary).frame(height: 56)
                    }
                }
            }.scrollIndicators(.hidden)
            Button { model.openIntegrations?() } label: {
                Text(L10n.tr("agents.manage")).font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).frame(height: 36)
            }.buttonStyle(.plain).foregroundStyle(NotchDesign.secondary)
        }.padding(.top, 8).padding(.bottom, 8)
    }
    private func agentRow(_ agent: AgentConnection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ProviderStyle(provider: agent.provider).symbol)
                .foregroundStyle(ProviderStyle(provider: agent.provider).color).frame(width: 16)
            Text(agent.name).fontWeight(.medium).lineLimit(1)
            Spacer()
            Circle().fill(agent.state == .online ? Color.green : Color.gray.opacity(0.5)).frame(width: 5, height: 5)
            Text(agent.state.label).foregroundStyle(NotchDesign.secondary)
                .help(L10n.tr("agents.presenceHelp"))
            Text("·").foregroundStyle(NotchDesign.muted)
            Text(agent.activity.label)
                .foregroundStyle(agent.activity == .attention ? .orange : agent.activity == .working ? .green : NotchDesign.secondary)
            if agent.activeTaskCount > 1 {
                Text("\(agent.activeTaskCount)").foregroundStyle(NotchDesign.secondary)
            }
        }.font(.system(size: 11)).padding(.horizontal, 24).frame(height: 32)
    }
    var emptyState: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center, spacing: 15) {
                if showCompanion { CompanionView(status: .idle, size: 58) }
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("Всё спокойно")).font(.system(size: 18, weight: .semibold))
                    Text(L10n.tr(model.agents.contains { $0.state == .online } ? "empty.ready" : "empty.description")).font(.system(size: 12)).foregroundStyle(NotchDesign.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 9) {
                if !model.agents.contains(where: { $0.state == .online }) {
                    Button { model.openIntegrations?() } label: { Label(L10n.tr("Подключить агента"), systemImage: "plus") }.buttonStyle(NotchActionButtonStyle(prominent: true))
                }
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SessionCard: View {
    let session: AgentSession
    @ObservedObject var model: AppModel
    @AppStorage("appLanguage") var appLanguage = "auto"
    @State private var promptExpanded = false
    @AppStorage("fontSize") var fontSize = 11.0
    @AppStorage("showModel") var showModel = true
    @AppStorage("showReasoning") var showReasoning = true
    @AppStorage("showProject") var showProject = true
    @AppStorage("showTasks") var showTasks = true
    @AppStorage("showSubagents") var showSubagents = true
    @AppStorage("showActivity") var showActivity = true
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var selected: Bool { model.selectedID == session.id || model.pending[session.id] != nil }
    var needsAgentResponse: Bool {
        [.waiting, .approval].contains(session.status) && session.lastEventID?.hasPrefix("interaction-submitted:") != true
    }
    var providerStyle: ProviderStyle { ProviderStyle(provider: session.provider.lowercased() == "codex" && session.isWorkSession == true ? "work" : session.provider) }
    var content: SessionCardContent {
        SessionCardContent(session: session, displayTitle: model.displayTitle(session),
                           displayMessage: session.lastMessage.map { model.displayMessage(session, $0) }, statusLabel: session.status.label)
    }
    var body: some View {
        let _ = appLanguage
        let info = content
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Button { model.activateSession(session) } label: {
                    HStack(alignment: .top, spacing: 11) {
                        Circle().fill(session.status.tint).frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(info.primaryTitle).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.94))
                                .lineLimit(selected ? 3 : 2).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Label(info.providerName, systemImage: providerStyle.symbol)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(providerStyle.color).lineLimit(1)
                                if showProject, let project = info.projectName, !info.projectIsTitle {
                                    Text("·").foregroundStyle(NotchDesign.muted)
                                    Label(project, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                Text(session.updatedAt, style: .relative).font(.system(size: 9)).lineLimit(1).foregroundStyle(NotchDesign.muted)
                            }.font(.system(size: 10)).foregroundStyle(NotchDesign.secondary)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("session.open", info.providerName, info.primaryTitle))
                    .accessibilityIdentifier("open-session-" + session.id)
                    .help(L10n.tr(model.isRemoteSession(session) ? "session.remote" : "session.openApp"))
                Button {
                    model.selectSession(selected ? nil : session.id)
                } label: {
                    Image(systemName: selected ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(NotchDesign.muted)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("%@, %@, %@. Подробнее", info.providerName, info.primaryTitle, session.status.label))
                    .accessibilityIdentifier("session-details-" + session.id)
            }
            HStack(spacing: 6) {
                ZStack {
                    if session.status == .working { PixelTerminalIndicator(color: providerStyle.color).transition(.opacity) }
                    else { Image(systemName: session.status.symbol).font(.system(size: 10, weight: .medium)).transition(.opacity) }
                }.frame(width: 14, height: 15).animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.status)
                Text(session.status.label).font(.system(size: 10, weight: .medium)).contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.status)
                if info.isMemoryService {
                    Label(L10n.tr("session.serviceMemory"), systemImage: "brain")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(NotchDesign.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.07), in: Capsule())
                        .help(L10n.tr("session.serviceMemoryHelp"))
                }
                if showActivity, let tool = info.tool {
                    Text("·").foregroundStyle(NotchDesign.muted)
                    Label(tool, systemImage: info.toolSymbol).font(.system(size: 10, design: .monospaced))
                        .lineLimit(1).foregroundStyle(NotchDesign.secondary)
                }
                Spacer()
                if showTasks, !session.tasks.isEmpty {
                    Label("\(session.tasks.filter(\.completed).count)/\(session.tasks.count)", systemImage: "checklist")
                        .font(.system(size: 9)).foregroundStyle(NotchDesign.secondary)
                }
                if showSubagents, !session.subagents.isEmpty { Label("\(session.subagents.count)", systemImage: "person.2").font(.system(size: 9)).foregroundStyle(NotchDesign.secondary) }
            }.foregroundStyle(session.status.tint)
                .contentShape(Rectangle()).onTapGesture { model.activateSession(session) }
            if (showModel && info.modelName != nil) || (showReasoning && info.reasoningEffort != nil) {
                HStack(spacing: 10) {
                    if showModel, let name = info.modelName { Label(name, systemImage: "cpu").help(name) }
                    if showReasoning, let effort = info.reasoningEffort { Label(effort, systemImage: "brain").help(effort) }
                }.font(.system(size: max(10, min(16, fontSize)) - 1))
                    .foregroundStyle(NotchDesign.secondary).lineLimit(1).truncationMode(.middle)
            }
            if !selected, showActivity, let summary = info.summary, model.pending[session.id] == nil {
                Text(summary).font(.system(size: max(10, min(16, fontSize)))).foregroundStyle(NotchDesign.secondary)
                    .lineSpacing(2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture { model.activateSession(session) }
            }
            if model.navigationErrorID == session.id {
                Label(L10n.tr(model.navigationNoticeKey ?? "session.openFailed"), systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !model.interactions(for: session.id).isEmpty {
                let requests = model.interactions(for: session.id)
                ForEach(requests) { request in
                    AgentInteractionView(model: model, request: request, providerName: info.providerName,
                        canOpenAgent: !model.defaults.bool(forKey: "disableClickJump") && !model.isRemoteSession(session) && SessionDestination.resolve(session) != nil, openAgent: { model.jump(session) })
                }
            } else if model.pending[session.id] == nil && needsAgentResponse {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr(session.status == .approval ? "interaction.approvalInAgent" : "interaction.answerInAgent", info.providerName))
                        .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if !model.defaults.bool(forKey: "disableClickJump"), SessionDestination.resolve(session) != nil {
                        Button(L10n.tr("interaction.openAgent", info.providerName)) { model.jump(session) }
                            .buttonStyle(NotchActionButtonStyle(prominent: true))
                            .accessibilityIdentifier("respond-in-agent-" + session.id)
                    } else {
                        Text(L10n.tr("interaction.openManually", info.providerName)).font(.system(size: 11))
                            .foregroundStyle(NotchDesign.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if selected {
                let tokenRow = model.usage.task(session: UsageSession.key(provider: session.provider, connection: session.connectionID, session: session.id), turn: session.turnID)
                Button { model.openUsage?(tokenRow?.id ?? UsageSession.key(provider: session.provider, connection: session.connectionID, session: session.id)) } label: {
                    HStack {
                        Label(L10n.tr("task.tokens"), systemImage: "chart.bar")
                        Spacer()
                        Text(tokenRow?.counts.map { TokenFormat.compact($0.total) } ?? "—").monospacedDigit()
                        if tokenRow?.partial == true { Image(systemName: "info.circle").help(L10n.tr("tokens.partial")) }
                        Image(systemName: "chevron.right")
                    }.font(.system(size: 11)).foregroundStyle(NotchDesign.secondary)
                        .padding(9).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityIdentifier("session-usage-" + session.id)
                if showActivity, let message = info.message, model.pending[session.id] == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr(session.status == .completed || session.status == .failed ? "session.lastResult" : "session.latestUpdate"))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(NotchDesign.muted)
                        Text(message).font(.system(size: max(10, min(16, fontSize)))).foregroundStyle(NotchDesign.secondary)
                            .lineSpacing(3).lineLimit(5).textSelection(.enabled)
                    }.padding(.top, 2)
                }
                if let prompt = info.taskPrompt {
                    DisclosureGroup(isExpanded: $promptExpanded) {
                        Text(prompt).font(.system(size: max(10, min(16, fontSize)))).foregroundStyle(NotchDesign.secondary)
                            .lineSpacing(3).lineLimit(6).textSelection(.enabled)
                    } label: {
                        Text(L10n.tr("session.task")).font(.system(size: 10, weight: .medium)).foregroundStyle(NotchDesign.muted)
                    }.tint(NotchDesign.muted).padding(.top, 2)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                }
                if showTasks, !session.tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.tasks.prefix(12), id: \.id) { task in Label(task.title, systemImage: task.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 10)).foregroundStyle(task.completed ? session.status.tint : .white.opacity(0.5)).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
                    }.padding(.top, 2)
                }
                if showSubagents, !session.subagents.isEmpty {
                    ForEach(session.subagents.prefix(12), id: \.id) { child in HStack { Image(systemName: "arrow.turn.down.right"); Text(child.name).lineLimit(2); Spacer(); Text(child.status.label).foregroundStyle(child.status.tint).lineLimit(1) }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)) }
                }
                if showActivity, let history = model.activity[session.id], history.count > 1 {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.tr("session.activity.title")).font(.system(size: 10, weight: .medium)).foregroundStyle(NotchDesign.muted)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(history.reversed()) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(item.timestamp, style: .time).foregroundStyle(NotchDesign.muted).frame(width: 58, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.label).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                                            if let message = item.message, info.message?.hasPrefix(message) != true {
                                                Text(message).foregroundStyle(NotchDesign.secondary).lineLimit(3)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.font(.system(size: 10, design: .monospaced))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }.padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                if showProject, let path = session.projectPath {
                    Label(path, systemImage: "folder").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NotchDesign.muted).lineLimit(1).truncationMode(.middle).help(path)
                }
                if let usage = session.usage {
                    if let used = usage.usedPercent {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(L10n.tr("Использовано")); Spacer(); Text("\(Int(used))%") }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                            ProgressView(value: min(100, max(0, used)), total: 100).tint(used > 85 ? .orange : providerStyle.color)
                        }
                    }
                }
                if model.pending[session.id] == nil {
                    HStack {
                        Button { model.jump(session) } label: { Label(session.status == .approval || session.status == .waiting ? L10n.tr("Ответить в агенте") : L10n.tr("Открыть"), systemImage: "arrow.up.forward") }.buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(session.status == .approval || session.status == .waiting ? session.status.tint : providerStyle.color)
                            .disabled(model.defaults.bool(forKey: "disableClickJump"))
                        Spacer()
                        Button { model.dismiss(session.id) } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(NotchDesign.muted).help(L10n.tr("Убрать сессию")).accessibilityLabel(L10n.tr("Убрать сессию %@", session.title))
                    }.padding(.top, 2)
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 11).fill(providerStyle.color.opacity(selected ? 0.07 : 0.025)))
        .overlay {
            if session.status == .approval || model.pending[session.id] != nil {
                RoundedRectangle(cornerRadius: 11).strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.75)
            } else if selected {
                RoundedRectangle(cornerRadius: 11).strokeBorder(providerStyle.color.opacity(0.22), lineWidth: 0.75)
            }
        }
        .overlay(alignment: .bottom) {
            if !selected { Rectangle().fill(.white.opacity(0.055)).frame(height: 0.5).padding(.horizontal, 13) }
        }
    }
}
