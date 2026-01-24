// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! JSON Schema Draft 2020-12 Validator
//!
//! Implements JSON Schema compilation and validation with support for:
//! - All Core vocabulary keywords ($id, $ref, $anchor, $dynamicRef, $defs)
//! - All Applicator vocabulary keywords (allOf, anyOf, oneOf, not, if/then/else)
//! - All Validation vocabulary keywords (type, const, enum, numeric, string, array, object)
//! - Unevaluated vocabulary keywords (unevaluatedItems, unevaluatedProperties)

const std = @import("std");
const json = @import("json.zig");
const pointer = @import("pointer.zig");
const regex_mod = @import("regex_ecma262.zig");
const number_mod = @import("number.zig");
const uri_mod = @import("uri");

const Value = json.Value;
const Number = json.Number;
const Member = json.Member;
const Document = json.Document;
const ErrorCode = json.ErrorCode;
const ParseError = json.ParseError;
const SchemaOptions = json.SchemaOptions;
const Resolver = json.Resolver;
const CompiledSchema = json.CompiledSchema;
const ValidationError = json.ValidationError;
const ValidationReport = json.ValidationReport;

pub const SchemaNode = struct {
    location: []const u8,
    /// The resolved base URI for this schema (from nearest $id ancestor)
    base_uri: []const u8 = "",
    id: ?[]const u8 = null,
    anchor: ?[]const u8 = null,
    dynamic_anchor: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    dynamic_ref: ?[]const u8 = null,

    schema_type: ?[]const []const u8 = null,
    const_val: ?Value = null,
    enum_vals: ?[]Value = null,

    minimum: ?Number = null,
    maximum: ?Number = null,
    exclusive_minimum: ?Number = null,
    exclusive_maximum: ?Number = null,
    multiple_of: ?Number = null,

    min_length: ?u64 = null,
    max_length: ?u64 = null,
    pattern: ?*regex_mod.Regex = null,
    format: ?[]const u8 = null,

    min_items: ?u64 = null,
    max_items: ?u64 = null,
    unique_items: bool = false,
    items: ?*SchemaNode = null,
    prefix_items: ?[]*SchemaNode = null,
    contains: ?*SchemaNode = null,
    min_contains: ?u64 = null,
    max_contains: ?u64 = null,

    min_properties: ?u64 = null,
    max_properties: ?u64 = null,
    required: ?[]const []const u8 = null,
    properties: ?std.StringHashMap(*SchemaNode) = null,
    pattern_properties: ?[]PatternProperty = null,
    additional_properties: ?*SchemaNode = null,
    property_names: ?*SchemaNode = null,
    dependent_required: ?std.StringHashMap([]const []const u8) = null,
    dependent_schemas: ?std.StringHashMap(*SchemaNode) = null,

    all_of: ?[]*SchemaNode = null,
    any_of: ?[]*SchemaNode = null,
    one_of: ?[]*SchemaNode = null,
    not: ?*SchemaNode = null,
    if_schema: ?*SchemaNode = null,
    then_schema: ?*SchemaNode = null,
    else_schema: ?*SchemaNode = null,

    unevaluated_items: ?*SchemaNode = null,
    unevaluated_properties: ?*SchemaNode = null,

    defs: ?std.StringHashMap(*SchemaNode) = null,

    is_bool_schema: bool = false,
    bool_value: bool = true,
};

const PatternProperty = struct {
    pattern: *regex_mod.Regex,
    schema: *SchemaNode,
};

pub fn compile(a: std.mem.Allocator, doc: *const Document, opts: SchemaOptions, resolver: ?Resolver, err: *ParseError) !CompiledSchema {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const root = try compileNode(alloc, doc.root, "", opts, err);

    var anchors = std.StringHashMap(*SchemaNode).init(alloc);
    var dynamic_anchors = std.StringHashMap(*SchemaNode).init(alloc);
    var id_registry = std.StringHashMap(*SchemaNode).init(alloc);

    // Collect anchors and $id values with base URI context
    try collectIdentifiers(alloc, root, "", &anchors, &dynamic_anchors, &id_registry);

    // Resolve external refs if resolver is provided
    if (resolver) |r| {
        var fetched = std.StringHashMap(void).init(alloc);
        try resolveExternalRefs(alloc, root, r, opts, err, &anchors, &dynamic_anchors, &id_registry, &fetched);
    }

    return .{
        .arena = arena,
        .root = root,
        .base_uri = "",
        .anchors = anchors,
        .dynamic_anchors = dynamic_anchors,
        .id_registry = id_registry,
        .resolver = resolver,
        .opts = opts,
    };
}

