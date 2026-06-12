// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! JSON-LD (JSON Linked Data) Support
//!
//! Implements JSON-LD 1.1 specification for representing Linked Data in JSON.
//! Provides context expansion, compaction, flattening, and framing operations.
//!
//! Specification: https://www.w3.org/TR/json-ld11/
//!
//! Features:
//! - Context processing and expansion
//! - IRI expansion and compaction
//! - Node object flattening
//! - Framing for data extraction
//! - N-Quads serialization

const std = @import("std");
const json = @import("json.zig");

/// JSON-LD keywords
pub const Keywords = struct {
    pub const context = "@context";
    pub const id = "@id";
    pub const type_kw = "@type";
    pub const value = "@value";
    pub const language = "@language";
    pub const container = "@container";
    pub const list = "@list";
    pub const set = "@set";
    pub const index = "@index";
    pub const reverse = "@reverse";
    pub const graph = "@graph";
    pub const vocab = "@vocab";
    pub const base = "@base";
    pub const version = "@version";
    pub const import_kw = "@import";
    pub const propagate = "@propagate";
    pub const protected = "@protected";
    pub const direction = "@direction";
    pub const json_kw = "@json";
    pub const none = "@none";
    pub const included = "@included";
    pub const nest = "@nest";
    pub const prefix = "@prefix";

    pub fn isKeyword(term: []const u8) bool {
        return term.len > 0 and term[0] == '@';
    }

    pub fn isValidKeyword(term: []const u8) bool {
        if (!isKeyword(term)) return false;
        const keywords = [_][]const u8{
            context, id,      type_kw,   value,     language,  container,
            list,    set,     index,     reverse,   graph,     vocab,
            base,    version, import_kw, propagate, protected, direction,
            json_kw, none,    included,  nest,      prefix,
        };
        for (keywords) |kw| {
            if (std.mem.eql(u8, term, kw)) return true;
        }
        return false;
    }
};

/// IRI types
pub const IriType = enum {
    /// Absolute IRI (e.g., "http://example.org/")
    absolute,
    /// Compact IRI (e.g., "ex:name")
    compact,
    /// Relative IRI reference
    relative,
    /// Blank node identifier (e.g., "_:b0")
    blank,
    /// Keyword (e.g., "@type")
    keyword,
};

/// Determine the type of an IRI
pub fn getIriType(iri: []const u8) IriType {
    if (iri.len == 0) return .relative;

    // Check for keyword
    if (iri[0] == '@') return .keyword;

    // Check for blank node
    if (iri.len >= 2 and iri[0] == '_' and iri[1] == ':') return .blank;

    // Check for absolute IRI (contains "://")
    if (std.mem.indexOf(u8, iri, "://")) |_| return .absolute;

    // Check for compact IRI (contains ":" but not at start)
    if (std.mem.indexOf(u8, iri, ":")) |pos| {
        if (pos > 0 and pos < iri.len - 1) return .compact;
    }

    return .relative;
}

/// Errors that JSON-LD processing can return.
///
/// These supplement the allocator errors (`error.OutOfMemory`) that the
/// recursive algorithms already propagate.
pub const Error = error{
    /// A document, value tree, or context nesting exceeded `Options.max_depth`.
    /// Raised to bound stack usage on untrusted, caller-built `Value` trees
    /// (which are NOT guaranteed to respect the core parser's 256-deep limit).
    MaxDepthExceeded,
    /// A remote `@context` URL was (directly or transitively) re-entered while
    /// it was still being resolved, i.e. a context-resolution cycle.
    RecursiveContext,
    /// A URL-valued `@context` was encountered but no document loader is
    /// configured (or the configured loader returned null for that URL), so the
    /// context cannot be resolved. Raised instead of silently producing output
    /// that ignores the referenced context.
    ContextNotLoaded,
    /// An `@import` context entry was encountered but could not be resolved
    /// (no document loader configured, or the loader returned null). Raised
    /// instead of silently dropping the `@import`.
    ContextImportFailed,
};

/// JSON-LD processing options
pub const Options = struct {
    /// Base IRI for relative IRI resolution
    base: ?[]const u8 = null,
    /// Compact arrays with single elements
    compact_arrays: bool = true,
    /// Compact IRIs using prefixes
    compact_iris: bool = true,
    /// Document loader for remote contexts
    document_loader: ?*const fn ([]const u8) ?json.Value = null,
    /// Maximum nesting depth for recursive processing of caller-built `Value`
    /// trees and `@context` chains. Bounds stack usage on untrusted input so a
    /// deeply nested document returns `error.MaxDepthExceeded` instead of
    /// overflowing the stack. The default matches the core parser's nesting cap.
    max_depth: u32 = 256,
    /// Processing mode (1.0 or 1.1)
    processing_mode: ProcessingMode = .@"1.1",
    /// Produce generalized RDF
    produce_generalized_rdf: bool = false,
    /// Frame expansion mode
    frame_expansion: bool = false,
    /// Use native types for values
    use_native_types: bool = false,
    /// Use @container: @set for repeated properties
    use_rdf_type: bool = false,

    pub const ProcessingMode = enum {
        @"1.0",
        @"1.1",
    };
};

// =============================================================================
// Remote Context Loading
// =============================================================================

/// Remote context loader with caching support
/// Provides a framework for loading JSON-LD contexts from URLs
pub const RemoteContextLoader = struct {
    allocator: std.mem.Allocator,
    /// Cache of loaded contexts
    cache: std.StringHashMap(CacheEntry),
    /// User-provided HTTP fetch function
    fetch_fn: ?*const fn ([]const u8) FetchError![]const u8,
    /// Maximum cache entries
    max_cache_size: usize,
    /// Cache hit/miss statistics
    cache_hits: usize,
    cache_misses: usize,

    const Self = @This();

    pub const FetchError = error{
        NetworkError,
        InvalidUrl,
        NotFound,
        Timeout,
        TooManyRedirects,
    };

    const CacheEntry = struct {
        context: json.Value,
        url: []const u8,
    };

    /// Well-known JSON-LD context URLs
    pub const WellKnown = struct {
        pub const schema_org = "https://schema.org/";
        pub const activitystreams = "https://www.w3.org/ns/activitystreams";
        pub const security_v1 = "https://w3id.org/security/v1";
        pub const did_v1 = "https://www.w3.org/ns/did/v1";
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .fetch_fn = null,
            .max_cache_size = 100,
            .cache_hits = 0,
            .cache_misses = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeValue(self.allocator, entry.value_ptr.context);
        }
        self.cache.deinit();
    }

    /// Set the HTTP fetch function for loading remote contexts
    pub fn setFetchFunction(self: *Self, fetch: *const fn ([]const u8) FetchError![]const u8) void {
        self.fetch_fn = fetch;
    }

    /// Load a context from a URL (with caching)
    pub fn loadContext(self: *Self, url: []const u8) ?json.Value {
        // Check cache first
        if (self.cache.get(url)) |entry| {
            self.cache_hits += 1;
            return entry.context;
        }

        self.cache_misses += 1;

        // Try to fetch the context
        if (self.fetch_fn) |fetch| {
            const content = fetch(url) catch return null;
            defer self.allocator.free(content);

            // Parse the JSON content
            var parse_err: json.ParseError = undefined;
            const doc = json.parse(self.allocator, content, .{}, &parse_err) catch return null;
            const parsed = doc.root;

            // Cache the result
            const url_copy = self.allocator.dupe(u8, url) catch {
                freeValue(self.allocator, parsed);
                return null;
            };

            // Evict oldest entry if cache is full
            if (self.cache.count() >= self.max_cache_size) {
                // Simple eviction: remove first entry.
                //
                // NEW-005: capture the key, stop using the iterator, then
                // `fetchRemove` BEFORE freeing anything. The previous code freed
                // the key and then called `remove(first.key_ptr.*)`, which hashes
                // and compares the just-freed key pointer -- a use-after-free
                // read. `fetchRemove` returns the removed entry while the key is
                // still valid; only then do we free the owned key and value.
                var iter = self.cache.iterator();
                if (iter.next()) |first| {
                    const key = first.key_ptr.*;
                    if (self.cache.fetchRemove(key)) |kv| {
                        freeValue(self.allocator, kv.value.context);
                        self.allocator.free(kv.key);
                    }
                }
            }

            self.cache.put(url_copy, .{ .context = parsed, .url = url_copy }) catch {
                self.allocator.free(url_copy);
                freeValue(self.allocator, parsed);
                return null;
            };

            return parsed;
        }

        return null;
    }

    /// Pre-cache a context for a given URL
    pub fn preloadContext(self: *Self, url: []const u8, context: json.Value) !void {
        const url_copy = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(url_copy);

        try self.cache.put(url_copy, .{ .context = context, .url = url_copy });
    }

    /// Clear the context cache
    pub fn clearCache(self: *Self) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeValue(self.allocator, entry.value_ptr.context);
        }
        self.cache.clearRetainingCapacity();
        self.cache_hits = 0;
        self.cache_misses = 0;
    }

    /// Get cache statistics
    pub fn getCacheStats(self: *Self) struct { hits: usize, misses: usize, size: usize } {
        return .{
            .hits = self.cache_hits,
            .misses = self.cache_misses,
            .size = self.cache.count(),
        };
    }

    /// Create a document_loader callback function for use with Options.
    ///
    /// LIMITATION (GAP-010): Zig has no stateful closures, so the returned
    /// function pointer cannot capture this loader instance. It therefore
    /// returns the `staticLoader` placeholder, which resolves nothing. Because
    /// `processContext` now treats a null loader result for a URL-valued
    /// `@context` (or `@import`) as `error.ContextNotLoaded` /
    /// `error.ContextImportFailed` rather than silently ignoring it, wiring this
    /// default loader up does NOT produce silently-wrong output — URL contexts
    /// will surface a clear error. To actually resolve remote contexts, supply
    /// your own top-level `fn ([]const u8) ?json.Value` in `Options.document_loader`
    /// that consults a `RemoteContextLoader` (or any cache/preload table) you own.
    pub fn createDocumentLoader(self: *Self) *const fn ([]const u8) ?json.Value {
        _ = self;
        return &staticLoader;
    }
};

