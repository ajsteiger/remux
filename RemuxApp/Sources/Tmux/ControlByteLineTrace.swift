import Foundation

enum ControlByteTraceDirection: String {
    case inbound = "rx"
    case outbound = "tx"
}

struct ControlByteLineTraceLine: Equatable {
    let sequence: Int
    let lineByteCount: Int
    let preview: String

    init(
        sequence: Int,
        rawLine: Data.SubSequence,
        previewLimit: Int
    ) {
        self.sequence = sequence
        self.lineByteCount = rawLine.count
        self.preview = GhosttyRuntimeTrace.preview(Data(rawLine), limit: previewLimit)
    }
}

struct ControlByteLineTraceAccumulator {
    private static let maximumBufferedByteCount = 16 * 1024

    private var bufferedBytes = Data()
    private var nextSequence = 1

    mutating func append(
        _ data: Data,
        previewLimit: Int
    ) -> [ControlByteLineTraceLine] {
        guard !data.isEmpty else { return [] }

        bufferedBytes.append(data)
        var records: [ControlByteLineTraceLine] = []
        while let newlineIndex = bufferedBytes.firstIndex(of: 0x0A) {
            var lineBytes = bufferedBytes[..<newlineIndex]
            bufferedBytes.removeSubrange(bufferedBytes.startIndex...newlineIndex)
            if lineBytes.last == 0x0D {
                lineBytes = lineBytes.dropLast()
            }
            records.append(
                ControlByteLineTraceLine(
                    sequence: nextSequence,
                    rawLine: lineBytes,
                    previewLimit: previewLimit
                )
            )
            nextSequence += 1
        }

        if bufferedBytes.count > Self.maximumBufferedByteCount {
            let lineBytes = bufferedBytes.prefix(Self.maximumBufferedByteCount)
            records.append(
                ControlByteLineTraceLine(
                    sequence: nextSequence,
                    rawLine: lineBytes,
                    previewLimit: previewLimit
                )
            )
            nextSequence += 1
            bufferedBytes.removeAll(keepingCapacity: false)
        }

        return records
    }

    var pendingByteCount: Int {
        bufferedBytes.count
    }
}
