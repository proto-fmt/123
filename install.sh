#!/bin/bash

# Function to print colored messages
print_message() {
    echo -e "\e[1;32m$1\e[0m"
}

# Function to print error messages
print_error() {
    echo -e "\e[1;31m$1\e[0m"
}

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root."
    exit 1
fi

### User Configurable Variables ###
# Disk to install on (e.g., /dev/sda)
DISK="/dev/sda"

# Partition sizes (in MiB)
BOOT_SIZE=513         # Size of /boot partition (512 MiB)
SWAP_SIZE=2048        # Size of swap partition (2 GiB)
ROOT_SIZE=18432       # Size of root partition (18 GiB)

# Localization settings
TIMEZONE="Europe/Moscow"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Hostname
HOSTNAME="arch"

# Root password
ROOT_PASSWORD="arch"

# Username and password for a new user
USERNAME="user"
USER_PASSWORD="password"

### End of User Configurable Variables ###

# Validate user inputs
validate_inputs() {
    # Check if the disk exists
    if [[ ! -e $DISK ]]; then
        print_error "Disk $DISK does not exist. Please check the disk name."
        exit 1
    fi

    # Check if the disk is large enough
    DISK_SIZE=$(blockdev --getsize64 $DISK)
    DISK_SIZE_MB=$((DISK_SIZE / 1024 / 1024))
    REQUIRED_SIZE=$((BOOT_SIZE + SWAP_SIZE + ROOT_SIZE + 100)) # 100 MiB buffer
    if [[ $DISK_SIZE_MB -lt $REQUIRED_SIZE ]]; then
        print_error "Disk $DISK is too small. Required: $REQUIRED_SIZE MiB, Available: $DISK_SIZE_MB MiB."
        exit 1
    fi

    # Check internet connection
    if ! ping -c 1 archlinux.org &> /dev/null; then
        print_error "No internet connection. Please connect to the internet before proceeding."
        exit 1
    fi

    # Check if system is in UEFI mode
    if [[ ! -d /sys/firmware/efi ]]; then
        print_error "This script supports only UEFI mode. Please boot in UEFI mode."
        exit 1
    fi

    # Check if system clock is synced
    if ! timedatectl status | grep "System clock synchronized: yes" &> /dev/null; then
        print_error "System clock is not synchronized. Please enable NTP or set the time manually."
        exit 1
    fi
}

# Confirm settings with the user
confirm_settings() {
    print_message "Settings:"
    echo "Disk: $DISK"
    echo "Boot partition size: $BOOT_SIZE MiB"
    echo "Swap partition size: $SWAP_SIZE MiB"
    echo "Root partition size: $ROOT_SIZE MiB"
    echo "Remaining space will be used for /home."
    echo "Timezone: $TIMEZONE"
    echo "Locale: $LOCALE"
    echo "Keymap: $KEYMAP"
    echo "Hostname: $HOSTNAME"
    echo "Root password: $ROOT_PASSWORD"
    echo "Username: $USERNAME"
    echo "User password: $USER_PASSWORD"

    read -p "Continue with these settings? (y/n): " CONFIRM
    if [[ $CONFIRM != "y" ]]; then
        print_error "Installation canceled."
        exit 1
    fi
}

# Partition the disk
partition_disk() {
    print_message "Partitioning the disk..."
    parted -s $DISK mklabel gpt
    parted -s $DISK mkpart primary fat32 1MiB ${BOOT_SIZE}MiB
    parted -s $DISK set 1 esp on
    parted -s $DISK mkpart primary linux-swap ${BOOT_SIZE}MiB $((BOOT_SIZE + SWAP_SIZE))MiB
    parted -s $DISK mkpart primary ext4 $((BOOT_SIZE + SWAP_SIZE))MiB $((BOOT_SIZE + SWAP_SIZE + ROOT_SIZE))MiB
    parted -s $DISK mkpart primary ext4 $((BOOT_SIZE + SWAP_SIZE + ROOT_SIZE))MiB 100%
}

# Format partitions
format_partitions() {
    print_message "Formatting partitions..."
    mkfs.fat -F32 ${DISK}1
    mkswap ${DISK}2
    mkfs.ext4 ${DISK}3
    mkfs.ext4 ${DISK}4
}

# Mount partitions
mount_partitions() {
    print_message "Mounting partitions..."
    mount ${DISK}3 /mnt
    mkdir -p /mnt/boot
    mount ${DISK}1 /mnt/boot
    swapon ${DISK}2
    mkdir -p /mnt/home
    mount ${DISK}4 /mnt/home
}

# Install base system
install_base_system() {
    print_message "Installing base system..."
    pacstrap /mnt base linux linux-firmware
}

# Generate fstab
generate_fstab() {
    print_message "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
}

# Configure system
configure_system() {
    print_message "Configuring system..."
    arch-chroot /mnt ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    arch-chroot /mnt hwclock --systohc
    echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
    arch-chroot /mnt locale-gen
    echo "LANG=$LOCALE" > /mnt/etc/locale.conf
    echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf
    echo "$HOSTNAME" > /mnt/etc/hostname
    echo "127.0.0.1 localhost" >> /mnt/etc/hosts
    echo "::1 localhost" >> /mnt/etc/hosts
    echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /mnt/etc/hosts
}

# Install systemd-boot
install_systemd_boot() {
    print_message "Installing systemd-boot..."
    arch-chroot /mnt bootctl --path=/boot install
    cat <<EOF > /mnt/boot/loader/loader.conf
default arch
timeout 3
console-mode max
EOF
    cat <<EOF > /mnt/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=${DISK}3 rw
EOF
}

# Install network utilities
install_network_utilities() {
    print_message "Installing network utilities..."
    arch-chroot /mnt pacman -S networkmanager --noconfirm
    arch-chroot /mnt systemctl enable NetworkManager
}

# Set root password
set_root_password() {
    print_message "Setting root password..."
    arch-chroot /mnt bash -c "echo 'root:$ROOT_PASSWORD' | chpasswd"
}

# Create a new user
create_user() {
    print_message "Creating user $USERNAME..."
    arch-chroot /mnt useradd -m -G wheel -s /bin/bash $USERNAME
    arch-chroot /mnt bash -c "echo '$USERNAME:$USER_PASSWORD' | chpasswd"
    echo "$USERNAME ALL=(ALL) ALL" >> /mnt/etc/sudoers
}

# Finalize installation
finalize_installation() {
    print_message "Installation complete. Unmounting partitions and rebooting..."
    umount -R /mnt
    swapoff -a
    print_message "You can now reboot into your new Arch Linux system."
}

### Main Script ###
validate_inputs
confirm_settings
partition_disk
format_partitions
mount_partitions
install_base_system
generate_fstab
configure_system
install_systemd_boot
install_network_utilities
set_root_password
create_user
finalize_installation