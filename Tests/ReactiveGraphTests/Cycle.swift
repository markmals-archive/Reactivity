import ReactiveGraph
import Testing

// SPEC: error.reactive.cycle
// Exit tests for dependency-cycle detection: the trap (preconditionFailure)
// exits the child process with .failure.
//
// Caveat: `.failure` would also match a generic crash (the pre-trap behavior was
// a stack overflow), so these tests pin "the process dies at the cycle" rather
// than the diagnostic text — exit-test output observation can tighten this when
// the Testing API makes stderr matching ergonomic.

@Suite(.spec("error.reactive.cycle"))
struct CycleTests {

    // Scenario 1 — self-read
    // A derived value whose computation reads its own wrappedValue.
    @Test(.scenario("error.reactive.cycle.self-read"))
    func `traps when a derived computation reads its own value`() async {
        await #expect(processExitsWith: .failure) {
            var readSelf: (() -> Int)!
            @DerivedState var a = readSelf()
            readSelf = { a }
            _ = a
        }
    }

    // Scenario 2 — mutual
    // Two derived values that each read the other. Reading EITHER one must trap.
    @Test(.scenario("error.reactive.cycle.mutual"))
    func `traps when two derived values form a mutual dependency`() async {
        // Reading a first.
        await #expect(processExitsWith: .failure) {
            var readB: (() -> Int)!
            @DerivedState var a = readB()

            var readA: (() -> Int)!
            @DerivedState var b = readA()

            readB = { b }
            readA = { a }

            _ = a
        }

        // Reading b first — the spec guarantees the same trap regardless of entry point.
        await #expect(processExitsWith: .failure) {
            var readB: (() -> Int)!
            @DerivedState var a = readB()

            var readA: (() -> Int)!
            @DerivedState var b = readA()

            readB = { b }
            readA = { a }

            _ = b
        }
    }

    // Scenario 3 — branch-gated
    // A cycle hidden behind a branch that was not taken at activation time.
    // After the condition changes so the branch is taken, reading either value
    // must trap — the cycle cannot lie dormant past its first closing read.
    @Test(.scenario("error.reactive.cycle.branch-gated"))
    func `traps when a branch-gated cycle is activated by a condition change`() async {
        // Topology: s = 0; u = { s == 0 ? 0 : readD() + 1 }; d = u (via closure box).
        // Activation (s == 0): u's body takes the false-branch, never reads d.
        // After s = 1: u's body takes the true-branch and reads d, which reads u.
        await #expect(processExitsWith: .failure) {
            @State var s = 0

            var readD: (() -> Int)!
            @DerivedState var u: Int = s == 0 ? 0 : readD() + 1
            @DerivedState var d: Int = u

            readD = { d }

            // Activate both with branch un-taken (s == 0 → u does NOT read d).
            _ = d

            // Flip the condition so u's body will now read d.
            s = 1

            // Reading d must trap — the cycle closes during re-validation.
            _ = d
        }
    }
}
