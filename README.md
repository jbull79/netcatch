# NetCatch

A pretty, fully self-contained native macOS app for sending and receiving files over
the local network. **One app, installed on every Mac** — it is always both a sender
and a receiver.

## Download

Grab the latest build from the [**Releases**](https://github.com/jbull79/netcatch/releases/latest)
page, unzip, and move **NetCatch.app** to `/Applications`. Requires macOS 14+.

> The app is ad-hoc signed (not notarized). On first launch, right-click the app →
> **Open**, or allow it under System Settings → Privacy & Security.

### Opening on a locked-down / managed Mac

Because the app isn't notarized yet, Gatekeeper may report
*"Apple could not verify 'NetCatch.app' is free from malware."* On a managed/work Mac
the usual overrides are often disabled by IT policy. The fastest fix is to **build from
source on that Mac** (locally built apps aren't quarantined, so Gatekeeper doesn't block
them):

```sh
git clone https://github.com/jbull79/netcatch
cd netcatch
xcodebuild -scheme NetCatch -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/NetCatch-*/Build/Products/Release/NetCatch.app
```

See **[docs/INSTALL.md](docs/INSTALL.md)** for all options (build from source, removing
the quarantine flag, and "Open Anyway"), plus what to do if a strict MDM blocks them.

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
| Authentication | Identity key (Curve25519 signing) signs the ephemeral key — peers are authenticated, not just encrypted; identity key stored in the Keychain |
| Encryption     | `CryptoKit` AES-GCM, per-session key, automatic |
| Integrity      | `CryptoKit` SHA-256 |
| Folder zip     | `AppleArchive` / `Compression` (streaming), with smart skip of already-compressed files |
| Resume         | Content-addressed partial blobs — interrupted transfers resume instead of restarting |
| Automation     | App Intents (Shortcuts/Siri) + `netcatch://` URL scheme |
| Finder send    | `NSServices` "Send with NetCatch" |
| UI             | SwiftUI, Swift Charts, `MenuBarExtra`, `UserNotifications` |

### Wire protocol

One TCP connection per transfer:

1. **Handshake** — both sides exchange an ephemeral Curve25519 public key plus a stable
   identity key, and **sign the ephemeral key** so each peer proves it owns the identity
   behind its **fingerprint** (trust-on-first-use; defeats impersonation/MITM). The
   session AES-GCM key is derived via HKDF and bound to the transcript.
2. **Header** (encrypted) — JSON describing the transfer: `transferId`, sender name,
   and the item(s) with sizes, compression flag, and SHA-256.
3. **Accept / reject** — the receiver sees the sender's name + fingerprint and the
   contents before anything is written to disk.
4. **Resume** — the receiver reports how much of each item it already holds; the sender
   resumes from there.
5. **Payload** (encrypted) — length-prefixed, contiguous offset-tagged chunks, verified
   by SHA-256, with an ack-confirmed close so nothing is truncated.

## Features

- Auto peer discovery over Bonjour (+ manual host/port fallback)
- Drag-and-drop to send; "compress before sending?" prompt
- Save name + location prompt on receive
- Live throughput graph (MB/s), %, ETA
- Authenticated, automatic encryption (zero passphrase) + accept/reject with fingerprint
- SHA-256 integrity verification
- Streaming smart compression (skips already-compressed files, shows ratio, any size)
- **Resumable transfers** — interrupted sends pick up where they left off
- **Shortcuts / Siri action** + `netcatch://send?peer=…&path=…` URL scheme
- Menu-bar mode, completion notifications, transfer history
- Finder right-click → "Send with NetCatch"

## Build & run

```sh
xcodebuild -scheme NetCatch -configuration Debug build
```

Or open `NetCatch.xcodeproj` in Xcode and run. Requires macOS 14+.

## Roadmap

- Persistent cross-restart send queue with automatic retry (multi-item batches already
  work within a single transfer)
- Developer ID signing + notarization for a warning-free download
