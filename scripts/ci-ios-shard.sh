#!/usr/bin/env bash
# Prints the -only-testing arguments for one shard of the iOS simulator tests (tests.yml):
#   hosted  TranscriptUIKitHostedTests, the longest suite, alone
#   lists   every other transcript and composer suite
#   svg     SVGRasterizerTests, which wait on a cold WebKit
# A suite added to PincerUITests that should run on iOS belongs in one of these lists.
set -euo pipefail
case "${1:-}" in
  hosted) suites=(TranscriptUIKitHostedTests) ;;
  lists) suites=(
    TranscriptUIKitLayoutTests TranscriptDynamicTypeParityTests TranscriptPremeasureTests
    TranscriptListControllerTests TranscriptMeasureQueueTests TranscriptLayoutCacheTests
    TranscriptWidthFreezeTests TranscriptFindTrimTests TranscriptNavigationTests
    TranscriptAccessibilityActionTests ScrollToBottomTests StreamingRenderingTests
    InlineMathOffMainTests ComposerSynchronousSizingUIKitTests) ;;
  svg) suites=(SVGRasterizerTests) ;;
  *) echo "usage: $0 hosted|lists|svg" >&2; exit 2 ;;
esac
printf -- '-only-testing:PincerUITests/%s\n' "${suites[@]}"
