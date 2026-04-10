//! Pidgn - The Zig Web Framework That Never Sleeps
//!
//! A Phoenix-inspired, batteries-included web framework written in Zig.
//! Blazing fast, memory-safe, with compile-time route resolution.

const std = @import("std");

// Core HTTP
pub const Server = @import("core/server.zig").Server;
pub const Config = @import("core/server.zig").Config;
pub const Handler = @import("core/server.zig").Handler;
pub const TlsConfig = @import("core/server.zig").TlsConfig;

pub const Request = @import("core/http/request.zig").Request;
pub const Method = @import("core/http/request.zig").Method;
pub const Response = @import("core/http/response.zig").Response;
pub const StatusCode = @import("core/http/status.zig").StatusCode;
pub const Headers = @import("core/http/headers.zig").Headers;

// HTTP Parser
pub const parser = @import("core/http/parser.zig");

// Router & Middleware
pub const Router = @import("router/router.zig").Router;
pub const RouteDef = @import("router/router.zig").RouteDef;
pub const Controller = @import("router/router.zig").Controller;
pub const ControllerConfig = @import("router/router.zig").ControllerConfig;
pub const Context = @import("middleware/context.zig").Context;
pub const HandlerFn = @import("middleware/context.zig").HandlerFn;
pub const Params = @import("middleware/context.zig").Params;
pub const Assigns = @import("middleware/context.zig").Assigns;

// Built-in Middleware
pub const logger = @import("middleware/logger.zig").logger;
pub const cors = @import("middleware/cors.zig").cors;
pub const staticFiles = @import("middleware/static.zig").staticFiles;
pub const bodyParser = @import("middleware/body_parser.zig").bodyParser;

// Body Parser Types
pub const FormData = @import("middleware/body_parser.zig").FormData;
pub const ParsedBody = @import("middleware/body_parser.zig").ParsedBody;
pub const FilePart = @import("middleware/body_parser.zig").FilePart;
pub const urlDecode = @import("middleware/body_parser.zig").urlDecode;

// Session & CSRF
pub const session = @import("middleware/session.zig").session;
pub const SessionConfig = @import("middleware/session.zig").SessionConfig;
pub const csrf = @import("middleware/csrf.zig").csrf;
pub const CsrfConfig = @import("middleware/csrf.zig").CsrfConfig;

// htmx Middleware
pub const htmx = @import("middleware/htmx.zig").htmx;
pub const HtmxConfig = @import("middleware/htmx.zig").HtmxConfig;

// Error Handler
pub const errorHandler = @import("middleware/error_handler.zig").errorHandler;
pub const ErrorHandlerConfig = @import("middleware/error_handler.zig").ErrorHandlerConfig;

// Gzip Compression
pub const gzipCompress = @import("middleware/compress.zig").gzipCompress;
pub const CompressConfig = @import("middleware/compress.zig").CompressConfig;

// Rate Limiting
pub const rateLimit = @import("middleware/rate_limit.zig").rateLimit;
pub const RateLimitConfig = @import("middleware/rate_limit.zig").RateLimitConfig;

// Auth Middleware
pub const bearerAuth = @import("middleware/auth.zig").bearerAuth;
pub const BearerConfig = @import("middleware/auth.zig").BearerConfig;
pub const basicAuth = @import("middleware/auth.zig").basicAuth;
pub const BasicAuthConfig = @import("middleware/auth.zig").BasicAuthConfig;
pub const jwtAuth = @import("middleware/auth.zig").jwtAuth;
pub const JwtConfig = @import("middleware/auth.zig").JwtConfig;

// Cache
pub const Cache = @import("core/cache.zig").Cache;
pub const cacheMiddleware = @import("middleware/cache_middleware.zig").cacheMiddleware;
pub const CacheConfig = @import("middleware/cache_middleware.zig").CacheConfig;

// Assets
pub const assets = @import("middleware/assets.zig").assets;
pub const assetPath = @import("middleware/assets.zig").assetPath;
pub const AssetConfig = @import("middleware/assets.zig").AssetConfig;
pub const AssetManifest = @import("middleware/assets.zig").AssetManifest;
pub const getAssetManifest = @import("middleware/assets.zig").getManifest;

// Resource Helper (re-exported from Router)
pub const ResourceHandlers = Router.ResourceHandlers;

// Typed handler helper (auto-detects request/response types for Swagger)
pub const typed = Router.typed;

// WebSocket
pub const WebSocket = @import("core/websocket/connection.zig").WebSocket;
pub const WsMessage = @import("core/websocket/connection.zig").Message;
pub const WsConfig = @import("middleware/websocket.zig").WsConfig;
pub const wsHandler = @import("middleware/websocket.zig").wsHandler; // re-export for live-reload and user WS routes

