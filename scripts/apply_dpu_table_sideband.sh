#!/usr/bin/env bash
set -euo pipefail

usage()
{
	echo "Usage: $0 HOST_DRIVER_NET_DIR" >&2
}

if [[ $# -ne 1 ]]; then
	usage
	exit 2
fi

driver_arg=$1
if [[ -L "$driver_arg" || ! -d "$driver_arg" ]]; then
	echo "error: driver tree must be a real directory: $driver_arg" >&2
	exit 1
fi
driver_dir=$(cd "$driver_arg" && pwd -P)
driver_parent=$(dirname "$driver_dir")
driver_name=$(basename "$driver_dir")
for required in Makefile main.c; do
	if [[ ! -f "$driver_dir/$required" ]]; then
		echo "error: host-driver-net is missing $required" >&2
		exit 1
	fi
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$script_dir/.." && pwd)
overlay_dir="$repo/guest/dpu-table-sideband"
sources=(
	"$overlay_dir/cosim_table_ctrl.c"
	"$overlay_dir/cosim_table_ctrl.h"
	"$repo/bridge/table/cosim_table_ctrl_uapi.h"
	"$repo/bridge/table/cosim_table_protocol.h"
)
for source in "${sources[@]}"; do
	if [[ ! -f "$source" ]]; then
		echo "error: overlay source is missing: $source" >&2
		exit 1
	fi
done

shopt -s nullglob
patches=("$overlay_dir"/[0-9][0-9][0-9][0-9]-*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
	echo "error: overlay has no numbered patches" >&2
	exit 1
fi
for index in "${!patches[@]}"; do
	printf -v expected '%04d' "$((index + 1))"
	name=$(basename "${patches[$index]}")
	if [[ ${name%%-*} != "$expected" ]]; then
		echo "error: patch stack must be contiguous from 0001: $name" >&2
		exit 1
	fi
done

rename_bin=${COSIM_TABLE_RENAME_BIN:-mv}
if ! command -v "$rename_bin" >/dev/null 2>&1; then
	echo "error: rename command is unavailable: $rename_bin" >&2
	exit 1
fi

commit_rename()
{
	"$rename_bin" -T -- "$1" "$2"
}

transaction=$(mktemp -d "$driver_parent/.cosim-table-transaction.XXXXXX")
stage="$transaction/stage"
backup="$transaction/original"
failed_live="$transaction/failed-live"
swap_started=false

finish()
{
	status=$?
	rollback_ok=true
	trap - EXIT INT TERM
	set +e
	if $swap_started && [[ -e "$backup" ]]; then
		if [[ -e "$driver_dir" || -L "$driver_dir" ]]; then
			if [[ -e "$failed_live" || -L "$failed_live" ]] ||
			   ! commit_rename "$driver_dir" "$failed_live"; then
				rollback_ok=false
			fi
		fi
		if $rollback_ok; then
			if [[ -e "$driver_dir" || -L "$driver_dir" ]] ||
			   ! commit_rename "$backup" "$driver_dir"; then
				rollback_ok=false
			fi
		fi
	fi
	if $rollback_ok && [[ -d "$driver_dir" && ! -L "$driver_dir" ]]; then
		rm -rf -- "$transaction"
	else
		echo "error: rollback incomplete; recovery tree: $transaction" >&2
		status=1
	fi
	exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp -a -- "$driver_dir" "$stage"
staged_files=0
for source in "${sources[@]}"; do
	cp -p -- "$source" "$stage/$(basename "$source")"
	staged_files=$((staged_files + 1))
	if [[ ${COSIM_TABLE_FAIL_AFTER_STAGE_FILE:-0} -eq $staged_files ]]; then
		echo "error: injected failure after staged file $staged_files" >&2
		exit 99
	fi
done

marker_dir="$stage/.cosim-table-sideband-applied"
mkdir -p "$marker_dir"
for patch_file in "${patches[@]}"; do
	patch_name=$(basename "$patch_file")
	marker="$marker_dir/$patch_name.applied"
	if [[ -f "$marker" ]]; then
		if ! patch --batch --binary --fuzz=0 --reverse --dry-run -p1 \
			-d "$stage" <"$patch_file" >/dev/null 2>&1; then
			echo "error: marker does not match applied patch: $patch_name" >&2
			exit 1
		fi
		continue
	fi
	if patch --batch --binary --fuzz=0 --forward --dry-run -p1 \
		-d "$stage" <"$patch_file" >/dev/null 2>&1; then
		patch --batch --binary --fuzz=0 --forward -p1 \
			-d "$stage" <"$patch_file" >/dev/null
	elif patch --batch --binary --fuzz=0 --reverse --dry-run -p1 \
		-d "$stage" <"$patch_file" >/dev/null 2>&1; then
		:
	else
		echo "error: patch is partially applied or has a missing anchor: $patch_name" >&2
		exit 1
	fi
	: >"$marker"
done

if diff -qr -- "$driver_dir" "$stage" >/dev/null; then
	rm -rf -- "$transaction"
	trap - EXIT INT TERM
	echo "dpu table sideband overlay is up to date: $driver_dir"
	exit 0
fi

swap_started=true
commit_rename "$driver_dir" "$backup"
commit_rename "$stage" "$driver_dir"
swap_started=false

rm -rf -- "$transaction"
trap - EXIT INT TERM
echo "dpu table sideband overlay is up to date: $driver_dir"
