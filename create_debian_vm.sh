#!/bin/bash
#https://wiki.debian.org/Debootstrap

DONE=false

function f_chroot() {
        chroot $rt /bin/su -c "$stuff"
}

function conf_replace() { sed -i $1 -e "s/$2/$3/"; }

#usage check_prog program
function check_prog() {
        which $1 > /dev/null
        if [ $? -ne 0 ]; then
                echo "$1 not found. Exiting"
                exit -1
        fi
}

#usage check_arg program argument
function check_arg() {
        local help=$($1 --help)
        echo $help | grep $2
        if [ $? -ne 0 ]; then
                echo "$1 does not contain argument $2. Exiting"
                exit -1
        fi
}


function create_debian_vm() {
	check_prog debootstrap
	check_prog losetup
	check_prog chroot
	
	os_arch="amd64"
	os_name="wheezy"
	hostname="itl"
	ssh_ips="128.153."
	image_size="15"
	image="/home/csguest/itl-image-$(date +%H-%M_%m-%d-%y).img"
	
	user="csguest"
	userpass="cspassword"
	rootpass="cspassword"
	
	set -e
	
	mount_ramfs
	
	
	bootstrap
	setup_apt
	setup_locale
	
#	mount -t proc none $rt/proc
#	f_chroot apt-get install openjdk-6-jdk openjdk-6-jre openjdk-6-jre-headless -y
#	f_chroot apt-get install openjdk-7-jdk -y
#	f_chroot apt-get install mono-gac -y
#	umount $rt/proc
	
#	basic_utils
	setup_network
	setup_secure
	setup_chroot
	setup_users
	setup_ntp
	setup_initramfs
	setup_fs
	#todo google stuff, lxdm things 
	#libreoffice f-spot
	
	f_chroot apt-get clean
	
	
	create_image
	
	if [ ! -d kernel ]; then
		mkdir kernel
	fi
	cp $rt/boot/* kernel/
	
	unmount_ramfs

	DONE=true
}

function mount_ramfs() {
	local root="/mnt/ram$$"
	mkdir $root
	mount -t ramfs none $root
	export rt=$root
}

function unmount_ramfs() {
	umount $rt
	rmdir $rt
}

function bootstrap() {
	local mirror="http://mirror.clarkson.edu/debian/"
	local pkgs="locales"
	
	for i in $(cat packages_pre.txt); do
		pkgs="$pkgs,$i"
	done
	
	mkdir -p $rt/var/cache/apt/archives
	if [ ! -d /tmp/archives ]; then
		mkdir /tmp/archives
	fi
	mount --bind /tmp/archives $rt/var/cache/apt/archives
	
	debootstrap --include $pkgs --arch $os_arch $os_name $rt $mirror
	
	umount $rt/var/cache/apt/archives
}

function setup_apt() {
	local sources="$rt/etc/apt/sources.list"
	function add_repo() { echo "deb $1 $os_name$2 $3" >> $sources; echo "#deb-src $1 $os_name$2 $3" >> $sources; }
	
	rm $sources
	add_repo "http://mirror.clarkson.edu/debian/" "" "main contrib non-free"
	add_repo "http://security.debian.org/" "/updates" "main contrib"
	add_repo "http://mirror.clarkson.edu/debian/" "-updates" "main"
	
	echo 'APT::Get::Install-Recommends "false";' > $rt/etc/apt/apt.conf
	
	f_chroot apt-get update
	f_chroot apt-get upgrade -y
}

function setup_locale() {
	f_chroot apt-get install -y locales
	conf_replace $rt/etc/locale.gen "# en_US.UTF-8 UTF-8" "en_US.UTF-8 UTF-8"
	f_chroot locale-gen
}

function basic_utils() {
#	IFS="\n"
	local packages #=$(cat packages.txt);
	#for packages in $(cat packages.txt); do
	while read packages; do
		echo $packages
		f_chroot apt-get install -y "$packages"
		f_chroot apt-get clean
	done < packages.txt
	f_chroot service ssh stop
	f_chroot service ntp stop
#	f_chroot service exim4 stop
}

function setup_network() {
	local interfaces="$rt/etc/network/interfaces"
	cat > $interfaces << EOT
auto lo
iface lo inet loopback

auto eth0
iface eth$i inet dhcp
  dns-nameservers 128.153.145.3 128.153.145.4

EOT
	echo $hostname > $rt/etc/hostname
	
#	echo "$ip $hostname $vm_name.cslabs $vm_name" >> $rt/etc/hosts
}

#TODO iptables
function setup_secure() {
	echo "ALL: 127.0.0.1" > $rt/etc/hosts.allow
	echo "ALL: ALL" > $rt/etc/hosts.deny
}

function setup_chroot() {
	echo "sshd: $ssh_ips" >> $rt/etc/hosts.allow
	local sshd_config="$rt/etc/ssh/sshd_config"
	conf_replace $sshd_config "PermitRootLogin yes" "PermitRootLogin no"
}

function setup_users() {
	local bashrc="$rt/etc/skel/.bashrc"
	conf_replace $bashrc "#force_color_prompt=yes" "force_color_prompt=yes"
	conf_replace $bashrc "#alias" "alias"
	cp $bashrc $rt/root/
	
	conf_replace $rt/etc/vim/vimrc '"syntax on' "syntax on"
	
	f_chroot "useradd -m $user -G sudo -s /bin/bash"
	f_chroot "usermod -a -G wireshark $user"
	echo -e "$userpass\n$userpass" | f_chroot passwd $user
	echo -e "$rootpass\n$rootpass" | f_chroot passwd root
	
	conf_replace $rt/etc/sudoers " ALL" " NOPASSWD:ALL"
}

function setup_ntp() {
	local ntp="$rt/etc/ntp.conf"
	conf_replace $ntp "server 0.debian.pool.ntp.org iburst" "server tick.clarkson.edu"
	conf_replace $ntp "server 1.debian.pool.ntp.org iburst" "server tock.clarkson.edu"
	conf_replace $ntp "server 2.debian.pool.ntp.org iburst" ""
	conf_replace $ntp "server 3.debian.pool.ntp.org iburst" ""
}

function setup_initramfs() {
	echo "Generating initramfs"
	cat >> $rt/etc/initramfs-tools/modules <<EOT
tg3
r8169
EOT
	conf_replace $rt/etc/initramfs-tools/initramfs.conf "MODULES=most" "MODULES=netboot"
#	rm $rt/boot/initrd*
	f_chroot update-initramfs -uk all
}

function setup_fs() {
	cat > $rt/etc/fstab <<EOT
#/dev/sda1	none	swap	defaults		0 0
/dev/nbd0	/	ext4	defaults,relatime	0 2
EOT
}

function setup_img() {
	losetup -f $image
	losetup -j $image | sed -e 's/:[^@]*$//'
}

function disconnect_img() {
	local loop=$1
	
	umount ${loop}
	losetup -d $loop
}

function format_mount_img() {
	local loop=$1
	local dest=$2
	
	mkfs.ext4 $loop
	mount $loop $dest
}

function create_image() {
	if [ -f $image ]; then
		echo "IMAGE EXISTS REMOVING"
		rm $image
	fi
	
	truncate -s ${image_size}GB $image
	
	local loop=$(setup_img $image)
	local dest="/mnt/tmp$$"
	mkdir $dest
	format_mount_img $loop $dest
	
	cp -rp $rt/* $dest
	
	disconnect_img $loop
	rmdir $dest
}

create_debian_vm