// Static loader placeholder - users should create their own callbacks.
//
// Always returns null. A null result for a URL-valued @context is no longer
// silently ignored by the processor: it surfaces as error.ContextNotLoaded
// (or error.ContextImportFailed for @import), so this placeholder can never
// cause silently-wrong expansion/compaction output.
fn staticLoader(url: []const u8) ?json.Value {
    _ = url;
    return null;
}

/// Active context for JSON-LD processing
pub const Context = struct {
    allocator: std.mem.Allocator,
    /// Term definitions
    terms: std.StringHashMap(TermDefinition),
    /// Base IRI
    base: ?[]const u8,
    /// Vocabulary mapping
    vocab: ?[]const u8,
    /// Default language
    language: ?[]const u8,
    /// Default direction
    direction: ?Direction,
    /// Previous context (for propagation)
    previous: ?*Context,

    pub const Direction = enum { ltr, rtl };

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .terms = std.StringHashMap(TermDefinition).init(allocator),
            .base = null,
            .vocab = null,
            .language = null,
            .direction = null,
            .previous = null,
        };
    }

    pub fn deinit(self: *Context) void {
        var iter = self.terms.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.terms.deinit();
        if (self.base) |b| self.allocator.free(b);
        if (self.vocab) |v| self.allocator.free(v);
        if (self.language) |l| self.allocator.free(l);
    }

    /// Clone the context
    pub fn clone(self: *Context) !*Context {
        const new_ctx = try self.allocator.create(Context);
        new_ctx.* = Context.init(self.allocator);
        new_ctx.base = if (self.base) |b| try self.allocator.dupe(u8, b) else null;
        new_ctx.vocab = if (self.vocab) |v| try self.allocator.dupe(u8, v) else null;
        new_ctx.language = if (self.language) |l| try self.allocator.dupe(u8, l) else null;
        new_ctx.direction = self.direction;

        var iter = self.terms.iterator();
        while (iter.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            try new_ctx.terms.put(key, try entry.value_ptr.clone(self.allocator));
        }

        return new_ctx;
    }

    /// Get term definition
    pub fn getTerm(self: *const Context, term: []const u8) ?TermDefinition {
        return self.terms.get(term);
    }

    /// Expand a term to an IRI
    /// Expand an IRI value. Returns newly allocated memory that the caller must free.
    pub fn expandIri(self: *const Context, value: []const u8, vocab: bool, document_relative: bool) !?[]const u8 {
        _ = document_relative;
        // Keywords expand to themselves (return owned copy)
        if (Keywords.isKeyword(value)) return try self.allocator.dupe(u8, value);

        // Check term definitions (return owned copy)
        if (self.terms.get(value)) |term_def| {
            if (term_def.iri) |iri| {
                return try self.allocator.dupe(u8, iri);
            }
            return null;
        }

        // Handle compact IRIs
        const iri_type = getIriType(value);
        if (iri_type == .compact) {
            const colon_pos = std.mem.indexOf(u8, value, ":").?;
            const prefix = value[0..colon_pos];
            const suffix = value[colon_pos + 1 ..];

            if (self.terms.get(prefix)) |prefix_def| {
                if (prefix_def.prefix) {
                    // Concatenate prefix IRI with suffix
                    if (prefix_def.iri) |base_iri| {
                        const result = try self.allocator.alloc(u8, base_iri.len + suffix.len);
                        @memcpy(result[0..base_iri.len], base_iri);
                        @memcpy(result[base_iri.len..], suffix);
                        return result;
                    }
                }
            }
        }

        // Use vocabulary mapping
        if (vocab and self.vocab != null) {
            if (self.vocab) |v| {
                const result = try self.allocator.alloc(u8, v.len + value.len);
                @memcpy(result[0..v.len], v);
                @memcpy(result[v.len..], value);
                return result;
            }
        }

        // Return absolute IRIs as-is (return owned copy)
        if (iri_type == .absolute) return try self.allocator.dupe(u8, value);

        return null;
    }
};

/// Term definition in active context
pub const TermDefinition = struct {
    /// The IRI this term expands to
    iri: ?[]const u8,
    /// Whether this term is a prefix
    prefix: bool,
    /// Type coercion
    type_mapping: ?[]const u8,
    /// Language tagging
    language: ?[]const u8,
    /// Direction
    direction: ?Context.Direction,
    /// Container type
    container: ContainerType,
    /// Nest term
    nest: ?[]const u8,
    /// Index mapping
    index: ?[]const u8,
    /// Context for this term
    local_context: ?json.Value,
    /// Whether definition is protected
    protected: bool,
    /// Reverse property
    reverse: bool,

    pub const ContainerType = enum {
        none,
        list,
        set,
        index,
        language,
        id,
        graph,
        type_kw,
    };

    pub fn init() TermDefinition {
        return .{
            .iri = null,
            .prefix = false,
            .type_mapping = null,
            .language = null,
            .direction = null,
            .container = .none,
            .nest = null,
            .index = null,
            .local_context = null,
            .protected = false,
            .reverse = false,
        };
    }

    pub fn deinit(self: *TermDefinition, allocator: std.mem.Allocator) void {
        if (self.iri) |i| allocator.free(i);
        if (self.type_mapping) |t| allocator.free(t);
        if (self.language) |l| allocator.free(l);
        if (self.nest) |n| allocator.free(n);
        if (self.index) |i| allocator.free(i);
    }

    pub fn clone(self: *const TermDefinition, allocator: std.mem.Allocator) !TermDefinition {
        return .{
            .iri = if (self.iri) |i| try allocator.dupe(u8, i) else null,
            .prefix = self.prefix,
            .type_mapping = if (self.type_mapping) |t| try allocator.dupe(u8, t) else null,
            .language = if (self.language) |l| try allocator.dupe(u8, l) else null,
            .direction = self.direction,
            .container = self.container,
            .nest = if (self.nest) |n| try allocator.dupe(u8, n) else null,
            .index = if (self.index) |i| try allocator.dupe(u8, i) else null,
            .local_context = self.local_context,
            .protected = self.protected,
            .reverse = self.reverse,
        };
    }
};