// Server-Sent Events (SSE)
pub const SseWriter = @import("core/sse.zig").SseWriter;
pub const sseMiddleware = @import("middleware/sse.zig").sseMiddleware;
pub const SseConfig = @import("middleware/sse.zig").SseConfig;

// Live Reload
pub const liveReload = @import("middleware/live_reload.zig").liveReload;
pub const liveReloadWs = @import("middleware/live_reload.zig").liveReloadWs;
pub const LiveReloadConfig = @import("middleware/live_reload.zig").LiveReloadConfig;

// pidgn.js Client Library
pub const pidgnJs = @import("middleware/pidgn_js.zig").pidgnJs;
pub const PidgnJsConfig = @import("middleware/pidgn_js.zig").PidgnJsConfig;

// SSR Bridge
pub const SsrPool = @import("core/ssr.zig").SsrPool;
pub const SsrConfig = @import("core/ssr.zig").SsrConfig;

// WebSocket Protocol (for advanced usage)
pub const ws_protocol = @import("core/websocket/websocket.zig");

// Channel System
pub const Socket = @import("core/channel/socket.zig").Socket;
pub const ChannelDef = @import("core/channel/channel.zig").ChannelDef;
pub const EventHandler = @import("core/channel/channel.zig").EventHandler;
pub const JoinResult = @import("core/channel/channel.zig").JoinResult;
pub const ChannelConfig = @import("middleware/channel.zig").ChannelConfig;
pub const PubSub = @import("core/channel/pubsub.zig").PubSub;
pub const Presence = @import("core/channel/presence.zig").Presence;
pub const channel_mod = @import("core/channel/channel_mod.zig");

// Template Engine
pub const template = @import("template/engine.zig").template;
pub const templateWithPartials = @import("template/engine.zig").templateWithPartials;

// Swagger / OpenAPI
pub const swagger = @import("swagger/root.zig");
pub const ApiDoc = swagger.ApiDoc;
pub const QueryParamDoc = swagger.QueryParamDoc;

// Observability Middleware
pub const structuredLogger = @import("middleware/structured_logger.zig").structuredLogger;
pub const StructuredLoggerConfig = @import("middleware/structured_logger.zig").StructuredLoggerConfig;
pub const LogLevel = @import("middleware/structured_logger.zig").LogLevel;
pub const LogFormat = @import("middleware/structured_logger.zig").LogFormat;
pub const requestId = @import("middleware/request_id.zig").requestId;
pub const RequestIdConfig = @import("middleware/request_id.zig").RequestIdConfig;
pub const telemetryMiddleware = @import("middleware/telemetry.zig").telemetry;
pub const TelemetryConfig = @import("middleware/telemetry.zig").TelemetryConfig;
pub const TelemetryEvent = @import("middleware/telemetry.zig").TelemetryEvent;
pub const metricsMiddleware = @import("middleware/metrics.zig").metrics;
pub const MetricsConfig = @import("middleware/metrics.zig").MetricsConfig;
pub const healthCheck = @import("middleware/health.zig").health;
pub const HealthConfig = @import("middleware/health.zig").HealthConfig;

// Security Scheme (for OpenAPI spec)
pub const SecurityScheme = @import("router/router.zig").SecurityScheme;

// Cookie helpers (re-exported from Context)
pub const CookieOptions = Context.CookieOptions;

// Environment
pub const Env = @import("env.zig").Env;

// Configuration
pub const Environment = @import("config.zig").Environment;
pub const DatabaseUrl = @import("config.zig").DatabaseUrl;
pub const mergeWithEnv = @import("config.zig").mergeWithEnv;
pub const configInit = @import("config.zig").configInit;

// Testing utilities
pub const testing = @import("testing/root.zig");

// Re-export Io for convenience
pub const Io = @import("std").Io;

// Backend info
pub const backend_name = @import("core/server.zig").backend_name;
pub const SelectedBackend = @import("core/server.zig").SelectedBackend;

// Timer (available when backend=libhv)
pub const Timer = if (@hasDecl(SelectedBackend, "Timer")) SelectedBackend.Timer else void;
pub const addTimer = if (@hasDecl(SelectedBackend, "addTimer")) SelectedBackend.addTimer else {};
pub const removeTimer = if (@hasDecl(SelectedBackend, "removeTimer")) SelectedBackend.removeTimer else {};
pub const resetTimer = if (@hasDecl(SelectedBackend, "resetTimer")) SelectedBackend.resetTimer else {};

/// Framework version.
pub const version = "0.3.1-beta.16";

