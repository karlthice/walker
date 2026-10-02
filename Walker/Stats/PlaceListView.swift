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
    @State private var progress: (done: Int, total: Int)?
    @State private var error: String?

    var body: some View {
        List {
            if let progress, progress.done < progress.total {
                Section {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text("Looking up places…")
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
                        if place.childCount > 0, case .country = scope {
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
        case .city: "OpenStreetMap has no neighbourhoods for this city."
        }
    }

    private var footer: String {
        var text = "Boundaries © OpenStreetMap contributors."
        if case .city = scope, places?.contains(where: { $0.fraction == nil }) == true {
            text = "Neighbourhoods here are mapped as points without boundaries, so each explored spot counts for the nearest one and no percentage is shown. " + text
        }
        return text
    }

    private func load() async {
        let resolver = PlaceResolver.shared
        error = nil
        switch scope {
        case .country(let country):
            places = try? await resolver.cityStats(country: country.code)
            guard let index = CountryIndex.shared else { return }
            do {
                try await resolver.resolve(country: country.code, countries: index) { done, total in
                    await MainActor.run {
                        progress = (done, total)
                    }
                    // Refresh the list as places come in, without querying after every tile.
                    if done == total || done % 10 == 0 {
                        let updated = try? await resolver.cityStats(country: country.code)
                        await MainActor.run { places = updated }
                    }
                }
                places = try await resolver.cityStats(country: country.code)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
        case .city(let city):
            places = (try? await resolver.neighbourhoodStats(city: city.id)) ?? []
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