/// JSON-LD Processor
pub const Processor = struct {
    allocator: std.mem.Allocator,
    options: Options,
    active_context: Context,
    /// Per-instance blank node counter. Used to mint deterministic blank node
    /// identifiers (`_:bN`) during flattening. Being per-instance (rather than a
    /// module-global `var`) makes blank node numbering deterministic per run and
    /// free of cross-instance data races / collisions.
    blank_node_counter: u64,
    /// Set of remote `@context` URLs currently being resolved. Used by
    /// `processContext` to detect resolution cycles (a loader returning a
    /// self-referential or mutually-referential context) and fail with
    /// `error.RecursiveContext` instead of looping forever.
    resolving_contexts: std.StringHashMap(void),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, options: Options) Self {
        return .{
            .allocator = allocator,
            .options = options,
            .active_context = Context.init(allocator),
            .blank_node_counter = 0,
            .resolving_contexts = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.active_context.deinit();
        self.resolving_contexts.deinit();
    }

    // =========================================================================
    // Expansion Algorithm (Section 5.1)
    // =========================================================================

    /// Expand a JSON-LD document
    pub fn expand(self: *Self, document: json.Value) !json.Value {
        return self.expandInternal(document, &self.active_context, null, 0);
    }

    fn expandInternal(
        self: *Self,
        element: json.Value,
        active_context: *Context,
        active_property: ?[]const u8,
        depth: u32,
    ) !json.Value {
        _ = active_property;

        if (depth > self.options.max_depth) return Error.MaxDepthExceeded;

        switch (element) {
            .null => return .null,
            .bool => |b| return .{ .bool = b },
            .num => |n| return .{ .num = n },
            .str => |s| {
                // String values are expanded based on context
                if (self.active_context.vocab != null) {
                    // Expand using vocabulary
                    if (try active_context.expandIri(s, true, false)) |expanded| {
                        return .{ .str = expanded };
                    }
                }
                return .{ .str = try self.allocator.dupe(u8, s) };
            },
            .arr => |arr| {
                // Expand each element in the array
                var result: std.ArrayList(json.Value) = .empty;
                // Contents-freeing errdefer (NASR-002): on the error unwind
                // (e.g. MaxDepthExceeded) free each already-expanded child
                // subtree before deiniting the spine, not just the buffer.
                errdefer {
                    for (result.items) |item| freeValue(self.allocator, item);
                    result.deinit(self.allocator);
                }

                for (arr) |item| {
                    const expanded = try self.expandInternal(item, active_context, null, depth + 1);
                    if (expanded != .null) {
                        try result.append(self.allocator, expanded);
                    }
                }

                return .{ .arr = try result.toOwnedSlice(self.allocator) };
            },
            .obj => |obj| {
                // Check for @context and process it
                var local_context = active_context;
                var free_local = false;

                for (obj) |member| {
                    if (std.mem.eql(u8, member.k, Keywords.context)) {
                        local_context = try self.processContext(active_context, member.v, depth + 1);
                        free_local = true;
                        break;
                    }
                }
                defer if (free_local) {
                    local_context.deinit();
                    self.allocator.destroy(local_context);
                };

                // Expand object properties
                var result: std.ArrayList(json.Member) = .empty;
                // Contents-freeing errdefer (NASR-002): on the error unwind free
                // each already-appended member's key string and expanded value
                // subtree before deiniting the spine. The bare spine-only
                // `result.deinit` freed only the buffer, leaking the prefix.
                errdefer {
                    for (result.items) |m| {
                        self.allocator.free(m.k);
                        freeValue(self.allocator, m.v);
                    }
                    result.deinit(self.allocator);
                }

                for (obj) |member| {
                    // Skip @context as it's already processed
                    if (std.mem.eql(u8, member.k, Keywords.context)) continue;

                    // Expand property name
                    const expanded_key = try self.expandKey(local_context, member.k);
                    // Free the in-flight key if value expansion below errors
                    // before it is appended (and thus before ownership moves to
                    // `result`). Cleared once ownership transfers.
                    var key_owned = expanded_key != null;
                    errdefer if (key_owned) self.allocator.free(expanded_key.?);

                    // Expand value
                    const expanded_value = try self.expandInternal(member.v, local_context, member.k, depth + 1);
                    // Free the in-flight value if the append below fails before
                    // ownership moves into `result`.
                    var value_owned = true;
                    errdefer if (value_owned) freeValue(self.allocator, expanded_value);

                    if (expanded_key != null and expanded_value != .null) {
                        try result.append(self.allocator, .{
                            .k = expanded_key.?,
                            .v = expanded_value,
                        });
                        key_owned = false;
                        value_owned = false;
                    } else {
                        // Not appended: free whatever was allocated so it does
                        // not leak on the success path.
                        if (expanded_key) |k| {
                            self.allocator.free(k);
                            key_owned = false;
                        }
                        freeValue(self.allocator, expanded_value);
                        value_owned = false;
                    }
                }

                return .{ .obj = try result.toOwnedSlice(self.allocator) };
            },
        }
    }

    fn expandKey(self: *Self, context: *Context, key: []const u8) !?[]const u8 {
        // Keywords remain unchanged
        if (Keywords.isKeyword(key)) {
            return try self.allocator.dupe(u8, key);
        }

        // Try to expand using term definitions
        if (context.getTerm(key)) |term_def| {
            if (term_def.iri) |iri| {
                return try self.allocator.dupe(u8, iri);
            }
        }

        // Try to expand using IRI expansion
        if (try context.expandIri(key, true, false)) |expanded| {
            return expanded;
        }

        // Return as-is if can't expand
        return try self.allocator.dupe(u8, key);
    }

    // =========================================================================
    // Context Processing (Section 5.2)
    // =========================================================================

    fn processContext(self: *Self, active_context: *Context, local_context: json.Value, depth: u32) (Error || std.mem.Allocator.Error)!*Context {
        if (depth > self.options.max_depth) return Error.MaxDepthExceeded;

        const result = try active_context.clone();
        // NEW-004: `result` is a disposable clone of `active_context` that this
        // function owns until it is either returned or superseded. The `.arr`
        // and `.str` branches reassign the live context as they iterate/recurse
        // and free the prior one in place; `errdefer_target` tracks whichever
        // context is currently live so this error cleanup frees it exactly once
        // and never double-frees a context already freed in-loop. On the success
        // path this errdefer never fires (it is error-only) and the final live
        // context is handed to the caller.
        var errdefer_target = result;
        errdefer {
            errdefer_target.deinit();
            self.allocator.destroy(errdefer_target);
        }

        switch (local_context) {
            .null => {
                // Reset to empty context
                result.terms.clearAndFree();
                result.vocab = null;
                result.base = null;
                result.language = null;
            },
            .str => |s| {
                // Context is a URL - load it via the document loader.
                //
                // Guard against resolution cycles: a loader that returns a
                // (directly or transitively) self-referential context would
                // otherwise recurse forever. Track URLs currently being
                // resolved and fail with RecursiveContext on re-entry.
                if (self.resolving_contexts.contains(s)) {
                    return Error.RecursiveContext;
                }

                const loader = self.options.document_loader orelse
                    return Error.ContextNotLoaded;
                const loaded = loader(s) orelse return Error.ContextNotLoaded;

                const url_key = try self.allocator.dupe(u8, s);
                var key_owned = true;
                defer if (key_owned) self.allocator.free(url_key);
                try self.resolving_contexts.put(url_key, {});
                key_owned = false;
                defer {
                    if (self.resolving_contexts.fetchRemove(s)) |kv| {
                        self.allocator.free(kv.key);
                    }
                }

                // NEW-004: the recursive call CLONES `result` (it does not
                // consume it), so `result` would be orphaned/leaked the same
                // way the `.arr` seed was. The recursive call needs `result`
                // live for its internal clone, so we cannot free `result`
                // first. Capture the recursive result, then free the now-dead
                // seed `result` and return.
                //
                // On the error path the recursive call propagates before
                // `processed` is bound; the function-level errdefer (which
                // still targets `result`) frees the seed exactly once -- no
                // double-free, because `result` is freed below ONLY on the
                // success path where the errdefer never fires.
                const processed = try self.processContext(result, loaded, depth + 1);
                result.deinit();
                self.allocator.destroy(result);
                return processed;
            },
            .obj => |obj| {
                // JSON-LD 1.1 @import (Section 4.1.2): resolve the referenced
                // context and merge it BEFORE processing the rest of this
                // context object. Must be handled first so local definitions
                // override imported ones. We do not silently drop @import.
                for (obj) |member| {
                    if (std.mem.eql(u8, member.k, Keywords.import_kw)) {
                        // A non-string @import value is invalid and must not be
                        // silently dropped (NQUAL-007). @import must reference a
                        // context by IRI string; anything else is unresolvable.
                        if (member.v != .str) return Error.ContextImportFailed;
                        const import_url = member.v.str;

                        // Guard against @import cycles using the same set used
                        // for URL-valued contexts.
                        if (self.resolving_contexts.contains(import_url)) {
                            return Error.RecursiveContext;
                        }

                        const loader = self.options.document_loader orelse
                            return Error.ContextImportFailed;
                        const imported = loader(import_url) orelse
                            return Error.ContextImportFailed;

                        const url_key = try self.allocator.dupe(u8, import_url);
                        var key_owned = true;
                        defer if (key_owned) self.allocator.free(url_key);
                        try self.resolving_contexts.put(url_key, {});
                        key_owned = false;
                        defer {
                            if (self.resolving_contexts.fetchRemove(import_url)) |kv| {
                                self.allocator.free(kv.key);
                            }
                        }

                        // Merge the imported context into `result` in place by
                        // processing it, then swapping the processed context's
                        // contents for `result`'s.
                        const merged = try self.processContext(result, imported, depth + 1);
                        result.deinit();
                        result.* = merged.*;
                        self.allocator.destroy(merged);
                    }
                }

                // Process context definition
                for (obj) |member| {
                    if (std.mem.eql(u8, member.k, Keywords.version)) {
                        // Handle @version
                        continue;
                    } else if (std.mem.eql(u8, member.k, Keywords.import_kw)) {
                        // Already handled above.
                        continue;
                    } else if (std.mem.eql(u8, member.k, Keywords.base)) {
                        // Handle @base
                        if (member.v == .str) {
                            if (result.base) |b| self.allocator.free(b);
                            result.base = try self.allocator.dupe(u8, member.v.str);
                        }
                    } else if (std.mem.eql(u8, member.k, Keywords.vocab)) {
                        // Handle @vocab
                        if (member.v == .str) {
                            if (result.vocab) |v| self.allocator.free(v);
                            result.vocab = try self.allocator.dupe(u8, member.v.str);
                        }
                    } else if (std.mem.eql(u8, member.k, Keywords.language)) {
                        // Handle @language
                        if (member.v == .str) {
                            if (result.language) |l| self.allocator.free(l);
                            result.language = try self.allocator.dupe(u8, member.v.str);
                        }
                    } else if (std.mem.eql(u8, member.k, Keywords.direction)) {
                        // Handle @direction
                        if (member.v == .str) {
                            result.direction = if (std.mem.eql(u8, member.v.str, "ltr"))
                                .ltr
                            else if (std.mem.eql(u8, member.v.str, "rtl"))
                                .rtl
                            else
                                null;
                        }
                    } else if (!Keywords.isKeyword(member.k)) {
                        // Create term definition
                        try self.createTermDefinition(result, member.k, member.v);
                    }
                }
            },
            .arr => |arr| {
                // Process array of contexts in order.
                //
                // NEW-004: each recursive `processContext` CLONES `current`
                // (it does not consume it), so after every iteration the prior
                // `current` is orphaned and must be freed -- including the seed
                // clone `result` on the first iteration. The old `if (i > 0)`
                // guard skipped freeing the seed, leaking one Context per call.
                //
                // To avoid double-freeing with the function-level errdefer we
                // advance `errdefer_target` to the new live context BEFORE
                // freeing the old one: if `processContext` below errors on a
                // later iteration, the errdefer frees only the still-live
                // `current` (already freed seeds are no longer referenced).
                var current = result;
                for (arr) |ctx| {
                    const processed = try self.processContext(current, ctx, depth + 1);
                    // `processed` is now the live context; make the errdefer
                    // target it, then free the superseded `current`.
                    errdefer_target = processed;
                    current.deinit();
                    self.allocator.destroy(current);
                    current = processed;
                }
                return current;
            },
            else => {},
        }

        return result;
    }

    fn createTermDefinition(self: *Self, context: *Context, term: []const u8, definition: json.Value) !void {
        var term_def = TermDefinition.init();
        // Partial-build leak guard (NASR/OOM): the fields below (iri /
        // type_mapping / language) are duped incrementally. If any later dupe --
        // or the `key` dupe / `terms.put` at the end -- fails, free the
        // already-duped fields. `TermDefinition.deinit` frees exactly those owned
        // slices. errdefer does NOT fire on the early `.null`/`else` returns
        // (those return normally), and on the success path ownership of
        // `term_def` moves into the map before this scope exits, so the cleanup
        // only runs on the OOM/error unwind.
        errdefer term_def.deinit(self.allocator);

        switch (definition) {
            .null => {
                // Null removes the term
                if (context.terms.fetchRemove(term)) |entry| {
                    self.allocator.free(entry.key);
                    var val = entry.value;
                    val.deinit(self.allocator);
                }
                return;
            },
            .str => |s| {
                // Simple term definition - just an IRI mapping
                term_def.iri = try self.allocator.dupe(u8, s);
            },
            .obj => |obj| {
                // Full term definition
                for (obj) |member| {
                    if (std.mem.eql(u8, member.k, Keywords.id)) {
                        if (member.v == .str) {
                            term_def.iri = try self.allocator.dupe(u8, member.v.str);
                        }
                    } else if (std.mem.eql(u8, member.k, Keywords.type_kw)) {
                        if (member.v == .str) {
                            term_def.type_mapping = try self.allocator.dupe(u8, member.v.str);
                        }
                    } else if (std.mem.eql(u8, member.k, Keywords.language)) {
                        if (member.v == .str) {
                            term_def.language = try self.allocator.dupe(u8, member.v.str);
                        }
                    } else if (std.mem.eql(u8, member.k, Keywords.container)) {
                        if (member.v == .str) {
                            term_def.container = self.parseContainerType(member.v.str);
                        }
                    } else if (std.mem.eql(u8, member.k, Keywords.reverse)) {
                        term_def.reverse = member.v == .bool and member.v.bool;
                    } else if (std.mem.eql(u8, member.k, Keywords.prefix)) {
                        term_def.prefix = member.v == .bool and member.v.bool;
                    } else if (std.mem.eql(u8, member.k, Keywords.protected)) {
                        term_def.protected = member.v == .bool and member.v.bool;
                    }
                }

                // If no @id, use term as IRI
                if (term_def.iri == null) {
                    term_def.iri = try self.allocator.dupe(u8, term);
                }
            },
            else => return,
        }

        const key = try self.allocator.dupe(u8, term);
        // If the map insertion fails, free the just-duped key (the `term_def`
        // errdefer above frees its fields). On success, ownership of both `key`
        // and `term_def` moves into the map.
        errdefer self.allocator.free(key);
        try context.terms.put(key, term_def);
    }

    fn parseContainerType(self: *Self, value: []const u8) TermDefinition.ContainerType {
        _ = self;
        if (std.mem.eql(u8, value, Keywords.list)) return .list;
        if (std.mem.eql(u8, value, Keywords.set)) return .set;
        if (std.mem.eql(u8, value, Keywords.index)) return .index;
        if (std.mem.eql(u8, value, Keywords.language)) return .language;
        if (std.mem.eql(u8, value, Keywords.id)) return .id;
        if (std.mem.eql(u8, value, Keywords.graph)) return .graph;
        if (std.mem.eql(u8, value, Keywords.type_kw)) return .type_kw;
        return .none;
    }

    // =========================================================================
    // Compaction Algorithm (Section 5.3)
    // =========================================================================

    /// Compact an expanded JSON-LD document
    pub fn compact(self: *Self, document: json.Value, context: json.Value) !json.Value {
        // First, expand the document
        const expanded = try self.expand(document);
        defer freeValue(self.allocator, expanded);

        // Process the compaction context
        const compact_context = try self.processContext(&self.active_context, context, 0);
        defer {
            compact_context.deinit();
            self.allocator.destroy(compact_context);
        }

        // Compact the expanded document
        return self.compactInternal(expanded, compact_context, 0);
    }

    fn compactInternal(self: *Self, element: json.Value, context: *Context, depth: u32) (Error || std.mem.Allocator.Error)!json.Value {
        if (depth > self.options.max_depth) return Error.MaxDepthExceeded;

        switch (element) {
            .null, .bool, .num => return element,
            .str => |s| {
                // Try to compact IRI
                return .{ .str = try self.compactIri(context, s) };
            },
            .arr => |arr| {
                var result: std.ArrayList(json.Value) = .empty;
                // Contents-freeing errdefer (NASR-002): free already-compacted
                // child subtrees on the error unwind, not just the buffer.
                errdefer {
                    for (result.items) |item| freeValue(self.allocator, item);
                    result.deinit(self.allocator);
                }

                for (arr) |item| {
                    const compacted = try self.compactInternal(item, context, depth + 1);
                    // Free the in-flight subtree if the append fails before
                    // ownership moves into `result`.
                    var owned = true;
                    errdefer if (owned) freeValue(self.allocator, compacted);
                    try result.append(self.allocator, compacted);
                    owned = false;
                }

                // Compact arrays with single element if enabled
                if (self.options.compact_arrays and result.items.len == 1) {
                    const single = result.items[0];
                    result.deinit(self.allocator);
                    return single;
                }

                return .{ .arr = try result.toOwnedSlice(self.allocator) };
            },
            .obj => |obj| {
                var result: std.ArrayList(json.Member) = .empty;
                // Contents-freeing errdefer (NASR-002): free each already-built
                // member's key string and compacted value subtree on the error
                // unwind before deiniting the spine.
                errdefer {
                    for (result.items) |m| {
                        self.allocator.free(m.k);
                        freeValue(self.allocator, m.v);
                    }
                    result.deinit(self.allocator);
                }

                for (obj) |member| {
                    const compacted_key = try self.compactIri(context, member.k);
                    // Free the in-flight key if value compaction errors before
                    // the member is appended (ownership moves on append).
                    var key_owned = true;
                    errdefer if (key_owned) self.allocator.free(compacted_key);

                    const compacted_value = try self.compactInternal(member.v, context, depth + 1);
                    // Free the in-flight value if the append fails before
                    // ownership moves into `result`.
                    var value_owned = true;
                    errdefer if (value_owned) freeValue(self.allocator, compacted_value);
                    try result.append(self.allocator, .{
                        .k = compacted_key,
                        .v = compacted_value,
                    });
                    key_owned = false;
                    value_owned = false;
                }

                return .{ .obj = try result.toOwnedSlice(self.allocator) };
            },
        }
    }

    fn compactIri(self: *Self, context: *Context, iri: []const u8) ![]const u8 {
        // Check if IRI matches a term definition
        var iter = context.terms.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.iri) |term_iri| {
                if (std.mem.eql(u8, term_iri, iri)) {
                    return try self.allocator.dupe(u8, entry.key_ptr.*);
                }
            }
        }

        // Try to create compact IRI with prefix
        if (self.options.compact_iris) {
            iter = context.terms.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.prefix) {
                    if (entry.value_ptr.iri) |prefix_iri| {
                        if (std.mem.startsWith(u8, iri, prefix_iri)) {
                            const suffix = iri[prefix_iri.len..];
                            const result = try self.allocator.alloc(u8, entry.key_ptr.len + 1 + suffix.len);
                            @memcpy(result[0..entry.key_ptr.len], entry.key_ptr.*);
                            result[entry.key_ptr.len] = ':';
                            @memcpy(result[entry.key_ptr.len + 1 ..], suffix);
                            return result;
                        }
                    }
                }
            }
        }

        // Return IRI as-is
        return try self.allocator.dupe(u8, iri);
    }

    // =========================================================================
    // Flattening Algorithm (Section 5.4)
    // =========================================================================

    /// Flatten a JSON-LD document
    pub fn flatten(self: *Self, document: json.Value, context: ?json.Value) !json.Value {
        // First, expand the document
        const expanded = try self.expand(document);
        defer freeValue(self.allocator, expanded);

        // Generate node map
        var node_map = std.StringHashMap(json.Value).init(self.allocator);
        defer {
            var iter = node_map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                freeValue(self.allocator, entry.value_ptr.*);
            }
            node_map.deinit();
        }

        try self.generateNodeMap(expanded, &node_map, null, 0);

        // Create flattened output.
        //
        // PERF-010: transfer ownership of each node out of the node map instead
        // of deep-cloning it a second time. `generateNodeMap` already produced
        // an owned deep copy in the map; we move that value into the graph and
        // replace the map slot with `.null` so the map's cleanup defer does not
        // double-free it. The key remains owned by the map (freed by the defer).
        var graph: std.ArrayList(json.Value) = .empty;
        errdefer graph.deinit(self.allocator);

        var iter = node_map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == .obj) {
                // Move the node out of the map (ownership transfer, no clone).
                const moved = entry.value_ptr.*;
                entry.value_ptr.* = .null;
                try graph.append(self.allocator, moved);
            }
        }

        // Create result with @graph
        var result_members: std.ArrayList(json.Member) = .empty;
        errdefer result_members.deinit(self.allocator);

        try result_members.append(self.allocator, .{
            .k = try self.allocator.dupe(u8, Keywords.graph),
            .v = .{ .arr = try graph.toOwnedSlice(self.allocator) },
        });

        const result = json.Value{ .obj = try result_members.toOwnedSlice(self.allocator) };

        // Compact if context provided
        if (context) |ctx| {
            const compacted = try self.compact(result, ctx);
            freeValue(self.allocator, result);
            return compacted;
        }

        return result;
    }

    fn generateNodeMap(
        self: *Self,
        element: json.Value,
        node_map: *std.StringHashMap(json.Value),
        active_graph: ?[]const u8,
        depth: u32,
    ) (Error || std.mem.Allocator.Error)!void {
        if (depth > self.options.max_depth) return Error.MaxDepthExceeded;

        switch (element) {
            .arr => |arr| {
                for (arr) |item| {
                    try self.generateNodeMap(item, node_map, active_graph, depth + 1);
                }
            },
            .obj => |obj| {
                // Get or generate @id
                var id: ?[]const u8 = null;
                for (obj) |member| {
                    if (std.mem.eql(u8, member.k, Keywords.id)) {
                        if (member.v == .str) {
                            id = member.v.str;
                            break;
                        }
                    }
                }

                if (id == null) {
                    // Generate blank node ID
                    id = try self.generateBlankNodeId();
                }

                // Clone the object into node map (depth-bounded so an untrusted
                // deeply nested node cannot overflow the stack here either).
                const key = try self.allocator.dupe(u8, id.?);
                const value = try cloneValueDepth(self.allocator, element, depth, self.options.max_depth);
                try node_map.put(key, value);

                // Process nested nodes
                for (obj) |member| {
                    if (member.v == .obj or member.v == .arr) {
                        try self.generateNodeMap(member.v, node_map, active_graph, depth + 1);
                    }
                }
            },
            else => {},
        }
    }

    fn generateBlankNodeId(self: *Self) ![]const u8 {
        // Per-instance counter (ASR-023 / GAP-009): blank node ids are
        // deterministic per processing run and free of cross-instance data
        // races, rather than sharing one module-global counter across every
        // processor instance.
        const id = self.blank_node_counter;
        self.blank_node_counter += 1;

        var buf: [32]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable;
        const result = try self.allocator.alloc(u8, 3 + digits.len);
        result[0] = '_';
        result[1] = ':';
        result[2] = 'b';
        @memcpy(result[3..], digits);
        return result;
    }

    // =========================================================================
    // Framing Algorithm (Section 5.5)
    // =========================================================================

    /// Frame a JSON-LD document
    pub fn frame(self: *Self, document: json.Value, frame_val: json.Value) !json.Value {
        // First, expand the document
        const expanded = try self.expand(document);
        defer freeValue(self.allocator, expanded);

        // Expand the frame
        const expanded_frame = try self.expand(frame_val);
        defer freeValue(self.allocator, expanded_frame);

        // Frame the document
        return self.frameInternal(expanded, expanded_frame, 0);
    }

    fn frameInternal(self: *Self, input: json.Value, frame_val: json.Value, depth: u32) (Error || std.mem.Allocator.Error)!json.Value {
        if (depth > self.options.max_depth) return Error.MaxDepthExceeded;

        // Match input against frame pattern
        if (frame_val != .obj) {
            return try cloneValueDepth(self.allocator, input, depth, self.options.max_depth);
        }

        const frame_obj = frame_val.obj;

        if (input == .arr) {
            var result: std.ArrayList(json.Value) = .empty;
            // Contents-freeing errdefer (NASR-002): free already-framed child
            // subtrees on the error unwind, not just the buffer.
            errdefer {
                for (result.items) |item| freeValue(self.allocator, item);
                result.deinit(self.allocator);
            }

            for (input.arr) |item| {
                if (try self.matchesFrame(item, frame_obj)) {
                    const framed = try self.frameInternal(item, frame_val, depth + 1);
                    try result.append(self.allocator, framed);
                }
            }

            return .{ .arr = try result.toOwnedSlice(self.allocator) };
        }

        if (input != .obj) {
            return try cloneValueDepth(self.allocator, input, depth, self.options.max_depth);
        }

        // Match object against frame
        if (!try self.matchesFrame(input, frame_obj)) {
            return .null;
        }

        // Build framed result
        var result: std.ArrayList(json.Member) = .empty;
        // Contents-freeing errdefer (NASR-002): free each already-built
        // member's key string and framed value subtree on the error unwind
        // before deiniting the spine.
        errdefer {
            for (result.items) |m| {
                self.allocator.free(m.k);
                freeValue(self.allocator, m.v);
            }
            result.deinit(self.allocator);
        }

        // Include all properties from frame
        for (frame_obj) |frame_member| {
            // Find matching property in input
            for (input.obj) |input_member| {
                if (std.mem.eql(u8, frame_member.k, input_member.k)) {
                    const framed_value = try self.frameInternal(input_member.v, frame_member.v, depth + 1);
                    // Free the in-flight framed value if the key dupe or append
                    // below fails before ownership moves into `result`.
                    errdefer freeValue(self.allocator, framed_value);
                    const framed_key = try self.allocator.dupe(u8, frame_member.k);
                    errdefer self.allocator.free(framed_key);
                    try result.append(self.allocator, .{
                        .k = framed_key,
                        .v = framed_value,
                    });
                    break;
                }
            }
        }

        return .{ .obj = try result.toOwnedSlice(self.allocator) };
    }

    fn matchesFrame(self: *Self, value: json.Value, frame_obj: []const json.Member) !bool {
        _ = self;
        if (value != .obj) return false;

        // Check @type constraint
        for (frame_obj) |frame_member| {
            if (std.mem.eql(u8, frame_member.k, Keywords.type_kw)) {
                var found = false;
                for (value.obj) |value_member| {
                    if (std.mem.eql(u8, value_member.k, Keywords.type_kw)) {
                        if (valuesMatch(frame_member.v, value_member.v)) {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found and frame_member.v != .obj) {
                    return false;
                }
            }
        }

        return true;
    }

    fn valuesMatch(a: json.Value, b: json.Value) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;

        switch (a) {
            .null => return true,
            .bool => |av| return av == b.bool,
            .str => |as| return std.mem.eql(u8, as, b.str),
            .num => |an| return std.mem.eql(u8, an.lexeme, b.num.lexeme),
            .arr => |aa| {
                if (aa.len != b.arr.len) return false;
                for (aa, b.arr) |ai, bi| {
                    if (!valuesMatch(ai, bi)) return false;
                }
                return true;
            },
            .obj => return false, // Objects don't match directly
        }
    }

    // =========================================================================
    // N-Quads Serialization (Section 9)
    // =========================================================================

    /// Convert JSON-LD to N-Quads format
    /// Note: The returned string is owned by the caller.
    /// Warning: expand() may return references to input document strings,
    /// so the input document must remain valid until this function returns.
    /// The caller is responsible for managing the input document's memory.
    pub fn toNQuads(self: *Self, document: json.Value) ![]const u8 {
        // Expand the document
        // Note: expanded result may share memory with input document
        const expanded = try self.expand(document);
        // Don't free expanded as it may reference input strings

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        try self.serializeNQuads(&result, expanded, null);

        return result.toOwnedSlice(self.allocator);
    }

    fn serializeNQuads(self: *Self, output: *std.ArrayList(u8), element: json.Value, subject: ?[]const u8) !void {
        switch (element) {
            .arr => |arr| {
                for (arr) |item| {
                    try self.serializeNQuads(output, item, subject);
                }
            },
            .obj => |obj| {
                // Get subject
                var subj = subject;
                for (obj) |member| {
                    if (std.mem.eql(u8, member.k, Keywords.id)) {
                        if (member.v == .str) {
                            subj = member.v.str;
                            break;
                        }
                    }
                }

                if (subj == null) {
                    subj = "_:b0";
                }

                // Serialize each predicate-object pair
                for (obj) |member| {
                    if (std.mem.eql(u8, member.k, Keywords.id)) continue;
                    if (std.mem.eql(u8, member.k, Keywords.context)) continue;

                    const predicate = member.k;

                    try self.serializeQuad(output, subj.?, predicate, member.v);
                }
            },
            else => {},
        }
    }

    fn serializeQuad(self: *Self, output: *std.ArrayList(u8), subject: []const u8, predicate: []const u8, object: json.Value) !void {
        // Subject
        if (std.mem.startsWith(u8, subject, "_:")) {
            try output.appendSlice(self.allocator, subject);
        } else {
            try output.append(self.allocator, '<');
            try output.appendSlice(self.allocator, subject);
            try output.append(self.allocator, '>');
        }
        try output.append(self.allocator, ' ');

        // Predicate
        try output.append(self.allocator, '<');
        try output.appendSlice(self.allocator, predicate);
        try output.append(self.allocator, '>');
        try output.append(self.allocator, ' ');

        // Object
        switch (object) {
            .str => |s| {
                try output.append(self.allocator, '"');
                try self.escapeNQuadsString(output, s);
                try output.append(self.allocator, '"');
            },
            .bool => |b| {
                try output.appendSlice(self.allocator, if (b) "\"true\"" else "\"false\"");
                try output.appendSlice(self.allocator, "^^<http://www.w3.org/2001/XMLSchema#boolean>");
            },
            .num => |n| {
                try output.append(self.allocator, '"');
                try output.appendSlice(self.allocator, n.lexeme);
                try output.append(self.allocator, '"');
                if (std.mem.indexOf(u8, n.lexeme, ".") != null) {
                    try output.appendSlice(self.allocator, "^^<http://www.w3.org/2001/XMLSchema#double>");
                } else {
                    try output.appendSlice(self.allocator, "^^<http://www.w3.org/2001/XMLSchema#integer>");
                }
            },
            .obj => |obj| {
                // Check for @value
                for (obj) |member| {
                    if (std.mem.eql(u8, member.k, Keywords.value)) {
                        return self.serializeQuad(output, subject, predicate, member.v);
                    }
                    if (std.mem.eql(u8, member.k, Keywords.id)) {
                        if (member.v == .str) {
                            if (std.mem.startsWith(u8, member.v.str, "_:")) {
                                try output.appendSlice(self.allocator, member.v.str);
                            } else {
                                try output.append(self.allocator, '<');
                                try output.appendSlice(self.allocator, member.v.str);
                                try output.append(self.allocator, '>');
                            }
                            try output.appendSlice(self.allocator, " .\n");
                            return;
                        }
                    }
                }
                return;
            },
            .arr => |arr| {
                for (arr) |item| {
                    try self.serializeQuad(output, subject, predicate, item);
                }
                return;
            },
            .null => return,
        }

        try output.appendSlice(self.allocator, " .\n");
    }

    fn escapeNQuadsString(self: *Self, output: *std.ArrayList(u8), s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '\n' => try output.appendSlice(self.allocator, "\\n"),
                '\r' => try output.appendSlice(self.allocator, "\\r"),
                '"' => try output.appendSlice(self.allocator, "\\\""),
                '\\' => try output.appendSlice(self.allocator, "\\\\"),
                else => try output.append(self.allocator, c),
            }
        }
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn freeValue(allocator: std.mem.Allocator, value: json.Value) void {
    switch (value) {
        .null, .bool, .num => {},
        .str => |s| allocator.free(s),
        .arr => |arr| {
            for (arr) |item| {
                freeValue(allocator, item);
            }
            allocator.free(arr);
        },
        .obj => |obj| {
            for (obj) |m| {
                allocator.free(m.k);
                freeValue(allocator, m.v);
            }
            allocator.free(obj);
        },
    }
}

