import Foundation

/// One Gateway call, sorted into the branches every Settings store handles: a value, an unknown
/// method, a missing scope, or any other failure. Unknown method wins over missing scope.
public enum GatewayCallOutcome<Value> {
    case success(Value)
    case unknownMethod(Error)
    case missingScope(Error)
    case failure(Error)

    @MainActor public static func run(_ body: @MainActor () async throws -> Value) async -> GatewayCallOutcome<Value> {
        do {
            return .success(try await body())
        } catch let error where GatewayError.isUnknownMethod(error) {
            return .unknownMethod(error)
        } catch let error where GatewayError.isMissingScope(error) {
            return .missingScope(error)
        } catch {
            return .failure(error)
        }
    }
}
