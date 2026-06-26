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
