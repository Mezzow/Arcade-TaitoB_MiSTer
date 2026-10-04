#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Taito B System core for MiSTer - simulation helper.
#
# Builds the ioctl index-0 ROM stream exactly as Main_MiSTer's mra_loader.cpp
# assembles it (support/arcade/mra_loader.cpp, rom_data(): a map nibble at
# position i with value v sends the i-th input byte of each unit to output
# byte first_nonzero_nibble + v - 1 + gaps), and writes the <switches default>
# bytes for index 254.
#
#   python sim/tools/mra_rom.py "releases/Ryu Jin (Japan, ET910000A PCB).mra" \
#          --rompath C:/path/to/mame/roms --out sim/work/ryujina
#
# writes <out>.rom and <out>.dip.

import argparse, binascii, os, sys, zipfile
import xml.etree.ElementTree as ET


def load_part(zips, rompath, name, crc):
    for z in zips:
        path = os.path.join(rompath, z)
        if not os.path.exists(path):
            continue
        with zipfile.ZipFile(path) as zf:
            for info in zf.infolist():
                if info.filename.lower() == name.lower() or (crc and info.CRC == crc):
                    data = zf.read(info)
                    if crc and (binascii.crc32(data) & 0xFFFFFFFF) != crc:
                        continue
                    return data
    sys.exit(f"missing ROM part {name} (crc {crc:08x}) in {zips}")


def unit_offsets(mapv, unitlen):
    if mapv == 0:
        mapv = 1
    nib = [(mapv >> (4 * i)) & 0xF for i in range(unitlen)]
    idx = next(i for i, v in enumerate(nib) if v)
    offs, gaps, first = [], 0, True
    for v in nib:
        if v:
            offs.append(idx + v - 1 + gaps)
            first = False
        elif not first:
            gaps += 1
    return offs


def build(mra, rompath):
    root = ET.parse(mra).getroot()
    rom = next(r for r in root.findall("rom") if r.get("index", "0") == "0")
    zips = rom.get("zip", "").split("|")
    out = bytearray()

    def part_bytes(p):
        if p.get("name"):
            crc = int(p.get("crc"), 16) if p.get("crc") else 0
            pz = p.get("zip")
            return load_part(pz.split("|") if pz else zips, rompath, p.get("name"), crc)
        return bytes.fromhex("".join((p.text or "").split()))

    for el in rom:
        if el.tag == "part":
            out += part_bytes(el)
        elif el.tag == "interleave":
            unitlen = int(el.get("output")) // 8
            block = None
            for p in el.findall("part"):
                data = part_bytes(p)
                offs = unit_offsets(int(p.get("map", "1"), 16), unitlen)
                n = len(data) // len(offs)
                if block is None:
                    block = bytearray(n * unitlen)
                for u in range(n):
                    for k, o in enumerate(offs):
                        block[u * unitlen + o] = data[u * len(offs) + k]
            out += block

    dip = bytearray(8)
    for i in range(8):
        dip[i] = 0xFF
    sw = root.find("switches")
    if sw is not None and sw.get("default"):
        raw = bytes.fromhex(sw.get("default").replace(",", "").replace(" ", ""))
        for i, b in enumerate(raw[:8]):
            dip[i] = b
    return bytes(out), bytes(dip)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("mra")
    ap.add_argument("--rompath", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rom, dip = build(a.mra, a.rompath)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out + ".rom", "wb").write(rom)
    open(a.out + ".dip", "wb").write(dip)
    print(f"{a.out}.rom: {len(rom)} bytes, dip {dip.hex()}")
