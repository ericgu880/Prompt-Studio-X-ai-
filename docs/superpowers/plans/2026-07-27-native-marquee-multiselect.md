# Native Marquee Multi-Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Finder-style marquee selection, Command + Backspace batch trash, and whole-selection drag-to-folder behavior to PromptStudio's active native masonry grid.

**Architecture:** Keep `AppState.selectedIDs` as the only selection state. Put deterministic rectangle/selection, drag-payload, and batch-move planning logic in `PromptStudioCore`; keep AppKit mouse capture and drawing in a focused `NativeMarqueeCollectionView`; use the existing masonry layout for hit testing and one versioned internal payload for all native and hosted card types.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit `NSCollectionView`, Uniform Type Identifiers, SQLite through `PromptRepository`, SwiftPM executable tests, shell UI regression checks.

---

## File Map

- Create `Sources/PromptStudioCore/MarqueeSelectionResolver.swift`
  - Pure rectangle normalization and selection-set resolution.
- Create `Sources/PromptStudioCore/PromptItemDragPayload.swift`
  - Versioned, order-preserving multi-item drag payload.
- Create `Sources/PromptStudioCore/PromptItemBatchMovePlanner.swift`
  - Deterministic validation and model updates for a batch folder move.
- Create `Sources/PromptStudio/Views/NativeMarqueeCollectionView.swift`
  - AppKit mouse tracking, selection overlay, Escape cancellation, and edge auto-scroll.
- Modify `Sources/PromptStudio/Views/PromptStudioView.swift`
  - Wire marquee callbacks to the masonry coordinator, generate group drag payloads for every card type, and decode group drops in sidebar folders.
- Modify `Sources/PromptStudio/AppState.swift`
  - Prepare ordered drag IDs and execute one transactional batch move with one refresh and one Toast.
- Modify `Sources/PromptStudioCoreUnitTests/main.swift`
  - Executable assertions for pure marquee, payload, and batch-move semantics.
- Modify `Tests/PromptStudioCoreTests/PromptStudioCoreTests.swift`
  - Compile-time coverage that the new core public APIs remain available to the SwiftPM test target.
- Create `scripts/test_native_marquee_multiselect.sh`
  - Source-level regression contract for native-grid wiring, private payload usage, batch drop, and shortcut safety.
- Modify `scripts/test_release_ui_copy.sh`
  - Invoke the focused marquee regression check as part of the established release UI gate.

## Task 1: Add Pure Marquee Selection and Drag Payload Primitives

**Files:**
- Create: `Sources/PromptStudioCore/MarqueeSelectionResolver.swift`
- Create: `Sources/PromptStudioCore/PromptItemDragPayload.swift`
- Modify: `Sources/PromptStudioCoreUnitTests/main.swift`
- Modify: `Tests/PromptStudioCoreTests/PromptStudioCoreTests.swift`

- [ ] **Step 1: Add failing executable assertions**

Add the following test functions before the final `do` block in `Sources/PromptStudioCoreUnitTests/main.swift`:

```swift
func testMarqueeSelectionResolver() throws {
    let rect = MarqueeSelectionResolver.normalizedRect(
        from: CGPoint(x: 100, y: 80),
        to: CGPoint(x: 20, y: 10)
    )
    try expect(rect == CGRect(x: 20, y: 10, width: 80, height: 70), "marquee rect should normalize every drag direction")

    let frames = [
        "image": CGRect(x: 0, y: 0, width: 40, height: 40),
        "markdown": CGRect(x: 39, y: 39, width: 40, height: 40),
        "outside": CGRect(x: 100, y: 100, width: 20, height: 20)
    ]
    let hitIDs = MarqueeSelectionResolver.hitIDs(
        in: CGRect(x: 20, y: 20, width: 20, height: 20),
        itemFrames: frames
    )
    try expect(hitIDs == Set(["image", "markdown"]), "marquee should select every intersecting card")
    try expect(
        MarqueeSelectionResolver.selection(base: ["existing"], hits: hitIDs, additive: false) == hitIDs,
        "plain marquee should replace the old selection"
    )
    try expect(
        MarqueeSelectionResolver.selection(base: ["existing"], hits: hitIDs, additive: true) == Set(["existing", "image", "markdown"]),
        "Command marquee should add to the old selection"
    )
}

func testPromptItemDragPayload() throws {
    let payload = PromptItemDragPayload(itemIDs: ["b", "a", "b", "c"])
    try expect(payload.itemIDs == ["b", "a", "c"], "drag payload should deduplicate IDs while preserving order")
    let decoded = try PromptItemDragPayload.decode(payload.encoded())
    try expect(decoded == payload, "drag payload should round-trip")
    try expect(
        PromptItemDragPayload.pasteboardTypeIdentifier == "com.promptstudio.internal.prompt-item-ids",
        "drag payload type must remain stable"
    )
}
```

Call both functions from the final test runner:

```swift
try testMarqueeSelectionResolver()
try testPromptItemDragPayload()
```

Add one API-availability expression to `promptStudioCoreTestsTargetLoads()`:

```swift
&& PromptItemDragPayload(itemIDs: ["one", "one"]).itemIDs == ["one"]
```

