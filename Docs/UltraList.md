# UltraList

`UltraListView` lays out a contiguous window of rows. It keeps final geometry
separate from motion: a mutation writes destination frames immediately, then
additive position tracks and absolute size or opacity tracks produce the
transition. `settledFrame(at:)` describes the destination; `presentedFrame(at:)`
evaluates the current animation model.

The default `.keyframe` engine bakes scroll physics at 120 Hz and sends an
additive bounds animation to Core Animation. A display link samples that same
trajectory for virtualization, edge reporting and host callbacks. Reads of the
offset never advance time. `.stepped` integrates on display callbacks;
`.uiKit` uses a platform scroll view for comparison.

## Rows and measurement

Rows have stable string identities and independent content revisions. A changed
revision reuses its view and calls `apply(to:transition:)`. Identities must be
unique within one collection. A plain view row returns a ready height from
`ListRowView.update(width:transition:)`; expensive layout belongs in asynchronous
measurement.

`NodeRow` creates its root off main and measures before mounting it. Measurements
are cached by identity, revision, width and environment. A missing measurement
stops expansion in that direction, leaving the edge open. Completion schedules a
coalesced pass; it never makes the main thread wait. `NodeRowMeasuring` allows a
host to supply its measurement policy. The default uses `NodeMeasurement` and
the list's current scale, text size, appearance and layout direction. A prepared root belongs to one mounted
host at a time.

The host prepares its measured size before display and never waits for drawing.
`ListRowView.isDisplayReady` and `onDisplayReady` report the first ready commit.
During a revision, the ready host remains visible until its replacement applies
the current-size visible commit. A shrinking row keeps its tall ready host until
the animated outer clip reaches the new height, then reveals the shorter host.
A newer revision discards a pending replacement.
Outer row geometry animates with the pass; `NodeRow` does not animate node-internal
property or text changes. Custom row hosts receive the transition through `apply`.

The preload window defaults to 160 points beyond the viewport. The list requests
up to 80 nearby asynchronous measurements, with the predicted direction first.
Rows outside the loaded window lose their views. Logical row data and measured
heights can outlive those views.

## Mutations and hosts

`applyChanges` accepts the next collection, size, insets, scroll target and
transition in one transaction. Reentrant calls retain all their arguments and
run later in FIFO order. Dirty callbacks coalesce independently.

A collection update first prepares nearby asynchronous rows while retaining its
transition and anchor. The displayed collection stays coherent until that pass
can apply; a newer complete collection supersedes a pending one. The list-level
`defaultTransition` starts at `.easeInOut(0.3)`. Per-update transitions override
it, including `.none`, `.init(duration:curve:)` and `.spring(_:damping:)`.
Position, size and opacity compile to `CABasicAnimation` or `CASpringAnimation`.
Display callbacks do not step row mutation geometry. Rows exposed by an inset
change enter at their final frames and share the viewport's keyboard transition.

Explicit targets take priority over the pin latch, followed by preservation of
visible content and normal anchoring. A target resolver runs once with its
measured row height. Automatic anchoring keeps the loaded collection top pinned;
`.preserveVisibleContent` instead follows a surviving visible witness. Insets
and additional scroll distance participate in the same viewport transition.

A row may request bottom pinning. Targeting it arms a latch; a user touch releases
that latch. Slack remains clamped and supplies scroll room without becoming a
second placement rule. Hosts decide when to target the pinned row. Keyboard
policy, paging and network loading also remain host responsibilities.

Departing rows form rigid blocks with spatial witnesses. Blocks may follow a
surviving row or another departing block; cycle checks prevent invalid links.
Outgoing rows that still exist in the collection use crossing carries. A far
scroll uses adjacent outgoing and incoming strips, driven by one viewport track.
Inserted blocks can slide separately from insertion opacity.

Visibility uses strictly positive intersection with the viewport. Edge callbacks
describe finite collection edges after the pass, rather than the preload band.
`loadedEdgeMargin` can require an edge to enter further into the viewport before
it is reported.

## Attachments

Rows publish attachments by key. Compatible consecutive members form a run.
Run witnesses preserve serial identity through clipping, splitting and merging.
Attachments can float at either edge, reserve space at actual run boundaries,
trim their member bands, and yield to one level of partner attachments.

One pure offset map supplies drag placement, final placement, stick distance and
every flight keyframe. During a flight the view has its destination frame; an
additive track supplies the displacement. The attachment reports live stick
distance on every sample. Unchanged trajectories keep their installed tracks.

