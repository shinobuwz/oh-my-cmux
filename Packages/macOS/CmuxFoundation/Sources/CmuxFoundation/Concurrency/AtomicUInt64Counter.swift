internal import CmuxFoundationAtomicsC

/// A macOS 14-compatible atomic counter for process-global resource accounting.
///
/// `macOS 14` predates the Swift `Synchronization` module's `Atomic` type, so the
/// atomic is owned by a stable C11 allocation (`CmuxAtomicUInt64Storage`) and every
/// pointee access goes through `<stdatomic.h>` primitives. C11 owns the
/// synchronization, which is why the imported storage is safe to share across
/// concurrency domains even though Swift cannot prove it — the same model used by
/// ``AtomicBooleanGate`` and ``AtomicUInt64Generation``.
///
/// **Memory ordering.** Every operation is relaxed. This type counts resources for
/// diagnostic observation (for example, live `FSEventStream` ownership exposed via
/// ``RecursivePathWatcher/activeStreamCount``); it never publishes access to other
/// memory and never gates a destructive action. Stronger ordering would add a fence
/// without buying a guarantee, because the count is a best-effort snapshot of
/// continuously-changing process-wide state.
///
/// **Decrement safety.** `decrementRelaxed()` is *non-underflowing*: once the
/// counter reaches zero it stays at zero instead of wrapping to `UInt64.max`. This
/// is what makes the counter safe for idempotent teardown paths — a real
/// `FSEventStream` is stopped from explicit `stop()`, from `deinit`, and from
/// repeated stops — where an extra decrement must never drive the process-global
/// count negative and corrupt every other owner's accounting. The increment
/// saturates at `UInt64.max` symmetrically, preserving monotonicity for the
/// lifetime of the process.
public final class AtomicUInt64Counter: @unchecked Sendable {
    // The pointer is allocated once and never changes. C11 owns every access to
    // its pointee, so concurrent calls do not form overlapping Swift `inout`
    // accesses and Thread Sanitizer sees the atomic synchronization directly.
    nonisolated(unsafe) private let storage: UnsafeMutablePointer<CmuxAtomicUInt64Storage>

    /// Creates a counter with the supplied initial value.
    ///
    /// - Parameter initialValue: The value returned by ``loadRelaxed()`` until the
    ///   first increment or decrement.
    public init(_ initialValue: UInt64 = 0) {
        storage = .allocate(capacity: 1)
        CmuxAtomicUInt64Initialize(storage, initialValue)
    }

    deinit {
        storage.deallocate()
    }

    /// Returns the current count with relaxed memory ordering.
    @inline(__always)
    public func loadRelaxed() -> UInt64 {
        CmuxAtomicUInt64LoadRelaxed(storage)
    }

    /// Atomically increments the counter and returns its new value.
    ///
    /// The counter saturates at `UInt64.max` instead of wrapping, so a runaway
    /// incrementer cannot corrupt a monotonic count.
    ///
    /// - Returns: The count immediately following the prior value, or
    ///   `UInt64.max` when the counter is already saturated.
    @inline(__always)
    public func incrementRelaxed() -> UInt64 {
        CmuxAtomicUInt64AdvanceRelaxed(storage)
    }

    /// Atomically decrements the counter and returns its new value.
    ///
    /// This operation is **non-underflowing**: when the counter is already zero it
    /// returns zero and leaves the value unchanged instead of wrapping to
    /// `UInt64.max`. That makes it safe to call from idempotent teardown paths
    /// (repeated `stop()`, `deinit`) where an extra decrement must never make the
    /// process-global count negative. See the type-level discussion for the full
    /// rationale.
    ///
    /// - Returns: The count immediately preceding the prior value, or `0` when the
    ///   counter is already zero.
    @inline(__always)
    public func decrementRelaxed() -> UInt64 {
        CmuxAtomicUInt64DecrementRelaxed(storage)
    }
}
