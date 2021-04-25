#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -e -u

# Control the environment
umask 0022
export LANG="C"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-"$(date +%s)"}"

# mkarchiso defaults
app_name="${0##*/}"
pkg_list=()
quiet="y"
work_dir="work"
out_dir="out"
img_name="${app_name}.iso"
gpg_key=""
override_gpg_key=""

# profile defaults
profile=""
iso_name="${app_name}"
iso_label="${app_name^^}"
override_iso_label=""
iso_publisher="${app_name}"
override_iso_publisher=""
iso_application="${app_name} iso"
override_iso_application=""
iso_version="v1.0."
install_dir="${app_name}"
override_install_dir=""
arch="$(uname -m)"
pacman_conf="/etc/pacman.conf"
override_pacman_conf=""
bootmodes=()
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz')
declare -A file_permissions=()


# Show an INFO message
# $1: message string
_msg_info() {
    local _msg="${1}"
    [[ "${quiet}" == "y" ]] || printf '[%s] INFO: %s\n' "${app_name}" "${_msg}"
}

# Show a WARNING message
# $1: message string
_msg_warning() {
    local _msg="${1}"
    printf '[%s] WARNING: %s\n' "${app_name}" "${_msg}" >&2
}

# Show an ERROR message then exit with status
# $1: message string
# $2: exit code number (with 0 does not exit)
_msg_error() {
    local _msg="${1}"
    local _error=${2}
    printf '[%s] ERROR: %s\n' "${app_name}" "${_msg}" >&2
    if (( _error > 0 )); then
        exit "${_error}"
    fi
}

_mount_airootfs() {
    trap "_umount_airootfs" EXIT HUP INT TERM
    install -d -m 0755 -- "${work_dir}/mnt/airootfs"
    _msg_info "Mounting '${airootfs_dir}.img' on '${work_dir}/mnt/airootfs'..."
    mount -- "${airootfs_dir}.img" "${work_dir}/mnt/airootfs"
    _msg_info "Done!"
}

_umount_airootfs() {
    _msg_info "Unmounting '${work_dir}/mnt/airootfs'..."
    umount -d -- "${work_dir}/mnt/airootfs"
    _msg_info "Done!"
    rmdir -- "${work_dir}/mnt/airootfs"
    trap - EXIT HUP INT TERM
}

# Show help usage, with an exit status.
# $1: exit status number.
_usage() {
    IFS='' read -r -d '' usagetext <<ENDUSAGETEXT || true
usage: ${app_name} [options] <profile_dir>
  options:
     -A <application> Set an application name for the ISO
                      Default: '${iso_application}'
     -C <file>        pacman configuration file.
                      Default: '${pacman_conf}'
     -D <install_dir> Set an install_dir. All files will by located here.
                      Default: '${install_dir}'
                      NOTE: Max 8 characters, use only [a-z0-9]
     -L <label>       Set the ISO volume label
                      Default: '${iso_label}'
     -P <publisher>   Set the ISO publisher
                      Default: '${iso_publisher}'
     -g <gpg_key>     Set the GPG key to be used for signing the sqashfs image
     -h               This message
     -o <out_dir>     Set the output directory
                      Default: '${out_dir}'
     -p PACKAGE(S)    Package(s) to install, can be used multiple times
     -v               Enable verbose output
     -w <work_dir>    Set the working directory
                      Default: '${work_dir}'

  profile_dir:        Directory of the archiso profile to build
ENDUSAGETEXT
    printf '%s' "${usagetext}"
    exit "${1}"
}

# Shows configuration options.
_show_config() {
    local build_date
    build_date="$(date --utc --iso-8601=seconds -d "@${SOURCE_DATE_EPOCH}")"
    _msg_info "${app_name} configuration settings"
    _msg_info "             Architecture:   ${arch}"
    _msg_info "        Working directory:   ${work_dir}"
    _msg_info "   Installation directory:   ${install_dir}"
    _msg_info "               Build date:   ${build_date}"
    _msg_info "         Output directory:   ${out_dir}"
    _msg_info "                  GPG key:   ${gpg_key:-None}"
    _msg_info "                  Profile:   ${profile}"
    _msg_info "Pacman configuration file:   ${pacman_conf}"
    _msg_info "          Image file name:   ${img_name}"
    _msg_info "         ISO volume label:   ${iso_label}"
    _msg_info "            ISO publisher:   ${iso_publisher}"
    _msg_info "          ISO application:   ${iso_application}"
    _msg_info "               Boot modes:   ${bootmodes[*]}"
    _msg_info "                 Packages:   ${pkg_list[*]}"
}

