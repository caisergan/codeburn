import CoreServices
import Foundation

/// "Keep Claude session numbers live while Claude is working". On by default;
/// off restores the old behaviour, where limits are read only when the popover
/// opens, a window resets, or the quota cadence says so.
enum ClaudeLiveReadingPreference {
    static let defaultsKey = "codeburn.claudeSessions.liveWhileActive"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// Knows when Claude Code last wrote a transcript, from FSEvents on the default
/// Claude config directory's `projects/` tree. No polling: the stream wakes the
/// app only when a transcript is written, and the refresh loop asks
/// `lastWriteAt` on its own ticks.
///
/// Antigravity's conversations use one too (`AntigravityActivity.monitor`),
/// with its own file suffixes and several directories.
final class ClaudeActivityMonitor: @unchecked Sendable {
    static let shared = ClaudeActivityMonitor()

    private let lock = NSLock()
    private var _lastWriteAt: Date?
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private let queue: DispatchQueue
    /// The file names that count as a write.
    let suffixes: [String]

    init(label: String = "org.agentseal.codeburn.claude-activity", suffixes: [String] = [".jsonl"]) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.suffixes = suffixes
    }

    var lastWriteAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastWriteAt
    }

    /// Test seam and FSEvents callback target.
    func noteWrite(at date: Date = Date()) {
        lock.lock()
        if _lastWriteAt.map({ date > $0 }) ?? true { _lastWriteAt = date }
        lock.unlock()
    }

    /// The directory V1 follows: the default account's transcripts. Readings
    /// come from the default account, so another account's activity would not
    /// move the numbers they feed.
    static func defaultProjectsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        UsageDataChangeGuard.claudeConfigDirectories(environment: environment, homeDirectory: homeDirectory)
            .first
            .map { ($0 as NSString).appendingPathComponent("projects") }
    }

    /// Starts (or re-targets) the stream. Idempotent for the same path.
    func start(path: String? = ClaudeActivityMonitor.defaultProjectsDirectory()) {
        guard let path else { return }
        start(paths: [path])
    }

    /// Watches every existing directory in `paths`. Idempotent for the same
    /// set.
    func start(paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty, existing != watchedPaths || stream == nil else { return }
        stopLocked()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<ClaudeActivityMonitor>.fromOpaque(info).takeUnretainedValue()
            let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            for index in 0..<count {
                let flag = Int(flags[index])
                let isFile = flag & kFSEventStreamEventFlagItemIsFile != 0
                let written = flag & (kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated) != 0
                let name = index < names.count ? names[index] : ""
                if isFile, written, monitor.suffixes.contains(where: { name.hasSuffix($0) }) {
                    monitor.noteWrite()
                    return
                }
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            5.0,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
        watchedPaths = existing
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPaths = []
    }
}
