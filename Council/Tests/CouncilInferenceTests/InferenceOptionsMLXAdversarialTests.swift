import XCTest
import CouncilCore
import MLXLMCommon
@testable import CouncilInference

final class InferenceOptionsMLXAdversarialTests: XCTestCase {
    /// Boundary pass-through of `maxTokens` into `GenerateParameters`,
    /// including 0 and 1.
    func testMaxTokensPassThroughBoundaries() {
        for maxTokens in [0, 1, 2048] {
            let params = InferenceOptions(maxTokens: maxTokens).mlxParameters
            XCTAssertEqual(params.maxTokens, maxTokens)
        }
    }

    /// Double→Float temperature conversion at exact-representable values and
    /// the high end of the usual sampling range.
    func testTemperatureDoubleToFloatMapping() {
        for temperature in [0.0, 0.7, 1.5, 2.0] {
            let params = InferenceOptions(temperature: temperature).mlxParameters
            XCTAssertEqual(params.temperature, Float(temperature))
        }
    }

    /// Pins the documented silent drop: MLX v1 applies stop sequences via
    /// the model configuration (`stopStrings`) and ignores JSON mode, so
    /// neither is representable in `GenerateParameters`. This is deliberate
    /// per the doc comment on `mlxParameters`; if support is added, update
    /// this pin.
    func testStopSequencesAndJSONModeAreSilentlyDropped() {
        let options = InferenceOptions(stopSequences: ["STOP", "END"], jsonMode: true)
        let params = options.mlxParameters
        XCTAssertEqual(params.maxTokens, options.maxTokens)
        XCTAssertEqual(params.temperature, Float(options.temperature))
    }
}
