# jre11 tag-truncation regression test

Android bionic tags C-heap pointers in the top byte. The aarch64 inline-cache
value cell for a virtual call is emitted as movz+movk+movk (48 bits), so a
CompiledICHolder* read back from it loses its tag; bionic's free() then aborts
with "Pointer tag ... was truncated" (exit 134, observed in a GC thread inside
InlineCacheBuffer::update_inline_caches).

This directory holds a stress case that creates many CompiledICHolder
transitions: 16 interface implementations, 6 threads doing megamorphic virtual
calls, reflection Method.invoke, class loading churn and periodic GC.

Baseline (unfixed 11.0.33.1 artifact, run 44682536823):
- Stress mixed:   14/20 runs abort
- Stress C1-only: 17/20 runs abort
- Hello mixed / C1-only: intermittent aborts (e.g. 1/20, 3/20)

Usage (on-device, JRE extracted at `$JRE`, classes prebuilt in ./classes):

```sh
export LD_LIBRARY_PATH="$JRE/lib:$JRE/lib/jli:$JRE/lib/server"
# regression stress: mixed and C1-only
for i in $(seq 1 50); do
  /system/bin/linker64 "$JRE/bin/java" -Xmx96m \
    -XX:CompileCommand=exclude,*.*f -cp ./classes Stress || exit 1
  /system/bin/linker64 "$JRE/bin/java" -XX:TieredStopAtLevel=1 -Xmx96m \
    -XX:CompileCommand=exclude,*.*f -cp ./classes Stress || exit 1
done
```

The fix (patches/jre_11/fixups/20-android-compiledic-holder-tag.diff) restores
the process heap tag when a cached CompiledICHolder is read or released. It
probes the process tag from a C-heap allocation once, is a no-op when tagging
is disabled, and only applies to the CompiledICHolder path (metadata values are
never retagged).