fn cloneValue(allocator: std.mem.Allocator, value: json.Value) !json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .num => |n| return .{ .num = n },
        .str => |s| return .{ .str = try allocator.dupe(u8, s) },
        .arr => |arr| {
            var result = try allocator.alloc(json.Value, arr.len);
            for (arr, 0..) |item, i| {
                result[i] = try cloneValue(allocator, item);
            }
            return .{ .arr = result };
        },
        .obj => |obj| {
            var result = try allocator.alloc(json.Member, obj.len);
            for (obj, 0..) |m, i| {
                result[i] = .{
                    .k = try allocator.dupe(u8, m.k),
                    .v = try cloneValue(allocator, m.v),
                };
            }
            return .{ .obj = result };
        },
    }
}

/// Depth-bounded deep clone. Mirrors `cloneValue` but returns
/// `Error.MaxDepthExceeded` once `depth` exceeds `max_depth`, so cloning an
/// untrusted, deeply nested `Value` tree cannot overflow the stack. Partial
/// allocations on the error path are released so no memory leaks.
fn cloneValueDepth(
    allocator: std.mem.Allocator,
    value: json.Value,
    depth: u32,
    max_depth: u32,
) (Error || std.mem.Allocator.Error)!json.Value {
    if (depth > max_depth) return Error.MaxDepthExceeded;

    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .num => |n| return .{ .num = n },
        .str => |s| return .{ .str = try allocator.dupe(u8, s) },
        .arr => |arr| {
            var result = try allocator.alloc(json.Value, arr.len);
            var filled: usize = 0;
            errdefer {
                for (result[0..filled]) |item| freeValue(allocator, item);
                allocator.free(result);
            }
            for (arr, 0..) |item, i| {
                result[i] = try cloneValueDepth(allocator, item, depth + 1, max_depth);
                filled = i + 1;
            }
            return .{ .arr = result };
        },
        .obj => |obj| {
            var result = try allocator.alloc(json.Member, obj.len);
            var filled: usize = 0;
            errdefer {
                for (result[0..filled]) |m| {
                    allocator.free(m.k);
                    freeValue(allocator, m.v);
                }
                allocator.free(result);
            }
            for (obj, 0..) |m, i| {
                const k = try allocator.dupe(u8, m.k);
                errdefer allocator.free(k);
                const v = try cloneValueDepth(allocator, m.v, depth + 1, max_depth);
                result[i] = .{ .k = k, .v = v };
                filled = i + 1;
            }
            return .{ .obj = result };
        },
    }
}

