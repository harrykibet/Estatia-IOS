// Auto-generated stub from /Users/builder/RealEstateApp-Android/feature/auth/src/main/java/com/estatia/realestate/apps/feature/auth/ui/screens/ForgotPasswordDialog.kt composable EmailInput
import SwiftUI
import CoreDesignSystem

public struct EmailInputView: View {
    @StateObject public var viewModel = EmailInputViewModel()

    public init(viewModel: EmailInputViewModel = .init()) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 16) {
                EstatiaText("Reset password")
            }
            .frame(maxWidth: .infinity)
        }
    }
}

public final class EmailInputViewModel: ObservableObject {
    // TODO: Implement state and actions ported from Android ViewModel/Presenter
    @Published public var isLoading: Bool = false

    public init() {}
}

#if DEBUG
struct EmailInputView_Preview: PreviewProvider {
    static var previews: some View { EmailInputView() }
}
#endif
