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


    def test_failed_and_abandoned_stages_are_cleaned_safely(self):
        cleanup_start = UPDATER.index("function Remove-StaleReleaseStages")
        cleanup_end = UPDATER.index("function Stage-Release", cleanup_start)
        cleanup = UPDATER[cleanup_start:cleanup_end]
        self.assertIn('AddHours(-24)', cleanup)
        self.assertIn('Where-Object { $_.Name -like ".stage-*"', cleanup)
        self.assertIn("Remove-Item -LiteralPath $_.FullName", cleanup)

        stage_start = cleanup_end
        stage_end = UPDATER.index("function Ensure-NewTopology", stage_start)
        stage = UPDATER[stage_start:stage_end]
        finally_block = stage.index("} finally {")
        guarded_delete = stage.index("Remove-Item -LiteralPath $stage", finally_block)
        self.assertLess(finally_block, guarded_delete)

    def test_stale_cleanup_runs_only_after_update_mutex_is_acquired(self):
        lock = UPDATER.index("$mutex.WaitOne(0)")
        cleanup = UPDATER.index("Remove-StaleReleaseStages", lock)
        resolution = UPDATER.index("$currentSha=", cleanup)
        self.assertLess(lock, cleanup)
        self.assertLess(cleanup, resolution)


if __name__ == "__main__":
    unittest.main()
