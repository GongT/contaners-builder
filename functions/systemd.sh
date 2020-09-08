declare -a _S_PREP_FOLDER
declare -a _S_LINUX_CAP
declare -a _S_VOLUME_ARG
declare -A _S_UNIT_CONFIG
declare -A _S_BODY_CONFIG
declare -a _S_EXEC_START_PRE
declare -a _S_EXEC_START_POST
declare -a _S_EXEC_STOP_POST
declare -a _S_PODMAN_ARGS
declare -a _S_COMMAND_LINE
declare -a _S_NETWORK_ARGS

declare -r SHARED_SOCKET_PATH=/dev/shm/container-shared-socksets

if podman stop --help 2>&1 | grep -q -- '--ignore'; then
	info_note "podman support --ignore flag"
	declare -r PODMAN_USE_IGNORE=yes
else
	echo "podman version is old. can't use --ignore flag" >&2
	declare -r PODMAN_USE_IGNORE=
fi

function _unit_init() {
	_S_IMAGE=
	_S_CURRENT_UNIT_SERVICE_TYPE=
	_S_AT_=
	_S_CURRENT_UNIT_TYPE=
	_S_CURRENT_UNIT_NAME=
	_S_CURRENT_UNIT_FILE=
	_S_IMAGE_PULL=never
	_S_HOST=
	_S_STOP_CMD=
	_S_KILL_TIMEOUT=5
	_S_KILL_FORCE=yes
	_S_INSTALL=multi-user.target
	_S_EXEC_RELOAD=
	_S_START_WAIT_SLEEP=10
	_S_START_WAIT_OUTPUT=
	_S_START_ACTIVE_FILE=
	_S_SYSTEMD=false

	_S_PREP_FOLDER=()
	_S_LINUX_CAP=()
	_S_VOLUME_ARG=()
	_S_UNIT_CONFIG=()
	_S_BODY_CONFIG=()
	_S_EXEC_START_PRE=()
	_S_EXEC_START_POST=()
	_S_EXEC_STOP_POST=()
	_S_PODMAN_ARGS=()
	_S_COMMAND_LINE=()
	_S_NETWORK_ARGS=()
	_S_BODY_CONFIG[RestartPreventExitStatus]="233"
	_S_BODY_CONFIG[Restart]="no"
	_S_BODY_CONFIG[KillSignal]="SIGINT"
	_S_BODY_CONFIG[Slice]="machine.slice"
	_S_REQUIRE_INFRA=

	## network.sh
	_N_TYPE=
}

function auto_create_pod_service_unit() {
	create_pod_service_unit "$(basename "$(pwd)")"
}
function create_pod_service_unit() {
	_arg_ensure_finish
	__create_unit__ pod "$1" service
}
function __create_unit__() {
	_unit_init
	_S_CURRENT_UNIT_SERVICE_TYPE="$1"
	_S_IMAGE="$2"
	_S_CURRENT_UNIT_TYPE="${3-service}"

	local NAME=$(basename "$_S_IMAGE")

	if [[ "$NAME" == *@ ]]; then
		NAME="${NAME:0:-1}"
		_S_AT_='@'
	fi

	_S_CURRENT_UNIT_NAME="$NAME"

	if [[ "$_S_CURRENT_UNIT_SERVICE_TYPE" ]]; then
		_S_CURRENT_UNIT_FILE="$NAME.$_S_CURRENT_UNIT_SERVICE_TYPE$_S_AT_.$_S_CURRENT_UNIT_TYPE"
	else
		_S_CURRENT_UNIT_FILE="$NAME$_S_AT_.$_S_CURRENT_UNIT_TYPE"
	fi
	echo "creating unit file $_S_CURRENT_UNIT_FILE"
}

function unit_write() {
	if [[ -z "$_S_CURRENT_UNIT_FILE" ]]; then
		die "create_xxxx_unit first."
	fi
	local -r TF=$(mktemp -u)
	_unit_assemble > $TF
	write_file "/usr/lib/systemd/system/$_S_CURRENT_UNIT_FILE" < $TF
	unlink $TF
}
_get_debugger_script() {
	echo "/usr/share/scripts/debug-startup-$(_unit_get_name).sh"
}
_debugger_file_write() {
	local -r TF=$(mktemp -u)
	local -r DEBUG_SCRIPT=
	local -a STARTUP_ARGS=()

	_create_startup_arguments
	{
		echo "#!/usr/bin/env bash"
		echo "declare -r SCOPE_ID='$(_unit_get_scopename)'"
		echo "declare -r NAME='$(_unit_get_name)'"
		echo "declare -r SERVICE_FILE='$_S_CURRENT_UNIT_FILE'"

		cat "$COMMON_LIB_ROOT/staff/debugger.sh"

		echo -n "X podman run -it"
		for I in "${STARTUP_ARGS[@]}"; do
			echo -ne " \\\\\n\t${I}"
		done
		echo ''
	} | write_file "$(_get_debugger_script)"
	chmod a+x "$(_get_debugger_script)"
}

