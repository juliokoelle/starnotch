// Tara's free brain: one call to Apple's on-device model (Foundation Models), for the Python sidecar (agent/claude.py,
// AppleModel). The app ships it in Contents/MacOS and passes its path to the sidecar as STARNOTCH_APPLE_HELPER.
//
//   AppleModel --status     {"available": true} or {"available": false, "reason": "modelNotReady", "message": "…"}
//   AppleModel < request    one JSON request on stdin, one JSON line on stdout:
//       {"instructions": "…", "prompt": "…", "schema": {JSON Schema}, "locale": "de_DE", "maximumResponseTokens": 600}
//       -> {"result": {…}} or {"error": {"kind": "…", "message": "…", "reason": "…"}}
//
// kind: unavailable (reason: deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady), rateLimited, guardrail,
// contextWindowExceeded, unsupportedLanguage, other. The schema is the JSON Schema subset the sidecar uses (object,
// array, string with or without enum, integer, number, boolean, description, required, minItems, maxItems), built into
// a DynamicGenerationSchema here: the Command Line Tools have no @Generable macro, and the sidecar keeps one schema
// format for every brain. Properties keep the order of `required`, then the others by name. The root is an object,
// and every `type` one string (a node without one is a string); anything else is refused with kind other.
//
// The rest of the app targets macOS 14; the framework needs macOS 26, so everything that touches it is behind
// @available, and the binary links it weakly (it starts on older systems and answers "unavailable").

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct Failure: Error {
    let kind: String
    let message: String
    var reason: String?
}

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func emit(_ failure: Failure) {
    var error: [String: Any] = ["kind": failure.kind, "message": failure.message]
    if let reason = failure.reason { error["reason"] = reason }
    emit(["error": error])
}

let tooOld = Failure(kind: "unavailable", message: "Apple Intelligence needs macOS 26 or later", reason: "deviceNotEligible")

#if canImport(FoundationModels)
@available(macOS 26, *)
func unavailable(_ model: SystemLanguageModel) -> Failure? {
    switch model.availability {
    case .available:
        return nil
    case .unavailable(.deviceNotEligible):
        return Failure(kind: "unavailable", message: "This Mac can't run Apple Intelligence", reason: "deviceNotEligible")
    case .unavailable(.appleIntelligenceNotEnabled):
        return Failure(kind: "unavailable", message: "Apple Intelligence is off: System Settings › Apple Intelligence & Siri",
                       reason: "appleIntelligenceNotEnabled")
    case .unavailable(.modelNotReady):
        return Failure(kind: "unavailable", message: "Apple Intelligence is still downloading its model", reason: "modelNotReady")
    case .unavailable(let other):
        return Failure(kind: "unavailable", message: "Apple Intelligence is unavailable: \(other)", reason: "\(other)")
    }
}

/// A JSON Schema node as a DynamicGenerationSchema; `name` is unique per node (objects and choices need one).
@available(macOS 26, *)
func dynamic(_ node: [String: Any], name: String) throws -> DynamicGenerationSchema {
    let description = node["description"] as? String
    if let type = node["type"], !(type is String) {
        throw Failure(kind: "other", message: "schema node \(name): the type must be one string")
    }
    switch node["type"] as? String {
    case "object":
        let properties = node["properties"] as? [String: Any] ?? [:]
        let required = (node["required"] as? [String] ?? []).filter { properties[$0] != nil }
        let order = required + properties.keys.filter { !required.contains($0) }.sorted()
        return DynamicGenerationSchema(name: name, description: description, properties: try order.map { key in
            let child = properties[key] as? [String: Any] ?? [:]
            return DynamicGenerationSchema.Property(name: key, description: child["description"] as? String,
                                                    schema: try dynamic(child, name: "\(name)_\(key)"),
                                                    isOptional: !required.contains(key))
        })
    case "array":
        let items = node["items"] as? [String: Any] ?? ["type": "string"]
        return DynamicGenerationSchema(arrayOf: try dynamic(items, name: "\(name)_item"),
                                       minimumElements: node["minItems"] as? Int, maximumElements: node["maxItems"] as? Int)
    case "string", nil:
        if let choices = node["enum"] as? [String], !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }
        return DynamicGenerationSchema(type: String.self)
    case "integer":
        return DynamicGenerationSchema(type: Int.self)
    case "number":
        return DynamicGenerationSchema(type: Double.self)
    case "boolean":
        return DynamicGenerationSchema(type: Bool.self)
    case let other?:
        throw Failure(kind: "other", message: "schema type \(other) isn't supported")
    }
}

@available(macOS 26, *)
func failure(_ error: Error) -> Failure {
    if let failure = error as? Failure { return failure }
    guard let error = error as? LanguageModelSession.GenerationError else {
        return Failure(kind: "other", message: String(describing: error))
    }
    let message = error.errorDescription ?? String(describing: error)
    switch error {
    case .exceededContextWindowSize: return Failure(kind: "contextWindowExceeded", message: message)
    case .rateLimited, .concurrentRequests: return Failure(kind: "rateLimited", message: message)
    case .guardrailViolation, .refusal: return Failure(kind: "guardrail", message: message)
    case .unsupportedLanguageOrLocale: return Failure(kind: "unsupportedLanguage", message: message)
    case .assetsUnavailable: return Failure(kind: "unavailable", message: message, reason: "modelNotReady")
    default: return Failure(kind: "other", message: message)
    }
}

@available(macOS 26, *)
func answer(_ request: [String: Any]) async throws -> Any {
    let model = SystemLanguageModel.default
    if let failure = unavailable(model) { throw failure }
    if let locale = request["locale"] as? String, !locale.isEmpty, !model.supportsLocale(Locale(identifier: locale)) {
        throw Failure(kind: "unsupportedLanguage", message: "Apple Intelligence doesn't support \(locale) yet")
    }
    guard let prompt = request["prompt"] as? String, let schema = request["schema"] as? [String: Any] else {
        throw Failure(kind: "other", message: "the request needs a prompt and a schema")
    }
    guard schema["type"] as? String == "object" else {
        throw Failure(kind: "other", message: "the schema's root must be an object")
    }
    let generation = try GenerationSchema(root: try dynamic(schema, name: "Answer"), dependencies: [])
    let session = LanguageModelSession(model: model, instructions: request["instructions"] as? String ?? "")
    let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: request["maximumResponseTokens"] as? Int)
    let response = try await session.respond(to: prompt, schema: generation, options: options)
    return try JSONSerialization.jsonObject(with: Data(response.content.jsonString.utf8))
}
#endif

if CommandLine.arguments.contains("--status") {
    var status: Failure? = tooOld
    #if canImport(FoundationModels)
    if #available(macOS 26, *) { status = unavailable(SystemLanguageModel.default) }
    #endif
    if let status {
        emit(["available": false, "reason": status.reason ?? "", "message": status.message])
    } else {
        emit(["available": true])
    }
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let request = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
    emit(Failure(kind: "other", message: "stdin isn't a JSON object"))
    exit(1)
}
#if canImport(FoundationModels)
if #available(macOS 26, *) {
    do {
        emit(["result": try await answer(request)])
        exit(0)
    } catch {
        emit(failure(error))
        exit(1)
    }
}
#endif
emit(tooOld)
exit(1)