/// Resolve a single external ref
fn resolveExternalRef(
    alloc: std.mem.Allocator,
    ref: []const u8,
    base_uri: []const u8,
    resolver: Resolver,
    opts: SchemaOptions,
    err: *ParseError,
    anchors: *std.StringHashMap(*SchemaNode),
    dynamic_anchors: *std.StringHashMap(*SchemaNode),
    id_registry: *std.StringHashMap(*SchemaNode),
    fetched: *std.StringHashMap(void),
) std.mem.Allocator.Error!void {
    // Resolve relative ref against base URI if needed
    var resolved_ref: []const u8 = ref;
    var allocated = false;

    if (std.mem.indexOf(u8, ref, ":") == null and base_uri.len > 0) {
        // Relative ref - resolve against base URI
        const parsed_ref = uri_mod.parse(ref) catch return;
        const parsed_base = uri_mod.parse(base_uri) catch return;
        var resolved = uri_mod.resolve(alloc, parsed_base, parsed_ref) catch return;
        defer alloc.free(resolved.path);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        resolved.format(buf.writer(alloc)) catch return;
        resolved_ref = buf.toOwnedSlice(alloc) catch return;
        allocated = true;
    }
    defer if (allocated) alloc.free(resolved_ref);

    // Extract base URI (without fragment)
    const uri_base = if (std.mem.indexOf(u8, resolved_ref, "#")) |pos| resolved_ref[0..pos] else resolved_ref;

    // Skip if already fetched or registered
    if (uri_base.len == 0 or fetched.contains(uri_base) or id_registry.contains(uri_base)) {
        return;
    }

    // Mark as fetched to prevent infinite loops
    try fetched.put(try alloc.dupe(u8, uri_base), {});

    // Try to resolve using the resolver
    const schema_json = resolver.resolve(resolver.ctx, uri_base, alloc) catch return;

    // Parse the fetched JSON
    var parse_err = json.ParseError.init();
    const ext_doc = json.parse(alloc, schema_json, .{}, &parse_err) catch return;

    // Compile the external schema
    const ext_root = compileNode(alloc, ext_doc.root, "", opts, err) catch return;

    // Collect identifiers from the external schema
    try collectIdentifiers(alloc, ext_root, uri_base, anchors, dynamic_anchors, id_registry);

    // Recursively resolve external refs in the fetched schema
    try resolveExternalRefs(alloc, ext_root, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
}

/// Resolve external $refs by fetching and compiling external schemas
fn resolveExternalRefs(
    alloc: std.mem.Allocator,
    node: *SchemaNode,
    resolver: Resolver,
    opts: SchemaOptions,
    err: *ParseError,
    anchors: *std.StringHashMap(*SchemaNode),
    dynamic_anchors: *std.StringHashMap(*SchemaNode),
    id_registry: *std.StringHashMap(*SchemaNode),
    fetched: *std.StringHashMap(void),
) std.mem.Allocator.Error!void {
    // Check if this node has an external $ref
    if (node.ref) |ref| {
        // Skip fragment-only refs
        if (ref.len > 0 and ref[0] != '#') {
            try resolveExternalRef(alloc, ref, node.base_uri, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
        }
    }

    // Recurse into child schemas
    if (node.defs) |defs| {
        var it = defs.iterator();
        while (it.next()) |entry| {
            try resolveExternalRefs(alloc, entry.value_ptr.*, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
        }
    }
    if (node.properties) |props| {
        var it = props.iterator();
        while (it.next()) |entry| {
            try resolveExternalRefs(alloc, entry.value_ptr.*, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
        }
    }
    if (node.items) |items| try resolveExternalRefs(alloc, items, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.prefix_items) |items| for (items) |item| try resolveExternalRefs(alloc, item, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.additional_properties) |ap| try resolveExternalRefs(alloc, ap, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.contains) |c| try resolveExternalRefs(alloc, c, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.all_of) |arr| for (arr) |s| try resolveExternalRefs(alloc, s, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.any_of) |arr| for (arr) |s| try resolveExternalRefs(alloc, s, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.one_of) |arr| for (arr) |s| try resolveExternalRefs(alloc, s, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.not) |n| try resolveExternalRefs(alloc, n, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.if_schema) |i| try resolveExternalRefs(alloc, i, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.then_schema) |t| try resolveExternalRefs(alloc, t, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.else_schema) |e| try resolveExternalRefs(alloc, e, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.property_names) |pn| try resolveExternalRefs(alloc, pn, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.dependent_schemas) |ds| {
        var it = ds.iterator();
        while (it.next()) |entry| {
            try resolveExternalRefs(alloc, entry.value_ptr.*, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
        }
    }
    if (node.unevaluated_items) |ui| try resolveExternalRefs(alloc, ui, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
    if (node.unevaluated_properties) |up| try resolveExternalRefs(alloc, up, resolver, opts, err, anchors, dynamic_anchors, id_registry, fetched);
}

/// Collect $id, $anchor, and $dynamicAnchor values with proper base URI resolution
fn collectIdentifiers(
    alloc: std.mem.Allocator,
    node: *SchemaNode,
    base_uri: []const u8,
    anchors: *std.StringHashMap(*SchemaNode),
    dynamic_anchors: *std.StringHashMap(*SchemaNode),
    id_registry: *std.StringHashMap(*SchemaNode),
) !void {
    // Determine the new base URI for this node
    var current_base = base_uri;
    if (node.id) |id| {
        // Resolve $id against current base URI
        const resolved_id = try resolveIdUri(alloc, base_uri, id);
        current_base = resolved_id;
        try id_registry.put(resolved_id, node);
    }

    // Store the base URI in the node for $ref resolution
    node.base_uri = current_base;

    // Register anchors with their full URI (base + #anchor)
    if (node.anchor) |anch| {
        // Store both plain anchor and full URI form
        try anchors.put(anch, node);
        if (current_base.len > 0) {
            const full_anchor = try std.fmt.allocPrint(alloc, "{s}#{s}", .{ current_base, anch });
            try anchors.put(full_anchor, node);
        }
    }
    if (node.dynamic_anchor) |danch| {
        // Only register plain anchor if not already registered (outermost wins per $dynamicRef spec)
        if (!dynamic_anchors.contains(danch)) {
            try dynamic_anchors.put(danch, node);
        }
        // Always register with full URI (uniquely identifies this specific anchor)
        if (current_base.len > 0) {
            const full_anchor = try std.fmt.allocPrint(alloc, "{s}#{s}", .{ current_base, danch });
            try dynamic_anchors.put(full_anchor, node);
        }
    }

    // Recurse into child schemas with updated base URI
    if (node.defs) |defs| {
        var it = defs.iterator();
        while (it.next()) |entry| {
            try collectIdentifiers(alloc, entry.value_ptr.*, current_base, anchors, dynamic_anchors, id_registry);
        }
    }
    if (node.properties) |props| {
        var it = props.iterator();
        while (it.next()) |entry| {
            try collectIdentifiers(alloc, entry.value_ptr.*, current_base, anchors, dynamic_anchors, id_registry);
        }
    }
    if (node.items) |items| try collectIdentifiers(alloc, items, current_base, anchors, dynamic_anchors, id_registry);
    if (node.prefix_items) |items| for (items) |item| try collectIdentifiers(alloc, item, current_base, anchors, dynamic_anchors, id_registry);
    if (node.additional_properties) |ap| try collectIdentifiers(alloc, ap, current_base, anchors, dynamic_anchors, id_registry);
    if (node.contains) |c| try collectIdentifiers(alloc, c, current_base, anchors, dynamic_anchors, id_registry);
    if (node.all_of) |arr| for (arr) |s| try collectIdentifiers(alloc, s, current_base, anchors, dynamic_anchors, id_registry);
    if (node.any_of) |arr| for (arr) |s| try collectIdentifiers(alloc, s, current_base, anchors, dynamic_anchors, id_registry);
    if (node.one_of) |arr| for (arr) |s| try collectIdentifiers(alloc, s, current_base, anchors, dynamic_anchors, id_registry);
    if (node.not) |n| try collectIdentifiers(alloc, n, current_base, anchors, dynamic_anchors, id_registry);
    if (node.if_schema) |i| try collectIdentifiers(alloc, i, current_base, anchors, dynamic_anchors, id_registry);
    if (node.then_schema) |t| try collectIdentifiers(alloc, t, current_base, anchors, dynamic_anchors, id_registry);
    if (node.else_schema) |e| try collectIdentifiers(alloc, e, current_base, anchors, dynamic_anchors, id_registry);
    if (node.property_names) |pn| try collectIdentifiers(alloc, pn, current_base, anchors, dynamic_anchors, id_registry);
    if (node.dependent_schemas) |ds| {
        var it = ds.iterator();
        while (it.next()) |entry| {
            try collectIdentifiers(alloc, entry.value_ptr.*, current_base, anchors, dynamic_anchors, id_registry);
        }
    }
    if (node.unevaluated_items) |ui| try collectIdentifiers(alloc, ui, current_base, anchors, dynamic_anchors, id_registry);
    if (node.unevaluated_properties) |up| try collectIdentifiers(alloc, up, current_base, anchors, dynamic_anchors, id_registry);
}

/// Resolve a $id URI against a base URI
fn resolveIdUri(alloc: std.mem.Allocator, base: []const u8, id: []const u8) ![]const u8 {
    // If id is absolute (has scheme), use it as-is
    const parsed_id = uri_mod.parse(id) catch return try alloc.dupe(u8, id);
    if (parsed_id.scheme != null) {
        return try alloc.dupe(u8, id);
    }

    // If no base, use id as-is
    if (base.len == 0) {
        return try alloc.dupe(u8, id);
    }

    // Resolve relative id against base
    const parsed_base = uri_mod.parse(base) catch return try alloc.dupe(u8, id);
    var resolved = uri_mod.resolve(alloc, parsed_base, parsed_id) catch return try alloc.dupe(u8, id);
    defer alloc.free(resolved.path); // Free the allocated path

    // Format resolved URI back to string
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    resolved.format(buf.writer(alloc)) catch return try alloc.dupe(u8, id);
    return buf.toOwnedSlice(alloc);
}

fn compileNode(a: std.mem.Allocator, v: Value, location: []const u8, opts: SchemaOptions, err: *ParseError) !*SchemaNode {
    const node = try a.create(SchemaNode);
    node.* = .{ .location = try a.dupe(u8, location) };

    switch (v) {
        .bool => |b| {
            node.is_bool_schema = true;
            node.bool_value = b;
            return node;
        },
        .obj => |obj| {
            for (obj) |m| {
                if (std.mem.eql(u8, m.k, "$id")) {
                    if (m.v == .str) node.id = try a.dupe(u8, m.v.str);
                } else if (std.mem.eql(u8, m.k, "$anchor")) {
                    if (m.v == .str) node.anchor = try a.dupe(u8, m.v.str);
                } else if (std.mem.eql(u8, m.k, "$dynamicAnchor")) {
                    if (m.v == .str) node.dynamic_anchor = try a.dupe(u8, m.v.str);
                } else if (std.mem.eql(u8, m.k, "$ref")) {
                    if (m.v == .str) node.ref = try a.dupe(u8, m.v.str);
                } else if (std.mem.eql(u8, m.k, "$dynamicRef")) {
                    if (m.v == .str) node.dynamic_ref = try a.dupe(u8, m.v.str);
                } else if (std.mem.eql(u8, m.k, "type")) {
                    node.schema_type = try parseTypeKeyword(a, m.v);
                } else if (std.mem.eql(u8, m.k, "const")) {
                    node.const_val = m.v;
                } else if (std.mem.eql(u8, m.k, "enum")) {
                    if (m.v == .arr) node.enum_vals = m.v.arr;
                } else if (std.mem.eql(u8, m.k, "minimum")) {
                    if (m.v == .num) node.minimum = m.v.num;
                } else if (std.mem.eql(u8, m.k, "maximum")) {
                    if (m.v == .num) node.maximum = m.v.num;
                } else if (std.mem.eql(u8, m.k, "exclusiveMinimum")) {
                    if (m.v == .num) node.exclusive_minimum = m.v.num;
                } else if (std.mem.eql(u8, m.k, "exclusiveMaximum")) {
                    if (m.v == .num) node.exclusive_maximum = m.v.num;
                } else if (std.mem.eql(u8, m.k, "multipleOf")) {
                    if (m.v == .num) node.multiple_of = m.v.num;
                } else if (std.mem.eql(u8, m.k, "minLength")) {
                    if (m.v == .num) node.min_length = parseIntKeyword(m.v.num);
                } else if (std.mem.eql(u8, m.k, "maxLength")) {
                    if (m.v == .num) node.max_length = parseIntKeyword(m.v.num);
                } else if (std.mem.eql(u8, m.k, "pattern")) {
                    if (m.v == .str) {
                        const re = try a.create(regex_mod.Regex);
                        re.* = try regex_mod.Regex.compile(m.v.str, a);
                        node.pattern = re;
                    }
                } else if (std.mem.eql(u8, m.k, "format")) {
                    if (m.v == .str) node.format = try a.dupe(u8, m.v.str);
                } else if (std.mem.eql(u8, m.k, "minItems")) {
                    if (m.v == .num) node.min_items = parseIntKeyword(m.v.num);
                } else if (std.mem.eql(u8, m.k, "maxItems")) {
                    if (m.v == .num) node.max_items = parseIntKeyword(m.v.num);
                } else if (std.mem.eql(u8, m.k, "uniqueItems")) {
                    if (m.v == .bool) node.unique_items = m.v.bool;
                } else if (std.mem.eql(u8, m.k, "items")) {
                    const loc = try pointer.append(location, "items", a);
                    node.items = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "prefixItems")) {
                    if (m.v == .arr) {
                        var prefix: std.ArrayList(*SchemaNode) = .empty;
                        for (m.v.arr, 0..) |item, i| {
                            const loc = try pointer.appendIndex(location, i, a);
                            try prefix.append(a, try compileNode(a, item, loc, opts, err));
                        }
                        node.prefix_items = try prefix.toOwnedSlice(a);
                    }
                } else if (std.mem.eql(u8, m.k, "contains")) {
                    const loc = try pointer.append(location, "contains", a);
                    node.contains = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "minContains")) {
                    if (m.v == .num) node.min_contains = parseIntKeyword(m.v.num);
                } else if (std.mem.eql(u8, m.k, "maxContains")) {
                    if (m.v == .num) node.max_contains = parseIntKeyword(m.v.num);
                } else if (std.mem.eql(u8, m.k, "minProperties")) {
                    if (m.v == .num) node.min_properties = parseIntKeyword(m.v.num);
                } else if (std.mem.eql(u8, m.k, "maxProperties")) {
                    if (m.v == .num) node.max_properties = parseIntKeyword(m.v.num);
                } else if (std.mem.eql(u8, m.k, "required")) {
                    if (m.v == .arr) {
                        var req: std.ArrayList([]const u8) = .empty;
                        for (m.v.arr) |item| {
                            if (item == .str) try req.append(a, try a.dupe(u8, item.str));
                        }
                        node.required = try req.toOwnedSlice(a);
                    }
                } else if (std.mem.eql(u8, m.k, "properties")) {
                    if (m.v == .obj) {
                        var props = std.StringHashMap(*SchemaNode).init(a);
                        for (m.v.obj) |prop| {
                            const loc = try std.fmt.allocPrint(a, "{s}/properties/{s}", .{ location, prop.k });
                            try props.put(try a.dupe(u8, prop.k), try compileNode(a, prop.v, loc, opts, err));
                        }
                        node.properties = props;
                    }
                } else if (std.mem.eql(u8, m.k, "patternProperties")) {
                    if (m.v == .obj) {
                        var patterns: std.ArrayList(PatternProperty) = .empty;
                        for (m.v.obj) |prop| {
                            const re = try a.create(regex_mod.Regex);
                            re.* = try regex_mod.Regex.compile(prop.k, a);
                            const loc = try pointer.append(location, prop.k, a);
                            try patterns.append(a, .{
                                .pattern = re,
                                .schema = try compileNode(a, prop.v, loc, opts, err),
                            });
                        }
                        node.pattern_properties = try patterns.toOwnedSlice(a);
                    }
                } else if (std.mem.eql(u8, m.k, "additionalProperties")) {
                    const loc = try pointer.append(location, "additionalProperties", a);
                    node.additional_properties = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "propertyNames")) {
                    const loc = try pointer.append(location, "propertyNames", a);
                    node.property_names = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "dependentRequired")) {
                    if (m.v == .obj) {
                        var dep_req = std.StringHashMap([]const []const u8).init(a);
                        for (m.v.obj) |dep| {
                            if (dep.v == .arr) {
                                var reqs: std.ArrayList([]const u8) = .empty;
                                for (dep.v.arr) |r| {
                                    if (r == .str) try reqs.append(a, try a.dupe(u8, r.str));
                                }
                                try dep_req.put(try a.dupe(u8, dep.k), try reqs.toOwnedSlice(a));
                            }
                        }
                        node.dependent_required = dep_req;
                    }
                } else if (std.mem.eql(u8, m.k, "dependentSchemas")) {
                    if (m.v == .obj) {
                        var dep_sch = std.StringHashMap(*SchemaNode).init(a);
                        for (m.v.obj) |dep| {
                            const loc = try pointer.append(location, dep.k, a);
                            try dep_sch.put(try a.dupe(u8, dep.k), try compileNode(a, dep.v, loc, opts, err));
                        }
                        node.dependent_schemas = dep_sch;
                    }
                } else if (std.mem.eql(u8, m.k, "allOf")) {
                    if (m.v == .arr) {
                        var schemas: std.ArrayList(*SchemaNode) = .empty;
                        for (m.v.arr, 0..) |s, i| {
                            const loc = try pointer.appendIndex(location, i, a);
                            try schemas.append(a, try compileNode(a, s, loc, opts, err));
                        }
                        node.all_of = try schemas.toOwnedSlice(a);
                    }
                } else if (std.mem.eql(u8, m.k, "anyOf")) {
                    if (m.v == .arr) {
                        var schemas: std.ArrayList(*SchemaNode) = .empty;
                        for (m.v.arr, 0..) |s, i| {
                            const loc = try pointer.appendIndex(location, i, a);
                            try schemas.append(a, try compileNode(a, s, loc, opts, err));
                        }
                        node.any_of = try schemas.toOwnedSlice(a);
                    }
                } else if (std.mem.eql(u8, m.k, "oneOf")) {
                    if (m.v == .arr) {
                        var schemas: std.ArrayList(*SchemaNode) = .empty;
                        for (m.v.arr, 0..) |s, i| {
                            const loc = try pointer.appendIndex(location, i, a);
                            try schemas.append(a, try compileNode(a, s, loc, opts, err));
                        }
                        node.one_of = try schemas.toOwnedSlice(a);
                    }
                } else if (std.mem.eql(u8, m.k, "not")) {
                    const loc = try pointer.append(location, "not", a);
                    node.not = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "if")) {
                    const loc = try pointer.append(location, "if", a);
                    node.if_schema = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "then")) {
                    const loc = try pointer.append(location, "then", a);
                    node.then_schema = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "else")) {
                    const loc = try pointer.append(location, "else", a);
                    node.else_schema = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "unevaluatedItems")) {
                    const loc = try pointer.append(location, "unevaluatedItems", a);
                    node.unevaluated_items = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "unevaluatedProperties")) {
                    const loc = try pointer.append(location, "unevaluatedProperties", a);
                    node.unevaluated_properties = try compileNode(a, m.v, loc, opts, err);
                } else if (std.mem.eql(u8, m.k, "$defs")) {
                    if (m.v == .obj) {
                        var defs = std.StringHashMap(*SchemaNode).init(a);
                        for (m.v.obj) |def| {
                            const loc = try std.fmt.allocPrint(a, "{s}/$defs/{s}", .{ location, def.k });
                            try defs.put(try a.dupe(u8, def.k), try compileNode(a, def.v, loc, opts, err));
                        }
                        node.defs = defs;
                    }
                }
            }
            return node;
        },
        else => {
            err.* = .{ .code = .SchemaInvalid, .line = 1, .col = 1, .offset = 0 };
            return error.JsonParse;
        },
    }
}

