#!/bin/sh
# Run the jre11 tag-truncation regression test.
# Usage: run.sh <jre-dir> [runs] [extra-jvm-args...]
set -eu
JRE=${1:?jre dir}
RUNS=${2:-10}
shift 2 2>/dev/null || true
HERE=$(cd "$(dirname "$0")" && pwd)
LD_LIBRARY_PATH="$JRE/lib:$JRE/lib/jli:$JRE/lib/server"
export LD_LIBRARY_PATH
fail=0
i=0
while [ "$i" -lt "$RUNS" ]; do
  i=$((i+1))
  /system/bin/linker64 "$JRE/bin/java" "$@" -Xmx96m -XX:CompileCommand=exclude,*.*f -cp "$HERE/classes" Stress || fail=$((fail+1))
done
echo "Stress $*: $((RUNS-fail))/$RUNS passed"
test "$fail" -eq 0
