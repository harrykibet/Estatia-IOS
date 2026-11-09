import SwiftUI
import CoreDesignSystem

/// A presentation-only Google sign-in action button.
///
/// Authentication is delegated to the supplied action so the feature can
/// connect this control to its configured identity provider.
public struct GoogleSignInButton: View {
    private let isLoading: Bool
    private let isEnabled: Bool
    private let action: () -> Void

    public init(
        isLoading: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        AppButton(
            style: .outlined,
            isEnabled: isEnabled,
            isLoading: isLoading,
            action: action
        ) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .accessibilityHidden(true)

                Text("Continue with Google")
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Continue with Google")
    }
}
