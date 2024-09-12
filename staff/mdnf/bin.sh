#!/usr/bin/env bash

set -Eeuo pipefail

if [[ -e /install-root ]]; then
	cd /install-root
else
	cd /
fi

mkdir -p /install-root/etc/dnf
cp /etc/dnf/dnf.conf /install-root/etc/dnf/dnf.conf

TO_UNMOUNT=()

bind_fs() {
	local FS=$1
	rm -rf "/install-root${FS}"
	mkdir -p "/install-root${FS}" "${FS}"
	mount --bind "${FS}" "/install-root${FS}"
	TO_UNMOUNT+=("/install-root${FS}")
}

bind_fs /var/lib/dnf/repos
bind_fs /var/cache/dnf

function main() {
	if [[ -z ${ACTION-} ]]; then
		ACTION="install"
	fi

	dnf() {
		echo -e "\e[2m + /usr/bin/dnf --nodocs -y '--releasever=${FEDORA_VERSION}' --installroot=/install-root $*\e[0m" >&2
		/usr/bin/dnf --nodocs -y "--releasever=${FEDORA_VERSION}" --installroot=/install-root "$@"
	}

	# dnf clean expire-cache
	# dnf makecache
	dnf "${ACTION}" "${@}"

	if [[ ${ACTION} == install ]]; then
		cd /install-root

		BUSYBOX_BIN=$(find bin usr/bin -name busybox -or -name busybox.shared | head -n1 | sed 's/^\.//')

		if [[ -n ${BUSYBOX_BIN} ]]; then
			echo "installing busybox (${BUSYBOX_BIN})..."
			chroot /install-root "${BUSYBOX_BIN}" --install -s /bin
		fi
	fi
}

_exit() {
	R=$?

	umount "${TO_UNMOUNT[@]}"

	DIRS_SHOULD_EMPTY=(/install-root/var/log /install-root/tmp)
	rm -rf "${DIRS_SHOULD_EMPTY[@]}"
	mkdir -p "${DIRS_SHOULD_EMPTY[@]}"
	chmod 0777 "${DIRS_SHOULD_EMPTY[@]}"

	echo "dnf script returned ${R}" >&2
	exit "${R}"
}

trap _exit EXIT
main "$@"
