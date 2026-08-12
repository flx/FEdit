//
//  TreeSkipGate.swift
//  FEdit
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

import Foundation

/// (watcher-scan-skip-parity) The FSEvents skip gate: given a changed path's components **below** a
/// watched root, would a rescan of that root ignore it? A dependency-free, UI-free namespace of pure
/// static functions — no filesystem access, no main-actor state, no `stat`.
///
/// **Why it is a separate file and not a `WorkspaceModel` method.** It runs per changed path inside
/// an FSEvents burst (thousands of paths for one `npm install` or `git checkout`) under two hard
/// constraints:
///
/// - **No syscall per path.** A `stat` here would pay realpath/attribute cost on every path in a
///   burst the gate is about to discard anyway. That is why the scanner *records* its verdicts
///   (`SkipRecord`, produced where the syscalls already happen) and this gate merely reads them.
/// - **An allocation budget, and it is a stated invariant rather than an implementation detail.**
///   The two static rules run **first**, over `Substring` components, materializing no `String` at
///   all — and they drop the overwhelming mass of a real burst (`.git/**` writes at the dot rule,
///   `node_modules`/`DerivedData` interiors at the skip-name rule). Only what survives both reaches
///   the record consult, and only when a record exists and is non-empty; its cost is then at most
///   depth-many `String` builds for the ancestor prefixes it has to look up. **Do not reorder these
///   steps** — putting the record consult first would pay those builds for every `.git` write. The
///   same invariant binds the **caller**: `record` is an argument, so anything expensive written in
///   its place is evaluated before the statics ever run. `WorkspaceModel.handleTreeChange` therefore
///   resolves each root's record **once per batch** into the pairs it hands to `isSkippedTreePath`,
///   rather than looking it up per path.
///
/// `WorkspaceModel` imports AppKit, so a gate living there could never be assertion-pinned; here it
/// is, by `scripts/TreeSkipGateTests`.
///
/// **Parity, and where it is exact.** The scanner (`FileNode.scanRecordingSkips`) owns one skip
/// predicate and this gate consults it, so the two cannot drift by re-derivation. The dot rule below
/// is exact *by construction*, not by assumption: the scanner's predicate carries a deliberate
/// `name.hasPrefix(".")` belt, so "dot ⟹ the scanner skipped it" holds on any volume. The remaining
/// rules are conservative in a **stated direction** — see `isSkipped(belowRootComponents:record:)`.
enum TreeSkipGate {
    /// The components of `path` below `rootPath`, the gate's input — split on `/`, so repeated or
    /// trailing separators collapse and no empty component is ever produced.
    ///
    /// **Precondition:** `FileNode.path(path, isContainedIn: rootPath)`. The caller establishes it
    /// (a path outside every root is dropped before reaching here), and it is what makes dropping
    /// `rootPath.count` leading characters exact.
    ///
    /// The `"/"` root is why this is a function and not an inlined idiom: `dropFirst` leaves a
    /// leading `"/"` under every other root and none under `"/"`, and `split` maps both shapes to the
    /// same components — so the `"//"` class that (root-slash-prefix-match) fixed in the containment
    /// test cannot reappear here. `path == rootPath` (an event naming the root itself) yields `[]`.
    static func belowRootComponents(of path: String, root rootPath: String) -> [Substring] {
        path.dropFirst(rootPath.count).split(separator: "/")
    }

