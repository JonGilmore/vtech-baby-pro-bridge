#!/usr/bin/env python3
"""Compute the kernel-uprobe offset for capturing the camera's TUTK UID
from a VTech APK at runtime.

Usage: python3 extract_uid_offsets.py <split-apk-path>

Where <split-apk-path> is the split APK that contains the aarch64 native
libs (e.g., `config.arm64_v8a.apk` after unzipping the .xapk).

Hooks `IOTC_Connect_ByUID_Parallel(const char *uid, int sid)` in
libIOTCAPIs.so. Its first arg is a `char *` to the UID C-string, so
the uprobe expression is a simple single-deref:
`uid=+0(%x0):string`. The probe fires when the official VTech app
initiates a TUTK connection to the camera (i.e., when you open the
camera live view in the app).

Why you might need this:
  - Lost the UID and the camera-info screen in the app isn't loading
  - Want to verify what UID the SDK actually sees (vs. what the app
    displays — they should match, but ground-truth is nice)
  - Re-paired the camera on a different network and want to confirm
    the UID didn't change (it usually doesn't — UID is camera-hardware
    derived — but worth verifying)

Same machinery as `extract_license_offsets.py` and
`extract_password_offsets.py` — different lib + symbol.
"""

import struct
import sys

LIB_PATH_IN_APK = "lib/arm64-v8a/libIOTCAPIs.so"
SYMBOL_NAME = "IOTC_Connect_ByUID_Parallel"


def find_lib_offset_in_zip(apk_path, lib_name):
    """Return (data_offset, size) of the lib within the apk zip file."""
    with open(apk_path, "rb") as f:
        f.seek(0, 2)
        flen = f.tell()
        scan_size = min(65557, flen)
        f.seek(flen - scan_size)
        tail = f.read(scan_size)
        eocd = tail.rfind(b"PK\x05\x06")
        if eocd < 0:
            raise ValueError("EOCD signature not found; not a valid zip?")
        total_entries = struct.unpack("<H", tail[eocd + 10 : eocd + 12])[0]
        cd_offset = struct.unpack("<I", tail[eocd + 16 : eocd + 20])[0]

        f.seek(cd_offset)
        for _ in range(total_entries):
            sig = f.read(4)
            if sig != b"PK\x01\x02":
                raise ValueError(f"bad central-directory entry signature: {sig!r}")
            f.read(6)
            comp_meth = struct.unpack("<H", f.read(2))[0]
            f.read(8)
            csize = struct.unpack("<I", f.read(4))[0]
            f.read(4)
            fnlen, exlen, cmnlen = struct.unpack("<HHH", f.read(6))
            f.read(8)
            lfh_offset = struct.unpack("<I", f.read(4))[0]
            name = f.read(fnlen).decode("utf-8", errors="replace")
            f.read(exlen + cmnlen)
            if name != lib_name:
                continue
            if comp_meth != 0:
                raise ValueError(
                    f"lib '{lib_name}' is compressed (zip method={comp_meth}); "
                    "expected stored — APK was likely built with extractNativeLibs=true."
                )
            here = f.tell()
            f.seek(lfh_offset)
            if f.read(4) != b"PK\x03\x04":
                raise ValueError("bad local-file-header signature")
            f.read(22)
            lfh_fnlen, lfh_exlen = struct.unpack("<HH", f.read(4))
            data_offset = lfh_offset + 30 + lfh_fnlen + lfh_exlen
            f.seek(here)
            return data_offset, csize
        raise ValueError(f"'{lib_name}' not found in {apk_path}")


