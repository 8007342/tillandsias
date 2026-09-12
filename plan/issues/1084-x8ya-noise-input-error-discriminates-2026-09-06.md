# 1084-x8ya criterion 2: the error VARIANT is the discriminating measurement

filed-by: macneo-macos, 2026-09-06
status: NARROWS criterion 2. Does not close it.
trace: crates/tillandsias-vm-layer/src/vz.rs (`provision_user_data`),
       snow-0.9.6 `Error`, `HandshakeState::_read_message`

## What criterion 2 asks

"the handshake failure is attributed to a NAMED cause — version skew, a
PSK/version-binding mismatch, or something else — WITH THE MEASUREMENT THAT
DISTINGUISHES THEM."

The measurement exists and it is already in the failure text. Nobody read it.

## `noise: input error` is a LENGTH error, not a crypto error

The observed string is snow's `Error::Input` Display. In `_read_message`,
`Error::Input` is returned when the received message is TOO SHORT to hold the
token being parsed — for `Token::E`, when `ptr.len() < dh_len` — or when it
exceeds `MAXMSGLEN`. It is an INVALID-INPUT-SIZE error.

A cryptographic disagreement does NOT produce it. snow has separate variants:

  Error::Decrypt   authentication/MAC failure — what a wrong key, wrong PSK,
                   or garbage-in-the-right-shape produces
  Error::Dh        Diffie-Hellman failure
  Error::Input     the bytes were the wrong SIZE

## Why this matters for the leading hypothesis

1084-x8ya's leading hypothesis is version skew: a host speaking Noise to a
guest that predates the encrypted-by-default change. That guest would answer
in PLAINTEXT. A plaintext responder emitting a normal greeting sends MORE than
`dh_len` bytes of non-Noise data, which parses as a well-sized message with a
bad tag — `Error::Decrypt`, NOT `Error::Input`.

`Error::Input` is instead what you get when the responder sends FEWER bytes
than one handshake message requires: a truncated, closed, or absent response.

THIS IS A NARROWING, NOT A REFUTATION, and the limit is stated because it is
real: a plaintext guest whose first write happens to be shorter than `dh_len`
would also yield `Error::Input`. What the variant establishes is that the
failure is CONSISTENT WITH A SHORT OR ABSENT RESPONSE and INCONSISTENT WITH
the ordinary presentation of a crypto mismatch.

## The discriminating measurement, stated so it can be run

Report the snow error VARIANT, not its Display string, at the poll site:

  Decrypt / Dh  -> the guest answered with a full-sized message that failed
                   authentication. Crypto disagreement: skew, PSK, binding.
  Input         -> the guest did not answer with enough bytes. Look at whether
                   anything is LISTENING, not at what it is speaking.
  IO error      -> the connection itself failed; not a handshake question.

Today all three collapse into one line that names none of them.

## What this hands to criterion 3

If the cause is a short or absent response, the question becomes whether
`tillandsias-headless.service` is running at all — which is exactly the record
criterion 3 proposes to write into `provision.state`. The two criteria meet
here. NOTE THE PRE-COMMITTED CONSTRAINT: "inactive" must NOT be recorded as
"failed", because the completion record is written after
`systemctl start --no-block` and a not-yet-started unit is expected at that
instant.

## Refuted along the way, cheaply, so nobody re-runs it

The control wire is VSOCK (`--listen-vsock 42420` in the guest unit written by
`provision_user_data`). The early-boot getty is on a SEPARATE virtio-console
device. Getty banner bytes therefore cannot arrive on the wire and be parsed as
a handshake. That hypothesis is dead; it cost one grep.

## What is still NOT established

- The running guest's actual behaviour. Everything above is read from code and
  from the error variant's semantics; no guest was reached.
- Whether anything is listening on 42420 in the failing guest.
- Therefore criterion 2 is NARROWED, not met. The named cause is still owed.
