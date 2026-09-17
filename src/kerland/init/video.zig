const std = @import("std");
const FirmwareInterface = @import("fi.zig").FirmwareInterface;

pub var monitor: Video = undefined;

/// Foreground colours (RGBA) used by the logger for the severity level.
pub const COLOR_INFO: u32 = 0xFFFFFFFF; // white
pub const COLOR_OK: u32 = 0xFF00FF00; // green
pub const COLOR_FAIL: u32 = 0xFFFF0000; // red
pub const COLOR_TRACE: u32 = 0xFF808080; // grey

/// True once `console` has been populated with a real framebuffer.
pub fn isActive() bool {
    return monitor.width > 0 and monitor.height > 0;
}

/// Emits a whole string through the global `console`; a no-op while inactive.
pub fn print(str: []const u8) void {
    if (!isActive()) return;
    for (str) |c| monitor.putChar(c);
}

pub const PixelFormat = enum { RGBA, BGRA };
pub const Color = enum(u32) {
    Red = 0xFFFF0000,
    Green = 0xFF00FF00,
    Blue = 0xFF0000FF,
};
///
/// Embedded console service. Extern fi struct given by EFI bootloader
/// contains a data about screen. (frame buffer and screen resolution).
/// This is not traditional case, when monitor pointer locates device buffer @0xB8000,
///
/// EFI services already caught all devices pointers, save them and turn
/// CPU mode into LONG (64-bit mode).
///
pub const Video = struct {
    framebuffer: [*]volatile u32,
    /// Inherits by UEFI boot services
    width: u32,
    /// Inhertis by UEFI boot services
    height: u32,
    pixel_format: PixelFormat,
    /// Mono raster font (8x16). Any differences are throwing exceptions
    /// 256 characters
    font: []const u8,
    /// 8
    font_width: u32,
    /// 16
    font_height: u32,
    cursor_x: u32,
    cursor_y: u32,
    /// Foreground (pixel format dependent)
    fg_color: u32,
    /// Background (pixel format dependent)
    bg_color: u32,
    /// How many lines was scrolled up
    scroll_y: u32,

    pub fn init(fi: *const FirmwareInterface) !Video {
        const fmt = PixelFormat.RGBA;
        //const font_data = installIBMRaster();

        return Video{
            .framebuffer = @ptrCast(
                @alignCast(fi.framebuffer_base),
            ),
            .width = fi.framebuffer_width,
            .height = fi.framebuffer_height,
            .pixel_format = fmt,
            .font = fi.font_map[0..fi.font_map_size],
            .font_width = 8,
            .font_height = 16,
            .cursor_x = 0,
            .cursor_y = 0,
            .fg_color = 0xFFFFFFFF,
            .bg_color = 0xFF000000,
            .scroll_y = 0,
        };
    }

    /// Draw charater pixel-by-pixel
    inline fn drawCharacter(
        self: *Video,
        c: u8,
        x: u32,
        y: u32,
    ) void {
        if (c < 32)
            return; // Escape sequencies handles exactly here
        const font_offset = c * self.font_height;
        for (0..self.font_height) |urow| {
            const byte = self.font[font_offset + urow];
            for (0..self.font_width) |ucol| {
                const col: u3 = @intCast(ucol);
                const row: u32 = @intCast(urow);
                if (((byte >> (7 - @as(u3, col))) & 1) != 0) {
                    self.setPixel(
                        x + col,
                        y + row,
                        self.fg_color,
                    );
                } else {
                    self.setPixel(
                        x + col,
                        y + row,
                        self.bg_color,
                    );
                }
            }
        }
    }
    inline fn setPixel(
        self: *Video,
        px: u32,
        py: u32,
        color: u32,
    ) void {
        if (px >= self.width or py >= self.height) return;
        const idx = py * self.width + px;
        // Convert colors. If target scheme is (alpha)BGR -> needed to apply
        // little bit transformations. (replace Blue bits with Red).
        //      color & 0xFF000000 -> Alpha channel and nothing after it (color => AA______)
        //      color & 0x00FF0000 << 16 -> Select Only Red channed and move it right (color => 0x__..__BB)
        //      color & 0x0000FF00 -> Only Green channel selected (color => 0x____GG__)
        //      color & 0x000000FF << 16 -> Select blue channel and move it left (color => 0x__RR__..)
        // And hold the fact that color
        const val = switch (self.pixel_format) {
            .RGBA => color,
            .BGRA => ((color & 0xFF000000))
                | // A
                ((color & 0x00FF0000) >> 16)
                | // R -> B
                ((color & 0x0000FF00))
                | // G -> G
                ((color & 0x000000FF) << 16), // B -> R
        };
        self.framebuffer[idx] = val;
    }
    /// Output character in the video buffer
    pub inline fn putChar(self: *Video, ch: u8) void {
        switch (ch) {
            '\n' => {
                self.cursor_x = 0;
                self.cursor_y += self.font_height;
                if (
                    self.cursor_y + self.font_height
                        > self.height
                ) {
                    self.scrollUp();
                }
            },
            '\r' => self.cursor_x = 0,
            '\t' => {
                const tab_width = 4 * self.font_width;
                self.cursor_x = ((self.cursor_x / tab_width) + 1)
                    * tab_width;
                if (self.cursor_x >= self.width) {
                    self.cursor_x = 0;
                    self.cursor_y += self.font_height;
                }
            },
            else => {
                self.drawCharacter(
                    ch,
                    self.cursor_x,
                    self.cursor_y,
                );
                self.cursor_x += self.font_width;
                if (
                    self.cursor_x + self.font_width
                        > self.width
                ) {
                    self.cursor_x = 0;
                    self.cursor_y += self.font_height;
                }
                if (
                    self.cursor_y + self.font_height
                        > self.height
                ) {
                    self.scrollUp();
                }
            },
        }
    }
    /// Move screen containment at the one line upper
    fn scrollUp(self: *Video) void {
        const line_height = self.font_height;
        const bytes_per_pixel = 4;
        const row_bytes = self.width * bytes_per_pixel;

        // Copy up lines 1..(height-line_height)
        const copy_size = row_bytes
            * (self.height - line_height);
        const src = @as(
            [*]volatile u8,
            @ptrCast(self.framebuffer),
        )
            + row_bytes * line_height;
        const dst = @as(
            [*]volatile u8,
            @ptrCast(self.framebuffer),
        );

        //@memcpy(dst, src);
        for (src, 0..copy_size) |byte, i| {
            dst[i] = byte;
        }

        // Fill last lines line_height with backrgound
        const fill_start = dst
            + row_bytes * (self.height - line_height);
        const fill_size = row_bytes * line_height;

        //@memset(fill_start, @as(u8, @truncate(self.bg_color >> 24)));
        for (0..fill_size) |i| {
            fill_start[i] = @as(
                u8,
                @truncate(self.bg_color >> 24),
            );
        }

        self.cursor_y -= line_height;
    }
    /// Formatted output in the VGA
    pub fn printf(
        self: *Video,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var buffer: [2048]u8 = undefined;
        const result = std.fmt.bufPrint(&buffer, fmt, args)
            catch unreachable;

        for (result) |ch| {
            self.putChar(ch);
        }
    }
    pub fn foreground(self: *Video, hex: u32) void {
        self.fg_color = hex;
    }
    pub fn background(self: *Video, hex: u32) void {
        self.bg_color = hex;
    }
    pub fn clear(self: *Video) void {
        for (0..self.width) |w| {
            for (0..self.height) |h| {
                self.drawCharacter(
                    ' ',
                    @intCast(w),
                    @intCast(h),
                );
            }
        }
    }
    pub const Writer = std.Io.Writer(*Video, error{}, write);

    fn write(self: *Video, bytes: []const u8) error{}!usize {
        for (bytes) |b| self.putChar(b);
        return bytes.len;
    }

    pub fn writer(self: *Video) Writer {
        return .{ .context = self };
    }
};

