#!/bin/bash

### User Configurable Variables ###
# Disk to install on (e.g., /dev/sda)
DISK="/dev/sda"

# Partition sizes (in GB, except for boot which is fixed at 512 MiB)
SWAP_SIZE=2          # Size of swap partition (in GB)
ROOT_SIZE=18         # Size of root partition (in GB)

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

# Fixed boot partition size (512 MiB)
BOOT_SIZE_MB=512

# Convert GB to MiB for calculations
SWAP_SIZE_MB=$((SWAP_SIZE * 1024))
ROOT_SIZE_MB=$((ROOT_SIZE * 1024))

### Color Constants ###
COLOR_RESET="\e[0m"
COLOR_GREEN="\e[1;32m"
COLOR_RED="\e[1;31m"
COLOR_BLUE="\e[1;34m"
COLOR_YELLOW="\e[1;33m"

# Function to print colored messages
print_message() {
    echo -e "${COLOR_GREEN}$1${COLOR_RESET}"
}

# Function to print error messages
print_error() {
    echo -e "${COLOR_RED}$1${COLOR_RESET}"
}

# Function to execute a command and display status
execute_with_status() {
    local command=$1
    local description=$2
    echo -n "$description... "
    $command &>/dev/null
    if [[ $? -eq 0 ]]; then
        echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET}"
        print_error "Error: Failed to execute '$command'"
        exit 1
    fi
}

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root."
    exit 1
fi

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
    REQUIRED_SIZE=$((BOOT_SIZE_MB + SWAP_SIZE_MB + ROOT_SIZE_MB + 100)) # 100 MiB buffer
    if [[ $DISK_SIZE_MB -lt $REQUIRED_SIZE ]]; then
        print_error "Disk $DISK is too small. Required: $((REQUIRED_SIZE / 1024)) GB, Available: $((DISK_SIZE_MB / 1024)) GB."
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
    print_message "=== Installation Settings ==="
    echo -e "Disk: ${COLOR_BLUE}$DISK${COLOR_RESET}"
    echo -e "Boot partition size: ${COLOR_BLUE}512 MiB (fixed)${COLOR_RESET}"
    echo -e "Swap partition size: ${COLOR_BLUE}$SWAP_SIZE GB${COLOR_RESET}"
    echo -e "Root partition size: ${COLOR_BLUE}$ROOT_SIZE GB${COLOR_RESET}"
    echo -e "Remaining space will be used for ${COLOR_BLUE}/home${COLOR_RESET}."
    echo -e "Timezone: ${COLOR_BLUE}$TIMEZONE${COLOR_RESET}"
    echo -e "Locale: ${COLOR_BLUE}$LOCALE${COLOR_RESET}"
    echo -e "Keymap: ${COLOR_BLUE}$KEYMAP${COLOR_RESET}"
    echo -e "Hostname: ${COLOR_BLUE}$HOSTNAME${COLOR_RESET}"
    echo -e "Root password: ${COLOR_BLUE}$ROOT_PASSWORD${COLOR_RESET}"
    echo -e "Username: ${COLOR_BLUE}$USERNAME${COLOR_RESET}"
    echo -e "User password: ${COLOR_BLUE}$USER_PASSWORD${COLOR_RESET}"
    echo -e "================================="

    read -p "Continue with these settings? (y/n): " CONFIRM
    if [[ $CONFIRM != "y" ]]; then
        print_error "Installation canceled."
        exit 1
    fi
}

# Partition the disk
partition_disk() {
    execute_with_status \
        "parted -s $DISK mklabel gpt && \
         parted -s $DISK mkpart primary fat32 1MiB ${BOOT_SIZE_MB}MiB && \
         parted -s $DISK set 1 esp on && \
         parted -s $DISK mkpart primary linux-swap ${BOOT_SIZE_MB}MiB $((BOOT_SIZE_MB + SWAP_SIZE_MB))MiB && \
         parted -s $DISK mkpart primary ext4 $((BOOT_SIZE_MB + SWAP_SIZE_MB))MiB $((BOOT_SIZE_MB + SWAP_SIZE_MB + ROOT_SIZE_MB))MiB && \
         parted -s $DISK mkpart primary ext4 $((BOOT_SIZE_MB + SWAP_SIZE_MB + ROOT_SIZE_MB))MiB 100%" \
        "Partitioning disk"
}

