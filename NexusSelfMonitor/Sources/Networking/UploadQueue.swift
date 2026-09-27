import Foundation

/// Persistent retry queue for failed uploads. Items are saved to disk and
/// retried with jittered exponential backoff.
///
/// Hardening features:
///  - Atomic disk writes (.atomic) preventing index or media corruption
///  - Bounded storage limit (max 150 items / 50 MB) with FIFO eviction
///  - Circuit breaker: halts batch retries immediately on network drop
///  - Corrupted / 0-byte file self-healing and pruning
///  - Jittered exponential backoff preventing thundering herd
///  - Full integration with DiagnosticsLogger
@MainActor
final class UploadQueue: ObservableObject {
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var totalDiskBytes: Int64 = 0

    private var items: [QueueItem] = []
    private var retryTimer: Timer?
    private var uploadHandler: ((QueueItem) async -> Bool)?

    private let maxRetries: Int = 5
    private let maxQueueCount: Int = 150
    private let maxQueueDiskBytes: Int64 = 50 * 1024 * 1024 // 50 MB limit
    private let queueDir: URL

    struct QueueItem: Codable, Identifiable {
        let id: String          // UUID
        let kind: String        // "audio" | "photo"
        let ext: String         // "m4a" | "jpg"
        let contentType: String
        let sessionId: String
        let seq: Int
        let startedAt: Int64
        let durationMs: Int?
        let filePath: String    // absolute path to temp file on disk
        let byteSize: Int64     // file size in bytes
        var retryCount: Int = 0
        var nextRetryAt: Date = Date()
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        queueDir = appSupport.appendingPathComponent("nexus_upload_queue", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        } catch {
            DiagnosticsLogger.shared.log("Failed to create upload queue directory: \(error.localizedDescription)",
                                         subsystem: .queue, level: .error)
        }

        loadFromDisk()
    }

    /// Set the handler that executes the upload request. Returns true on success.
    func setUploadHandler(_ handler: @escaping (QueueItem) async -> Bool) {
        self.uploadHandler = handler
    }

    /// Enqueue raw media data for durable persistence and scheduled retry.
    func enqueue(kind: String, ext: String, contentType: String,
                 sessionId: String, seq: Int, startedAt: Int64,
                 durationMs: Int?, data: Data) {
        guard !data.isEmpty else {
            DiagnosticsLogger.shared.log("Refusing to enqueue empty 0-byte media for seq \(seq)",
                                         subsystem: .queue, level: .warn)
            return
        }

        let id = UUID().uuidString
        let fileURL = queueDir.appendingPathComponent("\(id).\(ext)")

        // Atomic write to prevent partial file writes
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DiagnosticsLogger.shared.log("Failed writing queue item to disk (\(kind) #\(seq)): \(error.localizedDescription)",
                                         subsystem: .queue, level: .error)
            return
        }

        let item = QueueItem(
            id: id,
            kind: kind,
            ext: ext,
            contentType: contentType,
            sessionId: sessionId,
            seq: seq,
            startedAt: startedAt,
            durationMs: durationMs,
            filePath: fileURL.path,
            byteSize: Int64(data.count)
        )

        items.append(item)
        enforceQueueBounds()
        saveToDisk()

        DiagnosticsLogger.shared.log("Enqueued failed \(kind) #\(seq) (\(data.count / 1024) KB). Queue depth: \(items.count)",
                                     subsystem: .queue, level: .warn)

