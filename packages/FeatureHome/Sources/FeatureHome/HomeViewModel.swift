import Foundation
import SwiftUI

import CoreAppData
import CoreModel

@MainActor
public final class HomeViewModel: ObservableObject {
    @Published public private(set) var properties: [PropertyModel] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let repository: PropertyRepository
    private var hasLoaded = false

    public init(repository: PropertyRepository) {
        self.repository = repository
    }

    public func load(forceRefresh: Bool = false) async {
        guard !isLoading, forceRefresh || !hasLoaded else {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            properties = try await repository.fetchProperties()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
