//
//  main.swift
//  FilterRowCacheTests
//
//  Copyright © 2026 Felix Matschke
//
//  This file is part of FEdit.
//
//  FEdit is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your
//  option) any later version.
//
//  FEdit is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
//  for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with FEdit. If not, see <https://www.gnu.org/licenses/>.
//
//  Standalone assertion harness for `FilterRowCache` (filter-walk-main-thread Tier 1). Not part of
//  the app target — compiled and run manually:
//
//      swiftc FEdit/Models/FileNode.swift FEdit/Models/FilterQuery.swift \
//             FEdit/Models/FilterRowCache.swift scripts/FilterRowCacheTests/main.swift \
//             -o /tmp/frctests && /tmp/frctests
//
//  Named `main.swift` because Swift only allows top-level statements in a file with that exact
//  name when compiling multiple files together.
//
//  Touches no filesystem: `FileNode` is a value type, so trees are built in memory and are
//  deterministic, which is what makes the differential sweep below reproducible.
//

import Foundation

// MARK: - Tiny test harness

var failureCount = 0

func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        print("  PASS: \(message)")
    } else {
        failureCount += 1
        print("  FAIL: \(message) (\(file):\(line))")
    }
}

func section(_ title: String) {
    print("\n== \(title) ==")
}

// MARK: - Fixtures

/// A deterministic linear-congruential generator, so a failure here is always reproducible (a
/// `SystemRandomNumberGenerator` sweep would be a different tree set on every run).
final class Rng {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

/// Builds an in-memory `FileNode` tree of pseudo-random shape rooted at `rootURL`: directories
/// before files at every level (the scanner's own folders-first order, so `filesWithRelativePaths`
/// yields realistic DFS output), file names carrying one of three extensions so the query set below
/// has something to discriminate on.
func generateTree(seed: UInt64, rootURL: URL, maxDepth: Int) -> FileNode {
    let rng = Rng(seed: seed)

    func build(url: URL, name: String, depth: Int) -> FileNode {
        var directories: [FileNode] = []
        var files: [FileNode] = []

        let directoryCount = depth >= maxDepth ? 0 : rng.next(3)
        let fileCount = rng.next(4)

        for index in 0..<directoryCount {
            let childName = "dir\(index)"
            directories.append(build(url: url.appendingPathComponent(childName), name: childName, depth: depth + 1))
        }
        for index in 0..<fileCount {
            let ext = ["swift", "md", "txt"][rng.next(3)]
            let childName = "file\(index).\(ext)"
            files.append(FileNode(url: url.appendingPathComponent(childName), name: childName, isDirectory: false, children: nil))
        }

        return FileNode(url: url, name: name, isDirectory: true, children: directories + files)
    }

    return build(url: rootURL, name: rootURL.lastPathComponent, depth: 0)
}

/// The mutation standing in for "a scan landed and spliced a structurally different tree in": one
/// extra top-level file with a name no generated tree can produce. Its presence/absence in a cached
/// result is what separates "the cache re-walked" from "the cache served pre-splice rows".
let markerName = "zzmarker.swift"

func mutated(_ tree: FileNode) -> FileNode {
    let marker = FileNode(
        url: tree.url.appendingPathComponent(markerName),
        name: markerName,
        isDirectory: false,
        children: nil
    )
    return FileNode(url: tree.url, name: tree.name, isDirectory: true, children: (tree.children ?? []) + [marker])
}

/// The reference implementation — literally the inline expression `SidebarView.flatRows` used
/// before this item, so every parity assertion below compares the cache against the behavior it
/// replaced rather than against a re-derivation of itself.
func referenceRows(_ tree: FileNode, _ query: FilterQuery) -> [FilterRowCache.Match] {
    tree.filesWithRelativePaths()
        .filter { query.matches($0.path) }
        .map { FilterRowCache.Match(path: $0.path, node: $0.node) }
}

/// Counts provider invocations. A class box rather than a captured local so the count is
/// unambiguously shared with the closure handed to the cache.
final class ProviderCounter {
    private(set) var count = 0

