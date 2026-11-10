import SwiftUI
import CoreModel
import CorePlayerEngine
import CorePlayerUI

public struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel

    public init(viewModel: HomeViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading && viewModel.properties.isEmpty {
                    ProgressView("Loading properties…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError = viewModel.loadError, viewModel.properties.isEmpty {
                    ContentUnavailableView(
                        "Unable to load properties",
                        systemImage: "wifi.exclamationmark",
                        description: Text(loadError)
                    )
                } else if viewModel.properties.isEmpty {
                    ContentUnavailableView(
                        "No properties yet",
                        systemImage: "house",
                        description: Text("New listings will appear here.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            ForEach(Array(viewModel.properties.enumerated()), id: \.offset) { entry in
                                let index = entry.offset
                                HomePropertyFeedCard(
                                    property: entry.element,
                                    previous: index > 0
                                        ? Array(viewModel.properties[..<index].suffix(1))
                                        : [],
                                    next: Array(viewModel.properties.dropFirst(index + 1).prefix(2)),
                                    viewModel: viewModel
                                )
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .refreshable {
                        await viewModel.load()
                    }
                }
            }
            .navigationTitle("Home")
            .task {
                await viewModel.load()
            }
            .onDisappear {
                viewModel.endFeed()
            }
        }
    }
}

@MainActor
private struct HomePropertyFeedCard: View {
    let property: PropertyModel
    let previous: [PropertyModel]
    let next: [PropertyModel]
    @ObservedObject var viewModel: HomeViewModel

    @State private var isVisible = false
    @State private var engine: (any PlayerEngine)?

    private var videoItem: FeedPlaybackItem? {
        HomeViewModel.playbackItem(for: property)
    }

    private var firstImageURL: URL? {
        property.imageUrl.first.flatMap(URL.init(string:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.08))

                if videoItem != nil {
                    if let engine {
                        EngineVideoPlayer(
                            engine: engine,
                            title: property.title,
                            isMuted: viewModel.isMuted,
                            onMuteToggle: viewModel.toggleMute
                        )
                    } else {
                        ProgressView()
                            .tint(.secondary)
                    }
                } else if let firstImageURL {
                    AsyncImage(url: firstImageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "house")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            Color.gray.opacity(0.15)
                        }
                    }
                } else {
                    Image(systemName: "house")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 6) {
                Text(property.title ?? "Untitled property")
                    .font(.headline)
                    .lineLimit(2)

                if let county = property.county, !county.isEmpty {
                    Text(county)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let price = property.price {
                    Text(price, format: .currency(code: "KES").precision(.fractionLength(0)))
                        .font(.subheadline.weight(.semibold))
                }

                if let description = property.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .onScrollVisibilityChange(threshold: 0.6) { visible in
            isVisible = visible
            viewModel.setComposed(property, isComposed: visible)
            if visible {
                viewModel.itemBecameVisible(
                    property,
                    previous: previous,
                    next: next
                )
            }
        }
        .task(id: isVisible) {
            guard isVisible, videoItem != nil else {
                engine = nil
                return
            }
            do {
                engine = try await viewModel.playerEngine(for: property)
            } catch {
                engine = nil
            }
        }
        .onDisappear {
            if isVisible {
                viewModel.setComposed(property, isComposed: false)
            }
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(repository: HomePreviewRepository()))
}

private struct HomePreviewRepository: PropertyRepository {
    func fetchProperty(id: String) async throws -> PropertyModel { PropertyModel() }
    func fetchProperties() async throws -> [PropertyModel] { [PropertyModel()] }
    func searchProperties(query: String?, filters: PropertySearchFilters) async throws -> [PropertyModel] { [] }
    func createProperty(_ property: PropertyModel) async throws -> PropertyModel { property }
    func updateProperty(_ property: PropertyModel) async throws -> PropertyModel { property }
    func deleteProperty(id: String) async throws {}
}
