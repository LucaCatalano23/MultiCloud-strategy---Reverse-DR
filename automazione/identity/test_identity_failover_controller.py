import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("identity_failover_controller.py")
SPEC = importlib.util.spec_from_file_location("identity_failover_controller", MODULE_PATH)
assert SPEC and SPEC.loader
identity = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = identity
SPEC.loader.exec_module(identity)


class PolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = identity.Policy(failure_threshold=3, recovery_threshold=2)

    def test_entra_remains_active_before_failure_threshold(self) -> None:
        result = self.policy.choose(identity.IdentityState.ENTRA_ACTIVE, 2, 0, 2, False)
        self.assertEqual(identity.IdentityState.ENTRA_ACTIVE, result)

    def test_failover_requires_healthy_keycloak(self) -> None:
        result = self.policy.choose(identity.IdentityState.ENTRA_ACTIVE, 3, 0, 1, False)
        self.assertEqual(identity.IdentityState.ENTRA_ACTIVE, result)

    def test_failover_to_keycloak_is_automatic(self) -> None:
        result = self.policy.choose(identity.IdentityState.ENTRA_ACTIVE, 3, 0, 2, False)
        self.assertEqual(identity.IdentityState.KEYCLOAK_ACTIVE, result)

    def test_entra_recovery_waits_for_approval(self) -> None:
        result = self.policy.choose(identity.IdentityState.KEYCLOAK_ACTIVE, 0, 2, 10, False)
        self.assertEqual(identity.IdentityState.ENTRA_RECOVERED_AWAITING_APPROVAL, result)

    def test_recovered_entra_does_not_fail_back_without_approval(self) -> None:
        result = self.policy.choose(
            identity.IdentityState.ENTRA_RECOVERED_AWAITING_APPROVAL, 0, 10, 10, False
        )
        self.assertEqual(identity.IdentityState.ENTRA_RECOVERED_AWAITING_APPROVAL, result)

    def test_approved_failback_returns_to_entra(self) -> None:
        result = self.policy.choose(
            identity.IdentityState.ENTRA_RECOVERED_AWAITING_APPROVAL, 0, 3, 10, True
        )
        self.assertEqual(identity.IdentityState.ENTRA_ACTIVE, result)

    def test_entra_failure_while_waiting_cancels_recovery_state(self) -> None:
        result = self.policy.choose(
            identity.IdentityState.ENTRA_RECOVERED_AWAITING_APPROVAL, 1, 0, 10, False
        )
        self.assertEqual(identity.IdentityState.KEYCLOAK_ACTIVE, result)


if __name__ == "__main__":
    unittest.main()
