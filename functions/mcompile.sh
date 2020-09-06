function run_compile() {
	local PROJECT_ID="$1" WORKER="$2" SCRIPT="$3"

	if [[ "${SOURCE_DIRECTORY+found}" = found ]]; then
		SOURCE_DIRECTORY="$(realpath "$SOURCE_DIRECTORY")"
	else
		local SOURCE_DIRECTORY
		SOURCE_DIRECTORY="$(pwd)/source/$PROJECT_ID"
	fi

	mkdir -p "$SYSTEM_COMMON_CACHE/ccache"

	info "compile project in '$WORKER' by '$SCRIPT'"
	{
		SHELL_ERROR_HANDLER
		echo "export PROJECT_ID='$PROJECT_ID'"
		cat "$COMMON_LIB_ROOT/staff/mcompile/prefix.sh"
		SHELL_USE_PROXY
		cat "$SCRIPT"
	} | buildah run \
		"--volume=$SYSTEM_COMMON_CACHE/ccache:/opt/cache" \
		"--volume=$SOURCE_DIRECTORY:/opt/projects/$PROJECT_ID" "$BUILDER" bash
}
function run_install() {
	local PROJECT_ID="$1" SOURCE_IMAGE="$2" TARGET_DIR="$3"

	local WORKER
	WORKER=$(new_container "${PROJECT_ID}-result-copyout" "$SOURCE_IMAGE")

	local PREPARE_SCRIPT=""
	if [[ $# -eq 4 ]]; then
		PREPARE_SCRIPT=$(< "$4")
	fi

	local SRC="$(mktemp)"
	{
		echo 'set -Eeuo pipefail'
		SHELL_ERROR_HANDLER
		echo "export PROJECT_ID='$PROJECT_ID'"
		cat "$COMMON_LIB_ROOT/staff/mcompile/installer.sh"
		echo "$PREPARE_SCRIPT"
	} > "$SRC"
	buildah run -t \
		"--volume=$SRC:/mnt/script.sh:ro" \
		"--volume=$TARGET_DIR:/mnt/install" \
		"$WORKER" bash "/mnt/script.sh"
}
