# The Helm hub's protocol — the declaration

Every frame that passes between the hub (`hub/hub.mjs`, WebSocket on :3039)
and an app (`src/Helm/WebMIDI.js`).

`test/Hub/Protocol.purs` is the reference: each message described once,
and two data types over the descriptions.
`conformance/vectors/helm-hub.json` is generated from it and replayed against
both ends. `conformance/machines/helm-claim.json` is the state machine of one
name. If any of these disagree with this file, that is a bug, and it is
settled here first.

Declared 2026-11-13, from the code as it stood. Before this the protocol was
a comment at the top of `hub.mjs`, which had fallen five kinds of frame
behind the code.

## Frames

A frame is one JSON object in one WebSocket text message. Its `t` says what
it is. A writer produces exactly the fields listed, each of the type given.
The order of keys carries nothing.

A **name** is a string. Most names are outputs (`Midi Fighter Twister`). A
name that is not a port is a responsibility (`itajara:switches`). The hub
treats both alike. A port's id is its name, with ` #2` for a second port of
the same name.

**Bytes** are an array of whole numbers 0 to 255, at least one.

### An app says

<!-- generated:app -->
| `t` | Fields | Meaning |
|---|---|---|
| `hello` | `client` string | Names the app. Once, on connecting. |
| `send` | `port` name; `data` bytes; `delayMs` number, zero or more | Bytes for an output, now or later. |
| `claim` | `port` name | Hold a name. Granted if no other live connection holds it. |
| `want` | `port` name | Ask for a name: a claim if it is free, otherwise passed to the holder. |
| `grant` | `port` name; `to` string | The holder hands the name to the one client called `to`. |
| `refuse` | `port` name; `to` string; `why` string | The holder says no to `to`. `why` may be empty. |
| `release` | `port` name | The holder lets the name go. |
| `watch` | `port` name | Be told every message the hub delivers to this output. |
| `unwatch` | `port` name | Stop being told. |
| `ask` | `port` name; `text` string | A request to whoever holds the name. The hub relays `text` unread. |
<!-- /generated:app -->

### The hub says

<!-- generated:hub -->
| `t` | Fields | Meaning |
|---|---|---|
| `you` | `id` whole number | To a new connection: its connection number. Once. |
| `ports` | `inputs` array of {id, name}; `outputs` array of {id, name} | To a new connection, and to everyone on a change: the machine's ports. |
| `claims` | `claims` table of string; `holders` table of whole number | To a new connection, and to everyone on a change: who holds what. |
| `msg` | `port` name; `data` bytes | To everyone: a message that arrived on an input. |
| `error` | `text` string | To the app at fault: something it asked for could not be done. |
| `wanted` | `port` name; `by` string | To the holder: `by` wants the name. |
| `refused` | `port` name; `by` string; `why` string | To the wanter: the holder, `by`, said no. |
| `sent` | `port` name; `data` bytes; `by` string | To watchers, not the sender: `by` sent this to the output. An empty `by` is the hub saying what the output last showed. |
| `asked` | `port` name; `by` string; `text` string | To the holder: `by` asks this of it. |
<!-- /generated:hub -->

The two tables above are generated from the descriptions in
`test/Hub/Protocol.purs` by `make vectors`, and `make check-vectors` fails
if they are out of date. Do not edit them here.

What the hub replays to a new watcher is the last value of each control
change sent to that output, and nothing else.

The text of an `error` is for people. Nothing may depend on its wording, and
the vectors do not pin it.

## Readers are more forgiving than writers

The hub reads a missing `client` as `unnamed`, a missing `why` or `text` as
empty and a missing `delayMs` as zero. The client reads missing lists as
empty. This file declares what a **writer** must produce, and the reference
decoder is strict to match. Neither end's leniency is held by anything.

## One name, as a machine

`conformance/machines/helm-claim.json`, in Glassbox's format. Two states,
`free` and `held`. Who the holder is stays outside the machine, and reaches
it as a fact about each request: whether the holder sent it.

| Request | When free | When held |
|---|---|---|
| `claim` | held | by the holder: no change. By another: refused |
| `want` | held | no change (passed to the holder) |
| `grant` | refused | by the holder to a known client: no change of state, new holder. Otherwise refused |
| `release` | no change | by the holder: free. By another: no change |
| `refuse` | relayed if `to` is known, otherwise refused | the same |
| `ask` | refused | no change (passed to the holder) |
| the holder disconnects | — | free |

"Refused" means the sender is sent an `error`.

The machine pins which requests change the state and which are refused. It
does not pin the frames sent in reply. Those are in the scenarios.

## Conforming

`make conformance` runs four checks. Each fails if its vector file is
missing.

| Check | Holds | To |
|---|---|---|
| `spago test` | the reference codec | 50 frames with hand-written verdicts |
| `hub/conformance.mjs` | `hub.mjs` | 27 scenarios: who says what, and exactly what each connection then hears |
| `hub/conformance-client.mjs` | `WebMIDI.js` | one of each frame an app writes, made through the client's own API |
| `hub/conformance-machine.mjs` | `hub.mjs` | every vector of the machine |

The two hub checks run the real `hub.mjs` on `hub/fake-midi.mjs`, selected by
the `HELM_HUB_FAKE_MIDI` environment variable, so they open no MIDI port and
can run beside a live rig.

Not covered:

- `ports` being sent again when the machine's ports change;
- `send` with a delay;
- the wording of errors, and which refusal an error stands for;
- the leniency of either reader;
- `GET /state`.

## Changing this

Change this document, then `test/Hub/Cases.purs`, whose verdicts and
scenarios are written by hand, then the reference until `spago test` passes,
then `make vectors`, then both ends until `make conformance` passes.
