import SwiftUI
import Observation

// MARK: - Model

/// A sound stored on a Halcyon Instruments synthesizer.
struct Patch: Identifiable, Hashable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case bass, lead, pad, keys, texture, percussion

        var id: Self { self }
        var label: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .bass:       "waveform.path"
            case .lead:       "bolt.horizontal"
            case .pad:        "cloud"
            case .keys:       "pianokeys"
            case .texture:    "sparkles"
            case .percussion: "metronome"
            }
        }
    }

    let id: UUID
    var name: String
    var category: Category
    var bank: Character
    var slot: Int
    var author: String
    var isFavourite: Bool
    var lastPlayed: Date?
    /// Brightness of the sound, 0 (dark) to 1 (bright): drives the little meter.
    var brightness: Double

    var location: String { "\(bank)\(String(format: "%02d", slot))" }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case location = "Bank & slot"
    case name = "Name"
    case recent = "Recently played"

    var id: Self { self }
}

@Observable
@MainActor
final class PatchLibrary {
    private(set) var patches: [Patch]
    var query = ""
    var category: Patch.Category?
    var favouritesOnly = false
    var sortOrder: SortOrder = .location
    var selection: Patch.ID?

    init(patches: [Patch]) {
        self.patches = patches
    }

    var visible: [Patch] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let filtered = patches.filter { patch in
            (category == nil || patch.category == category)
                && (!favouritesOnly || patch.isFavourite)
                && (needle.isEmpty
                    || patch.name.localizedCaseInsensitiveContains(needle)
                    || patch.author.localizedCaseInsensitiveContains(needle)
                    || patch.location.caseInsensitiveCompare(needle) == .orderedSame)
        }

        switch sortOrder {
        case .location:
            return filtered.sorted { ($0.bank, $0.slot) < ($1.bank, $1.slot) }
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recent:
            return filtered.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
    }

    var selected: Patch? {
        patches.first { $0.id == selection }
    }

    func toggleFavourite(_ id: Patch.ID) {
        guard let index = patches.firstIndex(where: { $0.id == id }) else { return }
        patches[index].isFavourite.toggle()
    }

    func markPlayed(_ id: Patch.ID, at date: Date = .now) {
        guard let index = patches.firstIndex(where: { $0.id == id }) else { return }
        patches[index].lastPlayed = date
    }

    func counts() -> [Patch.Category: Int] {
        Dictionary(grouping: patches, by: \.category).mapValues(\.count)
    }
}

// MARK: - Views

struct PatchBrowserView: View {
    @State private var library: PatchLibrary

    init(library: PatchLibrary) {
        _library = State(initialValue: library)
    }

    var body: some View {
        NavigationSplitView {
            CategoryList(library: library)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            PatchList(library: library)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if let patch = library.selected {
                PatchDetail(patch: patch) {
                    library.toggleFavourite(patch.id)
                } onAudition: {
                    library.markPlayed(patch.id)
                }
            } else {
                ContentUnavailableView(
                    "No Patch Selected",
                    systemImage: "slider.horizontal.3",
                    description: Text("Choose a patch to see its details and audition it.")
                )
            }
        }
        .searchable(text: $library.query, prompt: "Name, author or slot (A07)")
    }
}

private struct CategoryList: View {
    @Bindable var library: PatchLibrary

    var body: some View {
        let counts = library.counts()
        List(selection: $library.category) {
            Section("Library") {
                Label("All Patches", systemImage: "square.grid.2x2")
                    .badge(library.patches.count)
                    .tag(Patch.Category?.none)
                Toggle(isOn: $library.favouritesOnly) {
                    Label("Favourites only", systemImage: "star")
                }
            }
            Section("Categories") {
                ForEach(Patch.Category.allCases) { category in
                    Label(category.label, systemImage: category.symbol)
                        .badge(counts[category, default: 0])
                        .tag(Optional(category))
                }
            }
        }
        .navigationTitle("Patches")
    }
}