fn parseIntKeyword(n: Number) u64 {
    const val = std.fmt.parseInt(i64, n.digits, 10) catch return 0;
    if (val < 0) return 0;
    return @intCast(val);
}

fn parseTypeKeyword(a: std.mem.Allocator, v: Value) !?[]const []const u8 {
    switch (v) {
        .str => |s| {
            var types: std.ArrayList([]const u8) = .empty;
            try types.append(a, try a.dupe(u8, s));
            return try types.toOwnedSlice(a);
        },
        .arr => |arr| {
            var types: std.ArrayList([]const u8) = .empty;
            for (arr) |item| {
                if (item == .str) try types.append(a, try a.dupe(u8, item.str));
            }
            return try types.toOwnedSlice(a);
        },
        else => return null,
    }
}

const ValidationContext = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ValidationError),
    opts: SchemaOptions,
    schema: *const CompiledSchema,
    evaluated_props: std.StringHashMap(void),
    evaluated_items: std.AutoHashMap(usize, void),
    allocated_ptrs: std.ArrayList([]const u8),
    /// Cache for resolved $ref references - maps (ref, base_uri) to resolved node
    ref_cache: RefCache,
    /// Cache for resolved $dynamicRef references
    dynamic_ref_cache: RefCache,

    /// Cache key combining ref string and base URI
    const RefCacheKey = struct {
        ref: []const u8,
        base_uri: []const u8,

        pub fn hash(self: RefCacheKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(self.ref);
            hasher.update(&[_]u8{0}); // separator
            hasher.update(self.base_uri);
            return hasher.final();
        }

        pub fn eql(a: RefCacheKey, b: RefCacheKey) bool {
            return std.mem.eql(u8, a.ref, b.ref) and std.mem.eql(u8, a.base_uri, b.base_uri);
        }
    };

    const RefCache = std.HashMap(RefCacheKey, ?*const SchemaNode, RefCacheContext, std.hash_map.default_max_load_percentage);

    const RefCacheContext = struct {
        pub fn hash(_: RefCacheContext, key: RefCacheKey) u64 {
            return key.hash();
        }

        pub fn eql(_: RefCacheContext, a: RefCacheKey, b: RefCacheKey) bool {
            return a.eql(b);
        }
    };

    fn init(a: std.mem.Allocator, sch: *const CompiledSchema, opts: SchemaOptions) ValidationContext {
        return .{
            .allocator = a,
            .errors = .empty,
            .opts = opts,
            .schema = sch,
            .evaluated_props = std.StringHashMap(void).init(a),
            .evaluated_items = std.AutoHashMap(usize, void).init(a),
            .allocated_ptrs = .empty,
            .ref_cache = RefCache.init(a),
            .dynamic_ref_cache = RefCache.init(a),
        };
    }

    fn deinit(self: *ValidationContext) void {
        // Free error strings
        for (self.errors.items) |err| {
            self.allocator.free(err.instance_ptr);
            self.allocator.free(err.schema_ptr);
            self.allocator.free(err.keyword);
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);
        self.evaluated_props.deinit();
        self.evaluated_items.deinit();
        for (self.allocated_ptrs.items) |ptr| {
            self.allocator.free(ptr);
        }
        self.allocated_ptrs.deinit(self.allocator);
        self.ref_cache.deinit();
        self.dynamic_ref_cache.deinit();
    }

    /// Get cached $ref resolution or compute and cache it
    fn getCachedRef(self: *ValidationContext, ref: []const u8, base_uri: []const u8) ?*const SchemaNode {
        const key = RefCacheKey{ .ref = ref, .base_uri = base_uri };
        if (self.ref_cache.get(key)) |cached| {
            return cached;
        }

        // Not cached - resolve and cache
        const resolved = resolveRef(self.allocator, self.schema, ref, base_uri);
        self.ref_cache.put(key, resolved) catch {};
        return resolved;
    }

    /// Get cached $dynamicRef resolution or compute and cache it
    fn getCachedDynamicRef(self: *ValidationContext, ref: []const u8, base_uri: []const u8) ?*const SchemaNode {
        const key = RefCacheKey{ .ref = ref, .base_uri = base_uri };
        if (self.dynamic_ref_cache.get(key)) |cached| {
            return cached;
        }

        // Not cached - resolve and cache
        const resolved = resolveDynamicRef(self.allocator, self.schema, ref, base_uri);
        self.dynamic_ref_cache.put(key, resolved) catch {};
        return resolved;
    }

    fn allocPtr(self: *ValidationContext, base: []const u8, key: []const u8) ![]const u8 {
        const ptr = try pointer.append(base, key, self.allocator);
        try self.allocated_ptrs.append(self.allocator, ptr);
        return ptr;
    }

    fn allocIdxPtr(self: *ValidationContext, base: []const u8, idx: usize) ![]const u8 {
        const ptr = try pointer.appendIndex(base, idx, self.allocator);
        try self.allocated_ptrs.append(self.allocator, ptr);
        return ptr;
    }

    fn addError(self: *ValidationContext, inst_ptr: []const u8, schema_ptr: []const u8, keyword: []const u8, message: []const u8) !void {
        if (self.errors.items.len >= self.opts.max_errors) return;

        try self.errors.append(self.allocator, .{
            .instance_ptr = try self.allocator.dupe(u8, inst_ptr),
            .schema_ptr = try self.allocator.dupe(u8, schema_ptr),
            .keyword = try self.allocator.dupe(u8, keyword),
            .message = try self.allocator.dupe(u8, message),
        });
    }
};

