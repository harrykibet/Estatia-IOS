import SwiftUI

import CoreAppData
import CoreModel
import CorePlayerEngine
import CorePlayerUI

public struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    @StateObject private var playbackController: HomeFeedPlaybackController

    public init(
        viewModel: HomeViewModel,
        playbackController: HomeFeedPlaybackController = HomeFeedPlaybackController()
    ) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self._playbackController = StateObject(wrappedValue: playbackController)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if viewModel.properties.isEmpty && viewModel.isLoading {
                    ProgressView("Loading properties…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.properties.isEmpty, let error = viewModel.errorMessage {
                    ContentUnavailableView {
                        Label("Unable to load properties", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            Task { await viewModel.load(forceRefresh: true) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.properties.isEmpty {
                    ContentUnavailableView(
                        "No properties yet",
                        systemImage: "house",
                        description: Text("New property listings will appear here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    propertyFeed
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            playbackController.start()
            await viewModel.load()
        }
        .onDisappear {
            Task { await playbackController.stop() }
        }
    }

    private var propertyFeed: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.properties.enumerated()), id: \.offset) { index, property in
                    HomeFeedCardView(
                        property: property,
                        engine: property.id.flatMap { playbackController.engines[$0] },
                        isMuted: playbackController.isMuted,
                        onMuteToggle: playbackController.toggleMute
                    )
                    .containerRelativeFrame(.vertical)
                    .onAppear {
                        playbackController.setComposed(true, property: property)
                    }
                    .onDisappear {
                        playbackController.setComposed(false, property: property)
                    }
                    .onScrollVisibilityChange(threshold: 0.6) { isVisible in
                        guard isVisible else { return }
                        playbackController.itemBecameVisible(
                            in: viewModel.properties,
                            at: index
                        )
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .refreshable {
            await viewModel.load(forceRefresh: true)
        }
    }
}

private struct HomeFeedCardView: View {
    let property: PropertyModel
    let engine: (any PlayerEngine)?
    let isMuted: Bool
    let onMuteToggle: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Color.black

                if let engine {
                    EngineVideoPlayer(
                        engine: engine,
                        title: property.title,
                        isMuted: isMuted,
                        onMuteToggle: onMuteToggle
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    poster
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.12), .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 8) {
                    Text(property.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled property")
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)

                    Text([property.county, property.propertyType]
                        .compactMap { $0?.isEmpty == false ? $0 : nil }
                        .joined(separator: " • ")
                    )
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))

                    if let price = property.price {
                        Text(price.formatted(.number.precision(.fractionLength(0))))
                            .font(.headline)
                    }

                    if let description = property.description,
                       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .lineLimit(3)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.bottom, 112)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .background(Color.black)
    }

    @ViewBuilder
    private var poster: some View {
        if let imageURL = property.imageUrl.lazy.compactMap(Self.validRemoteURL).first {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.28)
            Image(systemName: "house.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private static func validRemoteURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else {
            return nil
        }
        return url
    }
}

// Keep preview fixtures at file scope. The #Preview macro body is a
// PreviewMacroBodyBuilder and cannot contain local type declarations.
private struct HomePreviewRepository: PropertyRepository {
    func fetchProperty(id: String) async throws -> PropertyModel {
        PropertyModel()
    }

    func fetchProperties() async throws -> [PropertyModel] {
        [PropertyModel()]
    }

    func searchProperties(query: String?, filters: PropertySearchFilters) async throws -> [PropertyModel] {
        [PropertyModel()]
    }

    func createProperty(_ property: PropertyModel) async throws -> PropertyModel {
        property
    }

    func updateProperty(_ property: PropertyModel) async throws -> PropertyModel {
        property
    }

    func deleteProperty(id: String) async throws {}
}

#Preview {
    HomeView(viewModel: HomeViewModel(repository: HomePreviewRepository()))
}
