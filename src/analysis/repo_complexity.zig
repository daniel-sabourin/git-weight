const std = @import("std");
const object_id = @import("../git/object_id.zig");
const objects = @import("objects.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");
const domain = @import("domain_complexity.zig");

/// A stock measure: only blobs reachable from one commit's tree contribute.
/// This is deliberately distinct from the PR report's churn/work measure.
pub const Report = struct {
    pub const score_version = "complexity-2";
    revision: []const u8,
    commit: object_id.ObjectId,
    committed_at: ?i64,
    total_points: u64 = 0,
    size_points: u64 = 0,
    structural_points: u64 = 0,
    domain_points: u64 = 0,
    points_per_kloc: u64 = 0,
    structural_points_per_kloc: u64 = 0,
    domain_points_per_kloc: u64 = 0,
    source_files: u64 = 0,
    source_lines: u64 = 0,
    branch_lines: u64 = 0,
    internal_imports: u64 = 0,
    external_host_references: u64 = 0,
    dependency_manifests: u64 = 0,
    ui_components: u64 = 0,
    crypto_files: u64 = 0,
    algorithm_files: u64 = 0,
    excluded_files: u64 = 0,
    binary_files: u64 = 0,
    terraform_files: u64 = 0,
    sql_files: u64 = 0,
    sql_migration_files: u64 = 0,
    domain_counts: domain.Counts = .{},
    comparison: ?Comparison = null,

    pub const Comparison = struct {
        base_revision: []const u8,
        base_commit: object_id.ObjectId,
        base_points: u64,
        delta_points: i128,
    };
};

fn source(path: []const u8) bool {
    if (domain.isTerraform(path) or domain.isSql(path)) return true;
    const extensions = [_][]const u8{ ".zig", ".go", ".py", ".js", ".jsx", ".ts", ".tsx", ".vue", ".svelte", ".java", ".kt", ".swift", ".rs", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs", ".rb", ".php", ".sh" };
    for (extensions) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
    return false;
}

fn excluded(path: []const u8) bool {
    const parts = [_][]const u8{ "vendor/", "node_modules/", "dist/", "build/", "generated/", ".gen.", "_generated.", ".min." };
    for (parts) |part| if (std.mem.indexOf(u8, path, part) != null) return true;
    return false;
}

fn dependencyManifest(path: []const u8) bool {
    const names = [_][]const u8{ "package.json", "go.mod", "Cargo.toml", "pyproject.toml", "requirements.txt", "Gemfile", "build.zig.zon", "Package.swift" };
    for (names) |name| if (std.mem.endsWith(u8, path, name)) return true;
    return false;
}

fn uiComponent(path: []const u8) bool {
    const ui = std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".jsx") or std.mem.endsWith(u8, path, ".vue") or std.mem.endsWith(u8, path, ".svelte");
    return ui and (std.mem.indexOf(u8, path, "components/") != null or std.mem.indexOf(u8, path, "Components/") != null);
}

fn containsAny(line: []const u8, words: []const []const u8) bool {
    for (words) |word| if (std.mem.indexOf(u8, line, word) != null) return true;
    return false;
}

fn branchLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const words = [_][]const u8{ "if ", "if(", "else if", "elif ", "for ", "for(", "while ", "while(", "case ", "catch ", "catch(", "except ", "switch ", "switch(", "match " };
    for (words) |word| if (std.mem.startsWith(u8, trimmed, word)) return true;
    return false;
}

fn scanFile(allocator: std.mem.Allocator, path: []const u8, text: []const u8, go_module_prefix: ?[]const u8, report: *Report) !void {
    var seen_imports: std.StringHashMapUnmanaged(void) = .empty;
    var seen_hosts: std.StringHashMapUnmanaged(void) = .empty;
    var crypto = false;
    var algorithm = false;
    const domain_file = domain.isTerraform(path) or domain.isSql(path);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        report.source_lines += 1;
        if (branchLine(line)) report.branch_lines += 1;
        if (domain_file) continue; // Domain-specific scanner owns these signals.
        const is_import = containsAny(line, &.{ "import ", "from ", "require(", "@import(", "#include " });
        const local_import = (is_import and containsAny(line, &.{ "./", "../", "@/", "crate::", "self::", "super::" })) or
            (std.mem.endsWith(u8, path, ".go") and go_module_prefix != null and std.mem.indexOf(u8, line, go_module_prefix.?) != null);
        if (local_import) {
            const entry = try seen_imports.getOrPut(allocator, line);
            if (!entry.found_existing) report.internal_imports += 1;
        }
        if (std.mem.indexOf(u8, line, "https://") orelse std.mem.indexOf(u8, line, "http://")) |start| {
            const scheme_len: usize = if (std.mem.startsWith(u8, line[start..], "https://")) 8 else 7;
            const rest = line[start + scheme_len ..];
            const end = std.mem.indexOfAny(u8, rest, "/\"' \t:)}") orelse rest.len;
            const host = rest[0..end];
            if (host.len > 0 and !std.mem.eql(u8, host, "localhost")) {
                const entry = try seen_hosts.getOrPut(allocator, host);
                if (!entry.found_existing) report.external_host_references += 1;
            }
        }
        if (containsAny(line, &.{ "crypto", "Crypto", "cipher", "Cipher", "encrypt", "decrypt", "signature", "hmac", "HMAC" })) crypto = true;
        if (containsAny(line, &.{ "algorithm", "Algorithm", "state machine", "binarySearch", "dijkstra", "quicksort", "dynamic programming" })) algorithm = true;
    }
    if (crypto) report.crypto_files += 1;
    if (algorithm) report.algorithm_files += 1;
}

