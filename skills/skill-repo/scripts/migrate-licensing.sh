#!/bin/bash
# migrate-licensing.sh - Migrate a skill repo from single LICENSE to split licensing
# Usage: ./migrate-licensing.sh <repo-root-path>
set -euo pipefail

REPO_DIR="${1:-.}"
YEAR="2025-2026"

echo "Migrating licensing in: $REPO_DIR"

# 1. Create LICENSE-MIT
if [[ -f "$REPO_DIR/LICENSE" ]]; then
    if grep -q "GNU GENERAL PUBLIC LICENSE" "$REPO_DIR/LICENSE"; then
        echo "INFO: Repo has GPL license — creating MIT from scratch"
        cat > "$REPO_DIR/LICENSE-MIT" << 'MITEOF'
MIT License

Copyright (c) 2025-2026 Netresearch DTT GmbH

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
        # Existing MIT — copy and update year
        cp "$REPO_DIR/LICENSE" "$REPO_DIR/LICENSE-MIT"
        if ! grep -q "2026" "$REPO_DIR/LICENSE-MIT"; then
            sed -i -E "s/Copyright \(c\) ([0-9]{4})/Copyright (c) \1-2026/" "$REPO_DIR/LICENSE-MIT"
        fi
    fi
    # Stage removal of old LICENSE
    git -C "$REPO_DIR" rm -f LICENSE 2>/dev/null || rm -f "$REPO_DIR/LICENSE"
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

# 3. Update composer.json and plugin.json
python3 - "$REPO_DIR" << 'PYEOF'
import json, sys, os
repo_dir = sys.argv[1]

for rel_path, label in [("composer.json", "composer.json"), (".claude-plugin/plugin.json", "plugin.json")]:
    full_path = os.path.join(repo_dir, rel_path)
    if not os.path.isfile(full_path):
        continue
    with open(full_path, 'r') as f:
        data = json.load(f)
    data['license'] = '(MIT AND CC-BY-SA-4.0)'
    with open(full_path, 'w') as f:
        json.dump(data, f, indent=4)
        f.write('\n')
    print(f"Updated {label} license")
PYEOF

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
