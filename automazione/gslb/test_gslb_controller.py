import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("gslb_controller.py")
SPEC = importlib.util.spec_from_file_location("gslb_controller", MODULE_PATH)
assert SPEC and SPEC.loader
gslb = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = gslb
SPEC.loader.exec_module(gslb)


class PolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = gslb.Policy(failure_threshold=3, recovery_threshold=2, auto_failback=True)

    def test_keeps_production_before_failure_threshold(self) -> None:
        selected = self.policy.choose(gslb.Site.PRODUCTION, 2, 0, 2)
        self.assertEqual(gslb.Site.PRODUCTION, selected)

    def test_does_not_fail_over_when_dr_is_not_healthy(self) -> None:
        selected = self.policy.choose(gslb.Site.PRODUCTION, 3, 0, 1)
        self.assertEqual(gslb.Site.PRODUCTION, selected)

    def test_fails_over_after_primary_failures_and_dr_recovery(self) -> None:
        selected = self.policy.choose(gslb.Site.PRODUCTION, 3, 0, 2)
        self.assertEqual(gslb.Site.DR, selected)

    def test_fails_back_only_after_primary_recovery(self) -> None:
        self.assertEqual(gslb.Site.DR, self.policy.choose(gslb.Site.DR, 0, 1, 3))
        self.assertEqual(gslb.Site.PRODUCTION, self.policy.choose(gslb.Site.DR, 0, 2, 3))

    def test_can_disable_automatic_failback(self) -> None:
        policy = gslb.Policy(failure_threshold=3, recovery_threshold=2, auto_failback=False)
        selected = policy.choose(gslb.Site.DR, 0, 10, 10)
        self.assertEqual(gslb.Site.DR, selected)


class ZoneTest(unittest.TestCase):
    def test_renders_selected_address_and_ttl(self) -> None:
        zone = gslb._render_zone(1234, 30, "192.0.2.10")
        self.assertIn("1234 ; serial", zone)
        self.assertIn("$TTL 30", zone)
        self.assertIn("app IN A 192.0.2.10", zone)


if __name__ == "__main__":
    unittest.main()
