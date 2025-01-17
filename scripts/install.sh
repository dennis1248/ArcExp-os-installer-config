#!/usr/bin/env bash

# Enable debugging and log the output to a file
LOG_FILE="/tmp/install_script_log.txt"
exec > >(tee -a "$LOG_FILE") 2>&1
set -x

declare -r workdir='/mnt'
declare -r rootlabel='ArcExp_root'
declare -r osidir='/etc/os-installer'

# Function to display an error and exit
show_error() {
    printf "ERROR: %s\n" "$1" >&2
    exit 1
}

# Function to display partition table information
display_partition_table_info() {
    echo "Partition Table Information for $OSI_DEVICE_PATH:"
    sudo gdisk -l "$OSI_DEVICE_PATH"
    echo
}

# Write partition table to the disk
if [[ ! -d "$workdir/sys/firmware/efi" ]]; then
	# Booted in to UEFI, lets make the disk GPT
	sudo sfdisk $OSI_DEVICE_PATH < $osidir/gpt.sfdisk
else
	# Booted in to BIOS, lets make the disk MBR
	sudo sfdisk $OSI_DEVICE_PATH < $osidir/mbr.sfdisk
fi


# NVMe drives follow a slightly different naming scheme to other block devices
# this will change `/dev/nvme0n1` to `/dev/nvme0n1p` for easier parsing later
if [[ $OSI_DEVICE_PATH == *"nvme"*"n"* ]]; then
	declare -r partition_path="${OSI_DEVICE_PATH}p"
else
	declare -r partition_path="${OSI_DEVICE_PATH}"
fi

# Check if encryption is requested, write filesystems accordingly
if [[ $OSI_USE_ENCRYPTION -eq 1 ]]; then

	# If user requested disk encryption
	if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then

		# If target is a drive
		sudo mkfs.fat -F32 ${partition_path}1
		echo $OSI_ENCRYPTION_PIN | sudo cryptsetup -q luksFormat ${partition_path}2
		echo $OSI_ENCRYPTION_PIN | sudo cryptsetup open ${partition_path}2 $rootlabel -
		sudo mkfs.btrfs -f -L $rootlabel /dev/mapper/$rootlabel

		sudo mount -o compress=zstd /dev/mapper/$rootlabel $workdir
		sudo mount --mkdir ${partition_path}1 $workdir/boot
		sudo btrfs subvolume create $workdir/home

	else

		# If target is a partition
		printf 'PARTITION TARGET NOT YET IMPLEMENTED BECAUSE OF EFI DETECTION BUG\n'
		exit 1
	fi

else

	# If no disk encryption requested
	if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then

		# If target is a drive
		sudo mkfs.fat -F32 ${partition_path}1
		sudo mkfs.btrfs -f -L $rootlabel ${partition_path}2

		sudo mount -o compress=zstd ${partition_path}2 $workdir
		sudo mount --mkdir ${partition_path}1 $workdir/boot
		sudo btrfs subvolume create $workdir/home

	else

		# If target is a partition
		printf 'PARTITION TARGET NOT YET IMPLEMENTED BECAUSE OF EFI DETECTION BUG\n'
		exit 1
	fi

fi

# Install system packages
sudo pacstrap "$workdir" base base-devel linux-zen linux-zen-headers linux-firmware dkms || show_error "Failed to install system packages"

# Populate the Arch Linux keyring inside chroot
sudo arch-chroot "$workdir" pacman-key --init || show_error "Failed to initialize Arch Linux keyring"
sudo arch-chroot "$workdir" pacman-key --populate archlinux || show_error "Failed to populate Arch Linux keyring"

# Install desktop environment packages
sudo arch-chroot "$workdir" pacman -S --noconfirm firefox fsarchiver gdm gedit git gnome-backgrounds gnome-calculator gnome-console gnome-control-center gnome-disk-utility gnome-font-viewer gnome-photos gnome-screenshot gnome-settings-daemon gnome-shell gnome-software gnome-text-editor gnome-tweaks gnu-netcat gpart gpm gptfdisk nautilus neofetch networkmanager network-manager-applet power-profiles-daemon dbus ostree bubblewrap glib2 libarchive flatpak xdg-user-dirs-gtk || show_error "Failed to install desktop environment packages"

# Install grub packages including os-prober
sudo arch-chroot "$workdir" pacman -S --noconfirm grub efibootmgr os-prober || show_error "Failed to install GRUB, efibootmgr, or os-prober"

# Install GRUB based on firmware type (UEFI or BIOS)
if [ -d "$workdir/sys/firmware/efi" ]; then
    # For UEFI systems
    sudo arch-chroot "$workdir" grub-install --target=x86_64-efi --efi-directory="/boot/efi" --bootloader-id=GRUB || show_error "Failed to install GRUB on NVME drive on UEFI system"
    sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || show_error "Failed to generate GRUB configuration file for UEFI system"
else
    # For BIOS systems
    sudo arch-chroot "$workdir" grub-install --target=i386-pc "$partition_path" || show_error "Failed to install GRUB on BIOS system"
    sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || show_error "Failed to generate GRUB configuration file for BIOS system"
fi

# Run os-prober to collect information about other installed operating systems
sudo arch-chroot "$workdir" os-prober || show_error "Failed to run os-prober"

# Generate the fstab file
sudo genfstab -U "$workdir" | sudo tee "$workdir/etc/fstab" || show_error "Failed to generate fstab file"

exit 0
