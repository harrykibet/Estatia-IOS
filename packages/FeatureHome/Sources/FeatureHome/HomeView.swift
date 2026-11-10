import SwiftUI
import CoreAppData
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
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
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
                                .containerRelativeFrame(.vertical)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
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
    @State private var engineLoadFailed = false

    private var videoItem: FeedPlaybackItem? {
        HomeViewModel.playbackItem(for: property)
    }

    private var firstImageURL: URL? {
        property.imageUrl.first.flatMap { URL(string: $0) }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black

            if videoItem != nil {
                if let engine {
                    EngineVideoPlayer(
                        engine: engine,
                        title: property.title,
                        isMuted: viewModel.isMuted,
                        onMuteToggle: viewModel.toggleMute
                    )
                } else if engineLoadFailed {
                    ContentUnavailableView(
                        "Video unavailable",
                        systemImage: "video.slash",
                        description: Text("This listing's video could not be prepared.")
                    )
                    .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            } else if let firstImageURL {
                AsyncImage(url: firstImageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "house")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.8))
                    case .empty:
                        ProgressView().tint(.white)
                    @unknown default:
                        Color.black
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                Image(systemName: "house")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.8))
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.18), .black.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 8) {
                Text(property.title ?? "Untitled property")
                    .font(.title3.weight(.bold))
                    .lineLimit(2)

                if let county = property.county, !county.isEmpty {
                    Text(county)
                        .font(.subheadline)
                }

                if let price = property.price {
                    Text(price, format: .currency(code: "KES").precision(.fractionLength(0)))
                        .font(.headline)
                }

                if let description = property.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .lineLimit(3)
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, 20)
            .padding(.trailing, 92)
            .padding(.bottom, 138)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            viewModel.setComposed(property, isComposed: visible)
        }
        .onScrollVisibilityChange(threshold: 0.9) { visible in
            isVisible = visible
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
                engineLoadFailed = false
                return
            }

            do {
                let preparedEngine = try await viewModel.playerEngine(for: property)
                guard !Task.isCancelled else { return }
                engine = preparedEngine
                engineLoadFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                engine = nil
                engineLoadFailed = true
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
