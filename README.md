# H3 Zombie Task Repro

This workspace is a minimal raw `quinn` + `h3` reproduction for a half-open HTTP/3 stream.

What it demonstrates:

- a long-lived `/events` HTTP/3 response stream that periodically sends JSON payloads
- a graceful client shutdown path using `SIGTERM`, where the client sends `ApplicationClose(0x100)` before exiting
- an abrupt client shutdown path using `SIGKILL`, where no application-level close is sent
- the difference between those two paths from the server's point of view
- that, in this repro, an abruptly killed client can remain visible as a subscriber until QUIC idle timeout

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

Current timing/config values in the repro:

- `TICK_INTERVAL_SECS = 1`
- `KEEPALIVE_INTERVAL_SECS = 1`
- `IDLE_TIMEOUT_SECS = 10`


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

## Files of interest

- `tests/scenario.sh`
- `h3-server/src/main.rs`
- `h3-client/src/main.rs`

