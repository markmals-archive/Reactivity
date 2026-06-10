import Foundation
import ReactiveGraph
import Synchronization
import Testing

// SPEC: behavior.reactive.write-visibility
// Coordinated-window stress tests for the deferred-detach, first-track-flag,
// and settle-requires-settled-sources guards in ReactiveNode.
//
// Each test opens a deterministic race window by parking a derived body on a
// Rendezvous, making the window last the entire rendezvous rather than a
// nanosecond.  All assertions are made only at quiescence (after both threads
// have joined).  Thread pairs use explicit Thread.detachNewThread + a bounded
// completion rendezvous to guarantee distinct OS threads and bounded joins.

// MARK: - Rendezvous helper

/// A pair of boolean flags used to choreograph a two-thread rendezvous.
///
/// `entered` is set by the body thread when it reaches the rendezvous point.
/// `proceed` is set by the peer thread when it has completed its side of the
/// bargain.  `armed` controls whether the park is active, so priming runs
/// that should not block pass straight through.
///
/// All waits are bounded: after ~5 seconds they record a Swift Testing issue,
/// set `failed`, and return so the round unwinds instead of hanging forever.
final class Rendezvous: @unchecked Sendable {
    // @unchecked Sendable: every access uses atomic operations; no additional
    // locking is required because the only mutable state is the atomics.
    private let _armed = Atomic<Bool>(false)
    private let _entered = Atomic<Bool>(false)
    private let _proceed = Atomic<Bool>(false)

    /// Set to true by a timed-out wait; checked by test bodies to skip asserts.
    private let _failed = Atomic<Bool>(false)
    var failed: Bool { _failed.load(ordering: .acquiring) }

    /// Whether the rendezvous is armed for the current round.
    var isArmed: Bool { _armed.load(ordering: .acquiring) }

    /// Arm the rendezvous for a new round (resets all flags; enables parking).
    func arm() {
        _entered.store(false, ordering: .releasing)
        _proceed.store(false, ordering: .releasing)
        _armed.store(true, ordering: .releasing)
    }

    /// Disarm the rendezvous so the body passes through without parking.
    /// Also resets entered/proceed.
    func disarm() {
        _armed.store(false, ordering: .releasing)
        _entered.store(false, ordering: .releasing)
        _proceed.store(false, ordering: .releasing)
    }

    /// Signal that the rendezvous point has been reached.
    func signalEntered() {
        _entered.store(true, ordering: .releasing)
    }

    /// Signal that the peer has finished its work and the body may continue.
    func signalProceed() {
        _proceed.store(true, ordering: .releasing)
    }

    /// Block until `entered` is set, with a ~5-second deadline.
    /// On timeout, records a Swift Testing issue, sets `failed`, and returns.
    func waitForEntered() {
        let deadline = DispatchTime.now() + .seconds(5)
        var ticks = 0
        while !_entered.load(ordering: .acquiring) {
            if DispatchTime.now() > deadline {
                Issue.record("Rendezvous timed out waiting for `entered` — choreography broke")
                _failed.store(true, ordering: .releasing)
                return
            }
            ticks &+= 1
            if ticks & 0xFF == 0 { usleep(50) }
        }
    }

    /// Block until `proceed` is set, with a ~5-second deadline.
    /// On timeout, records a Swift Testing issue, sets `failed`, and returns.
    func waitForProceed() {
        let deadline = DispatchTime.now() + .seconds(5)
        var ticks = 0
        while !_proceed.load(ordering: .acquiring) {
            if DispatchTime.now() > deadline {
                Issue.record("Rendezvous timed out waiting for `proceed` — choreography broke")
                _failed.store(true, ordering: .releasing)
                return
            }
            ticks &+= 1
            if ticks & 0xFF == 0 { usleep(50) }
        }
    }
}

// MARK: - Bounded thread pair helper

