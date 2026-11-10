#!/bin/bash
# Voice Note Transcriber installer
#
#   ./install.sh               test, build, install to /Applications and open
#   ./install.sh --build-only  test and build ./build/Voice Note Transcriber.app without installing
#   ./install.sh --skip-tests  skip the unit tests (combines with the above)
#   ./install.sh --uninstall   remove the app, and optionally your saved API key and settings
#
# Needs macOS 26 or later and Swift 6.2 or later (Xcode 26, or its Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Voice Note Transcriber"
EXECUTABLE="VoiceNoteTranscriber"
BUNDLE_ID="local.voicenotetranscriber"
BUILT_APP="build/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
KEYCHAIN_SERVICE="VoiceNoteTranscriber"
KEYCHAIN_ACCOUNT="openai-api-key"

if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; X=$'\033[0m'; else B=; G=; R=; Y=; D=; X=; fi
step() { printf "\n${B}▸ %s${X}\n" "$1"; }
ok()   { printf "  ${G}✓${X} %s\n" "$1"; }
warn() { printf "  ${Y}!${X} %s\n" "$1"; }
die()  { printf "\n  ${R}✗ %s${X}\n" "$1" >&2; shift; for line in "$@"; do printf "    %s\n" "$line" >&2; done; exit 1; }
ask()  { local reply; printf "  %s [y/N] " "$1"; read -r reply </dev/tty || reply=""; [[ "$reply" =~ ^[Yy] ]]; }

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }

MODE="install"; SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --build-only) MODE="build" ;;
    --uninstall)  MODE="uninstall" ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "Unknown option: $arg" "Run ./install.sh --help" ;;
  esac
done

# Runs a command in the background with a spinner; output goes to a log.
spin() {
  local label="$1" log="$2"; shift 2
  "$@" >"$log" 2>&1 &
  local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -t 1 ]]; then printf "\r  ${D}%s${X} %s" "${frames:i++%10:1}" "$label"; fi
    sleep 0.1
  done
  [[ -t 1 ]] && printf "\r\033[K"
  wait "$pid"
}

is_running() { pgrep -f "$INSTALLED_APP/Contents/MacOS/$EXECUTABLE" >/dev/null 2>&1; }
has_saved_key() { security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; }

# Asks the running app to quit (it may be partway through a transcription), then waits for it.
quit_app() {
  is_running || return 0
  warn "$APP_NAME is open. Quitting it stops any transcription in progress."
  ask "Quit it and continue?" || die "Nothing was changed." "Quit $APP_NAME when it's finished, then run ./install.sh again."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..50}; do is_running || return 0; sleep 0.2; done
  die "$APP_NAME didn't quit." "Quit it yourself, then run ./install.sh again."
}

# ── Uninstall ────────────────────────────────────────────────────────────────
uninstall() {
  printf "${B}Uninstall $APP_NAME${X}\n"
  [[ -d "$INSTALLED_APP" ]] || die "$APP_NAME isn’t installed in /Applications."
  echo "  This removes the app. Your saved notes are kept."
  ask "Continue?" || { echo "  Cancelled."; exit 0; }
  quit_app

  step "Removing the app"
  rm -rf "$INSTALLED_APP"
  ok "Deleted $INSTALLED_APP"
  if has_saved_key && ask "Also delete your OpenAI API key from the Keychain?"; then
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null && ok "Deleted the API key"
  fi
  if defaults read "$BUNDLE_ID" >/dev/null 2>&1 && ask "Also reset its settings (notes folder, format, model and prompt)?"; then
    defaults delete "$BUNDLE_ID" && ok "Reset settings"
  fi
  printf "\n${G}${B}$APP_NAME has been removed.${X}\n"
}

# ── Requirements ─────────────────────────────────────────────────────────────
check_requirements() {
  step "Checking your Mac"
  local macos; macos="$(sw_vers -productVersion)"
  [[ "${macos%%.*}" -ge 26 ]] || die "$APP_NAME needs macOS 26 or later (you have $macos)."
  ok "macOS $macos"

  xcode-select -p >/dev/null 2>&1 || die "Swift is required (it’s free)." \
    "Install Xcode from the App Store, or just the command-line tools with: xcode-select --install"
  local version major minor
  version="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
  [[ -n "$version" ]] || die "Couldn’t run Swift." "Open Xcode once to finish its setup, then run ./install.sh again."
  IFS=. read -r major minor <<<"$version"
  (( major > 6 || (major == 6 && minor >= 2) )) || die "Swift 6.2 or later is required (you have $version)." \
    "Update Xcode, or the command-line tools, from Software Update."
  ok "Swift $version"
}

# ── Build ────────────────────────────────────────────────────────────────────
build() {
  mkdir -p build
  if [[ "$SKIP_TESTS" -eq 0 ]]; then
    step "Running tests"
    spin "Running unit tests (the first run compiles everything, so it takes a minute or two)" build/test.log swift test ||
      die "Tests failed." "See build/test.log"
    ok "$(grep -Eo 'Test run with [0-9]+ tests?' build/test.log | tail -1 | sed 's/Test run with //') passed"
  fi

  step "Building $APP_NAME"
  spin "Compiling a release build" build/build.log swift build -c release --product "$EXECUTABLE" ||
    die "The build failed." "See build/build.log"
  local bin; bin="$(swift build -c release --show-bin-path)/$EXECUTABLE"
  ok "Compiled"

  # The icon is drawn by a script, then converted to .icns once.
  if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
    rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
    swift scripts/make-icon.swift build/icon-1024.png
    for px in 16 32 128 256 512; do
      sips -z $px $px build/icon-1024.png --out "build/AppIcon.iconset/icon_${px}x${px}.png" >/dev/null
      sips -z $((px * 2)) $((px * 2)) build/icon-1024.png --out "build/AppIcon.iconset/icon_${px}x${px}@2x.png" >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  fi

  rm -rf "$BUILT_APP"
  mkdir -p "$BUILT_APP/Contents/MacOS" "$BUILT_APP/Contents/Resources"
  cp "$bin" "$BUILT_APP/Contents/MacOS/$EXECUTABLE"
  cp Resources/Info.plist "$BUILT_APP/Contents/Info.plist"
  cp build/AppIcon.icns "$BUILT_APP/Contents/Resources/AppIcon.icns"
  # An ad-hoc signature is all a locally built app needs on your own Mac.
  codesign --force --sign - "$BUILT_APP" >/dev/null 2>&1 || die "Couldn’t sign the app."
  codesign --verify --strict "$BUILT_APP" || die "The app’s signature didn’t verify."
  ok "Built $BUILT_APP"
}

# ── Install ──────────────────────────────────────────────────────────────────
install_app() {
  step "Installing"
  quit_app
  rm -rf "$INSTALLED_APP"
  cp -R "$BUILT_APP" /Applications/
  ok "Installed $INSTALLED_APP"
  open "$INSTALLED_APP"

  printf "\n${G}${B}$APP_NAME is ready.${X}\n"
  if has_saved_key; then
    echo "  If macOS asks whether it can use its Keychain item, choose Always Allow."
    echo "  (It asks once after each rebuild, because each local build has a new signature.)"
  else
    echo "  Next: open Settings (⌘,) and paste your OpenAI API key."
    echo "  Get one at https://platform.openai.com/api-keys"
  fi
}

case "$MODE" in
  uninstall) uninstall ;;
  build)     check_requirements; build; printf "\n${G}${B}Built %s${X}\n" "$BUILT_APP" ;;
  install)   check_requirements; build; install_app ;;
esac
