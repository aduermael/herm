#!/bin/sh

herm_sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		printf '%s\n' "error: sha256sum or shasum is required" >&2
		return 1
	fi
}

herm_source_revision() {
	git -C "$1" rev-parse HEAD 2>/dev/null || printf '%s\n' unknown
}

herm_manifest_init() {
	manifest_path=$1
	printf '%s\n' 'format=1' >"$manifest_path"
}

herm_manifest_add() {
	manifest_path=$1
	manifest_key=$2
	manifest_value=$(printf '%s' "$3" | tr '\r\n' '  ')
	case "$manifest_key" in
	'' | *[!a-z0-9_]*)
		printf '%s\n' "error: invalid build manifest key: $manifest_key" >&2
		return 1
		;;
	esac
	printf '%s=%s\n' "$manifest_key" "$manifest_value" >>"$manifest_path"
}

herm_manifest_add_file() {
	manifest_path=$1
	manifest_key=$2
	manifest_file=$3
	[ -f "$manifest_file" ] || return 0
	herm_manifest_add "$manifest_path" "$manifest_key" "$(herm_sha256_file "$manifest_file")"
}
