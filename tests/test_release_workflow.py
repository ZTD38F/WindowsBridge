from pathlib import Path
import unittest


WORKFLOW = Path(__file__).parents[1] / ".github" / "workflows" / "release.yml"


class ReleaseWorkflowGateTests(unittest.TestCase):
    def test_integration_tests_run_before_bundle_and_publish(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        gate = workflow.index("- name: Exercise release integration gates")
        bundle = workflow.index("- name: Build immutable release bundle")
        publish = workflow.index("- name: Publish stable release")

        self.assertLess(gate, bundle)
        self.assertLess(bundle, publish)

        gate_block = workflow[gate:bundle]
        required = (
            "python -m unittest discover -s tests -v",
            r".\tests\update_recovery_integration.ps1",
            r".\tests\update_mutex_integration.ps1",
            r".\tests\update_tunnel_continuity_integration.ps1",
        )
        for command in required:
            with self.subTest(command=command):
                self.assertIn(command, gate_block)

        self.assertGreaterEqual(
            gate_block.count("if ($LASTEXITCODE -ne 0)"),
            len(required),
        )


if __name__ == "__main__":
    unittest.main()
