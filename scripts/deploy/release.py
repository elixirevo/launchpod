#!/usr/bin/env python3
"""Shared macOS release pipeline. Python stdlib only; commands never use a shell."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from urllib.parse import quote, urlparse

HERE = Path(__file__).resolve().parent
ARCHS = ('arm64', 'x86_64')
STAGES = ('build', 'sign', 'notarize', 'package', 'sparkle', 'validate', 'github', 'homebrew')
NS = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(*args, cwd=None, env=None, capture=False):
    args = [str(arg) for arg in args]
    print('+ ' + shlex.join(args), flush=True)
    return subprocess.run(args, cwd=cwd, env=env, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write_json(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.replace(path)


def repository_from_remote(remote):
    match = re.fullmatch(r'(?:git@github\.com:|https://github\.com/|ssh://git@github\.com/)([^/]+/[^/]+?)(?:\.git)?', remote.strip())
    require(match, 'GitHub origin을 해석할 수 없습니다. repository를 owner/repo로 설정하세요.')
    return match[1]


def update_cask(text, token, name, version, repository, tag, sums):
    require(re.search(r'^cask "' + re.escape(token) + r'" do$', text, re.M), 'Cask token 불일치')
    require(re.search(r'^  app "' + re.escape(name) + r'\.app"$', text, re.M), 'Cask app 이름 불일치')
    # Support dual-architecture and Apple Silicon-only top-level templates.
    require(not re.search(r'^\s+(?:on_arm|on_intel|on_macos|on_system|on_\w+)\b', text, re.M),
            '조건부 cask는 지원하지 않습니다. 단일 arch/sha256 템플릿을 사용하세요.')
    text = re.sub(r'^  arch .+\n', '', text, flags=re.M)
    arm_only = set(sums) == {'arm64'}
    require(arm_only or set(sums) == set(ARCHS), 'Unsupported cask architectures')
    if arm_only:
        require(re.search(r'^  depends_on arch: :arm64$', text, re.M),
                'ARM-only cask requires depends_on arch: :arm64')
    else:
        text = text.replace(f'cask "{token}" do\n', f'cask "{token}" do\n  arch arm: "arm64", intel: "x86_64"\n', 1)
    checksum = (f'  sha256 "{sums["arm64"]}"' if arm_only else
                f'  sha256 arm:   "{sums["arm64"]}",\n         intel: "{sums["x86_64"]}"')
    artifact_arch = 'arm64' if arm_only else '#{arch}'
    replacements = [
        (r'^  version .+$', f'  version "{version}"'),
        (r'^  sha256 [^\n]+(?:\n +(?:arm|intel):[^\n]+)*',
         checksum),
        (r'^  url [^\n]+$', f'  url "https://github.com/{repository}/releases/download/{quote(tag, safe="")}/{quote(name)}-#{{version}}-{artifact_arch}.dmg"'),
    ]
    for pattern, value in replacements:
        text, count = re.subn(pattern, lambda _: value, text, flags=re.M)
        require(count == 1, 'Cask에는 version, sha256, url 항목이 각각 하나씩 있어야 합니다.')
    return text


class Release:
    def __init__(self, root, config=None):
        self.root = Path(root).resolve(strict=True)
        require(self.root.is_dir(), '앱 소스 디렉토리가 필요합니다.')
        default = self.root / 'deploy.json'
        # Bundle identity, not directory name, selects the legacy MenuBox adapter.
        probe = self.root / 'Resources/Info.plist'
        self.c = {}
        if probe.exists() and plistlib.loads(probe.read_bytes()).get('CFBundleIdentifier') == 'com.elixirevo.MenuBox':
            self.c.update(json.loads((HERE / 'profiles/menubox.json').read_text()))
        self.config_path = Path(config).resolve() if config else default
        if config or default.exists():
            self.c.update(json.loads(self.config_path.read_text()))
        self.info = self.path(self.c.get('info_plist', 'Resources/Info.plist'))
        self.plist = plistlib.loads(self.info.read_bytes())
        self.name = self.c.get('app_name', self.plist['CFBundleName'])
        self.executable = self.c.get('executable', self.plist['CFBundleExecutable'])
        self.version = str(self.c.get('version', self.plist['CFBundleShortVersionString']))
        self.archs = tuple(self.c.get('architectures', ARCHS))
        require(self.archs in (('arm64',), ARCHS), 'architectures must be [arm64] or [arm64, x86_64]')
        if self.archs == ('arm64',):
            self.builds = {'arm64': int(self.c.get('arm_build', self.plist['CFBundleVersion']))}
        else:
            self.builds = {'x86_64': int(self.c.get('intel_build', self.plist['CFBundleVersion']))}
            self.builds['arm64'] = int(self.c.get('arm_build', self.builds['x86_64'] + 1))
        self.bundle_id = self.c.get('bundle_id', self.plist['CFBundleIdentifier'])
        self.repo = self.c.get('repository') or repository_from_remote(self.git('config', '--get', 'remote.origin.url'))
        self.tag = self.c.get('tag', 'v' + self.version)
        for label, value in [('app_name', self.name), ('executable', self.executable), ('version', self.version), ('tag', self.tag)]:
            require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+ -]*', value), f'잘못된 {label}: {value}')
        require(re.fullmatch(r'[\w.-]+/[\w.-]+', self.repo), 'repository는 owner/repo 형식이어야 합니다.')
        require(all(b > 0 for b in self.builds.values()), 'Build numbers must be positive')
        if 'x86_64' in self.builds:
            require(self.builds['arm64'] > self.builds['x86_64'], 'arm_build must exceed intel_build')
        self.token = self.c.get('cask_token', self.root.name.lower())
        require(re.fullmatch(r'[a-z0-9][a-z0-9-]*', self.token), '잘못된 cask_token')
        self.feed = self.c.get('feed_name', Path(urlparse(self.plist.get('SUFeedURL', 'appcast.xml')).path).name)
        self.extra = self.c.get('extra_assets', [])
        for name in [self.feed, *self.extra]:
            require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name), 'feed/extra_assets는 파일명만 허용합니다.')
        require(self.feed not in self.extra and len(set(self.extra)) == len(self.extra), '중복된 extra_assets')
        self.out = self.root / 'dist' / 'deploy' / self.version
        self.notes = self.path(self.c.get('notes_file', f'docs/releases/{self.version}.md'))
        self.tap = self.path(self.c.get('tap_path', '../homebrew-tap'))
        self.template = self.path(self.c.get('cask_template', f'homebrew/Casks/{self.token}.rb'))
        self.identity = os.environ.get('SIGN_IDENTITY', self.c.get('sign_identity', ''))
        self.profile = os.environ.get('NOTARY_PROFILE', self.c.get('notary_profile', self.token))
        self.account = os.environ.get('SPARKLE_KEY_ACCOUNT', self.c.get('sparkle_account', self.token))
        self.feed_url = f'https://github.com/{self.repo}/releases/latest/download/{self.feed}'
        self.prefix = f'https://github.com/{self.repo}/releases/download/{quote(self.tag, safe="")}/'
        reserved = {self.feed, 'state.json', 'SHA256SUMS.txt', self.token + '.rb',
                    *(self.dmg(a).name for a in self.archs)}
        require(not reserved.intersection(self.extra), 'extra_assets가 기본 산출물과 충돌합니다.')
        self.state_path = self.out / 'state.json'
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}

    def path(self, value):
        p = Path(value).expanduser()
        return p.resolve() if p.is_absolute() else (self.root / p).resolve()

    def git(self, *args, root=None):
        return run('git', '-C', root or self.root, *args, capture=True).strip()

    def app(self, arch):
        return self.out / arch / (self.name + '.app')

    def dmg(self, arch):
        return self.out / f'{self.name}-{self.version}-{arch}.dmg'

    def tool(self, name):
        base = self.path(self.c['sparkle_bin']) if self.c.get('sparkle_bin') else self.root / '.build/artifacts'
        matches = [base / name] if self.c.get('sparkle_bin') else sorted(base.rglob(name))
        found = next((p for p in matches if p.is_file() and os.access(p, os.X_OK)), None)
        require(found, f'Sparkle {name} 없음: swift package resolve 또는 sparkle_bin 설정이 필요합니다.')
        return found

    def config_hash(self):
        return hashlib.sha256(json.dumps([self.c, self.plist, self.identity, self.profile, self.account],
                                        sort_keys=True, default=str).encode()).hexdigest()

    def source_hash(self):
        # Committing the prepared source does not invalidate artifacts; changing it does.
        raw = run('git', '-C', self.root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', capture=True)
        h = hashlib.sha256()
        for name in sorted(set(raw.split('\0')) - {''}):
            p = self.root / name
            require(not p.is_relative_to(self.root / 'dist'), 'dist/를 .gitignore에 추가하고 추적 대상에서 제외하세요.')
            h.update(name.encode() + b'\0')
            if p.is_symlink():
                h.update(os.readlink(p).encode())
            elif p.is_file():
                h.update(str(p.stat().st_mode & 0o111).encode())
                h.update(digest(p).encode())
            else:
                require(not p.is_dir(), 'Git submodule은 지원하지 않습니다. 별도 build adapter를 구성하세요.')
                h.update(b'<deleted>')
        return h.hexdigest()

    def check_source(self):
        require(self.state.get('config') == self.config_hash(), '설정이 변경됐습니다. build부터 다시 실행하세요.')
        require(self.state.get('source') == self.source_hash(), '빌드 이후 소스가 변경됐습니다. build부터 다시 실행하세요.')

    def command(self, key, arch=None):
        values = dict(arch=arch or '', version=self.version, arm_build=self.builds['arm64'],
                      repository=self.repo, tag=self.tag, output=str(self.out), app_path=str(self.app(arch)) if arch else '')
        cmd = self.c[key]
        require(isinstance(cmd, list) and cmd and all(isinstance(s, str) for s in cmd), f'{key}는 문자열 배열이어야 합니다.')
        # Replace only known placeholders; preserve Ruby/Swift/JSON braces in arguments.
        for k, value in values.items():
            cmd = [s.replace('{' + k + '}', str(value)) for s in cmd]
        env = dict(os.environ, APP_NAME=self.name, PRODUCT_NAME=self.name, EXECUTABLE_NAME=self.executable,
                   APP_VERSION=self.version, BUNDLE_ID=self.bundle_id, APP_ROOT=str(self.root),
                   RELEASE_TAG=self.tag, GITHUB_REPOSITORY=self.repo, DEPLOY_OUTPUT=str(self.out))
        if arch:
            env.update(ARCH=arch, APP_BUILD=str(self.builds[arch]), DIST_DIR=str(self.out / arch),
                       APP_PATH=str(self.app(arch)), SIGN_IDENTITY='-')
        run(*cmd, cwd=self.root, env=env)

    def doctor(self):
        require(sys.platform == 'darwin', 'macOS에서 실행하세요.')
        for tool in ('git', 'swift', 'codesign', 'security', 'xcrun', 'ditto', 'hdiutil', 'lipo', 'spctl', 'gh', 'brew', 'ruby'):
            require(shutil.which(tool), f'필요한 명령 없음: {tool}')
        require(self.notes.is_file(), f'릴리스 노트 없음: {self.notes}')
        require(self.template.is_file(), f'Cask 템플릿 없음: {self.template}')
        require(self.tap.is_dir(), f'Homebrew tap 체크아웃 없음: {self.tap}')
        require(self.identity.startswith('Developer ID Application:'), 'SIGN_IDENTITY에 Developer ID Application 인증서를 지정하세요.')
        require(self.identity in run('security', 'find-identity', '-v', '-p', 'codesigning', capture=True), '서명 인증서/개인키를 찾을 수 없습니다.')
        run('xcrun', 'notarytool', 'history', '--keychain-profile', self.profile, '--output-format', 'json', capture=True)
        run('gh', 'auth', 'status')
        require(self.plist.get('SUFeedURL') == self.feed_url, f'SUFeedURL을 {self.feed_url} 로 설정하세요.')
        require(self.plist.get('SUPublicEDKey'), 'Info.plist의 SUPublicEDKey가 필요합니다.')
        # Tools may be downloaded by the initial build. If already present, check now.
        if (self.root / '.build/artifacts').exists() or self.c.get('sparkle_bin'):
            self.check_key()
        self.check_git_target()
        print('사전 점검 완료')

    def check_key(self):
        key = run(self.tool('generate_keys'), '--account', self.account, '-p', capture=True).strip()
        require(key == self.plist.get('SUPublicEDKey'), 'Sparkle Keychain 공개키와 Info.plist가 다릅니다.')

    def check_git_target(self):
        require(Path(self.git('rev-parse', '--show-toplevel')).resolve() == self.root,
                '앱 경로는 독립 Git 저장소 루트여야 합니다.')
        require(repository_from_remote(self.git('config', '--get', 'remote.origin.url')) == self.repo,
                'origin과 repository가 다릅니다.')

    def build(self):
        self.check_git_target()
        before = self.source_hash()
        for arch in self.archs:
            app = self.app(arch)
            if app.exists():
                shutil.rmtree(app)
            app.parent.mkdir(parents=True, exist_ok=True)
            if self.c.get('build_command'):
                self.command('build_command', arch)
            else:
                self.swift_build(arch)
            self.check_bundle(app, arch)
        require(before == self.source_hash(), '빌드가 소스 파일을 변경했습니다. 변경을 검토한 뒤 build를 다시 실행하세요.')
        self.state.update(source=before, config=self.config_hash())

    def swift_build(self, arch):
        require((self.root / 'Package.swift').exists(), 'build_command 또는 Swift Package.swift가 필요합니다.')
        args = ['swift', 'build', '-c', 'release', '--arch', arch, '--product', self.executable]
        run(*args, cwd=self.root)
        binary_dir = Path(run(*args, '--show-bin-path', cwd=self.root, capture=True).strip())
        app = self.app(arch)
        contents = app / 'Contents'
        for d in ('MacOS', 'Resources', 'Frameworks'):
            (contents / d).mkdir(parents=True)
        shutil.copy2(binary_dir / self.executable, contents / 'MacOS' / self.executable)
        run('install_name_tool', '-add_rpath', '@executable_path/../Frameworks', contents / 'MacOS' / self.executable)
        info = dict(self.plist, CFBundleVersion=str(self.builds[arch]), CFBundleShortVersionString=self.version,
                    CFBundleName=self.name, CFBundleExecutable=self.executable, CFBundleIdentifier=self.bundle_id)
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        for p in self.info.parent.iterdir():
            if p.name != 'Info.plist':
                run('ditto', p, contents / 'Resources' / p.name)
        for p in binary_dir.glob('*.bundle'):
            run('ditto', p, contents / 'Resources' / p.name)
        framework = self.path(self.c['sparkle_framework']) if self.c.get('sparkle_framework') else next(
            iter(sorted((self.root / '.build/artifacts').glob('**/macos-arm64_x86_64/Sparkle.framework'))), None)
        require(framework and framework.is_dir(), 'sparkle_framework에 Sparkle.framework 경로를 지정하세요.')
        run('ditto', framework, contents / 'Frameworks/Sparkle.framework')

    def check_bundle(self, app, arch):
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        expected = dict(CFBundleIdentifier=self.bundle_id, CFBundleExecutable=self.executable,
                        CFBundleName=self.name, CFBundleShortVersionString=self.version,
                        CFBundleVersion=str(self.builds[arch]), SUFeedURL=self.feed_url,
                        SUPublicEDKey=self.plist.get('SUPublicEDKey'))
        for key in ('LSMinimumSystemVersion', 'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
            if key in self.plist:
                expected[key] = self.plist[key]
        for key, value in expected.items():
            require(value is not None and info.get(key) == value, f'{arch}: 번들 {key} 불일치')
        slices = run('lipo', '-archs', app / 'Contents/MacOS' / self.executable, capture=True).strip()
        require(slices == arch, f'{arch}: 잘못된 아키텍처 {slices}')
        require((app / 'Contents/Frameworks/Sparkle.framework').is_dir(), 'Sparkle.framework가 번들에 없습니다.')
        if self.archs == ('arm64',):
            for path in (app / 'Contents/Frameworks').rglob('*'):
                if path.is_symlink() or not path.is_file():
                    continue
                with path.open('rb') as stream:
                    magic = stream.read(4)
                if magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                             b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                    slices = run('lipo', '-archs', path, capture=True).strip()
                    require(slices == 'arm64', f'Embedded binary is not arm64-only: {path}: {slices}')

    def codesign(self, target, app=False, preserve=False):
        require(self.identity.startswith('Developer ID Application:'), 'SIGN_IDENTITY가 필요합니다.')
        args = ['codesign', '--force', '--timestamp', '--sign', self.identity]
        if target.suffix != '.dmg':
            args += ['--options', 'runtime']
        if preserve:
            args += ['--preserve-metadata=entitlements']
        if app and self.c.get('entitlements'):
            args += ['--entitlements', self.path(self.c['entitlements'])]
        run(*args, target)

    def sign(self):
        for arch in self.archs:
            app = self.app(arch)
            # Deepest Mach-O files first, then their containing bundles. Never use --deep to sign.
            for p in sorted(app.rglob('*'), key=lambda p: len(p.parts), reverse=True):
                if p.is_symlink():
                    continue
                if p.is_file():
                    with p.open('rb') as stream:
                        magic = stream.read(4)
                    if magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                        self.codesign(p, preserve=True)
                elif p.suffix in ('.app', '.xpc', '.framework', '.appex', '.bundle'):
                    # Resource-only .bundle directories do not need signing.
                    if p.suffix != '.bundle' or (p / 'Contents/MacOS').exists():
                        self.codesign(p, preserve=True)
            self.codesign(app, app=True, preserve=True)
            run('codesign', '--verify', '--deep', '--strict', app)

    def notary(self, target):
        logs = self.out / 'notarization'
        logs.mkdir(exist_ok=True)
        upload = target
        if target.suffix == '.app':
            upload = logs / (target.parent.name + '.zip')
            upload.unlink(missing_ok=True)
            run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', target, upload)
        record = logs / (target.parent.name + '-' + target.name + '.json')
        sha = digest(upload)
        previous = json.loads(record.read_text()) if record.exists() else {}
        if previous.get('sha256') == sha and previous.get('profile') == self.profile:
            submission = previous['id']
        else:
            result = json.loads(run('xcrun', 'notarytool', 'submit', upload, '--keychain-profile', self.profile,
                                    '--output-format', 'json', capture=True))
            submission = result['id']
            write_json(record, dict(id=submission, sha256=sha, profile=self.profile))
        # Submission ID survives interruptions and is reused for identical uploads.
        result = json.loads(run('xcrun', 'notarytool', 'wait', submission, '--keychain-profile', self.profile,
                                '--output-format', 'json', capture=True))
        write_json(record.with_suffix('.result.json'), result)
        run('xcrun', 'notarytool', 'log', submission, '--keychain-profile', self.profile, record.with_suffix('.log.json'))
        require(result.get('status') == 'Accepted', f'Apple 공증 실패: {record}')
        run('xcrun', 'stapler', 'staple', target)
        self.verify_apple(target)

    def verify_apple(self, target):
        run('codesign', '--verify', '--deep', '--strict', target)
        details = subprocess.run(['codesign', '-d', '--verbose=4', str(target)],
                                 check=True, capture_output=True, text=True).stderr
        require('Authority=' + self.identity in details.splitlines(), 'Developer ID 서명 인증서 불일치')
        run('xcrun', 'stapler', 'validate', target)
        if target.suffix == '.app':
            run('spctl', '--assess', '--type', 'execute', target)
        else:
            run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', target)

    def notarize(self):
        for arch in self.archs:
            self.notary(self.app(arch))

    def package(self):
        for arch in self.archs:
            self.verify_apple(self.app(arch))
            with tempfile.TemporaryDirectory(prefix='mac-deploy-') as temp:
                stage = Path(temp) / 'stage'
                stage.mkdir()
                run('ditto', self.app(arch), stage / (self.name + '.app'))
                (stage / 'Applications').symlink_to('/Applications')
                run('hdiutil', 'create', '-volname', self.name, '-srcfolder', stage, '-fs', 'HFS+',
                    '-format', 'UDZO', '-ov', self.dmg(arch))
            self.codesign(self.dmg(arch))
            run('hdiutil', 'verify', self.dmg(arch))
            self.notary(self.dmg(arch))

    def sparkle(self):
        self.check_key()
        # Fresh generation directory prevents stale versions / notes from entering the feed.
        with tempfile.TemporaryDirectory(prefix='appcast-', dir=self.out) as temp:
            folder = Path(temp)
            for arch in self.archs:
                shutil.copy2(self.dmg(arch), folder / self.dmg(arch).name)
                shutil.copy2(self.notes, folder / (self.dmg(arch).stem + '.md'))
            run(self.tool('generate_appcast'), '--account', self.account,
                '--download-url-prefix', self.prefix, '--embed-release-notes', '--link', f'https://github.com/{self.repo}',
                '--maximum-versions', '1', '--maximum-deltas', '0', '-o', folder / self.feed, folder)
            shutil.copy2(folder / self.feed, self.out / self.feed)
        # Explicit signing also supports feeds whose clients do not yet require signed feeds.
        run(self.tool('sign_update'), '--account', self.account, self.out / self.feed)
        if self.c.get('extra_feed_command'):
            self.command('extra_feed_command')
        sums = {a: digest(self.dmg(a)) for a in self.archs}
        (self.out / 'SHA256SUMS.txt').write_text(''.join(f'{sums[a]}  {self.dmg(a).name}\n' for a in self.archs))
        cask = update_cask(self.template.read_text(), self.token, self.name, self.version, self.repo, self.tag, sums)
        (self.out / (self.token + '.rb')).write_text(cask)
        run('ruby', '-c', self.out / (self.token + '.rb'))

    def assets(self):
        return [*(self.dmg(a) for a in self.archs), self.out / self.feed, self.out / 'SHA256SUMS.txt',
                *(self.out / name for name in self.extra)]

    def validate(self):
        self.check_key()
        run(self.tool('sign_update'), '--account', self.account, '--verify', self.out / self.feed)
        items = ET.parse(self.out / self.feed).findall('channel/item')
        require(len(items) == len(self.archs), 'appcast must contain one item per architecture')
        seen = set()
        for item in items:
            enclosure = item.find('enclosure')
            require(enclosure is not None, 'appcast enclosure 없음')
            arch = next((a for a in self.archs if enclosure.get('url') == self.prefix + quote(self.dmg(a).name)), None)
            require(arch and arch not in seen, 'appcast 다운로드 URL/아키텍처 중복 또는 불일치')
            seen.add(arch)
            require(item.findtext('s:version', namespaces=NS) == str(self.builds[arch]), 'appcast 빌드 번호 불일치')
            require(item.findtext('s:shortVersionString', namespaces=NS) == self.version, 'appcast 버전 불일치')
            require(item.findtext('s:minimumSystemVersion', namespaces=NS) == self.plist['LSMinimumSystemVersion'], '최소 OS 불일치')
            require(item.findtext('s:hardwareRequirements', namespaces=NS) == ('arm64' if arch == 'arm64' else None), 'Sparkle 하드웨어 라우팅 불일치')
            require(item.find('description') is not None, '내장 릴리스 노트 없음')
            require(int(enclosure.get('length', '0')) == self.dmg(arch).stat().st_size, 'DMG 크기 불일치')
            signature = enclosure.get('{' + NS['s'] + '}edSignature')
            require(signature, 'Sparkle 업데이트 서명 없음')
            run(self.tool('sign_update'), '--account', self.account, '--verify', self.dmg(arch), signature)
            self.verify_apple(self.dmg(arch))
            mounted = plistlib.loads(run('hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', self.dmg(arch), capture=True).encode())
            mounts = [Path(e['mount-point']) for e in mounted['system-entities'] if 'mount-point' in e]
            require(mounts, 'DMG mount 실패')
            try:
                app = mounts[0] / (self.name + '.app')
                self.check_bundle(app, arch)
                self.verify_apple(app)
            finally:
                for mount in mounts:
                    run('hdiutil', 'detach', mount)
        sums = {a: digest(self.dmg(a)) for a in self.archs}
        require((self.out / 'SHA256SUMS.txt').read_text() == ''.join(f'{sums[a]}  {self.dmg(a).name}\n' for a in self.archs), 'SHA256SUMS 불일치')
        expected = update_cask(self.template.read_text(), self.token, self.name, self.version, self.repo, self.tag, sums)
        require((self.out / (self.token + '.rb')).read_text() == expected, 'Cask 해시/내용 불일치')
        for path in self.assets():
            require(path.is_file(), f'릴리스 파일 없음: {path}')
        if self.bundle_id == 'com.elixirevo.MenuBox':
            legacy = ET.parse(self.out / 'appcast.xml').findall('channel/item')
            require(len(legacy) == 1 and legacy[0].find('enclosure') is None, 'MenuBox legacy feed는 안내 전용이어야 합니다.')
            require(legacy[0].findtext('link') == f'https://github.com/{self.repo}/releases/tag/{self.tag}', 'legacy 링크 불일치')
        self.state['artifacts'] = {p.name: digest(p) for p in [*self.assets(), self.out / (self.token + '.rb')]}
        self.state['notes'] = digest(self.notes)

    def check_manifest(self):
        self.check_source()
        require(self.state.get('artifacts'), 'validate를 먼저 실행하세요.')
        for name, sha in self.state['artifacts'].items():
            require(digest(self.out / name) == sha, f'검증 이후 파일 변경: {name}')
        require(digest(self.notes) == self.state['notes'], '검증 이후 릴리스 노트 변경')

    def release_info(self):
        # Listing succeeds independently of whether this particular tag exists;
        # authentication/network failures must not masquerade as a missing release.
        data = json.loads(run('gh', 'api', '--paginate', '--slurp', f'repos/{self.repo}/releases?per_page=100', capture=True))
        return next((r for page in data for r in page if r['tag_name'] == self.tag), None)

    def remote_assets_match(self, release):
        require(not release['draft'] and not release['prerelease'], '공개 정식 GitHub release가 필요합니다.')
        require({a['name'] for a in release['assets']} == {p.name for p in self.assets()}, 'GitHub 자산 목록 불일치')
        with tempfile.TemporaryDirectory(prefix='release-verify-') as temp:
            run('gh', 'release', 'download', self.tag, '--repo', self.repo, '--dir', temp)
            for p in self.assets():
                require(digest(Path(temp) / p.name) == digest(p), f'GitHub 업로드 해시 불일치: {p.name}')

    def github(self):
        self.check_manifest()
        self.check_git_target()
        require(not self.git('status', '--porcelain'), 'GitHub 배포 전에 앱 소스 변경을 커밋하세요.')
        require(self.release_info() is None, '동일 태그의 GitHub release가 이미 있습니다. 덮어쓰지 않습니다.')
        head = self.git('rev-parse', 'HEAD')
        tags = self.git('tag', '--list', self.tag)
        if tags:
            require(self.git('rev-parse', self.tag + '^{commit}') == head, '로컬 태그가 HEAD와 다릅니다.')
        else:
            self.git('tag', '-a', self.tag, '-m', f'{self.name} {self.version}')
        branch = self.git('symbolic-ref', '--short', 'HEAD')
        self.git('push', 'origin', f'HEAD:refs/heads/{branch}')
        self.git('push', 'origin', f'refs/tags/{self.tag}')
        run('gh', 'release', 'create', self.tag, '--repo', self.repo, '--verify-tag', '--draft',
            '--title', f'{self.name} {self.version}', '--notes-file', self.notes, *self.assets())
        # Verify uploaded bytes while the release is still a draft.
        with tempfile.TemporaryDirectory(prefix='draft-verify-') as temp:
            run('gh', 'release', 'download', self.tag, '--repo', self.repo, '--dir', temp)
            for p in self.assets():
                require(digest(Path(temp) / p.name) == digest(p), f'업로드 해시 불일치: {p.name}')
        run('gh', 'release', 'edit', self.tag, '--repo', self.repo, '--draft=false', '--latest')
        self.state['github_commit'] = head

    def homebrew(self):
        self.check_manifest()
        release = self.release_info()
        require(release, 'GitHub release를 먼저 공개하세요.')
        self.remote_assets_match(release)
        require(Path(self.git('rev-parse', '--show-toplevel', root=self.tap)).resolve() == self.tap, 'tap_path는 독립 Git 저장소여야 합니다.')
        require(not self.git('status', '--porcelain', root=self.tap), 'Homebrew tap 변경을 먼저 커밋하거나 정리하세요.')
        target = self.tap / 'Casks' / (self.token + '.rb')
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(self.out / (self.token + '.rb'), target)
        # Audit an isolated local tap. Existing rename metadata stays in the checkout.
        audit_tap = f'deploy-check/{self.token}-{os.getpid()}'
        trust_supported = False
        try:
            run('brew', 'tap', '--custom-remote', audit_tap, self.tap)
            audit_dir = Path(run('brew', '--repository', audit_tap, capture=True).strip())
            shutil.copy2(target, audit_dir / 'Casks' / target.name)
            # New Homebrew versions require explicit trust even for local audit taps.
            trust_supported = subprocess.run(['brew', 'help', 'trust'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if trust_supported:
                run('brew', 'trust', '--cask', f'{audit_tap}/{self.token}')
            run('brew', 'audit', '--cask', f'{audit_tap}/{self.token}')
            run('brew', 'style', audit_dir / 'Casks' / target.name)
        except Exception:
            # Restore only our file, never unrelated changes.
            tracked = self.git('ls-files', '--', f'Casks/{target.name}', root=self.tap)
            if tracked:
                self.git('restore', '--', f'Casks/{target.name}', root=self.tap)
            else:
                target.unlink(missing_ok=True)
            raise
        finally:
            subprocess.run(['brew', 'untap', audit_tap], check=False)
            if trust_supported:
                subprocess.run(['brew', 'untrust', '--cask', f'{audit_tap}/{self.token}'], check=False)
        relative = f'Casks/{target.name}'
        self.git('add', '--', relative, root=self.tap)
        if self.git('diff', '--cached', '--name-only', root=self.tap):
            self.git('commit', '-m', f'{self.token} {self.version}', '--', relative, root=self.tap)
        self.git('push', root=self.tap)

    def outputs(self, stage):
        paths = []
        if stage in ('build', 'sign', 'notarize'):
            for arch in self.archs:
                paths.extend(p for p in self.app(arch).rglob('*') if p.is_file() or p.is_symlink())
        elif stage == 'package':
            paths = [self.dmg(a) for a in self.archs]
        else:
            paths = [*self.assets(), self.out / (self.token + '.rb')]
        return {str(p.relative_to(self.out)): ('link:' + os.readlink(p) if p.is_symlink() else digest(p)) for p in paths}

    def execute(self, stage):
        completed = self.state.get('completed', [])
        index = STAGES.index(stage)
        if stage != 'build':
            self.check_source()
            # Homebrew can recover a failed push after GitHub already published.
            previous = 'validate' if stage == 'homebrew' else STAGES[index - 1]
            require(previous in completed, f'{previous} 단계를 먼저 실행하세요.')
            pending = self.state.get('in_progress')
            require(pending in (None, stage) or (stage == 'homebrew' and pending == 'github'),
                    f'{pending} 단계가 미완료입니다. 그 단계 또는 build부터 다시 실행하세요.')
            if pending is None:
                require(self.state.get('outputs') == self.outputs(completed[-1]), '이전 단계 이후 산출물이 변경됐습니다. build부터 다시 생성하세요.')
        # Invalidate downstream receipts *before* mutation, even if the stage fails.
        self.state['completed'] = [s for s in completed if STAGES.index(s) < index]
        self.state['in_progress'] = stage
        if index <= STAGES.index('validate'):
            self.state.pop('artifacts', None)
        self.out.mkdir(parents=True, exist_ok=True)
        write_json(self.state_path, self.state)
        print(f'\n=== {stage}: {self.name} {self.version} ===', flush=True)
        getattr(self, stage)()
        self.state.pop('in_progress', None)
        self.state['outputs'] = self.outputs(stage)
        self.state['completed'].append(stage)
        write_json(self.state_path, self.state)


@contextlib.contextmanager
def lock(root):
    # Per-app lock, outside the source tree, covers all versions and processes.
    key = hashlib.sha256(str(root).encode()).hexdigest()
    with (Path(tempfile.gettempdir()) / ('mac-deploy-' + key + '.lock')).open('a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('이 앱의 배포가 이미 실행 중입니다.')
        yield


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app_path', type=Path, help='앱 Git 저장소 경로')
    parser.add_argument('stage', nargs='?', default='prepare', choices=['plan', 'doctor', 'prepare', 'publish', 'all', *STAGES])
    parser.add_argument('--config', type=Path, help='deploy.json 대체 파일')
    args = parser.parse_args()
    try:
        with lock(args.app_path.resolve()):
            r = Release(args.app_path, args.config)
            if args.stage == 'plan':
                print(json.dumps(dict(app=r.name, version=r.version, builds=r.builds, repository=r.repo,
                                      tag=r.tag, output=str(r.out), stages=STAGES, completed=r.state.get('completed', []),
                                      build_command=r.c.get('build_command', 'built-in SwiftPM'),
                                      feed=r.feed, extra_assets=r.extra, tap=str(r.tap)), indent=2))
                return 0
            if args.stage == 'doctor':
                r.doctor()
                return 0
            if args.stage in ('prepare', 'all'):
                r.doctor()
            stages = STAGES[:6] if args.stage == 'prepare' else STAGES[6:] if args.stage == 'publish' else STAGES if args.stage == 'all' else [args.stage]
            for stage in stages:
                r.execute(stage)
            print(f'\n완료: {args.stage}\n산출물: {r.out}')
        return 0
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.CalledProcessError, ET.ParseError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
