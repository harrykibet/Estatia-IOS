import SwiftUI

/// Public Home feed entry point used by the app composition root.
public struct HomeFeedContentView: View {
    private let viewModel: HomeViewModel

    public init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HomeView(viewModel: viewModel)
    }
}
