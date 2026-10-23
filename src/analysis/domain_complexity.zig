const std = @import("std");

/// Observable infrastructure/database constructs, not semantic difficulty.
pub const Counts = struct {
    terraform_resources: u64 = 0,
    terraform_data_sources: u64 = 0,
    terraform_modules: u64 = 0,
    terraform_providers: u64 = 0,
    terraform_dynamic_blocks: u64 = 0,
    terraform_iterations: u64 = 0,
    terraform_explicit_dependencies: u64 = 0,
    terraform_conditionals: u64 = 0,
    sql_tables: u64 = 0,
    sql_foreign_references: u64 = 0,
    sql_indexes: u64 = 0,
    sql_views: u64 = 0,
    sql_procedures: u64 = 0,
    sql_functions: u64 = 0,
    sql_triggers: u64 = 0,
    sql_joins: u64 = 0,
    sql_ctes: u64 = 0,
    sql_unions: u64 = 0,

    pub fn points(c: Counts) u64 {
        return 8 * c.terraform_resources + 6 * c.terraform_data_sources +
            10 * c.terraform_modules + 6 * c.terraform_providers +
            4 * c.terraform_dynamic_blocks + 3 * c.terraform_iterations +
            5 * c.terraform_explicit_dependencies + 3 * c.terraform_conditionals +
            8 * c.sql_tables + 8 * c.sql_foreign_references +
            4 * c.sql_indexes + 10 * c.sql_views +
            24 * c.sql_procedures + 24 * c.sql_functions +
            20 * c.sql_triggers + 4 * c.sql_joins +
            5 * c.sql_ctes + 3 * c.sql_unions;
    }

    pub fn add(c: *Counts, other: Counts) void {
        inline for (@typeInfo(Counts).@"struct".fields) |field| {
            @field(c, field.name) += @field(other, field.name);
        }
    }

    /// Added constructs are review signals. Removed constructs belong in the
    /// signed repository snapshot delta, not negative PR work points.
    pub fn added(after: Counts, before: Counts) Counts {
        var result: Counts = .{};
        inline for (@typeInfo(Counts).@"struct".fields) |field| {
            const a = @field(after, field.name);
            const b = @field(before, field.name);
            @field(result, field.name) = a -| b;
        }
        return result;
    }
};

pub fn isTerraform(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".tf");
}

pub fn isSql(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".sql");
}

fn startsWord(line: []const u8, word: []const u8) bool {
    return std.mem.startsWith(u8, line, word) and
        (line.len == word.len or std.ascii.isWhitespace(line[word.len]) or line[word.len] == '"' or line[word.len] == '{');
}

fn assignment(line: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, line, word)) return false;
    const rest = std.mem.trimStart(u8, line[word.len..], " \t");
    return rest.len > 0 and rest[0] == '=';
}