def find_symbol_in_elf(elf_bytes, symbol_name):
    """Return the vaddr (st_value) of `symbol_name` in the ELF's dynsym.
    Walks PT_DYNAMIC + DT_SYMTAB / DT_STRTAB since these libs are stripped
    of their section header table.
    """
    if elf_bytes[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if elf_bytes[4] != 2:
        raise ValueError("expected ELF64")
    if elf_bytes[5] != 1:
        raise ValueError("expected little-endian ELF")

    e_phoff = struct.unpack("<Q", elf_bytes[0x20:0x28])[0]
    e_phentsize = struct.unpack("<H", elf_bytes[0x36:0x38])[0]
    e_phnum = struct.unpack("<H", elf_bytes[0x38:0x3A])[0]

    PT_LOAD, PT_DYNAMIC = 1, 2
    loads = []
    dyn_seg = None
    for i in range(e_phnum):
        ph = elf_bytes[e_phoff + i * e_phentsize : e_phoff + (i + 1) * e_phentsize]
        p_type = struct.unpack("<I", ph[0:4])[0]
        p_offset = struct.unpack("<Q", ph[8:16])[0]
        p_vaddr = struct.unpack("<Q", ph[16:24])[0]
        p_filesz = struct.unpack("<Q", ph[32:40])[0]
        if p_type == PT_LOAD:
            loads.append((p_offset, p_vaddr, p_filesz))
        elif p_type == PT_DYNAMIC:
            dyn_seg = (p_offset, p_filesz)

    if dyn_seg is None:
        raise ValueError("no PT_DYNAMIC segment found")

    def vaddr_to_offset(vaddr):
        for off, va, sz in loads:
            if va <= vaddr < va + sz:
                return off + (vaddr - va)
        raise ValueError(f"vaddr 0x{vaddr:x} not in any PT_LOAD")

    DT_NULL, DT_STRTAB, DT_SYMTAB, DT_STRSZ, DT_SYMENT = 0, 5, 6, 10, 11
    dyn_off, dyn_size = dyn_seg
    sym_vaddr = str_vaddr = strsz = syment = None
    for i in range(dyn_size // 16):
        entry = elf_bytes[dyn_off + i * 16 : dyn_off + (i + 1) * 16]
        d_tag, d_val = struct.unpack("<qQ", entry)
        if d_tag == DT_NULL:
            break
        elif d_tag == DT_SYMTAB: sym_vaddr = d_val
        elif d_tag == DT_STRTAB: str_vaddr = d_val
        elif d_tag == DT_STRSZ:  strsz = d_val
        elif d_tag == DT_SYMENT: syment = d_val

    if None in (sym_vaddr, str_vaddr, strsz, syment):
        raise ValueError("dynamic table missing one of DT_SYMTAB/DT_STRTAB/DT_STRSZ/DT_SYMENT")

    sym_off = vaddr_to_offset(sym_vaddr)
    str_off = vaddr_to_offset(str_vaddr)
    strtab = elf_bytes[str_off : str_off + strsz]

    target = symbol_name.encode("utf-8")
    i = 0
    while True:
        base = sym_off + i * syment
        if base + syment > len(elf_bytes):
            break
        s = elf_bytes[base : base + syment]
        st_name = struct.unpack("<I", s[0:4])[0]
        st_value = struct.unpack("<Q", s[8:16])[0]
        if st_name >= strsz:
            break
        end = strtab.find(b"\x00", st_name)
        if end < 0:
            break
        if strtab[st_name:end] == target:
            return st_value
        i += 1
    raise ValueError(f"symbol '{symbol_name}' not found in dynsym (walked {i} entries)")


def main():
    if len(sys.argv) != 2:
        print(
            "usage: extract_uid_offsets.py <split-apk-path>\n"
            "  e.g.  extract_uid_offsets.py xapk/config.arm64_v8a.apk",
            file=sys.stderr,
        )
        sys.exit(1)
    apk_path = sys.argv[1]

    print(f"# scanning '{LIB_PATH_IN_APK}' in {apk_path} ...", file=sys.stderr)
    lib_off, lib_size = find_lib_offset_in_zip(apk_path, LIB_PATH_IN_APK)
    print(f"#   lib data offset within APK: 0x{lib_off:x} ({lib_size} bytes)", file=sys.stderr)

    with open(apk_path, "rb") as f:
        f.seek(lib_off)
        elf_bytes = f.read(lib_size)

    print(f"# looking up '{SYMBOL_NAME}' in lib's dynsym ...", file=sys.stderr)
    sym_vaddr = find_symbol_in_elf(elf_bytes, SYMBOL_NAME)
    print(f"#   symbol vaddr in lib: 0x{sym_vaddr:x}", file=sys.stderr)

    combined = lib_off + sym_vaddr

    print(f"\n# Combined uprobe offset: 0x{combined:x}\n", file=sys.stderr)
    print("# Now extract the UID (open the VTech app + tap your camera tile to trigger):", file=sys.stderr)
    print(f"#   adb push extract_uid.sh /data/local/tmp/", file=sys.stderr)
    print(
        "#   adb shell su -c '/data/local/tmp/extract_uid.sh "
        f"$(pm path com.cams.vtech.mvb.pro | grep arm64_v8a | sed s/^package://) 0x{combined:x}'",
        file=sys.stderr,
    )
    print(file=sys.stderr)

    print(f"0x{combined:x}")


if __name__ == "__main__":
    main()
