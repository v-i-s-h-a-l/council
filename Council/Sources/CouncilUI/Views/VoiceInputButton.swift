#if os(iOS)
import AVFoundation
import Speech
import SwiftUI

/// Voice input button that only enables on-device speech recognition.
///
/// Server-based recognition is explicitly blocked by setting
/// `requiresOnDeviceRecognition = true` on both the recognizer and request.
public struct VoiceInputButton: View {
    public let onTranscript: (String) -> Void

    @State private var isEnabled: Bool = false
    @State private var isRecording: Bool = false
    @State private var recognizer: SFSpeechRecognizer?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine: AVAudioEngine?

    public init(onTranscript: @escaping (String) -> Void) {
        self.onTranscript = onTranscript
    }

    public var body: some View {
        Button(action: {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        }) {
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
        }
        .disabled(!isEnabled)
        .onAppear {
            isEnabled = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition ?? false
        }
    }

    private func startRecording() {
        guard isEnabled else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { return }
        self.recognizer = recognizer
        recognizer.requiresOnDeviceRecognition = true

        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { return }

                self.isRecording = true
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true

                let audioEngine = AVAudioEngine()
                self.audioEngine = audioEngine
                let inputNode = audioEngine.inputNode
                let recordingFormat = inputNode.outputFormat(forBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                    request.append(buffer)
                }

                audioEngine.prepare()
                try? audioEngine.start()

                self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    Task { @MainActor in
                        if let result {
                            let transcript = result.bestTranscription.formattedString
                            if result.isFinal {
                                self.onTranscript(transcript)
                                self.stopRecording()
                            }
                        }
                        if error != nil {
                            self.stopRecording()
                        }
                    }
                }
            }
        }
    }

    private func stopRecording() {
        recognitionTask?.cancel()
        recognitionTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isRecording = false
    }
}
#endif
