import SwiftUI

extension View {
    func cpslDictationErrorAlert(_ dictation: CPSLDictationService) -> some View {
        alert(
            "Dictation unavailable",
            isPresented: Binding(
                get: { dictation.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        dictation.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictation.errorMessage ?? "")
        }
    }
}
