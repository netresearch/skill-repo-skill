#!/bin/bash
# migrate-licensing.sh - Migrate a skill repo from single LICENSE to split licensing
# Usage: ./migrate-licensing.sh [<repo-root-path>]
#        ./migrate-licensing.sh --help
set -euo pipefail

usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

REPO_DIR="${1:-.}"
if [[ ! -d "$REPO_DIR" ]]; then
    echo "not a directory: $REPO_DIR" >&2
    exit 2
fi

# The copyright years come from the repository, not from this file: the year of
# its first commit through the current year, or the current year alone when the
# two are the same or the directory has no history.
CURRENT_YEAR="$(date +%Y)"
FIRST_YEAR="$(git -C "$REPO_DIR" log --reverse --format=%ad --date=format:%Y 2>/dev/null | head -n 1 || true)"
FIRST_YEAR="${FIRST_YEAR:-$CURRENT_YEAR}"
if [[ "$FIRST_YEAR" == "$CURRENT_YEAR" ]]; then
    YEAR="$CURRENT_YEAR"
else
    YEAR="$FIRST_YEAR-$CURRENT_YEAR"
fi

echo "Migrating licensing in: $REPO_DIR"

# 1. Create LICENSE-MIT
if [[ -f "$REPO_DIR/LICENSE" ]]; then
    if grep -q "GNU GENERAL PUBLIC LICENSE" "$REPO_DIR/LICENSE"; then
        echo "INFO: Repo has GPL license — creating MIT from scratch"
        cat > "$REPO_DIR/LICENSE-MIT" << MITEOF
MIT License

Copyright (c) $YEAR Netresearch DTT GmbH

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
MITEOF
    else
        # Existing MIT — copy it and extend its own year range to the current
        # year. The holder and the start year are the licence's, never ours. A
        # range already present is extended, not nested: 2024-2025 becomes
        # 2024-<current>, not 2024-<current>-2025.
        cp "$REPO_DIR/LICENSE" "$REPO_DIR/LICENSE-MIT"
        if ! grep -qE "Copyright \(c\) ([0-9]{4}-)?$CURRENT_YEAR\b" "$REPO_DIR/LICENSE-MIT"; then
            sed -i -E "s/Copyright \(c\) ([0-9]{4})(-[0-9]{4})?/Copyright (c) \1-$CURRENT_YEAR/" "$REPO_DIR/LICENSE-MIT"
        fi
    fi
    # Stage removal of old LICENSE
    git -C "$REPO_DIR" rm -f LICENSE 2>/dev/null || rm -f "$REPO_DIR/LICENSE"
elif [[ -f "$REPO_DIR/LICENSE-MIT" ]]; then
    # Already migrated. Writing it again from scratch would replace a copyright
    # holder the first run deliberately preserved with Netresearch's.
    echo "INFO: LICENSE-MIT already exists — leaving it untouched"
else
    echo "INFO: No LICENSE found — creating LICENSE-MIT from scratch"
    cat > "$REPO_DIR/LICENSE-MIT" << MITEOF
MIT License

Copyright (c) $YEAR Netresearch DTT GmbH

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
MITEOF
fi

# 2. Create LICENSE-CC-BY-SA-4.0
cat > "$REPO_DIR/LICENSE-CC-BY-SA-4.0" << CCEOF
Creative Commons Attribution-ShareAlike 4.0 International

Copyright (c) $YEAR Netresearch DTT GmbH

This work is licensed under the Creative Commons Attribution-ShareAlike 4.0
International License. To view a copy of this license, visit
https://creativecommons.org/licenses/by-sa/4.0/ or send a letter to
Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

You are free to:
- Share: copy and redistribute the material in any medium or format
- Adapt: remix, transform, and build upon the material for any purpose,
  even commercially

Under the following terms:
- Attribution: You must give appropriate credit, provide a link to the
  license, and indicate if changes were made.
- ShareAlike: If you remix, transform, or build upon the material, you
  must distribute your contributions under the same license as the original.
CCEOF

# 3. Update composer.json and the plugin manifest.
#
# The root plugin.json is the source of truth; .claude-plugin/plugin.json is
# generated from it by sync-plugin-manifest.sh, which would overwrite an edit
# made to the copy. So the root is edited and the copy regenerated. Only a
# repository that has no root manifest yet gets the copy edited directly.
# Each file keeps its own indentation, so the edit is one line and not a
# reformat of the whole document.
python3 - "$REPO_DIR" << 'PYEOF'
import json, os, re, sys
repo_dir = sys.argv[1]

manifests = ["composer.json"]
if os.path.isfile(os.path.join(repo_dir, "plugin.json")):
    manifests.append("plugin.json")
elif os.path.isfile(os.path.join(repo_dir, ".claude-plugin", "plugin.json")):
    manifests.append(os.path.join(".claude-plugin", "plugin.json"))

for rel_path in manifests:
    full_path = os.path.join(repo_dir, rel_path)
    if not os.path.isfile(full_path):
        continue
    with open(full_path) as f:
        text = f.read()
    m = re.search(r'^([ \t]+)"', text, re.M)
    indent = m.group(1) if m else "  "
    data = json.loads(text)
    data['license'] = '(MIT AND CC-BY-SA-4.0)'
    with open(full_path, 'w') as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)
        f.write('\n')
    print(f"Updated {rel_path} license")
PYEOF

SYNC="$(dirname "$0")/sync-plugin-manifest.sh"
if [[ -f "$REPO_DIR/plugin.json" && -f "$REPO_DIR/.claude-plugin/plugin.json" ]]; then
    if [[ -f "$SYNC" ]]; then
        bash "$SYNC" --repo "$REPO_DIR"
    else
        echo "WARN: .claude-plugin/plugin.json not regenerated — run sync-plugin-manifest.sh"
    fi
fi

# 5. Update README.md license section
if [[ -f "$REPO_DIR/README.md" ]]; then
    python3 - "$REPO_DIR" << 'PYEOF'
import re, sys

repo_dir = sys.argv[1] if len(sys.argv) > 1 else "."
readme_path = f"{repo_dir}/README.md"

with open(readme_path, 'r') as f:
    content = f.read()

# Replace license section
new_license = """## License

This project uses split licensing:

- **Code** (scripts, workflows, configs): [MIT](LICENSE-MIT)
- **Content** (skill definitions, documentation, references): [CC-BY-SA-4.0](LICENSE-CC-BY-SA-4.0)

See the individual license files for full terms."""

# Match ## License section until next ## heading or --- or end of file
pattern = r'## License\n.*?(?=\n## |\n---|\Z)'
content = re.sub(pattern, new_license, content, flags=re.DOTALL)

# Fix structure diagrams
content = re.sub(
    r'├── LICENSE\s+# (?:MIT|GPL[^\n]*)',
    '├── LICENSE-MIT           # Code license (MIT)\n├── LICENSE-CC-BY-SA-4.0  # Content license (CC-BY-SA-4.0)',
    content
)

with open(readme_path, 'w') as f:
    f.write(content)
PYEOF
    echo "Updated README.md license section"
fi

echo "Done! Review changes with: git -C $REPO_DIR diff"
