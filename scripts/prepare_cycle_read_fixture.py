#!/usr/bin/env python3
"""Create a disposable mixed-generator fixture with shared transitive sources.

Pub resolution and worker preparation are separate, untimed steps. Use
benchmark_cold_build.py --fixture-kind riverpod-cycle --stock-check.
"""
import argparse
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument("--skewed", action="store_true",
                        help="Add 23 extra provider declarations to the last half of inputs")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=False)
    for name in ('pubspec.yaml', 'pubspec.lock', 'build.yaml'):
        shutil.copy2(repo / 'fixtures/riverpod_app' / name, root / name)
    spec = root / 'pubspec.yaml'
    spec.write_text(spec.read_text().replace('path: ../..', f'path: {repo}'))
    config = root / 'build.yaml'
    config.write_text(config.read_text().replace('lib/model.dart', 'lib/provider_*.dart'))
    lib = root / 'lib'
    lib.mkdir()
    for n in range(8):
        for suffix in ('', '_io'):
            content = ''.join(
                f'class Shared{n}Type{k} {{\n  const Shared{n}Type{k}(this.value);\n'
                '  final int value;\n  int scaled(int factor) => value * factor;\n}\n'
                for k in range(256))
            (lib / f'shared_{n}{suffix}.dart').write_text(
                f"export 'transitive_{n}_0{suffix}.dart';\n" + content)
            for depth in range(8):
                export = (f"export 'transitive_{n}_{depth + 1}{suffix}.dart';\n"
                          if depth < 7 else '')
                declarations = ''.join(
                    f'class Transitive{n}_{depth}_{k} {{ final int value = {k}; }}\n'
                    for k in range(128))
                (lib / f'transitive_{n}_{depth}{suffix}.dart').write_text(export + declarations)
    for n in range(64):
        (lib / f'provider_{n:02}.dart').write_text(
            "import 'package:freezed_annotation/freezed_annotation.dart';\n"
            "import 'package:json_annotation/json_annotation.dart';\n"
            "import 'package:riverpod_annotation/riverpod_annotation.dart';\n" +
            ''.join(f"import 'shared_{k}.dart' if (dart.library.io) 'shared_{k}_io.dart';\n"
                    for k in range(8)) +
            f"part 'provider_{n:02}.g.dart';\npart 'provider_{n:02}.freezed.dart';\n"
            f'@riverpod\nint answer{n}(Ref ref) => ' +
            ' + '.join(f'Shared{k}Type0({n}).value' for k in range(8)) + ';\n' +
            f'@freezed\nabstract class Profile{n} with _$Profile{n} {{\n'
            f'  const factory Profile{n}({{required String label}}) = _Profile{n};\n}}\n'
            f'@JsonSerializable()\nclass User{n} {{\n  User{n}(this.label);\n'
            '  final String label;\n'
            f'  factory User{n}.fromJson(Map<String, dynamic> json) => _$User{n}FromJson(json);\n'
            f'  Map<String, dynamic> toJson() => _$User{n}ToJson(this);\n}}\n')

    if args.skewed:
        for n in range(32, 64):
            path = lib / f'provider_{n:02}.dart'
            path.write_text(path.read_text() + ''.join(
                f'@riverpod\nint extra{n}_{k}(Ref ref) => Shared0Type0({k}).value;\n'
                for k in range(23)))


if __name__ == '__main__':
    main()
