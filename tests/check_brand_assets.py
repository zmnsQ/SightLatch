#!/usr/bin/env python3
"""Brand source checks only; not an Xcode build. Requires Pillow."""
from pathlib import Path
import json, re, unittest, xml.etree.ElementTree as ET
from PIL import Image
ROOT = Path(__file__).resolve().parents[1]
class BrandAssets(unittest.TestCase):
    def test_icon(self):
        p=ROOT/'ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
        with Image.open(p) as image:
            self.assertEqual(image.size,(1024,1024))
            self.assertEqual(image.mode,'RGB')
        self.assertEqual(p.read_bytes(),(ROOT/'assets/brand/app-icon.png').read_bytes())
    def test_catalogs(self):
        for path in (ROOT/'ios/App/Assets.xcassets').rglob('Contents.json'):
            data=json.loads(path.read_text())
            for entry in data.get('images',[]):
                self.assertTrue((path.parent/entry['filename']).is_file())
        brand=json.loads((ROOT/'ios/App/Assets.xcassets/BrandMark.imageset/Contents.json').read_text())
        self.assertEqual(len(brand['images']),2)
        self.assertEqual(brand['images'][1]['appearances'][0]['value'],'dark')
    def test_vectors(self):
        for path in (ROOT/'assets/brand').glob('*.svg'):
            root=ET.parse(path).getroot()
            self.assertEqual(root.tag,'{http://www.w3.org/2000/svg}svg')
            self.assertIn('viewBox',root.attrib)
            self.assertNotIn('<script',path.read_text())
    def test_target_wiring(self):
        s=(ROOT/'ios/SightLatch.xcodeproj/project.pbxproj').read_text()
        self.assertEqual(s.count('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;'),2)
        # Xcode may reformat or unquote paths. Follow actual catalog membership
        # instead of fixing object IDs or assuming only the App has resources.
        clean=re.sub(r'/\*.*?\*/','',s,flags=re.S)
        objects=dict(re.findall(r'([A-F0-9]{24})\s*=\s*\{([^{}]*)\};',clean,re.S))
        def field(obj,key):
            value=re.search(r'\b'+key+r'\s*=\s*([^;]+);',obj)
            self.assertIsNotNone(value,(key,obj))
            return value[1].strip().strip('"')
        targets={field(obj,'name'):obj for obj in objects.values() if 'isa = PBXNativeTarget;' in obj}
        expected={'SightLatch':['App/Assets.xcassets'],'SightLatchWidget':['Widget/Assets.xcassets'],'SightLatchBroadcast':[]}
        self.assertEqual(set(targets),set(expected))
        for name,catalogs in expected.items():
            phases=[objects[uid] for uid in re.findall(r'[A-F0-9]{24}',field(targets[name],'buildPhases'))
                    if 'isa = PBXResourcesBuildPhase;' in objects[uid]]
            self.assertEqual(len(phases),1,name)
            actual=[field(objects[field(objects[uid],'fileRef')],'path')
                    for uid in re.findall(r'[A-F0-9]{24}',field(phases[0],'files'))]
            self.assertEqual(actual,catalogs,name)
        self.assertIn('Image("BrandMark")',(ROOT/'ios/App/HomeView.swift').read_text())
if __name__=='__main__':unittest.main()