pub fn validate(a: std.mem.Allocator, sch: *const CompiledSchema, inst: Value, opts: SchemaOptions) !ValidationReport {
    var ctx = ValidationContext.init(a, sch, opts);
    errdefer ctx.deinit();

    try validateNode(&ctx, inst, sch.root, "", 0);

    const errors = try ctx.errors.toOwnedSlice(a);

    // Clean up ctx resources (except errors which is now owned by caller)
    ctx.evaluated_props.deinit();
    ctx.evaluated_items.deinit();
    for (ctx.allocated_ptrs.items) |ptr| {
        a.free(ptr);
    }
    ctx.allocated_ptrs.deinit(a);
    ctx.ref_cache.deinit();
    ctx.dynamic_ref_cache.deinit();

    // Sort errors deterministically
    std.mem.sort(ValidationError, errors, {}, struct {
        fn lessThan(_: void, lhs: ValidationError, rhs: ValidationError) bool {
            const ptr_cmp = std.mem.order(u8, lhs.instance_ptr, rhs.instance_ptr);
            if (ptr_cmp != .eq) return ptr_cmp == .lt;
            const sch_cmp = std.mem.order(u8, lhs.schema_ptr, rhs.schema_ptr);
            if (sch_cmp != .eq) return sch_cmp == .lt;
            return std.mem.order(u8, lhs.keyword, rhs.keyword) == .lt;
        }
    }.lessThan);

    return .{
        .ok = errors.len == 0,
        .errors = errors,
    };
}