// =============================================================================
// Convenience Functions
// =============================================================================

/// Expand a JSON-LD document
pub fn expand(allocator: std.mem.Allocator, document: json.Value, options: Options) !json.Value {
    var processor = Processor.init(allocator, options);
    defer processor.deinit();
    return processor.expand(document);
}

/// Compact a JSON-LD document
pub fn compact(allocator: std.mem.Allocator, document: json.Value, context: json.Value, options: Options) !json.Value {
    var processor = Processor.init(allocator, options);
    defer processor.deinit();
    return processor.compact(document, context);
}

/// Flatten a JSON-LD document
pub fn flatten(allocator: std.mem.Allocator, document: json.Value, context: ?json.Value, options: Options) !json.Value {
    var processor = Processor.init(allocator, options);
    defer processor.deinit();
    return processor.flatten(document, context);
}

/// Frame a JSON-LD document
pub fn frame(allocator: std.mem.Allocator, document: json.Value, frame_val: json.Value, options: Options) !json.Value {
    var processor = Processor.init(allocator, options);
    defer processor.deinit();
    return processor.frame(document, frame_val);
}

/// Convert JSON-LD to N-Quads
pub fn toNQuads(allocator: std.mem.Allocator, document: json.Value, options: Options) ![]const u8 {
    var processor = Processor.init(allocator, options);
    defer processor.deinit();
    return processor.toNQuads(document);
}

