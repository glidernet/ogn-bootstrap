# ogn-bootstrap

Pick **OGN Receiver** in Raspberry Pi Imager, say where the aerial is, put the
card in the Pi. No logging in, no SSH session, no setup wizard — by the time it
first boots, it already knows what it is.

Everything is configured before the card ever goes near the Pi, which matters
when the receiver lives in a locked container on the far side of an airfield.

## What you need

| | |
|---|---|
| A Raspberry Pi | 3B/3B+, 4, 5, or CM3/CM4/CM5 — 64-bit, with 1 GB of RAM or more. Not the Zero 2 W or the 3A+: 64-bit, but only 512 MB. Not the Pi 1, 2, Zero, Zero W or CM1, which are 32-bit. |
| An SD card | **8 GB or more.** The image flashes to 3.6 GB, so 4 GB is technically enough and practically a bad idea. Nothing above 16 GB is ever used. |
| An RTL-SDR stick | RTL-SDR Blog V3/V4 or similar; the TCXO ones need no calibration |
| An 868 MHz aerial | outdoors, as high as you can reasonably get it |
| [Raspberry Pi Imager](https://www.raspberrypi.com/software/) **2.0 or newer** | older versions cannot configure Trixie and fail *silently* |

## Setup

### 1. Point Imager at this repository

Once only. In Imager, open **Settings** and switch the image repository to:

```
https://raw.githubusercontent.com/glidernet/ogn-bootstrap/master/os-list.json
```

Or, if you are scripting it:

```sh
rpi-imager --repo https://raw.githubusercontent.com/glidernet/ogn-bootstrap/master/os-list.json
```

The same setting switches back to Raspberry Pi's list afterwards.

### 2. Flash the card

Choose **OGN Receiver**, then use the customisation wizard to set:

- **hostname** — this doubles as the receiver's name on the OGN network, so
  make it something like `Lasham` or `EGHL` (up to 9 letters and digits)
- **username and password**
- **wifi**, if it is not on ethernet
- **SSH**, with your public key

The wizard works exactly as it does on the stock image, because underneath this
*is* the stock image — see [How the image is built](#how-the-image-is-built).

### 3. Edit `MyReceiver.conf`

Imager ejects the card when it finishes, so take it out and put it back in.
A volume called `bootfs` appears, with `MyReceiver.conf` already on it.

Open it in any text editor. There are four lines marked `TODO`:

```c
Call       = "";          // blank = use the hostname you set in Imager
Latitude   =    +0.0000;  // where the AERIAL is, decimal degrees
Longitude  =    +0.0000;
Altitude   =          0;  // metres above sea level, to the aerial
```

The file explains each one in full, including the traps: decimal degrees
rather than degrees and minutes, metres rather than feet, and the height of
the aerial rather than the height of the mast.

Everything else has a working default. Leave it alone unless you have a
reason.

### 4. Boot

Eject, put the card in the Pi, power on. The packages are already in the image,
so first boot is mostly waiting for the network: it fetches the decoder (about
350 kB) and the geoid table, then reboots itself once to bring up the read-only
filesystem. A minute or two, not five.

Check it worked:

```
http://<hostname>.local:8080/        status page
ssh <user>@<hostname>.local          then: systemctl status rtlsdr-ogn
```

Within a few minutes the receiver should appear on
[live.glidernet.org](https://live.glidernet.org).

## What it sets up

| | |
|---|---|
| OGN decoder | downloaded from glidernet, checksum-verified against [`versions.json`](versions.json) |
| DVB-T blacklist | stops the TV drivers grabbing the SDR stick |
| `rtlsdr-ogn.service` | native systemd, starting only once the clock is actually synchronised |
| Read-only root | the single most effective way to stop SD cards dying in the field |
| Hardware watchdog | reboots the Pi if it wedges |
| Weekly maintenance | security updates and OGN upgrades, in a window you choose |
| Geoid data | `WW15MGH.DAC`, so altitudes are right without hand-tuning |

Nothing is exposed to the internet, and no remote access is enabled, unless
you ask for it.

## Writes to the SD card

SD cards die two ways: wear from constant small writes, and corruption when
the power goes off mid-write. A receiver on an airfield gets plenty of both.
With `ReadOnlyFS = true` the answer is meant to be "nothing writes to the card
at all", so it is worth being precise about how that is achieved.

| | |
|---|---|
| Root filesystem | `overlayroot=tmpfs`. Every write goes to RAM and is discarded at reboot. |
| Journal | `Storage=volatile`, capped at 32 MB. Lives in `/run`, never `/var/log/journal` — pinned explicitly rather than relying on the overlay, so it holds even with `ReadOnlyFS = false`. |
| rsyslog | Not installed on Trixie. Disabled if something pulls it in, since it would write `/var/log/syslog` continuously. |
| `atime` | Raspberry Pi OS already mounts root `noatime`. |
| Swap | Disabled, along with the units that recreate it. A swapfile on a tmpfs overlay pins RAM to hold a "disk" that is itself RAM. |
| Boot partition | Mounted **read-only**, and made writable only for the moment it takes to write the maintenance marker — a handful of writes per week, each flushed and dropped straight back to read-only. |

That last one matters most. The root filesystem can hide behind the overlay,
but `/boot/firmware` cannot: cloud-init reads it, and the maintenance marker
has to survive the reboots the maintenance cycle depends on. It is also FAT,
which is the filesystem that actually corrupts when the power fails. So it
stays read-only except for those few seconds.

The practical upshot: between maintenance windows, a receiver running with
`ReadOnlyFS = true` does not write to the card at all. You can pull the power
whenever you like.

The cost is the usual one — changes you make by hand disappear at the next
reboot. Edit `MyReceiver.conf` on the card, or use `sudo ogn-maintenance --now`
to get a writable window.

## How the image is built

The image is not a new operating system. It is the official **Raspberry Pi OS
Lite (64-bit)** image, downloaded from Raspberry Pi and verified against the
same SHA256 Imager itself uses, with a short and enumerable list of changes:

| | |
|---|---|
| Packages installed | `rtl-sdr`, `librtlsdr0`, `libpng16-16t64`, `lynx`, `unattended-upgrades`, `overlayroot`, `autossh` — all from the Debian and Raspberry Pi archives |
| Files added | the `ogn-*` scripts in `/usr/local`, `MyReceiver.conf` and the first-boot installer on the boot partition, and `/etc/ogn-bootstrap-image` recording what it was built from |
| Files changed | none |
| Root filesystem | grown by 512 MB to fit the above; the Pi expands it to fill the card on first boot as usual |

cloud-init is left exactly as Raspberry Pi ships it, which is why the Imager
customisation wizard — hostname, user, wifi, SSH keys, Raspberry Pi Connect —
behaves identically to the stock image.

**There is no shrink step, and it does not need one.** The older OGN image was
captured by reading a physical SD card, so it came out the size of whatever
card happened to be in the reader and had to be shrunk back down before it
could be published. This one is built the other way round — from Raspberry
Pi's own already-minimal image, which never goes near a card — so there is
nothing to reclaim. It grows instead: 512 MB, to give `apt` room to work,
taking the flashed size from 3.06 GB to 3.60 GB. The download barely moves,
because the added space is zeroed before compression and `xz` throws it away.
Either way the Pi expands the root filesystem to fill the card on first boot,
exactly as the stock image does — that is one of the files we do not touch.

**The OGN decoder itself is not in the image.** `ogn-rf` and `gsm_scan` are
GPLv3 and `ogn-decode` is published with no redistribution terms at all, so
each receiver downloads them at first boot instead, verified against
[`versions.json`](versions.json). See [CREDITS.md](CREDITS.md).

To build it yourself, or to check that the published image matches:

```sh
sudo tools/build-image.sh          # Linux only; needs loop devices and qemu
```

It refuses to run on anything but Linux as root — it loop-mounts a disk image
and runs `apt` inside an emulated arm64 chroot, which is a CI activity, not a
workstation one. [`.github/workflows/build-image.yml`](.github/workflows/build-image.yml)
is the canonical invocation and documents why it is split into an unprivileged
build job and a separate publishing job.

### Installing on a Pi that is already running

If you have a working Raspberry Pi OS Trixie install and do not want to reflash
it, the installer works standalone:

```sh
git clone https://github.com/glidernet/ogn-bootstrap
sudo cp ogn-bootstrap/boot/MyReceiver.conf /boot/firmware/   # then edit it
sudo ogn-bootstrap/src/ogn-install
```

The stock-image route also still works: copy [`boot/vendor-data`](boot/vendor-data)
and [`boot/MyReceiver.conf`](boot/MyReceiver.conf) onto the boot partition of a
plain Raspberry Pi OS Lite card dated 2025-11-24 or later. It installs the same
packages on first boot instead of having them already, so it takes longer and
needs a more reliable network, but the result is identical — the image and this
route run the same installer from the same file.

## Remote access

All three are **off by default**, in the `Install.RemoteAdmin` section:

| Setting | What it does |
|---|---|
| `Connect` | [Raspberry Pi Connect](https://www.raspberrypi.com/documentation/services/connect.html): a shell in your browser, through NAT, using your Raspberry Pi ID. Set `ConnectAuthKey` to an organisation key to link it with no sign-in step; otherwise log in once and run `rpi-connect signin`. |
| `OGNTeam` | A reverse SSH tunnel letting the OGN core team log in to help diagnose problems. They must accept this machine's key first — ask on the OGN forum. **This grants a third party access to a machine on your club's network.** Worth it for a receiver nobody local can maintain; your decision either way. |
| `ExtraSSHKeys` | Additional authorised keys. Setting any also turns off SSH password login. |

## Updating

With a read-only root, updates have to happen with the overlay out of the way,
so they run as a two-reboot cycle inside the maintenance window:

```
overlay on   ->  disable overlay, reboot
overlay off  ->  security updates + OGN upgrade, enable overlay, reboot
overlay on   ->  back to normal
```

The state marker lives on the boot partition, outside the overlay, so an
interruption at any point resumes or backs out cleanly rather than leaving the
receiver unprotected.

```sh
sudo ogn-maintenance --status    # where things stand
sudo ogn-maintenance --now       # run the cycle immediately
sudo ogn-update --check          # installed vs available
```

Set `MaintenanceWindow = ""` to never update automatically.

### How versions are trusted

`download.glidernet.org` has no working HTTPS — and answers port 443 with
cleartext, so a "try TLS first" fallback looks like it works while protecting
nothing. So the checksums live here instead, in
[`versions.json`](versions.json), fetched over real TLS from GitHub. Upstream's
MD5 is checked too, but only for what it is good for: catching a corrupt
download.

New releases land by pull request:

```sh
tools/add-version 0.3.2 --promote latest     # download, hash, record
# then, once you have run it on a receiver or two:
#   edit channels.stable, commit
```

Receivers follow `Install.UpdateChannel`: `stable`, `latest`, or a pinned
version. Nothing moves under a fleet until you promote it.

> **Before first use:** `versions.json` ships with `sha256: null`, because the
> hashes have to be computed from the real downloads. Run
> `tools/add-version 0.3.2` and commit the result. Until you do, `ogn-update`
> refuses to install anything rather than running unverified code.

## Working on it

```sh
tests/run-tests            # offline: parser, validation, manifest, build
tools/build-vendor-data    # regenerate boot/vendor-data after editing src/
tools/make-icon            # regenerate doc/ogn-icon.png
```

`boot/vendor-data` is generated — edit `src/` and rebuild. It is kept as plain
readable shell rather than an encoded blob, because it ends up on someone
else's SD card and they are entitled to read what it intends to do.

The tests cover the parts that are pure logic. Installing packages, driving
systemd and switching the overlay can only be tested honestly on real
hardware — flash a spare card and watch `journalctl -u cloud-final`.

## Older receivers

Everything before Trixie used a different design: a web-based configurator you
reached by browser after booting the Pi. It is preserved at the
[`v2.1-legacy`](https://github.com/glidernet/ogn-bootstrap/tree/v2.1-legacy)
tag and is unmaintained.

## Licence

**This repository** is MIT — see [LICENSE](LICENSE). Every file here was
written for it; see [CREDITS.md](CREDITS.md) for what it was built from and why
none of it is copied.

**The published image** is a different question, because it is a redistribution
of Raspberry Pi OS. The MIT licence still covers our part of it, and the rest
stays under the licences it already had — mostly GPL, recorded per package in
`/usr/share/doc/*/copyright` inside the image. Putting them on one card is
aggregation, not relicensing, which is the same basis Raspberry Pi OS and every
other Debian derivative is distributed on.

What that does carry is an obligation to make the GPL source available.
[CREDITS.md](CREDITS.md#the-published-image) says how: the source is Debian's
and Raspberry Pi's own archives, and `/etc/ogn-bootstrap-image` on each card
records the exact base image and its SHA256 so the matching versions are never
in doubt.

**The receiver software** — `ogn-rf`, `gsm_scan`, `ogn-decode` — is not ours and
is not in the image. Each receiver downloads it at install time. That is a
licensing decision, not an implementation detail: `ogn-decode` publishes no
redistribution terms, so it is not ours to ship.
