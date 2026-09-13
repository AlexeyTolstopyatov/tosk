bits 64
section .text
    global vmm_invalidate_tlb
    global vmm_set_pml4

    vmm_invalidate_tlb:
        invlpg [rcx]
        ret

    vmm_set_pml4:
        ; first following argument = physical address of PML4
        mov cr3, rdi        ; <- CR3 (drop TLB)
        ret
