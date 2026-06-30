# Shared host PATH helpers for scripts invoked outside a login shell.
# Source this file; do not execute directly.

herm_prepend_path() {
	dir=$1

	[ -n "$dir" ] || return 0
	[ -d "$dir" ] || return 0
	case ":$PATH:" in
	*:"$dir":*) ;;
	*)
		PATH="$dir:$PATH"
		export PATH
		;;
	esac
}

herm_ensure_rust_path() {
	if [ -n "${HOME:-}" ] && [ -f "$HOME/.cargo/env" ]; then
		# shellcheck disable=SC1090
		. "$HOME/.cargo/env"
	fi
	herm_prepend_path "${HOME:-}/.cargo/bin"
}