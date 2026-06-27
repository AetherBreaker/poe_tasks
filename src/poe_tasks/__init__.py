# Standard library imports
import os

# Third party imports
from poethepoet_tasks import TaskCollection

_SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts")


def _script_path(filename: str) -> str:
  return os.path.join(_SCRIPTS_DIR, filename).replace("\\", "/")


tasks = TaskCollection()

tasks.add(
  task_name="release",
  task_config={
    "help": ("Bump version, commit, tag, build, and publish to GitHub and SFTPyPI. Usage: poe release [major|minor|patch]"),
    "envfile": ".env",
    "cmd": f'bash "{_script_path("release.sh")}" ${{bump_type}} "${{notes}}"',
    "args": [
      {
        "name": "bump_type",
        "positional": True,
        "help": "Version component to bump: major, minor, or patch",
      },
      {
        "name": "notes",
        "positional": True,
        "default": "",
        "help": "Optional release notes for the GitHub release (omit to auto-generate from commits)",
      },
    ],
  },
)

tasks.add(
  task_name="fix-bash",
  task_config={
    "help": "Windows-only: configure this workspace so all VS Code terminals prefer Git Bash without changing global PATH",
    "cmd": f'powershell -NoProfile -ExecutionPolicy Bypass -File "{_script_path("fix-git-bash-workspace.ps1")}"',
  },
)

tasks.add(
  task_name="docker-pin-latest",
  task_config={
    "help": (
      "Auto-detect the docker compose file in the project root, fetch the latest "
      "released version of its PACKAGE_NAME from SFTPyPI, and update PACKAGE_VERSION in place."
    ),
    "cmd": f'bash "{_script_path("docker-pin-latest.sh")}"',
  },
)

tasks.add(
  task_name="rescind-release",
  task_config={
    "help": (
      "Fully rescind a release: removes the package from SFTPyPI, deletes the GitHub release, "
      "and removes the Git tag (local and remote). Defaults to the most recent release; "
      "when defaulting, also rewinds the local branch to the previous release commit "
      "(all changes from the release are kept in the working tree). "
      "Usage: poe rescind-release [version]"
    ),
    "envfile": ".env",
    "cmd": f'bash "{_script_path("rescind-release.sh")}" "${{version}}"',
    "args": [
      {
        "name": "version",
        "positional": True,
        "default": "",
        "help": "Version to rescind (e.g. 1.2.3). Defaults to the most recent release.",
      },
    ],
  },
)
