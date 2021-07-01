#!/usr/bin/env bash

if [[ ${__PRAGMA_ONCE_FUNCTIONS_BUILD_SH+found} == found ]]; then
	return
fi
declare -r __PRAGMA_ONCE_FUNCTIONS_BUILD_SH=yes

# shellcheck source=./functions.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/functions.sh"

BUILDAH="$(find_command buildah)"
declare -rx BUILDAH

declare -r FEDORA_SYSTEMD_COMMAND='/lib/systemd/systemd --system --log-target=console --show-status=yes --log-color=no systemd.journald.forward_to_console=yes'

# shellcheck source=./functions/mdnf.sh
source "$COMMON_LIB_ROOT/functions/mdnf.sh"
# shellcheck source=./functions/mcompile.sh
source "$COMMON_LIB_ROOT/functions/mcompile.sh"
# shellcheck source=./functions/buildah-cache.sh
source "$COMMON_LIB_ROOT/functions/buildah-cache.sh"
# shellcheck source=./functions/buildah.hooks.sh
source "$COMMON_LIB_ROOT/functions/buildah.hooks.sh"
# shellcheck source=./functions/alpine.sh
source "$COMMON_LIB_ROOT/functions/alpine.sh"
# shellcheck source=./functions/python.sh
source "$COMMON_LIB_ROOT/functions/python.sh"
# shellcheck source=./functions/build-folder-hash.sh
source "$COMMON_LIB_ROOT/functions/build-folder-hash.sh"
# shellcheck source=./functions/healthcheck.sh
source "$COMMON_LIB_ROOT/functions/healthcheck.sh"

mapfile -t FILES < <(find "$COMMON_LIB_ROOT/standard_build_steps" -type f -name '*.sh')
for FELE in "${FILES[@]}"; do
	# shellcheck source=/dev/null
	source "$FELE"
done
unset FELE FILES

function create_if_not() {
	local NAME=$1 BASE=$2

	if is_ci; then
		info_log "[CI] Create container '$NAME' from image '$BASE'."
		new_container "$NAME" "$BASE"
	elif [[ $BASE == "scratch" ]]; then
		if container_exists "$NAME"; then
			info_log "Using exists container '$NAME'."
			buildah inspect --type container --format '{{.Container}}' "$NAME"
		else
			info_log "Create container '$NAME' from image $BASE."
			new_container "$NAME" "$BASE"
		fi
	else
		if ! image_exists "$BASE"; then
			info_note "missing base image $BASE, pulling from registry (proxy=${http_proxy:-'*notset'})..."
			buildah pull "$BASE" >&2
		fi

		local EXPECT GOT
		GOT=$(buildah inspect --type container --format '{{.FromImageID}}' "$NAME" 2>/dev/null)
		EXPECT=$(buildah inspect --type image --format '{{.FromImageID}}' "$BASE")
		if [[ $EXPECT == "$GOT" ]]; then
			info_log "Using exists container '$NAME'."
			buildah inspect --type container --format '{{.Container}}' "$NAME"
		elif [[ "$GOT" ]]; then
			info_log "Not using exists container: $BASE is updated"
			info_log "    current image:          $EXPECT"
			info_log "    exists container based: $GOT"
			buildah rm "$NAME" >/dev/null
			new_container "$NAME" "$BASE"
		else
			info_log "Create container '$NAME' from image '$BASE'."
			new_container "$NAME" "$BASE"
		fi
	fi
}

function container_exists() {
	local ID
	ID=$(buildah inspect --type container --format '{{.ContainerID}}' "$1")
	if [[ $ID == "" ]]; then
		info_warn "inspect container $1 success, but nothing return"
		return 1
	fi
}

function image_exists() {
	local ID
	ID=$(buildah inspect --type image --format '{{.FromImageID}}' "$1")
	if [[ $ID == "" ]]; then
		info_warn "inspect image $1 success, but nothing return"
		return 1
	fi
}

function image_get_id() {
	buildah inspect --type image --format '{{.FromImageID}}' "$1"
}

function is_id_digist() {
	echo "$*" | grep -qiE '^[0-9A-Z]+$'
}

function new_container() {
	local NAME=$1
	local EXISTS
	EXISTS=$(buildah inspect --type container --format '{{.Container}}' "$NAME" 2>/dev/null || true)
	if [[ -n $EXISTS ]]; then
		info_log "Remove exists container '$EXISTS'"
		buildah rm "$EXISTS" >/dev/null
	fi
	local FROM="${2-scratch}"
	if [[ $FROM != scratch ]] && ! is_id_digist "$FROM"; then
		if is_ci; then
			info_note "[CI] base image $FROM, pulling from registry (proxy=${http_proxy:-'*notset'})..."
			buildah pull "$FROM" >&2
		elif ! image_exists "$FROM"; then
			info_note "missing base image $FROM, pulling from registry (proxy=${http_proxy:-'*notset'})..."
			buildah pull "$FROM" >&2
		fi
	fi
	buildah from --name "$NAME" "$FROM"
}
