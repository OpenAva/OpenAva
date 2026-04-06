import Foundation

@MainActor
enum QueryEvent {
    case loading(String?)
    case refresh(scrolling: Bool)
    case result(QueryResult)
}
