#!/bin/bash
#https://wiki.debian.org/Debootstrap
#theme from https://github.com/duskp/numix-holo


function o_chroot() {
	
	local stuff="/bin/su -c '$@'"
	echo "Running $stuff"
	bash -c "chroot $rt $stuff"
}

function f_chroot() {
	local stuff="/bin/su -c '$@'"
	echo "Running $stuff"
	bash -c "systemd-nspawn -D $rt $stuff"
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

function create_build() {
	check_prog debootstrap
	check_prog chroot
	check_prog systemd-nspawn

	set -e
	
	os_arch="amd64"
	os_name="jessie"
	hostname="itl"
	ssh_ips="128.153."
	#rt="/itl-build$$"
	rt="/itl-build"

	echo "Starting build in $rt"
	
	user="csguest"
	userpass="cspassword"
	rootpass="cspassword"
	
	mount_archives

	bootstrap

	setup_apt
	setup_locale
	basic_utils
	f_chroot dpkg-reconfigure wireshark-common
	f_chroot plymouth-set-default-theme spinner

	setup_network
	setup_secure
	setup_ssh
	setup_users
	setup_ntp
	setup_aufs
	setup_initramfs
	setup_fs
	setup_udisks
	setup_misc
	#todo google stuff, lxdm things 
	
	f_chroot update-rc.d slim disable 2

	echo $rt
	
	#systemd-nspawn fix
#	umount $rt/proc/sys/fs/binfmt_misc
#	umount $rt/proc
#	
#	unmount_archives
	
}

function mount_ramfs() {
	rt="/mnt/ram$$"
	mkdir $rt
	mount -t ramfs none $rt
}

function mount_archives() {
	mkdir -p $rt/var/cache/apt/archives
	if [ ! -d /tmp/archives ]; then
		mkdir /tmp/archives
	fi
	mount --bind /tmp/archives $rt/var/cache/apt/archives
}

function unmount_archives() {
	umount $rt/var/cache/apt/archives
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
	
	debootstrap --include $pkgs --arch $os_arch $os_name $rt $mirror
	
}

function setup_apt() {
	local sources="$rt/etc/apt/sources.list"
	function add_repo() { echo "deb $1 $os_name$2 $3" >> $sources; echo "#deb-src $1 $os_name$2 $3" >> $sources; }
	
	rm $sources
	add_repo "http://mirror.clarkson.edu/debian/" "" "main contrib non-free"
	add_repo "http://security.debian.org/" "/updates" "main contrib"
	add_repo "http://mirror.clarkson.edu/debian/" "-updates" "main"
	echo "deb http://mirror.clarkson.edu/linuxmint/packages debian main import" >> $sources
	f_chroot "gpg --keyserver pgp.mit.edu --recv-keys 3EE67F3D0FF405B2"
	f_chroot "gpg --export 3EE67F3D0FF405B2 > 3EE67F3D0FF405B2.gpg"
	f_chroot "apt-key add ./3EE67F3D0FF405B2.gpg"
	f_chroot "rm ./3EE67F3D0FF405B2.gpg"
	
	echo 'APT::Get::Install-Recommends "false";' > $rt/etc/apt/apt.conf
	
	f_chroot apt-get update
	f_chroot apt-get upgrade -y
}

function setup_locale() {
	conf_replace $rt/etc/locale.gen "# en_US.UTF-8 UTF-8" "en_US.UTF-8 UTF-8"
	f_chroot locale-gen
}

function basic_utils() {
	f_chroot "ln -s /proc/self/fd /dev/fd; apt-get install virtualbox-dkms -y"
	local packages=$(cat packages.txt)
	for package in $packages; do
		f_chroot apt-get install -y "$package"
	done
}

function setup_network() {
	local interfaces="$rt/etc/network/interfaces"
	cat > $interfaces << EOT
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
  dns-nameservers 128.153.145.3 128.153.145.4

EOT
	echo $hostname > $rt/etc/hostname
	echo "127.0.0.1 itl" >> $rt/etc/hosts
#	echo "$ip $hostname $vm_name.cslabs $vm_name" >> $rt/etc/hosts
}

#TODO iptables
function setup_secure() {
	echo "ALL: 127.0.0.1" > $rt/etc/hosts.allow
	echo "ALL: ALL" > $rt/etc/hosts.deny
}

function setup_ssh() {
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
	
	echo "Before"
	cp -rv skel/.* $rt/etc/skel/
	echo "After"

	f_chroot "useradd -m $user -G sudo -s /bin/bash"
	f_chroot "usermod -a -G wireshark $user"
	f_chroot "usermod -a -G libvirt $user"
	f_chroot "usermod -a -G libvirt-qemu $user"
	f_chroot "usermod -a -G vboxusers $user"
	echo -e "$userpass\n$userpass" | o_chroot passwd $user
	echo -e "$rootpass\n$rootpass" | o_chroot passwd root
	
	conf_replace $rt/etc/sudoers " ALL" " NOPASSWD:ALL"
	
	echo "default_user	csguest" >> $rt/etc/slim.conf
	echo "auto_login		yes" >> $rt/etc/slim.conf
}

function setup_ntp() {
	local ntp="$rt/etc/ntp.conf"
	conf_replace $ntp "server 0.debian.pool.ntp.org iburst" "server tick.clarkson.edu"
	conf_replace $ntp "server 1.debian.pool.ntp.org iburst" "server tock.clarkson.edu"
	conf_replace $ntp "server 2.debian.pool.ntp.org iburst" ""
	conf_replace $ntp "server 3.debian.pool.ntp.org iburst" ""
	cp $rt/usr/share/zoneinfo/America/New_York $rt/etc/localtime
}

#http://debianaddict.com/2012/06/19/diskless-debian-linux-booting-via-dhcppxenfstftp/
#http://www.logicsupply.com/blog/2009/01/27/how-to-build-a-read-only-linux-system/
function setup_aufs() {
	local aufs="$rt/etc/initramfs-tools/scripts/init-bottom/ro_root"
	local hooks="$rt/etc/initramfs-tools/hooks/ro_root"
	cat > $hooks <<EOT
#!/bin/sh

PREREQ=''

prereqs() {
  echo "\$PREREQ"
}

case \$1 in
prereqs)
  prereqs
  exit 0
  ;;
esac

. /usr/share/initramfs-tools/hook-functions
manual_add_modules aufs
manual_add_modules tmpfs
copy_exec /bin/chmod /bin

copy_exec /bin/rm /bin


copy_lib() {
	copy_exec /lib/x86_64-linux-gnu/\$1 /lib/x86_64-linux-gnu/
}

copy_exec /usr/bin/free /bin
copy_lib libprocps.so.0

copy_exec /bin/grep /bin

cp /bin/mount /bin/s_mount
copy_exec /bin/s_mount /bin
copy_lib libsepol.so.1
copy_lib libmount.so.1
EOT

	cat > $aufs <<EOT
#!/bin/sh

PREREQ=''

prereqs() {
  echo "\$PREREQ"
}

case \$1 in
prereqs)
  prereqs
  exit 0
  ;;
