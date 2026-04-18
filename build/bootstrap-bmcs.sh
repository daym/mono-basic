#!/bin/sh
# Seed mono-basic bootstrap artifacts using bmcs from an external Mono host.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

MONO_HOST="${MONO_HOST:-}"

if [ -z "$MONO_HOST" ]; then
    echo "MONO_HOST must point to the external Mono host used for bootstrap." >&2
    exit 1
fi

CECIL_GMCS="${CECIL_GMCS:-$MONO_HOST/bin/gmcs}"

if [ -z "$CECIL_GMCS" ]; then
    echo "CECIL_GMCS must point to the gmcs used to build Mono.Cecil.VB.dll." >&2
    exit 1
fi

HOST_VB_RUNTIME="${HOST_VB_RUNTIME:-$MONO_HOST/lib/mono/2.0/Microsoft.VisualBasic.dll}"

PATH="$MONO_HOST/bin:$PATH"
export PATH

BOOTSTRAP_DIR="$ROOT/class/lib/bootstrap"
EXTRACT_DIR="$ROOT/tools/extract-source"
VBRT_DIR="$ROOT/vbruntime/Microsoft.VisualBasic"
VBNC_DIR="$ROOT/vbnc/vbnc"
CECIL_DIR="$ROOT/vbnc/cecil"
HOST_MONO_PATH="$MONO_HOST/lib/mono/2.0"
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/mono-basic-bootstrap-bmcs-XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

BMCS="${BMCS:-bmcs}"
MONO="${MONO:-mono}"
RESGEN2="${RESGEN2:-resgen2}"
if [ ! -x "$CECIL_GMCS" ]; then
    echo "CECIL_GMCS not found: $CECIL_GMCS" >&2
    exit 1
fi

if [ ! -f "$HOST_VB_RUNTIME" ]; then
    echo "HOST_VB_RUNTIME not found: $HOST_VB_RUNTIME" >&2
    exit 1
fi

mkdir -p "$BOOTSTRAP_DIR"

# Remove stale bootstrap outputs so failed rebuilds cannot be masked.
rm -f \
    "$EXTRACT_DIR/extract-source.exe" \
    "$EXTRACT_DIR/extract-source.exe.mdb" \
    "$BOOTSTRAP_DIR/Microsoft.VisualBasic.dll" \
    "$BOOTSTRAP_DIR/Microsoft.VisualBasic.dll.mdb" \
    "$BOOTSTRAP_DIR/Microsoft.VisualBasic.dll.pdb" \
    "$BOOTSTRAP_DIR/Mono.Cecil.VB.dll" \
    "$BOOTSTRAP_DIR/Mono.Cecil.VB.dll.mdb" \
    "$BOOTSTRAP_DIR/Mono.Cecil.VB.dll.pdb" \
    "$BOOTSTRAP_DIR/vbnc.exe" \
    "$BOOTSTRAP_DIR/vbnc.exe.mdb" \
    "$BOOTSTRAP_DIR/vbnc.exe.pdb" \
    "$BOOTSTRAP_DIR/vbnc.rsp"

echo "=== bootstrap-bmcs: Mono.Cecil.VB.dll ==="
(
    cd "$CECIL_DIR"
    "$CECIL_GMCS" \
        -keyfile:mono.snk \
        -d:CECIL \
        -debug \
        -target:library \
        -out:"$BOOTSTRAP_DIR/Mono.Cecil.VB.dll" \
        @Mono.Cecil.VB.dll.sources
)

echo "=== bootstrap-bmcs: extract-source.exe ==="
(
    cd "$EXTRACT_DIR"
    "$BMCS" \
        -target:exe \
        -out:"$EXTRACT_DIR/extract-source.exe" \
        -codepage:utf8 \
        -noconfig \
        -d:_MYTYPE=\"Empty\" \
        -r:"$HOST_VB_RUNTIME" \
        -r:System.dll \
        -r:System.Data.dll \
        -r:System.Xml.dll \
        @extract-source.exe.sources
)

