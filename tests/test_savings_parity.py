"""Pins savings.py to the behaviour recorded in savings_parity.json.

The identical fixture lives in arcade-video-scanner, which keeps its own copy of
this math for its dashboard. Both repos test against the same file, so a change
on either side fails the build on both.

DO NOT regenerate this fixture to make a failure go away. A failure means the
two implementations have diverged; decide deliberately which behaviour is
correct, change both, and update the fixture in both repos in the same breath.
"""
import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from savings import estimate_savings_pct  # noqa: E402

FIXTURE = REPO_ROOT / "savings_parity.json"
CASES = json.loads(FIXTURE.read_text())


def test_fixture_is_not_empty():
    assert len(CASES) >= 18


@pytest.mark.parametrize("case", CASES, ids=lambda c: f"{c['source_codec']}->{c['target_codec']}@{c['height']}p/{c['source_kbps']}k")
def test_matches_fixture(case):
    result = estimate_savings_pct(
        float(case["source_kbps"]), case["height"], float(case["fps"]),
        case["source_codec"], case["target_codec"])
    if case["expected"] is None:
        assert result is None
        return
    assert result is not None
    saved, known = result
    assert saved == pytest.approx(case["expected"][0], abs=1e-6)
    assert known is case["expected"][1]
