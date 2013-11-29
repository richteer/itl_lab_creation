Scripts to automate the creation of the base image for the Internet Teaching Lab at Clarkson University

## Usage:
  ./create_build.sh    (as root)

This generates a linux system at /itl-build.  The recommended way to use this system is rsync it to a server running nfs and configure a read only export.  Then boot the kernel with the standard nfsroot arguments (preferably over pxe).

## Requirements:
  debootstrap
  chroot
  systemd-nspawn
  at least 6 GB at /itl-build (TODO location parameter)
  
## How it works:
### Debootstrap:
* Runs debootstrap targeting /itl-build with arguments specifying aditional packages to install
* These packages are contained in packages_pre.sh
* Several packages cannot be installed here and shall be installed later. This includes but is not limited to packages requiring /proc to be mounted (debootstrap does not do this).  Packages in repositories outside of main must be installed later.
### Additional Package Installation:
* Uses systemd-nspawn to install packages from packages.txt
* Systemd-nspawn provides a better environment that chroot.  It simulates a running system in more detail, including proc.  It also will force all processes inside the environment to exit
### Misc setup:
* Create users
* Configure packages
* Setup hosts.allow and hosts.deny
* etc
### Initramfs/AUFS: (the really cool part)
* We need a environment that has a read only root device that stores all modifications in ram.  For this we use aufs and tmpfs.  Aufs is a kernel module that can be used to union a ro and rw directory.  Another thing to note is we need a more advanced mount utility than is provided by busybox.
* There are 2 scripts, one that is run when the initramfs is generated (hook), and one that is run toward the end of the initramfs scripts (just before the init system is started, systemd in this case) in the init-bottom directory.
* Hook: copies over aufs module , tmpfs module, rm, awk, free, grep, mount, and all of the libraries they depend upon.
* init-bottom:
   * Moves ${rootmnt} to $ro_temp
   * Mounts a tmpfs the size of the ram in the system at $rw_temp
   * Creates the AUFS union from the two mount points.
   * Moves $ro_temp and $rw_temp to /ro and /rw respectivley
