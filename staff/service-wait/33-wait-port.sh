#!/usr/bin/env bash
set -Eeuo pipefail

function wait_by_port() {
	local -r PORT_DEFINE="$1"
	local -r PORT=${PORT_DEFINE%/*} PROTOCOL=${PORT_DEFINE#*/}

	while ! INNER_PID=$(podman container inspect -f '{{.State.Pid}}' "${CONTAINER_ID}"); do
		sleep 2
	done

	debug "container init pid is ${INNER_PID}"

	while ! nsenter --user --net --target "${INNER_PID}" ss --listening "--$PROTOCOL" --numeric | grep -q ":${PORT} "; do
		sleep 2
	done
	debug "${PROTOCOL} port ${PORT} has opened for listening"
	service_wait_success
}
