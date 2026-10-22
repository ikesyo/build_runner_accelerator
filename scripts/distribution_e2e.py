#!/usr/bin/env python3
"""Exercise a packaged frontend through a Dart-only consumer over local HTTPS.

No production files or trust settings are modified. Keep --results outside the
consumer workspace; it contains reproducible evidence and process logs.
"""
from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import ssl
import subprocess
import tempfile
import threading
import time


REPO = Path(__file__).resolve().parents[1]
# macOS ships LibreSSL; use the runner's Homebrew OpenSSL for Ed25519.
OPENSSL = next((str(path) for path in (
    Path('/opt/homebrew/opt/openssl@3/bin/openssl'),
    Path('/usr/local/opt/openssl@3/bin/openssl')) if path.is_file()), 'openssl')


def run(command, *, cwd, env=None, log=None, timeout=300):
    result = subprocess.run([str(arg) for arg in command], cwd=cwd, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout)
    if log:
        log.write_bytes(result.stdout)
    if result.returncode:
        raise RuntimeError(f'{command} failed ({result.returncode}):\n'
                           + result.stdout.decode(errors='replace'))
    return result.stdout


def outputs(workspace):
    # All public fixture outputs, including unexpected generated paths.
    return {p.relative_to(workspace).as_posix(): p.read_bytes()
            for p in (workspace / 'lib').rglob('*')
            if p.is_file() and p.name != 'model.dart'}


def compare(stock, native):
    expected, actual = outputs(stock), outputs(native)
    if not expected or expected != actual:
        raise AssertionError(f'output set/bytes differ: stock={list(expected)}, native={list(actual)}')
    return {key: hashlib.sha256(value).hexdigest() for key, value in actual.items()}


def wait_for(predicate, process, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'watch exited early: {process.returncode}')
        if predicate():
            return
        time.sleep(0.1)
    raise TimeoutError('watch did not reach the expected state')


def stop(process):
    if os.name == 'nt':
        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    else:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        if os.name == 'nt':
            process.kill()
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=10)