function unit_finish() {
	unit_write

	_debugger_file_write

	apply_systemd_service "$_S_CURRENT_UNIT_FILE"

	_unit_init
}
function apply_systemd_service() {
	_arg_ensure_finish
	local UN="$1"

	echo -ne "\e[2m"
	if is_installing; then
		if [[ "${SYSTEMD_RELOAD-yes}" == "yes" ]]; then
			systemctl daemon-reload
			if ! systemctl is-enabled -q "$UN"; then
				systemctl enable "$UN"
			fi
			echo -ne "\e[0m"
			info "systemd unit $UN create and enabled."
		fi
		echo -ne "\e[0m"
	else
		if systemctl is-enabled -q "$UN"; then
			systemctl disable "$UN"
			systemctl reset-failed "$UN"
		fi
		echo -ne "\e[0m"
		info "systemd unit $UN disabled."
	fi
}
function _unit_get_extension() {
	echo "${_S_CURRENT_UNIT_TYPE}"
}
function _unit_get_name() {
	echo "${_S_CURRENT_UNIT_NAME}"
}
function _unit_get_scopename() {
	local NAME="$(_unit_get_name)"
	if [[ "$_S_AT_" ]]; then
		NAME="${NAME%@}"
		echo "${NAME}_%i"
	else
		echo "$NAME"
	fi
}
function _unit_assemble() {
	_network_use_not_define
	_create_service_library

	local I
	echo "[Unit]"

	if [[ "${#_S_PREP_FOLDER[@]}" -gt 0 ]]; then
		unit_depend wait-mount.service
	fi

	for VAR_NAME in "${!_S_UNIT_CONFIG[@]}"; do
		echo "$VAR_NAME=${_S_UNIT_CONFIG[$VAR_NAME]}"
	done

	local EXT="$(_unit_get_extension)"
	local NAME="$(_unit_get_name)"
	local SCOPE_ID="$(_unit_get_scopename)"
	echo ""
	echo "[${EXT^}]
Type=forking
NotifyAccess=none
PIDFile=/run/$SCOPE_ID.conmon.pid"

	if [[ "${#_S_PREP_FOLDER[@]}" -gt 0 ]]; then
		echo -n "ExecStartPre=/usr/bin/mkdir -p"
		for I in "${_S_PREP_FOLDER[@]}"; do
			echo -n " '$I'"
		done
		echo ''
	fi

	if [[ -z "$_S_STOP_CMD" ]]; then
		if [[ "$PODMAN_USE_IGNORE" ]]; then
			echo "ExecStartPre=/usr/bin/podman stop --ignore --time $_S_KILL_TIMEOUT $SCOPE_ID"
		else
			echo "ExecStartPre=-/usr/bin/podman stop --time $_S_KILL_TIMEOUT $SCOPE_ID"
		fi
	else
		echo "ExecStartPre=-$_S_STOP_CMD"
	fi
	if [[ "$_S_KILL_FORCE" == "yes" ]]; then
		if [[ "$PODMAN_USE_IGNORE" ]]; then
			echo "ExecStartPre=/usr/bin/podman rm --ignore --force $SCOPE_ID"
			echo "ExecStopPost=/usr/bin/podman rm --ignore --force $SCOPE_ID"
		else
			echo "ExecStartPre=-/usr/bin/podman rm --force $SCOPE_ID"
			echo "ExecStopPost=-/usr/bin/podman rm --force $SCOPE_ID"
		fi
	fi

	if [[ "${_S_IMAGE_PULL}" = "missing" ]]; then
		: # TODO
	elif [[ "${_S_IMAGE_PULL}" = "never" ]]; then
		:   # Nothing
	else # always
		echo "ExecStartPre=-/usr/bin/podman pull '${_S_IMAGE:-"$NAME"}'"
	fi

	if [[ "${#_S_EXEC_START_PRE[@]}" -gt 0 ]]; then
		for I in "${_S_EXEC_START_PRE[@]}"; do
			echo "ExecStartPre=$I"
		done
		echo ''
	fi

	if [[ "${#_S_EXEC_START_POST[@]}" -gt 0 ]]; then
		for I in "${_S_EXEC_START_POST[@]}"; do
			echo "ExecStartPost=$I"
		done
		echo ''
	fi

	WAIT_ENV_FILE=$(
		save_environments start-params \
			"WAIT_TIME=$_S_START_WAIT_SLEEP" \
			"WAIT_OUTPUT=$_S_START_WAIT_OUTPUT" \
			"ACTIVE_FILE=$_S_START_ACTIVE_FILE"
	)
	echo "Environment=CONTAINER_ID=$SCOPE_ID"
	echo "EnvironmentFile=$WAIT_ENV_FILE"

	local _SERVICE_WAITER
	_SERVICE_WAITER=$(install_script_as "$COMMON_LIB_ROOT/tools/service-wait.sh" "$(_unit_get_name).pod")
	echo -n "ExecStart=${_SERVICE_WAITER} \\
	--detach-keys=q --conmon-pidfile=/run/$SCOPE_ID.conmon.pid '--name=$SCOPE_ID'"

	local -a STARTUP_ARGS=()
	_create_startup_arguments
	for I in "${STARTUP_ARGS[@]}"; do
		echo -ne " \\\\\n\t${I}"
	done
	echo ""
	echo "# debug script: $(_get_debugger_script)"

	if [[ -z "$_S_STOP_CMD" ]]; then
		echo "ExecStop=${_CONTAINER_STOP} $_S_KILL_TIMEOUT $SCOPE_ID"
		echo "TimeoutStopSec=$((_S_KILL_TIMEOUT + 10))"
	else
		echo "ExecStop=$_S_STOP_CMD"
	fi
	for I in "${_S_EXEC_STOP_POST[@]}"; do
		echo "ExecStopPost=$I"
	done

	if [[ -n "$_S_EXEC_RELOAD" ]]; then
		echo "ExecReload=$_S_EXEC_RELOAD"
	fi

	for VAR_NAME in "${!_S_BODY_CONFIG[@]}"; do
		echo "$VAR_NAME=${_S_BODY_CONFIG[$VAR_NAME]}"
	done

	echo ""
	echo "[Install]"
	echo "WantedBy=$_S_INSTALL"
}