- [ ] **Step 2: Run the core test executable and verify it fails**

Run:

```bash
swift run PromptStudioCoreUnitTests
```

Expected: compilation fails because `MarqueeSelectionResolver` and `PromptItemDragPayload` do not exist.

- [ ] **Step 3: Implement the pure primitives**

Create `Sources/PromptStudioCore/MarqueeSelectionResolver.swift`:

```swift
import CoreGraphics

public enum MarqueeSelectionResolver {
    public static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public static func hitIDs(
        in selectionRect: CGRect,
        itemFrames: [String: CGRect]
    ) -> Set<String> {
        Set(itemFrames.compactMap { id, frame in
            frame.intersects(selectionRect) ? id : nil
        })
    }

    public static func selection(
        base: Set<String>,
        hits: Set<String>,
        additive: Bool
    ) -> Set<String> {
        additive ? base.union(hits) : hits
    }
}
```

Create `Sources/PromptStudioCore/PromptItemDragPayload.swift`:

```swift
import Foundation

public struct PromptItemDragPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let pasteboardTypeIdentifier = "com.promptstudio.internal.prompt-item-ids"

    public let version: Int
    public let itemIDs: [String]

    public init(itemIDs: [String]) {
        version = Self.currentVersion
        var seen = Set<String>()
        self.itemIDs = itemIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        let payload = try JSONDecoder().decode(Self.self, from: data)
        guard payload.version == currentVersion else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unsupported PromptStudio drag payload version")
            )
        }
        return PromptItemDragPayload(itemIDs: payload.itemIDs)
    }
}
```

- [ ] **Step 4: Run core tests**

Run:

```bash
swift run PromptStudioCoreUnitTests
swift test
```

Expected: `PromptStudioCoreUnitTests passed`; SwiftPM test target builds and passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/PromptStudioCore/MarqueeSelectionResolver.swift Sources/PromptStudioCore/PromptItemDragPayload.swift Sources/PromptStudioCoreUnitTests/main.swift Tests/PromptStudioCoreTests/PromptStudioCoreTests.swift
git commit -m "Add marquee selection and drag payload primitives"
```

## Task 2: Add Transactional Batch-Move Planning

**Files:**
- Create: `Sources/PromptStudioCore/PromptItemBatchMovePlanner.swift`
- Modify: `Sources/PromptStudioCoreUnitTests/main.swift`
- Modify: `Sources/PromptStudio/AppState.swift`

- [ ] **Step 1: Add failing batch-move planner assertions**

Add this function to `Sources/PromptStudioCoreUnitTests/main.swift`:

```swift
func testPromptItemBatchMovePlanner() throws {
    var first = sampleItem(title: "First", prompt: "first")
    first.id = "first"
    first.folderId = "source"
    first.folderName = "Source"

    var alreadyThere = sampleItem(title: "Already", prompt: "already")
    alreadyThere.id = "already"
    alreadyThere.folderId = "target"
    alreadyThere.folderName = "Target"

    var deleted = sampleItem(title: "Deleted", prompt: "deleted")
    deleted.id = "deleted"
    deleted.folderId = "source"
    deleted.deletedAt = Date()

    let plan = PromptItemBatchMovePlanner.plan(
        items: [first, alreadyThere, deleted],
        requestedIDs: ["missing", "already", "first", "deleted", "first"],
        targetFolderID: "target",
        targetFolderName: "Target",
        updatedAt: Date(timeIntervalSince1970: 100)
    )

    try expect(plan.updatedItems.map(\.id) == ["first"], "only valid resources outside the target folder should move")
    try expect(plan.updatedItems[0].folderId == "target", "moved resource should receive the target folder ID")
    try expect(plan.updatedItems[0].folderName == "Target", "moved resource should receive the target folder name")
    try expect(plan.unchangedIDs == ["already"], "same-folder resources should be reported as unchanged")
    try expect(Set(plan.ignoredIDs) == Set(["missing", "deleted"]), "missing and deleted resources should be ignored")
}

func testPromptRepositoryBatchSaveRollsBack() throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    var first = sampleItem(title: "First", prompt: "first")
    first.id = "rollback-first"
    first.folderId = "source"
    first.folderName = "Source"
    var second = sampleItem(title: "Second", prompt: "second")
    second.id = "rollback-second"
    second.folderId = "source"
    second.folderName = "Source"
    try repository.saveItems([first, second])

    let databasePath = libraryURL.appendingPathComponent("database/promptstudio.sqlite").path
    let database = try SQLiteDatabase(path: databasePath, mode: .existingReadWrite)
    try database.execute(
        """
        CREATE TRIGGER fail_batch_move
        BEFORE INSERT ON prompt_items
        WHEN NEW.id = 'rollback-second' AND NEW.folderId = 'target'
        BEGIN
            SELECT RAISE(ABORT, 'forced batch failure');
        END;
        """
    )

    first.folderId = "target"
    first.folderName = "Target"
    second.folderId = "target"
    second.folderName = "Target"
    var didThrow = false
    do {
        try repository.saveItems([first, second])
    } catch {
        didThrow = true
    }
    try expect(didThrow, "forced batch failure should throw")
    let persisted = Dictionary(uniqueKeysWithValues: try repository.loadItems().map { ($0.id, $0) })
    try expect(persisted[first.id]?.folderId == "source", "the first update must roll back")
    try expect(persisted[second.id]?.folderId == "source", "the failing update must remain unchanged")
}
```

Call both from the final runner:

```swift
try testPromptItemBatchMovePlanner()
try testPromptRepositoryBatchSaveRollsBack()
```

- [ ] **Step 2: Run the core test executable and verify it fails**

Run:

```bash
swift run PromptStudioCoreUnitTests
```

Expected: compilation fails because `PromptItemBatchMovePlanner` does not exist.

- [ ] **Step 3: Add the pure planner**

Create `Sources/PromptStudioCore/PromptItemBatchMovePlanner.swift`:

```swift
import Foundation

