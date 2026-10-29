"""Apply the MacGameDeck patch to pinned DepotDownloader 3.4.0 sources.
Already-patched corresponding sources are included in Source/.
"""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parent
patch = root / "integration.patch"
def run(reverse=False, dry=True):
    args = ["patch", "--batch", "-p1", "-i", str(patch)]
    if reverse: args += ["--reverse"]
    else: args += ["--forward"]
    if dry: args += ["--dry-run"]
    return subprocess.run(args, cwd=root / "Source", capture_output=True, text=True)
forward = run()
if forward.returncode == 0:
    result = run(dry=False)
    if result.returncode: raise RuntimeError(result.stdout + result.stderr)
    print("MacGameDeck integration applied.")
elif run(reverse=True).returncode == 0:
    print("MacGameDeck integration is already applied.")
else:
    raise RuntimeError("Unexpected sources: restore the pinned 3.4.0 source tree before applying the patch.")
