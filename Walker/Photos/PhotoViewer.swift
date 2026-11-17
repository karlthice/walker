import SwiftUI

/// Photos opened from the map: one pin, or every photo in a cluster taken at about one spot.
struct PhotoSelection: Identifiable {
    let id = UUID()
    /// Newest first.
    let pins: [PhotoPin]
}

/// Full-screen photos, swiped through when there are several.
struct PhotoViewer: View {
    let pins: [PhotoPin]

    @Environment(\.dismiss) private var dismiss
    @State private var current: String?

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(pins) { pin in
                    PhotoPage(pin: pin)
                        .tag(Optional(pin.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(.black)
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        if let date = currentPin?.date {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.headline)
                            Text(date.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                if pins.count > 1, let index = pins.firstIndex(where: { $0.id == current }) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("\(index + 1) of \(pins.count)")
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .onAppear { current = current ?? pins.first?.id }
    }

    private var currentPin: PhotoPin? {
        pins.first { $0.id == current }
    }
}

private struct PhotoPage: View {
    let pin: PhotoPin

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var missing = false
    @State private var request: PHImageRequestIDBox?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(pin.date.map { "Photo from \($0.formatted(date: .long, time: .shortened))" } ?? "Photo")
                } else if missing {
                    ContentUnavailableView("Photo not available", systemImage: "photo",
                                           description: Text("It may have been deleted."))
                        .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .onAppear { load(size: proxy.size) }
            .onDisappear {
                PhotoImages.cancel(request?.id)
                request = nil
            }
        }
    }

    private func load(size: CGSize) {
        guard request == nil else { return }
        let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        let box = PHImageRequestIDBox()
        request = box
        box.id = PhotoImages.request(pin.id, pixelSize: pixels) { result, isFinal in
            if let result {
                image = result
            } else if isFinal && image == nil {
                missing = true
            }
        }
    }
}