public struct PromptItemBatchMovePlan: Sendable {
    public let updatedItems: [PromptItem]
    public let unchangedIDs: [String]
    public let ignoredIDs: [String]
}

public enum PromptItemBatchMovePlanner {
    public static func plan(
        items: [PromptItem],
        requestedIDs: [String],
        targetFolderID: String,
        targetFolderName: String,
        updatedAt: Date = Date()
    ) -> PromptItemBatchMovePlan {
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var seen = Set<String>()
        let orderedIDs = requestedIDs.filter { seen.insert($0).inserted }
        var updatedItems: [PromptItem] = []
        var unchangedIDs: [String] = []
        var ignoredIDs: [String] = []

        for id in orderedIDs {
            guard var item = itemsByID[id], !item.isDeleted else {
                ignoredIDs.append(id)
                continue
            }
            guard item.folderId != targetFolderID else {
                unchangedIDs.append(id)
                continue
            }
            item.folderId = targetFolderID
            item.folderName = targetFolderName
            item.category = item.assetKind.displayName
            item.updatedAt = updatedAt
            updatedItems.append(item)
        }

        return PromptItemBatchMovePlan(
            updatedItems: updatedItems,
            unchangedIDs: unchangedIDs,
            ignoredIDs: ignoredIDs
        )
    }
}
```

- [ ] **Step 4: Implement AppState's ordered drag IDs and batch move**

Add beside the current `moveItem` methods in `Sources/PromptStudio/AppState.swift`:

```swift
func orderedItemIDsForDrag(startingWith itemID: String) -> [String] {
    if !selectedIDs.contains(itemID), let item = itemsByID[itemID] {
        select(item)
    }
    let requested = selectedIDs.isEmpty ? Set([itemID]) : selectedIDs
    let visible = filteredItems.map(\.id).filter(requested.contains)
    let visibleSet = Set(visible)
    let remaining = items.map(\.id).filter { requested.contains($0) && !visibleSet.contains($0) }
    return visible + remaining
}

func moveItems(_ itemIDs: [String], toFolderID folderID: String) {
    guard requireFeature(.proManageCollections) else { return }
    guard let folder = folder(withID: folderID) else {
        modal = .error("目标文件夹不存在")
        return
    }

    let selectionBeforeMove = selectedIDs
    let primaryBeforeMove = selectedID
    let plan = PromptItemBatchMovePlanner.plan(
        items: items,
        requestedIDs: itemIDs,
        targetFolderID: folder.id,
        targetFolderName: folder.name
    )
    guard !plan.updatedItems.isEmpty else {
        if !plan.unchangedIDs.isEmpty {
            showToast("所选素材已在当前文件夹")
        }
        return
    }

    do {
        try repository?.saveItems(plan.updatedItems)
        folders = try repository?.loadFolders() ?? folders
        items = try repository?.loadItems() ?? items
        tags = try repository?.loadTags() ?? tags

        let visibleIDs = Set(filteredItems.map(\.id))
        let retainedIDs = selectionBeforeMove.intersection(visibleIDs)
        if !retainedIDs.isEmpty {
            selectItems(
                ids: retainedIDs,
                primaryID: primaryBeforeMove.flatMap { retainedIDs.contains($0) ? $0 : nil }
            )
        }
        showToast(
            plan.updatedItems.count > 1
                ? "已移动 \(plan.updatedItems.count) 个项目到 \(folder.name)"
                : "已移动到 \(folder.name)"
        )
    } catch {
        modal = .error(error.localizedDescription)
    }
}
```

Replace the complete existing single-item `moveItem(_:toFolderID:)` implementation with this wrapper:

```swift
func moveItem(_ itemID: String, toFolderID folderID: String) {
    moveItems([itemID], toFolderID: folderID)
}
```

Keep the feature check only in `moveItems` so the single-item wrapper does not display the license gate twice.

- [ ] **Step 5: Run tests and build**

Run:

```bash
swift run PromptStudioCoreUnitTests
swift build
```

Expected: unit executable passes and Debug build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/PromptStudioCore/PromptItemBatchMovePlanner.swift Sources/PromptStudioCoreUnitTests/main.swift Sources/PromptStudio/AppState.swift
git commit -m "Add transactional batch folder moves"
```

