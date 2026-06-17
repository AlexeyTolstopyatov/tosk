pub const BootInfo = extern struct {
    memory_map: [*]u8,
    memory_map_size: usize,
    memory_map_desc_size: usize,
    framebuffer_base: *volatile anyopaque,
    framebuffer_width: u32,
    framebuffer_height: u32,
    rsdp: ?*anyopaque,
    module_start: usize,
    module_end: usize
    // anything here??
};