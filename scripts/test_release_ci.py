#!/usr/bin/env python3
import sys
sys.dont_write_bytecode = True

import unittest
from check_release_ci import validated_run

SHA = "a" * 40


def run(**changes):
    return {"id": 1, "head_sha": SHA, "head_branch": "main", "event": "push",
            "status": "completed", "conclusion": "success", "html_url": "https://example.com/run", **changes}


class ReleaseCITests(unittest.TestCase):
    def test_exact_successful_main_commit_passes(self):
        self.assertEqual(validated_run([run()], SHA)["id"], 1)

    def test_other_commit_or_pr_does_not_authorize_upload(self):
        for candidate in (run(head_sha="b" * 40), run(event="pull_request"), run(head_branch="feature")):
            with self.subTest(candidate=candidate), self.assertRaises(ValueError):
                validated_run([candidate], SHA)

    def test_pending_failed_cancelled_and_skipped_are_rejected(self):
        for candidate in (run(status="in_progress", conclusion=None), run(conclusion="failure"),
                          run(conclusion="cancelled"), run(conclusion="skipped")):
            with self.subTest(candidate=candidate), self.assertRaises(ValueError):
                validated_run([candidate], SHA)

    def test_older_success_cannot_hide_a_newer_failure(self):
        with self.assertRaises(ValueError):
            validated_run([run(), run(id=2, conclusion="failure")], SHA)

    def test_no_run_fails_closed(self):
        with self.assertRaises(ValueError):
            validated_run([], SHA)


if __name__ == "__main__":
    unittest.main()
