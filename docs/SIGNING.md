# Local signing — keeping TCC permissions across rebuilds

NetCatch has no Apple Developer account, so by default it's **ad-hoc signed**. The
downside: an ad-hoc app's *designated requirement* is a `cdhash` that changes on
every build, so macOS's privacy database (TCC) treats each rebuild as a brand-new
app. Permissions like **Accessibility** and **Input Monitoring** (needed for the
planned Control/KVM feature) reset to "not granted" after every rebuild, even
though a stale entry still shows in System Settings.

## The fix

Sign every build with a **stable, self-signed local certificate**. The requirement
then becomes:

```
identifier "com.netcatch.NetCatch" and certificate leaf = H"<stable hash>"
```

which is identical on every rebuild — so a permission granted once **persists**.

```sh
scripts/sign-local.sh /path/to/NetCatch.app
```

On first run this creates a certificate named **"NetCatch Local Signing"** in your
login keychain (no admin, no Apple account), then signs the app with it. Re-run it
after each build (the release flow does this automatically).

## One-time step after switching

Because the requirement changes from the old ad-hoc cdhash to the certificate, any
**previously granted permission must be granted once more** for the first
stable-signed build:

1. System Settings → Privacy & Security → **Accessibility** / **Input Monitoring**
2. Remove the old "NetCatch" entry (–), then re-add/re-enable the new build.

From then on, rebuilds keep the grant.

## Notes

- The certificate is **not Gatekeeper-trusted** — that only affects the
  "unidentified developer" prompt on *downloaded* copies (unchanged from before),
  not signing or TCC.
- The cert is **per-machine**. For permissions to persist on a given Mac, that Mac
  must always run builds signed by the *same* cert. Easiest: on each Mac, pick one
  path and stick to it — either always download the signed release, or always build
  locally (which uses that Mac's own "NetCatch Local Signing" cert).
- To remove it: Keychain Access → login → delete "NetCatch Local Signing".
