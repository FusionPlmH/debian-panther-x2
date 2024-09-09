#!/bin/sh


set -e
CURRENT_DIR=$(pwd)

# script exit codes:
#   1: missing utility
#   2: download failure
#   3: image mount failure
#   4: missing file
#   5: invalid file hash
#   9: superuser required

main() {
    # file media is sized with the number between 'mmc_' and '.img'
    #   use 'm' for 1024^2 and 'g' for 1024^3
    local media='mmc_2g.img' # or block device '/dev/sdX'
    local deb_dist='bookworm'
    local hostname='panther-x2-arm64'
    local acct_uid='debian'
    local acct_pass='debian'
    local extra_pkgs='curl, pciutils, sudo, unzip, wget, xxd, xz-utils, zip, zstd'


    if is_param 'clean' "$@"; then
        rm -rf cache*/var
        rm -f "$media"*
        rm -rf "$mountpt"
        rm -rf rootfs
        echo '\nclean complete\n'
        exit 0
    fi

    check_installed 'debootstrap' 'wget' 'xz-utils'

    if [ -f "$media" ]; then
        read -p "file $media exists, overwrite? <y/N> " yn
        if ! [ "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo 'exiting...'
            exit 0
        fi
    fi

    # no compression if disabled or n media
    local compress=$(is_param 'nocomp' "$@" || [ -b "$media" ] && echo false || echo true)

    if $compress && [ -f "$media.xz" ]; then
        read -p "file $media.xz exists, overwrite? <y/N> " yn
        if ! [ "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo 'exiting...'
            exit 0
        fi
    fi

    print_hdr "downloading files"
    local cache="cache.$deb_dist"

    # linux firmware
    local lfw=$(download "$cache" 'https://mirrors.edge.kernel.org/pub/linux/kernel/firmware/linux-firmware-20240811.tar.xz')

    # u-boot
    local uboot_spl=$(download "$cache" 'https://github.com/ophub/u-boot/blob/main/u-boot/rockchip/panther-x2/idbloader.img')
    [ -f "$uboot_spl" ] || { echo "unable to fetch $uboot_spl"; exit 4; }
    local uboot_itb=$(download "$cache" 'https://github.com/ophub/u-boot/blob/main/u-boot/rockchip/panther-x2/u-boot.itb')
    [ -f "$uboot_itb" ] || { echo "unable to fetch: $uboot_itb"; exit 4; }

    # dtb
    local dtb=$(download "$cache" "https://github.com/ophub/amlogic-s9xxx-armbian/blob/main/build-armbian/armbian-files/platform-files/rockchip/bootfs/dtb/rockchip/rk3566-panther-x2.dtb")
    [ -f "$dtb" ] || { echo "unable to fetch $dtb"; exit 4; }

    # setup media
    if [ ! -b "$media" ]; then
        print_hdr "creating image file"
        make_image_file "$media"
    fi

    print_hdr "partitioning media"
    parition_media "$media"

    print_hdr "formatting media"
    format_media "$media"

    print_hdr "mounting media"
    mount_media "$media"

    print_hdr "configuring files"
    mkdir "$mountpt/etc"
    echo 'link_in_boot = 1' > "$mountpt/etc/kernel-img.conf"
    echo 'do_symlinks = 0' >> "$mountpt/etc/kernel-img.conf"




    print_hdr "installing firmware"
    mkdir -p "$mountpt/usr/lib/firmware"
    local lfwn=$(basename "$lfw")
    local lfwbn="${lfwn%%.*}"
	tar -C "$mountpt/usr/lib/firmware" --strip-components=1 --wildcards -xavf "$lfw" \
    "$lfwbn/rockchip" \
    "$lfwbn/rtl_bt" \
    "$lfwbn/rtl_nic" \
    "$lfwbn/rtlwifi" \
    "$lfwbn/rtw88" \
    "$lfwbn/rtw89"


    # install device tree
    install -vm 644 "$dtb" "$mountpt/boot"

    # install debian linux from deb packages (debootstrap)
    print_hdr "installing root filesystem from debian.org"

    # do not write the cache to the image
    mkdir -p "$cache/var/cache" "$cache/var/lib/apt/lists"
    mkdir -p "$mountpt/var/cache" "$mountpt/var/lib/apt/lists"
    mount -o bind "$cache/var/cache" "$mountpt/var/cache"
    mount -o bind "$cache/var/lib/apt/lists" "$mountpt/var/lib/apt/lists"

    local pkgs="linux-image-arm64, dbus, dhcpcd, libpam-systemd, openssh-server, systemd-timesyncd"
    pkgs="$pkgs, rfkill, wireless-regdb, wpasupplicant"
    pkgs="$pkgs, $extra_pkgs"
    debootstrap --arch arm64 --include "$pkgs" --exclude "isc-dhcp-client" "$deb_dist" "$mountpt" 'https://deb.debian.org/debian/'

    umount "$mountpt/var/cache"
    umount "$mountpt/var/lib/apt/lists"


    # apt sources 
    cat > "$mountpt/etc/apt/sources.list" <<-EOF
    # For information about how to configure apt package sources,
    # see the sources.list(5) manual.

    deb http://deb.debian.org/debian ${deb_dist} main contrib non-free non-free-firmware
    #deb-src http://deb.debian.org/debian ${deb_dist} main contrib non-free non-free-firmware

    deb http://deb.debian.org/debian-security ${deb_dist}-security main contrib non-free non-free-firmware
    #deb-src http://deb.debian.org/debian-security ${deb_dist}-security main contrib non-free non-free-firmware

    deb http://deb.debian.org/debian ${deb_dist}-updates main contrib non-free non-free-firmware
    #deb-src http://deb.debian.org/debian ${deb_dist}-updates main contrib non-free non-free-firmware
EOF

    # Add custom support
    cp -rf files/etc/ $mountpt/
    cp -rf files/usr/ $mountpt/
    rm -rf $mountpt/etc/resolv.conf
    rm -rf $mountpt/usr/lib/systemd/resolv.conf
    cat > "$mountpt/etc/resolv.conf" <<-EOF
    nameserver 1.1.1.1
    mameserver 8.8.8.8
EOF
    cat > "$mountpt/usr/lib/systemd/resolv.conf" <<-EOF
    nameserver 1.1.1.1
    mameserver 8.8.8.8
EOF



    # hostname
    echo $hostname > "$mountpt/etc/hostname"
    sed -i "s/127.0.0.1\tlocalhost/127.0.0.1\tlocalhost\n127.0.1.1\t$hostname/" "$mountpt/etc/hosts"

    print_hdr "creating user account"
    chroot "$mountpt" /usr/sbin/useradd -m "$acct_uid" -s '/bin/bash'
    chroot "$mountpt" /bin/sh -c "/usr/bin/echo $acct_uid:$acct_pass | /usr/sbin/chpasswd -c YESCRYPT"
    chroot "$mountpt" /usr/bin/passwd -e "$acct_uid"
    (umask 377 && echo "$acct_uid ALL=(ALL) NOPASSWD: ALL" > "$mountpt/etc/sudoers.d/$acct_uid")

    print_hdr "installing rootfs expansion script to /etc/rc.local"
    install -Dvm 754 'files/rc.local' "$mountpt/etc/rc.local"

    # disable sshd until after keys are regenerated on first boot
    rm -fv "$mountpt/etc/systemd/system/sshd.service"
    rm -fv "$mountpt/etc/systemd/system/multi-user.target.wants/ssh.service"

    # generate machine id on first boot
    rm -fv "$mountpt/etc/machine-id"

    # Download the Kernel
    print_hdr "Start downloading kernel package..."

    # Download the kernel from [ releases ]
    kernel_path="$mountpt/boot"
    inputs_kernel="6.1.75"
    kernel_version_path="${kernel_path}/${inputs_kernel}"
    kernel_down_from="https://github.com/ophub/kernel/releases/download/kernel_rk35xx/${inputs_kernel}.tar.gz"
    wget "${kernel_down_from}" -o "${kernel_path}/${inputs_kernel}.tar.gz"
    tar -mxzf "${inputs_kernel}.tar.gz" -C "${kernel_path}"

    # Install kernel
    PLATFORM='rockchip'
    kernel_name="${inputs_kernel}-rk35xx-ophub"
    cd ${kernel_path}
    rm -rf config-* initrd.img-* System.map-* uInitrd-* vmlinuz-* uInitrd Image zImage dtb-*
    print_hdr "Remove old complete"

    # 01. For boot five files
    tar -mxzf $inputs_kernel/boot-${kernel_name}.tar.gz
    ln -sf uInitrd-${kernel_name} uInitrd && ln -sf vmlinuz-${kernel_name} Image
    print_hdr " (1/4) Unpacking [ boot-${kernel_name}.tar.gz ] succeeded."

    # 02. For boot/dtb/${PLATFORM}/*
    mkdir -p dtb/${PLATFORM} 
    tar -mxzf $inputs_kernel/dtb-${PLATFORM}-${kernel_name}.tar.gz -C dtb/${PLATFORM}
    ln -sf dtb /dtb-${kernel_name}
    print_hdr "(2/4) Unpacking [ dtb-${PLATFORM}-${kernel_name}.tar.gz ] succeeded."

    # 03. For /usr/src/linux-headers-${kernel_name}
    header_path="linux-headers-${kernel_name}"
    rm -rf $mountpt/usr/src/linux-headers-* 
    mkdir -p $CURRENT_DIR/rootfs/usr/src/${header_path}
    tar -mxzf $inputs_kernel/header-${kernel_name}.tar.gz -C $CURRENT_DIR/rootfs/usr/src/${header_path}
    print_hdr "(3/4) Unpacking [ header-${kernel_name}.tar.gz ] succeeded."


    # 04. For /usr/lib/modules/${kernel_name}
    rm -rf $mountpt/usr/lib/modules/*
    tar -mxzf $inputs_kernel/modules-${kernel_name}.tar.gz -C $CURRENT_DIR/rootfs/usr/lib/modules
    print_hdr "(4/4) Unpacking [ modules-${kernel_name}.tar.gz ] succeeded."


    # Delete related files
    rm -f $CURRENT_DIR/rootfs/var/lib/dpkg/info/linux-image*
    rm -rf $CURRENT_DIR/rootfs/usr/share/doc/linux-image-*
    rm -rf $CURRENT_DIR/rootfs/usr/lib/linux-image-*


	
    # setup extlinux boot
    cd $CURRENT_DIR
    install -Dvm 754 'files/dtb_cp' "$mountpt/etc/kernel/postinst.d/dtb_cp"
    install -Dvm 754 'files/dtb_rm' "$mountpt/etc/kernel/postrm.d/dtb_rm"
    install -Dvm 754 'files/mk_extlinux' "$mountpt/boot/mk_extlinux"
    ln -svf '../../../boot/mk_extlinux' "$mountpt/etc/kernel/postinst.d/update_extlinux"
    ln -svf '../../../boot/mk_extlinux' "$mountpt/etc/kernel/postrm.d/update_extlinux"
	
    ln -sf $mountpt/usr/bin $mountpt/bin
    ln -sf $mountpt/usr/lib $mountpt/lib
    ln -sf $mountpt/usr/sbin $mountpt/sbin
    ln -sf $mountpt/run/lock $mountpt/var/lock
    ln -sf $mountpt/run $mountpt/var/run
    ln -sf $mountpt/usr/share/zoneinfo/Asia/Shanghai $mountpt/etc/localtime
	
    # Delete kernel tmpfiles
    rm -rf ${kernel_path}/${inputs_kernel}.tar.gz
    rm -rf $kernel_version_path
	

	
    # reduce entropy on non-block media
    [ -b "$media" ] || fstrim -v "$mountpt"

    umount "$mountpt"
    rm -rf "$mountpt"

    print_hdr "installing u-boot"
    dd bs=4K seek=8 if="$uboot_spl" of="$media" conv=notrunc
    dd bs=4K seek=2048 if="$uboot_itb" of="$media" conv=notrunc,fsync
	


    if $compress; then
        print_hdr "compressing image file"
        xz -z8v "$media"
        echo "\n${cya}compressed image is now ready${rst}"
        echo "\n${cya}copy image to target media:${rst}"
        echo "  ${cya}sudo sh -c 'xzcat $media.xz > /dev/sdX && sync'${rst}"
    elif [ -b "$media" ]; then
        echo "\n${cya}media is now ready${rst}"
    else
        echo "\n${cya}image is now ready${rst}"
        echo "\n${cya}copy image to media:${rst}"
        echo "  ${cya}sudo sh -c 'cat $media > /dev/sdX && sync'${rst}"
    fi
	rm -rf  cache.$deb_dist $inputs_kernel.tar.gz
    echo
	
	
}

make_image_file() {
    local filename="$1"
    rm -f "$filename"*
    local size="$(echo "$filename" | sed -rn 's/.*mmc_([[:digit:]]+[m|g])\.img$/\1/p')"
    truncate -s "$size" "$filename"
}

parition_media() {
    local media="$1"

    # partition with gpt
    cat <<-EOF | sfdisk "$media"
	label: gpt
	unit: sectors
	first-lba: 2048
	part1: start=32768, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=rootfs
	EOF
    sync
}

format_media() {
    local media="$1"
    local partnum="${2:-1}"

    # create ext4 filesystem
    if [ -b "$media" ]; then
        local rdn="$(basename "$media")"
        local sbpn="$(echo /sys/block/${rdn}/${rdn}*${partnum})"
        local part="/dev/$(basename "$sbpn")"
        mkfs.ext4 -L rootfs -vO metadata_csum_seed "$part" && sync
    else
        local lodev="$(losetup -f)"
        losetup -vP "$lodev" "$media" && sync
        mkfs.ext4 -L rootfs -vO metadata_csum_seed "${lodev}p${partnum}" && sync
        losetup -vd "$lodev" && sync
    fi
}

mount_media() {
    local media="$1"
    local partnum="1"

    if [ -d "$mountpt" ]; then
        mountpoint -q "$mountpt/var/cache" && umount "$mountpt/var/cache"
        mountpoint -q "$mountpt/var/lib/apt/lists" && umount "$mountpt/var/lib/apt/lists"
        mountpoint -q "$mountpt" && umount "$mountpt"
    else
        mkdir -p "$mountpt"
    fi

    local success_msg
    if [ -b "$media" ]; then
        local rdn="$(basename "$media")"
        local sbpn="$(echo /sys/block/${rdn}/${rdn}*${partnum})"
        local part="/dev/$(basename "$sbpn")"
        mount -n "$part" "$mountpt"
        success_msg="partition ${cya}$part${rst} successfully mounted on ${cya}$mountpt${rst}"
    elif [ -f "$media" ]; then
        # hard-coded to p1
        mount -no loop,offset=16M "$media" "$mountpt"
        success_msg="media ${cya}$media${rst} partition 1 successfully mounted on ${cya}$mountpt${rst}"
    else
        echo "file not found: $media"
        exit 4
    fi

    if [ ! -d "$mountpt/lost+found" ]; then
        echo 'failed to mount the image file'
        exit 3
    fi

    echo "$success_msg"
}

check_mount_only() {
    local item img flag=false
    for item in "$@"; do
        case "$item" in
            mount) flag=true ;;
            *.img) img=$item ;;
            *.img.xz) img=$item ;;
        esac
    done
    ! $flag && return

    if [ ! -f "$img" ]; then
        if [ -z "$img" ]; then
            echo "no image file specified"
        else
            echo "file not found: ${red}$img${rst}"
        fi
        exit 3
    fi

    if [ "$img" = *.xz ]; then
        local tmp=$(basename "$img" .xz)
        if [ -f "$tmp" ]; then
            echo "compressed file ${bld}$img${rst} was specified but uncompressed file ${bld}$tmp${rst} exists..."
            echo -n "mount ${bld}$tmp${rst}"
            read -p " instead? <Y/n> " yn
            if ! [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
                echo 'exiting...'
                exit 0
            fi
            img=$tmp
        else
            echo -n "compressed file ${bld}$img${rst} was specified"
            read -p ', decompress to mount? <Y/n>' yn
            if ! [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
                echo 'exiting...'
                exit 0
            fi
            xz -dk "$img"
            img=$(basename "$img" .xz)
        fi
    fi

    echo "mounting file ${yel}$img${rst}..."
    mount_media "$img"
    trap - EXIT INT QUIT ABRT TERM
    echo "media mounted, use ${grn}sudo umount $mountpt${rst} to unmount"

    exit 0
}

# ensure inner mount points get cleaned up
on_exit() {
    if mountpoint -q "$mountpt"; then
        mountpoint -q "$mountpt/var/cache" && umount "$mountpt/var/cache"
        mountpoint -q "$mountpt/var/lib/apt/lists" && umount "$mountpt/var/lib/apt/lists"

        read -p "$mountpt is still mounted, unmount? <Y/n> " yn
        if [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo "unmounting $mountpt"
            umount "$mountpt"
            sync
            rm -rf "$mountpt"
        fi
    fi
}
mountpt='rootfs'
trap on_exit EXIT INT QUIT ABRT TERM







# download / return file from cache
download() {
    local cache="$1"
    local url="$2"

    [ -d "$cache" ] || mkdir -p "$cache"

    local filename="$(basename "$url")"
    local filepath="$cache/$filename"
    [ -f "$filepath" ] || wget "$url" -P "$cache"
    [ -f "$filepath" ] || exit 2

    echo "$filepath"
}

is_param() {
    local item match
    for item in "$@"; do
        if [ -z "$match" ]; then
            match="$item"
        elif [ "$match" = "$item" ]; then
            return 0
        fi
    done
    return 1
}

# check if debian package is installed
check_installed() {
    local item todo
    for item in "$@"; do
        dpkg -l "$item" 2>/dev/null | grep -q "ii  $item" || todo="$todo $item"
    done

    if [ ! -z "$todo" ]; then
        echo "this script requires the following packages:${bld}${yel}$todo${rst}"
        echo "   run: ${bld}${grn}sudo apt update && sudo apt -y install$todo${rst}\n"
        exit 1
    fi
}

print_hdr() {
    local msg="$1"
    echo "\n${h1}$msg...${rst}"
}

rst='\033[m'
bld='\033[1m'
red='\033[31m'
grn='\033[32m'
yel='\033[33m'
blu='\033[34m'
mag='\033[35m'
cya='\033[36m'
h1="${blu}==>${rst} ${bld}"

if [ 0 -ne $(id -u) ]; then
    echo 'this script must be run as root'
    echo "   run: ${bld}${grn}sudo sh $(basename "$0")${rst}\n"
    exit 9
fi

cd "$(dirname "$(realpath "$0")")"
check_mount_only "$@"
main "$@"
