from pathlib import Path
import hashlib, json
resources = Path(__file__).resolve().parents[2] / 'Sources' / 'MacGameDock' / 'Resources'
root = resources / 'SteamRuntime'
entries = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
           for p in sorted(root.rglob('*')) if p.is_file()}
(resources / 'helper-files.json').write_text(json.dumps(entries, indent=2) + '\n')
