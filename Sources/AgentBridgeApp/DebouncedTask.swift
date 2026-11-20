import Foundation

/// Runs only the latest scheduled operation, after a short quiet period. Each
/// `schedule` or `cancel` supersedes the operation before it; an operation that
/// already started is told through `isCurrent` that it should stop updating state.
@MainActor
final class DebouncedTask {
    let delayNanoseconds: UInt64
    private var generation = 0
    private var task: Task<Void, Never>?

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func schedule(_ operation: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void) {
        generation += 1
        let scheduled = generation
        task?.cancel()
        let delay = delayNanoseconds
        task = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled, self.generation == scheduled else { return }
            await operation { [weak self] in
                !Task.isCancelled && self?.generation == scheduled
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
