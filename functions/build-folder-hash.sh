#!/usr/bin/env bash

_HASH_CACHED=""
_HASH_CACHED_AT=""

function hash_path() {
	local F=$1
	if [[ $F == /* ]]; then
		tar c --owner=0 --group=0 --mtime='UTC 2000-01-01' --sort=name -C / ".$F" | md5sum | awk '{print $1}'
	else
		tar c --owner=0 --group=0 --mtime='UTC 2000-01-01' --sort=name "$F" | md5sum | awk '{print $1}'
	fi
}
function fast_hash_path() {
	{
		git ls-tree -r master "$@"
	} | md5sum | awk '{print $1}'
}
function hash_current_folder_cached() {
	if [[ "$_HASH_CACHED" ]]; then
		if [[ $_HASH_CACHED_AT != "$(pwd)" ]]; then
			die "Fatal: current working directory changed during build. (from $_HASH_CACHED_AT to $(pwd))"
		fi

		echo "$_HASH_CACHED"
	fi

	hash_current_folder
}
function hash_current_folder() {
	set -- $(
		IFS=$'\n' git ls-tree --name-only -r master "$(pwd)" \
			| xargs -n1 grep --directories=skip --no-messages --binary-files=without-match -A1 -E "install_shared_project"
	)

	declare -a DEPS
	while [[ $# -gt 0 ]]; do
		if [[ $1 == install_shared_project ]]; then
			shift
			if [[ $1 == '\' ]]; then
				shift
			fi
			DEPS+=("$(get_shared_project_location "$1")")
		fi

		shift
	done

	local HASH
	HASH=$(
		git ls-tree -r master "${DEPS[@]}" "$COMMON_LIB_ROOT" "$(pwd)" | md5sum | awk '{print $1}'
	)

	_HASH_CACHED="$HASH"
	_HASH_CACHED_AT="$(pwd)"
	declare -r _HASH_CACHED_AT _HASH_CACHED

	echo "$HASH"
}
