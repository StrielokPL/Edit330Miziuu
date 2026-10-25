import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('edit_package', Path(__file__).resolve().parents[1] / 'tools/edit_package.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def run(root, *args):
    subprocess.run(['git', *args], cwd=root, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


class OverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'edit'
        self.source = self.root / 'source'
        self.repo.mkdir()
        self.source.mkdir()
        self.base = self.root / 'original.zip'
        xml = b'<modDesc><version>1.0.0.0</version></modDesc>'
        original = {'modDesc.xml':xml, 'Textures/keep.dds':b'unchanged',
                    'Textures/remove.dds':b'delete me', 'c330m.xml':b'old'}
        with zipfile.ZipFile(self.base, 'w') as z:
            for name, data in original.items(): z.writestr(name, data)
        for name, data in {**original, 'c330m.xml':b'new\r\n', 'Scripts/new.lua':b'return true'}.items():
            p=self.source/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        (self.source/'Textures/remove.dds').unlink()
        config={'id':'test','archiveName':'FS25_Test.zip','runtimeProfile':'c330',
                'sourceRepository':'owner/repo','baseMod':{'version':'1.0.0.0',
                'modDescVersion':'1.0.0.0','compatibleVersions':[]}}
        (self.repo/'edit-config.json').write_text(json.dumps(config),encoding='utf-8')
        run(self.source,'init');run(self.source,'config','user.name','Test')
        run(self.source,'config','user.email','test@example.invalid')
        run(self.source,'add','.');run(self.source,'commit','-m','fixture')
        with contextlib.redirect_stdout(io.StringIO()):module.build(self.repo,self.source,self.base)

    def test_exact_reconstruction_and_only_changed_files(self):
        result=module.verify(self.repo,self.base,self.source)
        self.assertTrue(result['verified'])
        paths={p.relative_to(self.repo/'files').as_posix() for p in (self.repo/'files').rglob('*') if p.is_file()}
        self.assertEqual(paths,{'c330m.xml','Scripts/new.lua'})
        self.assertEqual((self.repo/'files/c330m.xml').read_bytes(),b'new\r\n')
        deleted=json.loads((self.repo/'delete.json').read_text())
        self.assertEqual(deleted['files'],['Textures/remove.dds'])
        with zipfile.ZipFile(next((self.repo/'dist').glob('*.zip'))) as z:
            self.assertEqual(set(z.namelist()),{'updater.json','delete.json','files/c330m.xml','files/Scripts/new.lua'})

    def test_wrong_base_and_tampered_payload_are_rejected(self):
        other=self.root/'other.zip';other.write_bytes(b'wrong original')
        with self.assertRaises(ValueError):module.verify(self.repo,other)
        (self.repo/'files/c330m.xml').write_bytes(b'corrupt')
        with self.assertRaises(ValueError):module.verify(self.repo,self.base)

    def test_unlisted_payload_and_unsafe_zip_paths_are_rejected(self):
        (self.repo/'files/extra.xml').write_bytes(b'unlisted')
        with self.assertRaises(ValueError):module.verify(self.repo,self.base)
        with zipfile.ZipFile(self.root/'bad.zip','w') as z:z.writestr('../escape.xml',b'bad')
        with zipfile.ZipFile(self.root/'bad.zip') as z:
            with self.assertRaises(ValueError):module.zip_index(z)

    def test_changed_source_and_existing_payload_require_explicit_regeneration(self):
        (self.source/'c330m.xml').write_bytes(b'different source')
        with self.assertRaises(ValueError):module.verify(self.repo,self.base,self.source)
        with self.assertRaises(ValueError):module.build(self.repo,self.source,self.base)


if __name__ == '__main__':
    unittest.main()
