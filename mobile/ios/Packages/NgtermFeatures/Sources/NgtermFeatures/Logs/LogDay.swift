/// The lines of one day, newest first.
internal struct LogDay: Identifiable {
    /// A line with its place on the page.
    internal struct Item: Identifiable {
        internal let id: Int
        internal let line: LogLine
    }

    internal let id: Int
    internal let day: String
    internal let lines: [Item]

    /// `lines` (newest first) under their days, in their order; a line without a day stays under the one before.
    internal static func days(of lines: [LogLine]) -> [Self] {
        var days: [Self] = []
        var current: (day: String, items: [Item])?
        for (index, line) in lines.enumerated() {
            if let open = current, line.day.isEmpty || line.day == open.day {
                current?.items.append(Item(id: index, line: line))
                continue
            }
            if let open = current {
                days.append(Self(id: days.count, day: open.day, lines: open.items))
            }
            current = (line.day, [Item(id: index, line: line)])
        }
        if let open = current {
            days.append(Self(id: days.count, day: open.day, lines: open.items))
        }
        return days
    }
}