function _create_startup_arguments() {
	local -r SCOPE_ID="$(_unit_get_scopename)"
	STARTUP_ARGS+=("'--hostname=${_S_HOST:-$SCOPE_ID}'")
	STARTUP_ARGS+=("--systemd=$_S_SYSTEMD --log-opt=path=/dev/null --restart=no")
	STARTUP_ARGS+=("${_S_NETWORK_ARGS[@]}" "${_S_PODMAN_ARGS[@]}" "${_S_VOLUME_ARG[@]}")
	if [[ "${#_S_LINUX_CAP[@]}" -gt 0 ]]; then
		local CAP_ITEM CAP_LIST=""
		for CAP_ITEM in "${_S_LINUX_CAP[@]}"; do
			CAP_LIST+=",$CAP_ITEM"
		done
		STARTUP_ARGS+=("--cap-add=${CAP_LIST:1}")
	fi
	if [[ -n "$_S_START_ACTIVE_FILE" ]]; then
		STARTUP_ARGS+=("'--volume=ACTIVE_FILE:/tmp/ready-volume'" "'--env=ACTIVE_FILE=/tmp/ready-volume/$_S_START_ACTIVE_FILE'")
	fi
	STARTUP_ARGS+=("'--pull=missing' --rm '${_S_IMAGE:-"$NAME"}'")
	STARTUP_ARGS+=("${_S_COMMAND_LINE[@]}")
}

declare -r BIND_RBIND="noexec,nodev,nosuid,rw,rbind"

