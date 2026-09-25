#!/usr/bin/env python3
"""Build an isolated Codex model catalog for one VibeShare connection."""
import json
import sys
import urllib.request
from pathlib import Path

root = Path.home() / ".vibeshare-codex-dad"
conn_id = (root / "connection-id").read_text().strip()
if not conn_id:
    sys.exit("codex-dad: missing connection ID")

with urllib.request.urlopen("http://127.0.0.1:8799/api/connections", timeout=5) as response:
    connections = json.load(response)
matches = [c for c in connections if c.get("id") == conn_id]
if len(matches) != 1 or not matches[0].get("online") or matches[0].get("revoked"):
    sys.exit("codex-dad: Dad's VibeShare connection is offline")
models = [m for m in matches[0].get("models", []) if "image" not in m.lower()]
if not models:
    sys.exit("codex-dad: Dad is online but sharing no chat models")

rows = []
for model in sorted(set(models)):
    rows.append({
        "model": model,
        "provider": "generic-chat-completion-api",
        "baseUrl": "http://127.0.0.1:8788/v1",
        "apiKey": "vibeshare",
        # The separate slug also prevents the shim's gpt-5.5 special case from
        # routing to the Mac owner's personal ChatGPT account.
        "displayName": "Dad " + model,
        "maxContextLimit": 400000 if model.startswith("gpt-") else 128000,
        "extraHeaders": {"X-VibeShare-Connection-ID": conn_id},
    })

root.mkdir(mode=0o700, exist_ok=True)
settings = root / "models.json"
settings.write_text(json.dumps({"customModels": rows}, indent=2) + "\n")
settings.chmod(0o600)

sys.path.insert(0, str(Path.home() / "Documents/codex-shim"))
from codex_shim.settings import FactorySettings
from codex_shim.catalog import catalog_entry

entries = []
for model in FactorySettings(settings).load():
    entry = catalog_entry(model)
    entry["description"] = f"{model.model} via Dad's VibeShare host"
    entries.append(entry)
catalog = root / "catalog.json"
catalog.write_text(json.dumps({"models": entries}, indent=2) + "\n")
catalog.chmod(0o600)
for model in models:
    print(model)
