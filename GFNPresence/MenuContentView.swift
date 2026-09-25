import SwiftUI
import AppKit

struct MenuContentView: View {
    @Bindable var controller: PresenceController

    @State private var searchText = ""
    @State private var customTitle = ""
    @State private var isEditingCustom = false
    @State private var isEditingFallbackId = false
    @State private var fallbackDraft = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case search, custom, fallbackId
    }

    private var filteredGames: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return controller.libraryGames }
        return controller.libraryGames.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuDivider()
            nowPlaying
            MenuDivider()
            gamePicker
            MenuDivider()
            settings
            MenuDivider()
            MenuRow(title: "Quit GFN Presence", shortcut: "⌘Q") {
                controller.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(5)
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("GFN Presence")
                .font(.headline)
            Spacer()
            Toggle("Rich Presence", isOn: Binding(
                get: { controller.isEnabled },
                set: { newValue in
                    controller.isEnabled = newValue
                    controller.recomputePresence()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 9)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: - Now Playing

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Now Playing")

            HStack(spacing: 10) {
                GameArtwork(url: controller.isEnabled ? controller.currentArtworkURL : nil,
                            symbol: artworkSymbol)

                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlayingTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(nowPlayingSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let status = discordStatusLabel {
                        status
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 4)
        }
    }

    private var artworkSymbol: String {
        if !controller.isEnabled { return "eye.slash" }
        return controller.currentTitle == nil ? "gamecontroller" : "gamecontroller.fill"
    }

    private var nowPlayingTitle: String {
        if !controller.isEnabled { return "Presence Off" }
        return controller.currentTitle ?? "Not Playing"
    }

    private var nowPlayingSubtitle: String {
        if !controller.isEnabled {
            if let hidden = controller.pendingTitle {
                return "\(hidden) is hidden from Discord."
            }
            return "Discord won’t see what you play."
        }
        if controller.currentTitle == nil {
            return "Start a game in GeForce NOW."
        }
        return controller.isManual ? "Set manually" : "Detected automatically"
    }

    private var discordStatusLabel: StatusLine? {
        guard controller.isEnabled else { return nil }
        switch controller.discordStatus {
        case .idle:
            return nil
        case .connecting:
            return StatusLine(color: .secondary, text: "Connecting to Discord…")
        case .connected:
            return StatusLine(color: .green, text: "Visible on Discord")
        case .needsFallbackId:
            return StatusLine(color: .orange, text: "Needs a fallback application ID")
        case .error(let message):
            return StatusLine(color: .red, text: message)
        }
    }

    // MARK: - Game Picker

    private var gamePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Show a Different Game")

            SearchField(text: $searchText, prompt: "Search Library")
                .focused($focusedField, equals: .search)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

            if filteredGames.isEmpty {
                Text(controller.libraryGames.isEmpty
                     ? "Your library appears after GeForce NOW opens."
                     : "No Matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredGames, id: \.self) { title in
                            MenuRow(
                                title: title,
                                isChecked: controller.isManual && controller.manualOverride?.title == title
                            ) {
                                controller.setManualGame(title: title)
                                searchText = ""
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(CGFloat(filteredGames.count) * 24, 288))
            }

            if isEditingCustom {
                HStack(spacing: 6) {
                    TextField("Game Title", text: $customTitle)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .custom)
                        .onSubmit(submitCustom)
                        .onExitCommand { isEditingCustom = false }
                    Button("Show", action: submitCustom)
                        .disabled(customTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
            } else {
                MenuRow(title: "Custom Title…", systemImage: "pencil") {
                    isEditingCustom = true
                    focusedField = .custom
                }
            }

            if controller.isManual {
                MenuRow(title: "Resume Automatic Detection", systemImage: "arrow.uturn.backward") {
                    controller.clearManualOverride()
                }
            }
        }
        .disabled(!controller.isEnabled)
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Launch at Login")
                Spacer()
                Toggle("Launch at Login", isOn: $controller.launchesAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)

            MenuRow(
                title: "Fallback Application ID…",
                trailingSymbol: isEditingFallbackId ? "chevron.down" : "chevron.right"
            ) {
                if !isEditingFallbackId {
                    fallbackDraft = controller.fallbackClientId == PresenceController.defaultFallbackClientId
                        ? ""
                        : controller.fallbackClientId
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    isEditingFallbackId.toggle()
                }
                if isEditingFallbackId { focusedField = .fallbackId }
            }

            if isEditingFallbackId {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField("Discord Application ID", text: $fallbackDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .focused($focusedField, equals: .fallbackId)
                            .onSubmit(saveFallbackId)
                            .onExitCommand { isEditingFallbackId = false }
                        Button("Save", action: saveFallbackId)
                            .disabled(!isValidApplicationId(fallbackDraft))
                    }
                    .controlSize(.small)
                    Text("Used for games Discord doesn’t recognize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Actions

    private func submitCustom() {
        let title = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        controller.setManualGame(title: title)
        customTitle = ""
        searchText = ""
        isEditingCustom = false
    }

    private func saveFallbackId() {
        let trimmed = fallbackDraft.trimmingCharacters(in: .whitespaces)
        guard isValidApplicationId(trimmed) else { return }
        controller.fallbackClientId = trimmed
        controller.recomputePresence()
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingFallbackId = false
        }
    }

    private func isValidApplicationId(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 17 && trimmed.allSatisfy(\.isNumber)
    }
}

// MARK: - Components

/// A row that behaves like a menu item: full-width hover highlight, optional checkmark and icon.
private struct MenuRow: View {
    var title: String
    var systemImage: String? = nil
    var isChecked: Bool = false
    var shortcut: String? = nil
    var trailingSymbol: String? = nil
    var action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 12)
                    .opacity(isChecked ? 1 : 0)
                    .accessibilityHidden(!isChecked)

                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                }

                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.secondary)
                }
                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 3)
            .padding(.trailing, 9)
            .frame(height: 24)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary)
                    .opacity(isHovered && isEnabled ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
    }
}

private struct StatusLine: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct GameArtwork: View {
    let url: URL?
    let symbol: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quinary)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
    }
}
