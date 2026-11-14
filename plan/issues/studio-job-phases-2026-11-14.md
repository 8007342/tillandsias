# Studio job phases, progress and retry_after (order 2082-sjph)

Packet: studio-job-status-reports-typed-phases-with-progress-and-a-retry-after-hint-so-an-agent-waiting-on-a-first-use-model-fetch-backs-off-instead-of-polling-or-cancelling

## Incident (2026-11-13)

A macron.dev forge submitted a Wan 2.2 VACE workflow through studio.queue_workflow.
The host downloaded about 41 GB of weights (two 17.3 GB experts, a 6.7 GB umt5
encoder, a 250 MB VAE) at about 18 MB/s and hashed them, all before ComfyUI
admission. The ticket said only "running". The agent assumed a stall, cancelled
once after about 20 minutes and polled repeatedly.

Operator direction: put download size and bandwidth in the messages so impatient
agents back off their polling and ask again later for real running metadata;
"running" is not good enough.

## Where the information is lost (by symbol)

- studio_jobs::queue_with writes `running` as the worker starts. The Runner type
  takes no progress sink, and live_runner gives studio_tool::call a closure that
  discards every Progress.
- studio_tool::call runs ensure_models, gpu_queue::wait_for_gpu and the engine run
  under that single status.
- imagegen_models::FetchEvent has Started with bytes, Percent and Verified only;
  Transport::fetch reports a whole percent; the sha256 pass emits nothing.

## Shared path

- image.generate shares Progress and FetchEvent with the studio (blocking call,
  MCP progress notifications, no ticket): it gets the sentence, not the poll hint.
- Audio studio is synchronous with no ticket; audio_separate passes a discarding
  FetchEvent sink to restricted_fetch::fetch_restricted. Feed it the same sentence.
- No studio cancel tool exists; cancel is the caller dropping the call or ticket.
  imagegen_models::ensure_files keeps verified files and leaves a .part for the
  transport's resume, so the cancel sentence is already true and gets a test.

## Decisions

- retry_after_s = clamp(remaining/10 .. remaining/2), floor 15 s, cap 600 s; 15 s
  when no ETA; 0 when finished. Every status response carries it, plus `message`.
- Ticket progress writes are throttled; tickets are atomic file rewrites.
- Links: extends 2002-stjb (studio-jobs-are-tickets-that-survive-a-lane-restart);
  same family as the on-demand image build progress packet and the image-build
  retry and tray feedback ruling (retry_after), which covers builds, not fetches.
