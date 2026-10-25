"""Checksum-pinned official archives; shared by setup and build verification."""
from pathlib import Path
import hashlib,json,urllib.request,zipfile
ROOT=Path(__file__).resolve().parents[1]
LOCK=json.loads((ROOT/'firmware/c3-web/dependencies.lock.json').read_text())
def archive(lib, cache):
 cache.mkdir(parents=True,exist_ok=True)
 target=cache/Path(lib['url']).name
 if not target.exists():
  with urllib.request.urlopen(lib['url'],timeout=90) as response:target.write_bytes(response.read())
 if hashlib.sha256(target.read_bytes()).hexdigest()!=lib['sha256']:
  raise RuntimeError('Dependency checksum mismatch: '+lib['name'])
 return target

def entries(lib,cache):
 with zipfile.ZipFile(archive(lib,cache)) as z:
  result={}
  for item in z.infolist():
   if item.is_dir():continue
   parts=Path(item.filename).parts
   if len(parts)<2 or '..' in parts:raise RuntimeError('Unsafe archive path')
   result[Path(*parts[1:])]=z.read(item)
  return result

def verify_library(lib, directory, cache):
 expected=entries(lib,cache)
 for path,data in expected.items():
  target=directory/path
  if not target.is_file() or target.read_bytes()!=data:
   raise RuntimeError('Modified/missing upstream library file: '+lib['name']+'/'+str(path))
 # An injected implementation/header must not silently enter Arduino's build.
 for path in directory.rglob('*'):
  if path.is_file() and path.suffix.lower() in ('.c','.cpp','.h','.hpp','.s') and path.relative_to(directory) not in expected:
   raise RuntimeError('Unexpected library source: '+str(path.relative_to(directory)))
