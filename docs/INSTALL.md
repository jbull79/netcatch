# Installing NetCatch

Download the latest build from the
[**Releases**](https://github.com/jbull79/netcatch/releases/latest) page, unzip, and
move **NetCatch.app** to `/Applications`. Requires macOS 14+.

On a personal Mac, the first launch may warn that the app is from an unidentified
developer — right-click the app → **Open**, or allow it under **System Settings →
Privacy & Security → Open Anyway**.

## Opening on a locked-down / managed (work) Mac

Because the app isn't notarized yet, Gatekeeper may report
*"Apple could not verify 'NetCatch.app' is free from malware."* On a managed/work Mac
the usual overrides are often disabled by IT policy. Try these in order.

### 1. Build it from source on that Mac — no prompt at all

Apps you compile locally are not quarantined, so Gatekeeper doesn't block them. If the
work Mac has Xcode or Command Line Tools:

```sh
git clone https://github.com/jbull79/netcatch
cd netcatch
xcodebuild -scheme NetCatch -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/NetCatch-*/Build/Products/Release/NetCatch.app
```

This sidesteps the whole issue — but only if dev tools are allowed/installed
(`xcode-select --install` adds the Command Line Tools).

### 2. Strip the quarantine flag

Needs Terminal + permission, which lockdown may deny:

```sh
xattr -dr com.apple.quarantine /path/to/NetCatch.app
```

### 3. System Settings → Privacy & Security → "Open Anyway"

Try it, but MDM often greys this out.

---

If all three are blocked, that's your Mac's management policy — only your **IT team can
whitelist** the app. A future [notarized](NOTARIZATION.md) build removes the warning on
unmanaged Macs (though a strict MDM may still require IT approval even then).