// =============================================================================
// Tests
// =============================================================================

test "Keywords.isKeyword" {
    try std.testing.expect(Keywords.isKeyword("@context"));
    try std.testing.expect(Keywords.isKeyword("@id"));
    try std.testing.expect(Keywords.isKeyword("@type"));
    try std.testing.expect(!Keywords.isKeyword("name"));
    try std.testing.expect(!Keywords.isKeyword(""));
}

test "getIriType" {
    try std.testing.expectEqual(IriType.absolute, getIriType("http://example.org/"));
    try std.testing.expectEqual(IriType.compact, getIriType("ex:name"));
    try std.testing.expectEqual(IriType.blank, getIriType("_:b0"));
    try std.testing.expectEqual(IriType.keyword, getIriType("@type"));
    try std.testing.expectEqual(IriType.relative, getIriType("name"));
}

test "Context basic operations" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Add a term
    var term_def = TermDefinition.init();
    term_def.iri = try allocator.dupe(u8, "http://example.org/name");
    const key = try allocator.dupe(u8, "name");
    try ctx.terms.put(key, term_def);

    const found = ctx.getTerm("name");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("http://example.org/name", found.?.iri.?);
}

test "Processor expand simple" {
    const allocator = std.testing.allocator;
    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    const result = try processor.expand(.{ .str = "hello" });
    defer freeValue(allocator, result);

    try std.testing.expect(result == .str);
    try std.testing.expectEqualStrings("hello", result.str);
}

test "Processor expand with context" {
    const allocator = std.testing.allocator;
    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    // Create a document with context
    var ctx_members = [_]json.Member{
        .{ .k = "name", .v = .{ .str = "http://schema.org/name" } },
    };
    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .obj = &ctx_members } },
        .{ .k = "name", .v = .{ .str = "Alice" } },
    };

    const result = try processor.expand(.{ .obj = &doc_members });
    defer freeValue(allocator, result);

    try std.testing.expect(result == .obj);
}

test "toNQuads basic" {
    // Use arena allocator to avoid tracking individual allocations
    // since expand() has complex shared memory semantics
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Use compile-time string literals which don't need freeing
    var members = [_]json.Member{
        .{ .k = "@id", .v = .{ .str = "http://example.org/person/1" } },
        .{ .k = "http://schema.org/name", .v = .{ .str = "Alice" } },
    };

    const nquads = try toNQuads(allocator, .{ .obj = &members }, .{});

    try std.testing.expect(nquads.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, nquads, "Alice") != null);
}

test "RemoteContextLoader init/deinit" {
    // Use arena allocator since contexts may reference string literals
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var loader = RemoteContextLoader.init(allocator);
    defer loader.deinit();

    // Initial stats should be zero
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 0), stats.hits);
    try std.testing.expectEqual(@as(usize, 0), stats.misses);
    try std.testing.expectEqual(@as(usize, 0), stats.size);
}

test "RemoteContextLoader cache operations" {
    // Use arena allocator since contexts may reference string literals
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var loader = RemoteContextLoader.init(allocator);
    // Don't defer deinit - arena handles cleanup

    // Preload a simple context (just null value to avoid string freeing issues)
    try loader.preloadContext("https://example.org/context.jsonld", .null);

    // Should be in cache
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.size);

    // Load should return the cached context
    const loaded = loader.loadContext("https://example.org/context.jsonld");
    try std.testing.expect(loaded != null);
    try std.testing.expect(loaded.? == .null);

    // Should count as hit
    const stats2 = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats2.hits);
}

test "RemoteContextLoader loadContext miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var loader = RemoteContextLoader.init(allocator);

    // Without a fetch function, load should fail
    const loaded = loader.loadContext("https://example.org/unknown.jsonld");
    try std.testing.expect(loaded == null);

    // Should count as miss
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.misses);
}

test "RemoteContextLoader clearCache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var loader = RemoteContextLoader.init(allocator);

    // Preload a context (use null to avoid string issues)
    try loader.preloadContext("https://example.org/test.jsonld", .null);

    // Verify it's there
    try std.testing.expectEqual(@as(usize, 1), loader.getCacheStats().size);

    // Clear the cache
    loader.clearCache();

    // Should be empty
    try std.testing.expectEqual(@as(usize, 0), loader.getCacheStats().size);
    try std.testing.expectEqual(@as(usize, 0), loader.getCacheStats().hits);
}

// NEW-005: fetch function for the cache-eviction UAF test. The loader frees the
// returned content with its own allocator, so the content must be allocated by
// the same allocator. A bare `fn` pointer carries no allocator, so the test
// publishes one here before driving the loader.
var new005_fetch_allocator: ?std.mem.Allocator = null;
fn new005FetchFn(url: []const u8) RemoteContextLoader.FetchError![]const u8 {
    _ = url;
    const a = new005_fetch_allocator orelse return error.NetworkError;
    // Minimal valid JSON object; parsed and cached by loadContext.
    return a.dupe(u8, "{}") catch return error.NetworkError;
}

test "NEW-005: cache eviction does not use freed key (no UAF)" {
    // Leak/UAF-detecting allocator (NOT an arena): a use-after-free read of the
    // evicted key and any leak of the evicted entry are caught here.
    const allocator = std.testing.allocator;

    var loader = RemoteContextLoader.init(allocator);
    defer loader.deinit();

    // Shrink the cache so a single extra load forces an eviction.
    loader.max_cache_size = 2;
    new005_fetch_allocator = allocator;
    defer new005_fetch_allocator = null;
    loader.setFetchFunction(new005FetchFn);

    // Fill the cache to capacity with real heap-owned keys/values (preload dupes
    // the URL key with `allocator`, so eviction must free it with `allocator`).
    var ctx_a = [_]json.Member{.{ .k = "a", .v = .{ .str = "http://schema.org/a" } }};
    var ctx_b = [_]json.Member{.{ .k = "b", .v = .{ .str = "http://schema.org/b" } }};
    try loader.preloadContext("https://example.org/a.jsonld", try cloneValue(allocator, .{ .obj = &ctx_a }));
    try loader.preloadContext("https://example.org/b.jsonld", try cloneValue(allocator, .{ .obj = &ctx_b }));
    try std.testing.expectEqual(@as(usize, 2), loader.getCacheStats().size);

    // A fresh load (miss) triggers the eviction branch. Before the fix this
    // hashed/compared the just-freed key pointer -> UAF; after the fix it
    // fetchRemoves while the key is still live.
    const loaded = loader.loadContext("https://example.org/c.jsonld");
    try std.testing.expect(loaded != null);

    // Cache stayed at capacity (one evicted, one inserted).
    try std.testing.expectEqual(@as(usize, 2), loader.getCacheStats().size);
}

