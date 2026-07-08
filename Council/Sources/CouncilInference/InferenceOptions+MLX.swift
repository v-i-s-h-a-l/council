import Foundation
import MLXLMCommon
import CouncilCore

extension InferenceOptions {
    /// Converts Council inference options into MLX generation parameters.
    ///
    /// - `temperature` maps to `GenerateParameters.temperature`.
    /// - `maxTokens` maps to `GenerateParameters.maxTokens`.
    ///
    /// Note: MLX v1 applies stop sequences via the model configuration
    /// (`stopStrings`) rather than `GenerateParameters`, so `stopSequences`
    /// is not represented here. JSON mode is ignored for MLX v1.
    public var mlxParameters: GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(temperature)
        )
    }
}
