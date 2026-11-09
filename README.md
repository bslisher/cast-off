# Cast Off

A free menu bar app for Mac drives that won't let go.

**Website:** https://bslisher.github.io/cast-off/

Sometimes macOS refuses to eject an external drive even though you've closed everything. The usual culprit is a background service, such as the Spotlight index inside a Photos library, that keeps files open on the drive. Your options are normally to wait, log out, or force eject.

Cast Off unties your drive from those services. It finds out what's holding the drive and, if it's only macOS indexing services, asks them to quit and ejects the drive. It never force-ejects.

> **Early release.** Cast Off 0.1.0 has been tested on one Apple Silicon Mac, mostly against disk images. Expect rough edges, and keep backups of anything important.

## What happens when you click Eject

1. Cast Off tries a normal eject.
2. If the drive is busy, it checks which processes have files open on it.
3. If they're all services on the stop list below, it sends them a normal quit signal (`SIGTERM`) and ejects right away, retrying a few times in case macOS relaunches them.
4. If anything else is using the drive, nothing is stopped. Cast Off tells you what's holding it and offers **Eject When Free**, which keeps checking and ejects the drive once it can.

The menu also has **Start at Login** and **Recent Activity**, which records what was ejected and which services were asked to quit.

A disk with several volumes appears as one item, because ejecting it ejects all of them.

## What it stops

Only processes running as you, with one of these exact names:

- `managedcorespotlightd`
- `corespotlightd`
- `mdworker`
- `mdworker_shared`
- `photoanalysisd`
- `mediaanalysisd`

macOS relaunches these when it needs them. Stopping `photoanalysisd` or `mediaanalysisd` interrupts Photos' analysis work, which will pick up again later. To change the list, edit `StopList` in [`Sources/Disks.swift`](Sources/Disks.swift) and rebuild.

## What it leaves alone

- Apps you've opened
- `photolibraryd`, which can be working on behalf of Photos
- Processes owned by root, such as `mds_stores` and `backupd`

If one of these is holding the drive, Cast Off can only wait for it. Some of them may hold on for a long time, particularly while Photos is working through a large library. Cancel **Eject When Free** from the menu whenever you like.

## Build it

You need macOS 13 or later and Xcode or its Command Line Tools.

```sh
git clone https://github.com/bslisher/cast-off.git
cd cast-off
./build.sh
```

This installs `CastOff.app` into `~/Applications` and opens it. Look for the eject icon in your menu bar. There's no prebuilt download yet.

## Command line

The app's executable also works from Terminal:

```sh
BIN=~/Applications/CastOff.app/Contents/MacOS/CastOff

$BIN --list                     # Show drives and what's holding them. Changes nothing.
$BIN --eject "My Drive"         # Eject, the same way the menu does.
$BIN --eject "My Drive" --wait  # Keep waiting until the drive is free.
$BIN --login on                 # on, off, or status
```

## Tests

`Tests/disk-image-tests.sh` runs Cast Off against throwaway disk images. It doesn't touch real drives or stop real services.

## Other options

- [Jettison](https://stclairsoft.com/Jettison/) is a mature paid app that can also quit root-owned processes through a helper.
- [Ejecta](https://ejecta-web.pages.dev/) names what's blocking a drive.
- [Ejectify](https://github.com/nielsmouthaan/ejectify-macos) unmounts drives automatically when your Mac sleeps.

## License

[MIT](LICENSE)
