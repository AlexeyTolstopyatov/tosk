;! For a reason of clobbers and zig relationship...
bits 64
section .text
    global vmm_invalidate_tlb
    global vmm_set_pml4

    vmm_invalidate_tlb:
        invlpg [rcx]
        ret

    vmm_set_pml4:
        mov cr3, rcx
        ret