def create_https_certificates(root):
    """Use a CA and a server-auth leaf accepted by platform trust engines."""
    ca, ca_key = root / 'ca.pem', root / 'ca-key.pem'
    certificate, tls_key = root / 'localhost.pem', root / 'localhost-key.pem'
    request, extensions = root / 'localhost.csr', root / 'localhost.ext'
    run([OPENSSL, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
         '-subj', '/CN=Distribution E2E Test CA',
         '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0',
         '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
         '-keyout', ca_key, '-out', ca], cwd=root)
    run([OPENSSL, 'req', '-new', '-newkey', 'rsa:2048', '-nodes',
         '-subj', '/CN=localhost', '-keyout', tls_key, '-out', request], cwd=root)
    extensions.write_text(
        'basicConstraints=critical,CA:FALSE\n'
        'keyUsage=critical,digitalSignature,keyEncipherment\n'
        'extendedKeyUsage=serverAuth\n'
        'subjectAltName=DNS:localhost,IP:127.0.0.1\n'
        'subjectKeyIdentifier=hash\n'
        'authorityKeyIdentifier=keyid,issuer\n')
    run([OPENSSL, 'x509', '-req', '-in', request, '-CA', ca, '-CAkey', ca_key,
         '-CAcreateserial', '-days', '1', '-sha256', '-extfile', extensions,
         '-out', certificate], cwd=root)
    return ca, certificate, tls_key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', required=True, type=Path)
    parser.add_argument('--target', required=True)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--results', required=True, type=Path)
    # Production post-sign verification uses the original package public key.
    parser.add_argument('--signed-dist', type=Path)
    parser.add_argument('--verify-install-only', action='store_true',
                        help='Verify/install every final signed artifact; run the host binary smoke only')
    parser.add_argument('--test-public-key', type=Path,
                        help='Dry-run signing public key; applied only to the disposable package copy')
    args = parser.parse_args()
    if args.verify_install_only and not args.signed_dist:
        parser.error('--verify-install-only requires --signed-dist')
    if args.signed_dist:
        args.signed_dist = args.signed_dist.resolve()
    if args.test_public_key:
        args.test_public_key = args.test_public_key.resolve()
    if args.test_public_key and not args.signed_dist:
        parser.error('--test-public-key requires --signed-dist')
    started = time.monotonic()
    dart, archive, results = args.dart.resolve(), args.archive.resolve(), args.results.resolve()
    results.mkdir(parents=True, exist_ok=True)
    version = re.search(r'^version: (.+)$', (REPO / 'pubspec.yaml').read_text(), re.M)[1]
    evidence = {'target': args.target, 'version': version,
                'source_commit': run(['git', 'rev-parse', 'HEAD'], cwd=REPO).decode().strip(),
                'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                'production_signature': bool(args.signed_dist and not args.test_public_key), 'stages': {}, 'timings_seconds': {}}
    with tempfile.TemporaryDirectory(prefix='distribution-e2e-') as temporary:
        root = Path(temporary)
        payload = root / 'package'
        payload.mkdir()
        # Only the portable pub payload: never copy rust/, .dart_tool or caches.
        for name in ('lib', 'bin', 'tool', 'pubspec.yaml', 'README.md', 'LICENSE', 'CHANGELOG.md', 'example', 'rust-toolchain.toml'):
            source = REPO / name
            if source.is_dir():
                shutil.copytree(source, payload / name)
            else:
                shutil.copy2(source, payload / name)
        serving = root / 'https' / f'v{version}'
        serving.mkdir(parents=True)
        shutil.copy2(archive, serving / archive.name)
        if args.signed_dist:
            signed_manifest = json.loads((args.signed_dist / 'release-manifest.json').read_text())
            assert signed_manifest['source_commit'] == evidence['source_commit']
            for item in signed_manifest['artifacts']:
                shutil.copy2(args.signed_dist / item['filename'], serving / item['filename'])
            for name in ('release-manifest.json', 'release-manifest.json.sig'):
                shutil.copy2(args.signed_dist / name, serving / name)
        else:
            key = root / 'test-signing.pem'
            run([OPENSSL, 'genpkey', '-algorithm', 'ED25519', '-out', key], cwd=root)
            public = run([OPENSSL, 'pkey', '-in', key, '-pubout', '-outform', 'DER'], cwd=root)[-32:]
            trust_file = payload / 'lib/src/release_downloader.dart'
            text, count = re.subn(r"(const releaseSigningPublicKeyBase64 =\s*)'[^']+'",
                                 lambda match: match[1] + "'" + base64.b64encode(public).decode() + "'",
                                 trust_file.read_text())
            assert count == 1
            trust_file.write_text(text)
            manifest = {'schema_version': 1, 'package_version': version, 'protocol_major': 1,
                        'source_commit': evidence['source_commit'], 'artifacts': [{
                            'target': args.target, 'filename': archive.name,
                            'size': archive.stat().st_size, 'sha256': evidence['archive_sha256']}]}
            (serving / 'release-manifest.json').write_text(json.dumps(manifest))
            run([OPENSSL, 'pkeyutl', '-sign', '-rawin', '-inkey', key,
                 '-in', serving / 'release-manifest.json',
                 '-out', serving / 'release-manifest.json.sig'], cwd=root)

        if args.test_public_key:
            public_key = args.test_public_key.read_text().strip()
            assert len(base64.b64decode(public_key, validate=True)) == 32
            trust_file = payload / 'lib/src/release_downloader.dart'
            text, count = re.subn(r"(const releaseSigningPublicKeyBase64 =\s*)'[^']+'",
                                 lambda match: match[1] + "'" + public_key + "'", trust_file.read_text())
            assert count == 1
            trust_file.write_text(text)

        ca, certificate, tls_key = create_https_certificates(root)
        # Trust only an additional local CA in the disposable consumer copy.
        # This also covers the launcher's downloader subprocess on every OS;
        # VM root-cert flags do not propagate to that child. No TLS bypass.
        transport = payload / 'lib/src/release_transport.dart'
        original = transport.read_text()
        certificate_literal = json.dumps(str(ca)).replace('$', r'\$')
        trust = ('HttpClient(context: SecurityContext(withTrustedRoots: true)'
                 f'..setTrustedCertificates({certificate_literal}))')
        assert original.count('_httpClient ?? HttpClient()') == 1
        transport.write_text(original.replace('_httpClient ?? HttpClient()',
                                              '_httpClient ?? ' + trust))
        requests = []

        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                super().do_GET()

            def log_message(self, *arguments):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(
            Handler, directory=str(serving.parent)))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certificate, tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith('BUILD_RUNNER_ACCELERATOR_')
                   and key not in ('CARGO_HOME', 'RUSTUP_HOME', 'CARGO_BIN', 'DART_BIN', 'DART_SDK', 'PUB_CACHE')}
            env.update(PUB_CACHE=str(root / 'pub-cache'),
                       XDG_CONFIG_HOME=str(root / 'config'),
                       BUILD_RUNNER_ACCELERATOR_CACHE=str(root / 'accelerator-cache'),
                       BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL=f'https://localhost:{server.server_port}')
            # Exclude Cargo/Rust even when the producer's runner has them installed.
            env['PATH'] = os.pathsep.join(entry for entry in env.get('PATH', '').split(os.pathsep)
                                          if not any((Path(entry) / tool).exists()
                                                     for tool in ('cargo', 'cargo.exe', 'rustc', 'rustc.exe')))
            for tool in ('cargo', 'rustc'):
                assert shutil.which(tool, path=env['PATH']) is None, f'{tool} remains available'
            command = [dart, '--suppress-analytics', 'run']
            if args.verify_install_only:
                # Recheck final production signatures/hashes for *all* targets.
                # Foreign executables are installed but never run on this host.
                run([dart, '--suppress-analytics', 'pub', 'get'], cwd=payload, env=env,
                    log=results / 'signed-install-pub-get.log')
                # The checksum signature is a separate published contract.
                public_key = re.search(r"const releaseSigningPublicKeyBase64 =\s*'([^']+)'",
                                       (payload / 'lib/src/release_downloader.dart').read_text())[1]
                public_der = root / 'trusted-public-key.der'
                public_der.write_bytes(bytes.fromhex('302a300506032b6570032100') + base64.b64decode(public_key))
                run([OPENSSL, 'pkeyutl', '-verify', '-rawin', '-pubin', '-keyform', 'DER',
                     '-inkey', public_der, '-in', args.signed_dist / 'SHA256SUMS',
                     '-sigfile', args.signed_dist / 'SHA256SUMS.sig'], cwd=root,
                    log=results / 'checksum-signature.log')
                for line in (args.signed_dist / 'SHA256SUMS').read_text().splitlines():
                    digest, filename = line.split(maxsplit=1)
                    assert Path(filename).name == filename, 'checksum entry must be a basename'
                    assert hashlib.sha256((args.signed_dist / filename).read_bytes()).hexdigest() == digest
                installed = {}
                for item in signed_manifest['artifacts']:
                    target = item['target']
                    binary_name = 'build_runner_accelerator' + ('.exe' if target.startswith('windows-') else '')
                    output = run([*command, str(payload / 'lib/src/release_downloader_entrypoint.dart'),
                                  str(root / 'accelerator-cache'), env['BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL'],
                                  version, target, binary_name], cwd=payload, env=env,
                                 log=results / f'signed-install-{target}.log')
                    response = json.loads(output.decode().strip().splitlines()[-1])
                    assert response['ok'] is True
                    installed[target] = hashlib.sha256(Path(response['path']).read_bytes()).hexdigest()
                    if target == args.target:
                        run([response['path'], '--version'], cwd=root, env=env,
                            log=results / 'signed-binary-version.log')
                        run([response['path'], '--help'], cwd=root, env=env,
                            log=results / 'signed-binary-help.log')
                evidence['stages']['signed-install'] = installed
                evidence['requests'] = requests
                evidence['result'] = 'passed'
                print(f'distribution-signed-install: PASS {len(installed)} targets; evidence: {results}')
                return
            workspaces = {}
            for lane in ('stock', 'native'):
                workspace = root / lane
                workspaces[lane] = workspace
                (workspace / 'lib').mkdir(parents=True)
                (workspace / 'pubspec.yaml').write_text('''name: distribution_fixture
publish_to: none
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  json_annotation: 4.12.0
dev_dependencies:
  build_runner: 2.16.2
  json_serializable: 6.14.1
''' + '  build_runner_accelerator:\n    path: ../package\n')
                (workspace / 'lib/model.dart').write_text('''import 'package:json_annotation/json_annotation.dart';
part 'model.g.dart';
@JsonSerializable()
class Model {
  Model({required this.id});
  final int id;
  factory Model.fromJson(Map<String, dynamic> json) => _$ModelFromJson(json);
  Map<String, dynamic> toJson() => _$ModelToJson(this);
}
''')
                lock = (REPO / 'fixtures/current_json_app/pubspec.lock').read_text()
                assert lock.count('path: \"../..\"') == 1
                (workspace / 'pubspec.lock').write_text(lock.replace('path: \"../..\"', 'path: \"../package\"'))
                run([dart, '--suppress-analytics', 'pub', 'get', '--enforce-lockfile'], cwd=workspace, env=env,
                    log=results / f'{lane}-pub-get.log')
            stock, native = workspaces['stock'], workspaces['native']
            # Require identical dependency solutions for the independent reference.
            for lane, workspace in workspaces.items():
                shutil.copy2(workspace / 'pubspec.lock', results / f'{lane}-pubspec.lock')
            def dependencies(workspace):
                config = json.loads((workspace / '.dart_tool/package_config.json').read_text())
                return {item['name']: item['rootUri'] for item in config['packages']
                        if item['name'] not in ('distribution_fixture', 'build_runner_accelerator')}
            assert dependencies(stock) == dependencies(native), 'stock/native dependency solutions differ'

            def invoke(lane, action, stage):
                stage_started = time.monotonic()
                package_name = 'build_runner' if lane == 'stock' else 'build_runner_accelerator'
                output = run([*command, package_name, action], cwd=workspaces[lane], env=env,
                             log=results / f'{stage}-{lane}.log')
                evidence['timings_seconds'][f'{stage}-{lane}'] = round(time.monotonic() - stage_started, 2)
                return output

            assert not (root / 'accelerator-cache').exists(), 'consumer cache was prepopulated'
            assert not (native / '.dart_tool/build_runner_accelerator/bin').exists()
            # Independent workspaces: overlap the two expensive cold compiles,
            # retaining two consumers and the existing runner/job bound.
            with ThreadPoolExecutor(max_workers=1) as reference:
                stock_initial = reference.submit(invoke, 'stock', 'build', 'initial')
                prewarm = invoke('native', 'prewarm', 'prewarm')
                assert b'AOT prewarm ready:' in prewarm, 'prewarm did not prepare the AOT worker'
                assert not outputs(native), 'prewarm ran build actions'
                required = [f'/v{version}/release-manifest.json', f'/v{version}/release-manifest.json.sig',
                            f'/v{version}/{archive.name}']
                assert all(path in requests for path in required), f'download path not exercised: {requests}'
                evidence['stages']['prewarm'] = 'passed; downloaded and verified signed archive; no outputs'
                stock_initial.result()
            invoke('native', 'build', 'initial')
            evidence['stages']['initial'] = compare(stock, native)
            before = {key: (native / key).stat().st_mtime_ns for key in outputs(native)}
            invoke('stock', 'build', 'no-op')
            no_op = invoke('native', 'build', 'no-op')
            assert b'No work to do (Rust frontend)' in no_op, 'native did not report a no-op'
            evidence['stages']['no-op'] = compare(stock, native)
            assert before == {key: (native / key).stat().st_mtime_ns for key in outputs(native)}, 'no-op rewrote outputs'
            for workspace in workspaces.values():
                path = workspace / 'lib/model.dart'
                path.write_text(path.read_text().replace('int id', 'String id'))
            invoke('stock', 'build', 'incremental')
            invoke('native', 'build', 'incremental')
            evidence['stages']['incremental'] = compare(stock, native)
            assert evidence['stages']['initial'] != evidence['stages']['incremental'], 'input edit had no effect'
            watch_log = results / 'watch-native.log'
            with watch_log.open('wb') as stream:
                watch = subprocess.Popen([str(arg) for arg in [*command, 'build_runner_accelerator', 'watch']],
                                         cwd=native, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                         start_new_session=os.name != 'nt')
                try:
                    wait_for(lambda: 'native filesystem events' in watch_log.read_text(errors='replace'), watch)
                    for workspace in workspaces.values():
                        path = workspace / 'lib/model.dart'
                        path.write_text(path.read_text().replace('String id', 'double id'))
                    invoke('stock', 'build', 'watch-reference')
                    expected = outputs(stock)
                    assert expected != outputs(native) or 'Change detected' in watch_log.read_text(errors='replace')
                    wait_for(lambda: outputs(native) == expected and 'Change detected' in
                             watch_log.read_text(errors='replace'), watch)
                    evidence['stages']['watch'] = compare(stock, native)
                    assert evidence['stages']['watch'] != evidence['stages']['incremental']
                finally:
                    stop(watch)
            # Cache hits must not fetch again after the first verified install.
            assert all(requests.count(path) == 1 for path in required), requests
            evidence['requests'] = requests
            evidence['dart'] = run([dart, '--version'], cwd=root, env=env).decode().strip()
            evidence['result'] = 'passed'
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            evidence['timings_seconds']['total'] = round(time.monotonic() - started, 2)
            (results / 'evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'distribution-e2e: PASS {args.target}; evidence: {results}')


if __name__ == '__main__':
    main()
