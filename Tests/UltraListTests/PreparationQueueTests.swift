import Testing
@testable import UltraList

struct PreparationQueueTests {
    private func newer(_ old: Int, _ new: Int) -> Int { new }

    @Test func aBusyProducerCannotReplaceThePreparationThatWillMakeProgress() {
        var queue = PreparationQueue<Int, String>()
        queue.submit(1, waiting: ["a"], merge: newer)
        queue.submit(2, waiting: ["b"], merge: newer)
        queue.submit(3, waiting: ["c"], merge: newer)
        queue.complete("a")
        #expect(queue.takeReady(merge: newer)?.value == 1)
        queue.complete("b")
        #expect(queue.takeReady(merge: newer) == nil)
        queue.complete("c")
        #expect(queue.takeReady(merge: newer)?.value == 3)
        #expect(queue.isEmpty)
    }

    @Test func aReadySuccessorCanOvertakeAnOlderPreparation() {
        var queue = PreparationQueue<Int, String>()
        queue.submit(1, waiting: ["slow"], merge: newer)
        queue.submit(2, waiting: [], merge: newer)
        #expect(queue.takeReady(merge: newer)?.value == 2)
        queue.complete("slow")
        #expect(queue.takeReady(merge: newer) == nil)
    }

    @Test func continuousSubmissionsHaveABoundedGapBetweenApplies() {
        var queue = PreparationQueue<Int, Int>()
        var completions: [Int: [Int]] = [:]
        var applied: [(time: Int, value: Int)] = []
        for time in 0...420 {
            if time < 400, time.isMultiple(of: 10) {
                queue.submit(time, waiting: [time], merge: newer)
                completions[time + 15, default: []].append(time)
            }
            for key in completions[time, default: []] { queue.complete(key) }
            if let ready = queue.takeReady(merge: newer) { applied.append((time, ready.value)) }
        }
        #expect(applied.first?.time == 15)
        #expect(applied.last?.value == 390)
        #expect(zip(applied, applied.dropFirst()).allSatisfy { pair in
            pair.1.time - pair.0.time <= 30 && pair.1.value > pair.0.value
        })
    }

    @Test func supersessionCarriesIntentWhileAnExplicitNewIntentWins() {
        struct Snapshot { var value: Int; var intent: String?; var blocks: [Int] }
        func merge(_ old: Snapshot, _ new: Snapshot) -> Snapshot {
            .init(value: new.value, intent: new.intent ?? old.intent, blocks: old.blocks + new.blocks)
        }
        var queue = PreparationQueue<Snapshot, Int>()
        queue.submit(.init(value: 1, blocks: [1]), waiting: [1], merge: merge)
        queue.submit(.init(value: 2, intent: "sent", blocks: [2]), waiting: [2], merge: merge)
        queue.submit(.init(value: 3, blocks: [3]), waiting: [3], merge: merge)
        queue.complete(3)
        let ready = queue.takeReady(merge: merge)
        #expect(ready?.value.value == 3)
        #expect(ready?.value.intent == "sent")
        #expect(ready?.value.blocks == [1, 2, 3])
        queue.submit(.init(value: 4, intent: "old", blocks: []), waiting: [4], merge: merge)
        queue.submit(.init(value: 5, intent: "new", blocks: []), waiting: [], merge: merge)
        #expect(queue.takeReady(merge: merge)?.value.intent == "new")
    }

    @Test func environmentChangesReplaceDependenciesWithoutReorderingSnapshots() {
        var queue = PreparationQueue<Int, String>()
        let generation = queue.submit(1, waiting: ["old-width"], merge: newer)
        queue.replaceWaiting(generation: generation, with: ["new-width"])
        queue.complete("old-width")
        #expect(queue.takeReady(merge: newer) == nil)
        queue.complete("new-width")
        #expect(queue.takeReady(merge: newer)?.generation == generation)
    }
}