# Cleanup airootfs
_cleanup_airootfs() {
    _msg_info "Cleaning up what we can on airootfs..."

    # Delete all files in /boot
    # Delete pacman database sync cache files (*.tar.gz)
    [[ -d "${airootfs_dir}/var/lib/pacman" ]] && find "${airootfs_dir}/var/lib/pacman" -maxdepth 1 -type f -delete
    # Delete pacman database sync cache
    [[ -d "${airootfs_dir}/var/lib/pacman/sync" ]] && find "${airootfs_dir}/var/lib/pacman/sync" -delete
    # Delete pacman package cache
    [[ -d "${airootfs_dir}/var/cache/pacman/pkg" ]] && find "${airootfs_dir}/var/cache/pacman/pkg" -type f -delete
    # Delete all log files, keeps empty dirs.
    [[ -d "${airootfs_dir}/var/log" ]] && find "${airootfs_dir}/var/log" -type f -delete
    # Delete all temporary files and dirs
    [[ -d "${airootfs_dir}/var/tmp" ]] && find "${airootfs_dir}/var/tmp" -mindepth 1 -delete
    # Delete package pacman related files.
    find "${work_dir}" \( -name '*.pacnew' -o -name '*.pacsave' -o -name '*.pacorig' \) -delete
    # Create an empty /etc/machine-id
    printf '' > "${airootfs_dir}/etc/machine-id"

    _msg_info "Done!"
}

_run_mksquashfs() {
    local image_path="${isofs_dir}/${install_dir}/${arch}/airootfs.sfs"
    if [[ "${quiet}" == "y" ]]; then
        mksquashfs "$@" "${image_path}" -noappend "${airootfs_image_tool_options[@]}" -no-progress > /dev/null
    else
        mksquashfs "$@" "${image_path}" -noappend "${airootfs_image_tool_options[@]}"
    fi
}

# Makes a ext4 filesystem inside a SquashFS from a source directory.
_mkairootfs_ext4+squashfs() {
    [[ -e "${airootfs_dir}" ]] || _msg_error "The path '${airootfs_dir}' does not exist" 1

    _msg_info "Creating ext4 image of 32 GiB..."
    if [[ "${quiet}" == "y" ]]; then
        mkfs.ext4 -q -O '^has_journal,^resize_inode' -E 'lazy_itable_init=0' -m 0 -F -- "${airootfs_dir}.img" 32G
    else
        mkfs.ext4 -O '^has_journal,^resize_inode' -E 'lazy_itable_init=0' -m 0 -F -- "${airootfs_dir}.img" 32G
    fi
    tune2fs -c 0 -i 0 -- "${airootfs_dir}.img" > /dev/null
    _msg_info "Done!"
    _mount_airootfs
    _msg_info "Copying '${airootfs_dir}/' to '${work_dir}/mnt/airootfs/'..."
    cp -aT -- "${airootfs_dir}/" "${work_dir}/mnt/airootfs/"
    chown -- 0:0 "${work_dir}/mnt/airootfs/"
    _msg_info "Done!"
    _umount_airootfs
    install -d -m 0755 -- "${isofs_dir}/${install_dir}/${arch}"
    _msg_info "Creating SquashFS image, this may take some time..."
    _run_mksquashfs "${airootfs_dir}.img"
    _msg_info "Done!"
    rm -- "${airootfs_dir}.img"
}

# Makes a SquashFS filesystem from a source directory.
_mkairootfs_squashfs() {
    [[ -e "${airootfs_dir}" ]] || _msg_error "The path '${airootfs_dir}' does not exist" 1

    install -d -m 0755 -- "${isofs_dir}/${install_dir}/${arch}"
    _msg_info "Creating SquashFS image, this may take some time..."
    _run_mksquashfs "${airootfs_dir}"
    _msg_info "Done!"
}

_mkchecksum() {
    _msg_info "Creating checksum file for self-test..."
    cd -- "${isofs_dir}/${install_dir}/${arch}"
    sha512sum airootfs.sfs > airootfs.sha512
    cd -- "${OLDPWD}"
    _msg_info "Done!"
}

_mksignature() {
    _msg_info "Signing SquashFS image..."
    cd -- "${isofs_dir}/${install_dir}/${arch}"
    gpg --detach-sign --default-key "${gpg_key}" airootfs.sfs
    cd -- "${OLDPWD}"
    _msg_info "Done!"
}

# Helper function to run functions only one time.
_run_once() {
    if [[ ! -e "${work_dir}/build.${1}" ]]; then
        "$1"
        touch "${work_dir}/build.${1}"
    fi
}

# Set up custom pacman.conf with custom cache and pacman hook directories
_make_pacman_conf() {
    local _cache_dirs _system_cache_dirs _profile_cache_dirs
    _system_cache_dirs="$(pacman-conf CacheDir| tr '\n' ' ')"
    _profile_cache_dirs="$(pacman-conf --config "${pacman_conf}" CacheDir| tr '\n' ' ')"

    # only use the profile's CacheDir, if it is not the default and not the same as the system cache dir
    if [[ "${_profile_cache_dirs}" != "/var/cache/pacman/pkg" ]] && \
        [[ "${_system_cache_dirs}" != "${_profile_cache_dirs}" ]]; then
        _cache_dirs="${_profile_cache_dirs}"
    else
        _cache_dirs="${_system_cache_dirs}"
    fi

    _msg_info "Copying custom pacman.conf to work directory..."
    # take the profile pacman.conf and strip all settings that would break in chroot when using pacman -r
    # see `man 8 pacman` for further info
    pacman-conf --config "${pacman_conf}" | \
        sed '/CacheDir/d;/DBPath/d;/HookDir/d;/LogFile/d;/RootDir/d' > "${work_dir}/pacman.conf"

    _msg_info "Using pacman CacheDir: ${_cache_dirs}"
    # append CacheDir and HookDir to [options] section
    # HookDir is *always* set to the airootfs' override directory
    sed "/\[options\]/a CacheDir = ${_cache_dirs}
        /\[options\]/a HookDir = ${airootfs_dir}/etc/pacman.d/hooks/" \
        -i "${work_dir}/pacman.conf"
}

