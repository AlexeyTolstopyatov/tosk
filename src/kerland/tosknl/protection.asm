;! CoffeeLake 2026-*  
;!      Zig 0.16 couldn't work correct with inline assembler 
;! when needed to declare the "clobbers". After execution 
;! registers must stay as they are. We don't need to restore registers
;! and Zig resists to deny it.
;!
;!      Raw strings for Clobbers was replaced in Zig 0.12+ i siggest, 
;! but type instances of [builtin.assembly.Clobbers__xxxxxx] aren't support .{} initialization
;! and can't have .register/.memory members.
global load_gdt
global load_idt
global isr_stub_table
extern kcheck

section .text   ; Location of procedures of given object (Zig linker places them into .text)
bits 64         ; UEFI services switched CPU in the "Long Mode" already.
; Loads Global Descriptor table by value in the 64-bit counter register
; Moves kernel module code into 8th segment (CS := 8) and sets all
; segment registers at the 16th. 
;   CODE   := 8
;   DATA   := 16
;   EXTRA  := 16
;   FLAGS  := 16
;   GLOBAL := 16
;   STACK  := 16
; \param rcx - gdtr_t pointer (limit: u16, base: u64)
load_gdt:
    lgdt [rcx] ; Microsoft x64 calling convention.
    ; reload CS through the far return
    push 0x08                    ; new kernel entrypoint address
    lea rax, [rel .reload_code]  ; next instruction
    push rax
    retfq
.reload_code:
    ; load kernel data selector and other segments
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    ret

load_idt:
    lidt [rcx] ; was rcx
    ret

; Macro handles interrupts/fault codes
%macro ISR_ERR 1
global isr_%1
isr_%1:
    push %1
    jmp common_handler_with_err
%endmacro

; Macro handles interrupts with no error codes 
%macro ISR_NOERR 1
global isr_%1
isr_%1:
    push %1
    jmp common_handler_no_err
%endmacro

common_handler_no_err:
    ; stack: [vector, RIP, CS, RFLAGS]
    ; Сохраняем все регистры (чтобы не повредить контекст)
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    ; Collect first argument for [kcheck] - vec#
    ; Now RSP points to the last saved reg64 value (r11). Expecting vector#.
    mov rcx, [rsp + 8*8] ; Size of  saved registers 8reg64 * 8imm64 = 64
    ; Stack alignmemt call
    and rsp, ~15
    call kcheck
common_handler_with_err:
    ; Стек: [vector, error_code, RIP, CS, RFLAGS]
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    mov rcx, [rsp + 8*8]   ; vector (rdi was)
    and rsp, ~15
    
    call kcheck

%define ERROR_VECTORS 8,10,11,12,13,14,17,30

align 16
isr_stub_table:
%assign i 0
%rep 256
    %if i in ERROR_VECTORS
        ISR_ERR i
    %else
        ISR_NOERR i
    %endif
%assign i i+1
%endrep