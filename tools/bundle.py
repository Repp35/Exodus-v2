#!/usr/bin/env python3
"""Build the single-file distribution from the source loader's manifest."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
source_root = root / "exodus hub"
loader = (source_root / "loader.luau").read_text(encoding="utf-8")
manifest = re.findall(r'^\s*\{\s*"([^"]+)",\s*"([^"]+)"\s*\},?\s*$', loader, re.MULTILINE)
if not manifest:
    raise SystemExit("Manifesto do loader não encontrado")

parts = ["-- Exodus v3: arquivo gerado por tools/bundle.py. Não edite diretamente.\n", "local modules = {}\n"]
for name, path in manifest:
    code = (source_root / path).read_text(encoding="utf-8")
    parts.append(f'\nmodules["{name}"] = (function()\n{code}\nend)()\n')
parts.append(f"\nlocal function launch(...)\n{loader}\nend\nreturn launch(modules)\n")
(root / "Exodus-v3.luau").write_text("".join(parts), encoding="utf-8", newline="\n")
