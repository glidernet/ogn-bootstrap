#!/bin/bash
#
# build-image.sh — build the "OGN Receiver" image for Raspberry Pi Imager.
#
# The result is Raspberry Pi OS Lite (64-bit) plus:
#
#   * the Debian packages the receiver needs, already installed
#   * the ogn-bootstrap scripts, already in /usr/local
#   * MyReceiver.conf and the first-boot installer on the boot partition
#
# It is NOT a new operating system. Every byte outside that list is stock
# Raspberry Pi OS, downloaded from Raspberry Pi over TLS and checked against
# the SHA256 that Imager itself uses. That is the point: the image stays
# auditable as "the official image, plus this list".
#
# cloud-init is left exactly as it ships, so the Imager customisation wizard
# (hostname, user, wifi, SSH keys, Raspberry Pi Connect) works unchanged.
#
# ---------------------------------------------------------------------------
# WHERE THIS RUNS
#
# CI, on a Linux runner, as root. It downloads a ~550 MB image and runs apt
# inside an emulated arm64 chroot, so it needs loop devices, binfmt_misc and
# a network. It refuses to run anywhere else — see require_linux_root below.
# Nothing about it is meant for a workstation.
# ---------------------------------------------------------------------------
#
# Copyright (c) 2026 ifly7charlie. MIT licence, see LICENSE.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The list Imager itself reads. Gives us the current Lite image, its SHA256,
# and the init_format Imager will use — all over TLS from Raspberry Pi.
OS_LIST_URL="${OS_LIST_URL:-https://downloads.raspberrypi.org/os_list_imagingutility_v4.json}"
BASE_NAME="${BASE_NAME:-Raspberry Pi OS Lite (64-bit)}"

# Headroom added to the root filesystem for the preinstalled packages. The Pi
# expands the partition to fill the card on first boot regardless, and xz
# squeezes the unused part down to nothing, so this is cheap.
GROW_MB="${GROW_MB:-512}"

OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/.build}"

# Mirrors the PACKAGES list in src/ogn-install, including both optional ones.
# ogn-install re-runs apt_install on first boot; because that is idempotent,
# anything already here makes first boot a no-op instead of a download.
PACKAGES=(
    rtl-sdr
    librtlsdr0
    libpng16-16t64
    lynx
    curl
    ca-certificates
    unattended-upgrades
    overlayroot
    autossh
)

log()  { printf '\n=== %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

require_linux_root() {
    [ "$(uname -s)" = "Linux" ] || die \
"this builds a Linux disk image by loop-mounting it and running apt in an
       arm64 chroot. It only works on Linux. Use the GitHub Actions workflow
       (.github/workflows/build-image.yml) rather than running it by hand."
    [ "$(id -u)" -eq 0 ] || die "must run as root (loop devices and chroot)"

    local missing=() t
    for t in curl python3 xz parted losetup mount chroot resize2fs e2fsck sha256sum; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]}"

    # arm64 binaries have to run somehow. Either the host is arm64, or binfmt
    # has qemu registered (docker/setup-qemu-action, or qemu-user-static).
    if [ "$(uname -m)" != "aarch64" ]; then
        [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
            || command -v qemu-aarch64-static >/dev/null 2>&1 \
            || die "no way to run arm64 binaries: register qemu-aarch64 with
       binfmt_misc, or install qemu-user-static"
    fi
}

# ---------------------------------------------------------------------------
# Base image
# ---------------------------------------------------------------------------

# Pull the current Lite entry out of Imager's own OS list. Doing it this way
# rather than hardcoding a URL means the image tracks Raspberry Pi's releases,
# and that the hash we verify against is the one Imager would have used.
resolve_base() {
    curl -fsSL --retry 3 "$OS_LIST_URL" -o "$WORK_DIR/os_list.json"
    BASE_JSON="$WORK_DIR/base.json"
    python3 - "$WORK_DIR/os_list.json" "$BASE_NAME" > "$BASE_JSON" <<'PY'
import json, sys

want = sys.argv[2]

def walk(items):
    for it in items:
        if "subitems" in it:
            yield from walk(it["subitems"])
        elif "url" in it:
            yield it

with open(sys.argv[1]) as fh:
    data = json.load(fh)

for entry in walk(data["os_list"]):
    if entry.get("name") == want:
        # cloudinit-rpi is what makes the Imager wizard and our boot-partition
        # payload work. Anything else means Raspberry Pi changed the first-boot
        # mechanism under us, and the build should stop rather than ship an
        # image that silently ignores the user's settings.
        if entry.get("init_format") != "cloudinit-rpi":
            sys.exit("%r has init_format %r, expected 'cloudinit-rpi'"
                     % (want, entry.get("init_format")))
        json.dump(entry, sys.stdout, indent=1)
        break
else:
    sys.exit("%r not found in the Raspberry Pi OS list" % want)
PY
    BASE_URL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$BASE_JSON")
    BASE_SHA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["extract_sha256"])' "$BASE_JSON")
    BASE_DATE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release_date"])' "$BASE_JSON")
    BASE_FILE="$WORK_DIR/$(basename "$BASE_URL")"
    BASE_IMG="${BASE_FILE%.xz}"
}