function unit_data() {
	if [[ "$1" == "safe" ]]; then
		_S_KILL_TIMEOUT=5
		_S_KILL_FORCE=yes
	elif [[ "$1" == "danger" ]]; then
		_S_KILL_TIMEOUT=120
		_S_KILL_FORCE=no
	else
		die "unit_data <safe|danger>"
	fi
}
function unit_using_systemd() {
	_S_SYSTEMD=true
}
function unit_fs_tempfs() {
	local SIZE="$1" PATH="$2"
	_S_VOLUME_ARG+=("'--mount=type=tmpfs,tmpfs-size=$SIZE,destination=$PATH'")
}
function unit_volume() {
	local NAME="$1" TO="$2" OPTIONS=":noexec,nodev,nosuid"
	if [[ $# -gt 2 ]]; then
		OPTIONS+=",$3"
	fi

	_S_PREP_FOLDER+=("$NAME")
	_S_VOLUME_ARG+=("'--volume=$NAME:$TO$OPTIONS'")
}
function unit_fs_bind() {
	local FROM="$1" TO="$2" OPTIONS=":noexec,nodev,nosuid"
	if [[ $# -gt 2 ]]; then
		OPTIONS+=",$3"
	fi
	if [[ "${FROM:0:1}" != "/" ]]; then
		FROM="$CONTAINERS_DATA_PATH/$FROM"
	fi

	_S_PREP_FOLDER+=("$FROM")
	_S_VOLUME_ARG+=("'--volume=$FROM:$TO$OPTIONS'")
}
function shared_sockets_use() {
	if ! echo "${_S_VOLUME_ARG[*]}" | grep $SHARED_SOCKET_PATH; then
		unit_fs_bind $SHARED_SOCKET_PATH /run/sockets
	fi
}
function shared_sockets_provide() {
	if ! echo "${_S_VOLUME_ARG[*]}" | grep $SHARED_SOCKET_PATH; then
		unit_fs_bind $SHARED_SOCKET_PATH /run/sockets
	fi
	local -a FULLPATH=()
	for i; do
		FULLPATH+=("'$SHARED_SOCKET_PATH/$i.sock'")
	done
	unit_hook_start "/usr/bin/rm -f ${FULLPATH[*]}"
	unit_hook_stop "/usr/bin/rm -f ${FULLPATH[*]}"
}
function unit_depend() {
	if [[ -n "$*" ]]; then
		unit_unit After "$*"
		unit_unit Requires "$*"
		unit_unit PartOf "$*"

		if echo "$*" | grep -q -- "virtual-gateway.pod.service"; then
			_S_REQUIRE_INFRA=yes
		fi
	fi
}
function unit_unit() {
	local K=$1
	shift
	local V="$*"
	if echo "$K" | grep -qE '^(Before|After|Requires|Wants|PartOf|WantedBy)$'; then
		_S_UNIT_CONFIG[$K]+=" $V"
	elif echo "$K" | grep -qE '^(WantedBy)$'; then
		_S_INSTALL="$V"
	else
		_S_UNIT_CONFIG[$K]="$V"
	fi
}
function unit_body() {
	local K="$1"
	shift
	local V="$*"
	if echo "$K" | grep -qE '^(RestartPreventExitStatus|Environment)$'; then
		if [[ "${_S_BODY_CONFIG[$K]+found}" = "found" ]]; then
			_S_BODY_CONFIG[$K]+=" "
		fi
		_S_BODY_CONFIG[$K]+="$V"
	elif echo "$K" | grep -qE '^(ExecStop)$'; then
		_S_STOP_CMD="$V"
	else
		_S_BODY_CONFIG[$K]="$V"
	fi
}
function _unit_podman_network_arg() {
	_S_NETWORK_ARGS+=("$*")
}
function unit_podman_arguments() {
	local I
	for I; do
		_S_PODMAN_ARGS+=("'$I'")
	done
}
function unit_podman_hostname() {
	_S_HOST=$1
}

function unit_podman_image_pull() {
	_S_IMAGE_PULL=$1
}
function unit_podman_image() {
	_S_IMAGE=$1
	shift
	_S_COMMAND_LINE=("$@")
}
function unit_hook_poststart() {
	_S_EXEC_START_POST+=("$*")
}
function unit_hook_start() {
	_S_EXEC_START_PRE+=("$*")
}
function unit_hook_stop() {
	_S_EXEC_STOP_POST+=("$*")
}
function unit_reload_command() {
	_S_EXEC_RELOAD="$*"
}
function unit_start_notify() {
	local TYPE="$1" ARG="${2-}"
	_S_START_WAIT_SLEEP=
	_S_START_WAIT_OUTPUT=
	_S_START_ACTIVE_FILE=
	case "$TYPE" in
	sleep)
		_S_START_WAIT_SLEEP="$ARG"
		;;
	output)
		_S_START_WAIT_OUTPUT="$ARG"
		;;
	touch)
		if [[ -z "$ARG" ]]; then
			ARG="$_S_CURRENT_UNIT_FILE.$RANDOM.ready"
		fi
		_S_START_ACTIVE_FILE="$ARG"
		;;
	*)
		die "Unknown start notify method $TYPE, allow: sleep, output, touch."
		;;
	esac
}
function _create_service_library() {
	if [[ "${_CONTAINER_STOP+found}" == "found" ]]; then
		return
	fi
	mkdir -p /usr/share/scripts/

	cat "$COMMON_LIB_ROOT/tools/stop-container.sh" > /usr/share/scripts/stop-container.sh
	chmod a+x /usr/share/scripts/stop-container.sh
	_CONTAINER_STOP=/usr/share/scripts/stop-container.sh

	cat "$COMMON_LIB_ROOT/tools/lowlevel-clear.sh" > /usr/share/scripts/lowlevel-clear.sh
	chmod a+x /usr/share/scripts/lowlevel-clear.sh
	_LOWLEVEL_CLEAR=/usr/share/scripts/lowlevel-clear.sh

	cat "$COMMON_LIB_ROOT/tools/update-hosts.sh" > /usr/share/scripts/update-hosts.sh
	chmod a+x /usr/share/scripts/update-hosts.sh
	_UPDATE_HOSTS=/usr/share/scripts/update-hosts.sh
}
