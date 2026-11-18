import SwiftUI

/// The major cities of a country bundled with the app, with the share of each uncovered.
struct CityListView: View {
    let country: CountryStat

    @Environment(LocationService.self) private var service
    /// The country's explored area, kept current here: `country` is a snapshot from when the list was opened.
    @State private var exploredArea: Double?
    @State private var cities: [PlaceStat]?

    var body: some View {
        List {
            Section {
                if let cities {
                    if cities.isEmpty {
                        Text("No major cities in \(country.name) yet.")
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
                Text("Major cities")
            } footer: {
                Text("City boundaries © OpenStreetMap contributors.")
            }
        }
        .navigationTitle([country.flag, country.name].compactMap { $0 }.joined(separator: " "))
        .task(id: service.revision) {
            // Walking bumps the revision every few seconds; coalesce those into one reload.
            if cities != nil {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let cityIndex = CityIndex.shared, let countryIndex = CountryIndex.shared else {
            cities = []
            return
        }
        let url = PointStore.defaultURL
        let code = country.code
        let loaded = await Task.detached(priority: .userInitiated) { () -> (cities: [PlaceStat], area: Double?)? in
            guard let cities = try? StatsCalculator.cityStats(databaseURL: url, country: code, cities: cityIndex) else { return nil }
            let area = (try? StatsCalculator.countryStats(databaseURL: url, countries: countryIndex))?.first { $0.code == code }?.exploredArea
            return (cities, area)
        }.value
        // A superseded load must not overwrite a newer one; a failed one (database still
        // locked) keeps what is shown.
        guard !Task.isCancelled else { return }
        cities = loaded?.cities ?? cities ?? []
        exploredArea = loaded?.area ?? exploredArea
    }
}

private struct CityRow: View {
    let city: PlaceStat

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(city.name)
                if let local = city.localName {
                    Text(local)
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
        // Cities not visited yet are listed as somewhere to go, but dimmed.
        .foregroundStyle(city.exploredArea > 0 ? .primary : .secondary)
        .accessibilityElement(children: .combine)
    }
}
