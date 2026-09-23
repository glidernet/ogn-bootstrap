# Credits and provenance

This is a clean-room implementation. No code was copied from any of the
projects below; they were read as documentation of *what a working OGN
receiver needs*, and everything here was written from scratch. What is shared
with them is fact rather than expression — Debian package names, kernel module
names, download URLs, the libconfig keys the OGN binaries parse — none of which
anybody owns.

That distinction is not pedantry. It is what lets this repository carry a
permissive licence while building on what other people worked out first.

## Prior art

**[snip/OGN-receiver-RPI-image](https://github.com/snip/OGN-receiver-RPI-image)**
— Sébastien Chaumontet. The OGN Raspberry Pi image most receivers in the field
still run. Its `imageCreationSteps.md` is the clearest surviving account of
what actually has to happen to turn a stock Raspbian card into a receiver:
blacklisting the DVB-T drivers, the read-only overlay, the single config file
on the boot partition, and the idea that a receiver should be configurable
without ever logging into it. That last idea is the one this repository is
built around.

Licensed **GPL-3.0**. Nothing here is derived from its code.

**[glc-illustrious/ogn-receiver-club](https://github.com/glc-illustrious/ogn-receiver-club)**
— the first write-up we found of the Debian 13 (Trixie) package substitutions:
`libconfig9` → `libconfig11`, `ntp` → `ntpsec`, and the discovery that the
64-bit Pi needs the `arm64` build rather than the `rpi-gpu` one. Useful
groundwork, and it saved a lot of guessing.

Carries **no licence file at all**, which means no rights are granted to
anybody. Nothing here is derived from its code either — and if you are
thinking of reusing it, that is worth knowing.

**[glidernet/ogn-bootstrap v2.1](https://github.com/glidernet/ogn-bootstrap/tree/v2.1-legacy)**
— this repository's own previous generation, by Melissa Jenkins. It got the
checksum question right in 2014, verifying downloads against upstream's
`md5.txt` at a time when most installers did not verify anything at all. The
version manifest here is the same instinct, moved somewhere the checksum can
actually be trusted.

## The receiver software itself

The `ogn-rf` and `gsm_scan` binaries are **GPL-3.0**, with source at
[glidernet/ogn-rf](https://github.com/glidernet/ogn-rf). `ogn-decode` is
closed source and publishes no redistribution terms at all.

This repository therefore ships **no binaries**. `versions.json` records URLs
and checksums; each receiver downloads from
[download.glidernet.org](http://download.glidernet.org) itself, at install
time. If you are packaging this further, that distinction matters.

## The published image

The `.img.xz` released here is Raspberry Pi OS Lite (64-bit) with packages from
the Debian and Raspberry Pi archives installed into it, so it is a
redistribution of thousands of other people's work under their own licences —
mostly GPL, with the rest spelled out per package in `/usr/share/doc/*/copyright`
inside the image itself.

We add no modified binaries, and everything we do add is the MIT-licensed
content of this repository. For the GPL components, the corresponding source is
the same source Debian and Raspberry Pi publish:

- `https://deb.debian.org/debian` and `https://sources.debian.org`
- `https://archive.raspberrypi.com/debian`

`apt-get source <package>` inside a running receiver fetches exactly the source
for the version installed. `/etc/ogn-bootstrap-image` records which base image
a given card was built from, and its SHA256, so that mapping is unambiguous.

The receiver software is **not** in the image, for the licensing reason above.

## Documentation worth reading

- [Receiver naming convention](http://wiki.glidernet.org/receiver-naming-convention)
- [Preventing SD card corruption](http://wiki.glidernet.org/wiki:prevent-sd-card-corruption)
- [Cloud-init on Raspberry Pi OS](https://www.raspberrypi.com/news/cloud-init-on-raspberry-pi-os/)
