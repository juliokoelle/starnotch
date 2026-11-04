// Reads a JSON array of regex patterns on standard input and prints a JSON array of booleans:
// whether NSRegularExpression compiles each. convert.py runs it (`swift check_regex.swift`), on
// macOS or Linux.
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let patterns = try? JSONDecoder().decode([String].self, from: input) else {
    FileHandle.standardError.write(Data("expected a JSON array of strings\n".utf8))
    exit(1)
}
let answers = patterns.map { (try? NSRegularExpression(pattern: $0, options: [])) != nil }
print(String(decoding: try JSONEncoder().encode(answers), as: UTF8.self))