Mutation transitions compare screen positions, so reparking the loaded window
cannot introduce a huge animation. A run that merely leaves the loaded window
disappears silently. A genuinely removed attachment fades, joining its departing
row block when all members share that block. Attachment containers pass through
touches outside interactive children.

## Physics and clocks

Physics uses full precision internally and ties-to-even pixel rounding at writes.
Rubber banding has an inverse for drag reanchoring. Release decisions retain two
velocity samples independently by axis, blend only when the previous vector is
nonzero, and apply bounded consecutive flick acceleration. The growth term is
`1 + (count - 3) / 2`, which gives 2.5 at count six. The multiplier
affects free deceleration; bounce uses its own state. Settling clamps exactly to
finite edges.

Flights have explicit layer-local start times. A coordinate shift translates the
content base and trajectory together without rebaking. Reachable edge changes
schedule one durable rebake; the replacement retains recent trajectory history.
A stopping touch truncates the same animation with two frames of headroom.
Leaving the window tears down motion and the sampling link.

The native engine keeps its content coordinate base stable as the window moves,
so virtualization does not repeatedly reset the platform offset or its momentum.
A delayed custom-engine sample catches up to the analytic flight without
clamping the travelled distance or stopping that flight.

The Compare demo attaches the native pane's pan recognizer to the shared
container and sends the observed input stream to both custom engines. A drag
in any pane drives all three; UIKit retains its native deceleration. The shared
Main off / 50 / 100 / 250 ms control deliberately blocks main every half second
to expose differences between platform, stepped and render-server motion.

The chat composer uses a text view that grows to five lines and then scrolls
inside its fixed width. Send and Stream retain their trailing positions; composer
height changes use the same inset path as keyboard changes. A queued inserted
block animation waits for its asynchronous mutation pass before starting.

Animation owners keep independent generations per property. Retargeting resumes
from the analytic value, with presentation samples for row y and absolute size
or opacity when available. A no-op preserves a live generation. Analytic
deadlines complete equal-endpoint tracks and reject stale callbacks. Duration
scaling changes playback speed without changing spring parameters.

## Decisions for unresolved behavior

The following records implementation choices and remaining empirical limits.
Numbers provide stable review references.

