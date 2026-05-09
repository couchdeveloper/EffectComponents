
// MARK: - ViewState Helpers

enum Empty {
    case blank
}

enum Content<Value> {
    case empty(Empty)
    case content(Value)
}
