import Foundation
import Combine
import PromptStudioCore

private func phase2a3Item(
    id: String,
    marker: String = "",
    versions: [PromptVersion] = []
) -> PromptItem {
    PromptItem(
        id: id,
        title: "Detail \(marker)",
        type: .image,
        modelId: "model",
        modelName: "model",
        folderName: "folder",
        category: "image",
        assetPath: "/tmp/\(id).png",
        aspectRatio: "1:1",
        width: 1,
        height: 1,
        format: "PNG",
        fileSize: 1,
        tags: ["tag-\(marker)"],
        versions: versions.isEmpty
            ? [PromptVersion(promptItemId: id, version: "V1", prompt: "prompt \(marker)")]
            : versions
    )
}

private final class Phase2A3Loader: ItemDetailLoading, @unchecked Sendable {
    enum Outcome {
        case item(PromptItem?)
        case failure
    }

    private let lock = NSLock()
    private var outcomes: [String: [Outcome]] = [:]
    private var fallback: [String: Outcome] = [:]
    private var delays: [String: UInt64] = [:]
    private var nonCooperativeIDs: Set<String> = []
    private(set) var requests = 0
    private(set) var cancellations = 0
    private(set) var active = 0
    private(set) var peakActive = 0
    var delayNanoseconds: UInt64 = 20_000_000

    func set(_ outcomes: [Outcome], for id: String) {
        lock.lock()
        self.outcomes[id] = outcomes
        lock.unlock()
    }

    func setFallback(_ outcome: Outcome, for id: String) {
        lock.lock()
        fallback[id] = outcome
        lock.unlock()
    }

    func setDelay(_ delayNanoseconds: UInt64, for id: String) {
        lock.lock()
        delays[id] = delayNanoseconds
        lock.unlock()
    }

    func makeNonCooperative(_ id: String) {
        lock.lock()
        nonCooperativeIDs.insert(id)
        lock.unlock()
    }