// =============================================================================
// JSON-LD Edge Case Tests
// =============================================================================

test "getIriType edge cases" {
    // Empty string
    try std.testing.expectEqual(IriType.relative, getIriType(""));

    // Single colon - treated as relative (empty prefix)
    try std.testing.expectEqual(IriType.relative, getIriType(":"));

    // Blank node
    try std.testing.expectEqual(IriType.blank, getIriType("_:b0"));
    try std.testing.expectEqual(IriType.blank, getIriType("_:"));

    // HTTP vs HTTPS
    try std.testing.expectEqual(IriType.absolute, getIriType("http://example.org"));
    try std.testing.expectEqual(IriType.absolute, getIriType("https://example.org"));

    // URN - treated as compact IRI (urn is the prefix)
    try std.testing.expectEqual(IriType.compact, getIriType("urn:isbn:123"));

    // Compact IRI
    try std.testing.expectEqual(IriType.compact, getIriType("schema:name"));
    try std.testing.expectEqual(IriType.compact, getIriType("foaf:Person"));
}

test "Keywords.isKeyword edge cases" {
    // All standard keywords
    try std.testing.expect(Keywords.isKeyword("@context"));
    try std.testing.expect(Keywords.isKeyword("@id"));
    try std.testing.expect(Keywords.isKeyword("@type"));
    try std.testing.expect(Keywords.isKeyword("@value"));
    try std.testing.expect(Keywords.isKeyword("@graph"));
    try std.testing.expect(Keywords.isKeyword("@list"));
    try std.testing.expect(Keywords.isKeyword("@set"));
    try std.testing.expect(Keywords.isKeyword("@language"));

    // isKeyword returns true for anything starting with @
    try std.testing.expect(Keywords.isKeyword("@custom"));
    try std.testing.expect(!Keywords.isKeyword("context")); // No @
    try std.testing.expect(!Keywords.isKeyword("")); // Empty
    try std.testing.expect(Keywords.isKeyword("@")); // Just @ is still a keyword pattern
}

test "Context term lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = Context.init(allocator);

    // Add a term
    const def = TermDefinition{
        .iri = try allocator.dupe(u8, "http://schema.org/name"),
        .prefix = false,
        .type_mapping = null,
        .language = null,
        .direction = null,
        .container = .none,
        .nest = null,
        .index = null,
        .local_context = null,
        .protected = false,
        .reverse = false,
    };
    try ctx.terms.put(try allocator.dupe(u8, "name"), def);

    // Lookup existing term
    const found = ctx.terms.get("name");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("http://schema.org/name", found.?.iri.?);

    // Lookup non-existent term
    const not_found = ctx.terms.get("unknown");
    try std.testing.expect(not_found == null);
}

test "Processor expand empty object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var processor = Processor.init(allocator, .{});
    var empty_members = [_]json.Member{};
    const result = try processor.expand(.{ .obj = &empty_members });

    try std.testing.expect(result == .obj);
    try std.testing.expectEqual(@as(usize, 0), result.obj.len);
}

test "Processor expand array of values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var processor = Processor.init(allocator, .{});
    var values = [_]json.Value{ .null, .{ .bool = true }, .{ .bool = false } };
    const result = try processor.expand(.{ .arr = &values });

    try std.testing.expect(result == .arr);
}

// =============================================================================
// DoS / correctness regression tests (ASR-009, ASR-023, GAP-009, GAP-010)
// =============================================================================

/// Build a `depth`-deep nested single-element array tree: [[[...value...]]].
/// Allocated from `allocator` (use an arena in tests for easy cleanup).
fn buildDeepArray(allocator: std.mem.Allocator, depth: usize, leaf: json.Value) !json.Value {
    var current = leaf;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const arr = try allocator.alloc(json.Value, 1);
        arr[0] = current;
        current = .{ .arr = arr };
    }
    return current;
}

test "ASR-009: deeply nested array expand returns MaxDepthExceeded (no crash)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Tree far deeper than the default max_depth (256).
    const deep = try buildDeepArray(allocator, 5000, .{ .str = "leaf" });

    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    try std.testing.expectError(Error.MaxDepthExceeded, processor.expand(deep));
}

test "ASR-009: max_depth is configurable and bounds expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 20-deep tree. With a generous cap it expands; with a tiny cap it fails.
    const deep = try buildDeepArray(allocator, 20, .{ .str = "leaf" });

    {
        var processor = Processor.init(allocator, .{ .max_depth = 1000 });
        defer processor.deinit();
        const ok = try processor.expand(deep);
        try std.testing.expect(ok == .arr);
    }
    {
        var processor = Processor.init(allocator, .{ .max_depth = 4 });
        defer processor.deinit();
        try std.testing.expectError(Error.MaxDepthExceeded, processor.expand(deep));
    }
}

test "ASR-009: deeply nested frame input returns MaxDepthExceeded (no crash)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const deep = try buildDeepArray(allocator, 5000, .{ .str = "leaf" });

    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    // Frame expands the document first, so the depth guard trips during expand.
    var frame_members = [_]json.Member{};
    try std.testing.expectError(
        Error.MaxDepthExceeded,
        processor.frame(deep, .{ .obj = &frame_members }),
    );
}

// Test document loader that always returns the SAME url it was asked for as a
// string context, producing a self-referential context resolution cycle.
fn selfReferentialLoader(url: []const u8) ?json.Value {
    return .{ .str = url };
}

test "ASR-009: self-referential @context returns RecursiveContext (no infinite loop)" {
    // Use the leak-detecting testing allocator (no arena): this also verifies
    // the cycle-guard cleanup path (resolving_contexts key dup/remove) and the
    // error unwind leak nothing.
    const allocator = std.testing.allocator;

    var processor = Processor.init(allocator, .{
        .document_loader = selfReferentialLoader,
    });
    defer processor.deinit();

    // Document whose @context is a URL the loader resolves back to itself.
    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .str = "https://example.org/ctx.jsonld" } },
        .{ .k = "name", .v = .{ .str = "Alice" } },
    };

    try std.testing.expectError(
        Error.RecursiveContext,
        processor.expand(.{ .obj = &doc_members }),
    );
}

test "GAP-010: URL @context with no document loader returns ContextNotLoaded" {
    // Leak-detecting allocator: error path must free everything it allocated.
    const allocator = std.testing.allocator;

    // No document_loader configured.
    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .str = "https://example.org/ctx.jsonld" } },
        .{ .k = "name", .v = .{ .str = "Alice" } },
    };

    try std.testing.expectError(
        Error.ContextNotLoaded,
        processor.expand(.{ .obj = &doc_members }),
    );
}

// Loader that returns a real object context for a known import URL.
// Backed by static storage so it owns no heap memory (matches how the real
// `document_loader` contract works: the loader owns the returned value).
var import_ctx_members = [_]json.Member{
    .{ .k = "name", .v = .{ .str = "http://schema.org/name" } },
};
fn importLoader(url: []const u8) ?json.Value {
    if (std.mem.eql(u8, url, "https://example.org/base.jsonld")) {
        return .{ .obj = &import_ctx_members };
    }
    return null;
}

test "GAP-009: @import is resolved and merged (not silently dropped)" {
    // Use the leak-detecting testing allocator (no arena): the previous arena
    // masked any per-allocation leak in the @import context merge/move path
    // (createTermDefinition, processContext merge). Running raw guards those
    // move/merge semantics -- every duped key/value must be owned and freed.
    const allocator = std.testing.allocator;

    var processor = Processor.init(allocator, .{
        .document_loader = importLoader,
    });
    defer processor.deinit();

    // @context that imports another context and adds nothing else.
    var ctx_members = [_]json.Member{
        .{ .k = "@import", .v = .{ .str = "https://example.org/base.jsonld" } },
    };
    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .obj = &ctx_members } },
        .{ .k = "name", .v = .{ .str = "Alice" } },
    };

    const result = try processor.expand(.{ .obj = &doc_members });
    defer freeValue(allocator, result);

    // The imported context defines `name` -> http://schema.org/name, so the
    // expanded object must contain that IRI as a key (proving @import merged).
    try std.testing.expect(result == .obj);
    var found = false;
    for (result.obj) |m| {
        if (std.mem.eql(u8, m.k, "http://schema.org/name")) found = true;
    }
    try std.testing.expect(found);
}

test "GAP-009: @import with no loader returns ContextImportFailed (not dropped)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // No loader configured: @import cannot be resolved and must error rather
    // than be silently skipped.
    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    var ctx_members = [_]json.Member{
        .{ .k = "@import", .v = .{ .str = "https://example.org/base.jsonld" } },
    };
    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .obj = &ctx_members } },
        .{ .k = "name", .v = .{ .str = "Alice" } },
    };

    try std.testing.expectError(
        Error.ContextImportFailed,
        processor.expand(.{ .obj = &doc_members }),
    );
}

test "NEW-004: array @context expansion does not leak a Context per call" {
    // Leak-detecting allocator (NOT an arena): before the fix the `.arr` branch
    // of processContext orphaned its seed clone every call (the `if (i > 0)`
    // guard skipped freeing iteration 0's seed), leaking one Context. This must
    // be clean now.
    const allocator = std.testing.allocator;

    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    // Array @context with two object entries -> two loop iterations, each
    // superseding the prior live context. All seeds must be freed exactly once.
    var ctx0 = [_]json.Member{.{ .k = "name", .v = .{ .str = "http://schema.org/name" } }};
    var ctx1 = [_]json.Member{.{ .k = "age", .v = .{ .str = "http://schema.org/age" } }};
    var ctx_arr = [_]json.Value{ .{ .obj = &ctx0 }, .{ .obj = &ctx1 } };
    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .arr = &ctx_arr } },
        .{ .k = "name", .v = .{ .str = "x" } },
    };

    const result = try processor.expand(.{ .obj = &doc_members });
    defer freeValue(allocator, result);

    // The array context defines `name` -> http://schema.org/name, so expansion
    // must rename the `name` key to that IRI (proves the array was applied).
    try std.testing.expect(result == .obj);
    var found = false;
    for (result.obj) |m| {
        if (std.mem.eql(u8, m.k, "http://schema.org/name")) found = true;
    }
    try std.testing.expect(found);
}

