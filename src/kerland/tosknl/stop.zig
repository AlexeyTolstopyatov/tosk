//! This file describes panic behavior of minimal payload.
//! After the IDT table initialization and loading, needed 
//! correct handlers of Interrupt requests
//!  
pub const Registers = extern struct {
    rax: u64,
    rcx: u64,
    rdx: u64,
    rbx: u64,
    rbp: u64,
    rsi: u64,
    rdi: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    vector: u64,
};