fetch_base() {
    if [ ! -f "$BASE_IMG" ]; then
        log "downloading $BASE_URL"
        curl -fSL --retry 3 --retry-delay 5 "$BASE_URL" -o "$BASE_FILE.part"
        mv "$BASE_FILE.part" "$BASE_FILE"
        log "decompressing"
        xz -dk -T0 "$BASE_FILE"
    fi

    log "verifying the base image against Raspberry Pi's published SHA256"
    local got
    got=$(sha256sum "$BASE_IMG" | cut -d' ' -f1)
    [ "$got" = "$BASE_SHA" ] || die "base image SHA256 mismatch
       expected $BASE_SHA
       got      $got"
    printf 'ok: %s (%s)\n' "$(basename "$BASE_IMG")" "$BASE_DATE"
}

# ---------------------------------------------------------------------------
# Mount / unmount
# ---------------------------------------------------------------------------

LOOP=""
MNT=""
RESOLV_SAVED=0

cleanup() {
    set +e
    if [ -n "$MNT" ] && [ -d "$MNT" ]; then
        if [ "$RESOLV_SAVED" -eq 1 ]; then
            rm -f "$MNT/etc/resolv.conf"
            mv "$MNT/etc/resolv.conf.ogn-build" "$MNT/etc/resolv.conf" 2>/dev/null
        fi
        rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/usr/bin/qemu-aarch64-static"
        umount -R "$MNT/dev" "$MNT/proc" "$MNT/sys" 2>/dev/null
        umount "$MNT/boot/firmware" 2>/dev/null
        umount "$MNT" 2>/dev/null
        rmdir "$MNT" 2>/dev/null
    fi
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    set -e
}
trap cleanup EXIT

grow_and_mount() {
    log "growing the root filesystem by ${GROW_MB} MiB"
    truncate -s "+${GROW_MB}M" "$IMG"
    parted -s "$IMG" resizepart 2 100%

    LOOP=$(losetup --find --show --partscan "$IMG")
    e2fsck -fp "${LOOP}p2" || true          # exit 1 just means "fixed something"
    resize2fs "${LOOP}p2"

    MNT=$(mktemp -d /tmp/ogn-image.XXXXXX)
    mount "${LOOP}p2" "$MNT"
    mount "${LOOP}p1" "$MNT/boot/firmware"
    printf 'mounted %s on %s\n' "$LOOP" "$MNT"
}

prepare_chroot() {
    mount --bind /dev     "$MNT/dev"
    mount --bind /dev/pts "$MNT/dev/pts"
    mount -t proc  proc  "$MNT/proc"
    mount -t sysfs sysfs "$MNT/sys"

    # Raspberry Pi OS ships /etc/resolv.conf as a symlink into /run, which is
    # empty in a chroot. Swap in a real file and put the symlink back after.
    mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.ogn-build"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$MNT/etc/resolv.conf"
    RESOLV_SAVED=1

    # Stop package postinst scripts trying to start daemons that cannot run
    # here. The real units are enabled normally; they just do not launch now.
    printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"
    chmod 0755 "$MNT/usr/sbin/policy-rc.d"

    if [ "$(uname -m)" != "aarch64" ] && command -v qemu-aarch64-static >/dev/null 2>&1; then
        cp "$(command -v qemu-aarch64-static)" "$MNT/usr/bin/"
    fi

    # Smoke test: if arm64 does not execute, everything after this is noise.
    chroot "$MNT" /bin/true || die "cannot execute arm64 binaries in the chroot"
}

# ---------------------------------------------------------------------------
# The actual changes
# ---------------------------------------------------------------------------

install_packages() {
    log "installing packages: ${PACKAGES[*]}"
    # Same flags as apt_install in src/ogn-common.sh, so that the first-boot
    # run finds these already satisfied and does nothing.
    chroot "$MNT" env DEBIAN_FRONTEND=noninteractive \
        apt-get update -qq
    chroot "$MNT" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --no-install-recommends "${PACKAGES[@]}"
    chroot "$MNT" apt-get clean
}

