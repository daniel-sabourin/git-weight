const std = @import("std");
const object_id = @import("../git/object_id.zig");
const objects = @import("objects.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");
const domain = @import("domain_complexity.zig");

pub const Report = struct {
    pub const score_version = "pr-2";
    pub const Evidence = struct { dimension: []const u8, path: []const u8, detail: []const u8 };
    base: []const u8,
    to: []const u8,
    base_commit: object_id.ObjectId,
    to_commit: object_id.ObjectId,
    id: ?[]const u8 = null,
    merged_at: ?[]const u8 = null,
    stage: ?[]const u8 = null,
    files: u64 = 0,
    added_lines: u64 = 0,
    removed_lines: u64 = 0,
    added_branches: u64 = 0,
    work_points: u64 = 0,
    complexity_points: u64 = 0,
    domain_points: u64 = 0,
    total_points: u64 = 0,
    internal_imports: u64 = 0,
    external_integrations: u64 = 0,
    dependency_changes: u64 = 0,
    new_ui_components: u64 = 0,
    changed_shared_ui_components: u64 = 0,
    reused_ui_components: u64 = 0,
    crypto_signals: u64 = 0,
    algorithm_signals: u64 = 0,
    excluded_files: u64 = 0,
    binary_files: u64 = 0,
    domain_counts: domain.Counts = .{},
    evidence: []Evidence = &.{},

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.evidence) |item| allocator.free(item.path);
        allocator.free(self.evidence);
    }
};

const FileMap = std.StringHashMapUnmanaged(object_id.ObjectId);

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

fn addEvidence(allocator: std.mem.Allocator, evidence: *std.ArrayList(Report.Evidence), dimension: []const u8, path: []const u8, detail: []const u8) !void {
    if (evidence.items.len >= 64) return;
    try evidence.append(allocator, .{ .dimension = dimension, .path = try allocator.dupe(u8, path), .detail = detail });
}

fn collect(store: *const objects.ObjectStore, alloc: std.mem.Allocator, tree: object_id.ObjectId, prefix: []const u8, files: *FileMap) !void {
    const payload = try store.readPayload(alloc, &tree);
    defer payload.release();
    if (payload.object_type != .tree) return error.CorruptRepository;
    var it = tree_mod.TreeIterator.init(payload.data, tree.algorithm);
    while (try it.next()) |entry| {
        const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, entry.name });
        switch (entry.entryMode()) {
            .tree => {
                const child = try std.fmt.allocPrint(alloc, "{s}/", .{path});
                try collect(store, alloc, entry.id, child, files);
            },
            .blob => try files.put(alloc, path, entry.id),
            else => {},
        }
    }
}

fn commitTree(store: *const objects.ObjectStore, alloc: std.mem.Allocator, oid: object_id.ObjectId) !object_id.ObjectId {
    const payload = try store.readPayload(alloc, &oid);
    defer payload.release();
    if (payload.object_type != .commit) return error.CorruptRepository;
    const commit = try commit_mod.parse(payload.data, oid.algorithm, alloc);
    return commit.tree;
}

fn branchLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const words = [_][]const u8{ "if ", "if(", "else if", "elif ", "for ", "for(", "while ", "while(", "case ", "catch ", "catch(", "except ", "switch ", "switch(", "match " };
    for (words) |word| if (std.mem.startsWith(u8, trimmed, word)) return true;
    return false;
}

const Counts = struct { added: u64 = 0, removed: u64 = 0, branches: u64 = 0 };