esac

# Boot normally when the user selects single user mode.
#if grep single /proc/cmdline >/dev/null; then
#  exit 0
#fi

ro_mount_point="\${rootmnt%/}.ro"
rw_mount_point="\${rootmnt%/}.rw"

# Create mount points for the read-only and read/write layers:
mkdir "\${ro_mount_point}" "\${rw_mount_point}"

# Move the already-mounted root filesystem to the ro mount point:
s_mount --move "\${rootmnt}" "\${ro_mount_point}"

# Mount the read/write filesystem:
size=\$(free -tm | grep Total | awk '{ print \$2"M"}')
s_mount -t tmpfs -o size=\$size root.rw "\${rw_mount_point}"
#s_mount -t tmpfs -o size=\$size tmpfs /rw/


# Mount the union:
s_mount -t aufs -o "dirs=\${rw_mount_point}=rw:\${ro_mount_point}=ro" root.union "\${rootmnt}"

# Correct the permissions of /:
chmod 755 "\${rootmnt}"

# Make sure the individual ro and rw mounts are accessible from within the root
# once the union is assumed as /.  This makes it possible to access the
# component filesystems individually.
mkdir "\${rootmnt}/ro" "\${rootmnt}/rw"
s_mount --move "\${ro_mount_point}" "\${rootmnt}/ro"
s_mount --move "\${rw_mount_point}" "\${rootmnt}/rw"

# Make sure checkroot.sh doesn't run.  It might fail or erroneously remount /.
rm -f "\${rootmnt}/etc/rcS.d"/S[0-9][0-9]checkroot.sh

sleep 10
EOT
	chmod +x $aufs
	chmod +x $hooks
}

function setup_initramfs() {
	echo "Generating initramfs"
	cat >> $rt/etc/initramfs-tools/modules <<EOT
tg3
r8169

intel_agp
drm
i915 modeset=1

drm
radeon modeset=1

aufs
EOT
	conf_replace $rt/etc/initramfs-tools/initramfs.conf "MODULES=most" "MODULES=netboot"
	f_chroot update-initramfs -uk all
}

function setup_udisks() {
	f_chroot groupadd storage
	f_chroot usermod -a -G storage csguest
	mkdir -p $rt/etc/polkit-1/localauthority/50-local.d/
	cat > $rt/etc/polkit-1/localauthority/50-local.d/10-udisks.pkla <<EOT
[udisks]
Identity=unix-group:storage
Action=org.freedesktop.udisks.drive-eject;org.freedesktop.udisks.filesystem-mount
ResultAny=yes
EOT
}

function setup_fs() {
	cat > $rt/etc/fstab <<EOT
#/dev/sda1	none	swap	defaults		0 0
#/dev/nbd0	/	ext4	defaults,relatime	0 2
EOT
}

function setup_misc() {
	rm $rt/opt/firefox/browser/searchplugins/*
	cp misc/google.xml $rt/opt/firefox/browser/searchplugins/
}


function exit_func() {
	unmount_archives
	umount $rt/proc/sys/fs/binfmt_misc
	umount $rt/proc
}

trap exit_func EXIT

create_build