/// Spawns two threads (A and B) and waits for both to finish, with a
/// ~10-second deadline.  Using explicit threads rather than
/// `concurrentPerform` guarantees distinct OS threads (no pool-serialization
/// risk) and gives the rendezvous's parking body a dedicated thread that
/// cannot be reused by other work while it is parked.
///
/// - Parameters:
///   - rv: The rendezvous that will be joined inside taskA or taskB.
///   - taskA: Work for thread A (typically the body that may park).
///   - taskB: Work for thread B (typically the peer that unblocks A).
/// - Returns: `true` if both threads finished within the deadline; otherwise
///   records a Swift Testing issue and returns `false`.
@discardableResult
func spawnAndJoin(
    rv: Rendezvous,
    taskA: @escaping @Sendable () -> Void,
    taskB: @escaping @Sendable () -> Void
) -> Bool {
    let group = DispatchGroup()
    group.enter()
    Thread.detachNewThread {
        taskA()
        group.leave()
    }
    group.enter()
    Thread.detachNewThread {
        taskB()
        group.leave()
    }
    let result = group.wait(timeout: .now() + .seconds(10))
    if result == .timedOut {
        Issue.record("Thread pair did not join within 10 seconds — likely a hang")
        return false
    }
    return true
}

// MARK: - Suite

@Suite(
    "Stress — coordinated-window write-visibility",
    .spec("behavior.reactive.write-visibility"),
    .tags(.stress)
)
struct CoordinatedWindowStressTests {

    /// Rounds per test.  The rendezvous window is wide enough to catch mutations
    /// in round 1; extra rounds provide statistical confidence.
    private static let rounds = 50

    // -------------------------------------------------------------------------
    // Epoch-guard: mid-body write is not lost at commit
    //
    // GUARD EXERCISED: invalidation-generation epoch guard at commit.  When a
    // write lands while a derived body is running, invalidateCheck() bumps the
    // node's invalidationGeneration unconditionally.  The commit step compares
    // its pre-body snapshot against the current generation; a mismatch means the
    // node stays .check so the next read re-validates and catches the write.
    //
    // MUTATION CAUGHT: M1 (remove the unconditional epoch bump from
    // invalidateCheck()).  Without the bump, a write landing mid-body is
    // invisible to the commit step: gen == genSnapshot → the node settles .clean
    // with the stale body result.
    //
    // Note: M3 (eager detach) is not independently catchable by a rendezvous
    // test — see the note at the bottom of this file.
    //
    // TOPOLOGY:  s (source) ──→ d (derived, pre-primed)
    //
    // CHOREOGRAPHY (one round):
    //   Prime: rv disarmed.  Read d → d = 0 + sentinel; s→d edge established.
    //   Invalidate: write s=1 → d becomes .check.
    //   Arm rv.
    //   Thread A reads d:
    //     d is .check → recompute().
    //     Body reads s (sees 1; re-registers d on s via deferred detach),
    //     signals entered, waits proceed, returns s_read + sentinel.
    //   Thread B waits entered, writes s=finalValue.
    //     d.invalidateCheck() fires (d is in s's observer list) → gen bumps.
    //     Signals proceed.
    //   Body unblocks, returns 1 + sentinel.
    //   Commit: gen != genSnapshot (M1 keeps this bump) → d stays .check.
    //   Quiescent read: d recomputes with s=finalValue → finalValue + sentinel. ✓
    //
    //   M1: invalidateCheck() does not bump gen.  Commit sees gen == genSnapshot
    //   → d settles .clean with 1 + sentinel.  Quiescent read is a fast-path
    //   hit → stale. RED.
    // -------------------------------------------------------------------------
    @Test(
        .scenario("behavior.reactive.write-visibility.concurrent-writers"),
        .timeLimit(.minutes(1))
    )
    func `does not lose a write that lands while a derived body runs on another thread`() {
        let rv = Rendezvous()

        for round in 1...Self.rounds {
            withReactiveScope {
                let sentinel = 1_000
                let finalValue = round * 7  // distinct each round

                @State var s: Int = 0
                let sigS = $s

                @DerivedState var d: Int = {
                    let v = sigS.wrappedValue  // reads s; re-registers d on s
                    if rv.isArmed {
                        rv.signalEntered()
                        rv.waitForProceed()
                    }
                    return v + sentinel
                }()
                let sigD = $d

                // Prime (rv disarmed → body passes straight through).
                rv.disarm()
                _ = sigD.wrappedValue  // d = 0 + sentinel; s→d edge established

                // Invalidate: write s=1 → d becomes .check.
                sigS.wrappedValue = 1

                rv.arm()

                let joined = spawnAndJoin(
                    rv: rv,
                    taskA: {
                        // Thread A: triggers d's recompute; body parks after reading s.
                        _ = sigD.wrappedValue
                    },
                    taskB: {
                        // Thread B: waits until the body has read s and parked, then
                        // writes s=finalValue.  d is in s's observer list → gen bumps.
                        rv.waitForEntered()
                        sigS.wrappedValue = finalValue
                        rv.signalProceed()
                    })

                guard joined, !rv.failed else { return }

                // Correct: d is .check (gen bumped mid-body) → recomputes →
                //          finalValue + sentinel.
                // M1:      gen unchanged → d settles .clean with 1 + sentinel → stale.
                #expect(sigD.wrappedValue == finalValue + sentinel)
            }
        }
    }

