//! Re-export from zzz_template package.
//! This wrapper preserves the `@import("template/engine.zig")` paths used
//! throughout zzz (context.zig, test_template.zig, root.zig).

const zzz_template = @import("zzz_template");

pub const Segment = zzz_template.Segment;
pub const parse = zzz_template.parse;
pub const template = zzz_template.template;
pub const templateWithPartials = zzz_template.templateWithPartials;
