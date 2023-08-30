FROM ubuntu:22.04

ARG KERNEL_SOURCE_GIT="git://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/jammy"
ARG KERNEL_SOURCE_BRANCH="Ubuntu-hwe-5.19-5.19.0-50.50"
ARG UBUNTU_RELEASE_NAME="jammy"
ARG UBUNTU_ROOTFS_URL="https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64-root.tar.xz"
ARG ROOTFS_TARBALL_PATH="/vm/origin_disk.img"
ARG ROOTFS_DIR="/rootfs"
ARG LINUX_SRC_DIR="/linux-src"
ARG VM_DIR="/vm"


# linux-image-kvm is installed to make libguestfs-tools happy, because it need a kernel and an simple rootfs to run VM
RUN apt-get update && \
	apt-get install -y wget vim \
					qemu-system-x86 git \
					build-essential cmake gcc libudev-dev libnl-3-dev libnl-route-3-dev \
					ninja-build pkg-config valgrind python3-dev cython3 python3-docutils pandoc \
					bc fakeroot libncurses5-dev libssl-dev ccache bison flex libelf-dev dwarves \ 
					rsync libguestfs-tools linux-image-kvm && \
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
	make -j20 && \
	make scripts_gdb

RUN mkdir -p $ROOTFS_DIR && \
	tar -Jxf $ROOTFS_TARBALL_PATH -C $ROOTFS_DIR && \
	cd $LINUX_SRC_DIR && \
	make INSTALL_MOD_PATH=$ROOTFS_DIR modules_install && \
	echo "root:root" | chpasswd -R $ROOTFS_DIR && \
	# generate a systemd service config file to mount 9p fs at booting. adding it to fstab seems not working.
	# after mounting,we also run a script mounted from host to do some init work. 
	echo "[Unit]" > $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "Description=Mount 9p to access host fs" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "After=network.target" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "[Service]" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "ExecStart=bash -c \"mount -t 9p -o trans=virtio,version=9p2000.L,access=any hostshare /host && /host/workspaces/dtld-rdma-driver/scripts/for_qemu/boot_init.sh\"" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "[Install]" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	echo "WantedBy=default.target" >> $ROOTFS_DIR/etc/systemd/system/mount_9p.service && \
	# == finish generating systemd config
	#
	# generate a tmp script to run in chroot environment to modify the rootfs for qemu
	echo "ssh-keygen -A " >> /tmp/vm_init.sh && \
	echo "apt-get purge --auto-remove -y snapd multipath-tools" >> /tmp/vm_init.sh && \
	echo 'mkdir -p /run/systemd/resolve/' >> /tmp/vm_init.sh && \
	echo 'echo "nameserver 8.8.8.8" > /run/systemd/resolve/stub-resolv.conf' >> /tmp/vm_init.sh && \
	echo "apt-get update && apt-get install -y build-essential gdb" >> /tmp/vm_init.sh && \
	echo "mkdir -p /host" >> /tmp/vm_init.sh && \
	#  -- this link below is to make rdma-core happy, since the build system of rdma-core can only build binary that "run inplace"
	#  -- with this link, the binary in qemu has the save path as it in the devcontainer. so we can build it in devcontainer and 
	#  -- run it in qemu.
	echo "ln -sf /host/workspaces /workspaces" >> /tmp/vm_init.sh && \
	#  -- make run scripts stored in devcontainer more easily.
	echo "echo \"export PATH=$PATH:/host/workspaces/dtld-rdma-driver/scripts/for_qemu:/host/workspaces/dtld-rdma-driver/rdma-core/build/bin\" > /etc/profile.d/set_path.sh" >> /tmp/vm_init.sh && \
	echo "systemctl enable mount_9p" >> /tmp/vm_init.sh && \
	chroot $ROOTFS_DIR /bin/sh < /tmp/vm_init.sh && \
	# finish generate and run tmp script.
	virt-make-fs --label cloudimg-rootfs --format=qcow2 --type=ext4 --size=+1G $ROOTFS_DIR /rootfs.qcow2

	

