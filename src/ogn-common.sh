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
MANIFEST_URL="${OGN_MANIFEST_URL:-https://raw.githubusercontent.com/glidernet/ogn-bootstrap/master/versions.json}"
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
        # libconfig takes # and // alike, and the templates in the wild use
        # both. A brace inside a string value would corrupt the depth count,
        # and no such line opens or closes a block anyway.
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
manifest_fetch() {
    local tmp
    if ! mkdir -p "$(dirname "$MANIFEST_CACHE")" 2>/dev/null; then
        # Not root, so we cannot refresh the cache. A read-only check against
        # whatever was last fetched is still useful.
        [ -r "$MANIFEST_CACHE" ] && return 0
        return 1
    fi
    tmp=$(mktemp)
    if fetch "$MANIFEST_URL" "$tmp" && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp"; then
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
# MOTD
# --------------------------------------------------------------------------
motd_set() {
    mkdir -p "$(dirname "$MOTD_FILE")"
    cat > "$MOTD_FILE"
}
