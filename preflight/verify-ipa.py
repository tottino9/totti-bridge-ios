"""Offline IPA/provenance checks; not a replacement for Apple codesign or hardware tests."""
import hashlib
import json
import plistlib
import struct
import sys
import uuid
import zipfile
from pathlib import Path

def macho(data):
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        raise ValueError('Expected little-endian Mach-O 64')
    cpu, subtype, kind, count, size = struct.unpack_from('<iiIII', data, 4)
    if 32 + size > len(data):
        raise ValueError('Invalid load-command size')
    result = dict(cpu=hex(cpu), subtype=subtype, fileType=kind, cryptIDs=[], uuids=[])
    offset = 32
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError('Invalid load-command bounds')
        if cmd in (0x21, 0x2C):
            result['cryptIDs'].append(struct.unpack_from('<I', data, offset + 16)[0])
        if cmd == 0x1B:
            result['uuids'].append(str(uuid.UUID(bytes=data[offset+8:offset+24])))
        if cmd == 0x32:
            platform, minimum, sdk = struct.unpack_from('<III', data, offset + 8)
            result.update(platform=platform, minimumOS=minimum, sdk=sdk)
        offset += length
    return result

def inspect(path):
    with zipfile.ZipFile(path) as z:
        if z.testzip() is not None:
            raise ValueError('ZIP CRC failure')
        names = z.namelist()
        if any(n.startswith('/') or '..' in n.split('/') for n in names):
            raise ValueError('Unsafe ZIP member')
        root = 'Payload/RokidLyricsIOS.app/'
        plist = plistlib.loads(z.read(root + 'Info.plist'))
        executable = z.read(root + plist['CFBundleExecutable'])
        info = macho(executable)
        if info['cpu'] != '0x100000c' or info['fileType'] != 2 or info.get('platform') != 2:
            raise ValueError('Not an arm64 iOS executable')
        if any(info['cryptIDs']):
            raise ValueError('Encrypted executable is not a resignable preflight product')
        if plist['CFBundleIdentifier'] != 'com.anezium.rokidlyrics':
            raise ValueError('Wrong bundle ID')
        sdk = macho(z.read(root + 'Frameworks/RGCxrClient.framework/RGCxrClient'))
        return dict(file=Path(path).name, sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest(),
                    bytes=Path(path).stat().st_size, bundleID=plist['CFBundleIdentifier'],
                    build=plist['CFBundleVersion'], commit=plist.get('TottiPreflightCommit'),
                    variant=plist.get('TottiAudioVariant'), executable=info,
                    hasDuplexClass=b'TottiDuplexAudio' in executable,
                    rgcxrUUIDs=sdk['uuids'])

if __name__ == '__main__':
    candidate, manifest_path, restore, commit = sys.argv[1:]
    c, r = inspect(candidate), inspect(restore)
    manifest = json.loads(Path(manifest_path).read_text())
    if r['sha256'] != 'e84cf545bc2f1b9ce941327566e14b80163878f00f226e7f8899b60ca4e347d8':
        raise ValueError('Restore IPA is not the pinned reference')
    if c['sha256'] != manifest['sha256'] or c['bytes'] != manifest['bytes']:
        raise ValueError('Candidate bytes disagree with CI manifest')
    if c['variant'] != 'duplex' or c['commit'] != commit or manifest['sourceCommit'] != commit:
        raise ValueError('Wrong candidate source/variant')
    if c['build'] != '1029' or not c['hasDuplexClass'] or r['hasDuplexClass']:
        raise ValueError('Unexpected executable feature identity')
    if c['rgcxrUUIDs'] != r['rgcxrUUIDs']:
        raise ValueError('Rokid SDK build identity differs from reference')
    print(json.dumps(dict(candidate=c, restore=r, byteChecksPassed=True,
                         localCodesignVerified=False, hardwareVerified=False), indent=2))
