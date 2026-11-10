import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('appcast', Path(__file__).parents[1] / 'scripts/validate-appcast.py')
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.archive = Path(self.tmp.name) / 'ElectronicClam-0.8.0.zip'
        self.archive.write_bytes(b'archive-fixture')
        self.feed = Path(self.tmp.name) / 'appcast.xml'
        self.root = ET.fromstring('''<rss><channel><item><enclosure /></item></channel></rss>''')
        self.item = self.root.find('./channel/item')
        self.enc = self.item.find('enclosure')
        self.enc.set('url', 'https://github.com/jadhvank/eclam/releases/download/v0.8.0/' + self.archive.name)
        self.enc.set('length', str(self.archive.stat().st_size))
        self.enc.set(appcast.SPARKLE + 'edSignature', base64.b64encode(bytes(64)).decode())
        ET.SubElement(self.item, appcast.SPARKLE + 'version').text = '0.8.0'
        ET.SubElement(self.item, appcast.SPARKLE + 'shortVersionString').text = '0.8.0'

    def validate(self):
        ET.ElementTree(self.root).write(self.feed)
        appcast.validate(self.feed, self.archive, '0.8.0', '0.8.0', 'jadhvank/eclam')

    def test_matching_release(self):
        self.validate()

    def test_wrong_repository(self):
        self.enc.set('url', 'https://example.com/update.zip')
        with self.assertRaises(ValueError): self.validate()

    def test_archive_changed_after_generation(self):
        self.archive.write_bytes(b'changed')
        with self.assertRaises(ValueError): self.validate()

    def test_unsigned_enclosure(self):
        del self.enc.attrib[appcast.SPARKLE + 'edSignature']
        with self.assertRaises(ValueError): self.validate()

    def test_stale_build(self):
        self.item.find(appcast.SPARKLE + 'version').text = '0.7.0'
        with self.assertRaises(ValueError): self.validate()

    def test_multiple_items(self):
        ET.SubElement(self.root.find('channel'), 'item')
        with self.assertRaises(ValueError): self.validate()


class ReleaseVersionTests(unittest.TestCase):
    def test_only_increasing_stable_versions(self):
        spec = importlib.util.spec_from_file_location('versions', Path(__file__).parents[1] / 'scripts/validate-release-version.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.validate('0.8.0', '0.8.0', 'v0.7.0')
        for current, build, old in [('0.7.0', '0.7.0', 'v0.7.0'),
                                    ('0.6.0', '0.6.0', 'v0.7.0'),
                                    ('0.8.0-beta', '0.8.0-beta', 'v0.7.0'),
                                    ('0.8.0', '0.7.0', 'v0.7.0')]:
            with self.assertRaises(ValueError): module.validate(current, build, old)


if __name__ == '__main__':
    unittest.main()