# Prepare working directory and copy custom airootfs files (airootfs)
_make_custom_airootfs() {
    local passwd=()
    local filename permissions

    install -d -m 0755 -o 0 -g 0 -- "${airootfs_dir}"

    if [[ -d "${profile}/airootfs" ]]; then
        _msg_info "Copying custom airootfs files..."
        cp -af --no-preserve=ownership,mode -- "${profile}/airootfs/." "${airootfs_dir}"
        # Set ownership and mode for files and directories
        for filename in "${!file_permissions[@]}"; do
            IFS=':' read -ra permissions <<< "${file_permissions["${filename}"]}"
            # Prevent file path traversal outside of $airootfs_dir
            if [[ "$(realpath -q -- "${airootfs_dir}${filename}")" != "$(realpath -q -- "${airootfs_dir}")"* ]]; then
                _msg_error "Failed to set permissions on '${airootfs_dir}${filename}'. Outside of valid path." 1
            # Warn if the file does not exist
            elif [[ ! -e "${airootfs_dir}${filename}" ]]; then
                _msg_warning "Cannot change permissions of '${airootfs_dir}${filename}'. The file or directory does not exist."
            else
                chown -fh -- "${permissions[0]}:${permissions[1]}" "${airootfs_dir}${filename}"
                chmod -f -- "${permissions[2]}" "${airootfs_dir}${filename}"
            fi
        done
        _msg_info "Done!"
    fi
}

# Install desired packages to airootfs
_make_packages() {
    _msg_info "Installing packages to '${airootfs_dir}/'..."

    if [[ -n "${gpg_key}" ]]; then
        exec {ARCHISO_GNUPG_FD}<>"${work_dir}/pubkey.gpg"
        export ARCHISO_GNUPG_FD
    fi

    if [[ "${quiet}" = "y" ]]; then
        pacstrap -C "${work_dir}/pacman.conf" -c -G -M -- "${airootfs_dir}" "${pkg_list[@]}" &> /dev/null
    else
        pacstrap -C "${work_dir}/pacman.conf" -c -G -M -- "${airootfs_dir}" "${pkg_list[@]}"
    fi

    if [[ -n "${gpg_key}" ]]; then
        exec {ARCHISO_GNUPG_FD}<&-
        unset ARCHISO_GNUPG_FD
    fi

    _msg_info "Done! Packages installed successfully."
}

# Customize installation (airootfs)
_make_customize_airootfs() {
    local passwd=()

    if [[ -e "${profile}/airootfs/etc/passwd" ]]; then
        _msg_info "Copying /etc/skel/* to user homes..."
        while IFS=':' read -a passwd -r; do
            # Only operate on UIDs in range 1000–59999
            (( passwd[2] >= 1000 && passwd[2] < 60000 )) || continue
            # Skip invalid home directories
            [[ "${passwd[5]}" == '/' ]] && continue
            [[ -z "${passwd[5]}" ]] && continue
            # Prevent path traversal outside of $airootfs_dir
            if [[ "$(realpath -q -- "${airootfs_dir}${passwd[5]}")" == "${airootfs_dir}"* ]]; then
                if [[ ! -d "${airootfs_dir}${passwd[5]}" ]]; then
                    install -d -m 0750 -o "${passwd[2]}" -g "${passwd[3]}" -- "${airootfs_dir}${passwd[5]}"
                fi
                cp -dnRT --preserve=mode,timestamps,links -- "${airootfs_dir}/etc/skel/." "${airootfs_dir}${passwd[5]}"
                chmod -f 0750 -- "${airootfs_dir}${passwd[5]}"
                chown -hR -- "${passwd[2]}:${passwd[3]}" "${airootfs_dir}${passwd[5]}"
            else
                _msg_error "Failed to set permissions on '${airootfs_dir}${passwd[5]}'. Outside of valid path." 1
            fi
        done < "${profile}/airootfs/etc/passwd"
        _msg_info "Done!"
    fi

    if [[ -e "${airootfs_dir}/root/customize_airootfs.sh" ]]; then
        _msg_info "Running customize_airootfs.sh in '${airootfs_dir}' chroot..."
        _msg_warning "customize_airootfs.sh is deprecated! Support for it will be removed in a future archiso version."
        chmod -f -- +x "${airootfs_dir}/root/customize_airootfs.sh"
        eval -- arch-chroot "${airootfs_dir}" "/root/customize_airootfs.sh"
        rm -- "${airootfs_dir}/root/customize_airootfs.sh"
        _msg_info "Done! customize_airootfs.sh run successfully."
    fi
}

# Set up boot loaders
_make_bootmodes() {
    local bootmode
    for bootmode in "${bootmodes[@]}"; do
        _run_once "_make_bootmode_${bootmode}"
    done
}