/// Resolve a $ref to a SchemaNode
fn resolveRef(alloc: std.mem.Allocator, schema: *const CompiledSchema, ref: []const u8, current_base: []const u8) ?*const SchemaNode {
    if (ref.len == 0) return null;

    // Fragment-only reference (#, #anchor, #/json/pointer) - resolve against current schema
    if (ref[0] == '#') {
        // Find the schema with the current base URI
        const base_node = if (current_base.len > 0)
            schema.id_registry.get(current_base) orelse schema.root
        else
            schema.root;

        // Root reference
        if (ref.len == 1) return base_node;

        // JSON pointer reference (# followed by /)
        if (ref[1] == '/') {
            const json_ptr = ref[1..];
            return resolvePointer(base_node, json_ptr);
        }

        // Anchor reference (# followed by name)
        const anchor = ref[1..];
        // Try full URI form first
        if (current_base.len > 0) {
            const full_anchor = std.fmt.allocPrint(alloc, "{s}#{s}", .{ current_base, anchor }) catch return null;
            defer alloc.free(full_anchor);
            if (schema.anchors.get(full_anchor)) |node| return node;
        }
        return schema.anchors.get(anchor);
    }

    // Try to resolve the ref as an absolute or relative URI
    var resolved_ref: []const u8 = ref;
    var allocated = false;

    // If ref doesn't have a scheme, try resolving against current base
    if (std.mem.indexOf(u8, ref, ":") == null and current_base.len > 0) {
        // Relative ref - resolve against current base
        const parsed_ref = uri_mod.parse(ref) catch return null;
        const parsed_base = uri_mod.parse(current_base) catch return null;
        var resolved = uri_mod.resolve(alloc, parsed_base, parsed_ref) catch return null;
        defer alloc.free(resolved.path); // Free the allocated path

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        resolved.format(buf.writer(alloc)) catch return null;
        resolved_ref = buf.toOwnedSlice(alloc) catch return null;
        allocated = true;
    }
    defer if (allocated) alloc.free(resolved_ref);

    // Check for fragment in the resolved ref
    if (std.mem.indexOf(u8, resolved_ref, "#")) |frag_pos| {
        const base_uri = resolved_ref[0..frag_pos];
        const frag = resolved_ref[frag_pos + 1 ..];

        // Look up base URI in id_registry
        if (schema.id_registry.get(base_uri)) |base_node| {
            if (frag.len == 0) {
                return base_node;
            } else if (frag[0] == '/') {
                // JSON pointer within the referenced schema
                return resolvePointer(base_node, frag);
            } else {
                // Anchor reference
                if (schema.anchors.get(resolved_ref)) |node| return node;
                return schema.anchors.get(frag);
            }
        }

        // Try looking up the full ref in anchors
        return schema.anchors.get(resolved_ref);
    }

    // No fragment - look up the full URI directly in id_registry
    if (schema.id_registry.get(resolved_ref)) |node| return node;

    // Try looking up in anchors
    return schema.anchors.get(resolved_ref);
}

/// Resolve a $dynamicRef to a SchemaNode
/// Dynamic refs look up in dynamic_anchors instead of anchors
/// Per JSON Schema 2020-12 spec, $dynamicRef resolves to the OUTERMOST $dynamicAnchor in dynamic scope
fn resolveDynamicRef(alloc: std.mem.Allocator, schema: *const CompiledSchema, ref: []const u8, current_base: []const u8) ?*const SchemaNode {
    _ = alloc;
    _ = current_base;
    if (ref.len == 0) return null;

    // $dynamicRef typically has a fragment-only form like "#meta"
    if (ref[0] == '#') {
        const anchor = ref[1..];
        if (anchor.len == 0) return schema.root;

        // For $dynamicRef, always use the plain anchor name (outermost wins per spec)
        // The outermost $dynamicAnchor is the first one registered, stored under plain name
        if (schema.dynamic_anchors.get(anchor)) |node| return node;

        // Fall back to regular anchors
        return schema.anchors.get(anchor);
    }

    // For non-fragment $dynamicRef (rare), look up in dynamic_anchors by URI
    if (std.mem.indexOf(u8, ref, "#")) |frag_pos| {
        const frag = ref[frag_pos + 1 ..];
        if (frag.len > 0 and frag[0] != '/') {
            // Plain anchor fragment - use the plain name for outermost resolution
            if (schema.dynamic_anchors.get(frag)) |node| return node;
            return schema.anchors.get(frag);
        }
    }

    // Try direct lookup
    if (schema.dynamic_anchors.get(ref)) |node| return node;
    return schema.id_registry.get(ref);
}

/// Resolve a JSON pointer within a SchemaNode tree
fn resolvePointer(root: *const SchemaNode, ptr: []const u8) ?*const SchemaNode {
    if (ptr.len == 0) return root;
    if (ptr[0] != '/') return null;

    var current: *const SchemaNode = root;
    var rest = ptr[1..]; // Skip leading /

    // Handle edge case: path is just "/" meaning empty string segment
    if (rest.len == 0) {
        // This would be looking for key "" at root level - not valid for schema
        return null;
    }

    while (true) {
        // Find next segment (empty segments are valid - they represent "" keys)
        const slash_pos = std.mem.indexOf(u8, rest, "/");
        const segment = if (slash_pos) |pos| rest[0..pos] else rest;
        const remaining = if (slash_pos) |pos| rest[pos + 1 ..] else "";
        const has_more = slash_pos != null;

        // Decode JSON pointer escapes (~0 -> ~, ~1 -> /)
        var decoded_buf: [256]u8 = undefined;
        const decoded = decodePointerSegment(segment, &decoded_buf) orelse return null;

        // Handle container segments that need to look at next segment for the key
        if (std.mem.eql(u8, decoded, "$defs")) {
            // $defs requires a next segment (the key name, which can be empty "")
            if (!has_more) return null;

            const next_slash = std.mem.indexOf(u8, remaining, "/");
            const def_name_seg = if (next_slash) |pos| remaining[0..pos] else remaining;
            var def_name_buf: [256]u8 = undefined;
            const def_name = decodePointerSegment(def_name_seg, &def_name_buf) orelse return null;

            if (current.defs) |defs| {
                current = defs.get(def_name) orelse return null;
            } else {
                return null;
            }

            // If there's more path after the key, continue; otherwise we're done
            if (next_slash) |pos| {
                rest = remaining[pos + 1 ..];
                if (rest.len == 0) return current; // Path ended with /
                continue;
            } else {
                return current;
            }
        }

        if (std.mem.eql(u8, decoded, "properties")) {
            if (!has_more) return null;

            const next_slash = std.mem.indexOf(u8, remaining, "/");
            const prop_name_seg = if (next_slash) |pos| remaining[0..pos] else remaining;
            var prop_name_buf: [256]u8 = undefined;
            const prop_name = decodePointerSegment(prop_name_seg, &prop_name_buf) orelse return null;

            if (current.properties) |props| {
                current = props.get(prop_name) orelse return null;
            } else {
                return null;
            }

            if (next_slash) |pos| {
                rest = remaining[pos + 1 ..];
                if (rest.len == 0) return current;
                continue;
            } else {
                return current;
            }
        }

        if (std.mem.eql(u8, decoded, "prefixItems")) {
            if (!has_more) return null;

            const next_slash = std.mem.indexOf(u8, remaining, "/");
            const idx_seg = if (next_slash) |pos| remaining[0..pos] else remaining;
            const idx = std.fmt.parseInt(usize, idx_seg, 10) catch return null;

            if (current.prefix_items) |items| {
                if (idx >= items.len) return null;
                current = items[idx];
            } else {
                return null;
            }

            if (next_slash) |pos| {
                rest = remaining[pos + 1 ..];
                if (rest.len == 0) return current;
                continue;
            } else {
                return current;
            }
        }

        if (std.mem.eql(u8, decoded, "allOf") or std.mem.eql(u8, decoded, "anyOf") or std.mem.eql(u8, decoded, "oneOf")) {
            if (!has_more) return null;

            const next_slash = std.mem.indexOf(u8, remaining, "/");
            const idx_seg = if (next_slash) |pos| remaining[0..pos] else remaining;
            const idx = std.fmt.parseInt(usize, idx_seg, 10) catch return null;

            const arr = if (std.mem.eql(u8, decoded, "allOf"))
                current.all_of
            else if (std.mem.eql(u8, decoded, "anyOf"))
                current.any_of
            else
                current.one_of;

            if (arr) |a| {
                if (idx >= a.len) return null;
                current = a[idx];
            } else {
                return null;
            }

            if (next_slash) |pos| {
                rest = remaining[pos + 1 ..];
                if (rest.len == 0) return current;
                continue;
            } else {
                return current;
            }
        }

        // Direct schema node references
        current = navigateSchema(current, decoded) orelse return null;

        // If no more segments, we're done
        if (!has_more) return current;
        rest = remaining;
        if (rest.len == 0) return current;
    }
}

