# Build FreeBSD Cloud Image For OpenStack

## Prerequisites

FreeBSD: 
```shell
pkg install -y bash git qemu-tools curl
```

## Usage

```shell
# e.g. to build FreeBSD-15.0-CURRENT-amd64-ufs-openstack.qcow2
./build.sh 15.0 ufs
```

## Reference

This repository is based on https://github.com/virt-lightning/freebsd-cloud-images.