fn scanTerraform(text: []const u8) Counts {
    var c: Counts = .{};
    var in_block_comment = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var candidate = raw;
        if (in_block_comment) {
            const end = std.mem.indexOf(u8, candidate, "*/") orelse continue;
            candidate = candidate[end + 2 ..];
            in_block_comment = false;
        }
        if (std.mem.indexOf(u8, candidate, "/*")) |start| {
            if (std.mem.indexOf(u8, candidate[start + 2 ..], "*/") == null) in_block_comment = true;
            candidate = candidate[0..start];
        }
        const line = std.mem.trim(u8, candidate, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;
        if (startsWord(line, "resource")) c.terraform_resources += 1;
        if (startsWord(line, "data")) c.terraform_data_sources += 1;
        if (startsWord(line, "module")) c.terraform_modules += 1;
        if (startsWord(line, "provider")) c.terraform_providers += 1;
        if (startsWord(line, "dynamic")) c.terraform_dynamic_blocks += 1;
        if (assignment(line, "for_each") or assignment(line, "count")) c.terraform_iterations += 1;
        if (assignment(line, "depends_on")) c.terraform_explicit_dependencies += 1;
        // A ternary adds an alternate configuration path. Require spaces to
        // avoid URLs, interpolation delimiters, and most quoted prose.
        if (std.mem.indexOf(u8, line, " ? ") != null) c.terraform_conditionals += 1;
    }
    return c;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn created(a: []const u8, b: []const u8, c: []const u8, d: []const u8) bool {
    return eq(a, "create") or eq(b, "create") or eq(c, "create") or eq(d, "create");
}

fn scanSql(allocator: std.mem.Allocator, text: []const u8) !Counts {
    // Strip comments and quoted literals before looking for SQL keywords.
    // This remains a dialect-neutral proxy, not a parser or a live schema.
    const clean = try allocator.alloc(u8, text.len);
    defer allocator.free(clean);
    const State = enum { normal, line_comment, block_comment, single_quote, double_quote };
    var state: State = .normal;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        const next: u8 = if (i + 1 < text.len) text[i + 1] else 0;
        clean[i] = ' ';
        switch (state) {
            .normal => {
                if (ch == '-' and next == '-') {
                    state = .line_comment;
                } else if (ch == '/' and next == '*') {
                    state = .block_comment;
                } else if (ch == '\'') {
                    state = .single_quote;
                } else if (ch == '"') {
                    state = .double_quote;
                } else {
                    clean[i] = std.ascii.toLower(ch);
                }
            },
            .line_comment => if (ch == '\n') {
                state = .normal;
                clean[i] = '\n';
            },
            .block_comment => if (ch == '*' and next == '/') {
                state = .normal;
                i += 1;
                clean[i] = ' ';
            },
            .single_quote => if (ch == '\'' and next == '\'') {
                i += 1;
                clean[i] = ' ';
            } else if (ch == '\'') {
                state = .normal;
            },
            .double_quote => if (ch == '"' and next == '"') {
                i += 1;
                clean[i] = ' ';
            } else if (ch == '"') {
                state = .normal;
            },
        }
    }

    var result: Counts = .{};
    var tokens = std.mem.tokenizeAny(u8, clean, " \t\r\n(){};,.[]");
    var p1: []const u8 = "";
    var p2: []const u8 = "";
    var p3: []const u8 = "";
    var p4: []const u8 = "";
    while (tokens.next()) |token| {
        const ddl = created(p1, p2, p3, p4);
        if (eq(token, "table") and ddl) result.sql_tables += 1;
        if (eq(token, "index") and ddl) result.sql_indexes += 1;
        if (eq(token, "view") and ddl) result.sql_views += 1;
        if (eq(token, "procedure") and ddl) result.sql_procedures += 1;
        if (eq(token, "function") and ddl) result.sql_functions += 1;
        if (eq(token, "trigger") and ddl) result.sql_triggers += 1;
        if (eq(token, "references")) result.sql_foreign_references += 1;
        if (eq(token, "join")) result.sql_joins += 1;
        if (eq(token, "with") and !eq(p1, "create")) result.sql_ctes += 1;
        if (eq(token, "union")) result.sql_unions += 1;
        p4 = p3;
        p3 = p2;
        p2 = p1;
        p1 = token;
    }
    return result;
}

pub fn scan(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !Counts {
    if (isTerraform(path)) return scanTerraform(text);
    if (isSql(path)) return try scanSql(allocator, text);
    return .{};
}

test "terraform dimensions exclude comments" {
    const c = try scan(std.testing.allocator, "infra/main.tf",
        \\# resource "ignore" "x" {}
        \\/* resource "also_ignored" "x" {
        \\   module "also_ignored" {}
        \\*/
        \\resource "aws_instance" "app" {
        \\  count = 2
        \\  depends_on = [module.network]
        \\  name = var.enabled ? "on" : "off"
        \\}
        \\data "aws_ami" "base" {}
        \\module "network" {}
        \\provider "aws" {}
        \\dynamic "ingress" {}
    );
    try std.testing.expectEqual(@as(u64, 1), c.terraform_resources);
    try std.testing.expectEqual(@as(u64, 1), c.terraform_data_sources);
    try std.testing.expectEqual(@as(u64, 1), c.terraform_modules);
    try std.testing.expectEqual(@as(u64, 1), c.terraform_iterations);
    try std.testing.expectEqual(@as(u64, 1), c.terraform_conditionals);
}

test "SQL dimensions ignore comments and strings" {
    const c = try scan(std.testing.allocator, "db/schema.sql",
        \\-- CREATE PROCEDURE phantom
        \\CREATE TABLE orders (customer_id INT REFERENCES customers(id));
        \\CREATE INDEX orders_customer_idx ON orders(customer_id);
        \\CREATE VIEW order_summary AS SELECT * FROM orders JOIN customers ON true;
        \\CREATE OR REPLACE FUNCTION order_total() RETURNS INT AS 'SELECT JOIN' LANGUAGE sql;
        \\CREATE TRIGGER update_total AFTER UPDATE ON orders;
        \\WITH recent AS (SELECT * FROM orders) SELECT * FROM recent UNION SELECT * FROM orders;
    );
    try std.testing.expectEqual(@as(u64, 1), c.sql_tables);
    try std.testing.expectEqual(@as(u64, 1), c.sql_indexes);
    try std.testing.expectEqual(@as(u64, 1), c.sql_views);
    try std.testing.expectEqual(@as(u64, 1), c.sql_functions);
    try std.testing.expectEqual(@as(u64, 0), c.sql_procedures);
    try std.testing.expectEqual(@as(u64, 1), c.sql_foreign_references);
    try std.testing.expectEqual(@as(u64, 1), c.sql_joins);
    try std.testing.expectEqual(@as(u64, 1), c.sql_ctes);
    try std.testing.expectEqual(@as(u64, 1), c.sql_unions);
}
