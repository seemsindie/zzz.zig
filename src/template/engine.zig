//! Re-export from pidgn_template package.
//! This wrapper preserves the `@import("template/engine.zig")` paths used
//! throughout pidgn (context.zig, test_template.zig, root.zig).

const pidgn_template = @import("pidgn_template");

pub const Segment = pidgn_template.Segment;
pub const parse = pidgn_template.parse;
pub const template = pidgn_template.template;
pub const templateWithPartials = pidgn_template.templateWithPartials;
