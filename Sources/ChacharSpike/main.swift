import Foundation
import ChacharCore
import WhisperKit

// chacharapp-spike — minimal transcription + latency smoke test (Phase 1 / 2).
//
// Usage: chacharapp-spike <audioFile> [--model <folder>] [--lang <code>] [--prompt <terms>]
//   Loads the local turbo model, transcribes the audio file with a warm model, and prints the
//   transcription plus measured timings (model load+warm-up, transcribe time, RTF).
//   `--prompt` exercises Layer 0 glossary biasing (DecodingOptions.promptTokens).

func flagValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = CommandLine.arguments
guard args.count >= 2, !args[1].hasPrefix("--") else {
    FileHandle.standardError.write(Data(
        "usage: chacharapp-spike <audioFile> [--model <folder>] [--lang <code>] [--prompt <terms>]\n".utf8))
    exit(2)
}

let audioPath = args[1]
let defaultModelFolder = FileManager.default.currentDirectoryPath
    + "/Models/\(DefaultModels.bundledASRFolderName)"
let modelFolder = flagValue("--model", in: args) ?? defaultModelFolder
let language = flagValue("--lang", in: args) ?? "es"
let prompt = flagValue("--prompt", in: args)

do {
    let transcriber = WhisperKitTranscriber(
        configuration: .init(modelFolder: modelFolder, language: language)
    )

    print("Loading model from: \(modelFolder)")
    try await transcriber.prepare()
    let loadDuration = await transcriber.lastLoadDuration
    print(String(format: "Model loaded + warmed up in %.2fs", loadDuration))

    // Decode the audio file to 16 kHz mono float samples (WhisperKit's loader resamples).
    let values = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
    let audioSeconds = Double(values.count) / 16_000.0
    let samples = AudioSamples(values: values)

    // Timed transcription with the model already warm.
    let result = try await transcriber.transcribe(samples, prompt: prompt)
    let rtf = result.duration / max(audioSeconds, 0.001)

    print("")
    print("Audio:       \(audioPath)  (\(String(format: "%.1f", audioSeconds))s)")
    print("Language:    \(language)")
    print("Prompt:      \(prompt ?? "(none)")")
    print(String(format: "Transcribe:  %.2fs  (RTF %.2fx — lower is faster than real time)", result.duration, rtf))
    print("Text:        \(result.text)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
