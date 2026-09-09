#!/bin/sh
# BuildHost link check — the one check that compiles the package the way an app does.
# The other ten build a hand-picked slice of `Sources/` against hand-written stubs in
# `Checks/Stubs/`, so all ten stay green while `IntegrationKit.swift` — the public
# composition root nobody else compiles — is broken. BuildHost is a small Xcode project
# that links the whole package against the real SDKs; if the public API stops compiling,
# this is what says so.
#
# `xcb` maps the failure onto its exit code itself: it exits non-zero unless xcodebuild
# both returned 0 and printed `** BUILD SUCCEEDED **`, so `exec` is enough — no log
# parsing here.
set -e
cd "$(dirname "$0")/.."
exec xcb app-sim --path BuildHost
