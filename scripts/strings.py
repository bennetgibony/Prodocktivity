#!/usr/bin/env python3
"""String Catalog without Xcode.

  scripts/strings.py extract           adds new interface strings from Sources/ to Resources/Localizable.xcstrings
                                       (keeps every translation already there, marks unused keys stale)
  scripts/strings.py compile <dir>     writes <dir>/<lang>.lproj/Localizable.strings for every language in the catalog

Only plain literals are found (Text("…"), Button("…"), .help("…") and friends); strings with
interpolation are added by hand, with %@ / %lld where Xcode would put them.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"
CALLS = r'(?:Text|Button|Toggle|Label|Section|Picker|LabeledContent|Menu|Link|TextField|SectionHeader\(title:|\.help|\.accessibilityLabel|navigationTitle)'
PATTERN = re.compile(CALLS + r'\(\s*"((?:[^"\\]|\\.)*)"')


def load():
    if CATALOG.exists():
        return json.loads(CATALOG.read_text())
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def extract():
    catalog = load()
    found = set()
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        for m in PATTERN.finditer(path.read_text()):
            s = m.group(1)
            if "\\(" in s or not s.strip():
                continue
            found.add(s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\"))
    strings = catalog["strings"]
    added = 0
    for key in sorted(found):
        if key not in strings:
            strings[key] = {}
            added += 1
        strings[key].pop("extractionState", None)
    for key, entry in strings.items():
        if key not in found and not entry.get("localizations"):
            entry["extractionState"] = "stale"
    catalog["strings"] = dict(sorted(strings.items()))
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"{len(found)} strings in the code, {added} new")


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def compile_to(out):
    catalog = load()
    by_lang = {}
    for key, entry in catalog["strings"].items():
        for lang, loc in entry.get("localizations", {}).items():
            unit = loc.get("stringUnit", {})
            if unit.get("value") is not None and unit.get("state", "translated") != "new":
                by_lang.setdefault(lang, {})[key] = unit["value"]
    for lang, table in by_lang.items():
        folder = pathlib.Path(out) / f"{lang}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        lines = [f'"{escape(k)}" = "{escape(v)}";' for k, v in sorted(table.items())]
        (folder / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"compiled {', '.join(sorted(by_lang)) or 'no translations (English is built in)'}")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "extract":
        extract()
    elif len(sys.argv) == 3 and sys.argv[1] == "compile":
        compile_to(sys.argv[2])
    else:
        sys.exit(__doc__)