    func itemDetail(id: String) async throws -> PromptItem? {
        let configuration: (Outcome, UInt64, Bool) = withLock {
            requests += 1
            active += 1
            peakActive = max(peakActive, active)
            let delay = delays[id] ?? delayNanoseconds
            let nonCooperative = nonCooperativeIDs.contains(id)
            if var queued = outcomes[id], !queued.isEmpty {
                let next = queued.removeFirst()
                outcomes[id] = queued
                return (next, delay, nonCooperative)
            }
            return (fallback[id] ?? .item(nil), delay, nonCooperative)
        }
        let outcome = configuration.0
        defer {
            withLock {
                active = max(0, active - 1)
            }
        }

        do {
            if configuration.2 {
                // A detached child deliberately ignores cancellation for the
                // configured delay, modelling a slow dependency that cannot
                // interrupt its underlying read immediately.
                _ = try await Task.detached {
                    try await Task.sleep(nanoseconds: configuration.1)
                }.value
            } else {
                try await Task.sleep(nanoseconds: configuration.1)
                try Task.checkCancellation()
            }
        } catch {
            withLock {
                cancellations += 1
            }
            throw error
        }

        switch outcome {
        case .item(let item):
            return item
        case .failure:
            throw Phase2A3LoaderError.failed
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private enum Phase2A3LoaderError: Error {
    case failed
}

private final class Phase2A3RevisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64

    init(_ current: UInt64) {
        self.current = current
    }

    var value: UInt64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}

/// Phase 2A.3 RED/GREEN coverage for the detail cache and controller.
func testItemDetailControllerPhase2A3() throws {
    let cache = ItemDetailCache()
    let item = phase2a3Item(id: "phase2a3-red")
    _ = cache.insert(item, revision: 1)
    try expect(cache.get(id: item.id, revision: 1) == item, "detail cache should round trip an item")
    try expect(cache.metrics.hits == 1 && cache.metrics.misses == 0, "cache hit metrics should be recorded")
}

func testItemDetailCacheBoundsAndRevision() throws {
    let countCache = ItemDetailCache(maxEntryCount: 32, maxCostBytes: Int.max)
    for index in 0..<33 {
        _ = countCache.insert(phase2a3Item(id: "count-\(index)"), revision: 1)
    }
    try expect(countCache.residentCount == 32, "33rd detail should evict the LRU entry at count bound")
    try expect(countCache.get(id: "count-0", revision: 1) == nil, "count eviction should remove oldest entry")
    try expect(countCache.evictions == 1, "count bound should record one eviction")

    let unit = phase2a3Item(id: "cost-a")
    let unitCost = ItemDetailCache.retainedCost(of: unit)
    let costCache = ItemDetailCache(maxEntryCount: 32, maxCostBytes: unitCost)
    _ = costCache.insert(unit, revision: 1)
    _ = costCache.insert(phase2a3Item(id: "cost-b"), revision: 1)
    try expect(costCache.residentCount == 1 && costCache.residentCost <= unitCost, "cost bound should evict until resident cost fits")
    try expect(costCache.get(id: unit.id, revision: 1) == nil, "cost eviction should remove the older LRU item")

    let oversize = ItemDetailCache(maxEntryCount: 32, maxCostBytes: unitCost - 1)
    try expect(oversize.insert(unit, revision: 1) == 0, "oversize detail should be explicitly skipped")
    try expect(oversize.residentCount == 0 && oversize.residentCost == 0, "oversize detail should not consume cache budget")

    let lru = ItemDetailCache(maxEntryCount: 2, maxCostBytes: Int.max)
    let lruA = phase2a3Item(id: "lru-a")
    let lruB = phase2a3Item(id: "lru-b")
    _ = lru.insert(lruA, revision: 1)
    _ = lru.insert(lruB, revision: 1)
    _ = lru.get(id: lruA.id, revision: 1)
    _ = lru.insert(phase2a3Item(id: "lru-c"), revision: 1)
    try expect(lru.get(id: lruA.id, revision: 1) != nil, "cache hit should promote an entry to MRU")
    try expect(lru.get(id: lruB.id, revision: 1) == nil, "LRU order should evict the least recently used entry")

    let revision = ItemDetailCache(maxEntryCount: 4, maxCostBytes: Int.max)
    let old = phase2a3Item(id: "revision", marker: "old")
    let fresh = phase2a3Item(id: "revision", marker: "fresh")
    _ = revision.insert(old, revision: 1)
    try expect(revision.get(id: old.id, revision: 2) == nil, "revision mismatch must miss")
    _ = revision.insert(fresh, revision: 2)
    try expect(revision.get(id: old.id, revision: 1) == nil, "older revisions must never be returned after a newer insert")
    try expect(revision.get(id: fresh.id, revision: 2) == fresh, "new revision should be returned")
    _ = revision.insert(old, revision: 1)
    try expect(revision.get(id: old.id, revision: 1) == nil, "stale revision reinsertion must remain rejected")
}

func testItemDetailCacheConservativeCost() throws {
    var versions: [PromptVersion] = []
    versions.reserveCapacity(500)
    for index in 0..<500 {
        versions.append(
            PromptVersion(
                promptItemId: "huge",
                version: "V\(index)",
                prompt: String(repeating: "p", count: 8_192),
                negativePrompt: String(repeating: "n", count: 256),
                parameters: ["seed-\(index)": String(index)],
                note: String(repeating: "note", count: 64)
            )
        )
    }
    let huge = phase2a3Item(id: "huge", versions: versions)
    let retained = ItemDetailCache.retainedCost(of: huge)
    try expect(retained > 4 * 1024 * 1024, "500 versions and large prompts must be charged conservatively")
    let cache = ItemDetailCache(maxEntryCount: 32, maxCostBytes: 1 * 1024 * 1024)
    try expect(cache.insert(huge, revision: 1) == 0, "large detail should be rejected when it exceeds the byte budget")
    try expect(cache.residentCount == 0, "rejected large detail should not be resident")

    // Exercise the production 64 MiB limit directly. The estimator charges
    // string payload conservatively, so this 34 MiB prompt crosses the real
    // default budget without requiring a 64+ MiB allocation in the test.
    let overDefaultBudget = phase2a3Item(
        id: "over-default-budget",
        versions: [
            PromptVersion(
                promptItemId: "over-default-budget",
                version: "V1",
                prompt: String(repeating: "x", count: 34 * 1024 * 1024)
            )
        ]
    )
    let overDefaultCost = ItemDetailCache.retainedCost(of: overDefaultBudget)
    try expect(overDefaultCost > ItemDetailCache.defaultMaxCostBytes, "fixture should exceed the production 64 MiB cache budget")
    let defaultBudgetCache = ItemDetailCache()
    try expect(defaultBudgetCache.insert(overDefaultBudget, revision: 1) == 0, "default cache should reject a detail over 64 MiB")
    try expect(defaultBudgetCache.residentCount == 0, "64 MiB rejection should not leave a resident detail")
}

func testItemDetailCacheTokensAndBoundedMetadata() throws {
    let cache = ItemDetailCache(maxEntryCount: 4, maxCostBytes: Int.max)
    let id = "tokenized"
    let item = phase2a3Item(id: id, marker: "late")
    let token = cache.token(for: id)

    cache.invalidate(ids: [id])
    try expect(cache.insert(item, revision: 1, token: token) == 0, "invalidation must reject an old completion token")
    try expect(cache.get(id: id, revision: 1) == nil, "rejected completion must not become resident")

    let removeToken = cache.token(for: id)
    cache.remove(ids: [id])
    try expect(cache.compareAndInsert(item, revision: 2, token: removeToken) == 0, "permanent remove must reject an old completion token")

    let allToken = cache.token(for: id)
    cache.removeAll()
    try expect(cache.insert(item, revision: 3, token: allToken) == 0, "removeAll must reject an old completion token")

    for index in 0..<500 {
        _ = cache.insert(phase2a3Item(id: "evicted-\(index)"), revision: 1)
    }
    try expect(cache.residentCount <= 4, "resident count must stay bounded after many IDs")
    try expect(cache.revisionMetadataCount <= cache.maxEntryCount, "revision metadata must be bounded by the cache capacity")

    let minimumOversizeCost = ItemDetailCache.retainedCost(of: phase2a3Item(id: "oversize-0"))
    let oversize = ItemDetailCache(maxEntryCount: 4, maxCostBytes: max(1, minimumOversizeCost - 1))
    for index in 0..<500 {
        _ = oversize.insert(phase2a3Item(id: "oversize-\(index)"), revision: 1)
    }
    try expect(oversize.residentCount == 0, "oversize IDs must not become resident")
    try expect(oversize.revisionMetadataCount <= oversize.maxEntryCount, "oversize IDs must not leave unbounded revision metadata")
}

func testItemDetailCacheConcurrentAccess() throws {
    let cache = ItemDetailCache(maxEntryCount: 32, maxCostBytes: Int.max)
    let items = (0..<100).map { phase2a3Item(id: "concurrent-\($0)") }
    DispatchQueue.concurrentPerform(iterations: 400) { index in
        let item = items[index % items.count]
        if index.isMultiple(of: 3) {
            _ = cache.insert(item, revision: UInt64(index / items.count + 1))
        } else {
            _ = cache.get(id: item.id, revision: 1)
        }
    }
    try expect(cache.residentCount <= 32, "concurrent cache access must preserve the count bound")
    try expect(cache.residentCost <= cache.maxCostBytes, "concurrent cache access must preserve the cost bound")
}

@MainActor
private func phase2a3Wait(_ nanoseconds: UInt64 = 100_000_000) async {
    try? await Task.sleep(nanoseconds: nanoseconds)
    await Task.yield()
}

@MainActor
func runItemDetailControllerTests() async throws {
    let hitID = "controller-cache-hit"
    let hitItem = phase2a3Item(id: hitID, marker: "cached")
    let hitCache = ItemDetailCache()
    _ = hitCache.insert(hitItem, revision: 7)
    let hitLoader = Phase2A3Loader()
    let hitRevision = Phase2A3RevisionBox(7)
    let hitController = ItemDetailController(
        loader: hitLoader,
        cache: hitCache,
        revisionProvider: { _ in hitRevision.value }
    )
    hitController.select(id: hitID)
    await phase2a3Wait()
    try expect(hitLoader.requests == 0, "cache hit should avoid a loader request")
    try expect(hitController.state == .loaded && hitController.currentDetail == hitItem, "cache hit should publish loaded detail")

    let raceLoader = Phase2A3Loader()
    raceLoader.delayNanoseconds = 200_000_000
    raceLoader.setFallback(.item(phase2a3Item(id: "A", marker: "A")), for: "A")
    raceLoader.setFallback(.item(phase2a3Item(id: "B", marker: "B")), for: "B")
    raceLoader.setFallback(.item(phase2a3Item(id: "C", marker: "C")), for: "C")
    let raceController = ItemDetailController(loader: raceLoader)
    raceController.select(id: "A")
    await Task.yield()
    raceController.select(id: "B")
    await Task.yield()
    raceController.select(id: "C")
    await phase2a3Wait(350_000_000)
    try expect(raceController.selectedID == "C", "selection should remain on the final ID")
    try expect(raceController.currentDetail?.id == "C" && raceController.state == .loaded, "late A/B results must not overwrite final C")
    try expect(raceLoader.cancellations >= 1, "replacing an in-flight selection should propagate cancellation to its loader")

    let nonCooperativeLoader = Phase2A3Loader()
    nonCooperativeLoader.setFallback(.item(phase2a3Item(id: "slow-A", marker: "slow")), for: "slow-A")
    nonCooperativeLoader.setFallback(.item(phase2a3Item(id: "fast-B", marker: "fast-b")), for: "fast-B")
    nonCooperativeLoader.setFallback(.item(phase2a3Item(id: "fast-C", marker: "fast-c")), for: "fast-C")
    nonCooperativeLoader.setDelay(400_000_000, for: "slow-A")
    nonCooperativeLoader.setDelay(20_000_000, for: "fast-B")
    nonCooperativeLoader.setDelay(20_000_000, for: "fast-C")
    nonCooperativeLoader.makeNonCooperative("slow-A")
    let nonCooperativeController = ItemDetailController(loader: nonCooperativeLoader)
    nonCooperativeController.select(id: "slow-A")
    await Task.yield()
    let fastSelectionStart = Date()
    nonCooperativeController.select(id: "fast-B")
    await Task.yield()
    nonCooperativeController.select(id: "fast-C")
    await phase2a3Wait(100_000_000)
    let fastSelectionLatency = Date().timeIntervalSince(fastSelectionStart)
    try expect(fastSelectionLatency < 0.25, "final selection must not wait for a non-cooperative slow predecessor")
    try expect(nonCooperativeController.currentDetail?.id == "fast-C", "non-cooperative A must not block final C")
    await phase2a3Wait(380_000_000)
    try expect(nonCooperativeController.currentDetail?.id == "fast-C", "late non-cooperative A must not overwrite final C")

    let rapidLoader = Phase2A3Loader()
    rapidLoader.delayNanoseconds = 100_000_000
    for index in 0..<50 {
        rapidLoader.setFallback(.item(phase2a3Item(id: "rapid-\(index)")), for: "rapid-\(index)")
    }
    let rapidController = ItemDetailController(loader: rapidLoader)
    for index in 0..<50 {
        rapidController.select(id: "rapid-\(index)")
        await Task.yield()
    }
    let rapidStart = Date()
    await phase2a3Wait(180_000_000)
    let rapidLatency = Date().timeIntervalSince(rapidStart)
    try expect(rapidController.currentDetail?.id == "rapid-49", "rapid selection should publish only the final detail")
    try expect(rapidLatency < 0.35, "50 rapid selections should have bounded final latency without a serialized wait queue")

    let errorID = "controller-error"
    let errorItem = phase2a3Item(id: errorID, marker: "retry")
    let errorLoader = Phase2A3Loader()
    errorLoader.set([.failure, .item(errorItem)], for: errorID)
    let errorController = ItemDetailController(loader: errorLoader)
    errorController.select(id: errorID)
    await phase2a3Wait()
    try expect(errorController.state == .failed && errorController.failureKind == .load, "loader errors should publish failed state")
    errorController.retry()
    await phase2a3Wait()
    try expect(errorController.state == .loaded && errorController.currentDetail == errorItem, "retry should reload only the current ID")

    let missingID = "controller-missing"
    let missingLoader = Phase2A3Loader()
    missingLoader.setFallback(.item(nil), for: missingID)
    var missingCallbacks: [String] = []
    let missingController = ItemDetailController(
        loader: missingLoader,
        missingCallback: { missingCallbacks.append($0) }
    )
    missingController.select(id: missingID)
    await phase2a3Wait()
    try expect(missingController.selectedID == missingID, "not-found should preserve the selection")
    try expect(missingController.state == .failed && missingController.failureKind == .notFound, "nil detail should publish not-found failure")
    try expect(missingController.currentDetail == nil && missingCallbacks == [missingID], "not-found should clear detail and call the callback")

    let removeID = "controller-remove"
    let removeLoader = Phase2A3Loader()
    removeLoader.delayNanoseconds = 120_000_000
    removeLoader.setFallback(.item(phase2a3Item(id: removeID)), for: removeID)
    removeLoader.makeNonCooperative(removeID)
    let removeCache = ItemDetailCache()
    let removeController = ItemDetailController(loader: removeLoader, cache: removeCache)
    removeController.select(id: removeID)
    await Task.yield()
    removeController.remove(ids: [removeID])
    try expect(removeController.selectedID == removeID, "permanent removal should keep the selection identity")
    try expect(removeController.currentDetail == nil && removeController.state == .failed && removeController.isNotFound, "permanent removal should clear detail and enter not-found failure")
    await phase2a3Wait(180_000_000)
    try expect(removeLoader.requests == 1, "permanent removal should leave only the original in-flight request")
    try expect(removeCache.get(id: removeID, revision: 0) == nil, "late completion after permanent remove must not repopulate cache")

    let invalidateID = "controller-invalidate"
    let stale = phase2a3Item(id: invalidateID, marker: "stale")
    let fresh = phase2a3Item(id: invalidateID, marker: "fresh")
    let invalidateCache = ItemDetailCache()
    _ = invalidateCache.insert(stale, revision: 1)
    let invalidateLoader = Phase2A3Loader()
    invalidateLoader.setFallback(.item(fresh), for: invalidateID)
    let invalidateRevision = Phase2A3RevisionBox(1)
    let invalidateController = ItemDetailController(
        loader: invalidateLoader,
        cache: invalidateCache,
        revisionProvider: { _ in invalidateRevision.value }
    )
    invalidateController.select(id: invalidateID)
    await phase2a3Wait()
    invalidateRevision.value = 2
    invalidateController.invalidate(ids: [invalidateID])
    await phase2a3Wait()
    try expect(invalidateLoader.requests == 1 && invalidateController.currentDetail == fresh, "invalidation should reload the selected ID at its new revision")
    invalidateController.invalidateAll()
    await phase2a3Wait()
    try expect(invalidateLoader.requests == 2, "invalidateAll should also reload the current selection")
}