install_scripts() {
    log "installing the ogn-bootstrap scripts"
    install -d -m 0755 "$MNT/usr/local/lib/ogn-bootstrap" "$MNT/usr/local/sbin"
    install -m 0644 src/ogn-common.sh "$MNT/usr/local/lib/ogn-bootstrap/"
    local f
    for f in src/ogn-install src/ogn-update src/ogn-maintenance \
             src/ogn-remote-admin src/ogn-calibrate; do
        install -m 0755 "$f" "$MNT/usr/local/sbin/"
    done

    # A snapshot of the release manifest, so a receiver on a slow or blocked
    # link still has something to resolve UpdateChannel against. ogn-update
    # refreshes it from GitHub when it can.
    install -d -m 0755 "$MNT/var/lib/ogn-bootstrap"
    install -m 0644 versions.json "$MNT/var/lib/ogn-bootstrap/versions.json"
}

install_boot_files() {
    log "placing MyReceiver.conf and the first-boot installer"
    install -m 0644 boot/MyReceiver.conf "$MNT/boot/firmware/MyReceiver.conf"
    install -m 0755 boot/vendor-data    "$MNT/boot/firmware/vendor-data"
}

stamp_image() {
    cat > "$MNT/etc/ogn-bootstrap-image" <<EOF
# Written by tools/build-image.sh. Identifies this image to support requests.
OGN_IMAGE_VERSION=$VERSION
OGN_IMAGE_DATE=$BUILD_DATE
OGN_BASE_IMAGE=$(basename "$BASE_IMG")
OGN_BASE_DATE=$BASE_DATE
OGN_BASE_SHA256=$BASE_SHA
EOF
    chmod 0644 "$MNT/etc/ogn-bootstrap-image"
}

tidy() {
    log "tidying"
    rm -rf "$MNT/var/lib/apt/lists/"*
    rm -f  "$MNT/var/cache/apt/archives/"*.deb
    find "$MNT/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true
    rm -f "$MNT/root/.bash_history" "$MNT/etc/machine-id"
    : > "$MNT/etc/machine-id"          # regenerated on first boot

    # cloud-init must still think it has never run. If this is not empty the
    # image was booted somewhere it should not have been.
    if [ -n "$(ls -A "$MNT/var/lib/cloud" 2>/dev/null)" ]; then
        die "/var/lib/cloud is not empty — the image has state from a boot"
    fi

    # Zero the slack so xz has something compressible to chew on.
    dd if=/dev/zero of="$MNT/.zerofill" bs=4M status=none 2>/dev/null || true
    rm -f "$MNT/.zerofill"
    sync
}

# ---------------------------------------------------------------------------
# Package up
# ---------------------------------------------------------------------------

compress_and_describe() {
    log "compressing (this is the slow part)"
    rm -f "$OUT_IMG_XZ"
    xz -9 -T0 -c "$IMG" > "$OUT_IMG_XZ"

    local extract_size extract_sha download_size download_sha
    extract_size=$(stat -c %s "$IMG")
    extract_sha=$(sha256sum "$IMG" | cut -d' ' -f1)
    download_size=$(stat -c %s "$OUT_IMG_XZ")
    download_sha=$(sha256sum "$OUT_IMG_XZ" | cut -d' ' -f1)

    python3 - > "$OUT_DIR/image-meta.json" <<PY
import json
json.dump({
    "name": "OGN Receiver",
    "file": "$(basename "$OUT_IMG_XZ")",
    "version": "$VERSION",
    "release_date": "$BUILD_DATE",
    "base_image": "$(basename "$BASE_IMG")",
    "base_release_date": "$BASE_DATE",
    "base_sha256": "$BASE_SHA",
    "extract_size": $extract_size,
    "extract_sha256": "$extract_sha",
    "image_download_size": $download_size,
    "image_download_sha256": "$download_sha",
}, open(1, "w", closefd=False), indent=2)
PY
    printf '\n'
    cat "$OUT_DIR/image-meta.json"
    printf '\nwrote %s\n' "$OUT_IMG_XZ"
}

# ---------------------------------------------------------------------------

main() {
    require_linux_root
    mkdir -p "$WORK_DIR" "$OUT_DIR"

    VERSION="${OGN_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"
    BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%d)}"

    resolve_base
    fetch_base

    IMG="$WORK_DIR/ogn-receiver-$BUILD_DATE-arm64.img"
    OUT_IMG_XZ="$OUT_DIR/ogn-receiver-$BUILD_DATE-arm64.img.xz"

    log "copying the base image"
    cp --reflink=auto "$BASE_IMG" "$IMG"

    grow_and_mount
    prepare_chroot
    install_packages
    install_scripts
    install_boot_files
    stamp_image
    tidy

    cleanup
    trap - EXIT

    compress_and_describe
}

main "$@"
