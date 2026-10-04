#if DEBUG
import PincerKit

@MainActor func runAvatarPhaseDiagnosticsChecks() {
    let value = AvatarPhaseDiagnostics()
    value.enter(.overlays, ready: true, width: .infinity, height: .greatestFiniteMagnitude)
    check(value.report().contains("width=0.0 height=10000.0"), "avatar diagnostics bound nonfinite/oversized frame scalars")
    value.enter(.complete, ready: true)
    check(value.report().contains("phase=complete") && !value.report().contains("phase=overlays") && value.report().utf8.count < 180,
          "avatar diagnostic replaces one fixed metadata snapshot without payload or history retention")
}
#endif
