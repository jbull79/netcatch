# NetCatch

A pretty, fully self-contained native macOS app for sending and receiving files over
the local network. **One app, installed on every Mac** — it is always both a sender
and a receiver.

## Why it exists

Quickly beam a file or folder to another Mac on the same Wi-Fi/LAN, with a nice UI,
no accounts, no cloud, and no setup. NetCatch discovers peers automatically and
encrypts every transfer.

## How it works (design)

NetCatch is **100% native** — Apple frameworks only, no external binaries, no
subprocesses:

| Concern        | Implementation |
|----------------|----------------|
| Raw TCP        | `Network.framework` — `NWListener` (receive), `NWConnection` (send) |
| Discovery      | Bonjour (`_netcatch._tcp`) via `NWListener` advertise + `NWBrowser` |
| Key exchange   | `CryptoKit` Curve25519 ECDH → HKDF → AES-GCM session key (no passphrase) |
| Encryption     | `CryptoKit` AES-GCM, per-session key, automatic |
| Integrity      | `CryptoKit` SHA-256 |
| Folder zip     | `AppleArchive` / `Compression`, with smart skip of already-compressed files |
| Finder send    | `NSServices` "Send with NetCatch" |
| UI             | SwiftUI, Swift Charts, `MenuBarExtra`, `UserNotifications` |

### Wire protocol

One TCP connection per transfer:

1. **Handshake** — both sides exchange an ephemeral Curve25519 public key and a stable
   identity key, then derive a shared AES-GCM key via HKDF. The identity key yields a
   short **fingerprint** for trust-on-first-use.
2. **Header** (encrypted) — JSON describing the transfer: `transferId`, sender name,
   and the item(s) with sizes, compression flag, and SHA-256.
3. **Accept / reject** — the receiver sees the sender's name + fingerprint and the
   contents before anything is written to disk.
4. **Payload** (encrypted) — length-prefixed, offset-tagged chunks.

## Features

- Auto peer discovery over Bonjour (+ manual host/port fallback)
- Drag-and-drop to send; "compress before sending?" prompt
- Save name + location prompt on receive
- Live throughput graph (MB/s), %, ETA
- Automatic encryption (zero passphrase) + accept/reject with fingerprint
- SHA-256 integrity verification
- Smart compression (skips already-compressed files, shows ratio)
- Menu-bar mode, completion notifications, transfer history
- Finder right-click → "Send with NetCatch"

## Build & run

```sh
xcodebuild -scheme NetCatch -configuration Debug build
```

Or open `NetCatch.xcodeproj` in Xcode and run. Requires macOS 14+.

## Roadmap (v2)

- Resume interrupted transfers + multi-item batch queue (protocol already carries
  `transferId` and per-chunk offsets)
- Shortcuts action + `netcatch://` URL scheme
