//
//  HomeView.swift
//  home
//
//  Created by builder on 5/8/25.
//

import SwiftUI
import CoreAppData
import CoreModel

public struct HomeView: View {
    @StateObject var viewModel: HomeViewModel

    public init(viewModel: HomeViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.properties.indices, id: \.self) { index in
                    let property = viewModel.properties[index]

                    VStack(alignment: .leading, spacing: 6) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 200)
                            .cornerRadius(10)

                        Text(property.title ?? "Untitled Property")
                            .font(.headline)
                        Text(property.county ?? "Unknown • — Beds • —")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Home")
            .task {
                await viewModel.load()
            }
        }
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