// Compare line multisets. Reordered lines do not count as work; duplicate
// occurrences are tracked. This is deliberately a stable proxy, not a diff.
fn compareLines(alloc: std.mem.Allocator, before: []const u8, after: []const u8) !Counts {
    var old: std.StringHashMapUnmanaged(u32) = .empty;
    var old_it = std.mem.splitScalar(u8, before, '\n');
    while (old_it.next()) |line| {
        if (line.len == 0) continue;
        const gop = try old.getOrPut(alloc, line);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var result: Counts = .{};
    var new_it = std.mem.splitScalar(u8, after, '\n');
    while (new_it.next()) |line| {
        if (line.len == 0) continue;
        if (old.getPtr(line)) |count| {
            if (count.* > 0) {
                count.* -= 1;
                continue;
            }
        }
        result.added += 1;
        if (branchLine(line)) result.branches += 1;
    }
    var it = old.iterator();
    while (it.next()) |entry| result.removed += entry.value_ptr.*;
    return result;
}

fn scanSignals(arena: std.mem.Allocator, allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8, path: []const u8, report: *Report, evidence: *std.ArrayList(Report.Evidence), seen_imports: *std.StringHashMapUnmanaged(void), seen_hosts: *std.StringHashMapUnmanaged(void)) !void {
    var old: std.StringHashMapUnmanaged(u32) = .empty;
    var old_it = std.mem.splitScalar(u8, old_text, '\n');
    while (old_it.next()) |line| {
        if (line.len == 0) continue;
        const gop = try old.getOrPut(arena, line);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var crypto_found = false;
    var algorithm_found = false;
    var new_it = std.mem.splitScalar(u8, new_text, '\n');
    while (new_it.next()) |line| {
        if (line.len == 0) continue;
        if (old.getPtr(line)) |count| {
            if (count.* > 0) {
                count.* -= 1;
                continue;
            }
        }
        const is_import = containsAny(line, &.{ "import ", "from ", "require(", "@import(", "#include " });
        if (is_import and containsAny(line, &.{ "./", "../", "@/" })) {
            if (!seen_imports.contains(line)) {
                try seen_imports.put(arena, try arena.dupe(u8, line), {});
                report.internal_imports += 1;
                try addEvidence(allocator, evidence, "internal_import", path, "new relative import");
            }
        }
        if (is_import and containsAny(line, &.{ "components/", "Components/" })) {
            report.reused_ui_components += 1;
            try addEvidence(allocator, evidence, "ui_reuse", path, "component import added");
        }
        if (std.mem.indexOf(u8, line, "https://") orelse std.mem.indexOf(u8, line, "http://")) |url_start| {
            const scheme_len: usize = if (std.mem.startsWith(u8, line[url_start..], "https://")) 8 else 7;
            const host_start = url_start + scheme_len;
            const rest = line[host_start..];
            const host_end = std.mem.indexOfAny(u8, rest, "/\"' \t:)}") orelse rest.len;
            const host = rest[0..host_end];
            if (host.len > 0 and !std.mem.eql(u8, host, "localhost") and !seen_hosts.contains(host)) {
                try seen_hosts.put(arena, try arena.dupe(u8, host), {});
                report.external_integrations += 1;
                try addEvidence(allocator, evidence, "external_endpoint", path, "new URL host (review whether partner integration)");
            }
        }
        if (containsAny(line, &.{ "crypto", "Crypto", "cipher", "Cipher", "encrypt", "decrypt", "signature", "hmac", "HMAC" })) crypto_found = true;
        if (containsAny(line, &.{ "algorithm", "Algorithm", "state machine", "binarySearch", "dijkstra", "quicksort", "dynamic programming" })) algorithm_found = true;
    }
    if (crypto_found) {
        report.crypto_signals += 1;
        try addEvidence(allocator, evidence, "crypto", path, "keyword signal; reviewer confirmation required");
    }
    if (algorithm_found) {
        report.algorithm_signals += 1;
        try addEvidence(allocator, evidence, "algorithm", path, "keyword signal; reviewer confirmation required");
    }
}

pub fn build(store: *const objects.ObjectStore, allocator: std.mem.Allocator, base_name: []const u8, base_oid: object_id.ObjectId, to_name: []const u8, to_oid: object_id.ObjectId) !Report {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var before: FileMap = .empty;
    var after: FileMap = .empty;
    try collect(store, a, try commitTree(store, a, base_oid), "", &before);
    try collect(store, a, try commitTree(store, a, to_oid), "", &after);
    var report: Report = .{ .base = base_name, .to = to_name, .base_commit = base_oid, .to_commit = to_oid };
    var evidence: std.ArrayList(Report.Evidence) = .empty;
    errdefer {
        for (evidence.items) |item| allocator.free(item.path);
        evidence.deinit(allocator);
    }
    var seen_imports: std.StringHashMapUnmanaged(void) = .empty;
    var seen_hosts: std.StringHashMapUnmanaged(void) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        var it = if (pass == 0) before.iterator() else after.iterator();
        while (it.next()) |item| {
            const path = item.key_ptr.*;
            if (seen.contains(path)) continue;
            try seen.put(a, path, {});
            const old_oid = before.get(path);
            const new_oid = after.get(path);
            if (old_oid != null and new_oid != null and old_oid.?.eql(&new_oid.?)) continue;
            report.files += 1;
            if (dependencyManifest(path)) {
                report.dependency_changes += 1;
                try addEvidence(allocator, &evidence, "dependency_manifest", path, "manifest changed; new dependency not confirmed");
            }
            if (uiComponent(path)) {
                if (old_oid == null) {
                    report.new_ui_components += 1;
                    try addEvidence(allocator, &evidence, "new_ui_component", path, "new component file");
                } else {
                    report.changed_shared_ui_components += 1;
                    try addEvidence(allocator, &evidence, "shared_ui_component", path, "component file changed; consumer reach unknown");
                }
            }
            if (!source(path) or excluded(path)) {
                report.excluded_files += 1;
                continue;
            }
            var scratch = std.heap.ArenaAllocator.init(allocator);
            defer scratch.deinit();
            const sa = scratch.allocator();
            const old_data = if (old_oid) |id| try store.readPayload(sa, &id) else null;
            defer if (old_data) |p| p.release();
            const new_data = if (new_oid) |id| try store.readPayload(sa, &id) else null;
            defer if (new_data) |p| p.release();
            const old_text: []const u8 = if (old_data) |p| p.data else "";
            const new_text: []const u8 = if (new_data) |p| p.data else "";
            if (std.mem.indexOfScalar(u8, old_text, 0) != null or std.mem.indexOfScalar(u8, new_text, 0) != null) {
                report.binary_files += 1;
                continue;
            }
            const counts = try compareLines(sa, old_text, new_text);
            report.added_lines += counts.added;
            report.removed_lines += counts.removed;
            report.added_branches += counts.branches;
            if (domain.isTerraform(path) or domain.isSql(path)) {
                const old_domain = try domain.scan(sa, path, old_text);
                const new_domain = try domain.scan(sa, path, new_text);
                const added_domain = domain.Counts.added(new_domain, old_domain);
                report.domain_counts.add(added_domain);
                if (added_domain.points() > 0) try addEvidence(allocator, &evidence, if (domain.isTerraform(path)) "terraform" else "sql", path, "new observable infrastructure/database constructs");
            } else {
                try scanSignals(a, allocator, old_text, new_text, path, &report, &evidence, &seen_imports, &seen_hosts);
            }
        }
    }
    report.work_points = report.added_lines + report.removed_lines + 4 * report.added_branches + 3 * (report.files - report.excluded_files - report.binary_files);
    report.complexity_points = 6 * report.internal_imports + 12 * report.external_integrations + 4 * report.dependency_changes + 6 * report.new_ui_components + 6 * report.changed_shared_ui_components + 10 * report.crypto_signals + 8 * report.algorithm_signals;
    report.domain_points = report.domain_counts.points();
    report.complexity_points += report.domain_points;
    report.total_points = report.work_points + report.complexity_points;
    report.evidence = try evidence.toOwnedSlice(allocator);
    return report;
}

test "line multiset and branch proxy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try compareLines(arena.allocator(), "same\nold\n", "same\nif ready\n");
    try std.testing.expectEqual(@as(u64, 1), c.added);
    try std.testing.expectEqual(@as(u64, 1), c.removed);
    try std.testing.expectEqual(@as(u64, 1), c.branches);
}

test "observable signals are reported separately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Report = .{ .base = "a", .to = "b", .base_commit = undefined, .to_commit = undefined };
    var evidence: std.ArrayList(Report.Evidence) = .empty;
    defer {
        for (evidence.items) |item| std.testing.allocator.free(item.path);
        evidence.deinit(std.testing.allocator);
    }
    var imports: std.StringHashMapUnmanaged(void) = .empty;
    var hosts: std.StringHashMapUnmanaged(void) = .empty;
    try scanSignals(a, std.testing.allocator, "", "import X from './components/X';\nconst api = 'https://partner.example/v1';\nencrypt(data);\n", "src/App.tsx", &report, &evidence, &imports, &hosts);
    try std.testing.expectEqual(@as(u64, 1), report.internal_imports);
    try std.testing.expectEqual(@as(u64, 1), report.external_integrations);
    try std.testing.expectEqual(@as(u64, 1), report.reused_ui_components);
    try std.testing.expectEqual(@as(u64, 1), report.crypto_signals);
    try std.testing.expectEqual(@as(usize, 4), evidence.items.len);
}
