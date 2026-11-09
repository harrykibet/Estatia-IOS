import SwiftUI
import CoreModel
import CoreDesignSystem

@MainActor
public final class AppCoordinator: ObservableObject {
    // Use the shared AppTabID from CoreDesignSystem for consistency across the app
    public typealias AppTab = AppTabID

    private let navigationState: NavigationState
    public let container: AppDIContainer

    init(container: AppDIContainer, navigationState: NavigationState) {
        self.container = container
        self.navigationState = navigationState
    }

    // Expose selectedTab as a façade to the central NavigationState
    public var selectedTab: AppTab {
        get { navigationState.selectedTab }
        set { navigationState.selectedTab = newValue }
    }

    public var currentUser: User {
        container.appScope.currentUser
    }

    public func makeRootView() -> some View {
        MainTabView(coordinator: self)
    }

    public func view(for destination: AppDIContainer.FeatureDestination) -> AnyView {
        container.makeView(for: destination) { [weak self] in
            self?.selectedTab = .home
        }
    }
}

