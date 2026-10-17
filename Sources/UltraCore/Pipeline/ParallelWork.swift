import Dispatch
import Foundation
import Synchronization

/// A small number of workers consume batches, instead of enqueueing one
/// dispatch task and taking a result lock for every node.
func parallelWork<Input: Sendable, Output: Sendable>(
    _ inputs: [Input],
    transform: @escaping @Sendable (Input) -> Output
) -> [Output] {
    guard !inputs.isEmpty else { return [] }
    let results = ParallelResults<Output>(count: inputs.count)
    let group = DispatchGroup()
    for _ in 0..<min(4, inputs.count) {
        Pipeline.displayQueue.async(group: group) {
            while let range = results.claim(count: inputs.count) {
                #if canImport(ObjectiveC)
                autoreleasepool {
                    results.store(range: range, values: range.map { transform(inputs[$0]) })
                }
                #else
                results.store(range: range, values: range.map { transform(inputs[$0]) })
                #endif
            }
        }
    }
    group.wait()
    return results.finish()
}

private final class ParallelResults<Value: Sendable>: Sendable {
    private struct State {
        var next = 0
        var values: [Value?]
    }
    private let state: Mutex<State>

    init(count: Int) {
        state = Mutex(State(values: Array(repeating: nil, count: count)))
    }

    func claim(count: Int) -> Range<Int>? {
        state.withLock { state in
            guard state.next < count else { return nil }
            let start = state.next
            state.next = min(count, start + 16)
            return start..<state.next
        }
    }

    func store(range: Range<Int>, values: [Value]) {
        state.withLock { state in
            for (index, value) in zip(range, values) {
                state.values[index] = .some(value)
            }
        }
    }

    func finish() -> [Value] {
        state.withLock { $0.values.map { $0! } }
    }
}