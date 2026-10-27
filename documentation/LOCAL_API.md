# Local API — letting other apps use the radio

Status: **implemented on `feat/local-api`** (fork), proposed upstream in zjs81/meshcore-open#616. Not merged into `main`/`dev` yet.

## Why

A MeshCore radio has exactly one BLE (or USB/serial) connection, and this app owns it.
Any other app that wants to send or receive mesh traffic today has two bad options: take the
radio over (then the chat app stops working), or reimplement the companion protocol and ask the
user to disconnect us. Both make MeshCore a single-app transport.

A small, opt-in **local API** turns this app into the radio daemon: it keeps the connection and
other applications on the same device subscribe to the traffic they care about and send through
it. The radio protocol does not change; nothing is exposed off the device.

The first consumer is a road-event client (Roadbeacon / Roadstr) that broadcasts 110–165-byte
binary datagrams on a `#roadstr` channel and bridges them to Nostr. The same interface covers
ordinary chat, adverts and any future application.

## Design constraints

* **Opt-in, off by default.** No listener, no port, no token until the user turns it on.
* **Loopback only.** `127.0.0.1`; never a LAN or public interface.
* **Explicit pairing, once per app.** The client proves possession of a P-256 key; the user
  approves the app in a dialog and the key is remembered. No shared secret to copy around.
* **No new dependencies.** `dart:io` `HttpServer` + `WebSocketTransformer`.
* **The radio keeps its own limits.** Sends go through the same quiet-wait, flood-scope and
  command-ack path as the UI; the API cannot bypass rate limits or take over the connection.
* **Transport-agnostic content.** Channel data is opaque bytes (`data_type` + payload); the API
  does not parse application formats such as road events or images.

## Transport

A WebSocket server bound to `127.0.0.1` on a fixed, configurable port (default `8787`):

```
ws://127.0.0.1:8787/api/v1
```

WebSocket rather than AIDL or a custom socket because it is:

* available on Android, iOS, Linux, macOS and Windows from the same Dart code;
* usable from Kotlin, Swift, Rust, Python, JS and Flutter clients without a platform plugin;
* testable in `flutter test` against an in-process server.

An Android bound-service (AIDL) wrapper can be added later without changing this protocol; it
would be a second transport for the same messages.

### Pairing

No shared secret and no QR to copy. Each client generates a **P-256 key pair** and keeps the
private half; the public key is its identity to this app.

1. Client connects and sends `hello` with its name, version and public key.
2. Server answers `pairing.challenge` with a random nonce (and whether the key is already known).
3. Client signs `meshcore-open-pair-v1:<nonce>` (`SHA256withECDSA`, DER or raw `r||s`).
4. First time only: this app shows **“Allow *Roadbeacon* (AB12 CD34 …) to connect?”** with the key
   fingerprint. On Allow the key is stored; on Deny the socket is closed. Later connections only
   re-prove the key and never prompt.
5. Paired apps are listed in settings and can be revoked; revoking forgets the key, so the next
   connection asks again.

A key is not a package name: an app could call itself anything. The dialog shows the name and a
fingerprint the user can compare, and the grant is always explicit. Binding the dialog to the
Android package would need a bound service with `Binder.getCallingUid()`; this protocol is
transport-neutral and works on Linux too, so identity here is the key the user approved.

## Messages

UTF-8 JSON text frames. Requests carry an `id`; responses echo it. Server-initiated events carry
`type: "event"`.

### Client → server

```json
{"type":"hello","client":{"name":"Roadbeacon","version":"0.4.0","publicKey":"<base64 X||Y>"}}
{"type":"pair","signature":"<base64 SHA256withECDSA over the nonce message>"}
{"id":1,"method":"device.info"}
{"id":2,"method":"events.subscribe","params":{"events":["channel.data"],"channel":"#roadstr","dataTypes":[46674]}}
{"id":3,"method":"channel.sendData","params":{"channel":"#roadstr","dataType":46674,"payload":"<base64>"}}
```

### Server → client

```json
{"type":"pairing.challenge","protocol":1,"nonce":"…","known":false,"fingerprint":"AB12 CD34 5678 9ABC","message":"meshcore-open-pair-v1:…"}
{"type":"hello","protocol":1,"client":{"name":"Roadbeacon","fingerprint":"…"},"device":{…}}
{"id":1,"ok":true,"result":{"connected":true,"batteryMv":4012,"radio":{"freqHz":869525000,"bwHz":250000,"sf":11,"cr":5},"channels":[{"index":0,"name":"#roadstr"}]}}
{"id":2,"ok":true,"result":{"subscriptionId":"s1"}}
{"type":"event","subscriptionId":"s1","event":{"type":"channel.data","channel":"#roadstr","channelIndex":0,"dataType":46674,"payload":"<base64>","snrDb":-7.25,"receivedAt":"2026-10-26T12:00:00Z","outgoing":false}}
{"id":3,"ok":false,"error":{"code":"payload_too_large","message":"payload is 190 bytes; the radio accepts 163"}}
```

