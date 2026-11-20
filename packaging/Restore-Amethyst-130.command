#!/bin/bash
set -euo pipefail

test_dir="$HOME/Applications/Amethyst Test 130"
official="$test_dir/Amethyst.app"
installed=/Applications/Amethyst.app
archive_url=https://github.com/ianyh/Amethyst/releases/download/v0.25.0/Amethyst.zip
archive_sha=cbdcab38c14e5b1cb359537faf0f274b7d77aeb2d3cfef1982866e2084880437

fail() { printf '%s\n' "$*" >&2; exit 1; }

verify_official() {
    local plist="$1/Contents/Info.plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")" == 130 ]] ||
        fail "Expected build 130 at $1. An existing copy will be kept."
    /usr/bin/codesign --verify --deep --strict "$1"
    /usr/bin/codesign --verify -R='anchor apple generic and identifier "com.amethyst.Amethyst" and certificate leaf[subject.OU] = "82P2XLB4UH"' "$1"
}

[[ ! -L "$official" ]] || fail "The test copy at $official is a symbolic link."
if [[ ! -e "$official" ]]; then
    /bin/mkdir -p "$test_dir"
    stage=$(/usr/bin/mktemp -d "$test_dir/.restore.XXXXXXXX")
    trap '/bin/rm -rf "$stage"' EXIT
    echo "Downloading official Amethyst 0.25.0 (130)..."
    /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' --retry 2 \
        --output "$stage/Amethyst.zip" "$archive_url"
    (cd "$stage" && printf '%s  Amethyst.zip\n' "$archive_sha" | /usr/bin/shasum -a 256 -c -)
    /usr/bin/ditto -x -k "$stage/Amethyst.zip" "$stage/unpacked"
    verify_official "$stage/unpacked/Amethyst.app"
    /bin/mv -n "$stage/unpacked/Amethyst.app" "$test_dir/"
fi
verify_official "$official"

# The preview and the official release may have different bundle IDs.
app_state() {
    /usr/bin/osascript -l JavaScript - "$1" "$installed" "$official" <<'JXA'
ObjC.import('AppKit');
function run(args) {
    const path = url => ObjC.unwrap(url.URLByResolvingSymlinksInPath.path);
    const installed = path($.NSURL.fileURLWithPath(args[1]));
    const official = path($.NSURL.fileURLWithPath(args[2]));
    const toQuit = [];
    let officialRunning = false;
    for (const id of ['com.amethyst.Amethyst', 'com.github.nevs55.AmethystPreview']) {
        const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(id);
        for (let i = 0; i < apps.count; i++) {
            const app = apps.objectAtIndex(i);
            const actual = path(app.bundleURL);
            if (actual === official) officialRunning = true;
            else if (actual === installed) toQuit.push(app);
            else throw Error('Quit the other running copy at ' + actual + ' and try again.');
        }
    }
    if (args[0] === 'quit-installed') {
        for (const app of toQuit) {
            if (!app.terminate) throw Error('Quit the installed Amethyst from its menu and try again.');
        }
    }
    if (toQuit.length) return 'quitting';
    return officialRunning ? 'running' : 'stopped';
}
JXA
}

state=$(app_state quit-installed)
for ((i=0; i<60; i++)); do
    [[ "$state" == quitting ]] || break
    /bin/sleep 0.25
    state=$(app_state inspect)
done
[[ "$state" != quitting ]] || fail "Quit the running Amethyst from its menu and run this file again."
if [[ "$state" == stopped ]]; then
    /usr/bin/open "$official"
    for ((i=0; i<60; i++)); do
        state=$(app_state inspect)
        [[ "$state" == running ]] && break
        /bin/sleep 0.25
    done
fi
[[ "$state" == running ]] || fail "Build 130 was restored at $official. macOS has not confirmed that it opened."
echo "Official Amethyst 0.25.0 (130) is running from $official"