fn goModulePrefix(store: *const objects.ObjectStore, allocator: std.mem.Allocator, tree: object_id.ObjectId) !?[]const u8 {
    const payload = try store.readPayload(allocator, &tree);
    defer payload.release();
    if (payload.object_type != .tree) return error.CorruptRepository;
    var it = tree_mod.TreeIterator.init(payload.data, tree.algorithm);
    while (try it.next()) |entry| {
        if (!std.mem.eql(u8, entry.name, "go.mod") or entry.entryMode() != .blob) continue;
        const blob = try store.readPayload(allocator, &entry.id);
        defer blob.release();
        if (blob.object_type != .blob) return error.CorruptRepository;
        var lines = std.mem.splitScalar(u8, blob.data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "module ")) continue;
            const module = std.mem.trim(u8, line[7..], " \t");
            if (module.len > 0) return try std.fmt.allocPrint(allocator, "{s}/", .{module});
        }
    }
    return null;
}

fn scanTree(store: *const objects.ObjectStore, allocator: std.mem.Allocator, tree: object_id.ObjectId, prefix: []const u8, go_module_prefix: ?[]const u8, report: *Report) !void {
    const payload = try store.readPayload(allocator, &tree);
    defer payload.release();
    if (payload.object_type != .tree) return error.CorruptRepository;
    var it = tree_mod.TreeIterator.init(payload.data, tree.algorithm);
    while (try it.next()) |entry| {
        const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, entry.name });
        switch (entry.entryMode()) {
            .tree => {
                const child = try std.fmt.allocPrint(allocator, "{s}/", .{path});
                try scanTree(store, allocator, entry.id, child, go_module_prefix, report);
            },
            .blob => {
                if (excluded(path)) {
                    report.excluded_files += 1;
                    continue;
                }
                if (dependencyManifest(path)) report.dependency_manifests += 1;
                if (!source(path)) {
                    report.excluded_files += 1;
                    continue;
                }
                const blob = try store.readPayload(allocator, &entry.id);
                defer blob.release();
                if (blob.object_type != .blob) return error.CorruptRepository;
                if (std.mem.indexOfScalar(u8, blob.data, 0) != null) {
                    report.binary_files += 1;
                    continue;
                }
                report.source_files += 1;
                if (domain.isTerraform(path)) report.terraform_files += 1;
                if (domain.isSql(path)) {
                    report.sql_files += 1;
                    if (std.mem.indexOf(u8, path, "migration") != null) report.sql_migration_files += 1;
                }
                if (uiComponent(path)) report.ui_components += 1;
                try scanFile(allocator, path, blob.data, go_module_prefix, report);
                report.domain_counts.add(try domain.scan(allocator, path, blob.data));
            },
            else => {},
        }
    }
}

pub fn build(store: *const objects.ObjectStore, allocator: std.mem.Allocator, name: []const u8, oid: object_id.ObjectId) !Report {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const payload = try store.readPayload(alloc, &oid);
    defer payload.release();
    if (payload.object_type != .commit) return error.CorruptRepository;
    const commit = try commit_mod.parse(payload.data, oid.algorithm, alloc);
    var report: Report = .{ .revision = name, .commit = oid, .committed_at = if (commit.committer) |c| c.timestamp else null };
    const go_module_prefix = try goModulePrefix(store, alloc, commit.tree);
    try scanTree(store, alloc, commit.tree, "", go_module_prefix, &report);
    report.size_points = report.source_lines;
    report.structural_points = 4 * report.branch_lines + 3 * report.source_files +
        6 * report.internal_imports + 12 * report.external_host_references +
        4 * report.dependency_manifests + 6 * report.ui_components +
        10 * report.crypto_files + 8 * report.algorithm_files;
    report.domain_points = report.domain_counts.points();
    report.total_points = report.size_points + report.structural_points + report.domain_points;
    if (report.source_lines > 0) {
        report.points_per_kloc = (report.total_points * 1000 + report.source_lines / 2) / report.source_lines;
        report.structural_points_per_kloc = (report.structural_points * 1000 + report.source_lines / 2) / report.source_lines;
        report.domain_points_per_kloc = (report.domain_points * 1000 + report.source_lines / 2) / report.source_lines;
    }
    return report;
}

test "snapshot counts active signals, not removed files" {
    var report: Report = .{ .revision = "HEAD", .commit = undefined, .committed_at = null };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try scanFile(arena.allocator(), "src/app.ts", "import x from './lib';\nif (x) {\nhttps://partner.example/v1\ncrypto.encrypt(x)\n", null, &report);
    try std.testing.expectEqual(@as(u64, 4), report.source_lines);
    try std.testing.expectEqual(@as(u64, 1), report.branch_lines);
    try std.testing.expectEqual(@as(u64, 1), report.internal_imports);
    try std.testing.expectEqual(@as(u64, 1), report.external_host_references);
    try std.testing.expectEqual(@as(u64, 1), report.crypto_files);
}

test "go module imports count as internal coupling" {
    var report: Report = .{ .revision = "HEAD", .commit = undefined, .committed_at = null };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try scanFile(arena.allocator(), "src/main.go", "\"example.com/project/internal/api\"\n\"net/http\"\n", "example.com/project/", &report);
    try std.testing.expectEqual(@as(u64, 1), report.internal_imports);
}