# Prepare kernel/initramfs ${install_dir}/boot/
_make_boot_on_iso9660() {
    local ucode_image
    _msg_info "Preparing kernel and intramfs for the ISO 9660 file system..."
    install -d -m 0755 -- "${isofs_dir}/${install_dir}/boot/${arch}"
    install -m 0644 -- "${airootfs_dir}/boot/initramfs-"*".img" "${isofs_dir}/${install_dir}/boot/${arch}/"
    install -m 0644 -- "${airootfs_dir}/boot/vmlinuz-"* "${isofs_dir}/${install_dir}/boot/${arch}/"

    for ucode_image in {intel-uc.img,intel-ucode.img,amd-uc.img,amd-ucode.img,early_ucode.cpio,microcode.cpio}; do
        if [[ -e "${airootfs_dir}/boot/${ucode_image}" ]]; then
            install -m 0644 -- "${airootfs_dir}/boot/${ucode_image}" "${isofs_dir}/${install_dir}/boot/"
            if [[ -e "${airootfs_dir}/usr/share/licenses/${ucode_image%.*}/" ]]; then
                install -d -m 0755 -- "${isofs_dir}/${install_dir}/boot/licenses/${ucode_image%.*}/"
                install -m 0644 -- "${airootfs_dir}/usr/share/licenses/${ucode_image%.*}/"* \
                    "${isofs_dir}/${install_dir}/boot/licenses/${ucode_image%.*}/"
            fi
        fi
    done
    _msg_info "Done!"
}

