//! Signed and encrypted cookies.
//!
//! - `SignedCookies` produces tamper-evident cookies (HMAC-SHA256) — the value
//!   is visible to the client but cannot be modified without detection.
//! - `EncryptedCookies` produces opaque cookies (AES-256-GCM) — the value is
//!   hidden from the client and still tamper-evident.
//!
//! Both are comptime-configured with a secret/key so the helpers stay bound to
//! the configured credential without runtime lookups.
const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const Context = @import("context.zig").Context;
const CookieOptions = Context.CookieOptions;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const base64_url = std.base64.url_safe_no_pad;

/// Fill `buf` with cryptographically secure random bytes from the OS.
fn fillRandom(buf: []u8) void {
    switch (native_os) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
        },
        else => @compileError("OS not supported for secure random"),
    }
}

pub const SignedCookieConfig = struct {
    /// Secret key used to HMAC cookie values. Must be non-empty.
    secret: []const u8,
};

/// Returns a helper namespace bound to a signing secret.
///
/// Usage:
/// ```zig
/// const SC = pidgn.SignedCookies(.{ .secret = env.require("COOKIE_SECRET") });
/// SC.set(ctx, "user_id", "42", .{});
/// if (SC.get(ctx, "user_id")) |v| { ... }
/// ```
pub fn SignedCookies(comptime config: SignedCookieConfig) type {
    if (config.secret.len == 0) @compileError("SignedCookies requires a non-empty secret");

    return struct {
        /// Set a signed cookie. The stored value is `<value>.<mac>` where mac is
        /// URL-safe base64 of HMAC-SHA256(value).
        pub fn set(ctx: *Context, name: []const u8, value: []const u8, opts: CookieOptions) void {
            var mac: [HmacSha256.mac_length]u8 = undefined;
            HmacSha256.create(&mac, value, config.secret);

            const mac_b64_len = base64_url.Encoder.calcSize(mac.len);
            const total = value.len + 1 + mac_b64_len;
            const buf = ctx.allocator.alloc(u8, total) catch return;
            @memcpy(buf[0..value.len], value);
            buf[value.len] = '.';
            _ = base64_url.Encoder.encode(buf[value.len + 1 ..], &mac);

            ctx.response.trackOwnedSlice(ctx.allocator, buf);
            ctx.setCookie(name, buf, opts);
        }

        /// Read and verify a signed cookie. Returns null if missing, malformed,
        /// or if the MAC does not match.
        pub fn get(ctx: *const Context, name: []const u8) ?[]const u8 {
            const raw = ctx.getCookie(name) orelse return null;
            const dot = std.mem.lastIndexOfScalar(u8, raw, '.') orelse return null;
            if (dot == 0 or dot == raw.len - 1) return null;

            const value = raw[0..dot];
            const mac_b64 = raw[dot + 1 ..];

            var provided_mac: [HmacSha256.mac_length]u8 = undefined;
            const decoded_len = base64_url.Decoder.calcSizeForSlice(mac_b64) catch return null;
            if (decoded_len != provided_mac.len) return null;
            base64_url.Decoder.decode(&provided_mac, mac_b64) catch return null;

            var expected_mac: [HmacSha256.mac_length]u8 = undefined;
            HmacSha256.create(&expected_mac, value, config.secret);

            if (!constantTimeEql(&provided_mac, &expected_mac)) return null;
            return value;
        }
    };
}

pub const EncryptedCookieConfig = struct {
    /// 32-byte encryption key. Compile-time error if the wrong length.
    key: [32]u8,
};

