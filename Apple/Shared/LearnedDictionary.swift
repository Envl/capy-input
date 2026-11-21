import Foundation

struct LearnedWord: Identifiable, Equatable {
    var code: String
    var text: String
    var commits: Int
    var weight: Double
    var tick: UInt64
    var id: String { code + "\t" + text }
    var deleted: Bool { commits < 0 }

    static func validate(text: String, code: String) throws {
        for value in [text, code] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.contains(where: { "\t\r\n\0".contains($0) }), value.utf8.count <= 4096 else {
                throw AppError(L10n.invalidWordOrCode)
            }
        }
    }
}

struct LearnedDictionary: Identifiable {
    let name: String
    var words: [LearnedWord]
    var tick: UInt64
    var id: String { name }
    var visibleWords: [LearnedWord] { words.filter { !$0.deleted }.sorted { $0.commits == $1.commits ? $0.text < $1.text : $0.commits > $1.commits } }

    init(data: Data, expectedName: String? = nil) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw AppError(L10n.thisLearnedDictionaryIsNotUTF8Text) }
        var names = [String](), entries = [LearnedWord](), clock: UInt64 = 0, seen = Set<String>()
        for (index, line) in text.components(separatedBy: .newlines).enumerated() where !line.isEmpty {
            if line.hasPrefix("#@/db_name\t") { names.append(String(line.dropFirst(11))); continue }
            if line.hasPrefix("#@/tick\t") {
                guard let value = UInt64(line.dropFirst(8)) else { throw AppError(L10n.invalidClockOnLine(index + 1)) }
                clock = max(clock, value)
                continue
            }
            if line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { throw AppError(L10n.invalidWordOnLine(index + 1)) }
            let code = fields[0].trimmingCharacters(in: .whitespaces)
            try LearnedWord.validate(text: fields[1], code: code)
            var properties = [String: String]()
            for field in fields[2].split(separator: " ") {
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, properties[pair[0]] == nil else { throw AppError(L10n.invalidStatisticsOnLine(index + 1)) }
                properties[pair[0]] = pair[1]
            }
            guard let commits = properties["c"].flatMap(Int.init), commits > Int(Int32.min), commits <= Int(Int32.max),
                  let weight = properties["d"].flatMap(Double.init), weight.isFinite, weight >= 0,
                  let tick = properties["t"].flatMap(UInt64.init) else { throw AppError(L10n.invalidStatisticsOnLine(index + 1)) }
            let entry = LearnedWord(code: code, text: fields[1], commits: commits, weight: weight, tick: tick)
            guard seen.insert(entry.id).inserted else { throw AppError(L10n.duplicateWordOnLine(index + 1)) }
            entries.append(entry)
            clock = max(clock, tick)
        }
        guard names.count == 1, !names[0].isEmpty, expectedName == nil || expectedName == names[0] else {
            throw AppError(L10n.theDictionaryNameDoesNotMatchItsFile)
        }
        name = names[0]
        words = entries
        tick = clock
    }

    static func merged(_ values: [LearnedDictionary]) throws -> LearnedDictionary {
        guard var result = values.first, values.allSatisfy({ $0.name == result.name }) else { throw AppError(L10n.chooseOneLearnedDictionary) }
        var entries = [String: LearnedWord]()
        for dictionary in values {
            result.tick = max(result.tick, dictionary.tick)
            for word in dictionary.words {
                if let current = entries[word.id] {
                    var winner = abs(current.commits) > abs(word.commits) ||
                        (abs(current.commits) == abs(word.commits) && (current.deleted || !word.deleted)) ? current : word
                    winner.weight = max(current.weight, word.weight)
                    winner.tick = max(current.tick, word.tick)
                    entries[word.id] = winner
                } else { entries[word.id] = word }
            }
        }
        result.words = Array(entries.values)
        return result
    }

    mutating func delete(_ text: String) throws -> Bool {
        let matches = words.indices.filter { words[$0].text == text && !words[$0].deleted }
        guard !matches.isEmpty else { return false }
        guard tick < UInt64.max, matches.allSatisfy({ words[$0].commits < Int(Int32.max) }) else {
            throw AppError(L10n.unsafeWordStatistics)
        }
        tick += 1
        // Rime keeps the larger absolute commit count. A stronger negative count
        // makes each reading stay deleted when an older device syncs.
        for index in matches {
            words[index].commits = -(words[index].commits + 1)
            words[index].tick = tick
        }
        return true
    }

    func encoded(user: String) -> Data {
        var lines = ["# Rime user dictionary", "#@/db_name\t" + name, "#@/db_type\tuserdb", "#@/user_id\t" + user, "#@/tick\t\(tick)"]
        lines += words.sorted { $0.id < $1.id }.map { "\($0.code) \t\($0.text)\tc=\($0.commits) d=\($0.weight) t=\($0.tick)" }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
