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
	"$overlay_dir/cosim_table_batch_core.h"
	"$overlay_dir/cosim_table_frontdoor_throttle_core.h"
	"$repo/bridge/table/cosim_table_ctrl_uapi.h"
	"$repo/bridge/table/cosim_table_protocol.h"
)
for source in "${sources[@]}"; do
	if [[ -L "$source" || ! -f "$source" ]]; then
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

path_is_safe()
{
	local path=$1 component
	local -a components

	if [[ -z "$path" || "$path" == /* || "$path" == */ ||
	      "$path" == *//* || "$path" =~ [[:space:]] ]]; then
		return 1
	fi
	IFS=/ read -r -a components <<<"$path"
	for component in "${components[@]}"; do
		if [[ -z "$component" || "$component" == . || "$component" == .. ]]; then
			return 1
		fi
	done
}

declare -A managed_path_set=()
for source in "${sources[@]}"; do
	managed_path_set["$(basename "$source")"]=1
done
marker_rel=.cosim-table-sideband-applied
managed_path_set["$marker_rel"]=1
for patch_file in "${patches[@]}"; do
	patch_name=$(basename "$patch_file")
	marker_path="$marker_rel/$patch_name.applied"
	path_is_safe "$marker_path" || {
		echo "error: unsafe overlay marker path: $marker_path" >&2
		exit 1
	}
	managed_path_set["$marker_path"]=1
	while IFS= read -r header; do
		case "$header" in
			'--- '*|'+++ '*) patch_path=${header:4} ;;
			*) continue ;;
		esac
		if [[ "$patch_path" == /dev/null ]]; then
			continue
		fi
		if ! path_is_safe "$patch_path" || [[ "$patch_path" != */* ]]; then
			echo "error: unsafe path in overlay patch: $patch_path" >&2
			exit 1
		fi
		managed_path=${patch_path#*/}
		if ! path_is_safe "$managed_path"; then
			echo "error: unsafe managed path in overlay patch: $patch_path" >&2
			exit 1
		fi
		managed_path_set["$managed_path"]=1
	done <"$patch_file"
done
managed_paths=("${!managed_path_set[@]}")

validate_managed_path()
{
	local root=$1 relative=$2 root_real target cursor component index
	local -a components

	if ! path_is_safe "$relative"; then
		echo "error: unsafe managed path: $relative" >&2
		return 1
	fi
	if [[ -L "$root" || ! -d "$root" ]]; then
		echo "error: managed root is not a real directory: $root" >&2
		return 1
	fi
	root_real=$(realpath -e -- "$root") || return 1
	target=$(realpath -m -- "$root/$relative") || return 1
	case "$target" in
		"$root_real"/*) ;;
		*)
			echo "error: managed path escapes its root: $relative" >&2
			return 1
			;;
	esac

	cursor=$root
	IFS=/ read -r -a components <<<"$relative"
	for index in "${!components[@]}"; do
		component=${components[$index]}
		cursor="$cursor/$component"
		if [[ -L "$cursor" ]]; then
			echo "error: managed path contains a symlink: $relative" >&2
			return 1
		fi
		if ((index + 1 < ${#components[@]})) &&
		   [[ -e "$cursor" && ! -d "$cursor" ]]; then
			echo "error: managed path parent is not a directory: $relative" >&2
			return 1
		fi
	done
}

validate_managed_tree()
{
	local root=$1 relative

	for relative in "${managed_paths[@]}"; do
		validate_managed_path "$root" "$relative"
	done
}

atomic_copy()
{
	local source=$1 root=$2 relative=$3 parent temporary

	validate_managed_path "$root" "$relative"
	parent="$root/$(dirname "$relative")"
	temporary=$(mktemp "$parent/.cosim-table-write.XXXXXX")
	cp -p -- "$source" "$temporary"
	validate_managed_path "$root" "$relative"
	mv -T -- "$temporary" "$root/$relative"
}

atomic_empty_file()
{
	local root=$1 relative=$2 parent temporary

	validate_managed_path "$root" "$relative"
	parent="$root/$(dirname "$relative")"
	temporary=$(mktemp "$parent/.cosim-table-write.XXXXXX")
	validate_managed_path "$root" "$relative"
	mv -T -- "$temporary" "$root/$relative"
}

validate_managed_tree "$driver_dir"

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
validate_managed_tree "$stage"
staged_files=0
for source in "${sources[@]}"; do
	atomic_copy "$source" "$stage" "$(basename "$source")"
	staged_files=$((staged_files + 1))
	if [[ ${COSIM_TABLE_FAIL_AFTER_STAGE_FILE:-0} -eq $staged_files ]]; then
		echo "error: injected failure after staged file $staged_files" >&2
		exit 99
	fi
done

marker_dir="$stage/.cosim-table-sideband-applied"
validate_managed_path "$stage" "$marker_rel"
if [[ -e "$marker_dir" ]]; then
	if [[ ! -d "$marker_dir" ]]; then
		echo "error: overlay marker path is not a directory: $marker_rel" >&2
		exit 1
	fi
else
	mkdir -- "$marker_dir"
fi
audit="$transaction/audit"
cp -a -- "$stage" "$audit"
validate_managed_tree "$audit"
declare -a patch_applied=()
for ((index = ${#patches[@]} - 1; index >= 0; index--)); do
	patch_file=${patches[$index]}
	patch_name=$(basename "$patch_file")
	validate_managed_tree "$audit"
	if patch --batch --force --binary --fuzz=0 --reverse --dry-run -p1 \
		-d "$audit" <"$patch_file" >/dev/null 2>&1; then
		patch --batch --force --binary --fuzz=0 --reverse -p1 \
			-d "$audit" <"$patch_file" >/dev/null
		patch_applied[$index]=true
	else
		patch_applied[$index]=false
	fi
	validate_managed_tree "$audit"
done

applied_prefix_ended=false
for index in "${!patches[@]}"; do
	patch_file=${patches[$index]}
	patch_name=$(basename "$patch_file")
	marker="$marker_dir/$patch_name.applied"
	if [[ ${patch_applied[$index]} == true ]]; then
		if $applied_prefix_ended; then
			echo "error: applied patch stack is not a contiguous prefix: $patch_name" >&2
			exit 1
		fi
	elif [[ -f "$marker" ]]; then
		echo "error: marker does not match applied patch: $patch_name" >&2
		exit 1
	else
		applied_prefix_ended=true
	fi
done

for index in "${!patches[@]}"; do
	patch_file=${patches[$index]}
	patch_name=$(basename "$patch_file")
	validate_managed_tree "$audit"
	if ! patch --batch --binary --fuzz=0 --forward --dry-run -p1 \
		-d "$audit" <"$patch_file" >/dev/null 2>&1; then
		echo "error: patch is partially applied or has a missing anchor: $patch_name" >&2
		exit 1
	fi
	patch --batch --binary --fuzz=0 --forward -p1 \
		-d "$audit" <"$patch_file" >/dev/null
	validate_managed_tree "$audit"
done

for index in "${!patches[@]}"; do
	patch_file=${patches[$index]}
	patch_name=$(basename "$patch_file")
	marker="$marker_dir/$patch_name.applied"
	marker_path="$marker_rel/$patch_name.applied"
	validate_managed_tree "$stage"
	if [[ ${patch_applied[$index]} == true ]]; then
		if [[ ! -f "$marker" ]]; then
			atomic_empty_file "$stage" "$marker_path"
		fi
		continue
	fi
	if ! patch --batch --binary --fuzz=0 --forward --dry-run -p1 \
		-d "$stage" <"$patch_file" >/dev/null 2>&1; then
		echo "error: audited patch state changed before apply: $patch_name" >&2
		exit 1
	fi
	patch --batch --binary --fuzz=0 --forward -p1 \
		-d "$stage" <"$patch_file" >/dev/null
	validate_managed_tree "$stage"
	atomic_empty_file "$stage" "$marker_path"
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
