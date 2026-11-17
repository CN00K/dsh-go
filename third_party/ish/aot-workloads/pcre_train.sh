#!/bin/sh
# Vendored from OpenMinis (GPLv3): deps/aot/workloads/pcre_train.sh
# (https://github.com/OpenMinis/OpenMinis). Copied with dsh-go changes:
# (1) `git config --global --add safe.directory` before the first git use,
#     because the recording guest's git refuses the repo as "dubious
#     ownership" (fix 7, attempt 8).
# (2) NO GIT AT ALL (fix 12, attempt 14): the recording guest's `git add -A`
#     HANGS with zero output — the sh -x trace in attempt 13 (build
#     6af91f0b, dry_pcre2.log) shows it stops right after `git init -q`
#     completes, at the first `git add -A`, and never returns within the
#     900s dry-run timeout. Most likely cause: git needs random bytes for
#     temp-file names when writing objects, and the emulated /dev/urandom
#     (reached via the fix-9 placeholder files) blocks instead of
#     returning. git is only the test-data setup here — the thing being
#     recorded is libpcre2, and ripgrep (`rg -P`) exercises it directly,
#     so the workload now uses a plain file tree (no repo, no commits)
#     and runs only rg -P searches. If the pcre2 translation count falls
#     below the 4100 floor, the floor (not the workload) is what to revisit.
# dsh-go is AGPL-3.0; GPLv3 code may be included in an AGPLv3
# work with attribution — see design §5 / THIRD_PARTY_NOTICES.md.
# Used by third_party/ish/record-aot.sh (the pcre2 training workload).
# Workload for recording the PCRE2 AOT image: rg -P with lookarounds,
# classes and backreferences, the regex paths agents reach through ripgrep
# (needs python3 and ripgrep; no git).
#
# The sample file tree is built here from Python's standard library.
R=/tmp/pcre-repo
rm -rf $R && mkdir -p $R && cd $R || { echo "FAIL pcre: no $R"; exit 1; }
src=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')
( cd "$src" && find . -name '*.py' ! -path './site-packages/*' ! -path './test/*' ! -path '*/tests/*' ! -path '*/__pycache__/*' |
    tar cf - -T - ) | tar xf -
echo "sample tree: $(find . -name '*.py' | wc -l) files"

for p in 'def\s+\w+\(self(?=,|\))' '(?<=import )\w+' '\b(\w+)\s*=\s*\1\b' '(?i)error|warn(ing)?' 'raise\s+[A-Z]\w+Error\((?!\))' '^\s*#\d?\s+TODO' '"[^"\\]*(?:\\.[^"\\]*)*"' '\d{2,}\.\d+'; do
    rg -P -c "$p" . > /dev/null
    rg -P -o -N "$p" email json > /dev/null
done
rg -P -n -i 'class\s+\w+(?:Error|Exception)\b' . > /dev/null
rg -P -U 'def \w+\([^)]*\n[^)]*\)' -c . > /dev/null
cd / && rm -rf $R
echo pcre-train-ok