    func note() {
        count += 1
    }
}

let rootA = URL(fileURLWithPath: "/tmp/FilterRowCacheTests/rootA")
let rootB = URL(fileURLWithPath: "/tmp/FilterRowCacheTests/rootB")

let treeA = generateTree(seed: 1, rootURL: rootA, maxDepth: 3)
let treeB = generateTree(seed: 99, rootURL: rootB, maxDepth: 3)

let swiftQuery = FilterQuery(".swift")
let mdQuery = FilterQuery(".md")
let noMatchQuery = FilterQuery("qqqqnothingmatchesthis")

section("Fixture sanity (non-vacuity of everything below)")
check(!treeA.filesWithRelativePaths().isEmpty, "generated tree A is non-empty (\(treeA.filesWithRelativePaths().count) files)")
check(!treeB.filesWithRelativePaths().isEmpty, "generated tree B is non-empty (\(treeB.filesWithRelativePaths().count) files)")
// Tree B's rows are compared with a `.txt` query below (its generated files are .txt-heavy and
// may contain zero .swift matches) — guard that the comparison is non-vacuous.
let txtQuery = FilterQuery(".txt")
check(!referenceRows(treeB, txtQuery).isEmpty, "tree B has at least one .txt match to compare")
check(!referenceRows(treeA, swiftQuery).isEmpty, "tree A has at least one .swift match to compare")
check(!referenceRows(treeA, mdQuery).isEmpty, "tree A has at least one .md match to compare")
check(
    referenceRows(treeA, swiftQuery) != referenceRows(treeA, mdQuery),
    "the two probe queries select genuinely different row sets on tree A"
)

// MARK: - Criterion 1 (type level): the provider runs only on a tree miss

section("Tree miss runs the provider exactly once and returns the filtered rows")
var cache = FilterRowCache()
let counter = ProviderCounter()

func rowsA(_ query: FilterQuery, tree: FileNode = treeA) -> [FilterRowCache.Match] {
    cache.rows(for: rootA, query: query) {
        counter.note()
        return tree.filesWithRelativePaths().map { FilterRowCache.Match(path: $0.path, node: $0.node) }
    }
}

let firstResult = rowsA(swiftQuery)
check(counter.count == 1, "first lookup (no entry) ran the provider once, got \(counter.count)")
check(firstResult == referenceRows(treeA, swiftQuery), "tree-miss rows equal the inline reference, order included")

section("Hit: same parsed query never re-runs the provider")
let hitResult = rowsA(swiftQuery)
check(counter.count == 1, "repeat lookup with the same query did NOT run the provider, count still \(counter.count)")
check(hitResult == firstResult, "hit returns the identical rows")
_ = rowsA(swiftQuery)
_ = rowsA(swiftQuery)
check(counter.count == 1, "two further hits still ran no provider, count still \(counter.count)")

section("Value keying: equal parses hit even from different text")
// Pin `FilterQuery: Equatable` directly first — the provider counts below cannot distinguish a
// hit from a query-miss refilter (neither runs the provider), but these can distinguish value
// keying from text keying.
check(FilterQuery("   .swift   ") == swiftQuery, "whitespace-padded text parses == the plain query")
check(FilterQuery(".swift OR") == swiftQuery, "trailing-operator text parses == the plain query")
check(FilterQuery(".swift") != mdQuery, "different queries parse != (Equatable is not degenerate)")
let paddedResult = rowsA(FilterQuery("   .swift   "))
check(counter.count == 1, "whitespace-padded text parsing equal is a HIT, count still \(counter.count)")
check(paddedResult == firstResult, "whitespace-padded query returns the same rows")
let danglingResult = rowsA(FilterQuery(".swift OR"))
check(counter.count == 1, "trailing-operator text parsing equal is a HIT, count still \(counter.count)")
check(danglingResult == firstResult, "trailing-operator query returns the same rows")

section("Query miss: a different query refilters WITHOUT re-running the provider")
let mdResult = rowsA(mdQuery)
check(counter.count == 1, "query change did NOT run the provider, count still \(counter.count)")
check(mdResult == referenceRows(treeA, mdQuery), "refiltered rows equal the inline reference for the new query")
let backResult = rowsA(swiftQuery)
check(counter.count == 1, "switching back to the first query still ran no provider, count still \(counter.count)")
check(backResult == firstResult, "switching back yields the original rows")
let emptyResult = rowsA(noMatchQuery)
check(counter.count == 1, "a query matching nothing still ran no provider, count still \(counter.count)")
check(emptyResult.isEmpty, "a query matching nothing yields zero rows")
check(emptyResult == referenceRows(treeA, noMatchQuery), "the empty result equals the inline reference")

// MARK: - Criterion 2 (type level): invalidation

section("Without invalidate, a changed tree is NOT re-walked (the contract the splice-branch placement rests on)")
let treeAPlusMarker = mutated(treeA)
check(
    referenceRows(treeAPlusMarker, swiftQuery).contains { $0.path == markerName },
    "the mutated tree really does add a new matching row"
)
let staleResult = rowsA(swiftQuery, tree: treeAPlusMarker)
check(counter.count == 1, "a lookup after a tree change with no invalidate ran no provider, count still \(counter.count)")
check(!staleResult.contains { $0.path == markerName }, "the pre-splice rows are served — the cache is genuinely holding")

section("invalidate drops the entry: the next lookup re-walks and serves the new tree")
cache.invalidate(rootA)
let afterInvalidate = rowsA(swiftQuery, tree: treeAPlusMarker)
check(counter.count == 2, "invalidate forced exactly one further provider run, got \(counter.count)")
check(afterInvalidate.contains { $0.path == markerName }, "hit-after-invalidate serves the post-splice rows")
check(afterInvalidate == referenceRows(treeAPlusMarker, swiftQuery), "post-invalidate rows equal the inline reference for the new tree")
let hitAfterInvalidate = rowsA(swiftQuery, tree: treeAPlusMarker)
check(counter.count == 2, "the entry rebuilt by invalidate caches again (no third provider run), count \(counter.count)")
check(hitAfterInvalidate == afterInvalidate, "hit-after-invalidate is stable across repeats")

section("invalidate is scoped and total")
cache.invalidate(URL(fileURLWithPath: "/tmp/FilterRowCacheTests/not-a-root"))
_ = rowsA(swiftQuery, tree: treeAPlusMarker)
check(counter.count == 2, "invalidating an unrelated URL left this entry intact, count still \(counter.count)")
var emptyCache = FilterRowCache()
emptyCache.invalidate(rootA)
let emptyCacheCounter = ProviderCounter()
let afterNoopInvalidate = emptyCache.rows(for: rootA, query: swiftQuery) {
    emptyCacheCounter.note()
    return treeA.filesWithRelativePaths().map { FilterRowCache.Match(path: $0.path, node: $0.node) }
}
check(emptyCacheCounter.count == 1 && afterNoopInvalidate == referenceRows(treeA, swiftQuery),
      "invalidate on a URL with no entry is a no-op: the cache then populates normally")
let queryAfterInvalidateOfOther = rowsA(mdQuery, tree: treeAPlusMarker)
check(counter.count == 2, "a query change after the unrelated invalidate still ran no provider, count \(counter.count)")
check(
    queryAfterInvalidateOfOther == referenceRows(treeAPlusMarker, mdQuery),
    "that refilter used the POST-splice flat list, not the pre-splice one"
)

// MARK: - Multi-root independence

section("Entries are per-root")
var multiCache = FilterRowCache()
let counterA = ProviderCounter()
let counterB = ProviderCounter()

func multiRows(_ url: URL, _ tree: FileNode, _ counter: ProviderCounter, _ query: FilterQuery) -> [FilterRowCache.Match] {
    multiCache.rows(for: url, query: query) {
        counter.note()
        return tree.filesWithRelativePaths().map { FilterRowCache.Match(path: $0.path, node: $0.node) }
    }
}

let multiA = multiRows(rootA, treeA, counterA, swiftQuery)
// Root B is queried with `.txt` (fixture-guarded non-empty above) so its parity check compares
// real rows — a `.swift` query on tree B can select zero rows, making the `==` vacuous.
let multiB = multiRows(rootB, treeB, counterB, txtQuery)
check(counterA.count == 1 && counterB.count == 1, "each root ran its own provider once (\(counterA.count), \(counterB.count))")
check(multiA == referenceRows(treeA, swiftQuery), "root A's rows equal its own reference")
check(multiB == referenceRows(treeB, txtQuery), "root B's rows equal its own (non-empty) reference")
multiCache.invalidate(rootA)
_ = multiRows(rootB, treeB, counterB, txtQuery)
check(counterB.count == 1, "invalidating root A did not disturb root B's entry, count still \(counterB.count)")
_ = multiRows(rootA, treeA, counterA, swiftQuery)
check(counterA.count == 2, "invalidating root A did drop root A's entry, count \(counterA.count)")

// MARK: - releaseAll

section("releaseAll empties everything")
multiCache.releaseAll()
_ = multiRows(rootA, treeA, counterA, swiftQuery)
check(counterA.count == 3, "releaseAll dropped root A's entry, count \(counterA.count)")
_ = multiRows(rootB, treeB, counterB, swiftQuery)
check(counterB.count == 2, "releaseAll dropped root B's entry too, count \(counterB.count)")
_ = multiRows(rootA, treeA, counterA, swiftQuery)
check(counterA.count == 3, "the cache repopulates normally after releaseAll, count still \(counterA.count)")
var releaseOnEmpty = FilterRowCache()
releaseOnEmpty.releaseAll()
let releaseOnEmptyCounter = ProviderCounter()
let afterNoopRelease = releaseOnEmpty.rows(for: rootA, query: swiftQuery) {
    releaseOnEmptyCounter.note()
    return treeA.filesWithRelativePaths().map { FilterRowCache.Match(path: $0.path, node: $0.node) }
}
check(releaseOnEmptyCounter.count == 1 && afterNoopRelease == referenceRows(treeA, swiftQuery),
      "releaseAll on an empty cache is a no-op: the cache then populates normally")

// MARK: - Criterion 3: differential parity over several trees × several queries

section("Order sensitivity of the parity comparison (non-vacuity of every `==` above)")
let orderProbe = referenceRows(treeA, swiftQuery)
check(orderProbe.count > 1, "the order probe has at least two rows to reorder (\(orderProbe.count))")
check(Array(orderProbe.reversed()) != orderProbe, "a reordered row list compares UNEQUAL — parity checks really do pin order")

let sweepQueries: [(String, FilterQuery)] = [
    (".swift", FilterQuery(".swift")),
    (".md OR .txt", FilterQuery(".md OR .txt")),
    ("dir1 AND .swift", FilterQuery("dir1 AND .swift")),
    ("^dir0/", FilterQuery("^dir0/")),
    (".swift$", FilterQuery(".swift$")),
    ("qqqqnothingmatchesthis", FilterQuery("qqqqnothingmatchesthis")),
]

var sweepMatchedRows = 0

section("Differential parity: generated trees × queries, fresh cache then refilter sequence")
for seed in [7, 13, 21, 42] as [UInt64] {
    let url = URL(fileURLWithPath: "/tmp/FilterRowCacheTests/sweep-\(seed)")
    let tree = generateTree(seed: seed, rootURL: url, maxDepth: 4)
    let sweepCounter = ProviderCounter()
    var sweepCache = FilterRowCache()

    // One cache across the whole query loop: the first query is a tree miss, every later one is a
    // query miss, so this pins refilter-after-query-change parity, not just first-fill parity.
    for (label, query) in sweepQueries {
        let cached = sweepCache.rows(for: url, query: query) {
            sweepCounter.note()
            return tree.filesWithRelativePaths().map { FilterRowCache.Match(path: $0.path, node: $0.node) }
        }
        let expected = referenceRows(tree, query)
        sweepMatchedRows += expected.count
        check(cached == expected, "seed \(seed), query \"\(label)\": \(expected.count) cached rows ≡ inline reference")
    }
    check(sweepCounter.count == 1, "seed \(seed): the whole \(sweepQueries.count)-query sweep ran ONE provider call, got \(sweepCounter.count)")

    // Splice, then invalidate: every query must now agree with the reference over the NEW tree.
    let spliced = mutated(tree)
    sweepCache.invalidate(url)
    for (label, query) in sweepQueries {
        let cached = sweepCache.rows(for: url, query: query) {
            sweepCounter.note()
            return spliced.filesWithRelativePaths().map { FilterRowCache.Match(path: $0.path, node: $0.node) }
        }
        check(cached == referenceRows(spliced, query), "seed \(seed), query \"\(label)\" after invalidate: rows ≡ post-splice reference")
    }
    check(sweepCounter.count == 2, "seed \(seed): the post-invalidate sweep ran exactly one more provider call, got \(sweepCounter.count)")
}

section("The differential sweep compared real rows, not empty arrays")
check(sweepMatchedRows > 0, "the sweep's expected results total \(sweepMatchedRows) rows across all trees × queries")

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