pub const VideoLogger = struct {
    pub fn init(b: *FirmwareInterface) void {
        monitor = try Video.init(b);
    }

    /// Switches foreground to white then prints raw message text
    pub fn printf(comptime fmt: []const u8, args: anytype) void {
        monitor.fg_color = COLOR_INFO;
        monitor.printf(fmt, args);
    }
    /// Inserts info:\t prefix then prints message
    pub fn infof(comptime fmt: []const u8, args: anytype) void {
        monitor.fg_color = COLOR_INFO;
        monitor.printf("[ INFO ] ", args);
        printf(fmt, args);
    }
    /// Inserts fail:\t prefix then prints message
    pub fn failf(comptime fmt: []const u8, args: anytype) void {
        monitor.fg_color = COLOR_FAIL;
        monitor.printf("[ FAIL ] ", .{});
        printf(fmt, args);
    }
    /// Inserts done:\t prefix then prints message
    pub fn okf(comptime fmt: []const u8, args: anytype) void {
        monitor.fg_color = COLOR_OK;
        monitor.printf("[  OK  ] ", .{});
        printf(fmt, args);
    }
    /// Switches soft grey color then prints raw message text
    pub fn tracef(comptime fmt: []const u8, args: anytype) void {
        monitor.fg_color = COLOR_TRACE;
        monitor.printf(fmt, args);
    }
};
