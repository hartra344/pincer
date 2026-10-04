#if DEBUG
import PincerKit

/// Probe scope semantics only. Actual UI Key/split tests verify the renderer binding.
@MainActor func runTaskScopeWorkProbeChecks() async {
    let recorder = TaskScopeWorkRecorder()
    await TaskScopeWorkProbe.$recorder.withValue(recorder) {
        TaskScopeWorkProbe.recorder?.record()
        check(recorder.count == 1, "shared scalar probe observes current owned scope")
        await Task { TaskScopeWorkProbe.recorder?.record() }.value
        check(recorder.count == 2, "ordinary child task inherits the same owned scope")
        let detachedHasScope = await Task.detached {
            TaskScopeWorkProbe.recorder?.record()
            return TaskScopeWorkProbe.recorder != nil
        }.value
        check(!detachedHasScope && recorder.count == 2,
              "detached unrelated work cannot contaminate owned scalar count")
    }
    TaskScopeWorkProbe.recorder?.record()
    check(TaskScopeWorkProbe.recorder == nil && recorder.count == 2,
          "scope ends without a global recorder or payload retention")
}
#endif
