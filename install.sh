#!/bin/bash

# Function to print colored messages
print_message() {
    echo -e "\e[1;32m$1\e[0m"
}

# Function to print error messages
print_error() {
    echo -e "\e[1;31m$1\e[0m"
}

# Function to display a dot animation while a command is running
dot_animation() {
    local pid=$1
    local delay=0.5
    while [[ $(ps -p $pid -o comm=) != "" ]]; do
        printf "   \r"
        sleep $delay
        printf ".  \r"
        sleep $delay
        printf ".. \r"
        sleep $delay
        printf "...\r"
        sleep $delay
    done
    printf "    \r"
}

# Function to execute a command with a dot animation
execute_with_animation() {
    local command=$1
    local description=$2
    echo -n "$description... "
    $command &>/dev/null &
    local pid=$!
    dot_animation $pid
    wait $pid
    if [[ $? -eq 0 ]]; then
        echo -e "\e[1;32m[OK]\e[0m"
    else
        echo -e "\e[1;31m[FAIL]\e[0m"
        exit 1
    fi
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
BOOT_SIZE=512         # Fixed size for /boot (512 MiB)
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
    echo "Boot partition size: $BOOT_SIZE MiB (fixed)"
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
    execute_with_animation \
        "parted -s $DISK mklabel gpt && \
         parted -s $DISK mkpart primary fat32 1MiB ${BOOT_SIZE}MiB && \
         parted -s $DISK set 1 esp on && \
         parted -s $DISK mkpart primary linux-swap ${BOOT_SIZE}MiB $((BOOT_SIZE + SWAP_SIZE))MiB && \
         parted -s $DISK mkpart primary ext4 $((BOOT_SIZE + SWAP_SIZE))MiB $((BOOT_SIZE + SWAP_SIZE + ROOT_SIZE))MiB && \
         parted -s $DISK mkpart primary ext4 $((BOOT_SIZE + SWAP_SIZE + ROOT_SIZE))MiB 100%" \
        "Partitioning disk"
}

# Format partitions
format_partitions() {
    execute_with_animation \
        "mkfs.fat -F32 ${DISK}1 && \
         mkswap ${DISK}2 && \
         mkfs.ext4 ${DISK}3 && \
         mkfs.ext4 ${DISK}4" \
        "Formatting partitions"
}

# Mount partitions
mount_partitions() {
    execute_with_animation \
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
    execute_with_animation \
        "pacstrap /mnt base linux linux-firmware" \
        "Installing base system"
}

# Generate fstab
generate_fstab() {
    execute_with_animation \
        "genfstab -U /mnt >> /mnt/etc/fstab" \
        "Generating fstab"
}

# Configure system
configure_system() {
    execute_with_animation \
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
    execute_with_animation \
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
    execute_with_animation \
        "arch-chroot /mnt pacman -S networkmanager --noconfirm && \
         arch-chroot /mnt systemctl enable NetworkManager" \
        "Installing network utilities"
}

# Set root password
set_root_password() {
    execute_with_animation \
        "arch-chroot /mnt bash -c 'echo root:$ROOT_PASSWORD | chpasswd'" \
        "Setting root password"
}

# Create a new user
create_user() {
    execute_with_animation \
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