# Prepare /syslinux for booting from MBR
_make_bootmode_bios.syslinux.mbr() {
    _msg_info "Setting up SYSLINUX for BIOS booting from a disk..."
    install -d -m 0755 -- "${isofs_dir}/syslinux"
    for _cfg in "${profile}/syslinux/"*.cfg; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g;
             s|%ARCH%|${arch}|g" \
             "${_cfg}" > "${isofs_dir}/syslinux/${_cfg##*/}"
    done
    if [[ -e "${profile}/syslinux/splash.png" ]]; then
        install -m 0644 -- "${profile}/syslinux/splash.png" "${isofs_dir}/syslinux/"
    fi
    install -m 0644 -- "${airootfs_dir}/usr/lib/syslinux/bios/"*.c32 "${isofs_dir}/syslinux/"
    install -m 0644 -- "${airootfs_dir}/usr/lib/syslinux/bios/lpxelinux.0" "${isofs_dir}/syslinux/"
    install -m 0644 -- "${airootfs_dir}/usr/lib/syslinux/bios/memdisk" "${isofs_dir}/syslinux/"

    _run_once _make_boot_on_iso9660

    if [[ -e "${isofs_dir}/syslinux/hdt.c32" ]]; then
        install -d -m 0755 -- "${isofs_dir}/syslinux/hdt"
        if [[ -e "${airootfs_dir}/usr/share/hwdata/pci.ids" ]]; then
            gzip -c -9 "${airootfs_dir}/usr/share/hwdata/pci.ids" > \
                "${isofs_dir}/syslinux/hdt/pciids.gz"
        fi
        find "${airootfs_dir}/usr/lib/modules" -name 'modules.alias' -print -exec gzip -c -9 '{}' ';' -quit > \
            "${isofs_dir}/syslinux/hdt/modalias.gz"
    fi

    # Add other aditional/extra files to ${install_dir}/boot/
    if [[ -e "${airootfs_dir}/boot/memtest86+/memtest.bin" ]]; then
        # rename for PXE: https://wiki.archlinux.org/index.php/Syslinux#Using_memtest
        install -m 0644 -- "${airootfs_dir}/boot/memtest86+/memtest.bin" "${isofs_dir}/${install_dir}/boot/memtest"
        install -d -m 0755 -- "${isofs_dir}/${install_dir}/boot/licenses/memtest86+/"
        install -m 0644 -- "${airootfs_dir}/usr/share/licenses/common/GPL2/license.txt" \
            "${isofs_dir}/${install_dir}/boot/licenses/memtest86+/"
    fi
    _msg_info "Done! SYSLINUX set up for BIOS booting from a disk successfully."
}

# Prepare /syslinux for El-Torito booting
_make_bootmode_bios.syslinux.eltorito() {
    _msg_info "Setting up SYSLINUX for BIOS booting from an optical disc..."
    install -d -m 0755 -- "${isofs_dir}/syslinux"
    install -m 0644 -- "${airootfs_dir}/usr/lib/syslinux/bios/isolinux.bin" "${isofs_dir}/syslinux/"
    install -m 0644 -- "${airootfs_dir}/usr/lib/syslinux/bios/isohdpfx.bin" "${isofs_dir}/syslinux/"

    # ISOLINUX and SYSLINUX installation is shared
    _run_once _make_bootmode_bios.syslinux.mbr

    _msg_info "Done! SYSLINUX set up for BIOS booting from an optical disc successfully."
}

# Prepare /EFI on ISO-9660
_make_efi_dir_on_iso9660() {
    _msg_info "Preparing an /EFI directory for the ISO 9660 file system..."
    install -d -m 0755 -- "${isofs_dir}/EFI/BOOT"
    install -m 0644 -- "${airootfs_dir}/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
        "${isofs_dir}/EFI/BOOT/BOOTx64.EFI"

    install -d -m 0755 -- "${isofs_dir}/loader/entries"
    install -m 0644 -- "${profile}/efiboot/loader/loader.conf" "${isofs_dir}/loader/"

    for _conf in "${profile}/efiboot/loader/entries/"*".conf"; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g;
             s|%ARCH%|${arch}|g" \
            "${_conf}" > "${isofs_dir}/loader/entries/${_conf##*/}"
    done

    # edk2-shell based UEFI shell
    # shellx64.efi is picked up automatically when on /
    if [[ -e "${airootfs_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" ]]; then
        install -m 0644 -- "${airootfs_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" "${isofs_dir}/shellx64.efi"
    fi
    _msg_info "Done!"
}

# Prepare kernel/initramfs on efiboot.img
_make_boot_on_fat() {
    local ucode_image all_ucode_images=()
    _msg_info "Preparing kernel and intramfs for the FAT file system..."
    mmd -i "${work_dir}/efiboot.img" \
        "::/${install_dir}" "::/${install_dir}/boot" "::/${install_dir}/boot/${arch}"
    mcopy -i "${work_dir}/efiboot.img" "${airootfs_dir}/boot/vmlinuz-"* \
        "${airootfs_dir}/boot/initramfs-"*".img" "::/${install_dir}/boot/${arch}/"
    for ucode_image in \
        "${airootfs_dir}/boot/"{intel-uc.img,intel-ucode.img,amd-uc.img,amd-ucode.img,early_ucode.cpio,microcode.cpio}
    do
        if [[ -e "${ucode_image}" ]]; then
            all_ucode_images+=("${ucode_image}")
        fi
    done
    if (( ${#all_ucode_images[@]} )); then
        mcopy -i "${work_dir}/efiboot.img" "${all_ucode_images[@]}" "::/${install_dir}/boot/"
    fi
    _msg_info "Done!"
}

# Prepare efiboot.img::/EFI for EFI boot mode
_make_bootmode_uefi-x64.systemd-boot.esp() {
    local efiboot_imgsize="0"
    _msg_info "Setting up systemd-boot for UEFI booting..."

    # the required image size in KiB (rounded up to the next full MiB with an additional MiB for reserved sectors)
    efiboot_imgsize="$(du -bc \
        "${airootfs_dir}/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
        "${airootfs_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" \
        "${profile}/efiboot/" \
        "${airootfs_dir}/boot/vmlinuz-"* \
        "${airootfs_dir}/boot/initramfs-"*".img" \
        "${airootfs_dir}/boot/"{intel-uc.img,intel-ucode.img,amd-uc.img,amd-ucode.img,early_ucode.cpio,microcode.cpio} \
        2>/dev/null | awk 'function ceil(x){return int(x)+(x>int(x))}
            function byte_to_kib(x){return x/1024}
            function mib_to_kib(x){return x*1024}
            END {print mib_to_kib(ceil((byte_to_kib($1)+1024)/1024))}'
        )"
    # The FAT image must be created with mkfs.fat not mformat, as some systems have issues with mformat made images:
    # https://lists.gnu.org/archive/html/grub-devel/2019-04/msg00099.html
    [[ -e "${work_dir}/efiboot.img" ]] && rm -f -- "${work_dir}/efiboot.img"
    _msg_info "Creating FAT image of size: ${efiboot_imgsize} KiB..."
    mkfs.fat -C -n ARCHISO_EFI "${work_dir}/efiboot.img" "$efiboot_imgsize"

    mmd -i "${work_dir}/efiboot.img" ::/EFI ::/EFI/BOOT
    mcopy -i "${work_dir}/efiboot.img" \
        "${airootfs_dir}/usr/lib/systemd/boot/efi/systemd-bootx64.efi" ::/EFI/BOOT/BOOTx64.EFI

    mmd -i "${work_dir}/efiboot.img" ::/loader ::/loader/entries
    mcopy -i "${work_dir}/efiboot.img" "${profile}/efiboot/loader/loader.conf" ::/loader/
    for _conf in "${profile}/efiboot/loader/entries/"*".conf"; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g;
             s|%ARCH%|${arch}|g" \
            "${_conf}" | mcopy -i "${work_dir}/efiboot.img" - "::/loader/entries/${_conf##*/}"
    done

    # shellx64.efi is picked up automatically when on /
    if [[ -e "${airootfs_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" ]]; then
        mcopy -i "${work_dir}/efiboot.img" \
            "${airootfs_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" ::/shellx64.efi
    fi

    # Copy kernel and initramfs
    _make_boot_on_fat

    _msg_info "Done! systemd-boot set up for UEFI booting successfully."
}

# Prepare efiboot.img::/EFI for "El Torito" EFI boot mode
_make_bootmode_uefi-x64.systemd-boot.eltorito() {
    _run_once _make_bootmode_uefi-x64.systemd-boot.esp
    # Set up /EFI on ISO-9660 to allow preparing an installation medium by manually copying files
    _run_once _make_efi_dir_on_iso9660
}

_validate_requirements_bootmode_bios.syslinux.mbr() {
    # bios.syslinux.mbr requires bios.syslinux.eltorito
    # shellcheck disable=SC2076
    if [[ ! " ${bootmodes[*]} " =~ ' bios.syslinux.eltorito ' ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Using 'bios.syslinux.mbr' boot mode without 'bios.syslinux.eltorito' is not supported." 0
    fi

    # Check if the syslinux package is in the package list
    # shellcheck disable=SC2076
    if [[ ! " ${pkg_list[*]} " =~ ' syslinux ' ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': The 'syslinux' package is missing from the package list!" 0
    fi

    # Check if syslinux configuration files exist
    if [[ ! -d "${profile}/syslinux" ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': The '${profile}/syslinux' directory is missing!" 0
    else
        local cfgfile
        for cfgfile in "${profile}/syslinux/"*'.cfg'; do
            if [[ -e "${cfgfile}" ]]; then
                break
            else
                (( validation_error=validation_error+1 ))
                _msg_error "Validating '${bootmode}': No configuration file found in '${profile}/syslinux/'!" 0
            fi
        done
    fi

    # Check for optional packages
    # shellcheck disable=SC2076
    if [[ ! " ${pkg_list[*]} " =~ ' memtest86+ ' ]]; then
        _msg_info "Validating '${bootmode}': 'memtest86+' is not in the package list. Memmory testing will not be available from syslinux."
    fi
}

_validate_requirements_bootmode_bios.syslinux.eltorito() {
    _validate_requirements_bootmode_bios.syslinux.mbr
}

_validate_requirements_bootmode_uefi-x64.systemd-boot.esp() {
    # Check if mkfs.fat is available
    if ! command -v mkfs.fat &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': mkfs.fat is not available on this host. Install 'dosfstools'!" 0
    fi

    # Check if mmd and mcopy are available
    if ! { command -v mmd &> /dev/null && command -v mcopy &> /dev/null; }; then
        _msg_error "Validating '${bootmode}': mmd and/or mcopy are not available on this host. Install 'mtools'!" 0
    fi

    # Check if systemd-boot configuration files exist
    if [[ ! -d "${profile}/efiboot/loader/entries" ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': The '${profile}/efiboot/loader/entries' directory is missing!" 0
    else
        if [[ ! -e "${profile}/efiboot/loader/loader.conf" ]]; then
            (( validation_error=validation_error+1 ))
            _msg_error "Validating '${bootmode}': File '${profile}/efiboot/loader/loader.conf' not found!" 0
        fi
        local conffile
        for conffile in "${profile}/efiboot/loader/entries/"*'.conf'; do
            if [[ -e "${conffile}" ]]; then
                break
            else
                (( validation_error=validation_error+1 ))
                _msg_error "Validating '${bootmode}': No configuration file found in '${profile}/efiboot/loader/entries/'!" 0
            fi
        done
    fi

    # Check for optional packages
    # shellcheck disable=SC2076
    if [[ ! " ${pkg_list[*]} " =~ ' edk2-shell ' ]]; then
        _msg_info "'edk2-shell' is not in the package list. The ISO will not contain a bootable UEFI shell."
    fi
}

_validate_requirements_bootmode_uefi-x64.systemd-boot.eltorito() {
    # uefi-x64.systemd-boot.eltorito has the exact same requirements as uefi-x64.systemd-boot.esp
    _validate_requirements_bootmode_uefi-x64.systemd-boot.esp
}

# Build airootfs filesystem image
_prepare_airootfs_image() {
    _run_once "_mkairootfs_${airootfs_image_type}"
    _mkchecksum
    if [[ -n "${gpg_key}" ]]; then
        _mksignature
    fi
}

_validate_requirements_airootfs_image_type_squashfs() {
    if ! command -v mksquashfs &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${airootfs_image_type}': mksquashfs is not available on this host. Install 'squashfs-tools'!" 0
    fi
}

_validate_requirements_airootfs_image_type_ext4+squashfs() {
    if ! { command -v mkfs.ext4 &> /dev/null && command -v tune2fs &> /dev/null; }; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${airootfs_image_type}': mkfs.ext4 and/or tune2fs is not available on this host. Install 'e2fsprogs'!" 0
    fi
    _validate_requirements_airootfs_image_type_squashfs
}

# SYSLINUX El Torito
_add_xorrisofs_options_bios.syslinux.eltorito() {
    xorrisofs_options+=(
        # El Torito boot image for x86 BIOS
        '-eltorito-boot' 'syslinux/isolinux.bin'
        # El Torito boot catalog file
        '-eltorito-catalog' 'syslinux/boot.cat'
        # Required options to boot with ISOLINUX
        '-no-emul-boot' '-boot-load-size' '4' '-boot-info-table'
    )
}

# SYSLINUX MBR
_add_xorrisofs_options_bios.syslinux.mbr() {
    xorrisofs_options+=(
        # SYSLINUX MBR bootstrap code; does not work without "-eltorito-boot syslinux/isolinux.bin"
        '-isohybrid-mbr' "${isofs_dir}/syslinux/isohdpfx.bin"
        # When GPT is used, create an additional partition in the MBR (besides 0xEE) for sectors 0–1 (MBR
        # bootstrap code area) and mark it as bootable
        # This violates the UEFI specification, but may allow booting on some systems
        # https://wiki.archlinux.org/index.php/Partitioning#Tricking_old_BIOS_into_booting_from_GPT
        '--mbr-force-bootable'
        # Set the ISO 9660 partition's type to "Linux filesystem data"
        # When only MBR is present, the partition type ID will be 0x83 "Linux" as xorriso translates all
        # GPT partition type GUIDs except for the ESP GUID to MBR type ID 0x83
        '-iso_mbr_part_type' '0FC63DAF-8483-4772-8E79-3D69D8477DE4'
        # Move the first partition away from the start of the ISO to match the expectations of partition
        # editors
        # May allow booting on some systems
        # https://dev.lovelyhq.com/libburnia/libisoburn/src/branch/master/doc/partition_offset.wiki
        '-partition_offset' '16'
    )
}

# systemd-boot in an attached EFI system partition
_add_xorrisofs_options_uefi-x64.systemd-boot.esp() {
    # Move the first partition away from the start of the ISO, otherwise the GPT will not be valid and ISO 9660
    # partition will not be mountable
    # shellcheck disable=SC2076
    [[ " ${xorrisofs_options[*]} " =~ ' -partition_offset ' ]] || xorrisofs_options+=('-partition_offset' '16')
    xorrisofs_options+=(
        # Attach efiboot.img as a second partition and set its partition type to "EFI system partition"
        '-append_partition' '2' 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' "${work_dir}/efiboot.img"
        # Ensure GPT is used as some systems do not support UEFI booting without it
        '-appended_part_as_gpt'
    )
}

# systemd-boot via El Torito
_add_xorrisofs_options_uefi-x64.systemd-boot.eltorito() {
    # shellcheck disable=SC2076
    if [[ " ${bootmodes[*]} " =~ ' uefi-x64.systemd-boot.esp ' ]]; then
        # systemd-boot in an attached EFI system partition via El Torito
        xorrisofs_options+=(
            # Start a new El Torito boot entry for UEFI
            '-eltorito-alt-boot'
            # Set the second partition as the El Torito UEFI boot image
            '-e' '--interval:appended_partition_2:all::'
            # Boot image is not emulating floppy or hard disk; required for all known boot loaders
            '-no-emul-boot'
        )
    else
        # The ISO will not contain a GPT partition table, so to be able to reference efiboot.img, place it as a
        # file inside the ISO 9660 file system
        install -d -m 0755 -- "${isofs_dir}/EFI/archiso"
        cp -a -- "${work_dir}/efiboot.img" "${isofs_dir}/EFI/archiso/efiboot.img"
        # systemd-boot in an embedded efiboot.img via El Torito
        xorrisofs_options+=(
            # Start a new El Torito boot entry for UEFI
            '-eltorito-alt-boot'
            # Set efiboot.img as the El Torito UEFI boot image
            '-e' 'EFI/archiso/efiboot.img'
            # Boot image is not emulating floppy or hard disk; required for all known boot loaders
            '-no-emul-boot'
        )
    fi
    # Specify where to save the El Torito boot catalog file in case it is not already set by bios.syslinux.eltorito
    # shellcheck disable=SC2076
    [[ " ${bootmodes[*]} " =~ ' bios.' ]] || xorrisofs_options+=('-eltorito-catalog' 'EFI/boot.cat')
}

# Build ISO
_build_iso() {
    local xorrisofs_options=()
    local bootmode

    [[ -d "${out_dir}" ]] || install -d -- "${out_dir}"

    [[ "${quiet}" == "y" ]] && xorrisofs_options+=('-quiet')

    # Add required xorrisofs options for each boot mode
    for bootmode in "${bootmodes[@]}"; do
        typeset -f "_add_xorrisofs_options_${bootmode}" &> /dev/null && "_add_xorrisofs_options_${bootmode}"
    done

    _msg_info "Creating ISO image..."
    xorriso -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -joliet \
            -joliet-long \
            -rational-rock \
            -volid "${iso_label}" \
            -appid "${iso_application}" \
            -publisher "${iso_publisher}" \
            -preparer "prepared by ${app_name}" \
            "${xorrisofs_options[@]}" \
            -output "${out_dir}/${img_name}" \
            "${isofs_dir}/"
    _msg_info "Done!"
    du -h -- "${out_dir}/${img_name}"
}

# Read profile's values from profiledef.sh
_read_profile() {
    local validation_error=0
    local bootmode

    _msg_info "Reading profile..."
    if [[ -z "${profile}" ]]; then
        _msg_error "No profile specified!" 1
    fi
    if [[ ! -d "${profile}" ]]; then
        _msg_error "Profile '${profile}' does not exist!" 1
    elif [[ ! -e "${profile}/profiledef.sh" ]]; then
        _msg_error "Profile '${profile}' is missing 'profiledef.sh'!" 1
    else
        cd -- "${profile}"

        # Source profile's variables
        # shellcheck source=configs/releng/profiledef.sh
        . "${profile}/profiledef.sh"

        # Resolve paths
        packages="$(realpath -- "${profile}/packages.${arch}")"
        pacman_conf="$(realpath -- "${pacman_conf}")"

        cd -- "${OLDPWD}"

        # Validate profile
        # Check if the package list file exists and read packages from it
        if [[ -e "${packages}" ]]; then
            mapfile -t pkg_list < <(sed '/^[[:blank:]]*#.*/d;s/#.*//;/^[[:blank:]]*$/d' "${packages}")
            if (( ${#pkg_list} < 1 )); then
                (( validation_error=validation_error+1 ))
                _msg_error "No package specified in '${packages}'." 0
            fi
        else
            (( validation_error=validation_error+1 ))
            _msg_error "File '${packages}' does not exist." 0
        fi
        # Check if pacman configuration file exists
        if [[ ! -e "${pacman_conf}" ]]; then
            (( validation_error=validation_error+1 ))
            _msg_error "File '${pacman_conf}' does not exist." 0
        fi
        # Check if the specified bootmodes are supported
        for bootmode in "${bootmodes[@]}"; do
            if typeset -f "_make_bootmode_${bootmode}" &> /dev/null; then
                if typeset -f "_validate_requirements_bootmode_${bootmode}" &> /dev/null; then
                    "_validate_requirements_bootmode_${bootmode}"
                else
                    _msg_warning "Function '_validate_requirements_bootmode_${bootmode}' does not exist. Validating the requirements of '${bootmode}' boot mode will not be possible."
                fi
            else
                (( validation_error=validation_error+1 ))
                _msg_error "${bootmode} is not a valid boot mode!" 0
            fi
        done
        # Check if the specified airootfs_image_type is supported
        if typeset -f "_mkairootfs_${airootfs_image_type}" &> /dev/null; then
            if typeset -f "_validate_requirements_airootfs_image_type_${airootfs_image_type}" &> /dev/null; then
                "_validate_requirements_airootfs_image_type_${airootfs_image_type}"
            else
                _msg_warning "Function '_validate_requirements_airootfs_image_type_${airootfs_image_type}' does not exist. Validating the requirements of '${airootfs_image_type}' airootfs image type will not be possible."
            fi
        else
            (( validation_error=validation_error+1 ))
            _msg_error "Unsupported image type: '${airootfs_image_type}'" 0
        fi
        if (( validation_error )); then
            _msg_error "${validation_error} errors were encountered while validating the profile. Aborting." 1
        fi
    fi
    _msg_info "Done!"
}

# set overrides from mkarchiso option parameters, if present
_set_overrides() {
    _msg_info "Setting overrides..."
    [[ -n "$override_iso_label" ]] && iso_label="$override_iso_label"
    [[ -n "$override_iso_publisher" ]] && iso_publisher="$override_iso_publisher"
    [[ -n "$override_iso_application" ]] && iso_application="$override_iso_application"
    [[ -n "$override_install_dir" ]] && install_dir="$override_install_dir"
    [[ -n "$override_pacman_conf" ]] && pacman_conf="$override_pacman_conf"
    [[ -n "$override_gpg_key" ]] && gpg_key="$override_gpg_key"
    # NOTE: the call to _msg_info() conveniently guards this function from evaluating to false
    _msg_info "Done!"
}


_export_gpg_publickey() {
    gpg --batch --output "${work_dir}/pubkey.gpg" --export "${gpg_key}"
}


_make_pkglist() {
    install -d -m 0755 -- "${isofs_dir}/${install_dir}"
    _msg_info "Creating a list of installed packages on live-enviroment..."
    pacman -Q --sysroot "${airootfs_dir}" > "${isofs_dir}/${install_dir}/pkglist.${arch}.txt"
    _msg_info "Done!"
}

_build_profile() {
    # Set up essential directory paths
    airootfs_dir="${work_dir}/${arch}/airootfs"
    isofs_dir="${work_dir}/iso"
    # Set ISO file name
    img_name="${iso_name}-${iso_version}-${arch}.iso"
    # Create working directory
    [[ -d "${work_dir}" ]] || install -d -- "${work_dir}"
    # Write build date to file or if the file exists, read it from there
    if [[ -e "${work_dir}/build_date" ]]; then
        SOURCE_DATE_EPOCH="$(<"${work_dir}/build_date")"
    else
        printf '%s\n' "$SOURCE_DATE_EPOCH" > "${work_dir}/build_date"
    fi

    [[ "${quiet}" == "n" ]] && _show_config
    _run_once _make_pacman_conf
    [[ -n "${gpg_key}" ]] && _run_once _export_gpg_publickey
    _run_once _make_custom_airootfs
    _run_once _make_packages
    _run_once _make_customize_airootfs
    _run_once _make_pkglist
    _make_bootmodes
    _run_once _cleanup_airootfs
    _run_once _prepare_airootfs_image
    _run_once _build_iso
}

while getopts 'p:C:L:P:A:D:w:o:g:vh?' arg; do
    case "${arg}" in
        p)
            read -r -a opt_pkg_list <<< "${OPTARG}"
            pkg_list+=("${opt_pkg_list[@]}")
            ;;
        C) override_pacman_conf="$(realpath -- "${OPTARG}")" ;;
        L) override_iso_label="${OPTARG}" ;;
        P) override_iso_publisher="${OPTARG}" ;;
        A) override_iso_application="${OPTARG}" ;;
        D) override_install_dir="${OPTARG}" ;;
        w) work_dir="$(realpath -- "${OPTARG}")" ;;
        o) out_dir="$(realpath -- "${OPTARG}")" ;;
        g) override_gpg_key="${OPTARG}" ;;
        v) quiet="n" ;;
        h|?) _usage 0 ;;
        *)
            _msg_error "Invalid argument '${arg}'" 0
            _usage 1
            ;;
    esac
done

shift $((OPTIND - 1))

if (( $# < 1 )); then
    _msg_error "No profile specified" 0
    _usage 1
fi

if (( EUID != 0 )); then
    _msg_error "${app_name} must be run as root." 1
fi

# get the absolute path representation of the first non-option argument
profile="$(realpath -- "${1}")"

_read_profile
_set_overrides
_build_profile

# vim:ts=4:sw=4:et:
