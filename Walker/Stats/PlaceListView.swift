import SwiftUI

/// Cities in a country, or neighbourhoods in a city, with the area explored in each.
/// Boundaries come from OpenStreetMap and are looked up the first time they're needed.
struct PlaceListView: View {
    enum Scope: Hashable {
        case country(CountryStat)
        case city(PlaceStat)

        var title: String {
            switch self {
            case .country(let country): country.name
            case .city(let city): city.name
            }
        }

        var exploredArea: Double {
            switch self {
            case .country(let country): country.exploredArea
            case .city(let city): city.exploredArea
            }
        }
    }

    let scope: Scope

    @Environment(LocationService.self) private var service
    @State private var places: [PlaceStat]?
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
                        Text(emptyText)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(places) { place in
                        if case .country = scope {
                            NavigationLink(value: Scope.city(place)) { PlaceRow(place: place) }
                        } else {
                            PlaceRow(place: place)
                        }
                    }
                    let elsewhere = scope.exploredArea - places.reduce(0) { $0 + $1.exploredArea }
                    // Ignore rounding noise; show only a meaningful remainder.
                    if elsewhere > max(scope.exploredArea * 0.01, 100) {
                        HStack {
                            Text("Elsewhere in \(scope.title)")
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
        switch scope {
        case .country: "Cities and municipalities"
        case .city: "Neighbourhoods"
        }
    }

    private var emptyText: String {
        switch scope {
        case .country: "No places found."
        case .city: "OpenStreetMap has no neighbourhoods here."
        }
    }

    private var footer: String {
        var text = "Boundaries © OpenStreetMap contributors."
        if case .city = scope, places?.contains(where: { $0.fraction == nil }) == true {
            text = "Some neighbourhoods here are mapped as points without boundaries, so they get the explored area around them and no percentage. " + text
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
            case .city(let city):
                places = try await resolver.neighbourhoodStats(city: city.id)
                try await resolver.resolveNeighbourhoods(city: city.id) { update in
                    await show(update) { try? await resolver.neighbourhoodStats(city: city.id) }
                }
                places = try await resolver.neighbourhoodStats(city: city.id)
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
