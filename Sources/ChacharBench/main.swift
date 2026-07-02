import ChacharCleanupMLX
import ChacharCore
import Foundation

// chacharapp-bench — Layer 2 cleanup benchmark (local MLX LLM).
//
// Measures, on this machine, the real cost of cleaning a transcription with the local LLM:
// model load time, a warm-up pass (first generation compiles Metal kernels), and then for each
// sample phrase the total wall-clock latency, prompt/generation token counts and tokens/second.
//
// Progress is written to stderr; a Markdown report is written to stdout (redirect it to a file).
//
// Usage: chacharapp-bench [modelId]
//   modelId   Hugging Face MLX model id (default: the cleaner's configured model)
//
// Built with xcodebuild (NOT `swift build`) so MLX's default.metallib is compiled — see
// Scripts/bench-cleanup.sh.

// MARK: - Samples

struct Sample {
    let category: String
    let input: String
    /// Ground-truth cleanup, when known (for the self-correction fixtures).
    let expected: String?
}

// The first three are illustrative self-corrections (with their expected cleanup).
// The rest map the latency curve across lengths and disfluency types.
let samples: [Sample] = [
    Sample(
        category: "self-correction (jargon)",
        input: "Subimos los ficheros a S3, digo a CloudFront.",
        expected: "Subimos los ficheros a CloudFront."),
    Sample(
        category: "self-correction (restart)",
        input: "Estamos pensando en alguna alternativa para completarlo. Perdón, ya hemos revisado las alternativas.",
        expected: "Ya hemos revisado las alternativas."),
    Sample(
        category: "self-correction (tool swap)",
        input: "Utilizamos GitLab, ah no, perdón, utilizamos GitHub.",
        expected: "Utilizamos GitHub."),
    Sample(
        category: "clean-short (baseline)",
        input: "Vale, lo reviso y te digo algo en un rato.",
        expected: nil),
    Sample(
        category: "fillers-medium",
        input: "Pues, eh, o sea, lo que quería decir es que, este, deberíamos, no sé, mirar los logs antes de desplegar, ¿no?",
        expected: nil),
    Sample(
        category: "mixed jargon + correction (long)",
        input: "Entonces lo que hice fue, eh, levantar un pod en Kubernetes, no espera, primero hice el build de la imagen con Docker y luego, este, lo subí al registry, y después ya apliqué el manifiesto con kubectl, o sea, el deployment.",
        expected: nil),
    Sample(
        category: "multi-correction (very long)",
        input: "Vale, mira, lo que necesito es que, eh, montemos el pipeline de, este, de CI, o sea, que cuando hagamos push a main se dispare el build, no espera, mejor que se dispare en cada pull request, y luego, pues, que corra los tests, los unitarios y los de integración, y si todo pasa, eh, que despliegue automáticamente a staging, no, perdón, a staging no, a un entorno de preview, y ya si lo aprobamos manualmente, entonces sí, que vaya a producción, ¿vale?",
        expected: nil),
]

// MARK: - Helpers

func err(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// Throttled download-progress printer. The MLX progress handler is `@Sendable` and may run off
/// the main actor, so this is a self-contained Sendable type that writes straight to stderr.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPct = -1
    func report(_ fraction: Double) {
        let pct = Int(fraction * 100)
        lock.lock()
        let show = pct != lastPct && pct % 5 == 0
        if show { lastPct = pct }
        lock.unlock()
        if show { FileHandle.standardError.write(Data("  download \(pct)%\n".utf8)) }
    }
}

func wordCount(_ s: String) -> Int {
    s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
}

struct Row {
    let sample: Sample
    let output: String
    let stats: MLXTextCleaner.CleanupStats
}

// MARK: - Run

let modelId = CommandLine.arguments.count >= 2
    ? CommandLine.arguments[1]
    : MLXTextCleaner.Configuration().modelId

let cleaner = MLXTextCleaner(configuration: .init(modelId: modelId))

err("Model: \(modelId)")
err("Preparing… (first run downloads the model; 7B 4-bit ≈ 4.3 GB)")

let loadStart = Date.timeIntervalSinceReferenceDate
let reporter = ProgressReporter()
do {
    try await cleaner.prepare { fraction in reporter.report(fraction) }
} catch {
    err("prepare failed: \(error)")
    exit(1)
}
let loadTime = Date.timeIntervalSinceReferenceDate - loadStart
err(String(format: "Loaded in %.2fs", loadTime))

// Warm-up: the first generation pays Metal kernel compilation; exclude it from the measurements.
err("Warming up…")
let warmStart = Date.timeIntervalSinceReferenceDate
_ = try? await cleaner.cleanMeasured("Hola, esto es una prueba de calentamiento.")
let warmTime = Date.timeIntervalSinceReferenceDate - warmStart
err(String(format: "Warm-up in %.2fs", warmTime))
err("")

var rows: [Row] = []
for (i, sample) in samples.enumerated() {
    err("[\(i + 1)/\(samples.count)] \(sample.category)")
    err("  in:  \(sample.input)")
    do {
        let (output, stats) = try await cleaner.cleanMeasured(sample.input)
        err("  out: \(output)")
        err(String(format: "       %.2fs total · %d→%d tok · %.1f tok/s",
                   stats.totalTime, stats.promptTokens, stats.generatedTokens, stats.tokensPerSecond))
        rows.append(Row(sample: sample, output: output, stats: stats))
    } catch {
        err("  ERROR: \(error)")
    }
    err("")
}

// MARK: - Markdown report (stdout)

let timestamp = ISO8601DateFormatter().string(from: Date())
let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0

var md = ""
md += "<!-- Auto-generated by Scripts/bench-cleanup.sh — do not hand-edit. "
md += "Curated analysis is kept alongside the raw numbers. -->\n\n"
md += "# Layer 2 cleanup benchmark\n\n"
md += "Local MLX LLM cleanup of voice transcriptions (remove fillers/false starts, resolve "
md += "mid-sentence self-corrections), measured on-device.\n\n"
md += "- **Model:** `\(modelId)`\n"
md += String(format: "- **Machine RAM:** %.0f GB\n", ramGB)
md += "- **Generated:** \(timestamp)\n"
md += String(format: "- **Model load:** %.2fs · **warm-up (first gen):** %.2fs\n", loadTime, warmTime)
md += "- **Params:** maxTokens 400, temperature 0 (greedy, deterministic)\n\n"

md += "## Summary\n\n"
md += "| # | Category | In words | Total s | Prompt tok | Gen tok | tok/s |\n"
md += "|---|---|---:|---:|---:|---:|---:|\n"
for (i, row) in rows.enumerated() {
    md += String(
        format: "| %d | %@ | %d | %.2f | %d | %d | %.1f |\n",
        i + 1, row.sample.category, wordCount(row.sample.input),
        row.stats.totalTime, row.stats.promptTokens, row.stats.generatedTokens,
        row.stats.tokensPerSecond)
}
md += "\n## Details\n\n"
for (i, row) in rows.enumerated() {
    md += "### \(i + 1). \(row.sample.category)\n\n"
    md += "- **In:**  \(row.sample.input)\n"
    md += "- **Out:** \(row.output)\n"
    if let expected = row.sample.expected {
        md += "- **Expected:** \(expected)\n"
    }
    md += String(
        format: "- **Timing:** %.2fs total · prompt %d tok in %.2fs · gen %d tok in %.2fs · %.1f tok/s\n\n",
        row.stats.totalTime, row.stats.promptTokens, row.stats.promptTime,
        row.stats.generatedTokens, row.stats.generateTime, row.stats.tokensPerSecond)
}

print(md, terminator: "")
err("Report written to stdout.")
