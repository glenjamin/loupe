import Foundation

public enum CodeWordDirection: Sendable {
    case left, right
}

/// Where a code editor's word movement lands from `offset` (in UTF-16 units, as `NSTextView`
/// counts) in `text`. Characters fall into words (letters, digits and underscores),
/// whitespace, and punctuation (everything else). A move skips any whitespace, then one run of
/// words or of punctuation, so `obj.Field` has stops at each edge of `obj`, `.` and `Field`,
/// and whitespace is never a stop of its own.
public func codeWordBoundary(in text: String, from offset: Int, _ direction: CodeWordDirection) -> Int {
    let characters = Array(text)
    var index = characterIndex(in: characters, utf16Offset: offset)
    switch direction {
    case .left:
        while index > 0, characters[index - 1].codeWordClass == .whitespace { index -= 1 }
        if index > 0 {
            let run = characters[index - 1].codeWordClass
            while index > 0, characters[index - 1].codeWordClass == run { index -= 1 }
        }
    case .right:
        while index < characters.count, characters[index].codeWordClass == .whitespace { index += 1 }
        if index < characters.count {
            let run = characters[index].codeWordClass
            while index < characters.count, characters[index].codeWordClass == run { index += 1 }
        }
    }
    return characters[..<index].reduce(0) { $0 + $1.utf16.count }
}

private enum CodeWordClass {
    case word, whitespace, punctuation
}

private extension Character {
    var codeWordClass: CodeWordClass {
        if isLetter || isNumber || self == "_" { return .word }
        if isWhitespace { return .whitespace }
        return .punctuation
    }
}

/// The index of the first character starting at or after `utf16Offset`, clamped to the text.
private func characterIndex(in characters: [Character], utf16Offset: Int) -> Int {
    var consumed = 0
    for (index, character) in characters.enumerated() {
        if consumed >= utf16Offset { return index }
        consumed += character.utf16.count
    }
    return characters.count
}
