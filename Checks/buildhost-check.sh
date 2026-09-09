#!/bin/sh
# BuildHost link check — the one check that compiles the package the way an app does.
# The other ten build a hand-picked slice of `Sources/` against hand-written stubs in
# `Checks/Stubs/`, so all ten stay green while `IntegrationKit.swift` — the public
# composition root nobody else compiles — is broken. BuildHost is a small Xcode project
# that links the whole package against the real SDKs; if the public API stops compiling,
# this is what says so.
#
# Once a project exists, `xcb` maps the failure onto its exit code itself: it exits
# non-zero unless xcodebuild both returned 0 and printed `** BUILD SUCCEEDED **`.
set -e
cd "$(dirname "$0")/.."

# `BuildHost/BuildHost.xcodeproj/` is generated from `project.yml` and is in `.gitignore`,
# so a fresh clone or a new worktree has none. With no project to build, `xcb` prints
# "не знайдено .xcworkspace/.xcodeproj" and still **exits 0** — this check would report
# green having compiled nothing, which is the exact hole it was written to close. So:
# regenerate first, then refuse to run at all if the project still is not there. Doing it
# unconditionally also settles the "did you re-run xcodegen?" question after a
# `project.yml` edit.
if command -v xcodegen >/dev/null 2>&1; then
	(cd BuildHost && xcodegen generate >/dev/null)
fi
if [ ! -d BuildHost/BuildHost.xcodeproj ]; then
	echo "buildhost-check: BuildHost/BuildHost.xcodeproj is missing and could not be generated."
	echo "buildhost-check: install xcodegen (brew install xcodegen), then run this again."
	echo "buildhost-check: refusing to pass — nothing was compiled."
	exit 1
fi

exec xcb app-sim --path BuildHost
