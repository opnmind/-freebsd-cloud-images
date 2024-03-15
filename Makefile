
build-latest: clean build-15

build-13:
	sudo ./build.sh 13.3 ufs

build-14:
	sudo ./build.sh 14.0 ufs

build-15:
	sudo ./build.sh 15.0 ufs

perm:
	sudo chown $(USER):$(USER) *.qcow2

clean:
	sudo umount /mnt/zbuildroot
	sudo umount /mnt
	sudo zpool destroy zbuildroot
	sudo rm -f final.raw

info:
	qemu-img info *.qcow2

rm: clean
	rm -f *.qcow2