fn decodePointerSegment(segment: []const u8, buf: []u8) ?[]const u8 {
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < segment.len and out_idx < buf.len) {
        if (i + 1 < segment.len and segment[i] == '~') {
            if (segment[i + 1] == '0') {
                buf[out_idx] = '~';
                i += 2;
            } else if (segment[i + 1] == '1') {
                buf[out_idx] = '/';
                i += 2;
            } else {
                buf[out_idx] = segment[i];
                i += 1;
            }
        } else if (i + 2 < segment.len and segment[i] == '%') {
            // Handle percent-encoding (e.g., %25 -> %)
            const hex = segment[i + 1 .. i + 3];
            buf[out_idx] = std.fmt.parseInt(u8, hex, 16) catch {
                buf[out_idx] = segment[i];
                i += 1;
                out_idx += 1;
                continue;
            };
            i += 3;
        } else {
            buf[out_idx] = segment[i];
            i += 1;
        }
        out_idx += 1;
    }

    return buf[0..out_idx];
}

fn navigateSchema(node: *const SchemaNode, segment: []const u8) ?*const SchemaNode {
    // Direct schema node keyword references
    if (std.mem.eql(u8, segment, "items")) return node.items;
    if (std.mem.eql(u8, segment, "additionalProperties")) return node.additional_properties;
    if (std.mem.eql(u8, segment, "not")) return node.not;
    if (std.mem.eql(u8, segment, "if")) return node.if_schema;
    if (std.mem.eql(u8, segment, "then")) return node.then_schema;
    if (std.mem.eql(u8, segment, "else")) return node.else_schema;
    if (std.mem.eql(u8, segment, "contains")) return node.contains;
    if (std.mem.eql(u8, segment, "propertyNames")) return node.property_names;
    if (std.mem.eql(u8, segment, "unevaluatedItems")) return node.unevaluated_items;
    if (std.mem.eql(u8, segment, "unevaluatedProperties")) return node.unevaluated_properties;

    return null;
}

