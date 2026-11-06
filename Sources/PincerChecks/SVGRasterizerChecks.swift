@testable import PincerUI

/// #1095: a stalled iOS SVG render (cold WebKit) gets up to three fresh web views, all inside one total
/// budget that covers the CI trace (180 s + 45 s + a quick third try); nothing else retries.
@MainActor
func runSVGRasterizerRetryChecks() {
    let retry = SVGWebRenderRetry.self
    let left = Duration.seconds(60)
    check(retry.triesAgain(afterAttempt: 1, gotImage: false, stalled: true, cancelled: false, remaining: left)
          && retry.triesAgain(afterAttempt: 2, gotImage: false, stalled: true, cancelled: false, remaining: left)
          && !retry.triesAgain(afterAttempt: 3, gotImage: false, stalled: true, cancelled: false, remaining: left),
          "a stalled SVG render tries a fresh web view up to three times in all")
    check(!retry.triesAgain(afterAttempt: 1, gotImage: true, stalled: false, cancelled: false, remaining: left)
          && !retry.triesAgain(afterAttempt: 1, gotImage: false, stalled: false, cancelled: false, remaining: left)
          && !retry.triesAgain(afterAttempt: 1, gotImage: false, stalled: true, cancelled: true, remaining: left),
          "a finished, failed or cancelled SVG render doesn't retry")
    let now = ContinuousClock.now
    check(!retry.triesAgain(afterAttempt: 1, gotImage: false, stalled: true, cancelled: false, remaining: .zero)
          && retry.totalBudget > .seconds(180 + 45 + 30) && retry.totalBudget <= .seconds(2 * (180 + 45))
          && retry.stepDeadline(now: now, timeout: .seconds(180), renderDeadline: now + .seconds(10)) == now + .seconds(10),
          "every attempt fits one total SVG render budget (\(retry.totalBudget))")
}
