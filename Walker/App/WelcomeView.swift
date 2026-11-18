import SwiftUI

/// Shown until location access has been asked for, so the iOS prompts come with a reason.
struct WelcomeView: View {
    @Environment(LocationService.self) private var service

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "figure.walk")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 104, height: 104)
                .background(Color(red: 0.11, green: 0.13, blue: 0.18), in: RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)
            Text("Walker")
                .font(.largeTitle.bold())
                .padding(.top, 20)
            Text("Clear the fog by exploring")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 24) {
                point("map", "The map starts covered in fog",
                      "Wherever you walk, it lifts, street by street. Stats show how much of each country and major city you have uncovered.")
                point("location.fill", "Location access set to Always",
                      "So the fog clears even while Walker is closed. iOS asks twice: first to allow while using the app, then to change to always.")
                point("lock.fill", "Stays on your iPhone",
                      "Your tracks and photos are never uploaded.")
            }
            Spacer(minLength: 24)

            Button {
                service.requestPermission()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
