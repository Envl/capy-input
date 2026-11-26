import SwiftUI
import ServiceManagement

@main
struct CapyCompanionApp: App {
    init() {
        InterfaceLanguage.saved.apply()
    }

    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @AppStorage(MacAppDelegate.showMenuBarIconKey) private var showMenuBarIcon = false

    var body: some Scene {
        Window(MacAppDelegate.appName, id: "main") {
            SettingsView()
                .onChange(of: showMenuBarIcon) { _, visible in MacAppDelegate.setDockIconVisible(!visible) }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        }
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            CapyCompanionMenu()
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel(MacAppDelegate.appName)
        }
    }
}

struct SettingsView: View {
    @Environment(\.scenePhase) private var phase
    @AppStorage(InterfaceLanguage.preferenceKey) private var language = InterfaceLanguage.system
    @ObservedObject private var sync = LibraryStatus.shared
    @AppStorage(LearnedSyncService.key, store: LibraryCloud.settings) private var service = LearnedSyncService.icloud
    @AppStorage("server", store: DictionarySync.settings) private var endpoint = UserDefaults.standard.string(forKey: "server") ?? DictionarySync.defaultServer
    @AppStorage("libraryCloudEnabled", store: LibraryCloud.settings) private var syncEnabled = true
    @State private var key = LearnedSyncService.serverSyncEnabled ? Secret.load() : ""
    @State private var savedKey = LearnedSyncService.serverSyncEnabled ? Secret.load() : ""
    private enum CredentialField { case endpoint, key }
    @FocusState private var credentialField: CredentialField?
    @ObservedObject private var screenWords = ScreenWordSuggestions.shared
    @ObservedObject private var autoSwitch = RimeAutoSwitch.shared
    @AppStorage(MacAppDelegate.showMenuBarIconKey) private var showMenuBarIcon = false
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @AppStorage("rimeInstallation") private var selectedInstallation = ""
    @State private var installations = RimeInstallation.discover()
    private var installation: RimeInstallation? { installations.first { $0.id == selectedInstallation } ?? installations.first }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.inputMethod) {
                    if installations.count > 1 {
                        Picker(L10n.inputMethod, selection: $selectedInstallation) {
                            ForEach(installations) { Text($0.name).tag($0.id) }
                        }
                    } else {
                        LabeledContent(L10n.inputMethod, value: installation?.name ?? L10n.noneDetected)
                    }
                    if let folder = installation?.dataDirectory {
                        LabeledContent(L10n.dataFolder, value: folder.path).textSelection(.enabled)
                    }
                    Toggle(L10n.screenWordSuggestions, isOn: Binding(
                        get: { screenWords.isEnabled },
                        set: { screenWords.setEnabled($0) }
                    ))
                    .alert(L10n.cannotCompleteThisChange, isPresented: Binding(
                        get: { screenWords.error != nil }, set: { if !$0 { screenWords.error = nil } }
                    )) {} message: { Text(screenWords.error ?? "") }
                    if screenWords.needsPermission {
                        Button(L10n.screenRecordingSettings) { screenWords.openScreenRecordingSettings() }
                    }
                    Toggle(L10n.autoSwitchEnZh, isOn: Binding(
                        get: { autoSwitch.isEnabled },
                        set: { autoSwitch.setEnabled($0) }
                    ))
                    .alert(L10n.cannotCompleteThisChange, isPresented: Binding(
                        get: { autoSwitch.error != nil }, set: { if !$0 { autoSwitch.error = nil } }
                    )) {} message: { Text(autoSwitch.error ?? "") }
                    if autoSwitch.isEnabled && autoSwitch.needsAccessibilityPermission {
                        Button(L10n.accessibilitySettings) { autoSwitch.openAccessibilitySettings() }
                    }
                }
                Section {
                    Toggle(L10n.showMenuBarIcon, isOn: $showMenuBarIcon)
                    Toggle(L10n.openAtLogin, isOn: Binding(
                        get: { loginStatus == .enabled },
                        set: { enabled in
                            let service = SMAppService.mainApp
                            do {
                                if enabled {
                                    if service.status != .requiresApproval { try service.register() }
                                    if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                                } else {
                                    try service.unregister()
                                }
                            } catch { loginError = error.localizedDescription }
                            loginStatus = service.status
                        }
                    ))
                    .alert(L10n.cannotCompleteThisChange, isPresented: Binding(
                        get: { loginError != nil }, set: { if !$0 { loginError = nil } }
                    )) {} message: { Text(loginError ?? "") }
                    Picker(selection: Binding(get: { language }, set: { choice in
                        choice.apply()
                        language = choice
                    })) {
                        ForEach(InterfaceLanguage.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    } label: {
                        Text(L10n.appLanguage)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("app-language-picker")
                }
                LibrarySection()
                Section {
                    Toggle(isOn: $syncEnabled) {
                        Text(L10n.sync)
                    }
                    .accessibilityLabel(L10n.sync)
                    .onChange(of: syncEnabled) { _, enabled in if enabled { Task { await sync.sync(force: true) } } }
                    Button {
                        credentialField = nil
                        saveCredentials()
                        Task { await sync.sync(force: true) }
                    } label: {
                        HStack(spacing: 12) {
                            Label(L10n.syncNow, systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if sync.busy { ProgressView() }
                        }
                    }
                    .disabled(sync.busy || !syncEnabled || (effectiveService == .server && !serverConfigured))
                    if effectiveService == .icloud {
                        LastSyncRow(key: "cloud-success-learned", hideEmpty: true)
                    } else if let client = serverClient {
                        LastSyncRow(key: client.lastSuccessKey, hideEmpty: true).id(client.lastSuccessKey)
                    }
                    if effectiveService == .icloud, syncEnabled, let conflict = sync.conflict {
                        Label(conflict.localizedDescription, systemImage: "exclamationmark.triangle")
                        Button(L10n.keepLocalCopy) { Task { await sync.resolve(useLocal: true) } }
                            .disabled(sync.busy)
                        Button(L10n.useCloudCopy) { Task { await sync.resolve(useLocal: false) } }
                            .disabled(sync.busy)
                    }
                    if LearnedSyncService.serverSyncEnabled {
                        syncOptions
                    }
                    ForEach(Array(Set([sync.resourceMessage, sync.learnedMessage].filter { !$0.isEmpty })).sorted(), id: \.self) {
                        Text($0).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.sync)
                }
            }
            .onAppear {
                if LearnedSyncService.serverSyncEnabled {
                    DictionarySync.settings.set(endpoint, forKey: "server")
                    key = Secret.load()
                    savedKey = key
                }
            }
            .onChange(of: credentialField) { previous, field in
                if previous == .key && key.isEmpty && !savedKey.isEmpty {
                    do { try Secret.save(""); savedKey = "" } catch { sync.learnedMessage = AppError.userMessage(for: error) }
                }
                if field == nil { saveCredentials() }
            }
            .onChange(of: service) { _, _ in sync.learnedMessage = ""; sync.resourceMessage = "" }
            .onSubmit { credentialField = nil }
            .navigationTitle(MacAppDelegate.appName)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                loginStatus = SMAppService.mainApp.status
                installations = RimeInstallation.discover()
                reloadKey()
                Task { await sync.sync() }
            }
            .formStyle(.grouped).frame(minWidth: 500, minHeight: 480)
        }
        .environment(\.locale, InterfaceLanguage.currentLocale)
        .id(language)
    }

    private var effectiveService: LearnedSyncService {
        LearnedSyncService.serverSyncEnabled ? service : .icloud
    }

    private var syncOptions: some View {
        Group {
            Picker(L10n.syncWith, selection: $service) {
                ForEach(LearnedSyncService.availableCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("learned-sync-service")
            if service == .server {
                TextField(L10n.serverURL, text: $endpoint).focused($credentialField, equals: .endpoint)
                SecureField(L10n.syncKey, text: $key).focused($credentialField, equals: .key)
            }
        }
    }

    private var serverClient: DictionarySync? {
        guard let url = URL(string: endpoint), let root = installation?.syncDirectory else { return nil }
        return DictionarySync(server: url, key: key, root: root)
    }
    private var serverConfigured: Bool { serverClient?.isConfigured == true }
    private func reloadKey() {
        guard LearnedSyncService.serverSyncEnabled else { return }
        let current = Secret.load()
        if key == savedKey { key = current }
        savedKey = current
    }
    private func saveCredentials() {
        guard LearnedSyncService.serverSyncEnabled, service == .server, serverConfigured else { return }
        do {
            if key != savedKey { try Secret.save(key); savedKey = key }
            UserDefaults.standard.set(endpoint, forKey: "server")
        } catch { sync.learnedMessage = AppError.userMessage(for: error) }
    }
}

private struct LastSyncRow: View {
    @AppStorage private var timestamp: Double

    var hideEmpty = false
    init(key: String, hideEmpty: Bool = false) {
        self.hideEmpty = hideEmpty
        _timestamp = AppStorage(wrappedValue: UserDefaults.standard.double(forKey: key), key, store: DictionarySync.settings)
    }

    var body: some View {
        let value = timestamp > 0
            ? Date(timeIntervalSince1970: timestamp).formatted(Date.FormatStyle(date: .abbreviated, time: .standard, locale: InterfaceLanguage.currentLocale))
            : L10n.noSyncRecorded
        if !hideEmpty || timestamp > 0 {
            LabeledContent(L10n.lastSynced, value: value)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.lastSynced)
                .accessibilityValue(value)
                .accessibilityIdentifier("last-sync")
        }
    }
}
