import Darwin
import Foundation

// MARK: - Job Control: bg, fg, jobs, Ctrl-Z support
// Enables running processes in the background, suspending with Ctrl-Z,
// and switching between foreground/background jobs.

// C macros for wait status aren't available in Swift — reimplement them
private func _WSTATUS(_ x: Int32) -> Int32 { x & 0x7f }
private let _WSTOPPED: Int32 = 0x7f
private func wIfStopped(_ x: Int32) -> Bool { _WSTATUS(x) == _WSTOPPED && (x >> 8) != 0x13 }
private func wIfExited(_ x: Int32) -> Bool { _WSTATUS(x) == 0 }
private func wExitStatus(_ x: Int32) -> Int32 { (x >> 8) & 0xff }

public enum JobState: String, Codable, Sendable {
    case running
    case stopped
    case done
}

public struct Job: Sendable {
    public let id: Int
    public let pid: pid_t
    public let command: String
    public let startedAt: Date
    public var state: JobState
    public var isForeground: Bool
}

public final class JobTable: @unchecked Sendable {
    private var jobs: [Int: Job] = [:]
    private var nextId = 1

    /// Add a new job (launched with &)
    @discardableResult
    public func add(pid: pid_t, command: String, foreground: Bool = false) -> Job {
        let job = Job(
            id: nextId,
            pid: pid,
            command: command,
            startedAt: Date(),
            state: .running,
            isForeground: foreground
        )
        jobs[nextId] = job
        nextId += 1
        return job
    }

    /// List all jobs
    public func list() -> [Job] {
        reapCompleted()
        return jobs.values.sorted { $0.id < $1.id }
    }

    /// Get a specific job by ID
    public func job(_ id: Int) -> Job? {
        reapCompleted()
        return jobs[id]
    }

    /// Get the most recent job
    public var current: Job? {
        reapCompleted()
        return jobs.values.max(by: { $0.id < $1.id })
    }

    /// Move a stopped job to the foreground and continue it
    public func foreground(_ jobId: Int? = nil) -> Job? {
        reapCompleted()
        let id = jobId ?? current?.id
        guard let id, var job = jobs[id] else { return nil }

        // Send SIGCONT to resume
        kill(job.pid, SIGCONT)
        job.state = .running
        job.isForeground = true
        jobs[id] = job

        // Wait for the process
        var status: Int32 = 0
        waitpid(job.pid, &status, WUNTRACED)

        if wIfStopped(status) {
            job.state = .stopped
            job.isForeground = false
            jobs[id] = job
            return job
        }

        // Process exited
        job.state = .done
        jobs[id] = job
        cleanupDone()
        return job
    }

    /// Resume a stopped job in the background
    public func background(_ jobId: Int? = nil) -> Job? {
        reapCompleted()
        let id = jobId ?? current?.id
        guard let id, var job = jobs[id] else { return nil }

        kill(job.pid, SIGCONT)
        job.state = .running
        job.isForeground = false
        jobs[id] = job
        return job
    }

    /// Mark a job as stopped (from Ctrl-Z / SIGTSTP)
    public func markStopped(pid: pid_t) {
        for (id, var job) in jobs {
            if job.pid == pid {
                job.state = .stopped
                job.isForeground = false
                jobs[id] = job
                return
            }
        }
    }

    /// Reap any completed background jobs
    @discardableResult
    public func reapCompleted() -> [Job] {
        var completed: [Job] = []
        for (id, var job) in jobs where job.state == .running && !job.isForeground {
            var status: Int32 = 0
            let result = waitpid(job.pid, &status, WNOHANG)
            if result > 0 {
                job.state = .done
                jobs[id] = job
                completed.append(job)
            }
        }
        return completed
    }

    /// Remove done jobs from the table
    public func cleanupDone() {
        jobs = jobs.filter { $0.value.state != .done }
    }

    public var isEmpty: Bool { jobs.isEmpty }
    public var count: Int { jobs.count }
}
