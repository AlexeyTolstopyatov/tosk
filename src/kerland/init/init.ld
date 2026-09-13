ENTRY(main)

SECTIONS {
    . = 1M;
    _start = main;

    .text : ALIGN(4K) {
        *(.text)
    }

    .rodata : ALIGN(4K) {
        *(.rodata)
    }

    .data : ALIGN(4K) {
        *(.data)
    }

    .bss : ALIGN(4K) {
        *(COMMON)
        *(.bss)
    }

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note*)
        *(.comment*)
    }
}