## Task 3: Lock the Native UI Contract with a Failing Regression Script

**Files:**
- Create: `scripts/test_native_marquee_multiselect.sh`
- Modify: `scripts/test_release_ui_copy.sh`

- [ ] **Step 1: Add the focused source regression script**

Create `scripts/test_native_marquee_multiselect.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
MARQUEE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/NativeMarqueeCollectionView.swift"
STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"

[[ -f "$MARQUEE_FILE" ]] || {
    echo "Native marquee collection view is missing." >&2
    exit 1
}

/usr/bin/grep -q 'NativeMarqueeCollectionView(frame: .zero)' "$GRID_FILE" || {
    echo "The active native masonry grid must use NativeMarqueeCollectionView." >&2
    exit 1
}

/usr/bin/grep -q 'onMarqueeChange' "$GRID_FILE" || {
    echo "The masonry coordinator must receive live marquee rectangles." >&2
    exit 1
}

/usr/bin/grep -q 'indexPathsForItems(in: rect)' "$GRID_FILE" || {
    echo "Marquee hit testing must reuse the masonry layout frames." >&2
    exit 1
}

/usr/bin/grep -q 'PromptItemDragPayload.pasteboardTypeIdentifier' "$GRID_FILE" || {
    echo "Card drag sources must publish the multi-item payload." >&2
    exit 1
}

/usr/bin/grep -q 'state.moveItems(itemIDs, toFolderID: row.folder.id)' "$GRID_FILE" || {
    echo "Folder drops must execute one batch move." >&2
    exit 1
}

/usr/bin/grep -q 'func orderedItemIDsForDrag(startingWith itemID: String)' "$STATE_FILE" || {
    echo "AppState must provide deterministic drag ordering." >&2
    exit 1
}

/usr/bin/grep -q 'flags == .command' "$GRID_FILE" || {
    echo "Batch trash must require Command without Shift, Option, or Control." >&2
    exit 1
}

/usr/bin/grep -q 'AppKitBridge.isTextInputActive()' "$GRID_FILE" || {
    echo "Batch trash must not intercept active text editing." >&2
    exit 1
}

echo "Native marquee multi-selection regression tests passed"
```

Make it executable:

```bash
chmod +x scripts/test_native_marquee_multiselect.sh
```

Append to `scripts/test_release_ui_copy.sh` before its success message:

```bash
"$ROOT_DIR/scripts/test_native_marquee_multiselect.sh"
```

- [ ] **Step 2: Run the focused script and verify it fails**

Run:

```bash
./scripts/test_native_marquee_multiselect.sh
```

Expected: FAIL with `Native marquee collection view is missing.`

- [ ] **Step 3: Commit the failing contract**

```bash
git add scripts/test_native_marquee_multiselect.sh scripts/test_release_ui_copy.sh
git commit -m "Test native marquee multi-selection wiring"
```

## Task 4: Implement the AppKit Marquee Capture View

**Files:**
- Create: `Sources/PromptStudio/Views/NativeMarqueeCollectionView.swift`

- [ ] **Step 1: Implement the event and overlay view**

Create `Sources/PromptStudio/Views/NativeMarqueeCollectionView.swift` with:

