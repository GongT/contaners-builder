#!/usr/bin/env bash

set -Eeuo pipefail

function sdnotify() {
	if [[ "${NOTIFY_SOCKET+found}" = found ]]; then
		systemd-notify "$@"
	fi
}

function image_get_id() {
	buildah inspect --type image --format '{{.FromImageID}}' "$IMAGE_TO_PULL" 2> /dev/null || true
}

declare -rx IMAGE_TO_PULL=$1
OLD_ID=$(image_get_id)
if [[ "$2" != "always" ]]; then
	if [[ "$OLD_ID" ]]; then
		echo "Image already exists: $OLD_ID"
		exit 0
	fi
fi

mkdir -p /var/run/last-pull
declare -r STORE_FILE="/var/run/last-pull/$(echo "$IMAGE_TO_PULL" | md5sum | awk '{print $1}')"
declare -i NOW LAST

NOW=$(date +%s)
if [[ -e "$STORE_FILE" ]]; then
	LAST=$(< "$STORE_FILE")
	LASTSTR=$(TZ=Asia/Chongqing date --date="@$LAST" "+%F %T")
	if [[ "$NOW" -lt $((LAST + 3600)) ]]; then
		echo "Skip pull image, last at: $LASTSTR"
		exit 0
	else
		echo "Last pull at $LASTSTR, expired"
	fi
else
	echo "Never pull this image in current boot."
fi

sdnotify "--status=pull image"

unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

echo "Pull image $IMAGE_TO_PULL from registry..."

sdnotify "--status=EXTEND_TIMEOUT_USEC=$((60 * 1000 * 1000))"

podman pull "$IMAGE_TO_PULL" || exit 233

NEW_ID=$(image_get_id)

if [[ "$OLD_ID" == "$NEW_ID" ]]; then
	echo "Image is up to date, id=$OLD_ID"
else
	echo "Downloaded newer image, id=$NEW_ID"
fi
echo -n "$NOW" > "$STORE_FILE"

echo "removing images:" >&2
podman images \
	| grep --fixed-strings '<none>' \
	| awk '{print $3}' \
	| xargs --no-run-if-empty --verbose --no-run-if-empty \
		podman rmi || true

sdnotify "--status=EXTEND_TIMEOUT_USEC=$((30 * 1000 * 1000))"
