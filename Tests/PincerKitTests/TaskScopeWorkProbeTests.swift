#if DEBUG
import Testing
@testable import PincerKit

@MainActor struct TaskScopeWorkProbeTests {
    @Test func scalarScopeIncludesChildrenAndExcludesDetachedTasks() async {
        let recorder = TaskScopeWorkRecorder()
        await TaskScopeWorkProbe.$recorder.withValue(recorder) {
            TaskScopeWorkProbe.recorder?.record()
            #expect(recorder.count == 1)
            await Task { TaskScopeWorkProbe.recorder?.record() }.value
            #expect(recorder.count == 2)
            let detachedHasScope = await Task.detached {
                TaskScopeWorkProbe.recorder?.record()
                return TaskScopeWorkProbe.recorder != nil
            }.value
            #expect(!detachedHasScope && recorder.count == 2)
        }
        #expect(TaskScopeWorkProbe.recorder == nil && recorder.count == 2)
    }
}
#endif