fn validateNode(ctx: *ValidationContext, inst: Value, node: *const SchemaNode, inst_ptr: []const u8, depth: u16) !void {
    if (depth > ctx.opts.max_ref_depth) return;

    // Boolean schema
    if (node.is_bool_schema) {
        if (!node.bool_value) {
            try ctx.addError(inst_ptr, node.location, "false", "schema is false");
        }
        return;
    }

    // Handle $ref (using cached resolution)
    if (node.ref) |ref| {
        if (ctx.getCachedRef(ref, node.base_uri)) |ref_node| {
            try validateNode(ctx, inst, ref_node, inst_ptr, depth + 1);
        }
    }

    // Handle $dynamicRef (using cached resolution)
    if (node.dynamic_ref) |dref| {
        if (ctx.getCachedDynamicRef(dref, node.base_uri)) |ref_node| {
            try validateNode(ctx, inst, ref_node, inst_ptr, depth + 1);
        }
    }

    // Type validation
    if (node.schema_type) |types| {
        var type_valid = false;
        for (types) |t| {
            if (matchType(inst, t)) {
                type_valid = true;
                break;
            }
        }
        if (!type_valid) {
            try ctx.addError(inst_ptr, node.location, "type", "type mismatch");
        }
    }

    // Const validation
    if (node.const_val) |cv| {
        if (!inst.eql(cv)) {
            try ctx.addError(inst_ptr, node.location, "const", "value mismatch");
        }
    }

    // Enum validation
    if (node.enum_vals) |ev| {
        var found = false;
        for (ev) |e| {
            if (inst.eql(e)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try ctx.addError(inst_ptr, node.location, "enum", "not in enum");
        }
    }

    // Number validations
    if (inst == .num) {
        const num = inst.num;

        if (node.minimum) |min| {
            if (number_mod.compare(num, min) < 0) {
                try ctx.addError(inst_ptr, node.location, "minimum", "must be >= minimum");
            }
        }

        if (node.maximum) |max| {
            if (number_mod.compare(num, max) > 0) {
                try ctx.addError(inst_ptr, node.location, "maximum", "exceeds maximum");
            }
        }

        if (node.exclusive_minimum) |min| {
            if (number_mod.compare(num, min) <= 0) {
                try ctx.addError(inst_ptr, node.location, "exclusiveMinimum", "must be > exclusiveMinimum");
            }
        }

        if (node.exclusive_maximum) |max| {
            if (number_mod.compare(num, max) >= 0) {
                try ctx.addError(inst_ptr, node.location, "exclusiveMaximum", "must be < exclusiveMaximum");
            }
        }

        if (node.multiple_of) |mult| {
            if (!number_mod.isMultipleOf(num, mult)) {
                try ctx.addError(inst_ptr, node.location, "multipleOf", "not a multiple");
            }
        }
    }

    // String validations
    if (inst == .str) {
        const str = inst.str;

        if (node.min_length) |min| {
            const len = countUtf8CodePoints(str);
            if (len < min) {
                try ctx.addError(inst_ptr, node.location, "minLength", "string too short");
            }
        }

        if (node.max_length) |max| {
            const len = countUtf8CodePoints(str);
            if (len > max) {
                try ctx.addError(inst_ptr, node.location, "maxLength", "string too long");
            }
        }

        if (node.pattern) |pat| {
            const matches = pat.match(str, ctx.opts.regex_max_steps) catch false;
            if (!matches) {
                try ctx.addError(inst_ptr, node.location, "pattern", "does not match pattern");
            }
        }

        if (node.format) |fmt| {
            if (ctx.opts.format_assertion) {
                if (!validateFormat(str, fmt, ctx.opts)) {
                    var msg_buf: [64]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "must match format {s}", .{fmt}) catch "invalid format";
                    try ctx.addError(inst_ptr, node.location, "format", msg);
                }
            }
        }
    }

    // Array validations
    if (inst == .arr) {
        const arr = inst.arr;

        if (node.min_items) |min| {
            if (arr.len < min) {
                try ctx.addError(inst_ptr, node.location, "minItems", "too few items");
            }
        }

        if (node.max_items) |max| {
            if (arr.len > max) {
                try ctx.addError(inst_ptr, node.location, "maxItems", "too many items");
            }
        }

        if (node.unique_items) {
            outer: for (arr, 0..) |item, i| {
                for (arr[i + 1 ..]) |other| {
                    if (item.eql(other)) {
                        try ctx.addError(inst_ptr, node.location, "uniqueItems", "items not unique");
                        break :outer;
                    }
                }
            }
        }

        // Prefix items
        var prefix_len: usize = 0;
        if (node.prefix_items) |prefix| {
            prefix_len = prefix.len;
            for (prefix, 0..) |schema, i| {
                if (i < arr.len) {
                    const item_ptr = try ctx.allocIdxPtr(inst_ptr, i);
                    try validateNode(ctx, arr[i], schema, item_ptr, depth);
                    try ctx.evaluated_items.put(i, {});
                }
            }
        }

        // Items schema (only for items beyond prefix_len)
        if (node.items) |items_schema| {
            if (prefix_len < arr.len) {
                for (arr[prefix_len..], prefix_len..) |item, i| {
                    const item_ptr = try ctx.allocIdxPtr(inst_ptr, i);
                    try validateNode(ctx, item, items_schema, item_ptr, depth);
                    try ctx.evaluated_items.put(i, {});
                }
            }
        }

        // Contains
        if (node.contains) |contains_schema| {
            var count: u64 = 0;
            for (arr, 0..) |item, i| {
                var sub_ctx = ValidationContext.init(ctx.allocator, ctx.schema, ctx.opts);
                defer sub_ctx.deinit();
                validateNode(&sub_ctx, item, contains_schema, "", depth) catch continue;
                if (sub_ctx.errors.items.len == 0) {
                    count += 1;
                    try ctx.evaluated_items.put(i, {});
                }
            }

            const min_contains = node.min_contains orelse 1;
            if (count < min_contains) {
                try ctx.addError(inst_ptr, node.location, "contains", "too few matches");
            }
            if (node.max_contains) |max| {
                if (count > max) {
                    try ctx.addError(inst_ptr, node.location, "contains", "too many matches");
                }
            }
        }
    }

    // Object validations
    if (inst == .obj) {
        const obj = inst.obj;

        if (node.min_properties) |min| {
            if (obj.len < min) {
                try ctx.addError(inst_ptr, node.location, "minProperties", "too few properties");
            }
        }

        if (node.max_properties) |max| {
            if (obj.len > max) {
                try ctx.addError(inst_ptr, node.location, "maxProperties", "too many properties");
            }
        }

        // Required
        if (node.required) |required| {
            for (required) |req| {
                var found = false;
                for (obj) |m| {
                    if (std.mem.eql(u8, m.k, req)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try ctx.addError(inst_ptr, node.location, "required", "missing required property");
                }
            }
        }

        // Properties
        if (node.properties) |properties| {
            for (obj) |m| {
                if (properties.get(m.k)) |prop_schema| {
                    const prop_ptr = try ctx.allocPtr(inst_ptr, m.k);
                    try validateNode(ctx, m.v, prop_schema, prop_ptr, depth);
                    try ctx.evaluated_props.put(m.k, {});
                }
            }
        }

        // Pattern properties
        if (node.pattern_properties) |patterns| {
            for (obj) |m| {
                for (patterns) |pp| {
                    const matches = pp.pattern.match(m.k, ctx.opts.regex_max_steps) catch false;
                    if (matches) {
                        const prop_ptr = try ctx.allocPtr(inst_ptr, m.k);
                        try validateNode(ctx, m.v, pp.schema, prop_ptr, depth);
                        try ctx.evaluated_props.put(m.k, {});
                    }
                }
            }
        }

        // Additional properties
        if (node.additional_properties) |ap_schema| {
            for (obj) |m| {
                var covered = false;

                if (node.properties) |props| {
                    if (props.contains(m.k)) covered = true;
                }

                if (!covered and node.pattern_properties != null) {
                    for (node.pattern_properties.?) |pp| {
                        if (pp.pattern.match(m.k, ctx.opts.regex_max_steps) catch false) {
                            covered = true;
                            break;
                        }
                    }
                }

                if (!covered) {
                    const prop_ptr = try ctx.allocPtr(inst_ptr, m.k);
                    try validateNode(ctx, m.v, ap_schema, prop_ptr, depth);
                    try ctx.evaluated_props.put(m.k, {});
                }
            }
        }

        // Property names
        if (node.property_names) |pn_schema| {
            for (obj) |m| {
                try validateNode(ctx, .{ .str = m.k }, pn_schema, inst_ptr, depth);
            }
        }

        // Dependent required
        if (node.dependent_required) |dep_req| {
            for (obj) |m| {
                if (dep_req.get(m.k)) |reqs| {
                    for (reqs) |req| {
                        var found = false;
                        for (obj) |m2| {
                            if (std.mem.eql(u8, m2.k, req)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            try ctx.addError(inst_ptr, node.location, "dependentRequired", "missing dependent property");
                        }
                    }
                }
            }
        }

        // Dependent schemas
        if (node.dependent_schemas) |dep_sch| {
            for (obj) |m| {
                if (dep_sch.get(m.k)) |schema| {
                    try validateNode(ctx, inst, schema, inst_ptr, depth);
                }
            }
        }
    }

    // allOf
    if (node.all_of) |schemas| {
        for (schemas) |schema| {
            try validateNode(ctx, inst, schema, inst_ptr, depth);
        }
    }

    // anyOf - must collect annotations from ALL matching branches
    if (node.any_of) |schemas| {
        var valid = false;
        for (schemas) |schema| {
            var sub_ctx = ValidationContext.init(ctx.allocator, ctx.schema, ctx.opts);
            defer sub_ctx.deinit();
            validateNode(&sub_ctx, inst, schema, inst_ptr, depth) catch continue;
            if (sub_ctx.errors.items.len == 0) {
                valid = true;
                // Merge evaluated tracking from successful branch
                var prop_it = sub_ctx.evaluated_props.keyIterator();
                while (prop_it.next()) |key| {
                    try ctx.evaluated_props.put(key.*, {});
                }
                var item_it = sub_ctx.evaluated_items.keyIterator();
                while (item_it.next()) |key| {
                    try ctx.evaluated_items.put(key.*, {});
                }
            }
        }
        if (!valid) {
            try ctx.addError(inst_ptr, node.location, "anyOf", "no schema matched");
        }
    }

    // oneOf - must collect annotations from the single matching branch
    if (node.one_of) |schemas| {
        var valid_count: usize = 0;
        var matching_props = std.StringHashMap(void).init(ctx.allocator);
        defer matching_props.deinit();
        var matching_items = std.AutoHashMap(usize, void).init(ctx.allocator);
        defer matching_items.deinit();

        for (schemas) |schema| {
            var sub_ctx = ValidationContext.init(ctx.allocator, ctx.schema, ctx.opts);
            defer sub_ctx.deinit();
            validateNode(&sub_ctx, inst, schema, inst_ptr, depth) catch continue;
            if (sub_ctx.errors.items.len == 0) {
                valid_count += 1;
                if (valid_count == 1) {
                    // Save evaluated tracking from first (and hopefully only) match
                    var prop_it = sub_ctx.evaluated_props.keyIterator();
                    while (prop_it.next()) |key| {
                        try matching_props.put(key.*, {});
                    }
                    var item_it = sub_ctx.evaluated_items.keyIterator();
                    while (item_it.next()) |key| {
                        try matching_items.put(key.*, {});
                    }
                }
            }
        }
        if (valid_count == 1) {
            // Merge evaluated tracking from the single matching branch
            var prop_it = matching_props.keyIterator();
            while (prop_it.next()) |key| {
                try ctx.evaluated_props.put(key.*, {});
            }
            var item_it = matching_items.keyIterator();
            while (item_it.next()) |key| {
                try ctx.evaluated_items.put(key.*, {});
            }
        } else {
            try ctx.addError(inst_ptr, node.location, "oneOf", "must match exactly one");
        }
    }

    // not
    if (node.not) |not_schema| {
        var sub_ctx = ValidationContext.init(ctx.allocator, ctx.schema, ctx.opts);
        defer sub_ctx.deinit();
        validateNode(&sub_ctx, inst, not_schema, inst_ptr, depth) catch {};
        if (sub_ctx.errors.items.len == 0) {
            try ctx.addError(inst_ptr, node.location, "not", "must not match");
        }
    }

    // if/then/else - must collect annotations from if and the executed branch
    if (node.if_schema) |if_sch| {
        var sub_ctx = ValidationContext.init(ctx.allocator, ctx.schema, ctx.opts);
        defer sub_ctx.deinit();
        validateNode(&sub_ctx, inst, if_sch, inst_ptr, depth) catch {};

        // Merge evaluated tracking from if branch (regardless of result)
        var prop_it = sub_ctx.evaluated_props.keyIterator();
        while (prop_it.next()) |key| {
            try ctx.evaluated_props.put(key.*, {});
        }
        var item_it = sub_ctx.evaluated_items.keyIterator();
        while (item_it.next()) |key| {
            try ctx.evaluated_items.put(key.*, {});
        }

        if (sub_ctx.errors.items.len == 0) {
            if (node.then_schema) |then_sch| {
                try validateNode(ctx, inst, then_sch, inst_ptr, depth);
            }
        } else {
            if (node.else_schema) |else_sch| {
                try validateNode(ctx, inst, else_sch, inst_ptr, depth);
            }
        }
    }

    // Unevaluated properties
    if (inst == .obj and node.unevaluated_properties != null) {
        const obj = inst.obj;
        for (obj) |m| {
            if (!ctx.evaluated_props.contains(m.k)) {
                const prop_ptr = try ctx.allocPtr(inst_ptr, m.k);
                try validateNode(ctx, m.v, node.unevaluated_properties.?, prop_ptr, depth);
            }
        }
    }

    // Unevaluated items
    if (inst == .arr and node.unevaluated_items != null) {
        const arr = inst.arr;
        for (arr, 0..) |item, i| {
            if (!ctx.evaluated_items.contains(i)) {
                const item_ptr = try ctx.allocIdxPtr(inst_ptr, i);
                try validateNode(ctx, item, node.unevaluated_items.?, item_ptr, depth);
            }
        }
    }
}

fn matchType(v: Value, t: []const u8) bool {
    if (std.mem.eql(u8, t, "null")) return v == .null;
    if (std.mem.eql(u8, t, "boolean")) return v == .bool;
    if (std.mem.eql(u8, t, "string")) return v == .str;
    if (std.mem.eql(u8, t, "array")) return v == .arr;
    if (std.mem.eql(u8, t, "object")) return v == .obj;
    if (std.mem.eql(u8, t, "number")) return v == .num;
    if (std.mem.eql(u8, t, "integer")) {
        return v == .num and number_mod.isInteger(v.num);
    }
    return false;
}

/// Count UTF-8 code points in a string (for JSON Schema minLength/maxLength)
fn countUtf8CodePoints(str: []const u8) u64 {
    var count: u64 = 0;
    var i: usize = 0;
    while (i < str.len) {
        const byte = str[i];
        // Count number of leading 1 bits to determine code point size
        if (byte & 0x80 == 0) {
            // ASCII: 0xxxxxxx
            i += 1;
        } else if (byte & 0xE0 == 0xC0) {
            // 2-byte: 110xxxxx 10xxxxxx
            i += 2;
        } else if (byte & 0xF0 == 0xE0) {
            // 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
            i += 3;
        } else if (byte & 0xF8 == 0xF0) {
            // 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
            i += 4;
        } else {
            // Invalid UTF-8 or continuation byte, skip
            i += 1;
        }
        count += 1;
    }
    return count;
}

fn validateFormat(str: []const u8, fmt: []const u8, opts: SchemaOptions) bool {
    // Check custom format validators first
    if (opts.custom_formats) |custom| {
        for (custom) |validator| {
            if (std.mem.eql(u8, validator.name, fmt)) {
                return validator.validate(str);
            }
        }
    }

    // Built-in format validators
    if (std.mem.eql(u8, fmt, "email")) {
        return std.mem.indexOf(u8, str, "@") != null;
    }
    if (std.mem.eql(u8, fmt, "uri")) {
        return std.mem.indexOf(u8, str, "://") != null;
    }
    if (std.mem.eql(u8, fmt, "date")) {
        if (str.len != 10) return false;
        return str[4] == '-' and str[7] == '-';
    }
    if (std.mem.eql(u8, fmt, "date-time")) {
        return std.mem.indexOf(u8, str, "T") != null;
    }
    if (std.mem.eql(u8, fmt, "uuid")) {
        if (str.len != 36) return false;
        return str[8] == '-' and str[13] == '-' and str[18] == '-' and str[23] == '-';
    }
    // Unknown formats pass
    return true;
}

test "validate type string" {
    const allocator = std.testing.allocator;

    const schema_json = "{\"type\":\"string\"}";
    var err = json.ParseError.init();
    var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
    defer schema_doc.deinit();

    var compiled = try compile(allocator, &schema_doc, .{}, null, &err);
    defer compiled.deinit();

    // Valid
    const valid_json = "\"hello\"";
    var valid_doc = try json.parse(allocator, valid_json, .{}, &err);
    defer valid_doc.deinit();

    const valid_result = try validate(allocator, &compiled, valid_doc.root, .{});
    defer allocator.free(valid_result.errors);
    try std.testing.expect(valid_result.ok);

    // Invalid
    const invalid_json = "42";
    var invalid_doc = try json.parse(allocator, invalid_json, .{}, &err);
    defer invalid_doc.deinit();

    const invalid_result = try validate(allocator, &compiled, invalid_doc.root, .{});
    defer {
        for (invalid_result.errors) |e| {
            allocator.free(e.instance_ptr);
            allocator.free(e.schema_ptr);
            allocator.free(e.keyword);
            allocator.free(e.message);
        }
        allocator.free(invalid_result.errors);
    }
    try std.testing.expect(!invalid_result.ok);
}

test "validate minimum" {
    const allocator = std.testing.allocator;

    const schema_json = "{\"minimum\":10}";
    var err = json.ParseError.init();
    var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
    defer schema_doc.deinit();

    var compiled = try compile(allocator, &schema_doc, .{}, null, &err);
    defer compiled.deinit();

    // Invalid - below minimum
    const invalid_json = "5";
    var invalid_doc = try json.parse(allocator, invalid_json, .{}, &err);
    defer invalid_doc.deinit();

    const result = try validate(allocator, &compiled, invalid_doc.root, .{});
    defer {
        for (result.errors) |e| {
            allocator.free(e.instance_ptr);
            allocator.free(e.schema_ptr);
            allocator.free(e.keyword);
            allocator.free(e.message);
        }
        allocator.free(result.errors);
    }
    try std.testing.expect(!result.ok);
}

test "custom format validator" {
    const allocator = std.testing.allocator;

    // Custom format that requires strings to start with "TEST-"
    const test_format = struct {
        fn validate(str: []const u8) bool {
            return std.mem.startsWith(u8, str, "TEST-");
        }
    }.validate;

    const custom_formats = [_]json.FormatValidator{
        .{ .name = "test-format", .validate = test_format },
    };

    const schema_json =
        \\{"type":"string","format":"test-format"}
    ;
    var err = json.ParseError.init();
    var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
    defer schema_doc.deinit();

    var compiled = try compile(allocator, &schema_doc, .{}, null, &err);
    defer compiled.deinit();

    // Valid - starts with TEST-
    {
        const valid_json = "\"TEST-123\"";
        var valid_doc = try json.parse(allocator, valid_json, .{}, &err);
        defer valid_doc.deinit();

        const result = try validate(allocator, &compiled, valid_doc.root, .{
            .custom_formats = &custom_formats,
        });
        defer {
            for (result.errors) |e| {
                allocator.free(e.instance_ptr);
                allocator.free(e.schema_ptr);
                allocator.free(e.keyword);
                allocator.free(e.message);
            }
            allocator.free(result.errors);
        }
        try std.testing.expect(result.ok);
    }

    // Invalid - doesn't start with TEST-
    {
        const invalid_json = "\"INVALID-123\"";
        var invalid_doc = try json.parse(allocator, invalid_json, .{}, &err);
        defer invalid_doc.deinit();

        const result = try validate(allocator, &compiled, invalid_doc.root, .{
            .custom_formats = &custom_formats,
        });
        defer {
            for (result.errors) |e| {
                allocator.free(e.instance_ptr);
                allocator.free(e.schema_ptr);
                allocator.free(e.keyword);
                allocator.free(e.message);
            }
            allocator.free(result.errors);
        }
        try std.testing.expect(!result.ok);
    }
}