        ensureRetryTimer()
    }

    /// Enqueue a file from an existing location on disk.
    func enqueueFile(kind: String, ext: String, contentType: String,
                     sessionId: String, seq: Int, startedAt: Int64,
                     durationMs: Int?, fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            DiagnosticsLogger.shared.log("Failed to read file for queue: \(fileURL.lastPathComponent)",
                                         subsystem: .queue, level: .error)
            return
        }
        enqueue(kind: kind, ext: ext, contentType: contentType,
                sessionId: sessionId, seq: seq, startedAt: startedAt,
                durationMs: durationMs, data: data)
    }

    func startProcessing() {
        ensureRetryTimer()
    }

    func stopProcessing() {
        retryTimer?.invalidate()
        retryTimer = nil
        isProcessing = false
    }

    /// User or system triggered immediate retry attempt.
    func retryNow() {
        let now = Date()
        for i in 0..<items.count {
            items[i].nextRetryAt = now
        }
        Task { await processQueue() }
    }

    // MARK: - Queue Processing & Circuit Breaker

    private func ensureRetryTimer() {
        guard retryTimer == nil, !items.isEmpty else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processQueue() }
        }
    }

    private func processQueue() async {
        guard !isProcessing, let handler = uploadHandler, !items.isEmpty else { return }
        isProcessing = true
        defer { isProcessing = false }

        let now = Date()
        var remaining: [QueueItem] = []
        var circuitBroken = false

        for var item in items {
            // If network failed previously in this cycle, stop processing remaining items to avoid redundant timeouts.
            if circuitBroken {
                remaining.append(item)
                continue
            }

            guard item.nextRetryAt <= now else {
                remaining.append(item)
                continue
            }

            // Verify file integrity before attempting upload.
            let fileURL = URL(fileURLWithPath: item.filePath)
            guard FileManager.default.fileExists(atPath: item.filePath),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: item.filePath),
                  (attributes[.size] as? Int64 ?? 0) > 0 else {
                DiagnosticsLogger.shared.log("Purging missing or 0-byte item: \(item.kind) #\(item.seq)",
                                             subsystem: .queue, level: .error)
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }

            DiagnosticsLogger.shared.log("Retrying upload for \(item.kind) #\(item.seq) (Attempt \(item.retryCount + 1)/\(maxRetries))",
                                         subsystem: .queue, level: .info)

            let success = await handler(item)
            if success {
                DiagnosticsLogger.shared.log("Successfully uploaded queued \(item.kind) #\(item.seq)",
                                             subsystem: .queue, level: .info)
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                item.retryCount += 1
                if item.retryCount < maxRetries {
                    // Exponential backoff with ±20% randomized jitter: 5s, 10s, 20s, 40s, 80s
                    let baseDelay = Double(5 * (1 << item.retryCount))
                    let jitterFactor = Double.random(in: 0.8...1.2)
                    let finalDelay = baseDelay * jitterFactor
                    item.nextRetryAt = Date().addingTimeInterval(finalDelay)
                    remaining.append(item)

                    DiagnosticsLogger.shared.log("Retry failed for \(item.kind) #\(item.seq). Next retry in \(Int(finalDelay))s",
                                                 subsystem: .queue, level: .warn)
                } else {
                    DiagnosticsLogger.shared.log("Discarding \(item.kind) #\(item.seq) after \(maxRetries) failed retries.",
                                                 subsystem: .queue, level: .error)
                    try? FileManager.default.removeItem(at: fileURL)
                }

                // Trip circuit breaker on failure to prevent hammering when offline
                circuitBroken = true
            }
        }

        items = remaining
        enforceQueueBounds()
        saveToDisk()

        if items.isEmpty {
            retryTimer?.invalidate()
            retryTimer = nil
        }
    }

    // MARK: - Bounds & Disk Persistence

    private func enforceQueueBounds() {
        // Enforce item count limit
        if items.count > maxQueueCount {
            let excess = items.count - maxQueueCount
            let discarded = items.prefix(excess)
            for item in discarded {
                try? FileManager.default.removeItem(atPath: item.filePath)
            }
            items.removeFirst(excess)
            DiagnosticsLogger.shared.log("Queue count capped: purged \(excess) oldest items.",
                                         subsystem: .queue, level: .warn)
        }

        // Calculate and enforce byte size limit
        var currentBytes: Int64 = 0
        for item in items {
            currentBytes += item.byteSize
        }

        while currentBytes > maxQueueDiskBytes && !items.isEmpty {
            let evicted = items.removeFirst()
            currentBytes -= evicted.byteSize
            try? FileManager.default.removeItem(atPath: evicted.filePath)
            DiagnosticsLogger.shared.log("Queue disk limit exceeded: evicted item \(evicted.id)",
                                         subsystem: .queue, level: .warn)
        }

        totalDiskBytes = currentBytes
        pendingCount = items.count
    }

    private var indexPath: URL { queueDir.appendingPathComponent("queue_index.json") }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexPath, options: .atomic)
        } catch {
            DiagnosticsLogger.shared.log("Failed to save queue index: \(error.localizedDescription)",
                                         subsystem: .queue, level: .error)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: indexPath),
              let loaded = try? JSONDecoder().decode([QueueItem].self, from: data) else {
            pendingCount = 0
            totalDiskBytes = 0
            return
        }

        // Validate on startup: only keep items whose files still exist on disk with > 0 bytes
        var valid: [QueueItem] = []
        var totalBytes: Int64 = 0

        for item in loaded {
            let fm = FileManager.default
            if fm.fileExists(atPath: item.filePath),
               let attr = try? fm.attributesOfItem(atPath: item.filePath),
               let size = attr[.size] as? Int64, size > 0 {
                valid.append(item)
                totalBytes += size
            } else {
                try? fm.removeItem(atPath: item.filePath)
            }
        }

        items = valid
        totalDiskBytes = totalBytes
        pendingCount = items.count

        DiagnosticsLogger.shared.log("Loaded \(items.count) queued uploads from disk (\(totalDiskBytes / 1024) KB).",
                                     subsystem: .queue, level: .info)
    }
}
