#!/usr/bin/env bash
set -eux

VERSION="${1:-14.0}"
ROOTFS="${2:-ufs}" # ufs or zfs
ZROOT=zbuildroot
RAW_IMAGE=final.raw
CHROOT_PATH=/mnt

function create_disk {
    if [ ${ROOTFS} = "zfs" ]; then
        gptboot=/boot/gptzfsboot
    else
        gptboot=/boot/gptboot
    fi

    dd if=/dev/zero of=$RAW_IMAGE bs=1M count=6144
    md_dev=$(mdconfig -a -t vnode -f $RAW_IMAGE)
    gpart create -s gpt ${md_dev}
    gpart add -t freebsd-boot -s 1024 ${md_dev}
    gpart bootcode -b /boot/pmbr -p ${gptboot} -i 1 ${md_dev}
    gpart add -t efi -s 200M ${md_dev}
    gpart add -s 1G -l swapfs -t freebsd-swap ${md_dev}
    gpart add -t freebsd-${ROOTFS} -l rootfs ${md_dev}
    newfs_msdos -F 32 -c 1 /dev/${md_dev}p2
    mount -t msdosfs /dev/${md_dev}p2 /mnt
    mkdir -p $CHROOT_PATH/EFI/BOOT
    cp /boot/loader.efi $CHROOT_PATH/EFI/BOOT/BOOTX64.efi
    umount $CHROOT_PATH


    if [ ${ROOTFS} = "zfs" ]; then
        zpool create -o altroot=$CHROOT_PATH $ZROOT ${md_dev}p4
        zfs set compress=on $ZROOT
        zfs create -o mountpoint=none                                  $ZROOT/ROOT
        zfs create -o mountpoint=/ -o canmount=noauto                  $ZROOT/ROOT/default
        mount -t zfs $ZROOT/ROOT/default $CHROOT_PATH
        zpool set bootfs=$ZROOT/ROOT/default $ZROOT
    else
        newfs -U -L FreeBSD /dev/${md_dev}p4
        mount /dev/${md_dev}p4 $CHROOT_PATH
    fi

}