# Format partitions
format_partitions() {
    execute_with_status \
        "mkfs.fat -F32 ${DISK}1 && \
         mkswap ${DISK}2 && \
         mkfs.ext4 ${DISK}3 && \
         mkfs.ext4 ${DISK}4" \
        "Formatting partitions"
}

# Mount partitions
mount_partitions() {
    execute_with_status \
        "mount ${DISK}3 /mnt && \
         mkdir -p /mnt/boot && \
         mount ${DISK}1 /mnt/boot && \
         swapon ${DISK}2 && \
         mkdir -p /mnt/home && \
         mount ${DISK}4 /mnt/home" \
        "Mounting partitions"
}

# Install base system
install_base_system() {
    execute_with_status \
        "pacstrap /mnt base linux linux-firmware" \
        "Installing base system"
}

# Generate fstab
generate_fstab() {
    execute_with_status \
        "genfstab -U /mnt >> /mnt/etc/fstab" \
        "Generating fstab"
}

# Configure system
configure_system() {
    execute_with_status \
        "arch-chroot /mnt ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && \
         arch-chroot /mnt hwclock --systohc && \
         echo '$LOCALE UTF-8' >> /mnt/etc/locale.gen && \
         arch-chroot /mnt locale-gen && \
         echo 'LANG=$LOCALE' > /mnt/etc/locale.conf && \
         echo 'KEYMAP=$KEYMAP' > /mnt/etc/vconsole.conf && \
         echo '$HOSTNAME' > /mnt/etc/hostname && \
         echo '127.0.0.1 localhost' >> /mnt/etc/hosts && \
         echo '::1 localhost' >> /mnt/etc/hosts && \
         echo '127.0.1.1 $HOSTNAME.localdomain $HOSTNAME' >> /mnt/etc/hosts" \
        "Configuring system"
}

# Install systemd-boot
install_systemd_boot() {
    execute_with_status \
        "arch-chroot /mnt bootctl --path=/boot install && \
         echo 'default arch' > /mnt/boot/loader/loader.conf && \
         echo 'timeout 3' >> /mnt/boot/loader/loader.conf && \
         echo 'console-mode max' >> /mnt/boot/loader/loader.conf && \
         echo 'title   Arch Linux' > /mnt/boot/loader/entries/arch.conf && \
         echo 'linux   /vmlinuz-linux' >> /mnt/boot/loader/entries/arch.conf && \
         echo 'initrd  /initramfs-linux.img' >> /mnt/boot/loader/entries/arch.conf && \
         echo 'options root=${DISK}3 rw' >> /mnt/boot/loader/entries/arch.conf" \
        "Installing systemd-boot"
}

# Install network utilities
install_network_utilities() {
    execute_with_status \
        "arch-chroot /mnt pacman -S networkmanager --noconfirm && \
         arch-chroot /mnt systemctl enable NetworkManager" \
        "Installing network utilities"
}

# Set root password
set_root_password() {
    execute_with_status \
        "arch-chroot /mnt bash -c 'echo root:$ROOT_PASSWORD | chpasswd'" \
        "Setting root password"
}

# Create a new user
create_user() {
    execute_with_status \
        "arch-chroot /mnt useradd -m -G wheel -s /bin/bash $USERNAME && \
         arch-chroot /mnt bash -c 'echo $USERNAME:$USER_PASSWORD | chpasswd' && \
         echo '$USERNAME ALL=(ALL) ALL' >> /mnt/etc/sudoers" \
        "Creating user $USERNAME"
}

# Finalize installation
finalize_installation() {
    print_message "Installation complete. Unmounting partitions and rebooting..."
    umount -R /mnt
    swapoff -a
    print_message "System ready for reboot."
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