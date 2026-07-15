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
    "help": "Bump version, commit, tag, build, and publish to GitHub and SFTPyPI.",
    "envfile": ".env",
    "cmd": f'bash "{_script_path("release.sh")}" ${{bump_types}}',
    "args": [
      {
        "name": "bump_types",
        "positional": True,
        "nargs": "+",
        "help": (
          "One or more version components to bump (e.g. 'major alpha'). "
          "Valid values: major, minor, patch, stable, alpha, beta, rc, post, dev. "
          "Optionally append release notes as the final argument — if the last word "
          "does not match a bump type it is treated as the GitHub release notes "
          "(omit to auto-generate from commits)."
        ),
      },
      {
        "name": "force",
        "options": ["--force", "-f"],
        "type": "boolean",
        "default": False,
        "help": "Skip the uncommitted changes check and proceed without prompting",
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
  task_name="release-and-pin",
  task_config={
    "help": (
      "Bump version, commit, tag, build, and publish to GitHub and SFTPyPI, "
      "then pin the docker-compose package version. "
      "Accepts the same arguments as the release task "
      "(one or more bump types, optional trailing release notes, --force)."
    ),
    "envfile": ".env",
    "sequence": [
      "release $POE_EXTRA_ARGS",
      "docker-pin-latest",
    ],
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
