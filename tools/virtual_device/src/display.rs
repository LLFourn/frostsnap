//! The device screen: a real 240×280 `VecFramebuffer<Rgb565>` (the SDL-free
//! framebuffer from `frostsnap_widgets`, deliberately *not*
//! `embedded-graphics-simulator`, so the app's rust crate can depend on this one
//! without pulling SDL). The framebuffer is shared (`Arc<Mutex<…>>`) so the device
//! thread draws into it while an outside reader exports RGBA frames (for the
//! Flutter tray) or PNGs (the Rust-side debug artifact).

use embedded_graphics::{
    draw_target::DrawTarget,
    geometry::{OriginDimensions, Size},
    pixelcolor::Rgb565,
    prelude::RgbColor,
    Pixel,
};
use frostsnap_widgets::vec_framebuffer::VecFramebuffer;
use std::sync::{Arc, Mutex};

pub const WIDTH: u32 = 240;
pub const HEIGHT: u32 = 280;

/// A handle to the device framebuffer, cloneable across threads. The device's
/// `FramebufferDisplay` and any number of readers hold the same buffer.
#[derive(Clone)]
pub struct SharedFramebuffer(Arc<Mutex<VecFramebuffer<Rgb565>>>);

impl SharedFramebuffer {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(VecFramebuffer::new(
            WIDTH as usize,
            HEIGHT as usize,
        ))))
    }

    /// Snapshot the framebuffer as `(width, height, rgba8888)` — the format the
    /// Flutter tray blits via `decodeImageFromPixels` (sim-5).
    pub fn export_rgba(&self) -> (u32, u32, Vec<u8>) {
        let fb = self.0.lock().unwrap();
        let mut out = Vec::with_capacity((WIDTH * HEIGHT * 4) as usize);
        for color in fb.contiguous_pixels() {
            out.push((color.r() as u16 * 255 / 31) as u8);
            out.push((color.g() as u16 * 255 / 63) as u8);
            out.push((color.b() as u16 * 255 / 31) as u8);
            out.push(0xff);
        }
        (WIDTH, HEIGHT, out)
    }

    /// Dump the current frame to a PNG (a Rust-side debug artifact).
    pub fn save_png(&self, path: impl AsRef<std::path::Path>) -> std::io::Result<()> {
        let (w, h, rgba) = self.export_rgba();
        image::RgbaImage::from_raw(w, h, rgba)
            .expect("rgba buffer matches dimensions")
            .save(path)
            .map_err(std::io::Error::other)
    }

    /// Whether the framebuffer changed since the last check (drives push-on-dirty).
    pub fn take_dirty(&self) -> bool {
        self.0.lock().unwrap().take_dirty()
    }

    /// Paint the whole screen black — the powered-off look. On power-off (sim-13) the
    /// slot clears the framebuffer and pushes the resulting blank frame so the tray and
    /// `screen` show a dark device, not the last live frame from before it was unplugged.
    pub fn clear(&self) {
        self.0.lock().unwrap().clear(Rgb565::BLACK);
    }
}

impl Default for SharedFramebuffer {
    fn default() -> Self {
        Self::new()
    }
}

/// The `DrawTarget` the device's `FrostyUi` renders into; writes land in the
/// shared framebuffer.
pub struct FramebufferDisplay {
    fb: SharedFramebuffer,
}

impl FramebufferDisplay {
    pub fn new(fb: SharedFramebuffer) -> Self {
        Self { fb }
    }
}

impl OriginDimensions for FramebufferDisplay {
    fn size(&self) -> Size {
        Size::new(WIDTH, HEIGHT)
    }
}

impl DrawTarget for FramebufferDisplay {
    type Color = Rgb565;
    type Error = core::convert::Infallible;

    fn draw_iter<I>(&mut self, pixels: I) -> Result<(), Self::Error>
    where
        I: IntoIterator<Item = Pixel<Self::Color>>,
    {
        self.fb.0.lock().unwrap().draw_iter(pixels)
    }
}
