# shellcheck shell=bash
# Shared helpers for the ogn-bootstrap scripts.
# Sourced, never executed directly.
#
# Copyright (c) 2026 ifly7charlie. MIT licence, see LICENSE.

# cloud-init runs the vendor script with a minimal PATH, so make sure the
# sibling commands are reachable by bare name.
case ":$PATH:" in *:/usr/local/sbin:*) ;; *) PATH="/usr/local/sbin:$PATH" ;; esac
export PATH

BOOT_DIR="${OGN_BOOT_DIR:-/boot/firmware}"
# Used by the scripts that source this file, which shellcheck cannot see.
# shellcheck disable=SC2034
BOOT_CONF="$BOOT_DIR/MyReceiver.conf"
# shellcheck disable=SC2034
STATE_DIR="$BOOT_DIR/ogn-bootstrap"
# What the card said when we last acted on it. On the boot partition, not in
# /var/lib: under the overlay a marker on the root filesystem reverts at every
# reboot, so the same edit would be re-detected for ever.
# shellcheck disable=SC2034
CONFIG_APPLIED="$STATE_DIR/config.applied"
# shellcheck disable=SC2034
INSTALL_APPLIED="$STATE_DIR/install.applied"
# A test image follows its branch's versions.json, as recorded in the image
# stamp by build-image.sh. raw.githubusercontent.com only: its TLS is what
# makes the SHA256s trustworthy.
IMAGE_STAMP="${OGN_IMAGE_STAMP:-/etc/ogn-bootstrap-image}"
MANIFEST_URL="${OGN_MANIFEST_URL:-}"
if [ -z "$MANIFEST_URL" ] && [ -r "$IMAGE_STAMP" ]; then
    MANIFEST_URL=$(sed -n 's|^OGN_MANIFEST_URL=\(https://raw\.githubusercontent\.com/.*\)$|\1|p' "$IMAGE_STAMP" | head -n 1)
fi
MANIFEST_MASTER_URL="https://raw.githubusercontent.com/glidernet/ogn-bootstrap/master/versions.json"
MANIFEST_URL="${MANIFEST_URL:-$MANIFEST_MASTER_URL}"
MANIFEST_CACHE="/var/lib/ogn-bootstrap/versions.json"
MOTD_FILE="/etc/motd.d/10-ogn-bootstrap"

log()  { printf '%s ogn-bootstrap: %s\n' "$(date -Is)" "$*"; }
warn() { printf '%s ogn-bootstrap: WARNING: %s\n' "$(date -Is)" "$*" >&2; }
die()  { printf '%s ogn-bootstrap: ERROR: %s\n' "$(date -Is)" "$*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0)"
}

# --------------------------------------------------------------------------
# libconfig reader
#
# Flattens a libconfig file to PATH=VALUE lines, e.g.
#   Install.RemoteAdmin.Connect=false
# Comments (// # /* */) are stripped string-aware, so a URL inside a quoted
# string is not mistaken for a comment. Values keep their quotes; conf_get
# strips them.
# --------------------------------------------------------------------------
_libconfig_flatten() {
    LC_ALL=C awk '{ src = src $0 "\n" } END {
        n = length(src); i = 1; instr = 0; out = ""
        while (i <= n) {
            c = substr(src, i, 1)
            if (instr) {
                out = out c
                if (c == "\\") { i++; out = out substr(src, i, 1); i++; continue }
                if (c == "\"") instr = 0
                i++; continue
            }
            if (c == "\"") { instr = 1; out = out c; i++; continue }
            if (c == "/" && substr(src, i+1, 1) == "/") {
                while (i <= n && substr(src, i, 1) != "\n") i++; continue }
            if (c == "#") {
                while (i <= n && substr(src, i, 1) != "\n") i++; continue }
            if (c == "/" && substr(src, i+1, 1) == "*") {
                i += 2
                while (i <= n && !(substr(src, i, 1) == "*" && substr(src, i+1, 1) == "/")) i++
                i += 2; continue }
            out = out c; i++
        }
        n = length(out); i = 1; np = 0; pending = ""
        while (i <= n) {
            c = substr(out, i, 1)
            if (c == " " || c == "\t" || c == "\n" || c == "\r") { i++; continue }
            if (c ~ /[A-Za-z_]/) {
                j = i
                while (j <= n && substr(out, j, 1) ~ /[A-Za-z0-9_]/) j++
                pending = substr(out, i, j - i); i = j; continue }
            if (c == "{") { np++; stack[np] = pending; pending = ""; i++; continue }
            if (c == "}") { if (np > 0) { delete stack[np]; np-- } pending = ""; i++; continue }
            if (c == "=") {
                j = i + 1; val = ""; bd = 0; ins = 0
                while (j <= n) {
                    d = substr(out, j, 1)
                    if (ins) {
                        val = val d
                        if (d == "\\") { j++; val = val substr(out, j, 1); j++; continue }
                        if (d == "\"") ins = 0
                        j++; continue }
                    if (d == "\"") { ins = 1; val = val d; j++; continue }
                    if (d == "[" || d == "(") { bd++; val = val d; j++; continue }
                    if (d == "]" || d == ")") { bd--; val = val d; j++; continue }
                    if (d == ";" && bd <= 0) break
                    val = val d; j++
                }
                p = ""
                for (k = 1; k <= np; k++) p = p stack[k] "."
                gsub(/^[ \t\r\n]+/, "", val); gsub(/[ \t\r\n]+$/, "", val)
                print p pending "=" val
                pending = ""; i = j + 1; continue }
            i++
        }
    }' "$1"
}

# conf_load <file> — flatten a libconfig file into a lookup table
#
# Deliberately a temp file rather than an associative array: Raspberry Pi OS
# has bash 5, but this way the scripts also run under the bash 3.2 on a Mac,
# which is where the test harness runs.
OGN_CONF_CACHE=""
conf_load() {
    local file="$1"
    [ -r "$file" ] || die "cannot read $file"
    [ -n "$OGN_CONF_CACHE" ] || OGN_CONF_CACHE=$(mktemp)
    _libconfig_flatten "$file" > "$OGN_CONF_CACHE"
    [ -s "$OGN_CONF_CACHE" ] || die "$file contained no settings — is it valid libconfig?"
}

conf_cleanup() { [ -n "$OGN_CONF_CACHE" ] && rm -f "$OGN_CONF_CACHE"; }

# conf_get <path> [default]
conf_get() {
    local k="$1" d="${2-}" val
    val=$(grep -m1 "^$k=" "$OGN_CONF_CACHE" 2>/dev/null) || true
    if [ -z "$val" ]; then printf '%s' "$d"; return 0; fi
    val="${val#*=}"
    # strip one layer of surrounding double quotes
    case "$val" in
        '"'*'"') val="${val#\"}"; val="${val%\"}" ;;
    esac
    if [ -z "$val" ]; then printf '%s' "$d"; else printf '%s' "$val"; fi
}

