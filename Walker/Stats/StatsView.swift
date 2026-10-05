import Charts
import SwiftUI

struct StatsView: View {
    @Environment(LocationService.self) private var service
    @State private var days: [DayStat] = []
    @State private var countries: [CountryStat]?
    @State private var selectedDay: Date?

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            List {
                Section {
                    hero
                    HStack(spacing: 12) {
                        periodTile("Today", since: calendar.startOfDay(for: .now))
                        periodTile("This week", since: calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now)
                        periodTile("This month", since: calendar.dateInterval(of: .month, for: .now)?.start ?? .now)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                }
                .listRowSeparator(.hidden)

                Section("New area per day · last 30 days") {
                    dailyChart
                }

                Section {
                    countryRows
                } header: {
                    Text("Countries")
                } footer: {
                    Text("Share of each country's land area you have uncovered. Tap a country for its cities.")
                }
            }
            .navigationTitle("Stats")
            .navigationDestination(for: CountryStat.self) { country in
                CityListView(country: country)
            }
            .task(id: service.revision) {
                days = service.store.dailyStats()
            }
            .task {
                await loadCountries()
            }
            .refreshable {
                days = service.store.dailyStats()
                await loadCountries()
            }
        }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Explored")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Self.formatArea(total(\.area)))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let first = days.first?.day {
                Text("\(Self.formatDistance(total(\.distance))) travelled since \(first.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func periodTile(_ title: String, since start: Date) -> some View {
        let area = total(\.area, since: start)
        let distance = total(\.distance, since: start)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.formatArea(area))
                .font(.headline)
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(Self.formatDistance(distance))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var recentDays: [DayStat] {
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: .now)) ?? .now
        return days.filter { $0.day >= start }
    }

    @ViewBuilder
    private var dailyChart: some View {
        let recent = recentDays
        if recent.isEmpty {
            Text("Nothing explored in the last 30 days.")
                .foregroundStyle(.secondary)
        } else {
            let selected = selectedDay.flatMap { day in recent.first { calendar.isDate($0.day, inSameDayAs: day) } }
            VStack(alignment: .leading, spacing: 8) {
                Text(selected.map { "\($0.day.formatted(.dateTime.weekday(.wide).day().month())): \(Self.formatArea($0.totals.area))" }
                     ?? "Tap a bar for details")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Chart(recent) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("km²", day.totals.area / 1e6),
                        width: .ratio(0.7)
                    )
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .foregroundStyle(Color.accentColor.opacity(selected == nil || selected?.id == day.id ? 1 : 0.35))
                }
                .chartXScale(domain: (calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: .now)) ?? .now)...(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now))
                .chartXSelection(value: $selectedDay)
                .chartXAxis {
                    // Weekly labels ending a week before today, so none is clipped at the right edge.
                    AxisMarks(values: [28, 21, 14, 7].compactMap { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: .now)) }) {
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel()
                    }
                }
                .chartYAxisLabel("km²")
                .frame(height: 160)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var countryRows: some View {
        if let countries {
            if countries.isEmpty {
                Text("No countries yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(countries) { country in
                NavigationLink(value: country) {
                HStack {
                    Text([country.flag, country.name].compactMap { $0 }.joined(separator: " "))
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(country.fraction.formatted(.percent.precision(.significantDigits(2))))
                            .monospacedDigit()
                        Text(Self.formatArea(country.exploredArea))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
                }
            }
        } else {
            ProgressView()
        }
    }

    // MARK: - Data

    private func total(_ value: KeyPath<DayTotals, Double>, since start: Date = .distantPast) -> Double {
        days.filter { $0.day >= start }.reduce(0) { $0 + $1.totals[keyPath: value] }
    }

    private func loadCountries() async {
        guard let index = CountryIndex.shared else {
            countries = []
            return
        }
        let url = PointStore.defaultURL
        countries = await Task.detached(priority: .userInitiated) {
            (try? StatsCalculator.countryStats(databaseURL: url, countries: index)) ?? []
        }.value
    }

    // MARK: - Formatting

    nonisolated static func formatArea(_ squareMetres: Double) -> String {
        let km2 = squareMetres / 1e6
        let digits = km2 < 1 ? 2 : km2 < 100 ? 1 : 0
        return "\(km2.formatted(.number.precision(.fractionLength(digits)))) km²"
    }

    nonisolated static func formatDistance(_ metres: Double) -> String {
        let km = metres / 1000
        return "\(km.formatted(.number.precision(.fractionLength(km < 100 ? 1 : 0)))) km"
    }
}
