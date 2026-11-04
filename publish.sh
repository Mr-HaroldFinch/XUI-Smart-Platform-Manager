#!/usr/bin/env bash
# publish.sh - prepare the repository before every commit / release.
#   ./publish.sh                         recompute the checksums and the release notes only
#   ./publish.sh <github-user> <repo>    also write the raw update address into the script (and README links)
#   ./publish.sh <github-user> <repo> <branch>     (branch defaults to "main")
# Run it again after EVERY change of XUI-SPM.sh: the checksum files must match the script exactly.
set -euo pipefail
cd "$(dirname "$0")"
F=XUI-SPM.sh

[[ -f $F ]] || { echo "ERROR: $F not found next to publish.sh" >&2; exit 1; }

if [[ $# -ge 2 ]]; then
    user=$1 repo=$2 branch=${3:-main}
    [[ $user =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || { echo "ERROR: invalid GitHub user name: $user" >&2; exit 1; }
    [[ $repo =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid repository name: $repo" >&2; exit 1; }
    [[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "ERROR: invalid branch name: $branch" >&2; exit 1; }
    url="https://raw.githubusercontent.com/${user}/${repo}/${branch}/${F}"
    old=$(cat .moc-repo 2>/dev/null || echo 'YOUR_USER/YOUR_REPO')
    # 1) the address the script's "Update this script" menu uses
    sed -i "s|^readonly SELF_UPDATE_URL_DEFAULT=.*|readonly SELF_UPDATE_URL_DEFAULT='${url}'|" "$F"
    # 2) the links in the documentation
    for d in README.md README.fa.md docs/GITHUB-GUIDE.fa.md; do
        [[ -f $d ]] && sed -i "s|${old}|${user}/${repo}|g" "$d"
    done
    printf '%s\n' "${user}/${repo}" > .moc-repo
    echo "Update address set to: ${url}"
fi

bash -n "$F" || { echo "ERROR: syntax error in $F" >&2; exit 1; }
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$F" && echo "shellcheck: clean" || { echo "ERROR: shellcheck reported problems" >&2; exit 1; }
else
    echo "shellcheck not installed - skipped (optional)"
fi

ver=$(bash "$F" --version)
sum=$(sha256sum "$F" | awk '{print $1}')
printf '%s  %s\n' "$sum" "$F" > "${F}.sha256"
cp "${F}.sha256" SHA256SUMS
sha256sum -c SHA256SUMS

repo_path=$(cat .moc-repo 2>/dev/null || echo 'YOUR_USER/YOUR_REPO')
cat > RELEASE_NOTES.md <<NOTES
## XUI-SPM - X-UI Smart Panel Manager v${ver}

Manages NX Panel, 3x-ui, Alireza x-ui and classic x-ui: backup, migration/restore, backup inspection, panel install/update, DNS verification, server checks and optimization.

### Verify before you run it
\`\`\`bash
curl -fsSLO https://github.com/${repo_path}/releases/download/v${ver}/${F}
echo "${sum}  ${F}" | sha256sum -c -
sudo bash ${F}
\`\`\`

**SHA-256**

\`\`\`
${sum}  ${F}
\`\`\`

See [CHANGELOG.md](https://github.com/${repo_path}/blob/main/CHANGELOG.md) for what changed.
NOTES

echo
echo "Version : ${ver}"
echo "SHA-256 : ${sum}"
echo "Files ready: ${F}  ${F}.sha256  SHA256SUMS  RELEASE_NOTES.md"
echo
echo "Next:  git add -A && git commit -m \"v${ver}\" && git push"
echo "       git tag v${ver} && git push origin v${ver}   (then create the Release and attach ${F}, ${F}.sha256, SHA256SUMS)"
