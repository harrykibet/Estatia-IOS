//
//  SearchView.swift
//  search
//
//  Created by builder on 5/8/25.
//

import SwiftUI
import CoreAppData
import CoreModel

public struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel

    public init(viewModel: SearchViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Custom Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search properties...", text: $viewModel.searchText, onCommit: {
                        Task { await viewModel.search() }
                    })
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6))
                )
                .padding(.horizontal)
                .padding(.top, 12)

                // Results List
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if viewModel.isLoading {
                            ProgressView()
                                .padding()
                        } else {
                            ForEach(viewModel.results.indices, id: \.self) { index in
                                let p = viewModel.results[index]
                                SearchResultCard(title: p.title ?? "Untitled",
                                                 subtitle: p.county ?? "Unknown location")
                                    .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.top)
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Search")
                        .font(.title3.bold())
                }
            }
        }
    }
}

// MARK: - Custom Card View
struct SearchResultCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
        )
    }
}

// Keep preview dependencies local to the feature package. The app composition
// root owns the concrete remote repository and data-source implementations.
private struct SearchPreviewRepository: PropertyRepository {
    func fetchProperty(id: String) async throws -> PropertyModel { PropertyModel() }
    func fetchProperties() async throws -> [PropertyModel] { [] }
    func searchProperties(query: String?, filters: PropertySearchFilters) async throws -> [PropertyModel] { [] }
    func createProperty(_ property: PropertyModel) async throws -> PropertyModel { property }
    func updateProperty(_ property: PropertyModel) async throws -> PropertyModel { property }
    func deleteProperty(id: String) async throws {}
}

#Preview {
    SearchView(viewModel: SearchViewModel(repository: SearchPreviewRepository()))
}
