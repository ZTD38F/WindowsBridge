from pathlib import Path
import unittest


UPDATER = (Path(__file__).resolve().parents[1] / "update.ps1").read_text(encoding="utf-8-sig")


class UpdateMaintenanceContractTest(unittest.TestCase):
    def test_current_generation_retries_deferred_maintenance_before_exit(self):
        condition = "if(-not $Force -and $currentSha -eq $targetSha){"
        start = UPDATER.index(condition)
        end = UPDATER.index("\n\n    Ensure-NewTopology $targetSha", start)
        current_block = UPDATER[start:end]

        maintenance = current_block.index("Invoke-CurrentGenerationMaintenance $targetSha")
        completion_log = current_block.index("deferred maintenance checked")
        exit_statement = current_block.index("exit 0")

        self.assertLess(maintenance, completion_log)
        self.assertLess(completion_log, exit_statement)

    def test_maintenance_stages_immutable_generation_before_components(self):
        start = UPDATER.index("function Invoke-CurrentGenerationMaintenance")
        end = UPDATER.index(
            'if (-not (Test-Path $Config) -or -not (Test-Path $Current))',
            start,
        )
        helper = UPDATER[start:end]

        topology = helper.index("Ensure-NewTopology $TargetSha")
        stage = helper.index("Stage-Release $TargetSha")
        supervisor = helper.index("Update-Supervisor")
        transport = helper.index("Update-Transport $TargetSha")

        self.assertLess(topology, stage)
        self.assertLess(stage, supervisor)
        self.assertLess(supervisor, transport)


if __name__ == "__main__":
    unittest.main()