### Methods (v1)

| Method | Params | Result |
|---|---|---|
| `device.info` | — | connection state, node name/pubkey, firmware, battery, radio parameters, channels |
| `channels.list` | — | `[{index,name,type,isPublic,storageId}]` |
| `contacts.list` | `{limit?, since?}` | `[{pubkey,name,type,lastSeen}]` |
| `events.subscribe` | `{events:[…], channel?, channelIndex?, dataTypes?, pubkeys?}` | `{subscriptionId}` |
| `events.unsubscribe` | `{subscriptionId}` | `{}` |
| `channel.sendText` | `{channel, text, replyToMessageId?}` | `{queued:true, messageId}` |
| `channel.sendData` | `{channel, dataType, payload(base64), path?}` | `{queued:true}` |
| `direct.sendText` | `{pubkey, text}` | `{queued:true, messageId}` |
| `advert.send` | `{flood?:true}` | `{queued:true}` |

`channel` is the channel **name** (e.g. `#roadstr`) or an index as a string. Names are resolved
case-sensitively against `channels.list`; an unknown or ambiguous name is an error.

### Events

| `type` | Fields |
|---|---|
| `channel.text` | `channel`, `channelIndex`, `senderName`, `senderKeyHex?`, `text`, `sentAt`, `messageId`, `outgoing` |
| `channel.data` | `channel`, `channelIndex`, `dataType`, `payload` (base64), `snrDb`, `outgoing` |
| `direct.text` | `pubkey`, `name?`, `text`, `sentAt`, `messageId`, `outgoing` |
| `advert` | `pubkey`, `name?`, `type`, `lastSeen?` |

Every event also has `receivedAt` (ISO-8601 UTC).

Filters are conjunctive: a subscription with `events:["channel.data"], channel:"#roadstr",
dataTypes:[46674]` receives only road-event datagrams on that channel. Omitting a filter means
"all" for that dimension. A subscription with no `events` receives every event type.

`outgoing` events are what this app sent (after the radio acknowledged the command), so a bridge
can avoid echoing its own traffic. Delivery is never acknowledged by the radio; `queued` only
means the firmware accepted the packet.

### Errors

`unauthorized`, `bad_request`, `unknown_method`, `not_connected`, `unsupported_firmware`,
`unknown_channel`, `ambiguous_channel`, `unknown_contact`, `payload_too_large` (over 163 bytes),
`invalid_data_type` (0 or > 0xFFFF), `rate_limited`, `internal`.

## Limits

* Payload: non-empty, at most **163 bytes** (the BLE notification bound already used for image
  chunks). MeshCore's radio-side limit is 165; the extra two bytes are not reachable through BLE.
* Sends: 30 per minute and one per 2 s per client, plus the existing radio quiet-wait. A refused
  send does not spend another client's quota.
* Subscriptions: 16 per connection, 4 connections, each with a bounded queue (drop oldest).
* Inbound events are not rate-limited per client, but the queue bound drops the slowest consumer
  rather than growing memory.
* Non-text frames, oversized frames and unknown fields are rejected.

## Security

* Off by default; enabling it is a deliberate action, and every app is approved by the user with a
  visible name and key fingerprint before it can read or transmit.
* Loopback bind only. No UDP broadcast, no mDNS, no LAN.
* Only a public key is stored; the private key never leaves the client app. Message contents and
  keys are never logged.
* The API cannot change radio settings, channels, contacts or keys in v1. Reads are limited to
  what a chat client would show.
* An approved app can transmit on the user's radio and read their messages. That is the same power
  the user's own chat app has; approval is the boundary, so the dialog states it and every grant is
  revocable.
* The server runs in the main isolate next to the connector, so it is only alive while the app
  process is (including the Android foreground service).

## Non-goals (v1)

* Remote/network access.
* Sending raw packets or bypassing the command queue.
* Channel/contact/radio administration.
* Reading message history (only live events).
* File/image transfers as such (they are channel data with `dataType` 0xAE1C; an API client can
  subscribe to them, but no reassembly is provided).

## Compatibility

`protocol: 1`. Additive fields are allowed without a version bump; a new method/event is
additive, a changed field meaning is not. Clients must ignore unknown fields and event types.

## Open questions for the maintainer

1. WebSocket on loopback plus key pairing versus an Android bound service (AIDL) with a runtime
   permission — WS is cross-platform and testable; AIDL gives the OS dialog and a verified package.
2. Whether a *read-only* grant (subscribe, no send) is worth a second switch per app.
3. Whether the API should be exposed while the app is in the background only via the foreground
   service, or always while the process is alive.
4. Naming: `local API`, `radio bridge`, `companion API`.
