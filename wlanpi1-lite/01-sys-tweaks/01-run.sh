#!/bin/bash -e

install -m 755 files/resize2fs_once	"${ROOTFS_DIR}/etc/init.d/"

install -m 644 files/50raspi		"${ROOTFS_DIR}/etc/apt/apt.conf.d/"

install -m 644 files/console-setup   	"${ROOTFS_DIR}/etc/default/"

on_chroot << EOF
systemctl disable hwclock.sh
systemctl disable nfs-common
systemctl disable rpcbind
if [ "${ENABLE_SSH}" == "1" ]; then
	systemctl enable ssh
else
	systemctl disable ssh
fi
systemctl enable regenerate_ssh_host_keys
EOF

if [ "${USE_QEMU}" = "1" ]; then
	echo "enter QEMU mode"
	install -m 644 files/90-qemu.rules "${ROOTFS_DIR}/etc/udev/rules.d/"
	on_chroot << EOF
systemctl disable resize2fs_once
EOF
	echo "leaving QEMU mode"
else
	on_chroot << EOF
systemctl enable resize2fs_once
EOF
fi

on_chroot <<EOF
for GRP in input spi i2c gpio netdev; do
	groupadd -f -r "\$GRP"
done
for GRP in adm dialout cdrom audio users sudo video games plugdev input gpio spi i2c netdev render; do
  adduser $FIRST_USER_NAME \$GRP
done
EOF

if [ -f "${ROOTFS_DIR}/etc/sudoers.d/010_pi-nopasswd" ]; then
  sed -i "s/^pi /$FIRST_USER_NAME /" "${ROOTFS_DIR}/etc/sudoers.d/010_pi-nopasswd"
fi

on_chroot << EOF
setupcon --force --save-only -v
EOF

on_chroot << EOF
usermod --pass='*' root
EOF

rm -f "${ROOTFS_DIR}/etc/ssh/"ssh_host_*_key*

sed -i "s/PLACEHOLDER//" "${ROOTFS_DIR}/etc/default/keyboard"
on_chroot << EOF
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure keyboard-configuration
EOF

#########
# tmpfs #
#########

echo "tmpfs /tmp tmpfs defaults,relatime,nosuid,nodev,size=32M 0 0" >> "${ROOTFS_DIR}/etc/fstab"

###########
# logging #
###########

mkdir -p "${ROOTFS_DIR}/var/log/persistent"
mkdir -p "${ROOTFS_DIR}/var/log/critical"

echo "tmpfs /var/log/critical tmpfs defaults,relatime,nosuid,nodev,noexec,mode=0755,size=2M 0 0" >> "${ROOTFS_DIR}/etc/fstab"

cat > "${ROOTFS_DIR}/usr/local/bin/critical-log" << 'EOF'
#!/bin/bash
TMPFS_LOG="/var/log/critical/system.log"

if [ -f "$TMPFS_LOG" ] && [ $(stat -c%s "$TMPFS_LOG" 2>/dev/null || echo 0) -gt 100000 ]; then
    tail -50 "$TMPFS_LOG" > "$TMPFS_LOG.tmp" && mv "$TMPFS_LOG.tmp" "$TMPFS_LOG"
fi

echo "$(date): $*" >> "$TMPFS_LOG"
EOF

chmod +x "${ROOTFS_DIR}/usr/local/bin/critical-log"

# 1 MB
cat > "${ROOTFS_DIR}/usr/local/bin/sync-critical-logs" << 'EOF'
#!/bin/bash
TMPFS_LOG="/var/log/critical/system.log"
PERSISTENT_LOG="/var/log/persistent/system.log"

if [ -f "$TMPFS_LOG" ] && [ -s "$TMPFS_LOG" ]; then
    if [ -f "$PERSISTENT_LOG" ] && [ $(stat -c%s "$PERSISTENT_LOG" 2>/dev/null || echo 0) -gt 50000 ]; then
        tail -20 "$PERSISTENT_LOG" > "$PERSISTENT_LOG.tmp" && mv "$PERSISTENT_LOG.tmp" "$PERSISTENT_LOG"
    fi
    
    cat "$TMPFS_LOG" >> "$PERSISTENT_LOG"
    > "$TMPFS_LOG"
fi
EOF

chmod +x "${ROOTFS_DIR}/usr/local/bin/sync-critical-logs"

# sync logs every minute
cat > "${ROOTFS_DIR}/etc/cron.d/critical-log-sync" << 'EOF'
*/1 * * * * root /usr/local/bin/sync-critical-logs
EOF

# usage examples

# 1. log a critical event
# /usr/local/bin/critical-log "System temperature exceeded 80°C"
# 2. variables

# TEMP=$(vcgencmd measure_temp | cut -d= -f2)
# /usr/local/bin/critical-log "CPU temperature: $TEMP"

# 3. service failures
# /usr/local/bin/critical-log "WiFi connection failed after 3 attempts"

# 4. in script
# if ! systemctl is-active --quiet ssh; then
#     /usr/local/bin/critical-log "SSH service is down"
#     systemctl restart ssh
# fi

# viewing examples

# 1. current logs in tmpfs
# cat /var/log/critical/system.log

# 2. persistent logs (complete history)
# cat /var/log/persistent/system.log

#############
# logrotate #
#############

# TODO

##################
# journal tweaks #
##################

# make journal tmpfs
echo "tmpfs /var/log/journal tmpfs defaults,relatime,nosuid,nodev,noexec,mode=0755,size=16M 0 0" >> "${ROOTFS_DIR}/etc/fstab"

mkdir -p "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
cat > "${ROOTFS_DIR}/etc/systemd/journald.conf.d/99-volatile.conf" << EOF
[Journal]
Storage=volatile
RuntimeMaxUse=4M
RuntimeMaxFileSize=500K
RuntimeMaxFiles=3
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
# Don't wait for shutdown
SyncIntervalSec=1
RateLimitInterval=5s
RateLimitBurst=100
EOF

#################
# kernel tweaks #
#################

# Tweak when kernel flushes dirty pages from RAM to storage
# Reduce write frequency by batching more per write operation
# Reduce kernel message verbosity
cat >> "${ROOTFS_DIR}/etc/sysctl.d/99-eMMC-tuning.conf" << EOF
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
kernel.printk = 1 4 1 3
EOF