```swift
import AppKit
import PromptStudioCore
import SwiftUI

@MainActor
final class NativeMarqueeCollectionView: NSCollectionView {
    var onBlankClick: (() -> Void)?
    var onMarqueeBegin: ((CGPoint, Bool) -> Void)?
    var onMarqueeChange: ((CGRect) -> Void)?
    var onMarqueeEnd: (() -> Void)?
    var onMarqueeCancel: (() -> Void)?

    private let marqueeView = NativeMarqueeOverlayView(frame: .zero)
    private var mouseDownPoint: CGPoint?
    private var currentWindowPoint: CGPoint?
    private var isMarqueeActive = false
    private var isCommandAdditive = false
    private var autoscrollTimer: Timer?
    private var windowResignObserver: NSObjectProtocol?
    private let dragThreshold: CGFloat = 4
    private let edgeZone: CGFloat = 32

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        if marqueeView.superview == nil {
            addSubview(marqueeView, positioned: .above, relativeTo: nil)
        }
        if let window {
            windowResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishMarquee(cancelled: false)
                }
            }
        } else {
            finishMarquee(cancelled: false)
        }
    }

    deinit {
        autoscrollTimer?.invalidate()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.buttonNumber == 0, !pointHitsItem(point) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        mouseDownPoint = point
        currentWindowPoint = event.locationInWindow
        isCommandAdditive = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else {
            super.mouseDragged(with: event)
            return
        }
        currentWindowPoint = event.locationInWindow
        let point = convert(event.locationInWindow, from: nil)
        if !isMarqueeActive, hypot(point.x - start.x, point.y - start.y) >= dragThreshold {
            isMarqueeActive = true
            onMarqueeBegin?(start, isCommandAdditive)
            startAutoscroll()
        }
        guard isMarqueeActive else { return }
        updateMarquee(from: start, to: point)
    }

    override func mouseUp(with event: NSEvent) {
        defer { clearPointerState() }
        guard mouseDownPoint != nil else {
            super.mouseUp(with: event)
            return
        }
        if isMarqueeActive {
            onMarqueeEnd?()
            hideMarquee()
        } else {
            onBlankClick?()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, isMarqueeActive else {
            super.keyDown(with: event)
            return
        }
        finishMarquee(cancelled: true)
    }

    func finishMarqueeForDatasetChange() {
        finishMarquee(cancelled: false)
    }

    private func pointHitsItem(_ point: CGPoint) -> Bool {
        collectionViewLayout?
            .layoutAttributesForElements(in: CGRect(origin: point, size: CGSize(width: 1, height: 1)))
            .contains(where: { $0.representedElementCategory == .item }) == true
    }

    private func updateMarquee(from start: CGPoint, to point: CGPoint) {
        let rect = MarqueeSelectionResolver.normalizedRect(from: start, to: point)
        marqueeView.frame = rect
        marqueeView.isHidden = false
        onMarqueeChange?(rect)
    }

    private func startAutoscroll() {
        autoscrollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    private func autoscrollTick() {
        guard isMarqueeActive,
              let currentWindowPoint,
              let start = mouseDownPoint,
              let scrollView = enclosingScrollView else { return }
        let windowPointInView = convert(currentWindowPoint, from: nil)
        let visible = visibleRect
        let upperDistance = windowPointInView.y - visible.minY
        let lowerDistance = visible.maxY - windowPointInView.y
        let delta: CGFloat
        if upperDistance < edgeZone {
            delta = -max(2, (edgeZone - upperDistance) * 0.28)
        } else if lowerDistance < edgeZone {
            delta = max(2, (edgeZone - lowerDistance) * 0.28)
        } else {
            return
        }

        let clipView = scrollView.contentView
        let maximumY = max(0, bounds.height - clipView.bounds.height)
        let nextY = min(max(0, clipView.bounds.origin.y + delta), maximumY)
        guard nextY != clipView.bounds.origin.y else { return }
        clipView.scroll(to: CGPoint(x: clipView.bounds.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
        updateMarquee(from: start, to: convert(currentWindowPoint, from: nil))
    }

    private func finishMarquee(cancelled: Bool) {
        guard mouseDownPoint != nil || isMarqueeActive else { return }
        if isMarqueeActive {
            cancelled ? onMarqueeCancel?() : onMarqueeEnd?()
        }
        hideMarquee()
        clearPointerState()
    }

    private func hideMarquee() {
        marqueeView.isHidden = true
        marqueeView.frame = .zero
    }

    private func clearPointerState() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        mouseDownPoint = nil
        currentWindowPoint = nil
        isMarqueeActive = false
        isCommandAdditive = false
    }
}

private final class NativeMarqueeOverlayView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        let accent = NSColor(StudioColor.primaryAction)
        layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        layer?.borderColor = accent.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.zPosition = 10_000
        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
```

- [ ] **Step 2: Build to catch AppKit API or actor-isolation errors**

Run:

```bash
swift build
```

Expected: Debug build succeeds. If AppKit reports a callback isolation error, keep all timer callbacks inside `MainActor.assumeIsolated` rather than removing main-thread isolation.

- [ ] **Step 3: Commit**

```bash
git add Sources/PromptStudio/Views/NativeMarqueeCollectionView.swift
git commit -m "Add native marquee collection view"
```

## Task 5: Wire Marquee Selection into the Masonry Coordinator

**Files:**
- Modify: `Sources/PromptStudio/Views/PromptStudioView.swift`

- [ ] **Step 1: Replace the passive native collection view**

In `MasonryCollectionGridView.makeNSView`, replace:

```swift
let collectionView = FlippedMasonryCollectionView(frame: .zero)
```

with:

```swift
let collectionView = NativeMarqueeCollectionView(frame: .zero)
```

After assigning Coordinator references, wire:

```swift
collectionView.onBlankClick = { [weak coordinator = context.coordinator] in
    coordinator?.clearSelectionFromBlankClick()
}
collectionView.onMarqueeBegin = { [weak coordinator = context.coordinator] point, additive in
    coordinator?.beginMarquee(at: point, additive: additive)
}
collectionView.onMarqueeChange = { [weak coordinator = context.coordinator] rect in
    coordinator?.updateMarquee(in: rect)
}
collectionView.onMarqueeEnd = { [weak coordinator = context.coordinator] in
    coordinator?.endMarquee()
}
collectionView.onMarqueeCancel = { [weak coordinator = context.coordinator] in
    coordinator?.cancelMarquee()
}
```

Delete the old `FlippedMasonryCollectionView` declaration after all references are gone.

- [ ] **Step 2: Add Coordinator selection snapshots and methods**

Add these properties to `MasonryCollectionGridView.Coordinator`:

```swift
private var marqueeBaseItemIDs: Set<String> = []
private var marqueeBaseFolderID: String?
private var isMarqueeAdditive = false
private var isMarqueeSelecting = false
```

Add these methods beside `selectItem`:

