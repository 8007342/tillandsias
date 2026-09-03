## Cycle 2026-09-03T13:14Z — tlatoanis-macbook-air (osx-next)

795-5itp macOS slice DONE (703daad23), released to ready; Windows lane remains.

The macos batch was exhausted — all four packets sit at limits I recorded in
earlier cycles — and the urgent flag on 702-6jza kept pinning the selector to
that epic anyway. Went to the highest-scoring frontier epic directly and took
795-5itp, which is tagged osx,windows and had an explicit macOS next_action.

MIGRATED pty_vsock_bridge.rs production framing onto the shared
control_frame_codec(): framed ONCE at the split, with the same FramedRead that
reads the HelloAck moved into reader_task, buffer intact. Ratchet lowered 5->4.

THE VALUABLE PART IS THE GUARD, AND THAT I PROVED IT. The packet warns a
per-call Framed can read ahead and drop pipelined bytes, silently. I
reintroduced that exact defect and measured which tests notice:

  pipelined_frame_behind_the_helloack_is_not_dropped ... FAILED (timeout)
  the other three ..................................... all ok

Three of four pass WITH the data-loss bug present. The existing handshake test
cannot see it because it sends the HelloAck and then READS, so nothing is ever
in flight behind the ack. The new one writes HelloAck and PtyData in one burst
before the host reads either — what the guest actually does — and fails as a
TIMEOUT rather than a decode error, which is exactly why the bug is silent.

Kept the test peers hand-rolled and moved the extension traits into the test
module: with production on the codec, a peer decoding u32-BE by hand is the only
thing still asserting the wire format rather than the codec against itself.

TWO FINDINGS NEITHER MINE NOR LANE WORK, both from running the ratchet by hand:
* THE RATCHET IS NOT WIRED INTO ./build.sh --check. It lives only in a litmus,
  and --check runs no litmus, so it went blocked when qcow2.rs landed and the
  gate stayed GREEN. Orphaned-guard shape on the very ratchet this packet built
  to prevent drift.
* Its detector counts u32::from_be_bytes, so a QCOW2 DISK HEADER read
  registered as a framing site. Dispositioned keep with the reason at the site;
  the class recurs as the tree grows.

Did NOT restate exit criterion 1 despite it being unsatisfiable as written — a
host that just migrated a slice should not rewrite the criterion it was measured
against. Coordinator decision still pending.

Gate green (199s).