test "NEW-004: single-object @context control is leak-free" {
    // Control: a single-object @context never hit the `.arr` seed-orphan bug;
    // this guards against a regression in the shared clone/free ownership.
    const allocator = std.testing.allocator;

    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    var ctx_members = [_]json.Member{.{ .k = "name", .v = .{ .str = "http://schema.org/name" } }};
    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .obj = &ctx_members } },
        .{ .k = "name", .v = .{ .str = "x" } },
    };

    const result = try processor.expand(.{ .obj = &doc_members });
    defer freeValue(allocator, result);
    try std.testing.expect(result == .obj);
}

test "NEW-004: string/URL @context expansion does not leak the seed clone" {
    // Leak-detecting allocator: the `.str` branch returned the recursive call's
    // result while orphaning its seed clone `result`. With a loader configured,
    // a URL-valued @context must expand cleanly with no leak.
    const allocator = std.testing.allocator;

    // `importLoader` resolves https://example.org/base.jsonld -> object context
    // {name -> http://schema.org/name} (defined above for the GAP-009 tests).
    var processor = Processor.init(allocator, .{
        .document_loader = importLoader,
    });
    defer processor.deinit();

    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .str = "https://example.org/base.jsonld" } },
        .{ .k = "name", .v = .{ .str = "x" } },
    };

    const result = try processor.expand(.{ .obj = &doc_members });
    defer freeValue(allocator, result);

    try std.testing.expect(result == .obj);
    var found = false;
    for (result.obj) |m| {
        if (std.mem.eql(u8, m.k, "http://schema.org/name")) found = true;
    }
    try std.testing.expect(found);
}

test "NEW-004: array @context error path frees live context without double-free" {
    // A two-element array @context where the SECOND entry is an unresolvable
    // URL-valued context (no loader) forces an error AFTER the first iteration
    // already freed the seed in-loop. The function-level errdefer must free only
    // the still-live context (the one produced by iteration 0), not the freed
    // seed -- proving no double-free and no leak on the error unwind.
    const allocator = std.testing.allocator;

    var processor = Processor.init(allocator, .{}); // no document_loader
    defer processor.deinit();

    var ctx0 = [_]json.Member{.{ .k = "name", .v = .{ .str = "http://schema.org/name" } }};
    var ctx_arr = [_]json.Value{
        .{ .obj = &ctx0 },
        .{ .str = "https://example.org/missing.jsonld" }, // unresolvable -> error
    };
    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .arr = &ctx_arr } },
        .{ .k = "name", .v = .{ .str = "x" } },
    };

    try std.testing.expectError(
        Error.ContextNotLoaded,
        processor.expand(.{ .obj = &doc_members }),
    );
}

test "ASR-023: blank node ids are per-instance and deterministic across runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Two independent processor instances must produce identical blank-node
    // numbering, i.e. both start their counter at 0 (no shared global state /
    // no continuously-incrementing module-global counter).
    var p1 = Processor.init(allocator, .{});
    defer p1.deinit();
    const id1a = try p1.generateBlankNodeId();
    const id1b = try p1.generateBlankNodeId();

    var p2 = Processor.init(allocator, .{});
    defer p2.deinit();
    const id2a = try p2.generateBlankNodeId();
    const id2b = try p2.generateBlankNodeId();

    // Each fresh instance restarts numbering deterministically.
    try std.testing.expectEqualStrings("_:b0", id1a);
    try std.testing.expectEqualStrings("_:b1", id1b);
    try std.testing.expectEqualStrings("_:b0", id2a);
    try std.testing.expectEqualStrings("_:b1", id2b);
}

// =============================================================================
// NASR-002: depth-limit error path must not leak partial work
//
// These build a deeply nested caller-owned `Value` tree with the leak-detecting
// testing allocator (and free it themselves), then feed it to a Processor that
// ALSO uses the testing allocator. The depth guard trips mid-build, so the
// processor's recursive builders accumulate a partial prefix of duped keys and
// expanded child subtrees before unwinding. The testing allocator fails the
// test if that partial work is not freed on the error path.
// =============================================================================

/// Build a `depth`-deep nested single-member object tree, all strings duped
/// from `allocator` so each level owns real heap key/value allocations:
///   {"k": {"k": {"k": ... {"leaf": "v"} ... }}}
/// Free with `freeValue(allocator, ...)`.
fn buildDeepObject(allocator: std.mem.Allocator, depth: usize) !json.Value {
    var current: json.Value = .{ .str = try allocator.dupe(u8, "leaf-value") };
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const members = try allocator.alloc(json.Member, 1);
        members[0] = .{
            .k = try allocator.dupe(u8, "nestedKey"),
            .v = current,
        };
        current = .{ .obj = members };
    }
    return current;
}

test "NASR-002: deep object expand error path frees partial work (no leak)" {
    // No arena: testing.allocator detects any leak in the processor's internal
    // partial expansion when MaxDepthExceeded unwinds.
    const allocator = std.testing.allocator;

    const deep = try buildDeepObject(allocator, 600);
    defer freeValue(allocator, deep);

    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    try std.testing.expectError(Error.MaxDepthExceeded, processor.expand(deep));
}

test "NASR-002: deep array expand error path frees partial work (no leak)" {
    const allocator = std.testing.allocator;

    // Each array level wraps an object so expandInternal's .arr branch
    // accumulates already-expanded object subtrees before tripping the guard.
    const inner = try buildDeepObject(allocator, 1);
    const deep = try buildDeepArray(allocator, 600, inner);
    defer freeValue(allocator, deep);

    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    try std.testing.expectError(Error.MaxDepthExceeded, processor.expand(deep));
}

test "NASR-002: deep object compact error path frees partial work (no leak)" {
    const allocator = std.testing.allocator;

    const deep = try buildDeepObject(allocator, 600);
    defer freeValue(allocator, deep);

    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    // An empty object context: compact must expand first (which trips the guard)
    // OR reach compactInternal; either way no partial work may leak.
    var ctx_members = [_]json.Member{};
    try std.testing.expectError(
        Error.MaxDepthExceeded,
        processor.compact(deep, .{ .obj = &ctx_members }),
    );
}

test "NASR-002: deep object frame error path frees partial work (no leak)" {
    const allocator = std.testing.allocator;

    const deep = try buildDeepObject(allocator, 600);
    defer freeValue(allocator, deep);

    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    var frame_members = [_]json.Member{};
    try std.testing.expectError(
        Error.MaxDepthExceeded,
        processor.frame(deep, .{ .obj = &frame_members }),
    );
}

// =============================================================================
// NQUAL-007: a non-string @import must not be silently dropped
// =============================================================================

test "NQUAL-007: non-string @import returns ContextImportFailed (not dropped)" {
    const allocator = std.testing.allocator;

    var processor = Processor.init(allocator, .{});
    defer processor.deinit();

    // @import set to a non-string (here an object) rather than a string IRI.
    // This must error rather than silently `continue` past the import.
    var import_obj = [_]json.Member{};
    var ctx_members = [_]json.Member{
        .{ .k = "@import", .v = .{ .obj = &import_obj } },
    };
    var doc_members = [_]json.Member{
        .{ .k = "@context", .v = .{ .obj = &ctx_members } },
        .{ .k = "name", .v = .{ .str = "Alice" } },
    };

    try std.testing.expectError(
        Error.ContextImportFailed,
        processor.expand(.{ .obj = &doc_members }),
    );
}

// =============================================================================
// NASR/OOM: createTermDefinition partial-build leak guard
//
// `createTermDefinition` dupes @id/@type/@language into a TermDefinition
// incrementally, then dupes a key and inserts into the term map. Before the
// errdefer fix, an allocation failure partway through leaked the already-duped
// fields (and a failed map insert leaked the key). This test sweeps the
// allocation fail index with std.testing.FailingAllocator over the
// leak-detecting testing allocator: at every failure point the partial work
// must be fully freed, so the testing allocator reports no leak.
// =============================================================================

test "NASR/OOM: createTermDefinition frees partial work on allocation failure (no leak)" {
    var saw_oom = false;
    var fail_index: usize = 0;
    // The full-object path dupes @id, @type, @language, then the key, then
    // inserts (the map's first put also allocates its backing store), so a small
    // sweep covers every allocation in the build.
    while (fail_index < 24) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const fa = failing.allocator();

        // Processor/Context init perform no allocation until first map insert,
        // so they are safe to build directly on the failing allocator.
        var processor = Processor.init(fa, .{});
        defer processor.deinit();

        var context = Context.init(fa);
        defer context.deinit();

        // A full @id/@type/@language object definition exercises every
        // incremental dupe in the build path.
        var def_members = [_]json.Member{
            .{ .k = Keywords.id, .v = .{ .str = "http://example.org/term" } },
            .{ .k = Keywords.type_kw, .v = .{ .str = "@id" } },
            .{ .k = Keywords.language, .v = .{ .str = "en" } },
        };

        const res = processor.createTermDefinition(&context, "myTerm", .{ .obj = &def_members });
        if (res) |_| {
            // Build completed before the fail index: term owned by `context`,
            // freed by context.deinit(). Nothing else to do.
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;
            // On the error path the partial fields must already be freed by the
            // errdefer; context holds no term for "myTerm". The testing allocator
            // (backing `failing`) will fail this test at teardown if anything
            // duped before the failure leaked.
        }
    }
    // Prove the sweep actually exercised at least one OOM unwind.
    try std.testing.expect(saw_oom);
}
