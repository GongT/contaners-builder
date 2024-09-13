#!/usr/bin/env bash
set -Eeuo pipefail

declare -i WAIT_ERROR=66
function core_switch() {
	case "${WAIT_TYPE}" in
	socket)
		wait_by_socket
		;;
	port)
		wait_by_port "${WAIT_ARGS%:*}" "${WAIT_ARGS#*:}"
		;;
	sleep)
		wait_by_sleep "$WAIT_ARGS"
		;;
	output)
		wait_by_output "$WAIT_ARGS"
		;;
	touch)
		wait_by_create_file "$WAIT_ARGS"
		;;
	healthy) exit 251 ;; # do nothing
	pass) exit 251 ;;    # do nothing
	*)
		sdnotify "--status=startup timeout"
		echo "invalid wait type: ${WAIT_TYPE}" >&2
		return 1
		;;
	esac
}

function service_wait_success() {
	WAIT_ERROR=0
}

function service_wait_thread() {
	function _wait_exit() {
		local RET=$?
		if [[ ${WAIT_ERROR} -eq 0 && ${RET} -eq 0 ]]; then
			startup_done
		elif [[ ${RET} -eq 251 ]]; then
			exit 0 # no need wait
		else
			debug "failed wait container '${CONTAINER_ID}' to stable running."

			sdnotify --stopping "wait fail"

			local SPID
			SPID=$(get_service_property "MainPID")
			if [[ ${SPID} -gt 0 ]]; then
				echo "send signal to podman container ${SPID}"
				kill -s sigterm "${SPID}"
			fi
		fi
	}
	trap _wait_exit EXIT

	debug "wait container ${CONTAINER_ID}, type=${WAIT_TYPE}, $(echo "${WAIT_ARGS}" | base64 --wrap=0)."

	core_switch
}

function main() {
	detect_image_using_systemd
	load_sdnotify

	add_run_argument "--name=${CONTAINER_ID}"
	ensure_mounts
	remove_old_socks

	if [[ ${START_WAIT_DEFINE} == auto ]]; then
		if is_image_has_healthcheck; then
			START_WAIT_DEFINE=healthy
		elif is_image_using_systemd; then
			START_WAIT_DEFINE=pass
		else
			START_WAIT_DEFINE=sleep:10
		fi
		debug "auto detect wait: ${START_WAIT_DEFINE}"
	fi
	if [[ ${START_WAIT_DEFINE} == touch || ${START_WAIT_DEFINE} == touch: ]]; then
		START_WAIT_DEFINE="touch:/startup.${RANDOM}.signal"
	fi

	local -r WAIT_TYPE=${START_WAIT_DEFINE%%:*}
	if [[ ${START_WAIT_DEFINE} == *:* ]]; then
		local -r WAIT_ARGS=${START_WAIT_DEFINE#*:}
	else
		local -r WAIT_ARGS=''
	fi

	if [[ ${WAIT_TYPE} == pass ]]; then
		add_run_argument "--sdnotify=container"
	elif [[ ${WAIT_TYPE} == healthy ]]; then
		add_run_argument "--sdnotify=healthy"
	elif [[ ${WAIT_TYPE} == touch ]]; then
		add_run_argument "--env=STARTUP_TOUCH_FILE=${WAIT_ARGS}"
	else
		wait_for_pid_and_notify
		add_run_argument "--sdnotify=ignore"
	fi

	make_arguments

	ensure_container_not_running

	service_wait_thread &

	podman_run_container
}

main
