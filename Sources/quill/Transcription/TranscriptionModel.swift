import FluidAudio
import Foundation

enum TranscriptionModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeetV3 = "parakeet-v3"
    case parakeetV2 = "parakeet-v2"

    static let `default`: Self = .parakeetV3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet TDT 0.6B v3"
        case .parakeetV2: "Parakeet TDT 0.6B v2"
        }
    }

    var recommendation: String {
        switch self {
        case .parakeetV3: "Best for Italian and multilingual meetings"
        case .parakeetV2: "Best for English-only meetings"
        }
    }

    var languageSummary: String {
        switch self {
        case .parakeetV3: "25 European languages · automatic detection"
        case .parakeetV2: "English only · higher English recall"
        }
    }

    var approximateSize: String { "About 600 MB" }
    var providerName: String { "NVIDIA" }
    var isRecommended: Bool { self == .parakeetV3 }

    var fluidVersion: AsrModelVersion {
        switch self {
        case .parakeetV3: .v3
        case .parakeetV2: .v2
        }
    }

    var provenance: String {
        switch self {
        case .parakeetV3: "parakeet-tdt-0.6b-v3-coreml"
        case .parakeetV2: "parakeet-tdt-0.6b-v2-coreml"
        }
    }
}
