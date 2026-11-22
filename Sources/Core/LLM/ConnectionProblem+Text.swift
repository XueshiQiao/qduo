import Foundation
import AIModelKit

/// How QDuo words the causes `AIModelKit` sorts a failed call into.
extension ConnectionProblem {
    var localizedText: String {
        switch self {
        case .badAddress:                 return L("models.problem.badAddress")
        case .cannotConnect(let message): return String(format: L("models.problem.cannotConnect"), message)
        case .timedOut:                   return L("models.problem.timedOut")
        case .keyRejected(let message):   return String(format: L("models.problem.keyRejected"), message)
        case .notFound(let message):      return String(format: L("models.problem.notFound"), message)
        case .noModel:                    return L("models.problem.noModel")
        case .service(let status, let m): return String(format: L("models.problem.service"), status, m)
        case .badResponse(let message):   return String(format: L("models.problem.badResponse"), message)
        }
    }
}
