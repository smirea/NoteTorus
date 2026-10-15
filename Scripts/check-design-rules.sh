#!/bin/sh
set -eu

project_root="${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
cd "$project_root"

for pattern in 'RoundedRectangle' 'ContainerRelativeShape' 'GroupBox' 'AppCard' 'AppStyle\.card' 'cardBorder'; do
	matches=$(/usr/bin/grep -R -n -E --include='*.swift' "$pattern" Sources/App Shared NotouroborosWidgets || true)
	if [ -n "$matches" ]; then
		echo "error: NO CARDS design rule violation: $pattern"
		echo "$matches"
		exit 1
	fi
done

backgrounds=$(/usr/bin/grep -R -n -E --include='*.swift' '\.background\(' Sources/App Shared NotouroborosWidgets || true)
invalid_backgrounds=$(printf '%s\n' "$backgrounds" | /usr/bin/grep -v -E '\.background\((AppStyle\.background|NativeBackSwipeEnabler\(\)|AppStyle\.accent, in: (Capsule|Circle)\(\))\)' || true)
if [ -n "$invalid_backgrounds" ]; then
	echo "error: NO CARDS design rule violation: unapproved background"
	echo "$invalid_backgrounds"
	exit 1
fi

required_rule='Never places content in decorative background boxes; uses spacing, typography, alignment, and dividers for hierarchy.'
if ! /usr/bin/grep -Fq "$required_rule" FEATURES.md; then
	echo "error: FEATURES.md is missing the non-negotiable NO CARDS rule"
	exit 1
fi

if ! /usr/bin/grep -Fq 'NO CARDS:' AGENTS.md; then
	echo "error: AGENTS.md is missing the non-negotiable NO CARDS rule"
	exit 1
fi
