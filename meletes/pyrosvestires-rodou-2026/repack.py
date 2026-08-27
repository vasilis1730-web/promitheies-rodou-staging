import zipfile, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
zin = zipfile.ZipFile(src)
names = [n for n in zin.namelist() if not n.endswith('/')]
first = '[Content_Types].xml'
assert first in names, 'missing [Content_Types].xml'
ordered = [first] + [n for n in names if n != first]
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
    for n in ordered:
        zout.writestr(n, zin.read(n))
print('repacked', len(ordered), 'entries ->', dst)