```swift
func clearSelectionFromBlankClick() {
    let previousIDs = state?.selectedIDs ?? []
    let previousFolderID = selectedFolderID
    selectedFolderID = nil
    state?.selectItems(ids: [])
    reloadSelectionChanges(
        previousItemIDs: previousIDs,
        nextItemIDs: [],
        previousFolderID: previousFolderID,
        nextFolderID: nil
    )
    lastRenderedSelectedItemIDs = []
}

func beginMarquee(at point: CGPoint, additive: Bool) {
    marqueeBaseItemIDs = state?.selectedIDs ?? []
    marqueeBaseFolderID = selectedFolderID
    isMarqueeAdditive = additive
    isMarqueeSelecting = true
    selectedFolderID = nil
}

func updateMarquee(in rect: CGRect) {
    guard isMarqueeSelecting, let state, let layout else { return }
    let hitIDs = Set(layout.indexPathsForItems(in: rect).compactMap { indexPath in
        guard entries.indices.contains(indexPath.item),
              case .item(let item) = entries[indexPath.item] else { return nil }
        return item.id
    })
    let nextIDs = MarqueeSelectionResolver.selection(
        base: marqueeBaseItemIDs,
        hits: hitIDs,
        additive: isMarqueeAdditive
    )
    guard nextIDs != state.selectedIDs || marqueeBaseFolderID != nil else { return }
    let previousIDs = state.selectedIDs
    let previousFolderID = selectedFolderID ?? marqueeBaseFolderID
    let primaryID = isMarqueeAdditive && state.selectedID.map(nextIDs.contains) == true
        ? state.selectedID
        : layout.visualItemIDs.first(where: nextIDs.contains)
    state.selectItems(ids: nextIDs, primaryID: primaryID)
    reloadSelectionChanges(
        previousItemIDs: previousIDs,
        nextItemIDs: nextIDs,
        previousFolderID: previousFolderID,
        nextFolderID: nil
    )
    lastRenderedSelectedItemIDs = nextIDs
}

func endMarquee() {
    isMarqueeSelecting = false
    marqueeBaseItemIDs = []
    marqueeBaseFolderID = nil
    isMarqueeAdditive = false
}

func cancelMarquee() {
    guard isMarqueeSelecting, let state else { return }
    let previousIDs = state.selectedIDs
    let previousFolderID = selectedFolderID
    selectedFolderID = marqueeBaseFolderID
    state.selectItems(
        ids: marqueeBaseItemIDs,
        primaryID: layout?.visualItemIDs.first(where: marqueeBaseItemIDs.contains)
    )
    reloadSelectionChanges(
        previousItemIDs: previousIDs,
        nextItemIDs: marqueeBaseItemIDs,
        previousFolderID: previousFolderID,
        nextFolderID: marqueeBaseFolderID
    )
    lastRenderedSelectedItemIDs = marqueeBaseItemIDs
    endMarquee()
}
```

Before applying a dataset reload in `applyPendingDatasetUpdate`, end the live interaction without restoring a stale snapshot:

```swift
(collectionView as? NativeMarqueeCollectionView)?.finishMarqueeForDatasetChange()
```

- [ ] **Step 3: Run the build and focused regression script**

Run:

```bash
swift build
./scripts/test_native_marquee_multiselect.sh
```

Expected: build succeeds; regression now advances past the native marquee and hit-test checks, then fails at the missing multi-item payload check.

- [ ] **Step 4: Commit**

```bash
git add Sources/PromptStudio/Views/PromptStudioView.swift
git commit -m "Wire marquee selection into native masonry grid"
```

## Task 6: Publish One Multi-Item Drag Payload from Every Card Type

**Files:**
- Modify: `Sources/PromptStudio/Views/PromptStudioView.swift`

- [ ] **Step 1: Add shared payload writers**

Near the native card declarations, add:

```swift
private extension NSPasteboard.PasteboardType {
    static let promptStudioItemIDs = NSPasteboard.PasteboardType(
        PromptItemDragPayload.pasteboardTypeIdentifier
    )
}

private extension UTType {
    static let promptStudioItemIDs = UTType(
        importedAs: PromptItemDragPayload.pasteboardTypeIdentifier
    )
}

private func promptStudioPasteboardItem(itemIDs: [String]) -> NSPasteboardItem? {
    let payload = PromptItemDragPayload(itemIDs: itemIDs)
    guard !payload.itemIDs.isEmpty, let data = try? payload.encoded() else { return nil }
    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setData(data, forType: .promptStudioItemIDs)
    pasteboardItem.setString(payload.itemIDs[0], forType: .string)
    return pasteboardItem
}

private func promptStudioItemProvider(itemIDs: [String]) -> NSItemProvider {
    let payload = PromptItemDragPayload(itemIDs: itemIDs)
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
        forTypeIdentifier: PromptItemDragPayload.pasteboardTypeIdentifier,
        visibility: .ownProcess
    ) { completion in
        completion(try? payload.encoded(), nil)
        return nil
    }
    if let primaryID = payload.itemIDs.first {
        provider.registerObject(primaryID as NSString, visibility: .ownProcess)
    }
    return provider
}
```

- [ ] **Step 2: Pass an ordered drag-ID provider to native cards**