/// Returns a helper namespace bound to an AES-256-GCM key.
///
/// Cookie wire format: URL-safe base64 of `nonce(12) || ciphertext || tag(16)`.
pub fn EncryptedCookies(comptime config: EncryptedCookieConfig) type {
    return struct {
        const nonce_len = Aes256Gcm.nonce_length;
        const tag_len = Aes256Gcm.tag_length;

        pub fn set(ctx: *Context, name: []const u8, value: []const u8, opts: CookieOptions) void {
            var nonce: [nonce_len]u8 = undefined;
            fillRandom(&nonce);

            const ct = ctx.allocator.alloc(u8, value.len) catch return;
            defer ctx.allocator.free(ct);
            var tag: [tag_len]u8 = undefined;
            Aes256Gcm.encrypt(ct, &tag, value, "", nonce, config.key);

            const raw_len = nonce_len + ct.len + tag_len;
            const raw = ctx.allocator.alloc(u8, raw_len) catch return;
            defer ctx.allocator.free(raw);
            @memcpy(raw[0..nonce_len], &nonce);
            @memcpy(raw[nonce_len .. nonce_len + ct.len], ct);
            @memcpy(raw[nonce_len + ct.len ..], &tag);

            const b64_len = base64_url.Encoder.calcSize(raw_len);
            const encoded = ctx.allocator.alloc(u8, b64_len) catch return;
            _ = base64_url.Encoder.encode(encoded, raw);

            ctx.response.trackOwnedSlice(ctx.allocator, encoded);
            ctx.setCookie(name, encoded, opts);
        }

        pub fn get(ctx: *const Context, name: []const u8) ?[]const u8 {
            const encoded = ctx.getCookie(name) orelse return null;

            const raw_len = base64_url.Decoder.calcSizeForSlice(encoded) catch return null;
            if (raw_len < nonce_len + tag_len) return null;
            const raw = ctx.allocator.alloc(u8, raw_len) catch return null;
            defer ctx.allocator.free(raw);
            base64_url.Decoder.decode(raw, encoded) catch return null;

            const ct_len = raw_len - nonce_len - tag_len;
            const nonce: *const [nonce_len]u8 = raw[0..nonce_len];
            const ct = raw[nonce_len .. nonce_len + ct_len];
            const tag: *const [tag_len]u8 = raw[nonce_len + ct_len ..][0..tag_len];

            const pt = ctx.allocator.alloc(u8, ct_len) catch return null;
            Aes256Gcm.decrypt(pt, ct, tag.*, "", nonce.*, config.key) catch {
                ctx.allocator.free(pt);
                return null;
            };
            return pt;
        }
    };
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;

fn makeCtx(alloc: std.mem.Allocator, req: *const Request) Context {
    return .{
        .request = req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = alloc,
        .next_handler = null,
    };
}

test "signed cookie round-trip" {
    const SC = SignedCookies(.{ .secret = "top-secret" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Write: set cookie and capture the Set-Cookie value.
    var req1: Request = .{};
    defer req1.deinit(alloc);
    var ctx1 = makeCtx(alloc, &req1);
    SC.set(&ctx1, "uid", "42", .{});
    const set_cookie = ctx1.response.headers.get("Set-Cookie").?;

    // Extract the name=value portion (strip attributes).
    const semi = std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;
    const cookie_pair = set_cookie[0..semi];

    // Read: verify.
    var req2: Request = .{};
    try req2.headers.append(alloc, "Cookie", cookie_pair);
    defer req2.deinit(alloc);
    const ctx2 = makeCtx(alloc, &req2);
    const got = SC.get(&ctx2, "uid") orelse return error.MissingSignedCookie;
    try std.testing.expectEqualStrings("42", got);
}

test "signed cookie rejects tampered value" {
    const SC = SignedCookies(.{ .secret = "top-secret" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{};
    // Deliberately wrong MAC.
    try req.headers.append(alloc, "Cookie", "uid=42.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    defer req.deinit(alloc);
    const ctx = makeCtx(alloc, &req);
    try std.testing.expect(SC.get(&ctx, "uid") == null);
}

test "signed cookie rejects wrong secret" {
    const Writer = SignedCookies(.{ .secret = "one-secret" });
    const Reader = SignedCookies(.{ .secret = "other-secret" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req1: Request = .{};
    defer req1.deinit(alloc);
    var ctx1 = makeCtx(alloc, &req1);
    Writer.set(&ctx1, "uid", "42", .{});
    const set_cookie = ctx1.response.headers.get("Set-Cookie").?;
    const semi = std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;

    var req2: Request = .{};
    try req2.headers.append(alloc, "Cookie", set_cookie[0..semi]);
    defer req2.deinit(alloc);
    const ctx2 = makeCtx(alloc, &req2);
    try std.testing.expect(Reader.get(&ctx2, "uid") == null);
}

test "encrypted cookie round-trip" {
    const key: [32]u8 = [_]u8{0x11} ** 32;
    const EC = EncryptedCookies(.{ .key = key });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req1: Request = .{};
    defer req1.deinit(alloc);
    var ctx1 = makeCtx(alloc, &req1);
    EC.set(&ctx1, "tok", "hello world", .{});
    const set_cookie = ctx1.response.headers.get("Set-Cookie").?;
    const semi = std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;
    const cookie_pair = set_cookie[0..semi];

    // Ciphertext must not contain the plaintext.
    try std.testing.expect(std.mem.indexOf(u8, cookie_pair, "hello world") == null);

    var req2: Request = .{};
    try req2.headers.append(alloc, "Cookie", cookie_pair);
    defer req2.deinit(alloc);
    const ctx2 = makeCtx(alloc, &req2);
    const got = EC.get(&ctx2, "tok") orelse return error.MissingEncryptedCookie;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "encrypted cookie rejects wrong key" {
    const key_a: [32]u8 = [_]u8{0x11} ** 32;
    const key_b: [32]u8 = [_]u8{0x22} ** 32;
    const Writer = EncryptedCookies(.{ .key = key_a });
    const Reader = EncryptedCookies(.{ .key = key_b });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req1: Request = .{};
    defer req1.deinit(alloc);
    var ctx1 = makeCtx(alloc, &req1);
    Writer.set(&ctx1, "tok", "hello", .{});
    const set_cookie = ctx1.response.headers.get("Set-Cookie").?;
    const semi = std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;

    var req2: Request = .{};
    try req2.headers.append(alloc, "Cookie", set_cookie[0..semi]);
    defer req2.deinit(alloc);
    const ctx2 = makeCtx(alloc, &req2);
    try std.testing.expect(Reader.get(&ctx2, "tok") == null);
}
