import ReactiveGraph
import Testing

// SPEC: behavior.reactive.equality-gating
// Tests for the custom-comparator surface on State and DerivedState.

@Suite(.spec("behavior.reactive.equality-gating"))
struct ComparatorTests {

    // Scenario 7 — equal-write-noop
    // Expected: GREEN immediately (the Equatable-init path already gates writes).
    @Test(.scenario("behavior.reactive.equality-gating.equal-write-noop"))
    func `does not recompute a derived when the source is assigned an equal value`() {
        withReactiveScope {
            @State var source = 42
            var computationCount = 0
            @DerivedState var derived = {
                computationCount += 1
                return source
            }()

            // Activate: first read.
            #expect(derived == 42)
            #expect(computationCount == 1)

            // Assign an equal value — must be a no-op at the source.
            source = 42
            // Re-read: should return cached result, no recompute.
            #expect(derived == 42)
            #expect(computationCount == 1)
        }
    }

    // Scenario 8 — custom-comparator
    // Expected: RED until `init(wrappedValue:equals:)` is added to State.
    @Test(.scenario("behavior.reactive.equality-gating.custom-comparator"))
    func `does not recompute when a custom comparator treats two distinct values as equal`() {
        // Comparator: two Ints are "equal" when |a - b| < 10.
        withReactiveScope {
            @State(equals: { abs($0 - $1) < 10 }) var source = 5
            var computationCount = 0
            @DerivedState var derived = {
                computationCount += 1
                return source
            }()

            // Activate.
            #expect(derived == 5)
            #expect(computationCount == 1)

            // Assign 12 — within 10 of 5, so comparator says "equal".
            source = 12
            #expect(derived == 5)
            #expect(computationCount == 1)
        }
    }

    // Scenario 9 — force-notify
    // Expected: RED until `init(wrappedValue:equals:)` is added to State.
    @Test(.scenario("behavior.reactive.equality-gating.force-notify"))
    func `recomputes exactly once when an always-unequal comparator forces propagation`() {
        // Comparator: `{ _, _ in false }` — always treats values as unequal.
        withReactiveScope {
            @State(equals: { _, _ in false }) var source = 7
            var computationCount = 0
            @DerivedState var derived = {
                computationCount += 1
                return source
            }()

            // Activate.
            #expect(derived == 7)
            #expect(computationCount == 1)

            // Assign the current value — comparator says "not equal", so propagation fires.
            source = 7
            #expect(derived == 7)
            #expect(computationCount == 2)
        }
    }

    // Scenario 10 — derived-custom-comparator
    // Expected: RED until `init(wrappedValue:equals:)` is added to DerivedState.
    @Test(.scenario("behavior.reactive.equality-gating.derived-custom-comparator"))
    func `downstream does not recompute when a derived comparator gates its results`() {
        // A small struct so DerivedState<Item> is non-Equatable by default.
        struct Item {
            let id: Int
            let noise: Int  // intentionally ignored by the comparator
        }

        withReactiveScope {
            @State var source = 0
            var upstreamCount = 0
            var downstreamCount = 0

            // Upstream: recomputes whenever source changes, but its comparator
            // only looks at the `id` field, so a change in `noise` alone is gated.
            // Here we fix id=1 and let noise track source — so the comparator
            // always sees id == id and blocks downstream.
            @DerivedState(equals: { $0.id == $1.id }) var upstream = {
                upstreamCount += 1
                return Item(id: 1, noise: source)
            }()

            @DerivedState var downstream = {
                downstreamCount += 1
                return upstream.noise
            }()

            // Activate both.
            #expect(downstream == 0)
            #expect(upstreamCount == 1)
            #expect(downstreamCount == 1)

            // Change source → upstream recomputes (new noise value),
            // but comparator sees id == id → downstream must NOT recompute.
            source = 99
            #expect(downstream == 0)  // still the old noise value
            #expect(upstreamCount == 2)  // upstream did recompute
            #expect(downstreamCount == 1)  // downstream did not
        }
    }
}