private struct PatchList: View {
    @Bindable var library: PatchLibrary

    var body: some View {
        let rows = library.visible
        List(rows, selection: $library.selection) { patch in
            PatchRow(patch: patch)
                .contextMenu {
                    Button(patch.isFavourite ? "Remove from Favourites" : "Add to Favourites",
                           systemImage: patch.isFavourite ? "star.slash" : "star") {
                        library.toggleFavourite(patch.id)
                    }
                }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView.search(text: library.query)
            }
        }
        .toolbar {
            Picker("Sort", selection: $library.sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
        }
        .navigationTitle(library.category?.label ?? "All Patches")
        .navigationSubtitle("\(rows.count) shown")
    }
}

private struct PatchRow: View {
    let patch: Patch

    var body: some View {
        HStack(spacing: 12) {
            Text(patch.location)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(patch.name).font(.headline)
                Text(patch.author).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            BrightnessMeter(value: patch.brightness)
                .frame(width: 34, height: 10)
                .accessibilityLabel("Brightness \(Int(patch.brightness * 100)) percent")

            if patch.isFavourite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favourite")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Five small bars, lit from the left, like the meter on the front panel.
private struct BrightnessMeter: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            let bars = 5
            let gap: CGFloat = 2
            let width = (geo.size.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
            HStack(spacing: gap) {
                ForEach(0..<bars, id: \.self) { index in
                    let lit = Double(index) < (value * Double(bars)).rounded()
                    Capsule()
                        .fill(lit ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: width, height: geo.size.height * (0.5 + 0.1 * Double(index)))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
}

private struct PatchDetail: View {
    let patch: Patch
    let onToggleFavourite: () -> Void
    let onAudition: () -> Void

    @State private var isAuditioning = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Location", value: patch.location)
                LabeledContent("Category") {
                    Label(patch.category.label, systemImage: patch.category.symbol)
                }
                LabeledContent("Author", value: patch.author)
                LabeledContent("Last played") {
                    if let played = patch.lastPlayed {
                        Text(played, format: .relative(presentation: .named))
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Character") {
                Gauge(value: patch.brightness) {
                    Text("Brightness")
                } currentValueLabel: {
                    Text(patch.brightness, format: .percent.precision(.fractionLength(0)))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(patch.name)
        .toolbar {
            Button(action: onToggleFavourite) {
                Label("Favourite", systemImage: patch.isFavourite ? "star.fill" : "star")
            }
            Button {
                isAuditioning = true
                onAudition()
            } label: {
                Label("Audition", systemImage: "play.circle")
            }
            .keyboardShortcut(.space, modifiers: [])
        }
        .sensoryFeedback(.selection, trigger: isAuditioning)
    }
}

// MARK: - Preview

extension PatchLibrary {
    static var sample: PatchLibrary {
        let names: [(String, Patch.Category, String)] = [
            ("Glass Harbour", .pad, "Studio North"),
            ("Low Growl", .bass, "Factory"),
            ("Paper Lantern", .keys, "Studio North"),
            ("Signal Fire", .lead, "Factory"),
            ("Tin Roof Rain", .texture, "Field Kit"),
            ("Clockwork Rim", .percussion, "Field Kit"),
            ("Undertow", .bass, "Factory"),
            ("Slow Aurora", .pad, "Field Kit"),
        ]
        let patches = names.enumerated().map { index, entry in
            Patch(
                id: UUID(),
                name: entry.0,
                category: entry.1,
                bank: index < 4 ? "A" : "B",
                slot: index % 4 + 1,
                author: entry.2,
                isFavourite: index.isMultiple(of: 3),
                lastPlayed: index.isMultiple(of: 2) ? Date.now.addingTimeInterval(Double(-index) * 3_600) : nil,
                brightness: Double((index * 37) % 100) / 100
            )
        }
        return PatchLibrary(patches: patches)
    }
}

#Preview {
    PatchBrowserView(library: .sample)
        .frame(width: 960, height: 600)
}
