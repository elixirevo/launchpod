import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'release.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

CASK = '''cask "sample" do
  version "0.1"
  sha256 "old"
  url "https://example.org/old.dmg"
  name "Sample App"
  desc "Preserve description"
  homepage "https://example.org"
  app "Sample App.app"
  zap trash: "~/Library/Sample"
end
'''


class CaskTests(unittest.TestCase):
    def update(self, text=CASK, tag='release-2.0'):
        return m.update_cask(text, 'sample', 'Sample App', '2.0', 'owner/sample', tag, {'arm64': 'a' * 64, 'x86_64': 'b' * 64})

    def test_dual_arch_and_custom_tag_preserve_metadata(self):
        result = self.update()
        self.assertIn('arch arm: "arm64", intel: "x86_64"', result)
        self.assertIn('release-2.0/Sample%20App-#{version}-#{arch}.dmg', result)
        self.assertIn('zap trash: "~/Library/Sample"', result)
        self.assertIn('desc "Preserve description"', result)
        self.assertIn('a' * 64, result)
        self.assertIn('b' * 64, result)

    def test_idempotent(self):
        result = self.update()
        self.assertEqual(result, self.update(result))

    def test_arm_only_cask_has_fixed_url_checksum_and_arch_requirement(self):
        source = CASK.replace('  app ', '  depends_on arch: :arm64\n  app ')
        result = m.update_cask(source, 'sample', 'Sample App', '2.0', 'owner/sample', 'v2.0', {'arm64': 'a' * 64})
        self.assertIn('Sample%20App-#{version}-arm64.dmg', result)
        self.assertIn('sha256 "' + 'a' * 64 + '"', result)
        self.assertIn('depends_on arch: :arm64', result)
        self.assertNotIn('intel', result)
        self.assertNotIn('#{arch}', result)
        self.assertEqual(result, m.update_cask(result, 'sample', 'Sample App', '2.0', 'owner/sample', 'v2.0', {'arm64': 'a' * 64}))

    def test_arm_only_cask_rejects_missing_arch_requirement(self):
        with self.assertRaisesRegex(RuntimeError, 'depends_on'):
            m.update_cask(CASK, 'sample', 'Sample App', '2.0', 'owner/sample', 'v2.0', {'arm64': 'a' * 64})

    def test_reject_wrong_token(self):
        with self.assertRaises(RuntimeError):
            self.update(CASK.replace('cask "sample"', 'cask "another"'))

    def test_reject_conditional_template(self):
        with self.assertRaises(RuntimeError):
            self.update(CASK.replace('  sha256', '  on_arm do\n  sha256'))

    def test_reject_incomplete_template(self):
        with self.assertRaises(RuntimeError):
            self.update(CASK.replace('  version "0.1"\n', ''))

    def test_github_remotes(self):
        for remote in ['git@github.com:owner/app.git', 'https://github.com/owner/app.git', 'ssh://git@github.com/owner/app', 'https://github.com/owner/app']:
            self.assertEqual(m.repository_from_remote(remote), 'owner/app')
        with self.assertRaises(RuntimeError):
            m.repository_from_remote('https://gitlab.com/owner/app')


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='deploy test ')
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.git('init', '-q')
        self.git('config', 'user.email', 'tests@example.invalid')
        self.git('config', 'user.name', 'Deploy Test')
        self.git('remote', 'add', 'origin', 'git@github.com:owner/sample.git')
        (self.root / '.gitignore').write_text('dist/\n.build/\n')
        (self.root / 'Resources').mkdir()
        (self.root / 'Resources/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleName='Sample App', CFBundleExecutable='Sample', CFBundleIdentifier='org.example.sample',
            CFBundleShortVersionString='2.0', CFBundleVersion='42', LSMinimumSystemVersion='13.0',
            SUPublicEDKey='public', SUFeedURL='https://github.com/owner/sample/releases/latest/download/appcast.xml')))
        (self.root / 'deploy.json').write_text(json.dumps({'cask_token': 'sample'}))
        self.r = m.Release(self.root)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def test_defaults_and_space_paths(self):
        self.assertEqual(self.r.builds, {'x86_64': 42, 'arm64': 43})
        self.assertEqual(self.r.repo, 'owner/sample')
        self.assertEqual(self.r.app('arm64').name, 'Sample App.app')

    def test_arm_only_pipeline_uses_plist_build_and_one_dmg(self):
        (self.root / 'deploy.json').write_text(json.dumps({'cask_token': 'sample', 'architectures': ['arm64']}))
        r = m.Release(self.root)
        self.assertEqual(r.builds, {'arm64': 42})
        self.assertEqual([p.name for p in r.assets() if p.suffix == '.dmg'], ['Sample App-2.0-arm64.dmg'])
        with patch.object(r, 'notary') as notarize:
            r.notarize()
        notarize.assert_called_once_with(r.app('arm64'))

    def test_unsupported_architectures_rejected(self):
        for archs in [[], ['x86_64'], ['arm64', 'arm64'], ['armv7']]:
            (self.root / 'deploy.json').write_text(json.dumps({'architectures': archs}))
            with self.assertRaisesRegex(RuntimeError, 'architectures'):
                m.Release(self.root)

    def test_source_hash_survives_commit_but_detects_edit(self):
        before = self.r.source_hash()
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.assertEqual(before, self.r.source_hash())
        (self.root / 'Resources/new.txt').write_text('changed')
        self.assertNotEqual(before, self.r.source_hash())

    def test_ignored_artifacts_do_not_change_source_hash(self):
        before = self.r.source_hash()
        self.r.out.mkdir(parents=True)
        (self.r.out / 'artifact').write_text('data')
        self.assertEqual(before, self.r.source_hash())

    def test_tracked_dist_is_rejected(self):
        self.r.out.mkdir(parents=True)
        (self.r.out / 'artifact').write_text('data')
        self.git('add', '-f', 'dist')
        with self.assertRaisesRegex(RuntimeError, 'dist/'):
            self.r.source_hash()

    def test_step_prerequisites(self):
        self.r.state.update(config=self.r.config_hash(), source=self.r.source_hash())
        with self.assertRaisesRegex(RuntimeError, 'build'):
            self.r.execute('sign')

    def test_mutated_source_rejected(self):
        self.r.state.update(config=self.r.config_hash(), source=self.r.source_hash(), completed=['build'])
        (self.root / 'change.txt').write_text('new')
        with self.assertRaisesRegex(RuntimeError, '소스'):
            self.r.execute('sign')

    def test_failed_stage_can_retry_and_invalidates_downstream(self):
        self.r.state.update(config=self.r.config_hash(), source=self.r.source_hash(), completed=['build'], outputs={})
        with patch.object(self.r, 'sign', side_effect=RuntimeError('interrupted')):
            with self.assertRaisesRegex(RuntimeError, 'interrupted'):
                self.r.execute('sign')
        saved = json.loads(self.r.state_path.read_text())
        self.assertEqual(saved['in_progress'], 'sign')
        self.assertEqual(saved['completed'], ['build'])
        with patch.object(self.r, 'sign'):
            self.r.execute('sign')
        self.assertNotIn('in_progress', self.r.state)
        self.assertEqual(self.r.state['completed'], ['build', 'sign'])

    def test_bundle_tampering_rejected_before_sign(self):
        self.r.state.update(config=self.r.config_hash(), source=self.r.source_hash(), completed=['build'], outputs={})
        self.r.app('arm64').mkdir(parents=True)
        (self.r.app('arm64') / 'injected').write_text('modified')
        with self.assertRaisesRegex(RuntimeError, '산출물'):
            self.r.execute('sign')

    def test_manifest_tampering_rejected(self):
        self.r.out.mkdir(parents=True)
        asset = self.r.out / 'asset.dmg'
        asset.write_text('before')
        self.r.state.update(config=self.r.config_hash(), source=self.r.source_hash(), artifacts={asset.name: m.digest(asset)})
        asset.write_text('after')
        with self.assertRaisesRegex(RuntimeError, '파일 변경'):
            self.r.check_manifest()

    def test_command_argv_is_not_shell_evaluated(self):
        self.r.c['build_command'] = ['build tool', '{app_path}', '$(do-not-run)', '{arch}']
        with patch.object(m, 'run') as run:
            self.r.command('build_command', 'arm64')
        self.assertEqual(run.call_args.args, ('build tool', str(self.r.app('arm64')), '$(do-not-run)', 'arm64'))
        self.assertEqual(run.call_args.kwargs['env']['SIGN_IDENTITY'], '-')

    def test_menu_profile_selected_by_bundle_not_folder(self):
        path = self.root / 'Resources/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['CFBundleIdentifier'] = 'com.elixirevo.MenuBox'
        path.write_bytes(plistlib.dumps(info))
        r = m.Release(self.root)
        self.assertEqual(r.feed, 'menubox-appcast.xml')
        self.assertEqual(r.extra, ['appcast.xml'])

    def test_complete_stage_sequence_and_homebrew_retry(self):
        # Exercise persisted receipts end-to-end without signing or publishing.
        def fake_build():
            self.r.state.update(config=self.r.config_hash(), source=self.r.source_hash())
        def fake_package():
            for arch in m.ARCHS:
                self.r.dmg(arch).write_text(arch)
        def fake_sparkle():
            for p in [*self.r.assets(), self.r.out / (self.r.token + '.rb')]:
                if not p.exists():
                    p.write_text(p.name)
        with patch.object(self.r, 'build', side_effect=fake_build), patch.object(self.r, 'sign'), \
             patch.object(self.r, 'notarize'), patch.object(self.r, 'package', side_effect=fake_package), \
             patch.object(self.r, 'sparkle', side_effect=fake_sparkle), patch.object(self.r, 'validate'), \
             patch.object(self.r, 'github'), patch.object(self.r, 'homebrew'):
            for stage in m.STAGES:
                self.r.execute(stage)
            self.r.execute('homebrew')
        self.assertEqual(self.r.state['completed'], list(m.STAGES))
        restored = m.Release(self.root)
        self.assertEqual(restored.state, self.r.state)

    def test_config_path_traversal_rejected(self):
        (self.root / 'deploy.json').write_text(json.dumps({'version': '../outside'}))
        with self.assertRaises(RuntimeError):
            m.Release(self.root)


if __name__ == '__main__':
    unittest.main()
