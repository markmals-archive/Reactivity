import ReactiveGraph
import Testing

// SPEC: behavior.reactive.write-visibility
// Tests for the no-lost-updates invariant from domain.signal.

@Suite(.spec("behavior.reactive.write-visibility"))
struct WriteVisibilityTests {

    // Scenario 1 — write-during-recompute
    // A derived value writes its own source mid-body (after the tracked read).
    // The write must not be swallowed when the recomputation commits.
    // Expected: RED until the invalidation-generation guard is implemented.
    @Test(.scenario("behavior.reactive.write-visibility.write-during-recompute"))
    func `does not lose a write that lands while a derived value is recomputing`() {
        withReactiveScope {
            var computationCount = 0
            @State var source = 0
            @DerivedState var d = {
                computationCount += 1
                let v = source
                if v < 1 { source = v + 1 }  // write lands mid-recompute, after the tracked read
                return v
            }()

            // First read: computed from pre-write value (source was 0 when read).
            #expect(d == 0)
            #expect(computationCount == 1)

            // The mid-body write (source = 1) must not be lost.
            // Second read: should recompute from the written value.
            #expect(d == 1)
            #expect(computationCount == 2)
        }
    }
}
