import Foundation
import ReactiveGraph
import Synchronization
import Testing

// SPEC: behavior.reactive.write-visibility
// Stress tests for scenarios 2-4 of the no-lost-updates invariant.
// All assertions are made only at quiescence (after all concurrent work joins).
// Mid-flight reads exist solely to create contention; they never assert.

// MARK: - Tags

extension Tag {
    // SPEC: manual — orthogonal category tag; no spec ID of its own.
    @Tag static var stress: Self
}

// MARK: - Iteration constant

/// Number of stress rounds per test.
/// Override with `STRESS_ITERATIONS=<N> swift test --filter Stress`.
private let rounds: Int =
    ProcessInfo.processInfo.environment["STRESS_ITERATIONS"].flatMap(Int.init) ?? 200

/// Number of writer and reader lanes per round.
private let writerLanes = 4
private let readerLanes = 4
private let writesPerLane = 20

// MARK: - Suite

@Suite(
    "Stress — behavior.reactive.write-visibility",
    .spec("behavior.reactive.write-visibility"),
    .tags(.stress)
)
struct WriteVisibilityStressTests {

    // -----------------------------------------------------------------------
    // Scenario 2 — concurrent-writers
    //
    // Topology:  source → d1 → d2   (chain depth ≥ 2 exercises transitive propagation)
    //
    // W writer lanes each perform K writes of distinct values.
    // R reader lanes hammer d2 mid-flight (creates contention; no assertions here).
    // At join:  d2 == f(source.final) where f(x) = x * 2 * 2 (x scaled through the chain).
    //
    // Why this catches:
    //   M1 (no epoch bump in invalidateCheck): a write landing while d1/d2 are mid-check
    //      goes undetected at the generation guard → d2 settles stale.
    //   M2 (no changed-commit notification): a recompute of d2 that commits before d1
    //      finishes never hears d1's changed result → stale cache.
    //   M3 (eager detach): detaching d1's sources before the body opens the window where
    //      a write to source notifies nobody → lost.
    //   M6 (unconditional settle): the classic hole — settle .clean with no generation
    //      check → stale value persists.
    // -----------------------------------------------------------------------
    @Test(
        .scenario("behavior.reactive.write-visibility.concurrent-writers"),
        .timeLimit(.minutes(1))
    )
    func `concurrent writers converge to the final source value`() {
        for _ in 0..<rounds {
            withReactiveScope {
                // Fresh graph each round — races need independent chances.
                @State var source = 0
                @DerivedState var d1 = source * 2
                @DerivedState var d2 = d1 * 2

                // Prime d2 so its source edges exist before contention begins.
                // This is distinct from the first-track path tested in scenario 3.
                _ = d2

                // Capture the Sendable wrappers directly so concurrent closures
                // can read/write them without capturing the local var bindings
                // (which the compiler sees as the Wrapped type inside a closure).
                let srcSignal = $source
                let d2Signal = $d2

                // Writer lanes: each writes distinct values (lane * writesPerLane + i)
                // so the last-write-wins value is deterministic at quiescence.
                // Reader lanes: read d2 repeatedly to create re-validation races.
                DispatchQueue.concurrentPerform(iterations: writerLanes + readerLanes) { lane in
                    if lane < writerLanes {
                        // Writer lane
                        for i in 0..<writesPerLane {
                            srcSignal.wrappedValue = lane * writesPerLane + i + 1
                        }
                    } else {
                        // Reader lane — creates contention, no assertion
                        for _ in 0..<writesPerLane * 2 {
                            _ = d2Signal.wrappedValue
                        }
                    }
                }

                // Quiescence: all concurrent work has joined.
                let finalSource = srcSignal.wrappedValue
                let expected = finalSource * 2 * 2
                #expect(d2Signal.wrappedValue == expected)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Scenario 3 — reads-under-contention
    //
    // Topology:  s1, s2, s3  (three sources)
    //            da = s1 + s2   (reads two sources — exercises multi-source settle)
    //            db = s2 + s3   (overlapping dependency with da)
    //            dc = s1        (single-source, narrow)
    //
    // Writer lanes per source + reader lanes per derived.
    // At join:  each derived equals f(final source values).
    // Completing under the time limit asserts "no read stalled" (scenario 3 clause).
    //
    // Why this catches:
    //   M5 (no all-sources-clean guard): da reads s1 and s2; if s2 is mid-validation
    //      (still .check) when da tries to settle, it must stay .check — without the
    //      guard da settles .clean over a dirty source → subsequent reads of da skip
    //      re-validation → stale value.
    //   M1, M2, M3, M6: same reasoning as scenario 2 across multiple source/derived pairs.
    // -----------------------------------------------------------------------
    @Test(
        .scenario("behavior.reactive.write-visibility.reads-under-contention"),
        .timeLimit(.minutes(1))
    )
    func `reads under write contention complete and converge to final values`() {
        for _ in 0..<rounds {
            withReactiveScope {
                @State var s1 = 0
                @State var s2 = 0
                @State var s3 = 0
                @DerivedState var da = s1 + s2
                @DerivedState var db = s2 + s3
                @DerivedState var dc = s1

                // Prime da/db/dc so their source edges exist.
                _ = da
                _ = db
                _ = dc

                // Capture Sendable wrappers for use inside the concurrent closure.
                let sig1 = $s1, sig2 = $s2, sig3 = $s3
                let sigDa = $da, sigDb = $db, sigDc = $dc

                DispatchQueue.concurrentPerform(
                    iterations: 3 * writerLanes + 3 * readerLanes
                ) { lane in
                    switch lane {
                    case 0..<writerLanes:
                        for i in 0..<writesPerLane {
                            sig1.wrappedValue = lane * writesPerLane + i + 1
                        }
                    case writerLanes..<(2 * writerLanes):
                        for i in 0..<writesPerLane {
                            sig2.wrappedValue = lane * writesPerLane + i + 1
                        }
                    case (2 * writerLanes)..<(3 * writerLanes):
                        for i in 0..<writesPerLane {
                            sig3.wrappedValue = lane * writesPerLane + i + 1
                        }
                    case (3 * writerLanes)..<(3 * writerLanes + readerLanes):
                        for _ in 0..<writesPerLane * 2 {
                            _ = sigDa.wrappedValue
                        }
                    case (3 * writerLanes + readerLanes)..<(3 * writerLanes + 2 * readerLanes):
                        for _ in 0..<writesPerLane * 2 {
                            _ = sigDb.wrappedValue
                        }
                    default:
                        for _ in 0..<writesPerLane * 2 {
                            _ = sigDc.wrappedValue
                        }
                    }
                }

                // Quiescence assertions.
                let fs1 = sig1.wrappedValue
                let fs2 = sig2.wrappedValue
                let fs3 = sig3.wrappedValue
                #expect(sigDa.wrappedValue == fs1 + fs2)
                #expect(sigDb.wrappedValue == fs2 + fs3)
                #expect(sigDc.wrappedValue == fs1)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Scenario 4 — diamond-under-contention
    //
    // Topology:  s → a (a = s * 2), s → b (b = s * 3), d = a + b (d = s * 5)
    //
    // Writers hammer s; readers hammer d (and some hammer a/b directly).
    // At join:  d == finalS * 5  (both paths reflect the SAME final s).
    //
    // Why this catches:
    //   M1 (no epoch bump): a write to s landing while d is mid-check on the a/b path
    //      goes undetected → one path sees stale a, the other sees fresh b → d ≠ s*5.
    //   M2 (no changed-commit notification): a commits a new value but doesn't notify d
    //      → d's edge-snapshot comparison against a's old value passes incorrectly →
    //      d may settle .clean while holding a+b computed from different s values.
    //   M3 (eager detach): detaching a's sources before a's body opens the same window
    //      as scenario 2 but now visible as diamond skew.
    //   M4 (no first-track flag): create d BEFORE the round but let the FIRST tracked
    //      read of d happen from inside a reader lane — the first-track frame-flag path
    //      is exercised; without it d may settle .clean while a was already re-invalidated
    //      at registration time.
    //   M5 (no all-sources-clean guard): a stays .check while d tries to settle →
    //      d would settle .clean above an unsettled source → stale.
    //   M6 (unconditional settle): same as scenario 2.
    //
    // M4 specifics: `d` is created but NOT primed before the round — the first tracked
    // read of d happens from inside a reader lane racing with writes to s.
    // -----------------------------------------------------------------------
    @Test(
        .scenario("behavior.reactive.write-visibility.diamond-under-contention"),
        .timeLimit(.minutes(1))
    )
    func `diamond settles consistently under write contention`() {
        for _ in 0..<rounds {
            withReactiveScope {
                @State var s = 0
                @DerivedState var a = s * 2
                @DerivedState var b = s * 3
                // d is intentionally NOT primed here — first tracked read happens
                // from inside a reader lane, exercising M4's first-track flag path.
                @DerivedState var d = a + b  // d = s * 5

                // Capture Sendable wrappers for use inside the concurrent closure.
                let sigS = $s
                let sigA = $a, sigB = $b, sigD = $d

                DispatchQueue.concurrentPerform(
                    iterations: writerLanes + readerLanes
                ) { lane in
                    if lane < writerLanes {
                        // Writer lane — writes distinct values
                        for i in 0..<writesPerLane {
                            sigS.wrappedValue = lane * writesPerLane + i + 1
                        }
                    } else if lane == writerLanes {
                        // One reader lane hammers a directly
                        for _ in 0..<writesPerLane * 2 {
                            _ = sigA.wrappedValue
                        }
                    } else if lane == writerLanes + 1 {
                        // One reader lane hammers b directly
                        for _ in 0..<writesPerLane * 2 {
                            _ = sigB.wrappedValue
                        }
                    } else {
                        // Remaining reader lanes hammer d — FIRST tracked read races with writes
                        for _ in 0..<writesPerLane * 2 {
                            _ = sigD.wrappedValue
                        }
                    }
                }

                // Quiescence: both paths must reflect the same final s.
                let finalS = sigS.wrappedValue
                let finalA = sigA.wrappedValue
                let finalB = sigB.wrappedValue
                let finalD = sigD.wrappedValue
                #expect(finalA == finalS * 2)
                #expect(finalB == finalS * 3)
                #expect(finalD == finalS * 5)
            }
        }
    }
}