Extend `MasonryCollectionItem.configure` with:

```swift
dragItemIDs: @escaping (String) -> [String]
```

Pass it from the Coordinator's item configuration:

```swift
dragItemIDs: { [weak state] itemID in
    state?.orderedItemIDsForDrag(startingWith: itemID) ?? [itemID]
}
```

Extend both `NativeImageCardView.configure` and `NativeMarkdownCardView.configure` to store:

```swift
private var dragItemIDs: ((String) -> [String])?
```

Add these parameters to both configure methods and assign them to the stored properties:

```swift
selectedItemCount: Int,
dragItemIDs: @escaping (String) -> [String]
```

At both call sites inside `MasonryCollectionItem.configure`, pass:

```swift
selectedItemCount: state.selectedIDs.count,
dragItemIDs: dragItemIDs
```

In `NativeImageCardView.mouseDragged`, replace the single-ID pasteboard setup with:

```swift
let itemIDs = dragItemIDs?(item.id) ?? [item.id]
guard let pasteboardItem = promptStudioPasteboardItem(itemIDs: itemIDs) else { return }
let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
draggingItem.setDraggingFrame(bounds, contents: dragPreviewImage(itemCount: itemIDs.count))
```

In `NativeMarkdownCardView.mouseDragged`, use:

```swift
let itemIDs = dragItemIDs?(draggedItemID) ?? [draggedItemID]
guard let pasteboardItem = promptStudioPasteboardItem(itemIDs: itemIDs) else { return }
let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
draggingItem.setDraggingFrame(bounds, contents: dragPreviewImage(itemCount: itemIDs.count))
```

Keep the existing no-argument `dragPreviewImage()` as the base renderer and add:

```swift
private func dragPreviewImage(itemCount: Int) -> NSImage {
    let base = dragPreviewImage()
    guard itemCount > 1 else { return base }

    let result = NSImage(size: base.size)
    result.lockFocus()
    base.draw(in: CGRect(origin: .zero, size: base.size))

    let text = "\(itemCount)" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    let textSize = text.size(withAttributes: attributes)
    let badgeRect = CGRect(
        x: max(8, base.size.width - textSize.width - 24),
        y: max(8, base.size.height - textSize.height - 20),
        width: textSize.width + 16,
        height: textSize.height + 8
    )
    NSColor.black.withAlphaComponent(0.78).setFill()
    NSBezierPath(roundedRect: badgeRect, xRadius: badgeRect.height / 2, yRadius: badgeRect.height / 2).fill()
    text.draw(
        at: CGPoint(x: badgeRect.minX + 8, y: badgeRect.minY + 4),
        withAttributes: attributes
    )
    result.unlockFocus()
    return result
}
```

Immediately before beginning a multi-item dragging session, announce its count:

```swift
if itemIDs.count > 1 {
    NSAccessibility.post(
        element: self,
        notification: .announcementRequested,
        userInfo: [
            .announcement: "拖动 \(itemIDs.count) 个项目",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ]
    )
}
```

- [ ] **Step 3: Preserve an existing multi-selection when drag starts**

In both native card views, add:

```swift
private var collapseSelectionOnMouseUp = false
private var selectedItemCount = 0
```

Store `isSelected` and the injected `selectedItemCount` during configuration. In `NativeImageCardView`, add an `isCardSelected` property matching the one already present in the Markdown view, and update it from `setSelected(_:)`.

Use this single-click branch in both `mouseDown` methods:

```swift
let selectionModifiers = event.modifierFlags.intersection([.command, .shift])
collapseSelectionOnMouseUp =
    selectionModifiers.isEmpty &&
    isCardSelected &&
    selectedItemCount > 1
if !collapseSelectionOnMouseUp {
    selectAction?(event.modifierFlags)
}
```

After the drag threshold is crossed and before `beginDraggingSession`, set:

```swift
collapseSelectionOnMouseUp = false
hasStartedDragging = true
```

At the start of `mouseUp`, before resetting state, add:

```swift
if collapseSelectionOnMouseUp && !hasStartedDragging {
    selectAction?([])
}
collapseSelectionOnMouseUp = false
```

Command and Shift clicks therefore remain immediate, a plain click still collapses the selection on release, and a drag from an already-selected card preserves the group. Double-click keeps the existing single-item preview path.

- [ ] **Step 4: Update SwiftUI-hosted media cards**

Add a `dragItemIDsProvider: (String) -> [String]` input to `AssetCardView`. Replace its current single-ID `.onDrag` provider with:

```swift
.onDrag {
    promptStudioItemProvider(itemIDs: dragItemIDsProvider(item.id))
}
```

Pass:

```swift
dragItemIDsProvider: { state.orderedItemIDsForDrag(startingWith: $0) }
```

from both the native `NSHostingView` path and the fallback `MasonryGridView` path so video, audio, document, and other resource cards match image and Markdown behavior.

- [ ] **Step 5: Build**

Run:

```bash
swift build
```

Expected: Debug build succeeds for native AppKit cards and hosted SwiftUI cards.

- [ ] **Step 6: Commit**

