import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which backend should serve the main Apple agent completion path.
nonisolated enum CPSLAgentProviderKind: String, Equatable, Sendable {
    case openAI
    case applePCC
}

/// Runtime flags that gate Apple Private Cloud Compute selection.
/// Kept as a value type so selection stays pure and unit-testable.
nonisolated struct CPSLAgentProviderSelectionInput: Equatable, Sendable {
    var isApplePlatform: Bool
    var isOS27OrNewer: Bool
    var isPCCAvailable: Bool
}

/// Pure selection helpers for the main agent provider.
/// Prefer PCC on iOS/macOS 27+ when the model reports availability; otherwise OpenAI/Grok.
nonisolated enum CPSLAgentProviderSelection {
    static let pccModelID = "apple/pcc"

    static func select(_ input: CPSLAgentProviderSelectionInput) -> CPSLAgentProviderKind {
        if input.isApplePlatform && input.isOS27OrNewer && input.isPCCAvailable {
            return .applePCC
        }
        return .openAI
    }

    static func modelID(kind: CPSLAgentProviderKind, openAIModel: String) -> String {
        switch kind {
        case .applePCC:
            return pccModelID
        case .openAI:
            return openAIModel
        }
    }
}

/// Platform capability probes used at runtime. Selection itself stays pure via
/// `CPSLAgentProviderSelection.select` with injected flags.
nonisolated enum CPSLAgentPlatform {
    static var isApple: Bool {
        #if os(iOS) || os(macOS) || os(visionOS)
        return true
        #else
        return false
        #endif
    }

    static var isOS27OrNewer: Bool {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return true
        }
        return false
    }
}

/// Live PCC availability. Always false when FoundationModels / iOS 27 APIs are absent.
nonisolated enum CPSLPCCAvailability {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
        return false
    }

    static func resolvedKind() -> CPSLAgentProviderKind {
        CPSLAgentProviderSelection.select(
            CPSLAgentProviderSelectionInput(
                isApplePlatform: CPSLAgentPlatform.isApple,
                isOS27OrNewer: CPSLAgentPlatform.isOS27OrNewer,
                isPCCAvailable: isAvailable
            )
        )
    }
}