echo "=== bootstrap-bmcs: Microsoft.VisualBasic.dll ==="
(
    cd "$VBRT_DIR"
    VBRT_WORK="$WORKDIR/vbruntime"
    VBRT_SOURCES="$VBRT_WORK/Microsoft.VisualBasic.dll.sources"
    VBRT_STRINGS="$VBRT_WORK/strings2.txt"
    VBRT_RESOURCES="$VBRT_WORK/strings2.resources"
    VBRT_BUILD="$VBRT_WORK/sources.build"
    VBRT_SRC_DIR="$VBRT_WORK/src"

    mkdir -p "$VBRT_SRC_DIR"

    MONO_PATH="$HOST_MONO_PATH${MONO_PATH:+:$MONO_PATH}" \
        "$MONO" ../../tools/extract-source/extract-source.exe \
        -x:r \
        -s:2010VB.vbproj \
        -d:"$VBRT_SOURCES" \
        -m:l

    cat strings.txt strings-only2.txt > "$VBRT_STRINGS"
    "$RESGEN2" "$VBRT_STRINGS" "$VBRT_RESOURCES"

    # bmcs with -noconfig does not inject the standard VB imports that the
    # runtime sources assume, so splice them into per-file temp copies.
    VBRT_IMPORTS='Imports System
Imports System.Collections
Imports System.Collections.Generic
Imports System.Data
Imports System.Diagnostics'

    # Use extract-source.exe as the authority for project membership and order,
    # but build from temp copies so the bootstrap target never rewrites tracked
    # .sources files or source files in the mono-basic tree.
    : > "$VBRT_BUILD"
    while IFS= read -r rel || [ -n "$rel" ]; do
        src="$VBRT_DIR/$rel"
        flat=$(printf '%s' "$rel" | sed 's|/|_|g')
        out="$VBRT_SRC_DIR/$flat"
        [ -f "$src" ] || continue
        printf '%s\n' "$VBRT_IMPORTS" > "$out"
        cat "$src" >> "$out"
        # Keep the real AssemblyInfo in the bootstrap runtime, but patch the
        # temp copy to avoid signing and to keep its assembly identity distinct
        # from the host Mono 1.2 GAC Microsoft.VisualBasic.dll.
        if [ "$flat" = "AssemblyInfo.vb" ]; then
            sed -i \
                -e '/<Assembly: AssemblyDelaySign/d' \
                -e '/<Assembly: AssemblyKeyFile/d' \
                -e '/<Assembly: Debuggable(/d' \
                -e '/<Assembly: CLSCompliant(True)>/d' \
                -e 's/AssemblyVersion("8\.0\.0\.0")/AssemblyVersion("8.0.0.1")/' \
                "$out"
        fi
        # Strings.AscW(Char) in the upstream source relies on vbnc-specific
        # intrinsic lowering when the runtime is compiled without a VB runtime
        # reference. Under the VB 10 conversion rules, CInt(Char) is not a
        # defined conversion, so bmcs is correct not to special-case it. Patch
        # the bootstrap copy to the explicit UInt16 conversion that preserves
        # AscW's Unicode semantics without depending on that compiler quirk.
        if [ "$flat" = "Microsoft.VisualBasic_Strings.vb" ]; then
            sed -i \
                -e 's/Return AscW(\[String\])/Return Convert.ToUInt16([String])/' \
                "$out"
        fi
        # Wine's trash support adds LinuxDriver/Win32Driver implementations
        # that old bmcs cannot bootstrap cleanly. Keep the real source intact,
        # but make the bootstrap copy throw before referencing the excluded
        # platform drivers.
        if [ "$flat" = "Microsoft.VisualBasic.OSSpecific_OSDriver.vb" ]; then
            sed -i \
                -e 's/m_Driver = New LinuxDriver()/Throw New PlatformNotSupportedException("Linux OSDriver is excluded from this bootstrap build.")/' \
                "$out"
        fi
        # This is intentionally a reduced bootstrap runtime, matching the
        # existing external build-vbnc.sh path where possible. The remaining
        # exclusions stay out of the bootstrap DLL because they still hit
        # known bmcs parse/semantic failures in this older toolchain.
        case "$flat" in
            *WindowsFormsApplication*|\
            *ComputerInfo*|\
            *LinuxDriver.vb|\
            *Win32Driver.vb|\
            *Collection.vb|\
            *ServerComputer*|\
            *_Computer.vb|\
            *ApplicationServices_AssemblyInfo*|\
            *ApplicationServices_ApplicationBase*|\
            *ApplicationServices_ConsoleApplicationBase*|\
            *_FileData.vb|\
            *_FileSystem.vb|\
            *_DateAndTime.vb|\
            *RegistryProxy.vb|\
            *TextFieldParser.vb|\
            *FileLogTraceListener.vb|\
            *Logging_Log.vb|\
            *Logging_AspLog.vb|\
            *FileSystemProxy.vb)
                continue
                ;;
        esac
        printf '%s\n' "$out" >> "$VBRT_BUILD"
    done < "$VBRT_SOURCES"

    "$BMCS" \
        -target:library \
        -out:"$BOOTSTRAP_DIR/Microsoft.VisualBasic.dll" \
        -codepage:utf8 \
        -noconfig \
        -d:NET_VER=2.0 \
        -d:TARGET_JVM=False \
        -r:System.dll \
        -r:System.Windows.Forms.dll \
        -r:System.Data.dll \
        -r:System.Drawing.dll \
        -r:System.Web.dll \
        -r:System.Xml.dll \
        -resource:"$VBRT_RESOURCES",strings.resources \
        @"$VBRT_BUILD"
)