| # | Decision |
|---|---|
| 1 | Use explicit commit origins and two-frame braking headroom. Display depth remains device-dependent; no universal depth is assumed. |
| 2 | Request the display's maximum rate while sampling a flight. This is a preference; system power and thermal policy can lower it. |
| 3 | Validate public invariants in all builds. No behavior depends on another project's build configuration. |
| 4 | Keep pass time distinct from the render server's time. Device measurements must report their observed residual rather than assume zero commit delay. |
| 5 | Apply the same bounded streak policy to direct and indirect input pending physical trackpad evidence. |
| 6 | Use ties-to-even writes and the documented exponential deceleration model. |
| 7 | Do not introduce an unverified spring velocity clamp. |
| 8 | Record recognizer velocities and offset writes through public APIs; recognizer equivalence requires measured replay evidence. |
| 9 | Custom physics supports vertical bouncing. Paging and bounce-disabled variants remain separate host policies. |
| 10 | Use the stronger indirect rubber-band coefficient. Physical trackpad parity remains an empirical limit. |
| 11 | Raw touch-down hooks run for the first active finger only; additional fingers do not catch the same flight again. |
| 12 | Stepped integration uses callback frame duration. Keyframe playback catches up by elapsed media time after a stalled sampler. |
| 13 | Momentum keeps physical time. Programmatic transition duration scaling does not stretch a fling. |
| 14 | Evaluate springs analytically and emit public spring animations. No private solver is called. |
| 15 | Force begin only when catching moving content. Navigation arbitration is left to the recognizer system. |
| 16 | The list grants no simultaneous recognition and adds no failure dependencies. A host must choose any navigation-specific stopping-tap policy. |
| 17 | Indirect zero-movement updates do not move the drag baseline. Gesture end or cancellation still uses the normal release path. |
| 18 | Programmatic offset writes halt the old motion. During a drag they begin a new baseline at the current recognizer translation. |
| 19 | Edge changes at rest schedule bounce after the current pass, avoiding an intermediate-layout bounce. |
| 20 | Leaving the window halts playback and invalidates the display link. |
| 21 | The platform engine has no debug border. |
| 22 | Programmatic writes do not publish user-scroll callbacks; real drag and sampled momentum do. |
| 23 | Cache attachment flight signatures and replace tracks only when the flight or map changes. |
| 24 | Streaming, send and keyboard mutation are separate demo actions and interaction scenarios. A device screenshot alone is not proof of continuity. |
| 25 | Platform finite-edge placement uses content insets so a negative top offset survives layout. |
| 26 | Horizontal and viewport resume use analytic state. They retain the possible display-delay residual. |
| 27 | Only live row y positions use the pass-entry presentation snapshot. Continuously repositioned attachments and overlays use analytic state. |
| 28 | Departures complete at their model deadline; stale animation delegates cannot reap a replacement generation. |
| 29 | Outgoing strips are visual carries. User dragging acts on the live destination list. |
| 30 | A scroll with an empty old window establishes its first measured geometry directly. An unmeasured target remains pending. |
| 31 | Partner yielding repeats bounded sweeps over a deterministic run order. |
| 32 | The pure solver verifies partner flight composition. Physical-device partner behavior needs a matching host scenario. |
| 33 | Node hosts receive final frames; the list animates wrappers rather than repeatedly animating hosted content offsets. |
| 34 | Hosts can provide release suppression through `shouldStopScrolling`. Tappable header navigation remains host policy. |
| 35 | The API supports pass-level insertion fade suppression and explicit inserted-block slides; arbitrary per-row transition policies are not exposed. |
| 36 | Preserve visible content uses an actual surviving witness. There is no ignored stationary-range argument. |
| 37 | Overscroll absorption and drag reanchoring are explicit pass options. Extra trailing-item spacing remains row or inset data. |
| 38 | Pin slack has exact tests. Keyboard, floating headers and navigation buttons require interaction/device evidence in addition. |
| 39 | Every visible-row intersection uses the same strict positive-area rule. |
| 40 | Unknown measurement/loading edges remain open. A finite loaded collection edge is real; hosts append the next page through a later pass. |
| 41 | Replay supports frame and event observations. Positive controls perturb expected offsets so an oracle cannot silently accept every trace. |
| 42 | Seeded tests interleave flight ticks, coordinate shifts and edge changes; window tests interleave insertion, deletion and movement. |
| 43 | Exact math tests use injected time. Window-hosted rendering tests necessarily retain platform scheduling variance. |

## Validation

Run `scripts/build.sh test` on Linux for math, release decisions, trajectories,
flight changes, window geometry, diffing, attachments, animation state and seeded
mutation simulations. UIKit integration tests cover all three engines, anchoring,
pin release, reentrant passes, view retention, asynchronous measurement and
animation compilation. Interaction tests exercise the demo and export public
gesture observations. Device timings distinguish callback gaps from render-server
playback; a smooth screenshot cannot establish frame-time performance.

Public simulator recordings run through both frame and event replay. The finite
edge recording crosses its edge and returns exactly to it. Maximum offset
differences, in points, are:

| Gesture | Frame replay | Event replay | Limit |
|---|---:|---:|---:|
| Slow drag | < 0.001 | < 0.001 | 1 |
| Medium flick | 1.334 | 1.334 | 3 |
| Flick into bottom | 1.334 | 1.334 | 3 |
| Outward overscroll | 1.667 | 1.667 | 4 |

The demo's optional `-listProbe YES` script writes timing JSON to its Documents
directory. It reports display callback intervals separately from busy run-loop
turns, counts callback hitches above 1.5 frame periods, and records any layout,
text measurement or drawing performed on main. `-listKeyboardProbe YES` adds
keyboard show, send and dismissal to the chat script. `-listStall YES` injects a
120 ms stall into the feed during momentum, to validate the detector and compare
render-server playback with a delayed sampler. These probes use only their own
application and require no UI automation settings.

In Chat, `-listFlingProbe YES` starts a fling toward the newest messages and
records 60 samples of flight state, loaded indices and finite row geometry.
Adding `-listStall YES` blocks main for 250 ms during that flight. Supply a unique
`-listProbeRunID` and check the exported value to reject a previous launch's data.

The mutation, resize and multiline composer changes passed 205 Linux tests and
285 simulator tests, plus seven interaction tests using actual input gestures.
The 34 list integration tests passed separately with Address Sanitizer and
Thread Sanitizer. The interaction checks include native coast after release,
one drag across all Compare panes, the main blocker, keyboard actions and the
composer's growth, height cap, button positions and shrink after Send.

