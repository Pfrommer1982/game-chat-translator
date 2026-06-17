import Foundation

final class AudioRingBuffer {
    private let sampleRate: Int
    private let capacity: Int
    private var samples: [Float] = []
    private let lock = NSLock()

    init(sampleRate: Int = 16_000, maxDurationSeconds: Double = 15) {
        self.sampleRate = sampleRate
        self.capacity = max(1, Int(maxDurationSeconds * Double(sampleRate)))
        self.samples.reserveCapacity(self.capacity)
    }

    var durationSeconds: Double {
        lock.withLock {
            Double(samples.count) / Double(sampleRate)
        }
    }

    func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }

        lock.withLock {
            samples.append(contentsOf: newSamples)
            clearOldSamplesLocked()
        }
    }

    func readLast(seconds: Double) -> [Float] {
        lock.withLock {
            let count = min(samples.count, Int(seconds * Double(sampleRate)))
            guard count > 0 else { return [] }
            return Array(samples.suffix(count))
        }
    }

    func popChunk(seconds: Double, keepingOverlap overlapSeconds: Double = 0) -> [Float] {
        lock.withLock {
            let requested = Int(seconds * Double(sampleRate))
            guard samples.count >= requested else { return [] }

            let chunk = Array(samples.prefix(requested))
            let overlap = max(0, Int(overlapSeconds * Double(sampleRate)))
            let removeCount = min(samples.count, max(0, requested - overlap))
            if removeCount > 0 {
                samples.removeFirst(removeCount)
            }
            clearOldSamplesLocked()
            return chunk
        }
    }

    func clearOldSamples() {
        lock.withLock {
            clearOldSamplesLocked()
        }
    }

    private func clearOldSamplesLocked() {
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

