# H3 Zombie Task Repro

This workspace is a minimal raw `quinn` + `h3` reproduction for a half-open HTTP/3 stream.

What it demonstrates:

- a long-lived `/events` HTTP/3 response stream that periodically sends JSON payloads
- a graceful client shutdown path using `SIGTERM`, where the client sends `ApplicationClose(0x100)` before exiting
- an abrupt client shutdown path using `SIGKILL`, where no application-level close is sent
- the difference between those two paths from the server's point of view
- that, in this repro, an abruptly killed client can remain visible as a subscriber until QUIC idle timeout
- why H3 stream applications need explicit keep-alive and idle-timeout policy

## Why this matters for H3 stream apps

HTTP/3 is not just HTTP/2 with a different version number. It runs on
QUIC over UDP. That matters for long-lived response streams such as event
streams, live feeds, subscriptions, progress streams, and server-driven
updates.

When a peer closes gracefully, the server can usually observe shutdown
quickly. When the peer disappears abruptly, there may be no immediate
application-level close signal. From the server's point of view, the
stream task can remain alive until QUIC's timeout machinery decides the
connection is dead.

The practical rule:

> For H3 streams, abrupt connection loss is discovered by timeout unless
> the peer sends an explicit close.

That is why keep-alive is not optional for this class of application.
Without a keep-alive interval and a finite idle timeout, a dead peer can
look alive long enough to keep subscriber/task state stale.

This is especially relevant for Claviron-style H3 policy:

- advertise H3 selectively with `Alt-Svc`
- keep H3 strict at the SNI/authority/vhost boundary
- return `421 Misdirected Request` when an advertised H3 alternative is
  not valid for the requested authority
- return `425 Too Early` when 0-RTT early-data policy rejects a request
- treat H2/H1 as compatibility lanes
- make UDP/QUIC behavior explicit in config
- do not recommend streamed request bodies by default
- use streaming deliberately for apps that understand timeout and
  backpressure behavior

For event-stream style apps, the important question is not only "can H3
send the stream?" It is also "when does the server learn the receiver is
gone?"

## Workspace shape

This repro has two small binaries:

- `h3-server`: accepts HTTP/3 connections and serves `/events`
- `h3-client`: connects to `/events` and prints each streamed JSON event

The server keeps a global subscriber count and emits one JSON line per tick:

```json
{"tick":N,"subscribers":M}
```

The client prints those payloads as they arrive.

## Relevant source behavior

### Server

Current Quinn/H3 transport policy values in the repro:

- `TICK_INTERVAL_SECS = 1`
- `KEEPALIVE_INTERVAL_SECS = 1`
- `IDLE_TIMEOUT_SECS = 10`

`KEEPALIVE_INTERVAL_SECS` maps to Quinn's transport keep-alive interval.
`IDLE_TIMEOUT_SECS` maps to Quinn's max idle timeout. Together they make
the abrupt-close case observable in bounded time.

The server keeps one task alive per `/events` stream. The task decrements
the subscriber count only when the stream send fails or the handler
returns. In the abrupt-close scenario, that failure is timeout-driven.

### Claviron mapping

The corresponding Claviron knobs live under `config/http.yaml`:

```yaml
services:
  http3:
    keep_alive_interval: "2s"
    idle_timeout: "5s"
    handshake_timeout: "5s"
    max_concurrent_bidi_streams: 256
    max_concurrent_uni_streams: 100
    enable_early_data: true
```

These are Quinn/H3 transport parameters, not generic application-router
timeouts.

- `keep_alive_interval` should be enabled for long-lived H3 streams.
- `idle_timeout` is the upper bound for detecting a silent peer.
- `handshake_timeout` bounds connection setup.
- stream limits protect the process from unbounded H3 concurrency.
- `enable_early_data` only enables QUIC 0-RTT as a transport capability;
  the per-vhost policy still decides whether a request is accepted or
  rejected with `425 Too Early`.

For Claviron, the useful production posture is usually `AllowIdempotent`:
enable the QUIC capability for H3-capable origins, allow early data for
safe/idempotent methods such as `GET`, `HEAD`, and `OPTIONS`, and reject
mutation-style requests with `425 Too Early` so the client retries outside
early data.