A focused simulator fling started with loaded index 38 and injected a 252.1 ms
main-thread block. The flight remained active at the next sample, continued from
loaded index 14 to 0, and finished with all 60 geometry samples finite. Node
layout, text measurement and drawing on main stayed at zero. The maximum busy
turn was 252.2 ms, including the deliberate block; p99 was 1.45 ms. This checks
motion state after a delayed sample, rather than every rendered frame.

The Xcode app target is `UltraViewDemoApp`, distinct from the SwiftPM demo library.
The shared scheme is `UltraViewDemo`. `DEMO_BUNDLE_ID` overrides only the app's
bundle identifier so independent test runners retain their own identities.

## Scope and remaining validation

| Area | Implemented | Deferred or not yet validated |
|---|---|---|
| Keyboard | The composer follows the keyboard layout guide. The inverted list receives the occlusion as its top inset, follows the keyboard transition, and suppresses inset compensation and release momentum during drag dismissal. Scripted actions export separate timings and public signpost intervals. | Continuous interactive dismissal. Device cold entry and UIKit keyboard/input work exceed 16.7 ms; measured limits are described below. |
| Accessibility | Hosted nodes apply accessibility properties; text nodes publish labels and static-text traits. Viewport-sized scroll actions follow screen direction, including inverted lists. Logical row focus survives virtualization and returns to a recreated descendant when available. | Physical VoiceOver interaction coverage, including custom accessibility-element containers. |
| Node row revisions | Ready content remains visible until the newest replacement applies its visible commit; superseded candidates are discarded. | Node-internal property and text animations. Custom row hosts receive the pass transition; the default bridge animates its outer row geometry. |
| Trackpad | Continuous indirect pan input has its own drag baseline and rubber-band coefficient. The physics model supports indirect replay. | Physical trackpad parity, indirect recording fixtures and discrete wheel input. The committed public gesture fixtures use direct touch. |
| Paging | Hosts can supply measured row targets and append new data through `applyChanges`. | Built-in page snapping and network loading policy. |
| Attachments | Run serial continuity, top/bottom floating maps, reserved space, member trimming, one-level partner yielding, ownership, stick distance, flight keyframes and departure behavior have math and simulator coverage. The feed demonstrates reserving section headers. A physical probe combines partner yielding, pinning and keyboard movement. | Navigation during that combined physical scenario. Render-server depth and commit-delay sweeps remain empirical work. |

The timing probes count layout, text measurement and drawing on main separately
from busy turns. Zero such operations does not imply that all UIKit input or
view-application work meets a frame budget. Report the measured maximum and p99
turns alongside the action timings when evaluating the keyboard scenario.

Add `-listHostProbe YES` to the keyboard probe to combine a streaming pin with
reserving date headers and partner-yielding sender headers. Its exported states
record pin placement, inset changes and attachment geometry before and after
keyboard/send/dismissal. Sending releases the streaming pin deliberately.

The device measurements below predate the multiline composer and the latest
scroll and resize fixes; they describe the earlier implementation.

That iPhone 12 Release probe held the strict streaming pin as keyboard
occlusion changed from 60 to 312 points, released it on Send, and returned to
60 points after dismissal. Two headers remained finite before Send and three
afterward. Feed busy turns measured 38.37 ms maximum and 5.25 ms p99; ordinary
chat measured 38.76 ms and 2.08 ms. The combined keyboard probe measured
128.78 ms and 2.28 ms, including keyboard show at 114.32 ms, field clearing at
92.02 ms, list application at 0.287 ms and insertion setup at 0.034 ms.
All three probes recorded zero layout, text measurement or drawing on main.
The separate 12-phase node scenario passed its regression budgets; host
application peaked at 9.46 ms. Startup, some switches and rotation still
exceeded the strict 16.67 ms benchmark. These final probes were unprofiled;
the stack observations below come from an earlier baseline.

A profiled iPhone 12 baseline measured keyboard show at 120.17 ms, filling the
field at 31.95 ms, clearing it at 84.12 ms, list application at 0.199 ms and the
insertion animation setup at 0.033 ms. Samples place the input stalls in UIKit's
responder, text-field, selection and keyboard task machinery. A later 235.73 ms
busy turn coincided with a system scene snapshot and trait/commit work; one of
84 main-thread samples in that interval included list application. Sampling
weights are CPU observations, not a complete breakdown of wall time. The probe
recorded zero layout, text measurement or drawing operations on main. These
results do not establish a one-frame guarantee for system keyboard work.