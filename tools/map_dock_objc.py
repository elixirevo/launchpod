#!/usr/bin/env python3
"""Read-only Objective-C code map for the Monterey Dock's arm64e slice.

Supports Mach-O 64 with ARM64E_USERLAND24 chained rebases (format 12).
No process attachment, execution, decryption, or input-file modification.
Addresses are unslid virtual addresses, not addresses in a running process.
Format references: Apple's dyld fixup-chains.h and objc4 objc-runtime-new.h.
"""
import argparse
import bisect
import hashlib
import json
import struct
import uuid
from pathlib import Path


class Image:
    def __init__(self, path):
        self.path = Path(path)
        raw = self.path.read_bytes()
        self.sha256 = hashlib.sha256(raw).hexdigest()
        self.fat_offset = 0
        if raw[:4] == b'\xca\xfe\xba\xbe':
            for i in range(struct.unpack_from('>I', raw, 4)[0]):
                cpu, sub, off, size, _ = struct.unpack_from('>5I', raw, 8 + 20*i)
                if cpu == 0x100000c and sub & 0xffffff == 2:
                    self.fat_offset = off
                    self.b = raw[off:off+size]
                    break
            else:
                raise ValueError('No arm64e slice')
        else:
            self.b = raw
        assert self.unpack('<I', 0)[0] == 0xfeedfacf, 'Expected Mach-O 64 LE'
        assert self.unpack('<I', 4)[0] == 0x100000c, 'Expected ARM64'
        self.segments = []
        self.sections = []
        self.starts = []
        pos = 32
        for _ in range(self.unpack('<I', 16)[0]):
            cmd, size = self.unpack('<II', pos)
            assert size >= 8
            if cmd == 0x19:
                vm, vsize, off, fsize = self.unpack('<4Q', pos+24)
                name = self.b[pos+8:pos+24].split(b'\0')[0].decode()
                flags = self.unpack('<I', pos+68)[0]
                self.segments.append(dict(name=name, vm=vm, size=vsize,
                                          offset=off, file_size=fsize, flags=flags))
                for i in range(self.unpack('<I', pos+64)[0]):
                    p = pos+72+i*80
                    sn = self.b[p:p+16].split(b'\0')[0].decode()
                    addr, sz, fo = self.unpack('<QQI', p+32)
                    self.sections.append(dict(name=sn, segment=name, vm=addr,
                                              size=sz, offset=fo))
            elif cmd == 0x1b:
                self.uuid = str(uuid.UUID(bytes=self.b[pos+8:pos+24])).upper()
            elif cmd == 0x26:
                self.functions = self.unpack('<II', pos+8)
            elif cmd == 0x80000034:
                self.fixups = self.unpack('<II', pos+8)
            pos += size
        text = next(s for s in self.segments if s['name'] == '__TEXT')
        assert text['flags'] & 8 == 0, 'Protected __TEXT is unsupported'
        self.base = text['vm']
        start = self.fixups[0]
        h = self.unpack('<7I', start)
        assert h[0] == 0 and h[5] == 1 and h[6] == 0, 'Unsupported fixups'
        self.imports = []
        for i in range(h[4]):
            imp = self.unpack('<I', start+h[2]+i*4)[0]
            self.imports.append(self.file_string(start+h[3]+(imp >> 9)))
        s = start+h[1]
        for i in range(self.unpack('<I', s)[0]):
            rel = self.unpack('<I', s+4+i*4)[0]
            if rel:
                assert self.unpack('<H', s+rel+6)[0] == 12, 'Unsupported pointer format'
        p, length = self.functions
        end = p+length
        addr = self.base
        while p < end:
            delta, shift = 0, 0
            while True:
                v = self.b[p]
                p += 1
                delta |= (v & 127) << shift
                if not v & 128:
                    break
                shift += 7
            if not delta:
                break
            addr += delta
            self.starts.append(addr)

    def unpack(self, fmt, offset):
        return struct.unpack_from(fmt, self.b, offset)

    def file_offset(self, address):
        for s in self.segments:
            if s['vm'] <= address < s['vm']+s['file_size']:
                return s['offset']+address-s['vm']
        raise ValueError('Unmapped address ' + hex(address))

    def file_string(self, off):
        end = self.b.index(0, off)
        return self.b[off:end].decode('utf-8')

    def string(self, address):
        return self.file_string(self.file_offset(address))

    def pointer(self, address):
        raw = self.unpack('<Q', self.file_offset(address))[0]
        if not raw:
            return 0
        if raw >> 62 & 1:
            return self.imports[raw & 0xffffff]
        if raw >> 63:
            return self.base + (raw & 0xffffffff)
        return (self.base + (raw & ((1 << 43)-1))) | (((raw >> 43) & 255) << 56)

    def methods(self, address, owner, kind):
        if not address:
            return []
        flags, count = self.unpack('<II', self.file_offset(address))
        stride = flags & 0xfffc
        result = []
        for i in range(count):
            entry = address+8+i*stride
            if flags & 0x80000000:
                assert stride == 12
                n, t, impl = self.unpack('<iii', self.file_offset(entry))
                name_addr = entry+n
                if not flags & 0x40000000:
                    name_addr = self.pointer(name_addr)
                type_addr = entry+4+t
                impl = entry+8+impl
            else:
                assert stride == 24
                name_addr = self.pointer(entry)
                type_addr = self.pointer(entry+8)
                impl = self.pointer(entry+16)
            selector = self.string(name_addr)
            assert selector and all(ord(c) >= 32 for c in selector)
            assert impl in self.starts, (owner, selector, hex(impl), 'not a function start')
            nxt = bisect.bisect_right(self.starts, impl)
            result.append(dict(owner=owner, kind=kind, selector=selector,
                               signature=f'{kind}[{owner} {selector}]',
                               implementation=hex(impl),
                               next_function=hex(self.starts[nxt]) if nxt < len(self.starts) else None,
                               slice_offset=hex(self.file_offset(impl)),
                               fat_file_offset=hex(self.fat_offset+self.file_offset(impl)),
                               type_encoding=self.string(type_addr)))
        return result

    def classes(self):
        section = next(s for s in self.sections if s['name'] == '__objc_classlist')
        result = []
        for i in range(section['size']//8):
            addr = self.pointer(section['vm']+i*8)
            ro = self.pointer(addr+32) & ~7
            name = self.string(self.pointer(ro+24))
            super_addr = self.pointer(addr+8)
            if isinstance(super_addr, int) and super_addr:
                super_ro = self.pointer(super_addr+32) & ~7
                superclass = self.string(self.pointer(super_ro+24))
            else:
                superclass = super_addr
            meta = self.pointer(addr)
            meta_ro = self.pointer(meta+32) & ~7
            methods = self.methods(self.pointer(ro+32), name, '-')
            methods += self.methods(self.pointer(meta_ro+32), name, '+')
            result.append(dict(name=name, address=hex(addr), superclass=superclass,
                               methods=methods))
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', nargs='?', default='/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock')
    parser.add_argument('--all', action='store_true', help='Include unrelated Dock classes')
    args = parser.parse_args()
    image = Image(args.binary)
    classes = image.classes()
    supporting = {'SBSearchPage', 'ECTextInputLayer', 'ECGridLayer', 'ECPage',
                  'ECPager', 'ECPagerLayer', 'ECPagerControlLayer', 'ECPagerIndicatorLayer'}
    selected = classes if args.all else [c for c in classes if
        c['name'].startswith(('LP', 'ECSB')) or 'Springboard' in c['name']
        or c['name'] in supporting]
    print(json.dumps(dict(source=str(image.path), sha256=image.sha256,
                          arch='arm64e', uuid=image.uuid, base=hex(image.base),
                          fat_slice_offset=hex(image.fat_offset),
                          class_count_total=len(classes), class_count_selected=len(selected),
                          method_count_selected=sum(len(c['methods']) for c in selected),
                          sections=image.sections, classes=selected), indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
