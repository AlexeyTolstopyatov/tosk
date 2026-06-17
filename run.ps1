$qemu = "D:\Program Files\qemu\qemu-system-x86_64.exe"

& $qemu -s -S -debugcon stdio -drive if=pflash,format=raw,readonly=on,file=ovmf.fd -hda fat:rw:zig-out/image