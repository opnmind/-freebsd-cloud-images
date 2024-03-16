#!/usr/bin/env bash
set -eux

version="${1:-14.0}"
root_fs="${2:-ufs}" # ufs or zfs
debug=${3:-false}

install_media="${install_media:-http}"
zroot_name=zbuildroot
raw_file=final.raw


function create_disk {
    if [ ${root_fs} = "zfs" ]; then
        gptboot=/boot/gptzfsboot
    else
        gptboot=/boot/gptboot
    fi

    dd if=/dev/zero of=$raw_file bs=1M count=6144
    md_dev=$(mdconfig -a -t vnode -f $raw_file)
    gpart create -s gpt ${md_dev}
    gpart add -t freebsd-boot -s 1024 ${md_dev}
    gpart bootcode -b /boot/pmbr -p ${gptboot} -i 1 ${md_dev}
    gpart add -t efi -s 200M ${md_dev}
    gpart add -s 1G -l swapfs -t freebsd-swap ${md_dev}
    gpart add -t freebsd-${root_fs} -l rootfs ${md_dev}
    newfs_msdos -F 32 -c 1 /dev/${md_dev}p2
    mount -t msdosfs /dev/${md_dev}p2 /mnt
    mkdir -p /mnt/EFI/BOOT
    cp /boot/loader.efi /mnt/EFI/BOOT/BOOTX64.efi
    umount /mnt


    if [ ${root_fs} = "zfs" ]; then
        zpool create -o altroot=/mnt $zroot_name ${md_dev}p4
        zfs set compress=on  $zroot_name
        zfs create -o mountpoint=none                                  $zroot_name/ROOT
        zfs create -o mountpoint=/ -o canmount=noauto                  $zroot_name/ROOT/default
        mount -t zfs $zroot_name/ROOT/default /mnt
        zpool set bootfs=$zroot_name/ROOT/default $zroot_name
    else
        newfs -U -L FreeBSD /dev/${md_dev}p4
        mount /dev/${md_dev}p4 /mnt
    fi

}

function close_disk {
    if [ ${root_fs} = "zfs" ]; then
        echo 'zfs_load="YES"' >> /mnt/boot/loader.conf
        echo "vfs.root.mountfrom=\"zfs:${zroot_name}/ROOT/default\"" >> /mnt/boot/loader.conf
        echo 'zfs_enable="YES"' >> /mnt/etc/rc.conf

        echo 'growpart:
   mode: auto
   devices:
      - /dev/vtbd0p4
      - /
' >> /mnt/usr/local/etc/cloud/cloud.cfg

        ls /mnt
        ls /mnt/sbin
        ls /mnt/sbin/init
        zfs umount /mnt
        zfs umount /mnt/$zroot_name
        zpool export $zroot_name
    else
        umount /dev/${md_dev}p4
    fi
    mdconfig -du ${md_dev}
}

function install_base_layer {
    curl -L ${BASE_URL}/base.txz | tar vxf - -C /mnt
    curl -L ${BASE_URL}/kernel.txz | tar vxf - -C /mnt

    cp /etc/resolv.conf /mnt/etc/resolv.conf
    mount -t devfs devfs /mnt/dev    
    chroot /mnt /bin/sh
    pkg install -y ca_root_nss
    exit
}

function build {
    VERSION=$version
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
    exit

    cp skel/dot.zshrc /mnt/usr/share/skel/dot.zshrc 
    cp skel/dot.p10k.zsh /mnt/usr/share/skel/dot.p10k.zsh
    chown root:wheel /mnt/usr/share/skel/dot.*

    echo "
export ASSUME_ALWAYS_YES=YES
cd /tmp
pkg install -y ca_root_nss
pkg install -y python3 qemu-guest-agent
pkg install -y py39-cloud-init py39-virtualenv
pkg install -y zsh ohmyzsh powerline-fonts vim git
pkg clean --all -y
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git /usr/local/share/ohmyzsh/custom/themes/powerlevel10k
ln -s /usr/local/share/ohmyzsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme /usr/local/share/ohmyzsh/themes/powerlevel10k.zsh-theme
chsh -s /usr/local/bin/zsh root

touch /etc/rc.conf
./tools/build-on-freebsd
" > /mnt/tmp/cloudify.sh

    if [ -z "${debug}" ]; then # Lock root account
        echo "pw mod user root -w no" >> /mnt/tmp/cloudify.sh
    else
        echo 'echo "!234AaAa56" | pw usermod -n root -h 0' >> /mnt/tmp/cloudify.sh
    fi

    chmod +x /mnt/tmp/cloudify.sh

    cp /etc/resolv.conf /mnt/etc/resolv.conf
    mount -t devfs devfs /mnt/dev
    chroot /mnt /tmp/cloudify.sh
    umount /mnt/dev
    rm /mnt/tmp/cloudify.sh
    echo '' > /mnt/etc/resolv.conf
    if [ ${root_fs} = "ufs" ]; then
        echo '/dev/gpt/rootfs   /       ufs     rw      1       1' >>  /mnt/etc/fstab
    fi
    echo '/dev/gpt/swapfs  none    swap    sw      0       0' >> /mnt/etc/fstab

    echo 'boot_multicons="YES"' >> /mnt/boot/loader.conf
    echo 'boot_serial="YES"' >> /mnt/boot/loader.conf
    echo 'comconsole_speed="115200"' >> /mnt/boot/loader.conf
    echo 'autoboot_delay="1"' >> /mnt/boot/loader.conf
    echo 'console="comconsole,efi"' >> /mnt/boot/loader.conf
    echo '-P' >> /mnt/boot.config
    rm -rf /mnt/tmp/*
    echo 'sshd_enable="YES"' >> /mnt/etc/rc.conf
    echo 'sendmail_enable="NONE"' >> /mnt/etc/rc.conf
    echo 'cloudinit_enable="YES"' >> /mnt/etc/rc.conf
    echo 'qemu_guest_agent_enable="YES"' >> /mnt/etc/rc.conf
    echo 'qemu_guest_agent_flags="-d -v -l /var/log/qemu-ga.log"' >> /mnt/etc/rc.conf
    
    sed -i '' "s|/bin/tcsh|/usr/local/bin/zsh|g" /mnt/usr/local/etc/cloud/cloud.cfg

    echo "/etc/rc.conf"
    echo "***"
    cat /mnt/etc/rc.conf
    echo "***"


    # call post hook for disk setup
    close_disk
}

build $version
qemu-img convert -f raw -O qcow2 $raw_file -c FreeBSD-$(basename $BASE_URL)-amd64-$root_fs-openstack.qcow2
rm $raw_file