```bash
git add Sources/PromptStudio/Views/PromptStudioView.swift
git commit -m "Drag complete resource selections"
```

## Task 7: Decode Group Drops and Execute One Folder Move

**Files:**
- Modify: `Sources/PromptStudio/Views/PromptStudioView.swift`

- [ ] **Step 1: Register the private drop type**

In the sidebar folder row's `.onDrop` declaration, include:

```swift
.promptStudioItemIDs
```

before `.text` and keep `.fileURL` support unchanged.

- [ ] **Step 2: Decode the group before falling back to a single string**

At the top of `handleDrop(_:)`, after the file URL branch, add:

```swift
if let provider = providers.first(where: {
    $0.hasItemConformingToTypeIdentifier(PromptItemDragPayload.pasteboardTypeIdentifier)
}) {
    provider.loadDataRepresentation(
        forTypeIdentifier: PromptItemDragPayload.pasteboardTypeIdentifier
    ) { data, _ in
        guard let data,
              let payload = try? PromptItemDragPayload.decode(data),
              !payload.itemIDs.isEmpty else { return }
        Task { @MainActor in
            state.moveItems(payload.itemIDs, toFolderID: row.folder.id)
        }
    }
    return true
}
```

Keep the old NSString branch, but route it through the batch API:

```swift
state.moveItems([itemID], toFolderID: row.folder.id)
```

- [ ] **Step 3: Run the focused source regression**

Run:

```bash
./scripts/test_native_marquee_multiselect.sh
```

Expected: `Native marquee multi-selection regression tests passed`.

- [ ] **Step 4: Build and run core tests**

Run:

```bash
swift build
swift run PromptStudioCoreUnitTests
```

Expected: both succeed.

- [ ] **Step 5: Commit**

```bash
git add Sources/PromptStudio/Views/PromptStudioView.swift
git commit -m "Move dragged resource groups into folders"
```

## Task 8: Verify Command + Backspace Safety and Full Regression

**Files:**
- Modify only if verification exposes a defect:
  - `Sources/PromptStudio/Views/PromptStudioView.swift`
  - `scripts/test_native_marquee_multiselect.sh`

- [ ] **Step 1: Confirm the existing shortcut contract**

Verify `DeleteSelectionKeyMonitor` still contains all of:

```swift
let textInputActive = MainActor.assumeIsolated {
    AppKitBridge.isTextInputActive()
}
guard !textInputActive,
      Self.isCommandDelete(event),
      self?.canDelete() == true else {
    return event
}
```

and:

```swift
let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
guard flags == .command else { return false }
return event.keyCode == 51 || event.keyCode == 117
```

No implementation change is required if these checks remain present.

- [ ] **Step 2: Run automated validation**

Run:

```bash
swift test
swift run PromptStudioCoreUnitTests
swift run PromptStudioSmokeTests
./scripts/test_native_marquee_multiselect.sh
./scripts/test_release_ui_copy.sh
./scripts/build_app.sh debug
```

Expected:

- SwiftPM tests pass.
- `PromptStudioCoreUnitTests passed`.
- `PromptStudioSmokeTests passed`.
- Both shell regression suites pass.
- Debug `.app` is built successfully.

- [ ] **Step 3: Launch the built app**

Run:

```bash
pkill -x PromptStudio || true
open .build/arm64-apple-macosx/debug/PromptStudio.app
```

Expected: the current debug app opens the existing local PromptStudio library.

- [ ] **Step 4: Perform manual interaction checks**

Use the real library and verify:

1. Blank-area drag in all four directions selects every intersecting resource and never selects folder cards.
2. A second plain marquee replaces the first selection.
3. Command-marquee adds to the first selection.
4. Blank click clears; Escape during drag restores the pre-drag selection.
5. Top/bottom edge dragging scrolls and stops immediately after mouseUp or Escape.
6. Dragging a selected image, Markdown, video, audio, or document card moves the full selection to a folder.
7. Dragging an unselected card moves only that card.
8. The drag image displays a count for multi-selection.
9. Command + Backspace moves all selected non-trash items to Trash.
10. The same keys in search, Prompt editing, and Markdown editing delete text rather than resources.
11. Command/Shift click, double-click preview, context menus, card action buttons, and single-card reorder still work.
12. Repeated marquee updates across approximately 280 resources show no selection flicker or material scroll regression.

- [ ] **Step 5: Inspect the final diff**

Run:

```bash
git diff --check
git status --short
git diff --stat HEAD~6
```

Expected: no whitespace errors, no unrelated files, and changes limited to the mapped implementation/test files.

- [ ] **Step 6: Commit any verification-only fixes**

If Step 4 required fixes:

```bash
git add Sources/PromptStudio/Views/PromptStudioView.swift Sources/PromptStudio/Views/NativeMarqueeCollectionView.swift Sources/PromptStudio/AppState.swift scripts/test_native_marquee_multiselect.sh
git commit -m "Polish native marquee interactions"
```

If no fixes were required, do not create an empty commit.

- [ ] **Step 7: Push the completed branch**

```bash
git push origin codex/close-button-unification
```

Expected: remote branch advances to the final verified commit.
