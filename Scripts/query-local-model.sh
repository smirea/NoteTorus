#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
	echo 'Usage: Scripts/query-local-model.sh "Your prompt"' >&2
	exit 64
fi

prompt="$*"
project_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
device_id="$(
	xcrun simctl list devices booted |
		sed -nE 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p' |
		head -n 1
)"

if [ -z "$device_id" ]; then
	echo "Open an iPhone Simulator first." >&2
	exit 1
fi

derived_data="${TMPDIR:-/tmp}/NoteTorusModelProbe"
build_log="$(mktemp -t notetorus-model-probe)"
output_path=""

cleanup() {
	trash "$build_log"
	if [ -n "$output_path" ] && [ -f "$output_path" ]; then
		trash "$output_path"
	fi
}

trap cleanup EXIT

echo "Building the simulator probe…" >&2
if ! xcodebuild \
	-project "$project_root/NoteTorus.xcodeproj" \
	-scheme NoteTorus \
	-configuration Debug \
	-destination "platform=iOS Simulator,id=$device_id" \
	-derivedDataPath "$derived_data" \
	build >"$build_log" 2>&1
then
	tail -n 80 "$build_log" >&2
	exit 1
fi

app_path="$derived_data/Build/Products/Debug-iphonesimulator/NoteTorus.app"
xcrun simctl install "$device_id" "$app_path" >/dev/null 2>&1
data_container="$(xcrun simctl get_app_container "$device_id" com.stefan.notetorus data)"
output_path="$data_container/tmp/local-model-probe.txt"
if [ -f "$output_path" ]; then
	trash "$output_path"
fi

set +e
xcrun simctl launch \
	--terminate-running-process \
	--console-pty \
	"$device_id" \
	com.stefan.notetorus \
	-demo \
	-local-model-prompt \
	"$prompt" >/dev/null 2>&1
launch_status=$?
set -e

if [ ! -f "$output_path" ]; then
	echo "The model probe exited without producing output." >&2
	exit 1
fi

sed -n 'p' "$output_path"
exit "$launch_status"
