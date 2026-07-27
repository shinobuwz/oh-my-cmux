import Testing
@testable import CmuxFoundation

@Suite
struct AtomicUInt64CounterTests {
    @Test func startsAtZeroAndTracksSequentialIncrementsAndDecrements() {
        let counter = AtomicUInt64Counter()
        #expect(counter.loadRelaxed() == 0)
        #expect(counter.incrementRelaxed() == 1)
        #expect(counter.incrementRelaxed() == 2)
        #expect(counter.loadRelaxed() == 2)
        #expect(counter.decrementRelaxed() == 1)
        #expect(counter.decrementRelaxed() == 0)
        #expect(counter.loadRelaxed() == 0)
    }

    @Test func honorsInjectedInitialValue() {
        let counter = AtomicUInt64Counter(7)
        #expect(counter.loadRelaxed() == 7)
        #expect(counter.incrementRelaxed() == 8)
        #expect(counter.decrementRelaxed() == 7)
    }

    /// The decrement is non-underflowing: a counter already at zero stays at zero
    /// no matter how many extra decrements arrive. This is the contract the
    /// idempotent `FSEventStream` teardown relies on — a plain wrapping decrement
    /// here would fail it.
    @Test func decrementNeverUnderflowsPastZero() {
        let counter = AtomicUInt64Counter()
        for _ in 0..<100 {
            #expect(counter.decrementRelaxed() == 0)
        }
        #expect(counter.loadRelaxed() == 0)

        #expect(counter.incrementRelaxed() == 1)
        #expect(counter.decrementRelaxed() == 0)
        // Extra decrements after draining remain clamped at zero.
        for _ in 0..<50 {
            #expect(counter.decrementRelaxed() == 0)
        }
        #expect(counter.loadRelaxed() == 0)
    }

    @Test func incrementSaturatesAtMax() {
        let counter = AtomicUInt64Counter(UInt64.max - 1)
        #expect(counter.incrementRelaxed() == UInt64.max)
        #expect(counter.incrementRelaxed() == UInt64.max)
        #expect(counter.loadRelaxed() == UInt64.max)
    }

    /// Concurrent increments hand out unique, monotonically increasing values and
    /// leave the counter at the total count.
    @Test func concurrentIncrementsReturnUniqueMonotonicValues() async {
        let counter = AtomicUInt64Counter()
        let values = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in 0..<100 {
                group.addTask { counter.incrementRelaxed() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(Set(values).count == 100)
        #expect(values.min() == 1)
        #expect(values.max() == 100)
        #expect(counter.loadRelaxed() == 100)
    }

    /// More decrements than increments, run concurrently: every observed value
    /// stays at or below the increment total (a non-underflow-safe decrement would
    /// wrap toward `UInt64.max` and blow past it), and the count settles at exactly
    /// zero once the surplus decrements have clamped.
    @Test func concurrentExcessDecrementsClampAtZeroWithoutUnderflow() async {
        let counter = AtomicUInt64Counter()
        let increments = 1_000
        let decrements = 4_000

        let worst = await withTaskGroup(of: UInt64.self, returning: UInt64.self) { group in
            for _ in 0..<increments {
                group.addTask { counter.incrementRelaxed() }
            }
            for _ in 0..<decrements {
                group.addTask { counter.decrementRelaxed() }
            }
            var worst: UInt64 = 0
            for await result in group {
                if result > worst { worst = result }
            }
            return worst
        }

        // Increment outputs cap at `increments`; a clamped decrement outputs 0.
        // A wrapping decrement would surface a value near `UInt64.max`.
        #expect(worst <= UInt64(increments))
        // Surplus decrements consume all increment credit and clamp, so the count
        // settles at exactly zero.
        #expect(counter.loadRelaxed() == 0)
    }
}
