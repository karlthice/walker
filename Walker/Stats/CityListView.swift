import SwiftUI

/// The cities and municipalities explored in a country, with the share of each uncovered.
/// Boundaries come from OpenStreetMap and are looked up the first time they're needed.
struct CityListView: View {
    let country: CountryStat

    @Environment(LocationService.self) private var service
    /// The country's explored area, kept current here: `country` is a snapshot from when the list was opened.
    @State private var exploredArea: Double?
    @State private var cities: [PlaceStat]?
    @State private var progress: ResolveProgress?
    @State private var error: String?

    var body: some View {
        List {
            if let progress, progress.done < progress.total {
                Section {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text(progress.status ?? "Looking up cities…")
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
                if let cities {
                    if cities.isEmpty && progress == nil && error == nil {
                        Text("No cities found.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(cities) { city in
                        CityRow(city: city)
                    }
                    let countryArea = exploredArea ?? country.exploredArea
                    let elsewhere = countryArea - cities.reduce(0) { $0 + $1.exploredArea }
                    // Ignore rounding noise; show only a meaningful remainder.
                    if elsewhere > max(countryArea * 0.01, 100) {
                        HStack {
                            Text("Elsewhere in \(country.name)")
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
                Text("Cities and municipalities")
            } footer: {
                Text("Boundaries © OpenStreetMap contributors.")
            }
        }
        .navigationTitle([country.flag, country.name].compactMap { $0 }.joined(separator: " "))
        .task { await keepUpdated() }
        .refreshable { await load() }
    }

    /// Loads now and again whenever new points are tracked, one load at a time: restarting
    /// on every location fix would keep cancelling slow boundary lookups.
    private func keepUpdated() async {
        var loadedRevision: Int?
        while !Task.isCancelled {
            if loadedRevision != service.revision {
                loadedRevision = service.revision
                await load()
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func load() async {
        let resolver = PlaceResolver.shared
        let code = country.code
        error = nil
        do {
            cities = try await resolver.cityStats(country: code)
            guard let index = CountryIndex.shared else { return }
            try await resolver.resolveCities(country: code, countries: index) { update in
                await show(update) { try? await resolver.cityStats(country: code) }
            }
            cities = try await resolver.cityStats(country: code)
            exploredArea = try await Self.exploredArea(country: code, countries: index)
        } catch is CancellationError {
            // Leave the state to whatever replaced this load.
            return
        } catch {
            self.error = error.localizedDescription
        }
        progress = nil
    }

    private static func exploredArea(country: String, countries: CountryIndex) async throws -> Double {
        let url = PointStore.defaultURL
        let stats = try await Task.detached(priority: .userInitiated) {
            try StatsCalculator.countryStats(databaseURL: url, countries: countries)
        }.value
        return stats.first { $0.code == country }?.exploredArea ?? 0
    }

    /// Shows progress, refreshing the list as cities come in (not after every tile).
    private func show(_ update: ResolveProgress, refresh: () async -> [PlaceStat]?) async {
        progress = update
        if update.status == nil, update.done == update.total || update.done % 10 == 0, let updated = await refresh() {
            cities = updated
        }
    }
}

private struct CityRow: View {
    let city: PlaceStat

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(city.name)
                if let english = city.englishName {
                    Text(english)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(city.fraction.formatted(.percent.precision(.significantDigits(2))))
                    .monospacedDigit()
                Text(StatsView.formatArea(city.exploredArea))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