echo "=== bootstrap-bmcs: vbnc.exe ==="
(
    cd "$VBNC_DIR"
    VBNC_WORK="$WORKDIR/vbnc"
    VBNC_SOURCES="$VBNC_WORK/vbnc.exe.sources"
    VBNC_ERRORS="$VBNC_WORK/vbnc.Errors.resources"
    VBNC_RSP_RESOURCE="$VBNC_WORK/vbnc.vbnc.rsp"
    VBNC_BUILD="$VBNC_WORK/sources"

    mkdir -p "$VBNC_WORK/src"

    "$RESGEN2" source/Resources/Errors.resx "$VBNC_ERRORS"
    cp source/vbnc.rsp "$VBNC_RSP_RESOURCE"

    MONO_PATH="$HOST_MONO_PATH${MONO_PATH:+:$MONO_PATH}" \
        "$MONO" ../../tools/extract-source/extract-source.exe \
        -s:source/vbnc.vbproj \
        -d:"$VBNC_SOURCES" \
        -m:l \
        -b:source/ \
        -x:r

    # Keep the mono-basic project file as the source of truth for membership
    # and order, but splice the imports into temp copies so we do not dirty the
    # tracked generated files under vbnc/vbnc/.
    : > "$VBNC_BUILD"
    VBNC_IMPORTS='Imports Mono.Cecil
Imports System
Imports System.Collections
Imports System.Reflection
Imports System.Reflection.Emit
Imports VB = Microsoft.VisualBasic'

    while IFS= read -r rel || [ -n "$rel" ]; do
        src="$VBNC_DIR/$rel"
        flat=$(printf '%s' "$rel" | sed -e 's|/|_|g' -e 's| |_|g')
        raw="$VBNC_WORK/src/$flat.raw"
        out="$VBNC_WORK/src/$flat"

        [ -f "$src" ] || continue

        awk -v imports="$VBNC_IMPORTS" '
            BEGIN { inserted = 0 }
            !inserted {
                if ($0 ~ /^[[:space:]]*$/) { print; next }
                if ($0 ~ /^[[:space:]]*'\''/) { print; next }
                if (tolower($0) ~ /^[[:space:]]*option[[:space:]]/) { print; next }
                print imports
                inserted = 1
            }
            { print }
            END { if (!inserted) print imports }
        ' "$src" > "$raw"

        mv "$raw" "$out"
        printf '%s\n' "$out" >> "$VBNC_BUILD"
    done < "$VBNC_SOURCES"

    MONO_PATH="$BOOTSTRAP_DIR${MONO_PATH:+:$MONO_PATH}" \
        "$BMCS" \
        -target:exe \
        -out:"$BOOTSTRAP_DIR/vbnc.exe" \
        -r:"$BOOTSTRAP_DIR/Microsoft.VisualBasic.dll" \
        -r:"$BOOTSTRAP_DIR/Mono.Cecil.VB.dll" \
        -r:System.dll \
        -r:System.Xml.dll \
        -r:System.Windows.Forms.dll \
        -r:System.Core.dll \
        -codepage:utf8 \
        -noconfig \
        -rootnamespace:vbnc \
        -debug:full \
        -d:DEBUG=false \
        -d:_MYTYPE=\"Empty\" \
        -resource:"$VBNC_ERRORS",vbnc.Errors.resources \
        -resource:"$VBNC_RSP_RESOURCE",vbnc.vbnc.rsp \
        @"$VBNC_BUILD"

    cp source/vbnc.rsp "$BOOTSTRAP_DIR/vbnc.rsp"
)

echo
echo "bootstrap artifacts:"
ls -l \
    "$BOOTSTRAP_DIR/Mono.Cecil.VB.dll" \
    "$BOOTSTRAP_DIR/Microsoft.VisualBasic.dll" \
    "$BOOTSTRAP_DIR/vbnc.exe" \
    "$BOOTSTRAP_DIR/vbnc.rsp"
