//! Swagger/OpenAPI support for the Pidgn web framework.
//!
//! Provides comptime OpenAPI 3.1.0 spec generation and Swagger UI serving.
//! Only routes annotated with `.doc()` appear in the generated spec.
//!
//! Usage:
//!   const routes = &[_]pidgn.RouteDef{ ... };
//!   const spec = pidgn.swagger.generateSpec(.{ .title = "My API" }, routes);
//!   // In middleware:
//!   pidgn.swagger.ui(.{ .spec_json = spec })

pub const schema = @import("schema.zig");
pub const spec = @import("spec.zig");
pub const middleware = @import("middleware.zig");

// Re-export key types for convenience
pub const ApiDoc = @import("../router/router.zig").ApiDoc;
pub const QueryParamDoc = @import("../router/router.zig").QueryParamDoc;
pub const SecurityScheme = @import("../router/router.zig").SecurityScheme;
pub const SpecConfig = spec.SpecConfig;

// Re-export key functions
pub const generateSpec = spec.generateSpec;
pub const jsonSchema = schema.jsonSchema;
pub const ui = middleware.ui;

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
