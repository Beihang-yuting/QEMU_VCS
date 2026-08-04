#!/usr/bin/env bash
# Provision a Guest rootfs with a loopback-only QEMU management SSH service.
#
# The management password is intentionally accepted only through the
# COSIM_GUEST_SSH_PASSWORD environment variable.  Do not put it on a command
# line, in a Make variable, or in an archive manifest.
set -euo pipefail

rootfs=''
guest_user='ryan'
dry_run=false
mount_dir=''
mounted_root=false
mounted_dev=false
mounted_devpts=false
mounted_proc=false
mounted_sys=false

usage() {
    cat <<'USAGE'
Usage:
  COSIM_GUEST_SSH_PASSWORD=... scripts/provision_guest_ssh.sh --rootfs IMAGE [--user USER]
  COSIM_GUEST_SSH_PASSWORD=... scripts/provision_guest_ssh.sh --dry-run --rootfs IMAGE [--user USER]

Provision a Debian/Ubuntu Guest image with openssh-server, sudo, DHCP for the
QEMU e1000e management NIC, and a non-root management user.

The password is read only from COSIM_GUEST_SSH_PASSWORD and is never printed.
--dry-run validates arguments and prints the planned package/configuration
names without mounting IMAGE or requiring root privileges.
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

run_root() {
    if [ "${EUID}" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

cleanup() {
    local status=$?
    set +e
    if [ -n "$mount_dir" ]; then
        run_root rm -f "$mount_dir/usr/sbin/policy-rc.d"
        if "$mounted_sys"; then run_root umount "$mount_dir/sys"; fi
        if "$mounted_proc"; then run_root umount "$mount_dir/proc"; fi
        if "$mounted_devpts"; then run_root umount "$mount_dir/dev/pts"; fi
        if "$mounted_dev"; then run_root umount "$mount_dir/dev"; fi
        if "$mounted_root"; then run_root umount "$mount_dir"; fi
        rmdir "$mount_dir" 2>/dev/null || true
    fi
    exit "$status"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --rootfs)
            [ "$#" -ge 2 ] || fail '--rootfs requires an image path'
            rootfs=$2
            shift 2
            ;;
        --user)
            [ "$#" -ge 2 ] || fail '--user requires a name'
            guest_user=$2
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

password="${COSIM_GUEST_SSH_PASSWORD:-}"
[ -n "$password" ] || fail 'COSIM_GUEST_SSH_PASSWORD must be set'
[ -n "$rootfs" ] || fail '--rootfs is required'
[[ "$guest_user" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || fail 'invalid guest user'

if "$dry_run"; then
    cat <<EOF
Would install: openssh-server sudo
Would write: /etc/systemd/network/10-cosim-management.network
[Match]
Driver=e1000e
[Network]
DHCP=yes
LinkLocalAddressing=no
Would write: /etc/ssh/sshd_config.d/99-cosim-management.conf
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers ${guest_user}
Would enable: systemd-networkd.service ssh.service
EOF
    exit 0
fi

[ -f "$rootfs" ] || fail "rootfs is not a regular file: $rootfs"
command -v sudo >/dev/null 2>&1 || [ "${EUID}" -eq 0 ] || fail 'sudo is required'
command -v mount >/dev/null 2>&1 || fail 'mount is required'
command -v chroot >/dev/null 2>&1 || fail 'chroot is required'
command -v systemctl >/dev/null 2>&1 || fail 'systemctl is required'

mount_dir=$(mktemp -d "${TMPDIR:-/tmp}/cosim-guest-ssh.XXXXXX")
trap cleanup EXIT INT TERM

run_root mount -o loop "$rootfs" "$mount_dir"
mounted_root=true
run_root mount --bind /dev "$mount_dir/dev"
mounted_dev=true
run_root mount --bind /dev/pts "$mount_dir/dev/pts"
mounted_devpts=true
run_root mount --bind /proc "$mount_dir/proc"
mounted_proc=true
run_root mount --bind /sys "$mount_dir/sys"
mounted_sys=true

# Use the builder's resolver while apt accesses the Guest package repository.
run_root cp --remove-destination /etc/resolv.conf "$mount_dir/etc/resolv.conf"

run_root tee "$mount_dir/usr/sbin/policy-rc.d" >/dev/null <<'POLICY'
#!/bin/sh
exit 101
POLICY
run_root chmod 0755 "$mount_dir/usr/sbin/policy-rc.d"

run_root chroot "$mount_dir" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
run_root chroot "$mount_dir" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends openssh-server sudo
run_root rm -f "$mount_dir/usr/sbin/policy-rc.d"

if ! run_root chroot "$mount_dir" id -u "$guest_user" >/dev/null 2>&1; then
    run_root chroot "$mount_dir" useradd --create-home --shell /bin/bash "$guest_user"
fi
printf '%s:%s\n' "$guest_user" "$password" | run_root chroot "$mount_dir" chpasswd
run_root chroot "$mount_dir" usermod --append --groups sudo "$guest_user"

run_root install -d -m 0755 "$mount_dir/etc/systemd/network" "$mount_dir/etc/ssh/sshd_config.d"
run_root tee "$mount_dir/etc/systemd/network/10-cosim-management.network" >/dev/null <<'NETWORK'
[Match]
Driver=e1000e

[Network]
DHCP=yes
LinkLocalAddressing=no
NETWORK
run_root tee "$mount_dir/etc/ssh/sshd_config.d/99-cosim-management.conf" >/dev/null <<EOF
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers ${guest_user}
EOF

run_root chroot "$mount_dir" ssh-keygen -A
run_root install -d -m 0755 "$mount_dir/run/sshd"
run_root chroot "$mount_dir" sshd -t
run_root systemctl --root="$mount_dir" enable systemd-networkd.service
run_root systemctl --root="$mount_dir" enable ssh.service

echo "Provisioned SSH/SCP management service in $rootfs for user $guest_user"
