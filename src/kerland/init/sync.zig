//!
//! Synchronization primitives shared across the `init`.
//!

/// Minimal test-and-set spinlock. On the BSP the acquire is usually one
/// uncontended exchange; the loop is what makes it safe on multiple CPUs.
pub const Spinlock = struct {
    /// 0 = free, 
    /// 1 = held. 
    /// Kept private; live through the builtins to be
    /// correct across CPUs regardless of compiler optimisations.
    raw: u8 = 0,

    /// Try to take the lock; spins (with a PAUSE) until acquired.
    // mint fmt: off
    pub inline fn lock(self: *Spinlock) void {
        while (@atomicRmw(u8, &self.raw, .Xchg, 1, .seq_cst) != 0) {
            // Turn CPU into power-less mode on
            // SMT cores and a no-op otherwise.
            asm volatile("pause");
        }
    }

    /// Release the lock.
    pub inline fn unlock(self: *Spinlock) void {
        @atomicStore(u8, &self.raw, 0, .seq_cst);
    }
    // mint fmt: on
};