function close_disk {
    # clean
    umount $CHROOT_PATH/dev
    rm -rf $CHROOT_PATH/tmp/*
    echo "" > $CHROOT_PATH/etc/resolv.conf

    if [ ${ROOTFS} = "zfs" ]; then
        echo 'zfs_load="YES"' >> $CHROOT_PATH/boot/loader.conf
        echo "vfs.root.mountfrom=\"zfs:${ZROOT}/ROOT/default\"" >> $CHROOT_PATH/boot/loader.conf
        echo 'zfs_enable="YES"' >> $CHROOT_PATH/etc/rc.conf

        echo 'growpart:
   mode: auto
   devices:
      - /dev/vtbd0p4
      - /
' >> $CHROOT_PATH/usr/local/etc/cloud/cloud.cfg

        ls $CHROOT_PATH
        zfs umount $CHROOT_PATH
        zfs umount $CHROOT_PATH/$ZROOT
        zpool export $ZROOT
    else
        umount /dev/${md_dev}p4
    fi
    mdconfig -du ${md_dev}
}

function install_base_layer {
    curl -L ${BASE_URL}/base.txz | tar vxf - -C $CHROOT_PATH
    curl -L ${BASE_URL}/kernel.txz | tar vxf - -C $CHROOT_PATH

    cp /etc/resolv.conf $CHROOT_PATH/etc/resolv.conf
    mount -t devfs devfs $CHROOT_PATH/dev
}

function install_packages {
    chroot $CHROOT_PATH pkg install -y \
	    ca_root_nss \
	    python3 \
	    qemu-guest-agent \
	    py39-cloud-init \
	    py39-virtualenv \
	    zsh \
	    ohmyzsh \
	    powerline-fonts \
	    git \
	    vim
    chroot $CHROOT_PATH pkg clean --all -y
    # zsh
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git $CHROOT_PATH/usr/local/share/ohmyzsh/custom/themes/powerlevel10k
}

function configure_packages {
    # /etc/rc.conf
    touch $CHROOT_PATH/etc/rc.conf
    echo 'sshd_enable="YES"' >> $CHROOT_PATH/etc/rc.conf
    echo 'sendmail_enable="NONE"' >> $CHROOT_PATH/etc/rc.conf
    echo 'cloudinit_enable="YES"' >> $CHROOT_PATH/etc/rc.conf
    echo 'qemu_guest_agent_enable="YES"' >> $CHROOT_PATH/etc/rc.conf
    echo 'qemu_guest_agent_flags="-d -v -l /var/log/qemu-ga.log"' >> $CHROOT_PATH/etc/rc.conf

    # /etc/fstab
    if [ "$ROOTFS" == "ufs" ]; then
	echo '/dev/gpt/rootfs   /       ufs     rw      1       1' >>  $CHROOT_PATH/etc/fstab
    fi
    echo '/dev/gpt/swapfs  none    swap    sw      0       0' >> $CHROOT_PATH/etc/fstab

    # bootloader
    echo 'boot_multicons="YES"' >> $CHROOT_PATH/boot/loader.conf
    echo 'boot_serial="YES"' >> $CHROOT_PATH/boot/loader.conf
    echo 'comconsole_speed="115200"' >> $CHROOT_PATH/boot/loader.conf
    echo 'autoboot_delay="1"' >> $CHROOT_PATH/boot/loader.conf
    echo 'console="comconsole,efi"' >> $CHROOT_PATH/boot/loader.conf
    echo '-P' >> $CHROOT_PATH/boot.config

    # Lock root account
    chroot $CHROOT_PATH pw mod user root -w no

    # cloud-init
    sed -i '' "s|/bin/tcsh|/usr/local/bin/zsh|g" $CHROOT_PATH/usr/local/etc/cloud/cloud.cfg

    # zsh
    chroot $CHROOT_PATH ln -s /usr/local/share/ohmyzsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme /usr/local/share/ohmyzsh/themes/powerlevel10k.zsh-theme
    chroot $CHROOT_PATH chsh -s /usr/local/bin/zsh root
    cp skel/dot.zshrc $CHROOT_PATH/root/.zshrc
    cp skel/dot.p10k.zsh $CHROOT_PATH/root/.p10k.zsh
    chown root:wheel $CHROOT_PATH/root/.*
    cp skel/dot.zshrc $CHROOT_PATH/usr/share/skel/dot.zshrc    
    cp skel/dot.p10k.zsh $CHROOT_PATH/usr/share/skel/dot.p10k.zsh
    chown root:wheel $CHROOT_PATH/usr/share/skel/dot.*
}

function build {
    BASE_URL="http://ftp5.de.freebsd.org/freebsd/snapshots/amd64/${VERSION}-STABLE"
    ALT_BASE_URL="http://ftp5.de.freebsd.org/freebsd/snapshots/amd64/${VERSION}-CURRENT"
    ARCHIVE_BASE_URL="http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/amd64/${VERSION}-RELEASE"

    if ! curl --fail --silent -L $BASE_URL; then
        BASE_URL=$ALT_BASE_URL
	if ! curl --fail --silent -L $BASE_URL; then
	    BASE_URL=$ARCHIVE_BASE_URL
	    if ! curl --fail --silent -L $BASE_URL; then
		echo "Version ${VERSION} not found ... abort!"
		exit 1;
            fi
	fi
    fi
    
    # call function create disk
    create_disk

    # extract basics and install some packages
    install_base_layer
    install_packages
    configure_packages
    
    echo "/etc/rc.conf"
    echo "***"
    cat $CHROOT_PATH/etc/rc.conf
    echo "***"

    # call post hook for disk setup
    close_disk
}

build
qemu-img convert -f raw -O qcow2 $RAW_IMAGE -c FreeBSD-$(basename $BASE_URL)-amd64-$ROOTFS-openstack.qcow2
rm $RAW_IMAGE
