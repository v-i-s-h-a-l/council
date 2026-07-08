import Foundation
import MLXLMCommon

/// Wrapper around `MLXLMCommon.ModelConfiguration` that provides
/// platform-appropriate defaults for Council on-device inference.
///
/// This type is named distinctly from `CouncilCore.ModelConfiguration` to avoid
/// ambiguity when both modules are imported.
public struct MLXModelConfiguration: Sendable {
    /// The underlying MLX model configuration.
    public let modelConfiguration: MLXLMCommon.ModelConfiguration

    public init(modelConfiguration: MLXLMCommon.ModelConfiguration) {
        self.modelConfiguration = modelConfiguration
    }

    /// Default MLX configuration for the current platform.
    ///
    /// - iOS: `mlx-community/Qwen2.5-3B-Instruct-4bit`
    /// - macOS: `mlx-community/Qwen2.5-7B-Instruct-4bit`
    public static var `default`: MLXModelConfiguration {
        #if os(iOS)
        MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(
                id: "mlx-community/Qwen2.5-3B-Instruct-4bit"
            )
        )
        #elseif os(macOS)
        MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(
                id: "mlx-community/Qwen2.5-7B-Instruct-4bit"
            )
        )
        #else
        MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(
                id: "mlx-community/Qwen2.5-3B-Instruct-4bit"
            )
        )
        #endif
    }
}
