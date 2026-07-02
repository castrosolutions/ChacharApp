import ChacharCore
import Foundation
import MLXLLM
import MLXLMCommon

/// Layer 2 cleanup using a small on-device LLM via MLX — 100% local, free, private.
///
/// An `actor` so it is `Sendable` and serialises access to the loaded model.
public actor MLXTextCleaner: TextCleaner {
    public struct Configuration: Sendable {
        /// Hugging Face id of an MLX-format instruct model.
        public var modelId: ModelId

        public init(modelId: ModelId = DefaultModels.cleanupModelId) {
            self.modelId = modelId
        }
    }

    public enum CleanerError: Error, Sendable { case notReady, metallibMissing }

    private var configuration: Configuration
    private var container: ModelContainer?
    public private(set) var isReady = false

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// The model id currently loaded (or configured to load).
    public var activeModelId: ModelId { configuration.modelId }

    /// Switch to a different model at runtime: release the current one and load `modelId`,
    /// reporting download progress (0...1) on first use. On failure the cleaner is left unready.
    public func reload(modelId: ModelId, progress: (@Sendable (Double) -> Void)?) async throws {
        container = nil
        isReady = false
        configuration.modelId = modelId
        try await prepare(progress: progress)
    }

    /// Load/warm the model (protocol entry point). See ``prepare(progress:)`` for download progress.
    public func prepare() async throws {
        try await prepare(progress: nil)
    }

    /// Run a minimal throwaway generation so the first user-facing cleanup doesn't pay MLX's
    /// one-time costs (Metal pipeline compilation, KV-cache setup) — roughly a second on the 7B.
    /// No-op if the model isn't loaded. Best-effort: warm-up failures are swallowed, never surfaced.
    public func warmUp() async {
        guard let container else { return }
        _ = try? await container.perform { context in
            let params = GenerateParameters(maxTokens: 1, temperature: 0)
            let input = try await context.processor.prepare(input: UserInput(chat: [.user("Hola")]))
            return try MLXLMCommon.generate(input: input, parameters: params, context: context) { (_: [Int]) in .stop }
        }
    }

    /// Release the model so it stops occupying ~4–5 GB (e.g. when the user disables cleanup).
    /// A later ``prepare()``/``reload(modelId:progress:)`` reloads it.
    public func unload() {
        container = nil
        isReady = false
    }

    /// Load the model, optionally reporting download progress (0...1) on first run.
    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        guard container == nil else { return }
        // Guard against a missing Metal library: without mlx-swift_Cmlx.bundle/default.metallib
        // MLX aborts the whole process (uncatchable), so refuse rather than crash. The env var lets
        // non-.app tooling (e.g. the benchmark) bypass the heuristic when the bundle lives next to
        // the executable rather than inside an .app's Resources.
        let skipCheck = ProcessInfo.processInfo.environment["CHACHARAPP_SKIP_METALLIB_CHECK"] != nil
        guard skipCheck || Self.metallibAvailable() else { throw CleanerError.metallibMissing }
        // Referencing LLMModelFactory ensures MLXLLM is linked so the model factory registers.
        _ = LLMModelFactory.shared
        // Downloads to the caches dir on first run (7B 4-bit ≈ 4.3 GB), then loads from cache.
        container = try await loadModelContainer(id: configuration.modelId) { p in
            progress?(p.fractionCompleted)
        }
        isReady = true
    }

    /// Whether MLX's compiled Metal library is present in the app bundle. If it isn't (e.g. the
    /// Metal Toolchain wasn't installed at build time), loading the model would hard-crash.
    private static func metallibAvailable() -> Bool {
        let bundleName = "mlx-swift_Cmlx.bundle"
        let bases = [Bundle.main.resourceURL,
                     Bundle.main.executableURL?.deletingLastPathComponent(),
                     Bundle.main.bundleURL].compactMap { $0 }
        let relativePaths = ["\(bundleName)/Contents/Resources/default.metallib",
                             "\(bundleName)/default.metallib"]
        for base in bases {
            for rel in relativePaths
            where FileManager.default.fileExists(atPath: base.appendingPathComponent(rel).path) {
                return true
            }
        }
        return false
    }

    public func clean(_ text: String) async throws -> String {
        try await cleanMeasured(text).text
    }

    /// Timing/throughput stats for a single cleanup pass (for benchmarking and diagnostics).
    public struct CleanupStats: Sendable {
        public let promptTokens: Int
        public let generatedTokens: Int
        /// Time to process the prompt / produce the first token.
        public let promptTime: TimeInterval
        /// Time spent generating the remaining tokens.
        public let generateTime: TimeInterval
        /// Wall-clock for the whole cleanup call — what the user actually waits.
        public let totalTime: TimeInterval
        public var tokensPerSecond: Double { generateTime > 0 ? Double(generatedTokens) / generateTime : 0 }
    }

    /// Like ``clean(_:)`` but also returns generation stats. Uses the low-level MLX generate path
    /// (equivalent to `ChatSession.respond`, which discards system messages anyway — that is why
    /// the prompt embeds the instructions) so we can capture token counts and timings.
    public func cleanMeasured(_ text: String) async throws -> (text: String, stats: CleanupStats) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (trimmed, CleanupStats(promptTokens: 0, generatedTokens: 0,
                                          promptTime: 0, generateTime: 0, totalTime: 0))
        }
        guard let container else { throw CleanerError.notReady }

        let promptText = Self.prompt(for: trimmed)
        // Delete-only cleanup never outputs more than the input, so size the generation cap to the
        // input length plus a margin rather than a fixed number: long dictations are never
        // truncated, yet a runaway generation is still bounded. ~3 chars/token is a conservative
        // es+en estimate (overestimates tokens, so the cap stays safely generous).
        let maxTokens = min(4096, max(128, trimmed.count / 3 + 64))
        let started = Date.timeIntervalSinceReferenceDate
        let result: GenerateResult = try await container.perform { context in
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            let input = try await context.processor.prepare(input: UserInput(chat: [.user(promptText)]))
            return try MLXLMCommon.generate(input: input, parameters: params, context: context) { tokens in
                tokens.count >= maxTokens ? .stop : .more
            }
        }
        let total = Date.timeIntervalSinceReferenceDate - started

        let stats = CleanupStats(
            promptTokens: result.promptTokenCount,
            generatedTokens: result.generationTokenCount,
            promptTime: result.promptTime,
            generateTime: result.generateTime,
            totalTime: total
        )
        return (Self.postProcess(result.output, fallback: trimmed), stats)
    }

    // MARK: Prompting

    private static let instructions = """
    Eres un corrector de transcripciones de voz en español (con términos técnicos en inglés). Tu \
    ÚNICA tarea es eliminar el ruido del habla, SIN reescribir.

    PROHIBIDO sustituir, traducir, reordenar, resumir o añadir palabras. Conserva EXACTAMENTE las \
    palabras del hablante, incluida su conjugación (si dice "subimos", la salida dice "subimos", \
    nunca "entramos"). Respeta los términos en inglés tal cual (S3, CloudFront, GitHub, Kubernetes…).

    Elimina SOLO:
    1. Muletillas y titubeos de relleno ("eh", "este", "o sea", "pues", "no sé", "a ver", "bueno", \
    "¿no?") y las repeticiones inmediatas.
    2. Autocorrecciones: si el hablante se rectifica, deja SOLO la versión final y borra la \
    descartada JUNTO con la palabra de aviso. Avisos: "no", "no espera", "perdón", "digo", \
    "mejor dicho", "quiero decir", "o sea no".

    Ajusta únicamente la mayúscula inicial y la puntuación al unir los trozos. Si no hay ruido, \
    devuelve el texto idéntico. Responde EXCLUSIVAMENTE con el texto corregido, sin comillas ni \
    comentarios.
    """

    /// Few-shot examples teaching delete-only behaviour (verbatim words; resolve self-corrections).
    /// Deliberately different from the benchmark phrases so any leakage would be visible.
    private static let fewShot = """
    Entrada: Pues, eh, mañana, o sea, mando el informe.
    Salida: Mañana mando el informe.

    Entrada: Lo guardamos en Postgres, no, en Redis.
    Salida: Lo guardamos en Redis.

    Entrada: Reservé la sala azul, digo la sala roja.
    Salida: Reservé la sala roja.

    Entrada: Te llamo cuando termine la reunión.
    Salida: Te llamo cuando termine la reunión.
    """

    private static func prompt(for text: String) -> String {
        """
        \(instructions)

        \(fewShot)

        Entrada: \(text)
        Salida:
        """
    }

    private static func postProcess(_ output: String, fallback: String) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["Salida:", "Texto limpio:", "Resultado:", "Output:"] where s.hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The few-shot "Entrada/Salida" format can make the model keep generating more pairs;
        // keep only the first answer by cutting at any continuation marker.
        for marker in ["\nEntrada:", "\nSalida:", "\nInput:", "\n\n"] {
            if let r = s.range(of: marker) { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»")]
        for (open, close) in quotePairs where s.count >= 2 && s.first == open && s.last == close {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? fallback : s
    }
}
