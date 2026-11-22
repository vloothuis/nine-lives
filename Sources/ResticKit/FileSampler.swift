import Foundation

/// A file seen during a backup. The path has no leading slash, like catalog paths.
public struct SampledFile: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

/// Picks files evenly spread over a stream of unknown length, with fixed memory.
///
/// The stream is split into blocks of `stride` items and one random file is kept per block.
/// When the buffer is full, the stride doubles and each pair of neighbouring samples is reduced to one.
/// restic visits files in tree order, so the samples are spread over the whole folder tree.
public final class FileSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var generator: any RandomNumberGenerator
    private var samples: [SampledFile] = []
    private var stride = 1
    private var index = 0
    private var blockEnd = 1
    private var pick = 0
    private var filled = false

    public init(capacity: Int = 64, generator: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        precondition(capacity >= 2 && capacity % 2 == 0)
        self.capacity = capacity
        self.generator = generator
    }

    /// Call once per item. Returns true when the caller should decode the item and pass it to `keep`.
    public func shouldInspect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if index == blockEnd { startBlock() }
        defer { index += 1 }
        return !filled && index >= pick
    }

    /// Keeps a file for the current block. Ignored when the block already has one.
    public func keep(_ file: SampledFile) {
        lock.lock(); defer { lock.unlock() }
        guard !filled else { return }
        samples.append(file)
        filled = true
    }

    public var result: [SampledFile] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func startBlock() {
        if samples.count >= capacity {
            stride *= 2
            samples = Swift.stride(from: 0, to: samples.count, by: 2).map { i in
                i + 1 < samples.count && Bool.random(using: &generator) ? samples[i + 1] : samples[i]
            }
        }
        pick = index + Int.random(in: 0..<stride, using: &generator)
        blockEnd = index + stride
        filled = false
    }
}