    /// Whether a rescan of the containing root would ignore the changed path these components name.
    ///
    /// `record` is the containing root's last **applied** walk's verdicts, or `nil` when no walk has
    /// delivered any yet (a root still on its first scan, or one just re-added) — in which case only
    /// the two static rules apply, exactly as before this item.
    ///
    /// The rules, in the order the allocation budget requires:
    ///
    /// 1. Any component starting with `"."` ⟹ skipped. Exact against the scanner by construction.
    /// 2. Any **intermediate** component in `FileNode.skippedDirectoryNames` ⟹ skipped.
    /// 3. Any **intermediate** component recorded as skipped at its own position (`skippedIndex`)
    ///    ⟹ skipped.
    /// 4. Otherwise not skipped: rescan.
    ///
    /// **Why rules 2 and 3 stop short of the final component**, and why that is the whole design
    /// rather than an omission:
    ///
    /// - *Rule 2* — an intermediate component is provably a directory (something lives under it); a
    ///   final one may be a plain **file** named `node_modules`, which the scanner keeps. Dropping
    ///   its events would mean a genuine change to that file never auto-refreshes.
    /// - *Rule 3* — a final component's *current* state is unknowable here, and the record is by
    ///   definition as old as the last walk. A stale index hit on a final component would drop the
    ///   very event — the `chflags nohidden`, the delete-and-recreate — whose rescan would refresh
    ///   the record: a **self-perpetuating skip**. With the final component always falling through,
    ///   the toggle event on the entry itself triggers the rescan that un-sticks everything beneath
    ///   it. That un-stick is not a hope: a `chflags` toggle on a directory *does* deliver an event
    ///   naming that directory (probe-verified 2026-08-11), which is exactly what rule 3 relies on.
    ///
    /// **`SkipRecord.unreadableDirs` is deliberately NOT consulted here.** It is recorded (for
    /// observability, and for future per-root scan-outcome reporting) but never gates, because the
    /// un-stick argument above has no analogue for *readability*: a probe on 2026-08-11 established
    /// that granting access (a TCC grant) fires **no filesystem event at all**, and that creating or
    /// writing anything inside a directory never delivers that directory's own path — only the
    /// interior path. So no event can ever name a recovered directory, and a recorded-unreadable
    /// entry consulted here would become a **permanent** auto-refresh black hole for its whole
    /// subtree — worst case the key `""`, a TCC-denied root, i.e. the entire root going dead until
    /// relaunch. Before this item there was no record and such subtrees self-healed; they still do.
    /// The cost of not consulting it is that events under an unreadable subtree keep requesting
    /// rescans that surface nothing — bounded by `RootScanScheduler`'s damping, and the deliberate
    /// price of automatic recovery.
    ///
    /// Recorded residual: if that single un-sticking event is lost (FSEvents coalescing or overflow),
    /// staleness persists until the next event naming that entry, an explicit Refresh, or a relaunch.
    /// `RootScanScheduler`'s damping is **not** a safety net for any of this — it defers requests, it
    /// cannot manufacture one this gate never made.
    static func isSkipped(belowRootComponents components: [Substring], record: SkipRecord?) -> Bool {
        // An event naming the watched root itself. Never skipped: it is one of the two ways a stale
        // record gets refreshed (the other is an event naming a recorded entry directly), and there
        // is nothing here to test anyway.
        guard !components.isEmpty else { return false }

        let lastIndex = components.count - 1

        // Statics first, on `Substring`s. `contains(where:)` over the three-name set rather than
        // `contains(String(component))`: heterogeneous `String`/`Substring` comparison is the same
        // canonical-equivalence test a `Set` lookup would run, without materializing a `String` per
        // component. This loop is what the overwhelming mass of a real burst dies in.
        for index in 0...lastIndex {
            let component = components[index]
            if component.hasPrefix(".") { return true }
            if index < lastIndex, FileNode.skippedDirectoryNames.contains(where: { $0 == component }) {
                return true
            }
        }

        // Past the statics: consult the walk's own skip index, if there is one to consult. Both
        // early-outs matter — `nil` is "no walk has landed for this root", and an empty index is the
        // common steady state (nothing non-dot skipped), so neither should pay for the prefix builds
        // below. `unreadableDirs` is not part of this test, by the doc's argument above.
        guard let record, !record.skippedIndex.isEmpty else {
            return false
        }

        // `ancestor` walks the proper ancestors of the changed path, in the record's own key form:
        // the path relative to the root, `""` for the root itself. One `String` build per level, and
        // the same build feeds both the index lookup and the next prefix.
        var ancestor = ""
        for index in 0..<lastIndex {
            let name = String(components[index])
            if record.skippedIndex[ancestor]?.contains(name) == true { return true }
            ancestor = ancestor.isEmpty ? name : ancestor + "/" + name
        }
        return false
    }
}
