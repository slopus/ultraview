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

The preload window defaults to 160 points beyond the viewport. The list requests
up to 80 nearby asynchronous measurements, with the predicted direction first.
Rows outside the loaded window lose their views. Logical row data and measured
heights can outlive those views.

## Mutations and hosts

`applyChanges` accepts the next collection, size, insets, scroll target and
transition in one transaction. Reentrant calls retain all their arguments and
run later in FIFO order. Dirty callbacks coalesce independently.

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

The Xcode app target is `UltraViewDemoApp`, distinct from the SwiftPM demo library.
The shared scheme is `UltraViewDemo`. `DEMO_BUNDLE_ID` overrides only the app's
bundle identifier so independent test runners retain their own identities.