# conf_has <path> — true if the key is present at all, even if empty
conf_has() { grep -q "^$1=" "$OGN_CONF_CACHE" 2>/dev/null; }

# conf_bool <path> [default] — true/yes/1/on are true, anything else false
conf_bool() {
    case "$(conf_get "$1" "${2:-false}" | tr '[:upper:]' '[:lower:]')" in
        true|yes|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# Config digests
#
# Over the flattened settings, not the raw file, so re-indenting or fixing a
# comment does not read as a change. Sorted: the flattener follows file order.
# --------------------------------------------------------------------------
sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# conf_digest [section] — digest of everything, or of one top-level section
conf_digest() {
    if [ $# -eq 0 ]; then
        LC_ALL=C sort "$OGN_CONF_CACHE" | sha256_stdin
    else
        { grep "^$1\." "$OGN_CONF_CACHE" || true; } | LC_ALL=C sort | sha256_stdin
    fi
}

# conf_set_value <file> <key> <value> <comment> [block]
#
# Rewrite one "Key = ...;" in place, keeping its indentation. Scope it to a
# block: CenterFreq and Gain are in both RF.GSM and RF.OGN, so an unscoped
# substitution would retune the receiver while recording a calibration.
# Returns 1 if the key is absent rather than guessing where to add it.
conf_set_value() {
    local file="$1" key="$2" value="$3" comment="$4" block="${5-}" tmp rc
    tmp=$(mktemp)
    LC_ALL=C awk -v key="$key" -v value="$value" -v comment="$comment" -v want="$block" '
    {
        line = $0
        code = line
        # Our own stripper, not libconfig: # and // only, no /* */. A block
        # comment, or a brace inside a string, corrupts the depth count —
        # neither appears in the template.
        sub(/\/\/.*$/, "", code)
        sub(/#.*$/, "", code)
        countable = (index(code, "\"") == 0)
        if (code ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:[ \t]*$/) {
            lbl = code; gsub(/[ \t:]/, "", lbl); pending = lbl
        }
        opens = 0; closes = 0
        if (countable) {
            o = code; opens  = gsub(/\{/, "", o)
            c = code; closes = gsub(/\}/, "", c)
        }
        for (i = 0; i < opens; i++) { depth++; stack[depth] = pending; pending = "" }
        inblock = (want == "")
        if (!inblock) { for (i = 1; i <= depth; i++) if (stack[i] == want) inblock = 1 }
        if (!done && inblock && code ~ ("^[ \t]*" key "[ \t]*=")) {
            match(line, /^[ \t]*/)
            printf "%s%s = %s;   # %s\n", substr(line, 1, RLENGTH), key, value, comment
            done = 1
        } else print line
        for (i = 0; i < closes; i++) { if (depth > 0) { delete stack[depth]; depth-- } }
    }
    END { exit(done ? 0 : 1) }
    ' "$file" > "$tmp"
    rc=$?
    [ "$rc" -eq 0 ] && cat "$tmp" > "$file"
    rm -f "$tmp"
    return "$rc"
}

# --------------------------------------------------------------------------
# Service user
#
# Trixie has no default 'pi' account: Raspberry Pi Imager creates whatever the
# operator typed. Detect it rather than hardcoding, so the install lands in the
# right home directory whatever they chose.
# --------------------------------------------------------------------------
detect_ogn_user() {
    local u
    if [ -n "${OGN_USER_OVERRIDE:-}" ]; then
        printf '%s' "$OGN_USER_OVERRIDE"; return 0
    fi
    # UID 1000 is what Imager creates
    u=$(getent passwd 1000 | cut -d: -f1)
    if [ -n "$u" ]; then printf '%s' "$u"; return 0; fi
    # fall back to the first member of the sudo group with a real home
    for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
        if [ -d "$(getent passwd "$u" | cut -d: -f6)" ]; then
            printf '%s' "$u"; return 0
        fi
    done
    return 1
}

user_home() { getent passwd "$1" | cut -d: -f6; }

# --------------------------------------------------------------------------
# apt
#
# cloud-init may still be holding the lock when the vendor script runs, so wait
# rather than failing the whole first boot on a race.
# --------------------------------------------------------------------------
apt_wait() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/apt/lists/lock   >/dev/null 2>&1; do
        [ "$waited" -eq 0 ] && log "waiting for the apt lock to clear"
        sleep 5
        waited=$((waited + 5))
        [ "$waited" -ge 600 ] && die "apt lock still held after 10 minutes"
    done
}

apt_install() {
    [ $# -gt 0 ] || return 0
    local missing=()
    local p
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    log "installing: ${missing[*]}"
    apt_wait
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    apt_wait
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
}

# --------------------------------------------------------------------------
# Downloads
#
# The OGN binaries are served from download.glidernet.org over plain HTTP.
# There is no HTTPS: https:// fails the TLS handshake outright, and port 443
# on that host serves *cleartext*, so any "try TLS first" fallback would look
# like it worked while providing nothing.
#
# Integrity therefore comes from versions.json, which we fetch from GitHub over
# real TLS. Upstream's published MD5 is checked too, but only for what it was
# always for: spotting a truncated or corrupted download.
# --------------------------------------------------------------------------
fetch() {
    local url="$1" dest="$2"
    curl --fail --silent --show-error --location \
         --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 5 \
         --proto '=http,https' \
         -o "$dest" "$url"
}

# network_wait <host> — wait up to OGN_NETWORK_WAIT seconds (default 300) for
# <host> to resolve. First-boot wifi takes longer than curl's retries.
network_wait() {
    local host="$1" limit="${OGN_NETWORK_WAIT:-300}" waited=0
    while ! getent hosts "$host" >/dev/null 2>&1; do
        if [ "$waited" -ge "$limit" ]; then
            warn "no network after ${waited}s: cannot resolve $host"
            return 1
        fi
        [ $((waited % 30)) -eq 0 ] && log "waiting for the network (cannot resolve $host yet)"
        sleep 5
        waited=$((waited + 5))
    done
    [ "$waited" -gt 0 ] && log "network is up after ${waited}s"
    return 0
}

verify_sha256() {
    local file="$1" expected="$2" actual
    [ -n "$expected" ] || die "no expected SHA256 supplied for $file"
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        die "SHA256 mismatch for $file: expected $expected, got $actual"
    fi
}

verify_md5() {
    local file="$1" expected="$2" actual
    [ -n "$expected" ] || return 0
    actual=$(md5sum "$file" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        warn "upstream MD5 mismatch for $file (download may be corrupt)"
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------------
# Manifest
#
# json_get uses python3, which Raspberry Pi OS Lite ships. Keeping the manifest
# as JSON means tools/add-version and the GitHub action can edit it safely.
# --------------------------------------------------------------------------
manifest_download() {
    fetch "$1" "$2" && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$2"
}

manifest_fetch() {
    local tmp
    if ! mkdir -p "$(dirname "$MANIFEST_CACHE")" 2>/dev/null; then
        # Not root, so we cannot refresh the cache. A read-only check against
        # whatever was last fetched is still useful.
        [ -r "$MANIFEST_CACHE" ] && return 0
        return 1
    fi
    tmp=$(mktemp)
    if manifest_download "$MANIFEST_URL" "$tmp"; then
        mv "$tmp" "$MANIFEST_CACHE"
        return 0
    fi
    # The branch may since have been deleted.
    if [ "$MANIFEST_URL" != "$MANIFEST_MASTER_URL" ] \
       && manifest_download "$MANIFEST_MASTER_URL" "$tmp"; then
        warn "could not fetch $MANIFEST_URL; using master's version manifest instead"
        mv "$tmp" "$MANIFEST_CACHE"
        return 0
    fi
    rm -f "$tmp"
    if [ -r "$MANIFEST_CACHE" ]; then
        warn "could not fetch the version manifest; using the cached copy"
        return 0
    fi
    return 1
}

# manifest_resolve <channel-or-version> -> prints the version number
manifest_resolve() {
    python3 - "$MANIFEST_CACHE" "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
want = sys.argv[2]
v = m.get("channels", {}).get(want, want)
if v not in m.get("releases", {}):
    sys.exit(1)
print(v)
PY
}

# manifest_field <version> <arch> <field>
manifest_field() {
    python3 - "$MANIFEST_CACHE" "$1" "$2" "$3" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
try:
    print(m["releases"][sys.argv[2]][sys.argv[3]][sys.argv[4]])
except KeyError:
    sys.exit(1)
PY
}

ogn_arch() {
    case "$(dpkg --print-architecture)" in
        arm64) printf 'arm64' ;;
        armhf) printf 'armhf' ;;
        *)     printf '%s' "$(dpkg --print-architecture)" ;;
    esac
}

# --------------------------------------------------------------------------
# Boot partition
#
# /boot/firmware is FAT, and FAT is what actually corrupts when the power goes
# off mid-write. The root filesystem is protected by the overlay, but the boot
# partition cannot be: cloud-init has to read it, and the maintenance marker
# has to survive the reboots the maintenance cycle depends on.
#
# So it is mounted read-only in normal running and made writable only for the
# few seconds it takes to write something, then flushed and dropped back. A
# receiver that is never powered down cleanly will still come back.
# --------------------------------------------------------------------------
boot_rw() {
    mountpoint -q "$BOOT_DIR" || return 0
    findmnt -no OPTIONS "$BOOT_DIR" | grep -q '^ro\b\|,ro\b' || return 0
    mount -o remount,rw "$BOOT_DIR"
}

boot_ro() {
    mountpoint -q "$BOOT_DIR" || return 0
    sync -f "$BOOT_DIR" 2>/dev/null || sync
    mount -o remount,ro "$BOOT_DIR" 2>/dev/null || true
}

# boot_write <path> — write stdin to a file on the boot partition, safely
boot_write() {
    local dest="$1" was_ro=0
    findmnt -no OPTIONS "$BOOT_DIR" 2>/dev/null | grep -q '^ro\b\|,ro\b' && was_ro=1
    [ "$was_ro" -eq 1 ] && boot_rw
    mkdir -p "$(dirname "$dest")"
    cat > "$dest"
    sync -f "$dest" 2>/dev/null || sync
    [ "$was_ro" -eq 1 ] && boot_ro
    return 0
}

# boot_replace <path> — replace a file on the boot partition with stdin
#
# Unlike boot_write this overwrites something the operator still needs. Written
# alongside, flushed, then renamed, so a power cut on FAT leaves the old file
# or the new one, never half of one.
boot_replace() {
    local dest="$1" tmp="$1.new" was_ro=0
    findmnt -no OPTIONS "$BOOT_DIR" 2>/dev/null | grep -q '^ro\b\|,ro\b' && was_ro=1
    [ "$was_ro" -eq 1 ] && boot_rw
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        [ "$was_ro" -eq 1 ] && boot_ro
        return 1
    fi
    sync -f "$tmp" 2>/dev/null || sync
    mv -f "$tmp" "$dest"
    sync -f "$dest" 2>/dev/null || sync
    [ "$was_ro" -eq 1 ] && boot_ro
    return 0
}

# --------------------------------------------------------------------------
# The read-only root overlay
#
# Debian's overlayroot, switched with overlayroot=tmpfs in cmdline.txt on the
# FAT partition. Not /etc/overlayroot.conf: /etc is on the root filesystem,
# which the overlay hides, so an edit there is discarded by the reboot meant
# to apply it and the overlay could never be switched off from inside itself.
# --------------------------------------------------------------------------
CMDLINE_FILE="$BOOT_DIR/cmdline.txt"
CONFIG_TXT="$BOOT_DIR/config.txt"
OVERLAY_PARAM="overlayroot=tmpfs"

# What this boot did is in /proc/cmdline, which anybody can read. What the
# next boot will do is in cmdline.txt on the boot partition, which is mounted
# root-only so that the credentials beside it stay that way — see
# boot_partition_options in ogn-install. So the answer is published at every
# boot, and whenever it changes, to a file anyone can read.
#
# In /run deliberately: it is a cache of something authoritative elsewhere, and
# tmpfs means it cannot survive a reboot into disagreeing with the card.
OVERLAY_STATE="${OGN_OVERLAY_STATE:-/run/ogn-bootstrap/overlay-next-boot}"

overlay_active() { grep -qw -- "$OVERLAY_PARAM" /proc/cmdline 2>/dev/null; }

overlay_next_boot() {
    if [ -r "$CMDLINE_FILE" ]; then
        grep -qw -- "$OVERLAY_PARAM" "$CMDLINE_FILE" 2>/dev/null
    else
        grep -qx 'enabled' "$OVERLAY_STATE" 2>/dev/null
    fi
}

# overlay_next_boot_known — false when neither source can be read, so that a
# status display can say "cannot tell" rather than quietly saying "disabled".
overlay_next_boot_known() { [ -r "$CMDLINE_FILE" ] || [ -r "$OVERLAY_STATE" ]; }

# overlay_state_publish — refresh that cache. Called at every boot, and by
# cmdline_write, which is the only thing that changes the answer.
overlay_state_publish() {
    [ -r "$CMDLINE_FILE" ] || return 0
    install -d -m 0755 "$(dirname "$OVERLAY_STATE")" 2>/dev/null || return 0
    if grep -qw -- "$OVERLAY_PARAM" "$CMDLINE_FILE" 2>/dev/null; then
        printf 'enabled\n' > "$OVERLAY_STATE"
    else
        printf 'disabled\n' > "$OVERLAY_STATE"
    fi
    chmod 0644 "$OVERLAY_STATE" 2>/dev/null || true
    return 0
}

overlay_status() {
    local now next
    overlay_active && now=active || now=inactive
    if overlay_next_boot_known; then
        overlay_next_boot && next=enabled || next=disabled
    else
        next=unknown
    fi
    printf '%s now=%s next_boot=%s\n' "$next" "$now" "$next"
}

# cmdline_write <param> <1 to add, 0 to remove>
#
# cmdline.txt is one line of space-separated parameters. Rebuilt from its own
# tokens rather than patched with sed: no escaping to get wrong, no duplicates,
# and no stray second line, which the bootloader would ignore.
cmdline_write() {
    local param="$1" want="$2" out
    [ -r "$CMDLINE_FILE" ] || { warn "cannot read $CMDLINE_FILE"; return 1; }
    out=$(LC_ALL=C awk -v param="$param" -v want="$want" '
        { for (i = 1; i <= NF; i++) if ($i != param) toks[++n] = $i }
        END {
            if (want == "1") toks[++n] = param
            line = ""
            for (i = 1; i <= n; i++) line = line (i > 1 ? " " : "") toks[i]
            print line
        }' "$CMDLINE_FILE")
    # A truncated cmdline.txt is an unbootable Pi. Never write one.
    case "$out" in
        ""|"$OVERLAY_PARAM") warn "refusing to write a suspiciously short $CMDLINE_FILE"; return 1 ;;
    esac
    printf '%s\n' "$out" | boot_replace "$CMDLINE_FILE" || return 1
    overlay_state_publish
}

# The parameter is inert without an initramfs to act on it, and that failure is
# silent — the Pi boots normally and keeps writing to the card. Check first.
overlay_preflight() {
    local problems=0
    if ! dpkg-query -W -f='${Status}' overlayroot 2>/dev/null | grep -q "ok installed"; then
        warn "the overlayroot package is not installed"
        problems=1
    fi
    if ! grep -qE '^[[:space:]]*auto_initramfs=1' "$CONFIG_TXT" 2>/dev/null; then
        warn "auto_initramfs=1 is not set in $CONFIG_TXT, so no initramfs will be loaded"
        problems=1
    fi
    return "$problems"
}

# auto_initramfs=1 picks up whatever initramfs-tools last built, so it survives
# kernel upgrades; naming one file does not.
overlay_ensure_initramfs() {
    grep -qE '^[[:space:]]*auto_initramfs=1' "$CONFIG_TXT" 2>/dev/null && return 0
    [ -r "$CONFIG_TXT" ] || { warn "no $CONFIG_TXT; cannot enable the initramfs"; return 1; }
    log "adding auto_initramfs=1 to $CONFIG_TXT"
    { cat "$CONFIG_TXT"; printf '\n# Load the initramfs the overlay needs. Added by ogn-bootstrap.\nauto_initramfs=1\n'; } \
        | boot_replace "$CONFIG_TXT"
}

OVERLAY_MOTD=/etc/motd.d/30-ogn-overlay

# overlay_motd_update — report the overlay in the login banner.
#
# A file rewritten at boot, not a script run per login: the live state is fixed
# by the initramfs, so it cannot change while the system is up. What the next
# boot will do can, and everything that changes it calls this.
overlay_motd_update() {
    local tmp
    mkdir -p "$(dirname "$OVERLAY_MOTD")" 2>/dev/null || return 0
    tmp=$(mktemp) || return 0
    if overlay_active && overlay_next_boot; then
        cat > "$tmp" <<'EOF'

  Filesystem:  READ-ONLY. Anything you change is discarded at the next reboot.
               To make a change stick:  sudo overlay off --reboot

EOF
    elif overlay_active; then
        cat > "$tmp" <<'EOF'

  Filesystem:  READ-ONLY for now, but switched OFF for the next boot.
               Reboot and this receiver comes up writable.
               Changed your mind?  sudo overlay on

EOF
    elif overlay_next_boot; then
        cat > "$tmp" <<'EOF'

  Filesystem:  WRITABLE, and read-only again after the next reboot.
               Finish what you are doing, then:  sudo reboot

EOF
    else
        cat > "$tmp" <<'EOF'

  *** Filesystem: WRITABLE. The read-only overlay is OFF. ***

  This receiver is writing to its SD card. That is fine while you are working
  on it, and a bad way to leave it: a card written to continuously, on a
  machine that loses power without warning, is the commonest way a receiver
  dies in the field.

  When you have finished:  sudo overlay on --reboot

EOF
    fi
    # Only touch the file if it actually changed. This runs at every boot, and
    # with the overlay off it is a write to the SD card.
    cmp -s "$tmp" "$OVERLAY_MOTD" || install -m 0644 "$tmp" "$OVERLAY_MOTD" 2>/dev/null || true
    rm -f "$tmp"
    return 0
}

# Swap on a tmpfs overlay is pathological: the backing file lives in the RAM
# upper layer, so the system pins memory to hold a "disk" that is itself
# memory, and the overlay slowly fills. Disable the units that recreate it
# rather than just swapoff, or it returns at the next boot.
#
# On Trixie the units come from rpi-swap-generator, regenerated under /run at
# every boot, so `systemctl disable` cannot touch them; only its own config
# can. Must be written while the root filesystem is still writable.
SWAP_DROPIN="${OGN_SWAP_DROPIN:-/etc/rpi/swap.conf.d/90-ogn-bootstrap.conf}"
swap_disable() {
    local u
    install -d -m 0755 "$(dirname "$SWAP_DROPIN")"
    printf '# Written by ogn-bootstrap: no swap under the read-only overlay.\n[Main]\nMechanism=none\n' \
        > "$SWAP_DROPIN"
    swapoff -a 2>/dev/null || true
    for u in rpi-setup-loop@var-swap.service rpi-resize-swap-file.service dphys-swapfile.service; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
    done
    rm -f /var/swap 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Wifi from the card
#
# Imager's wifi goes into cloud-init's network-config, read once per instance
# and rendered to a NetworkManager keyfile on ext4 -- which no Mac or Windows
# machine can open. Change the wifi password and a receiver linked only by that
# wifi is unreachable by every route at once. So Network.Wifi is applied every
# boot from the FAT partition, which any laptop can edit. Empty SSID, the
# shipped default, does nothing and leaves Imager's wifi alone.
#
# The password is in clear on the card. So is Imager's, so this is not a new
# exposure, but say it out loud.
# --------------------------------------------------------------------------
WIFI_CONN=ogn-wifi

wifi_device() {
    nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" { print $1; exit }'
}

# On a cold boot the sync service can beat NetworkManager to it.
wifi_wait_for_nm() {
    local waited=0
    while ! nmcli general status >/dev/null 2>&1; do
        [ "$waited" -ge 30 ] && return 1
        sleep 2
        waited=$((waited + 2))
    done
    return 0
}

# wifi_apply — make Network.Wifi the live wifi. Needs conf_load first. Never
# fails the caller: a wifi problem must not stop a receiver on ethernet.
wifi_apply() {
    local ssid psk country hidden dev cur_ssid cur_psk cur_hidden

    ssid=$(conf_get Network.Wifi.SSID "")
    [ -n "$ssid" ] || return 0

    if ! command -v nmcli >/dev/null 2>&1; then
        warn "Network.Wifi is set but nmcli is not installed; leaving the network alone"
        return 0
    fi
    if ! wifi_wait_for_nm; then
        warn "NetworkManager did not come up; not applying Network.Wifi"
        return 0
    fi

    psk=$(conf_get Network.Wifi.Password "")
    country=$(conf_get Network.Wifi.Country "")
    hidden=no
    conf_bool Network.Wifi.Hidden false && hidden=yes

    # The radio stays soft-blocked until a regulatory domain is set. Imager
    # does that, so only touch it if the card asks.
    if [ -n "$country" ]; then
        if command -v raspi-config >/dev/null 2>&1; then
            raspi-config nonint do_wifi_country "$country" >/dev/null 2>&1 \
                || warn "could not set the wifi country to '$country'"
        fi
    fi
    rfkill unblock wifi 2>/dev/null || true

    dev=$(wifi_device)
    if [ -z "$dev" ]; then
        warn "Network.Wifi is set but this Pi has no wifi interface"
        return 0
    fi

    # Already correct? Touch nothing: with the overlay off the connection
    # persists, and rewriting it every boot is a pointless write to the card.
    cur_ssid=$(nmcli -t -g 802-11-wireless.ssid connection show "$WIFI_CONN" 2>/dev/null || true)
    cur_psk=$(nmcli -t -s -g 802-11-wireless-security.psk connection show "$WIFI_CONN" 2>/dev/null || true)
    cur_hidden=$(nmcli -t -g 802-11-wireless.hidden connection show "$WIFI_CONN" 2>/dev/null || true)
    if [ "$cur_ssid" = "$ssid" ] && [ "$cur_psk" = "$psk" ] && [ "$cur_hidden" = "$hidden" ]; then
        return 0
    fi

    log "applying Network.Wifi from the card: SSID '$ssid' on $dev"
    nmcli connection delete "$WIFI_CONN" >/dev/null 2>&1 || true

    # Outrank whatever Imager left behind rather than hunting it down: under
    # the overlay that connection comes back at every boot anyway.
    if ! nmcli connection add type wifi con-name "$WIFI_CONN" ifname "$dev" \
            ssid "$ssid" \
            connection.autoconnect yes \
            connection.autoconnect-priority 10 \
            802-11-wireless.hidden "$hidden" >/dev/null 2>&1; then
        warn "could not create the $WIFI_CONN connection"
        return 0
    fi

    if [ -n "$psk" ]; then
        if ! nmcli connection modify "$WIFI_CONN" \
                802-11-wireless-security.key-mgmt wpa-psk \
                802-11-wireless-security.psk "$psk" >/dev/null 2>&1; then
            warn "could not set the wifi password"
            return 0
        fi
    fi

    nmcli connection up "$WIFI_CONN" >/dev/null 2>&1 \
        || warn "wifi has not associated yet; NetworkManager will keep trying"
    return 0
}

# --------------------------------------------------------------------------
# WireGuard from the card
#
# The same argument as the wifi above: a tunnel that exists so you can reach
# an unreachable receiver is no use if fixing it needs you to reach the
# receiver. So Network.WireGuard is applied from the FAT partition at every
# boot, and /etc/wireguard is treated as a rendering of the card rather than
# as configuration in its own right — which it has to be anyway, since under
# the read-only overlay /etc is RAM and forgets itself at every reboot.
#
# The private key is in clear on the card. Say it out loud, in the template
# and in the README, and keep it out of the world-readable copy of
# MyReceiver.conf that the decoder gets.
# --------------------------------------------------------------------------
WG_IFACE="${OGN_WG_IFACE:-wg-ogn}"
WG_DIR="${OGN_WG_DIR:-/etc/wireguard}"
WG_CONF="$WG_DIR/$WG_IFACE.conf"
WG_MOTD="${OGN_WG_MOTD:-/etc/motd.d/40-ogn-wireguard}"
# [s] without a handshake before the endpoint is re-resolved. Longer than the
# 2-minute interval WireGuard itself retries a handshake at, so this only
# fires once WireGuard has given up rather than racing it.
WG_STALE=300

# A WireGuard key is 32 bytes of base64: 43 characters and a '='.
wg_key_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; }

wg_up() { ip link show "$WG_IFACE" >/dev/null 2>&1; }

# wireguard_render — print a wg-quick config from the loaded card settings.
#
# Pure: reads the config, writes stdout, touches nothing. Returns 1, saying
# what is missing, rather than rendering something that cannot work.
wireguard_render() {
    local key addr mtu pub psk endpoint allowed keepalive ok=1

    key=$(conf_get Network.WireGuard.PrivateKey "")
    addr=$(conf_get Network.WireGuard.Address "")
    mtu=$(conf_get Network.WireGuard.MTU 0)
    pub=$(conf_get Network.WireGuard.Peer.PublicKey "")
    psk=$(conf_get Network.WireGuard.Peer.PresharedKey "")
    endpoint=$(conf_get Network.WireGuard.Peer.Endpoint "")
    allowed=$(conf_get Network.WireGuard.Peer.AllowedIPs "")
    keepalive=$(conf_get Network.WireGuard.Peer.PersistentKeepalive 25)

    [ -n "$key" ]      || { warn "Network.WireGuard.PrivateKey is empty"; ok=0; }
    [ -n "$addr" ]     || { warn "Network.WireGuard.Address is empty"; ok=0; }
    [ -n "$pub" ]      || { warn "Network.WireGuard.Peer.PublicKey is empty"; ok=0; }
    [ -n "$endpoint" ] || { warn "Network.WireGuard.Peer.Endpoint is empty"; ok=0; }
    [ -n "$allowed" ]  || { warn "Network.WireGuard.Peer.AllowedIPs is empty"; ok=0; }
    [ "$ok" -eq 1 ] || return 1

    wg_key_ok "$key" || { warn "Network.WireGuard.PrivateKey is not a WireGuard key (44 characters of base64)"; ok=0; }
    wg_key_ok "$pub" || { warn "Network.WireGuard.Peer.PublicKey is not a WireGuard key (44 characters of base64)"; ok=0; }
    if [ -n "$psk" ] && ! wg_key_ok "$psk"; then
        warn "Network.WireGuard.Peer.PresharedKey is not a WireGuard key (44 characters of base64)"; ok=0
    fi
    # The commonest way to get this wrong is to paste the private key into the
    # peer, which otherwise fails silently: the tunnel comes up and no
    # handshake ever completes.
    if [ "$key" = "$pub" ]; then
        warn "Network.WireGuard.Peer.PublicKey is this receiver's own key; it wants the SERVER's public key"; ok=0
    fi
    case "$addr" in
        */*) ;;
        *)   warn "Network.WireGuard.Address ('$addr') has no prefix length; it should look like 10.6.0.7/32"; ok=0 ;;
    esac
    case "$endpoint" in
        *:[0-9]*) ;;
        *)        warn "Network.WireGuard.Peer.Endpoint ('$endpoint') is not host:port"; ok=0 ;;
    esac
    case "$keepalive" in
        ''|*[!0-9]*) warn "Network.WireGuard.Peer.PersistentKeepalive ('$keepalive') is not a number"; ok=0 ;;
    esac
    case "$mtu" in
        ''|*[!0-9]*) warn "Network.WireGuard.MTU ('$mtu') is not a number"; ok=0 ;;
    esac
    [ "$ok" -eq 1 ] || return 1

    printf '# Generated from %s by ogn-bootstrap. Edit the card, not this file:\n' "$BOOT_CONF"
    printf '# this is rewritten from Network.WireGuard at every boot.\n\n'
    printf '[Interface]\n'
    printf 'PrivateKey = %s\n' "$key"
    printf 'Address = %s\n' "$addr"
    [ "$mtu" != "0" ] && printf 'MTU = %s\n' "$mtu"
    printf '\n[Peer]\n'
    printf 'PublicKey = %s\n' "$pub"
    [ -n "$psk" ] && printf 'PresharedKey = %s\n' "$psk"
    printf 'Endpoint = %s\n' "$endpoint"
    printf 'AllowedIPs = %s\n' "$allowed"
    [ "$keepalive" != "0" ] && printf 'PersistentKeepalive = %s\n' "$keepalive"
    return 0
}

# conf_redact_secrets <file> — blank every credential in a copy of the config.
#
# The copy of MyReceiver.conf the decoder runs from is world-readable, and the
# decoder has no use for any of these: the wifi password, a Raspberry Pi
# Connect auth key, or the WireGuard keys. The card keeps the only copy that
# needs them. Written through a temp file rather than `sed -i` so the target
# keeps the ownership and mode it was installed with.
#
# Named by key, not by path, because the flattener is not available here and a
# copy of this file is the one place a name collision could not do harm: every
# one of these names appears exactly once in the template, and blanking one
# line too many would only cost the decoder something it does not read.
OGN_SECRET_KEYS="Password ConnectAuthKey PrivateKey PresharedKey"
conf_redact_secrets() {
    local file="$1" tmp key args=() note="blanked by ogn-bootstrap: it is on the card"
    tmp=$(mktemp) || return 1
    for key in $OGN_SECRET_KEYS; do
        args+=(-e "s|^\\( *$key *= *\\)\"[^\"]*\"|\\1\"\";   # $note|")
    done
    sed "${args[@]}" "$file" > "$tmp" && cat "$tmp" > "$file" \
        || warn "could not blank the credentials in $file; it still holds them"
    rm -f "$tmp"
    return 0
}

# wireguard_down — take the tunnel down and forget it.
wireguard_down() {
    if wg_up; then
        log "taking the WireGuard tunnel $WG_IFACE down"
        if command -v wg-quick >/dev/null 2>&1 && [ -s "$WG_CONF" ]; then
            wg-quick down "$WG_IFACE" >/dev/null 2>&1 || ip link delete "$WG_IFACE" 2>/dev/null || true
        else
            ip link delete "$WG_IFACE" 2>/dev/null || true
        fi
    fi
    rm -f "$WG_CONF" "$WG_MOTD"
    return 0
}

# wireguard_refresh — re-resolve the endpoint if the handshake has stopped.
#
# WireGuard resolves Endpoint once, when the peer is configured, and never
# again. A server on a dynamic address therefore takes the tunnel with it when
# it moves — silently, and precisely when the tunnel is the only way in. One
# `wg set` re-resolves the name without disturbing the interface, its routes,
# or anything already running over it.
wireguard_refresh() {
    local pub endpoint last age
    endpoint=$(conf_get Network.WireGuard.Peer.Endpoint "")
    pub=$(conf_get Network.WireGuard.Peer.PublicKey "")
    # A literal address cannot have moved, so there is nothing to re-resolve.
    case "$endpoint" in ''|\[*) return 0 ;; [0-9]*.[0-9]*.[0-9]*.[0-9]*:*) return 0 ;; esac

    last=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk -v p="$pub" '$1 == p { print $2; exit }')
    case "$last" in ''|*[!0-9]*) return 0 ;; esac
    age=$(( $(date +%s) - last ))
    [ "$age" -ge "$WG_STALE" ] || return 0

    if [ "$last" -eq 0 ]; then
        log "WireGuard has never completed a handshake; re-resolving $endpoint"
    else
        log "no WireGuard handshake for ${age}s; re-resolving $endpoint"
    fi
    wg set "$WG_IFACE" peer "$pub" endpoint "$endpoint" 2>/dev/null \
        || warn "could not re-resolve the WireGuard endpoint '$endpoint'"
    return 0
}

WG_MOTD_TEMPLATE='
  WireGuard:   %s on %s, through %s
               Is it talking?  sudo ogn-wireguard status

'
wireguard_motd_update() {
    local tmp
    mkdir -p "$(dirname "$WG_MOTD")" 2>/dev/null || return 0
    tmp=$(mktemp) || return 0
    # shellcheck disable=SC2059
    printf "$WG_MOTD_TEMPLATE" \
        "$(conf_get Network.WireGuard.Address "")" "$WG_IFACE" \
        "$(conf_get Network.WireGuard.Peer.Endpoint "")" > "$tmp"
    cmp -s "$tmp" "$WG_MOTD" || install -m 0644 "$tmp" "$WG_MOTD" 2>/dev/null || true
    rm -f "$tmp"
    return 0
}

# wireguard_apply — make Network.WireGuard the live tunnel. Needs conf_load
# first. Returns 1 only when a tunnel was asked for and could not be provided,
# so that the unit holding this reports a failure someone can see.
wireguard_apply() {
    local tmp out

    if ! conf_bool Network.WireGuard.Enable false; then
        wireguard_down
        return 0
    fi

    if ! command -v wg-quick >/dev/null 2>&1; then
        warn "Network.WireGuard is enabled but wireguard-tools is not installed"
        return 1
    fi

    tmp=$(mktemp)
    if ! wireguard_render > "$tmp"; then
        rm -f "$tmp"
        warn "WireGuard is enabled but not usably configured; leaving the network alone"
        return 1
    fi

    # Unchanged and already up: nothing to do but check it is still talking.
    if cmp -s "$tmp" "$WG_CONF" && wg_up; then
        rm -f "$tmp"
        wireguard_refresh
        return 0
    fi

    install -d -m 0700 "$WG_DIR"
    install -m 0600 "$tmp" "$WG_CONF"
    rm -f "$tmp"

    # wg-quick installs a kill-switch rule for a default route through the
    # tunnel, and needs a firewall command to do it. Saying so here turns an
    # obscure failure two lines down into an explicable one.
    case "$(conf_get Network.WireGuard.Peer.AllowedIPs "")" in
        *0.0.0.0/0*|*::/0*)
            command -v nft >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1 \
                || warn "AllowedIPs routes everything through the tunnel, which needs nftables or iptables on this Pi" ;;
    esac

    log "bringing up the WireGuard tunnel $WG_IFACE"
    wg-quick down "$WG_IFACE" >/dev/null 2>&1 || true
    if ! out=$(wg-quick up "$WG_IFACE" 2>&1); then
        printf '%s\n' "$out" | sed 's/^/  /' >&2
        warn "could not bring up the WireGuard tunnel $WG_IFACE"
        return 1
    fi
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  /'
    wireguard_motd_update
    return 0
}

# --------------------------------------------------------------------------
# ADS-B from the card
#
# The same argument as WireGuard above: /etc/default/readsb is a rendering of
# ADSB.* rather than configuration in its own right. Under the read-only
# overlay /etc is RAM and forgets itself at every reboot, so it has to be.
#
# Nothing here writes to the card, and nothing anywhere writes continuously:
# readsb is started with no --write-json, because this image ships no map and
# a JSON directory rewritten every second is precisely the wear the overlay
# exists to prevent. The multilateration clients keep their settings in /run
# for the same reason.
# --------------------------------------------------------------------------
ADSB_DEFAULT="${OGN_ADSB_DEFAULT:-/etc/default/readsb}"
ADSB_MLAT_DIR="${OGN_ADSB_MLAT_DIR:-/run/ogn-bootstrap/mlat}"
ADSB_MOTD="${OGN_ADSB_MOTD:-/etc/motd.d/50-ogn-adsb}"

# readsb's own port conventions, and the ones every ADS-B instruction written
# for a Pi assumes: raw AVR out, Beast out, and Beast in for MLAT results.
ADSB_AVR_PORT=30002
ADSB_BEAST_PORT=30005
ADSB_MLAT_IN_PORT=30104

# The sites this receiver knows how to feed, and the only ones a tick box can
# reach. Kept here rather than on the card so that a hostname cannot be
# mistyped into a receiver nobody can get back to, and so that what a given
# setting sends, and to whom, can be read in one place.
#
# All four take Beast on 30004 and multilateration on 31090.
ADSB_FEEDS="ADSBExchange ADSBFi ADSBLol AirplanesLive"
ADSB_FEED_PORT=30004
ADSB_MLAT_PORT=31090

adsb_feed_host() {
    case "$1" in
        ADSBExchange)  printf 'feed.adsbexchange.com' ;;
        ADSBFi)        printf 'feed.adsb.fi' ;;
        ADSBLol)       printf 'feed.adsb.lol' ;;
        AirplanesLive) printf 'feed.airplanes.live' ;;
        *)             return 1 ;;
    esac
}

# systemd instance names, so it reads ogn-mlat@adsbfi rather than @ADSBFi.
adsb_feed_instance() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# The feeds switched on, one per line. Needs conf_load first.
adsb_enabled_feeds() {
    local f
    for f in $ADSB_FEEDS; do
        conf_bool "ADSB.Feed.$f" false && printf '%s\n' "$f"
    done
    return 0
}

# A number, possibly negative, possibly with a decimal point. readsb's -10
# means "let the tuner decide", so a bare - is not enough to reject on.
adsb_number_ok() { printf '%s' "$1" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'; }

# adsb_render — print /etc/default/readsb from the loaded card settings.
#
# Pure: reads the config, writes stdout, touches nothing. Returns 1, saying
# what is wrong, rather than rendering something that cannot work.
adsb_render() {
    local serial ogn_serial gain custom entry host f conn="" feeds="" ok=1

    serial=$(conf_get ADSB.DeviceSerial "")
    ogn_serial=$(conf_get RF.DeviceSerial "")
    gain=$(conf_get ADSB.Gain -10)
    custom=$(conf_get ADSB.Feed.Custom "")

    [ -n "$serial" ] || {
        warn "ADSB.DeviceSerial is empty; it wants the serial of the 1090 MHz stick"; ok=0; }

    # Two dongles and only one of them named is the trap this whole section is
    # built around: RF.Device is an index, indexes are handed out in USB
    # enumeration order, and so the OGN decoder can open the ADS-B stick and
    # hear nothing for reasons nothing reports.
    if [ -z "$ogn_serial" ]; then
        warn "ADS-B needs RF.DeviceSerial set as well, so the OGN decoder cannot open the ADS-B stick by accident"
        ok=0
    elif [ "$serial" = "$ogn_serial" ]; then
        warn "ADSB.DeviceSerial and RF.DeviceSerial are both '$serial'; one stick cannot do 868 and 1090 at once"
        ok=0
    fi

    adsb_number_ok "$gain" || { warn "ADSB.Gain ('$gain') is not a number"; ok=0; }

    # Multilateration works by comparing arrival times between receivers, so a
    # receiver that is not where it says it is makes everyone else's answers
    # worse. Refuse rather than quietly feed a template default.
    if conf_bool ADSB.Feed.MLAT false; then
        local lat lon
        lat=$(conf_get Position.Latitude 0)
        lon=$(conf_get Position.Longitude 0)
        if awk "BEGIN{exit !($lat == 0 && $lon == 0)}" 2>/dev/null; then
            warn "ADSB.Feed.MLAT needs a real Position; it is still 0,0"
            ok=0
        elif awk "BEGIN{exit !($lat < -90 || $lat > 90 || $lon < -180 || $lon > 180)}" 2>/dev/null; then
            warn "ADSB.Feed.MLAT needs a real Position; $lat,$lon is out of range"
            ok=0
        fi
        [ -n "$(adsb_enabled_feeds)" ] || {
            warn "ADSB.Feed.MLAT is on but no site is switched on to send it to"; ok=0; }
    fi

    for f in $(adsb_enabled_feeds); do
        host=$(adsb_feed_host "$f") || continue
        conn="$conn --net-connector $host,$ADSB_FEED_PORT,beast_reduce_plus_out"
        feeds="$feeds $f"
    done

    # Custom is a comma-separated scalar rather than a libconfig array,
    # because the flattener keeps an array as one opaque bracketed string and
    # conf_get has no way to take it apart.
    local IFS_SAVE="$IFS"
    IFS=','
    for entry in $custom; do
        IFS="$IFS_SAVE"
        entry=$(printf '%s' "$entry" | tr -d '[:space:]')
        [ -n "$entry" ] || continue
        case "$entry" in
            *:[0-9]*) conn="$conn --net-connector ${entry%:*},${entry##*:},beast_reduce_plus_out" ;;
            *)        warn "ADSB.Feed.Custom entry '$entry' is not host:port"; ok=0 ;;
        esac
        IFS=','
    done
    IFS="$IFS_SAVE"

    [ "$ok" -eq 1 ] || return 1

    printf '# Generated from %s by ogn-bootstrap. Edit the card, not this file:\n' "$BOOT_CONF"
    printf '# this is rewritten from ADSB at every boot.\n'
    printf '#\n'
    if [ -n "$feeds" ]; then
        printf '# Sharing with:%s\n' "$feeds"
    else
        printf '# Not shared with anyone: the OGN decoder reads it on %s and that is all.\n' "$ADSB_AVR_PORT"
    fi
    printf '\n'
    printf 'RECEIVER_OPTIONS="--device %s --device-type rtlsdr --gain %s --ppm 0"\n' "$serial" "$gain"
    printf 'DECODER_OPTIONS="--max-range 360"\n'
    printf 'NET_OPTIONS="--net --net-heartbeat 60 --net-ro-port %s --net-bo-port %s --net-bi-port %s%s"\n' \
        "$ADSB_AVR_PORT" "$ADSB_BEAST_PORT" "$ADSB_MLAT_IN_PORT" "$conn"
    # Deliberately empty. A map would want --write-json; this image ships none,
    # and the directory would be rewritten every second for nobody to read.
    printf 'JSON_OPTIONS=""\n'
    return 0
}

# adsb_mlat_render <feed> — print the environment for one ogn-mlat@ instance.
#
# Pure, as above. mlat-client reads Beast from readsb and sends its answers
# back in on ADSB_MLAT_IN_PORT, so multilaterated aircraft reach OGN too.
adsb_mlat_render() {
    local feed="$1" host call
    host=$(adsb_feed_host "$feed") || { warn "no multilateration server known for '$feed'"; return 1; }
    call=$(conf_get APRS.Call "")
    [ -n "$call" ] || { warn "APRS.Call is empty; multilateration servers want a station name"; return 1; }

    printf 'MLAT_SERVER=%s:%s\n' "$host" "$ADSB_MLAT_PORT"
    printf 'MLAT_LAT=%s\n'   "$(conf_get Position.Latitude 0)"
    printf 'MLAT_LON=%s\n'   "$(conf_get Position.Longitude 0)"
    printf 'MLAT_ALT=%s\n'   "$(conf_get Position.Altitude 0)"
    printf 'MLAT_CALL=%s\n'  "$call"
    printf 'MLAT_INPUT=localhost:%s\n'   "$ADSB_BEAST_PORT"
    printf 'MLAT_RESULTS=beast,connect,localhost:%s\n' "$ADSB_MLAT_IN_PORT"
    return 0
}

# adsb_down — stop decoding, stop feeding, and forget how.
adsb_down() {
    local f inst
    if systemctl is-enabled --quiet readsb 2>/dev/null || systemctl is-active --quiet readsb 2>/dev/null; then
        log "switching ADS-B off"
        systemctl disable --now readsb >/dev/null 2>&1 || true
    fi
    for f in $ADSB_FEEDS; do
        inst=$(adsb_feed_instance "$f")
        systemctl is-enabled --quiet "ogn-mlat@$inst.service" 2>/dev/null \
            && systemctl disable --now "ogn-mlat@$inst.service" >/dev/null 2>&1 || true
        rm -f "$ADSB_MLAT_DIR/$inst.env"
    done
    rm -f "$ADSB_DEFAULT" "$ADSB_MOTD"
    return 0
}

# adsb_mlat_apply — one mlat-client per site that is switched on, and none
# for any that is not. Returns 1 if a wanted one could not be configured.
adsb_mlat_apply() {
    local f inst tmp on=0 rc=0
    conf_bool ADSB.Feed.MLAT false && on=1
    [ "$on" -eq 1 ] && install -d -m 0755 "$ADSB_MLAT_DIR" 2>/dev/null

    for f in $ADSB_FEEDS; do
        inst=$(adsb_feed_instance "$f")
        if [ "$on" -eq 1 ] && conf_bool "ADSB.Feed.$f" false; then
            tmp=$(mktemp) || return 1
            if ! adsb_mlat_render "$f" > "$tmp"; then
                rm -f "$tmp"; rc=1; continue
            fi
            if ! cmp -s "$tmp" "$ADSB_MLAT_DIR/$inst.env"; then
                install -m 0644 "$tmp" "$ADSB_MLAT_DIR/$inst.env"
                systemctl restart "ogn-mlat@$inst.service" >/dev/null 2>&1 || true
            fi
            rm -f "$tmp"
            systemctl is-enabled --quiet "ogn-mlat@$inst.service" 2>/dev/null \
                || systemctl enable --now "ogn-mlat@$inst.service" >/dev/null 2>&1 || true
        else
            systemctl is-enabled --quiet "ogn-mlat@$inst.service" 2>/dev/null \
                && systemctl disable --now "ogn-mlat@$inst.service" >/dev/null 2>&1 || true
            rm -f "$ADSB_MLAT_DIR/$inst.env"
        fi
    done
    return $rc
}

# What this receiver is sharing with, in a form fit for a one-line summary.
adsb_feed_summary() {
    local f out=""
    for f in $(adsb_enabled_feeds); do
        out="$out, $(adsb_feed_host "$f")"
    done
    if [ -z "$out" ]; then printf 'OGN only'; else printf 'OGN%s' "$out"; fi
}

ADSB_MOTD_TEMPLATE='
  ADS-B:       readsb on stick %s, feeding %s
               Is it hearing anything?  sudo ogn-adsb status

'
adsb_motd_update() {
    local tmp
    mkdir -p "$(dirname "$ADSB_MOTD")" 2>/dev/null || return 0
    tmp=$(mktemp) || return 0
    # shellcheck disable=SC2059
    printf "$ADSB_MOTD_TEMPLATE" \
        "$(conf_get ADSB.DeviceSerial '?')" "$(adsb_feed_summary)" > "$tmp"
    cmp -s "$tmp" "$ADSB_MOTD" || install -m 0644 "$tmp" "$ADSB_MOTD" 2>/dev/null || true
    rm -f "$tmp"
    return 0
}

# adsb_apply — make ADSB the live state. Needs conf_load first. Returns 1
# only when ADS-B was asked for and could not be provided, so that the unit
# holding this reports a failure someone can see.
adsb_apply() {
    local tmp changed=0

    if ! conf_bool ADSB.Enable false; then
        adsb_down
        return 0
    fi

    if ! command -v readsb >/dev/null 2>&1; then
        warn "ADSB.Enable is true but readsb is not installed"
        return 1
    fi

    tmp=$(mktemp)
    if ! adsb_render > "$tmp"; then
        rm -f "$tmp"
        warn "ADS-B is enabled but not usably configured; leaving the receiver alone"
        return 1
    fi

    if cmp -s "$tmp" "$ADSB_DEFAULT" && systemctl is-active --quiet readsb 2>/dev/null; then
        rm -f "$tmp"
    else
        install -d -m 0755 "$(dirname "$ADSB_DEFAULT")"
        install -m 0644 "$tmp" "$ADSB_DEFAULT"
        rm -f "$tmp"
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        log "starting readsb on the ADS-B stick"
        systemctl enable readsb >/dev/null 2>&1 || true
        if ! systemctl restart readsb >/dev/null 2>&1; then
            warn "readsb would not start; see journalctl -u readsb"
            return 1
        fi
    fi

    adsb_mlat_apply || { adsb_motd_update; return 1; }
    adsb_motd_update
    return 0
}

# --------------------------------------------------------------------------
# MOTD
# --------------------------------------------------------------------------
motd_set() {
    mkdir -p "$(dirname "$MOTD_FILE")"
    cat > "$MOTD_FILE"
}