    // -------------------------------------------------------------------------
    // First-track-flag guard
    //
    // GUARD EXERCISED: first-track flag — when a consumer performs its first
    // tracked read of a source that is already non-clean at registration time,
    // markObservedInvalidatedSource() sets a frame flag so the consumer's commit
    // settles .check instead of .clean.
    //
    // MUTATION CAUGHT: M4 (never call frame.markObservedInvalidatedSource()).
    // With M4, the frame flag is never set.  Even though the source is .check at
    // registration, the consumer's commit sees gen unchanged + flag clear →
    // settles .clean with a stale value.
    //
    // TOPOLOGY:  s ──→ mid ──→ c   (chain; c is NOT primed — first activation
    //                               happens in the concurrent phase)
    //
    // CHOREOGRAPHY (one round):
    //   Prime mid (rv disarmed): read mid → mid = 0 + midOffset; s→mid edge set.
    //   Do NOT prime c — its first tracked activation must happen in the round.
    //   Invalidate: write s=1 → mid becomes .check.
    //   Arm rv.
    //   Thread A reads c (c is .dirty — first read ever):
    //     c.recompute() → body calls mid.read() → mid.updateIfNecessary():
    //       mid is .check → mid.recompute() → body reads s (sees 1),
    //       signals entered, waits proceed, returns s_read + midOffset.
    //     (Thread A is parked inside mid.updateIfNecessary.)
    //   Thread B waits entered, writes s=finalValue (gen bumps on mid via the
    //   deferred-detach guard — mid is still in s's observer list), signals proceed.
    //   mid's body unblocks → returns 1 + midOffset.
    //   mid commits: gen != genSnapshot → state = .check.
    //   Changed-commit notification fires — but c is NOT yet in mid's observer
    //   list (c hasn't reached its register-and-copy critical section yet), so
    //   c's gen is NOT bumped by this notification.
    //   mid.updateIfNecessary() returns.  c's read() reaches lock.withLock:
    //     mid.state == .check → sourceWasInvalidated = true.
    //     With correct code: markObservedInvalidatedSource() flags the frame.
    //   c's body finishes → c.recompute commits:
    //     Correct: frame.observedInvalidatedSource = true → state = .check.
    //     M4:      flag is false, gen unchanged → settles .clean with 1 + midOffset + cOffset.
    //   Quiescent read of c:
    //     Correct: c is .check → re-validates → mid is .check → s changed →
    //              mid recomputes → finalValue + midOffset → c = (finalValue + midOffset) + cOffset. ✓
    //     M4:      c is .clean → fast path → 1 + midOffset + cOffset ≠ expected. RED.
    //
    // WHY THIS IS A CLEAN M4 WITNESS: mid's changed-commit notification fires
    // BEFORE c is registered on mid, so it cannot bump c's generation.  The
    // propagation chain s→mid→c via invalidateCheck() also cannot reach c at
    // this point (c was not in mid's observer list when s was written before the
    // round).  The ONLY mechanism that can make c commit .check is the first-track
    // flag; M4 removes it.
    // -------------------------------------------------------------------------
    @Test(
        .scenario("behavior.reactive.write-visibility.reads-under-contention"),
        .timeLimit(.minutes(1))
    )
    func `reflects a re-invalidation that races the first read of an intermediate`() {
        let rv = Rendezvous()

        for round in 1...Self.rounds {
            withReactiveScope {
                let midOffset = 1_000
                let cOffset = 2_000
                let finalValue = round * 13

                @State var s: Int = 0
                let sigS = $s

                // mid: reads s, parks only when armed.
                @DerivedState var mid: Int = {
                    let v = sigS.wrappedValue
                    if rv.isArmed {
                        rv.signalEntered()
                        rv.waitForProceed()
                    }
                    return v + midOffset
                }()
                let sigMid = $mid

                // c: reads mid and adds cOffset.  NOT primed before the round.
                @DerivedState var c: Int = sigMid.wrappedValue + cOffset
                let sigC = $c

                // Prime mid only (rv disarmed → body passes straight through).
                rv.disarm()
                _ = sigMid.wrappedValue  // mid = 0 + midOffset; s→mid edge established

                // Invalidate mid: write s=1 → mid becomes .check.
                sigS.wrappedValue = 1

                rv.arm()

                let joined = spawnAndJoin(
                    rv: rv,
                    taskA: {
                        // Thread A: first read of c (c is .dirty).
                        // c.recompute → body calls mid.read() → mid.updateIfNecessary()
                        // → mid is .check → mid.recompute() → body parks.
                        _ = sigC.wrappedValue
                    },
                    taskB: {
                        // Thread B: wait for mid's body, then write the final value.
                        rv.waitForEntered()
                        sigS.wrappedValue = finalValue
                        rv.signalProceed()
                    })

                guard joined, !rv.failed else { return }

                // Correct: c is .check → re-validates → mid recomputes with s=finalValue
                //          → c = (finalValue + midOffset) + cOffset.
                // M4:      c is .clean → fast path → 1 + midOffset + cOffset ≠ expected.
                #expect(sigC.wrappedValue == finalValue + midOffset + cOffset)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Settle-requires-settled-sources guard
    //
    // GUARD EXERCISED: settle-requires-settled-sources — a node may only settle
    // .clean when every source it validates also settled .clean (isClean() true).
    // When a source refuses to settle (stays .check because its own generation
    // moved during its validation), the consumer must refuse too.
    //
    // MUTATION CAUGHT: M5 (drop the allSourcesSettled condition from the
    // validation settle in updateIfNecessary()).  With M5, a node settles .clean
    // above a source that is still .check.  Downstream propagation will
    // early-stop at that already-.check source on the next write, never reaching
    // the prematurely-.clean nodes above it → stale values.
    //
    // TOPOLOGY:
    //   dgateSrc (source)
    //     └──→ dgate (derived; body parks during the round when armed;
    //                 uses dgateSrc % 2 — a many-to-one mapping so that
    //                 distinct dgateSrc values can yield the same or different
    //                 gate value, making the topology flexible)
    //   s (source)
    //   s + dgate ──→ d (derived; reads s first, then dgate — edge order
    //                    ensures the s edge is validated before dgate parks)
    //   d ──→ c (derived)
    //
    // CHOREOGRAPHY (one round):
    //   Prime: rv disarmed.
    //     Write dgateSrc=1 → dgate = 1 % 2 = 1.
    //     Read dgate, d, c.  Edges established.
    //   Pre-round invalidations (put dgate in .check with a CHANGED edge):
    //     Write dgateSrc=3.  dgate → .check.  Edge snapshot for dgate: seen
    //     dgateSrc=1, current=3 → CHANGED.  (This is the key difference from
    //     the old choreography: the edge reports CHANGED so validation WILL
    //     recompute dgate and the body WILL park.)
    //     Write s=1 then s=0.  d and c → .check.
    //   Arm rv.
    //   Thread A reads c (c is .check):
    //     c validates d: d is .check → d validates:
    //       s edge: s=0, seenValue=0 → UNCHANGED → passes.
    //       dgate edge: dgate is .check → dgate.recompute() → body reads
    //         dgateSrc (sees 3), signals entered, waits proceed → PARKS.
    //   Thread B waits entered:
    //     Writes dgateSrc=5 → gen bumps on dgate (mid-body; deferred-detach
    //       guard keeps dgate in dgateSrc's observer list).
    //     Signals proceed.
    //   dgate body unblocks: returns 3 % 2 = 1.
    //   dgate commits: gen != genSnapshot (B's write bumped it) → state = .check.
    //   Committed value 1 == previous value 1 → no changed-commit notification.
    //   Back in d's validation: dgate edge → hasChangedSinceSeen?  seenValue was
    //   dgateSrc=1 (from prime), current dgate value = 1 (just committed) →
    //   no change at the value level.  isClean(dgate) = false (dgate is .check).
    //   allSourcesSettled = false.  Correct code: d refuses settle → stays .check.
    //   c's validation likewise: d is .check → allSourcesSettled = false →
    //   c refuses settle → stays .check.
    //
    //   M5: allSourcesSettled check omitted.  d sees all edges UNCHANGED →
    //   settles .clean over .check dgate.  c sees d edge UNCHANGED → settles
    //   .clean over .clean d.  Both are now prematurely .clean.
    //
    // Post-round trigger: write dgateSrc=triggerValue (parity change: 5%2=1 was
    // committed into dgate; triggerValue must have parity 0 to flip the output).
    //   dgate is .check → invalidateCheck bumps its gen but propagation stops at
    //   dgate (not .clean → no downstream notification).
    //   Correct: d and c stayed .check → quiescent read re-validates → dgate
    //     recomputes to triggerValue%2=0 (CHANGED: 1→0) → d detects change →
    //     recomputes (s=0 + 0 = 0) → c recomputes → 0 * cScale = 0. ✓
    //   M5: d and c are .clean → fast path → stale (dgateInitialParity * cScale). RED.
    //
    // Quiescent assertion: sigC.wrappedValue == 0.
    // -------------------------------------------------------------------------
    @Test(
        .scenario("behavior.reactive.write-visibility.reads-under-contention"),
        .timeLimit(.minutes(1))
    )
    func `does not settle over a source still catching up`() {
        let rv = Rendezvous()

        for round in 1...Self.rounds {
            withReactiveScope {
                // dgateSrc=1 → dgate = 1 % 2 = 1 (initial parity: 1)
                // dgateSrc=3 → body reads 3 during park, returns 3 % 2 = 1 (unchanged value)
                // dgateSrc=5 → B writes mid-body; gen bumps; body already read 3 → commits 1
                // triggerValue must be even so dgate recomputes to 0 (parity flip: 1 → 0)
                let dgateInitialSrc = 1  // dgateSrc at prime; dgate = 1 % 2 = 1
                let dgatePreRound = 3  // pre-round write; edge snapshot 1 vs current 3 → CHANGED
                let dgateMidBody = 5  // B writes mid-body; odd → gen bumps, parity still 1
                // even → dgate recomputes to 0 (parity flip: 1 → 0)
                let triggerValue = (round % 2 == 0 ? round : round + 1) * 10
                let cScale = 10

                @State var s: Int = 0
                @State var dgateSrc: Int = dgateInitialSrc
                let sigS = $s
                let sigDgateSrc = $dgateSrc

                // dgate: many-to-one mapping (dgateSrc % 2), parks when armed.
                // This mapping ensures:
                //   - Writing dgateSrc from 1 → 3 changes the edge snapshot (1 vs 3)
                //     so validation WILL recompute dgate and the body WILL park.
                //   - The committed value is 3 % 2 = 1 (same as pre-round value 1 % 2 = 1)
                //     so no changed-commit notification fires to d.
                //   - dgate stays .check after commit (gen bumped by B's mid-body write).
                @DerivedState var dgate: Int = {
                    let v = sigDgateSrc.wrappedValue  // reads dgateSrc; registers edge
                    if rv.isArmed {
                        rv.signalEntered()
                        rv.waitForProceed()
                    }
                    return v % 2
                }()
                let sigDgate = $dgate

                // d: reads s FIRST, then dgate (edge order ensures the s edge is
                // validated — and passes — before dgate's body parks).
                @DerivedState var d: Int = sigS.wrappedValue + sigDgate.wrappedValue
                let sigD = $d

                // c: reads d only.
                @DerivedState var c: Int = sigD.wrappedValue * cScale
                let sigC = $c

                // --- Prime (rv disarmed → dgate body passes straight through) ---
                rv.disarm()
                _ = sigDgate.wrappedValue  // dgate = 1 % 2 = 1; dgateSrc→dgate edge set
                _ = sigD.wrappedValue  // d = 0 + 1 = 1; s→d and dgate→d edges set
                _ = sigC.wrappedValue  // c = 1 * 10 = 10; d→c edge set

                // --- Pre-round invalidations ---
                // Write dgateSrc=3: dgate → .check.  Edge snapshot: seen dgateSrc=1,
                // current=3 → CHANGED.  Validation WILL recompute dgate → body WILL park.
                sigDgateSrc.wrappedValue = dgatePreRound

                // Write s=1 then s=0: d and c → .check via propagation.
                sigS.wrappedValue = 1  // d → .check → c → .check
                sigS.wrappedValue = 0  // d gen bumps (already .check); c stays .check

                // --- Arm rendezvous ---
                rv.arm()

                let joined = spawnAndJoin(
                    rv: rv,
                    taskA: {
                        // Thread A: reads c (c is .check).
                        // c validates d: d is .check → d validates:
                        //   s edge: s=0, seenValue=0 → UNCHANGED → passes.
                        //   dgate edge: dgate is .check → dgate.recompute() → body reads
                        //     dgateSrc (sees 3), signals entered, waits proceed → PARKS.
                        _ = sigC.wrappedValue
                    },
                    taskB: {
                        // Thread B: wait for dgate's body to park.
                        rv.waitForEntered()
                        // Write dgateSrc=5: gen bumps on dgate mid-body (deferred-detach
                        // guard keeps dgate in dgateSrc's observer list during body).
                        // dgate's body already read dgateSrc=3 before parking; the body
                        // returns 3 % 2 = 1 regardless of this write.
                        sigDgateSrc.wrappedValue = dgateMidBody
                        rv.signalProceed()
                        // After proceed:
                        //   dgate body unblocks, returns 3 % 2 = 1.
                        //   dgate commits: gen != genSnapshot (B's write bumped it).
                        //   state = .check.  Committed value 1 == previous value 1
                        //   → no changed-commit notification to d.
                        //   d's validation: dgate edge seenValue=dgateSrc=1, current dgate=1
                        //   → UNCHANGED.  But isClean(dgate)=false (dgate is .check).
                        //   allSourcesSettled=false.  Correct: d refuses settle → .check.
                        //   c likewise refuses → stays .check.
                    })

                guard joined, !rv.failed else { return }

                // --- Post-round trigger ---
                // Write dgateSrc=triggerValue (even).  Current dgate is .check with
                // committed value=1 and edge snapshot dgateSrc=3.  current=triggerValue
                // Edge snapshot (dgateSrc=3) vs current (triggerValue=even) → CHANGED.
                // dgate is already .check → invalidateCheck bumps its gen but propagation
                // stops at dgate (not .clean → no downstream notification fires).
                //
                // Correct: d and c stayed .check → re-validate on next read.
                //   dgate recomputes: dgateSrc=triggerValue (even) → 0.  CHANGED (1→0).
                //   d detects dgate changed → recomputes: s=0 + 0 = 0.
                //   c recomputes: 0 * cScale = 0. ✓
                //
                // M5: d and c are .clean → fast path → stale.
                //   d.clean with old value 1.  c.clean with old value 10. RED.
                sigDgateSrc.wrappedValue = triggerValue

                // Quiescence assertion: expected 0 (s=0 + dgate=0) * cScale = 0.
                #expect(sigC.wrappedValue == 0)
            }
        }
    }
}

// =============================================================================
// NOTE ON M3 — eager detach
// =============================================================================
//
// M3 clears sources and calls removeObserver for all old edges BEFORE running
// the body, and drops the post-commit prune.
//
// Analysis of independent detectability via a rendezvous test:
//
// A rendezvous parks body execution at a point the body itself chooses —
// typically after reading at least one source.  Any source the body has
// already read has been re-registered (body called read() on it, which appended
// the observer back into the source's observer list).  A write to that source
// after the park finds d registered and bumps its generation, making M3's
// behaviour identical to correct code for those sources.
//
// The M3 window — between "removeObserver for all old edges" and "body calls
// read() on a source for the first time" — is therefore only open for sources
// the body has NOT yet re-read when signalEntered fires.  To place a write in
// that window a rendezvous would need to park BEFORE the body reads the target
// source.  But then the body captures the source's POST-write value when it
// unblocks and re-reads it, so the committed value is the same as what a fresh
// recompute would produce — the test is vacuous.
//
// Consequence: M3 is not independently catchable by a deterministic rendezvous
// test.  The mutation table therefore reports M3 as:
//   - not caught by any coordinated test (window is pre-first-read, unreachable
//     by a post-read park without making the result vacuous)
//   - potentially caught by the blind-write tests under heavy scheduling pressure
//     (writes racing the sub-microsecond detach-to-first-read window), but those
//     catches are probabilistic, not guaranteed

// =============================================================================
// NOTE ON M2 — no changed-commit notification
// =============================================================================
//
// M2 removes the loop in recompute() that calls observer.invalidateCheck() when
// a commit produces a value different from the previous one (the changed-commit
// notification).
//
// Analysis of independent detectability:
//
// Every write to a source s propagates invalidateCheck() transitively through
// the observer chain via the invalidation-generation mechanism:
//   s.write() → d.invalidateCheck() [gen bumps, propagates] → c.invalidateCheck()
// This propagation reaches c regardless of whether d later commits a changed
// value (M2's responsibility).  Concretely: in any race where c would miss a
// changed value from d due to M2's absence, d.invalidateCheck() already bumped
// c's generation before the race window closed, preventing c from settling
// .clean anyway.
//
// The only topology where M2 is the sole catcher is one where d commits changed
// without a prior invalidateCheck propagating all the way to c.  That requires c
// to not yet be in any node's observer list when the write fires — i.e. c is
// receiving its first-ever tracked read.  In that scenario, c registers on d
// AFTER d has already been invalidated and d's state is .check.  That is exactly
// the race window that the first-track-flag guard covers: d's state is non-clean
// at c's registration time → sourceWasInvalidated=true → flag set → c commits
// .check.
//
// Consequence: a choreographed test that removes only M2 while keeping M1 and
// M4 intact will pass on both correct code and M2-mutated code.  M2 is a
// defense-in-depth invariant whose independent observability requires M1 or M4
// to also be compromised.  The mutation table therefore reports M2 as:
//   - caught by the existing blind-write stress tests (where M1+M2 together
//     close the window under concurrent hammering — removing M2 alone
//     occasionally lets a race through that M1 would normally absorb, but not
//     reliably in isolation)
//   - not caught by a coordinated M2-only test (M1 absorbs the same window)