Production rule: if early data is disabled, do not advertise H3 with
`Alt-Svc`. Keep H3 quiet until the origin has a deliberate 0-RTT policy.

If an H3 stream app needs very long-lived subscriptions, it should still
keep a finite idle timeout and use keep-alive rather than relying on the
application task to notice a dead client immediately.

## RFC anchors

- [RFC 9114: HTTP/3](https://www.rfc-editor.org/rfc/rfc9114.html)
- [RFC 9000: QUIC transport, idle timeout/liveness](https://www.rfc-editor.org/rfc/rfc9000.html#section-10.1)
- [RFC 8470: HTTP early data and 425 Too Early](https://www.rfc-editor.org/rfc/rfc8470.html#section-5.2)
- [RFC 7838: Alt-Svc](https://www.rfc-editor.org/rfc/rfc7838.html#section-3)


## Scenario script

The recommended way to run the repro is:

```bash
bash tests/scenario.sh
```

The script builds the binaries, starts the server, and then runs three client phases:

1. `client1` connects and establishes the baseline subscriber count of `1`
2. `client2` connects, then is terminated with `SIGTERM`
3. `client3` connects, then is killed with `SIGKILL`

The script checks subscriber counts from the point of view of `client1`, and for the abrupt-close case it also prints server-side timeout evidence.

## What the current run shows

From the terminal logs shown for this workspace, the scenario is stable and reproducible.

### Graceful close (`SIGTERM`)

Observed client-side script output:

```text
== graceful exit scenario (SIGTERM) ==
sending SIGTERM to client2 pid=61776 (with ApplicationClose(0x100))
[OK] [client1 should see 1 subscriber after client2 exit]: {"tick":6,"subscribers":1}
```

This means the graceful path is reflected quickly in the streamed subscriber count.

### Abrupt close (`SIGKILL`)

Observed client-side script output:

```text
== abrupt close scenario (SIGINT/SIGKILL)
sending SIGKILL to client3 pid=61951 (without ApplicationClose)
[FAILED] [client1 should see 1 subscriber after client3 exit]: expected subscribers=1 got 2 from {"tick":11,"subscribers":2}
waiting 10s for server idle timeout, then retrying assertion
[OK] [client1 should see 1 subscriber after server idle timeout]: {"tick":31,"subscribers":1}
```

`Note: if there is any concern that `SIGKILL` itself introduces a race in the local repro, the client is also coded so that `SIGINT` exits without sending an application close.`

This is the core repro result.

Immediately after the abrupt client death, the remaining client still sees:

```json
{"tick":11,"subscribers":2}
```

So the dead subscriber is still counted.

Only after waiting for the server-side idle timeout does the remaining client observe:

```json
{"tick":31,"subscribers":1}
```

So in this repro, the abruptly closed peer is not cleaned up immediately; it is cleaned up when the connection is later considered dead by timeout.


## Interpretation

This repro currently demonstrates two different behaviors:

- **Graceful close**: the server learns about shutdown quickly, and the subscriber count drops promptly.
- **Abrupt close**: the server continues to treat the stream as alive until QUIC timeout machinery detects the dead peer.

That is why the scenario script prints the warning:

```text
--- if the server is not configured with a keepalive interval and idle_timeout, this may remain stale --
```

That warning is not speculative in the context of this repro. The observed cleanup after `SIGKILL` is explicitly timeout-driven.

But for the full graceful-vs-abrupt comparison, `tests/scenario.sh` is the intended entry point.

## Design takeaway

For H3 stream applications, subscriber/task lifetime must be treated as a
lease, not as a perfect reflection of client process lifetime.

Good defaults:

- configure QUIC keep-alive
- configure a finite idle timeout
- make subscriber cleanup idempotent
- tolerate stale membership until timeout
- keep app-level heartbeats if business semantics need faster detection

Bad assumptions:

- "The server will immediately know the client process died."
- "A long-lived response stream is enough to detect disconnect."
- "No timeout means safer streams."

No timeout means stale tasks can survive longer.

## Files of interest

- `tests/scenario.sh`
- `h3-server/src/main.rs`
- `h3-client/src/main.rs`
