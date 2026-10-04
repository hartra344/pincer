#if DEBUG
import Synchronization

/// Payload-free, constant-size diagnostic counter for actual work in a task-local scope.
/// Inherited child tasks share the scope; detached or unrelated tasks do not.
package final class TaskScopeWorkRecorder: Sendable {
    private let counter = Mutex<Int>(0)
    package init() {}
    package var count: Int { self.counter.withLock { $0 } }
    package func record() { self.counter.withLock { $0 += 1 } }
}

package enum TaskScopeWorkProbe {
    @TaskLocal package static var recorder: TaskScopeWorkRecorder?
}
#endif
