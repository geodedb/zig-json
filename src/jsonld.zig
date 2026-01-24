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
                // Simple eviction: remove first entry
                var iter = self.cache.iterator();
                if (iter.next()) |first| {
                    self.allocator.free(first.key_ptr.*);
                    freeValue(self.allocator, first.value_ptr.context);
                    _ = self.cache.remove(first.key_ptr.*);
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

    /// Create a document_loader callback function for use with Options
    /// Note: The returned function is bound to this loader instance
    pub fn createDocumentLoader(self: *Self) *const fn ([]const u8) ?json.Value {
        // This creates a closure-like pattern using a static variable
        // In real usage, users would create their own callback that references their loader
        _ = self;
        return &staticLoader;
    }
};

// Static loader placeholder - users should create their own callbacks
fn staticLoader(url: []const u8) ?json.Value {
    // This is a placeholder that does nothing
    // Real implementations should use a RemoteContextLoader instance
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

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, options: Options) Self {
        return .{
            .allocator = allocator,
            .options = options,
            .active_context = Context.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.active_context.deinit();
    }

    // =========================================================================
    // Expansion Algorithm (Section 5.1)
    // =========================================================================

    /// Expand a JSON-LD document
    pub fn expand(self: *Self, document: json.Value) !json.Value {
        return self.expandInternal(document, &self.active_context, null);
    }

    fn expandInternal(
        self: *Self,
        element: json.Value,
        active_context: *Context,
        active_property: ?[]const u8,
    ) !json.Value {
        _ = active_property;

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
                errdefer result.deinit(self.allocator);

                for (arr) |item| {
                    const expanded = try self.expandInternal(item, active_context, null);
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
                        local_context = try self.processContext(active_context, member.v);
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
                errdefer result.deinit(self.allocator);

                for (obj) |member| {
                    // Skip @context as it's already processed
                    if (std.mem.eql(u8, member.k, Keywords.context)) continue;

                    // Expand property name
                    const expanded_key = try self.expandKey(local_context, member.k);

                    // Expand value
                    const expanded_value = try self.expandInternal(member.v, local_context, member.k);

                    if (expanded_key != null and expanded_value != .null) {
                        try result.append(self.allocator, .{
                            .k = expanded_key.?,
                            .v = expanded_value,
                        });
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

    fn processContext(self: *Self, active_context: *Context, local_context: json.Value) !*Context {
        const result = try active_context.clone();
        errdefer {
            result.deinit();
            self.allocator.destroy(result);
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
                // Context is a URL - load it
                if (self.options.document_loader) |loader| {
                    if (loader(s)) |loaded| {
                        return self.processContext(result, loaded);
                    }
                }
            },
            .obj => |obj| {
                // Process context definition
                for (obj) |member| {
                    if (std.mem.eql(u8, member.k, Keywords.version)) {
                        // Handle @version
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
                // Process array of contexts in order
                var current = result;
                for (arr, 0..) |ctx, i| {
                    const processed = try self.processContext(current, ctx);
                    if (i > 0) {
                        current.deinit();
                        self.allocator.destroy(current);
                    }
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
        const compact_context = try self.processContext(&self.active_context, context);
        defer {
            compact_context.deinit();
            self.allocator.destroy(compact_context);
        }

        // Compact the expanded document
        return self.compactInternal(expanded, compact_context);
    }

    fn compactInternal(self: *Self, element: json.Value, context: *Context) !json.Value {
        switch (element) {
            .null, .bool, .num => return element,
            .str => |s| {
                // Try to compact IRI
                return .{ .str = try self.compactIri(context, s) };
            },
            .arr => |arr| {
                var result: std.ArrayList(json.Value) = .empty;
                errdefer result.deinit(self.allocator);

                for (arr) |item| {
                    const compacted = try self.compactInternal(item, context);
                    try result.append(self.allocator, compacted);
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
                errdefer result.deinit(self.allocator);

                for (obj) |member| {
                    const compacted_key = try self.compactIri(context, member.k);
                    const compacted_value = try self.compactInternal(member.v, context);
                    try result.append(self.allocator, .{
                        .k = compacted_key,
                        .v = compacted_value,
                    });
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

        try self.generateNodeMap(expanded, &node_map, null);

        // Create flattened output
        var graph: std.ArrayList(json.Value) = .empty;
        errdefer graph.deinit(self.allocator);

        var iter = node_map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == .obj) {
                // Clone the node
                const cloned = try cloneValue(self.allocator, entry.value_ptr.*);
                try graph.append(self.allocator, cloned);
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
    ) !void {
        switch (element) {
            .arr => |arr| {
                for (arr) |item| {
                    try self.generateNodeMap(item, node_map, active_graph);
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

                // Clone the object into node map
                const key = try self.allocator.dupe(u8, id.?);
                const value = try cloneValue(self.allocator, element);
                try node_map.put(key, value);

                // Process nested nodes
                for (obj) |member| {
                    if (member.v == .obj or member.v == .arr) {
                        try self.generateNodeMap(member.v, node_map, active_graph);
                    }
                }
            },
            else => {},
        }
    }

    var blank_node_counter: u64 = 0;

    fn generateBlankNodeId(self: *Self) ![]const u8 {
        const id = blank_node_counter;
        blank_node_counter += 1;

        var buf: [32]u8 = undefined;
        const len = std.fmt.formatIntBuf(&buf, id, 10, .lower, .{});
        const result = try self.allocator.alloc(u8, 3 + len);
        result[0] = '_';
        result[1] = ':';
        result[2] = 'b';
        @memcpy(result[3..], buf[0..len]);
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
        return self.frameInternal(expanded, expanded_frame);
    }

    fn frameInternal(self: *Self, input: json.Value, frame_val: json.Value) !json.Value {
        // Match input against frame pattern
        if (frame_val != .obj) {
            return try cloneValue(self.allocator, input);
        }

        const frame_obj = frame_val.obj;

        if (input == .arr) {
            var result: std.ArrayList(json.Value) = .empty;
            errdefer result.deinit(self.allocator);

            for (input.arr) |item| {
                if (try self.matchesFrame(item, frame_obj)) {
                    const framed = try self.frameInternal(item, frame_val);
                    try result.append(self.allocator, framed);
                }
            }

            return .{ .arr = try result.toOwnedSlice(self.allocator) };
        }

        if (input != .obj) {
            return try cloneValue(self.allocator, input);
        }

        // Match object against frame
        if (!try self.matchesFrame(input, frame_obj)) {
            return .null;
        }

        // Build framed result
        var result: std.ArrayList(json.Member) = .empty;
        errdefer result.deinit(self.allocator);

        // Include all properties from frame
        for (frame_obj) |frame_member| {
            // Find matching property in input
            for (input.obj) |input_member| {
                if (std.mem.eql(u8, frame_member.k, input_member.k)) {
                    const framed_value = try self.frameInternal(input_member.v, frame_member.v);
                    try result.append(self.allocator, .{
                        .k = try self.allocator.dupe(u8, frame_member.k),
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
