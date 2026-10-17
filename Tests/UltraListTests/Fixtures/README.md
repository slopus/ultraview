These four recordings were produced by this repository's public gesture recorder
on an iPhone 17 Pro simulator running iOS 26.5. The interaction test generates a
slow drag, a medium flick, a flick toward the finite bottom edge, and an outward
drag from that edge. Observations come from the scroll delegate and the public
pan recognizer. No private APIs or injected scroll-view implementation are used.

The JSON bytes preserve the captured observations. The bottom-edge flick has
an explicit `initialOffset` at maximum minus 450 and crosses that edge during
momentum before returning exactly to it. The other three captures predate the
explicit field; the test supplies the recorder's known starting offsets:
zero for the slow drag and medium flick, maximum for overscroll.
Recognizer begin/end events define the gesture phase:
the captured scroll view's `isDragging` remained true during some momentum runs.
Delegate and recognizer callbacks from one input delivery can differ by less
than one millisecond; matching observations are associated with that delivery.

Both frame and event replay are checked. A perturbed-offset control verifies
that the comparison detects a changed trajectory. These are simulator touch
recordings; they do not establish physical trackpad parity.