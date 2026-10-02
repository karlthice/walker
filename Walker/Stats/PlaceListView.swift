import SwiftUI

/// The places one level down from a country (cities) or from a city or district, with the
/// area explored in each. Boundaries come from OpenStreetMap, looked up the first time needed.
struct PlaceListView: View {
    enum Scope: Hashable {
        case country(CountryStat)
        /// A place and its own level.
        case place(PlaceStat, PlaceLevel)

        var title: String {
            switch self {
            case .country(let country): [country.flag, country.name].compactMap { $0 }.joined(separator: " ")
            case .place(let place, _): place.name
            }
        }

        var name: String {
            switch self {
            case .country(let country): country.name
            case .place(let place, _): place.name
            }
        }

        var exploredArea: Double {
            switch self {
            case .country(let country): country.exploredArea
            case .place(let place, _): place.exploredArea
            }
        }

        /// The level listed; a city without districts lists its neighbourhoods instead.
        var childLevel: PlaceLevel? {
            switch self {
            case .country: .city
            case .place(_, let level): level.below
            }
        }
    }

    let scope: Scope

    @State private var places: [PlaceStat]?
    @State private var listedLevel: PlaceLevel?
    @State private var progress: ResolveProgress?
    @State private var error: String?

    var body: some View {
        List {
            if let progress, progress.done < progress.total {
                Section {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text(progress.status ?? "Looking up places…")
                    } currentValueLabel: {
                        Text("\(progress.done) of \(progress.total) map tiles")
                    }
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Try again") { Task { await load() } }
                }
            }

            Section {
                if let places {
                    if places.isEmpty && progress == nil && error == nil {
                        Text("OpenStreetMap has no smaller places here.")
                            .foregroundStyle(.secondary)
                    }
                    let level = listedLevel ?? scope.childLevel
                    ForEach(places) { place in
                        // Only a place with a boundary can have places found inside it.
                        if let level, level.below != nil, place.totalArea > 0 {
                            NavigationLink(value: Scope.place(place, level)) { PlaceRow(place: place) }
                        } else {
                            PlaceRow(place: place)
                        }
                    }
                    let elsewhere = scope.exploredArea - places.reduce(0) { $0 + $1.exploredArea }
                    // Ignore rounding noise; show only a meaningful remainder.
                    if elsewhere > max(scope.exploredArea * 0.01, 100) {
                        HStack {
                            Text("Elsewhere in \(scope.name)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(StatsView.formatArea(elsewhere))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text(sectionTitle)
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle(scope.title)
        .task { await load() }
        .refreshable { await load() }
    }

    private var sectionTitle: String {
        switch listedLevel ?? scope.childLevel {
        case .city: "Cities and municipalities"
        case .district: "Districts"
        case .neighbourhood, nil: "Neighbourhoods"
        }
    }

    private var footer: String {
        var text = "Boundaries © OpenStreetMap contributors."
        if places?.contains(where: { $0.fraction == nil }) == true {
            text = "Places OpenStreetMap has only as a point, without a boundary, show the area explored but no percentage. " + text
        }
        return text
    }

    private func load() async {
        let resolver = PlaceResolver.shared
        error = nil
        do {
            switch scope {
            case .country(let country):
                places = try await resolver.cityStats(country: country.code)
                guard let index = CountryIndex.shared else { return }
                try await resolver.resolveCities(country: country.code, countries: index) { update in
                    await show(update) { try? await resolver.cityStats(country: country.code) }
                }
                places = try await resolver.cityStats(country: country.code)
            case .place(let place, _):
                guard var level = scope.childLevel else { return }
                while true {
                    let current = level
                    listedLevel = current
                    places = try await resolver.childStats(of: place.id, level: current)
                    try await resolver.resolveChildren(of: place.id, level: current) { update in
                        await show(update) { try? await resolver.childStats(of: place.id, level: current) }
                    }
                    let found = try await resolver.childStats(of: place.id, level: current)
                    // No places at this level here (Kanazawa has no districts): go one level down.
                    if found.isEmpty, let next = current.below {
                        level = next
                        continue
                    }
                    places = found
                    break
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        progress = nil
    }

    /// Shows progress, refreshing the list as places come in (not after every tile).
    private func show(_ update: ResolveProgress, refresh: () async -> [PlaceStat]?) async {
        progress = update
        if update.status == nil, update.done == update.total || update.done % 10 == 0, let updated = await refresh() {
            places = updated
        }
    }
}

private struct PlaceRow: View {
    let place: PlaceStat

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(place.name)
                if let english = place.englishName {
                    Text(english)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                if let fraction = place.fraction {
                    Text(fraction.formatted(.percent.precision(.significantDigits(2))))
                        .monospacedDigit()
                    Text(StatsView.formatArea(place.exploredArea))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(StatsView.formatArea(place.exploredArea))
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
