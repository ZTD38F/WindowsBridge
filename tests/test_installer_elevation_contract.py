from pathlib import Path
import unittest


INSTALLER = Path(__file__).parents[1] / "install.ps1"


class InstallerElevationContractTests(unittest.TestCase):
    def test_uac_consent_precedes_machine_writes(self) -> None:
        script = INSTALLER.read_text(encoding="utf-8")

        consent_boundary = 'if (-not (Test-Administrator)) { Invoke-Elevated }'
        first_machine_write = (
            'New-Item -ItemType Directory -Force '
            '-Path $Root,$Bin,$Logs,$Releases,$Runtime,$Cache,$Management,$State,$Secrets'
        )
        self.assertIn(consent_boundary, script)
        self.assertIn(first_machine_write, script)
        self.assertLess(script.index(consent_boundary), script.index(first_machine_write))

    def test_elevation_is_visible_waited_runas(self) -> None:
        script = INSTALLER.read_text(encoding="utf-8")
        start = script.index("function Invoke-Elevated")
        end = script.index("function Get-ReleaseAsset", start)
        elevation = script[start:end]

        self.assertIn(
            '$p = Start-Process -FilePath "powershell.exe" -Verb RunAs '
            '-ArgumentList $args -Wait -PassThru',
            elevation,
        )
        self.assertIn("exit $p.ExitCode", elevation)
        self.assertNotIn("-WindowStyle Hidden", elevation)
        self.assertNotIn("runas.exe", elevation.lower())


if __name__ == "__main__":
    unittest.main()
