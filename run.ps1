Set-Alias -Name qemu -Value "D:\Program Files\qemu\qemu-system-x86_64.exe"

qemu -drive if=pflash,format=raw,readonly=on,file=ovmf.fd -debugcon stdio -hda fat:rw:zig-out/img -m 256M