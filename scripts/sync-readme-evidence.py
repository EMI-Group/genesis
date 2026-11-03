"""Update only the bounded Evidence block; Python 3.11+, standard library only."""
import argparse
from datetime import date
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
START = "<!-- evidence:start -->"
END = "<!-- evidence:end -->"
SNAPSHOT = ROOT / "docs/readme-evidence.snapshot.json"


def safe_url(value):
    url = urlsplit(value)
    if (url.scheme != "https" or url.netloc != "genesis.evox.group"
            or not url.path.startswith("/evidence/") or any(c in value for c in "\r\n<> ()")):
        raise ValueError(f"Unexpected Evidence URL: {value!r}")
    return value


def cell(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("Missing text in Evidence record")
    return (value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace("|", "&#124;").replace("[", "&#91;").replace("]", "&#93;")
            .replace("\n", " ").replace("\r", " "))


def normalize(payload):
    if payload.get("schema_version") != "1.0" or not payload.get("worlds"):
        raise ValueError("Unsupported or empty Evidence manifest")
    if payload.get("count") != len(payload["worlds"]):
        raise ValueError("Evidence count does not match records")
    worlds = []
    for record in payload["worlds"]:
        item = {key: record[key] for key in
                ("slug", "id", "title", "date", "url", "verification_results")}
        date.fromisoformat(item["date"])
        safe_url(item["url"])
        cell(item["title"])
        worlds.append(item)
    if len({w["slug"] for w in worlds}) != len(worlds):
        raise ValueError("Duplicate Evidence slug")
    return {"schema_version": "1.0", "count": len(worlds),
            "worlds": sorted(worlds, key=lambda w: w["slug"])}


def render(config, payload):
    featured = config["featured"]
    if len(featured) != 3 or len({f["slug"] for f in featured}) != 3:
        raise ValueError("Select exactly three distinct featured worlds")
    worlds = {w["slug"]: w for w in payload["worlds"]}
    lines = [START, "", "## Built with Genesis", "",
             "Selected software worlds developed with Genesis.", "",
             "| Project | What emerged | Reported result |",
             "| :-- | :-- | :-- |"]
    for entry in featured:
        world = worlds[entry["slug"]]
        matches = [v for v in world["verification_results"] if v["name"] == entry["verification"]]
        if len(matches) != 1:
            raise ValueError(f"Missing or ambiguous verification: {entry['slug']} / {entry['verification']}")
        metric = matches[0]
        lines.append(f"| [{cell(world['title'])}]({world['url']}) | {cell(entry['summary'])} | "
                     f"{cell(metric['result'])} {cell(metric['name'])} |")
    # Record dates determine recency; IDs provide a stable tie-break for same-day records.
    latest = max(worlds.values(), key=lambda w: (w["date"], w["id"], w["slug"]))
    lines += ["", f"Latest evidence: [{cell(latest['title'])}]({latest['url']}) · {latest['date']}", "",
              "[Explore all evidence →](https://genesis.evox.group/evidence/)", "", END]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true", help="Fetch published data and refresh the snapshot")
    parser.add_argument("--check", action="store_true", help="Fail if the README differs; never write files")
    args = parser.parse_args()
    config = json.loads((ROOT / "docs/readme-evidence.json").read_text(encoding="utf-8"))
    if args.refresh:
        request = Request(safe_url(config["source"]), headers={"User-Agent": "genesis-readme-sync/1.0"})
        with urlopen(request, timeout=30) as response:
            payload = normalize(json.load(response))
    else:
        payload = normalize(json.loads(SNAPSHOT.read_text(encoding="utf-8")))
    block = render(config, payload)
    readme = ROOT / "README.md"
    original = readme.read_text(encoding="utf-8")
    if original.count(START) != 1 or original.count(END) != 1 or original.index(START) >= original.index(END):
        raise ValueError("Expected one ordered pair of Evidence markers")
    updated = original[:original.index(START)] + block + original[original.index(END) + len(END):]
    if args.check:
        if updated != original:
            raise ValueError("README Evidence is stale; run python scripts/sync-readme-evidence.py")
    else:
        if args.refresh:
            SNAPSHOT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        if updated != original:
            readme.write_text(updated, encoding="utf-8")
    print(f"Evidence {'checked' if args.check else 'synced'}: 3 featured / {payload['count']} archived")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        sys.exit(f"Evidence sync failed: {error}")
