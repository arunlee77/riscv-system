#!/bin/bash 


echo "Install Prerequisites"
echo "sudo password required"
sudo apt update
sudo apt install autoconf automake autotools-dev curl libmpc-dev libmpfr-dev libgmp-dev gawk build-essential bison flex texinfo gperf libtool patchutils bc zlib1g-dev libexpat-dev git
mkdir -p riscv64-linux
cd riscv64-linux
sudo umount linux-disk
sudo rm -rf disk.img

if [ ! -d qemu ]; then
    echo "Building qemu for RISC-V"
    git clone https://github.com/qemu/qemu
    cd qemu && git checkout v7.1.0
    git submodule init
    git submodule update --recursive
else
   cd qemu
fi
./configure --target-list=riscv64-softmmu && make -j2
cd ..

if [ ! -d riscv-gnu-toolchain ]; then
    echo "Building risc-v toolchain"
    git clone https://github.com/riscv-collab/riscv-gnu-toolchain.git
    cd riscv-gnu-toolchain
    git checkout 2022.12.17
else
    cd riscv-gnu-toolchain
fi
./configure --prefix=/opt/riscv --with-arch=rv64gc --with-abi=lp64d
sudo -E make linux
echo "Set toolchain path"
echo "export PATH=$PATH:/opt/riscv/bin/" >> /home/$USER/.bashrc
source /home/$USER/.bashrc
cd ..
echo "Build u-boot with virtual disks"
export CROSS_COMPILE=riscv64-unknown-linux-gnu-
if [ ! -d u-boot ]; then
    git clone https://source.denx.de/u-boot/u-boot.git
    cd u-boot && git checkout v2022.07
else
    cd u-boot
fi
make qemu-riscv64_smode_defconfig
cp ../../configs/uboot.config .config
make -j2
cd ..
if [ ! -d opensbi ]; then
   echo "Build opensbi with u-boot as payload"
   git clone https://github.com/riscv-software-src/opensbi.git
   cd opensbi && git checkout v1.1
else
   cd opensbi
fi
make PLATFORM=generic FW_PAYLOAD_PATH=../u-boot/u-boot.bin -j2
cd ..

echo "Download an build kernel"
export ARCH=riscv
if [ ! -d linux-6.0 ]; then
    wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.0.tar.xz
    tar xf linux-6.0.tar.xz
fi
cd linux-6.0/
make defconfig
make -j2
cd ..

echo "Make disk for kernel and rootfs"
dd if=/dev/zero of=disk.img bs=1M count=1024
sudo parted disk.img mklabel gpt
name=$(sudo losetup --find --show disk.img)
echo $name
sudo parted --align minimal $name mkpart primary ext4 0 40%
sudo parted --align minimal $name mkpart primary ext4 40% 100%
sudo parted $name print
sudo mkfs.ext4 ${name}p1
sudo mkfs.ext4 ${name}p2
sudo parted $name set 1 boot on
sudo mkdir -p linux-disk
sudo mount ${name}p1 linux-disk
sudo cp linux-6.0/arch/riscv/boot/Image linux-disk
ls -ls linux-disk
sudo umount linux-disk

sudo mount ${name}p2 linux-disk
ls -la linux-disk

sudo chown -R $USER:$USER linux-disk

if [ ! -d busybox ]; then
    echo "Make busybox"
    git clone https://git.busybox.net/busybox
    cd busybox && git checkout 1_35_stable
    cp ../../configs/busybox.config .config
else
    cd busybox
fi
CROSS_COMPILE=riscv64-unknown-linux-gnu- LDFLAGS=--static make defconfig
CROSS_COMPILE=riscv64-unknown-linux-gnu- LDFLAGS=--static make -j2 install CONFIG_PREFIX=../linux-disk

echo "Finalizing rootfs"

cd ..
sudo chown -R root:root linux-disk

sudo mkdir linux-disk/proc linux-disk/sys linux-disk/dev linux-disk/etc linux-disk/etc/init.d
sudo touch linux-disk/etc/fstab
sudo cp ../configs/rcS linux-disk/etc/init.d/rcS
sudo chmod a+x linux-disk/etc/init.d/rcS
ls -ls linux-disk
sudo umount linux-disk
sudo losetup -d $name

./qemu/build/qemu-system-riscv64 -smp 2 -m 1G -nographic -machine virt -bios ./opensbi/build/platform/generic/firmware/fw_payload.elf -blockdev driver=file,filename=./disk.img,node-name=disk -device virtio-blk-device,drive=disk -netdev user,id=eth0 -device virtio-net-device,netdev=eth0
