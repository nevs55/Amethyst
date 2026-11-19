#!/bin/bash
set -eu
cd "$(dirname "$0")"
image="Amethyst-preview-132.dmg"
echo "Checking the Amethyst 0.25.0 (132) disk image..."
printf '%s  %s\n' '5937371d33b56ae755fadbe2864898ec79e8ff8a8682e1c7a63b59cd5b90c867' "$image" | /usr/bin/shasum -a 256 -c -
mountpoint=$(/usr/bin/mktemp -d)
mounted=false
cleanup() {
    if "$mounted"; then
        /usr/sbin/diskutil eject "$mountpoint" >/dev/null || return
    fi
    /bin/rmdir "$mountpoint"
}
trap cleanup EXIT

usage=$(/usr/sbin/diskutil image attach 2>&1 || true)
case "$usage" in
    *--mountPoint*)
        /usr/sbin/diskutil image attach --readOnly --mountOptions nobrowse --mountPoint "$mountpoint" "$image" ;;
    *-mountPoint*)
        /usr/sbin/diskutil image attach -readOnly -mountOptions nobrowse -mountPoint "$mountpoint" "$image" ;;
    *)
        /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$image" ;;
esac
mounted=true
app="$mountpoint/Amethyst.app"
/usr/bin/codesign --verify --deep --strict "$app"
installed=/Applications/Amethyst.app
build_number() {
    /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$1/Contents/Info.plist"
}
verify_preview() {
    [[ "$(build_number "$1")" == 132 ]] &&
        /usr/bin/codesign --verify --deep --strict "$1" &&
        /usr/bin/cmp -s "$app/Contents/MacOS/Amethyst" "$1/Contents/MacOS/Amethyst"
}
verify_preview "$app" || { echo "The mounted app is not the expected build 132."; exit 1; }
if [[ -L "$installed" ]]; then
    echo "$installed is a symbolic link. Install using the tool that manages it."
    exit 1
fi
if [[ -e "$installed" ]]; then
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$installed/Contents/Info.plist")
    [[ "$bundle_id" == com.amethyst.Amethyst ]] || { echo "Unexpected app at $installed"; exit 1; }
    echo "Current installed build: $(build_number "$installed")"
fi

if ! verify_preview "$installed" 2>/dev/null; then
    install_cmd=()
    if [[ ! -w /Applications ]]; then
        echo "Administrator permission is needed to write to /Applications."
        install_cmd=(/usr/bin/sudo)
    fi
    # Bash 3.2 with nounset treats an empty array as unbound.
    install_action() { ${install_cmd[@]+"${install_cmd[@]}"} "$@"; }
    stage=$(install_action /usr/bin/mktemp -d /Applications/.Amethyst-upgrade.XXXXXXXX)
    if [[ ! -r "$stage" ]]; then
        install_action /usr/sbin/chown "$(/usr/bin/id -u)" "$stage"
    fi
    previous="$stage/Previous.app"
    pending="$stage/New.app"
    rollback=false
    finish() {
        status=$?
        if "$rollback"; then
            if [[ -e "$installed" ]]; then
                install_action /bin/mv "$installed" "$stage/Unverified.app" || { echo "Previous app is at $previous"; exit 1; }
            fi
            if [[ -e "$previous" ]]; then
                install_action /bin/mv "$previous" "$installed" || { echo "Previous app is at $previous"; exit 1; }
            fi
        fi
        cleanup || true
        exit "$status"
    }
    trap finish EXIT
    /usr/bin/ditto "$app" "$pending"
    verify_preview "$pending" || { echo "Verification failed before replacement."; exit 1; }
    if /usr/bin/pgrep -x Amethyst >/dev/null; then
        /usr/bin/osascript -e 'tell application id "com.amethyst.Amethyst" to quit'
        for ((attempt=0; attempt<100; attempt++)); do
            /usr/bin/pgrep -x Amethyst >/dev/null || break
            /bin/sleep 0.1
        done
        if /usr/bin/pgrep -x Amethyst >/dev/null; then
            echo "Quit Amethyst, then run this updater again."
            exit 1
        fi
    fi
    if [[ -e "$installed" ]]; then
        install_action /bin/mv "$installed" "$previous"
    fi
    rollback=true
    install_action /bin/mv "$pending" "$installed"
    verify_preview "$installed" || { echo "Installed copy failed verification; restoring the previous app."; exit 1; }
    rollback=false
    if [[ -d "$previous" ]]; then
        echo "Previous app saved at $previous"
    else
        install_action /bin/rmdir "$stage"
    fi
fi
echo "Installed Amethyst build $(build_number "$installed"). Opening the app..."
/usr/bin/open "$installed"
echo "Window diagnostic for Codex, Discord, and Claude (titles redacted):"
set -o pipefail
"$installed/Contents/MacOS/Amethyst" debug windows --redact-window-titles |
    /usr/bin/awk '
        /^Accessibility access for this diagnostic:/ { print; next }
        /^[^[:space:]].* \(pid / { show = tolower($0) ~ /codex|discord|claude/; if (show) found = 1 }
        show { print }
        END { if (!found) print "No matching app entries in this diagnostic." }
    '
