from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class AgentContextTests(unittest.TestCase):
    def test_calla_workspace_keeps_only_what_must_outrank_a_persona(self) -> None:
        """The workspace exists to beat a general-agent persona, not to teach.

        It used to restate the whole loop — capture once, advance planned steps
        locally, crop on mismatch — which the plugin's teaching contract also
        says. Two copies drift, and this one drifted into being wrong: planned
        steps do not advance without the model any more. What has to survive
        here is only what a helpful-assistant persona would otherwise override.
        """
        context = (ROOT / "agent-workspace" / "AGENTS.md").read_text(encoding="utf-8")
        for required in (
            "tutor_*",
            "never in\nprose",
            "Point; never click",
            "Never store or repeat screen",
        ):
            self.assertIn(required, context)
        # The loop belongs to the teaching contract, in one place.
        for duplicated in ("tutor_observe", "tutor_guide", "same session id", "one tight crop"):
            self.assertNotIn(duplicated, context)

    def test_canonical_context_separates_gateway_and_mac_acceptance(self) -> None:
        context = (ROOT / "docs" / "agent-context.md").read_text(encoding="utf-8")
        for required in (
            "apps/tutor/integrations/openclaw",
            "loopback-bound",
            "Tailscale Serve",
            "tutor.host",
            "~/.openclaw/tutor",
            "never writes a chat recipe",
            "Screen Recording",
            "real TutorHost teaching round trip",
        ):
            self.assertIn(required, context)


if __name__ == "__main__":
    unittest.main()
