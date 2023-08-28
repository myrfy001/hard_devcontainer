FROM ubuntu:22.04

ARG KERNEL_SOURCE_GIT="git://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/jammy"
ARG KERNEL_SOURCE_BRANCH="Ubuntu-hwe-5.19-5.19.0-50.50"
ARG UBUNTU_RELEASE_NAME="jammy"
ARG UBUNTU_ROOTFS_URL="https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64-root.tar.xz"
ARG ROOTFS_TARBALL_PATH="/vm/origin_disk.img"
ARG ROOTFS_DIR="/rootfs"
ARG LINUX_SRC_DIR="/linux-src"
ARG VM_DIR="/vm"


RUN apt-get update && \
	apt-get install -y wget vim \
					qemu-system-x86 git \
					build-essential cmake gcc libudev-dev libnl-3-dev libnl-route-3-dev \
					ninja-build pkg-config valgrind python3-dev cython3 python3-docutils pandoc \
					bc fakeroot libncurses5-dev libssl-dev ccache bison flex libelf-dev dwarves \ 
					cpio rsync && \
	rm -rf /var/lib/apt/lists/*

RUN mkdir -p $VM_DIR && \
	wget $UBUNTU_ROOTFS_URL -O $ROOTFS_TARBALL_PATH && \
	git clone $KERNEL_SOURCE_GIT --depth=1 --branch $KERNEL_SOURCE_BRANCH ./linux-src


RUN cd $LINUX_SRC_DIR && \
	echo "" > config_patch.config && \
	echo "CONFIG_INFINIBAND=m" >> config_patch.config && \
	echo "# CONFIG_WERROR is not set" >> config_patch.config && \
	echo "# CONFIG_RANDOMIZE_BASE is not set" >> config_patch.config && \
	echo "CONFIG_DEBUG_INFO_DWARF5=y" >> config_patch.config && \
	echo "CONFIG_GDB_SCRIPTS=y" >> config_patch.config && \
	echo "# CONFIG_DEBUG_INFO_REDUCED is not set" >> config_patch.config && \
	make defconfig && \
	./scripts/kconfig/merge_config.sh .config ./config_patch.config && \
	make -j20

RUN apt-get update && apt-get install -y libguestfs-tools

RUN apt-get install -y linux-image-kvm

RUN mkdir -p $ROOTFS_DIR && \
	tar -Jxf $ROOTFS_TARBALL_PATH -C $ROOTFS_DIR && \
	cd $LINUX_SRC_DIR && \
	make INSTALL_MOD_PATH=$ROOTFS_DIR modules_install && \
	echo "root:root" | chpasswd -R $ROOTFS_DIR && \
	
	echo "[Unit]" > $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "Description=Mount 9p to access host fs" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "After=network.target" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "[Service]" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "ExecStart=mount -t 9p -o trans=virtio,version=9p2000.L,access=any hostshare /host" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "[Install]" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "WantedBy=default.target" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \

	echo "ssh-keygen -A " >> /tmp/vm_init.sh && \
	echo "apt-get purge --auto-remove -y snapd multipath-tools" >> /tmp/vm_init.sh && \
	echo "mkdir -p /host" >> /tmp/vm_init.sh && \
	echo "systemctl enable mount_9p" >> /tmp/vm_init.sh && \

	chroot $ROOTFS_DIR /bin/sh < /tmp/vm_init.sh && \
	virt-make-fs --label cloudimg-rootfs --format=qcow2 --type=ext4 --size=+1G $ROOTFS_DIR /rootfs.qcow2

	

