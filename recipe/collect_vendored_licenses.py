"""Collect vendored third-party license texts from pdfium's synced tree.

The win-64 toolchained build links pdfium's vendored deps statically into
pdfium.dll (unlike linux/osx, nothing is unvendored), so their license texts
must ship in the conda package. Concatenates every LICENSE*/COPYING* file
under each third_party/<lib>/ (up to two levels deep, to catch layouts like
freetype's docs/FTL-adjacent files) into a single file, which meta.yaml
references as about/license_file.

Fails loudly if the tree or any license file is missing, so a ref bump that
rearranges third_party/ cannot silently strip attribution.

Usage: collect_vendored_licenses.py <pdfium/third_party dir> <output file>
"""

import pathlib
import sys


def main() -> int:
    third_party, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    if not third_party.is_dir():
        print(f"third_party dir not found: {third_party}", file=sys.stderr)
        return 1
    chunks = []
    for lib in sorted(p for p in third_party.iterdir() if p.is_dir()):
        for f in sorted(lib.rglob("*")):
            if (
                f.is_file()
                and len(f.relative_to(lib).parts) <= 2
                and f.name.upper().startswith(("LICENSE", "COPYING"))
            ):
                header = f"===== {lib.name}/{f.relative_to(lib)} ====="
                chunks.append(header + "\n" + f.read_text(errors="replace").strip())
    if not chunks:
        print(f"no license files found under {third_party}", file=sys.stderr)
        return 1
    out.write_text("\n\n\n".join(chunks) + "\n")
    print(f"collected {len(chunks)} license files into {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
