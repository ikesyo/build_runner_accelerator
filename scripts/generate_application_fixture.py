#!/usr/bin/env python3
"""Stage a mixed-builder application using the existing riverpod_app lockfile."""

import argparse
from pathlib import Path
import tempfile


SHARED = """import 'package:json_annotation/json_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'shared.g.dart';

// shared-lifecycle: base
enum Lifecycle { unknown, draft, active, archived }

@JsonSerializable()
class Address {
  const Address({required this.street, required this.city, required this.postalCode});
  final String street;
  final String city;
  final int postalCode;
  factory Address.fromJson(Map<String, dynamic> json) => _$AddressFromJson(json);
  Map<String, dynamic> toJson() => _$AddressToJson(this);
}

@Riverpod(keepAlive: true)
bool featureEnabled(Ref ref) => true;
"""

MODEL = """import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../shared.dart';

part 'model.freezed.dart';
part 'model.g.dart';

// baseline-marker: base
@JsonSerializable(explicitToJson: true)
class ModelNNN {
  const ModelNNN({required this.id, required this.title, required this.createdAt,
    required this.address, required this.history, required this.amounts,
    required this.attributes, required this.lifecycle, required this.enabled,
    this.score, this.revision});
  final int id;
  @JsonKey(name: 'title_base')
  final String title;
  final DateTime createdAt;
  final Address address;
  final List<Address> history;
  final List<double> amounts;
  final Map<String, String> attributes;
  @JsonKey(unknownEnumValue: Lifecycle.unknown)
  final Lifecycle lifecycle;
  final bool enabled;
  final double? score;
  final int? revision;
  factory ModelNNN.fromJson(Map<String, dynamic> json) => _$ModelNNNFromJson(json);
  Map<String, dynamic> toJson() => _$ModelNNNToJson(this);
}

@freezed
sealed class FeatureStateNNN with _$FeatureStateNNN {
  const factory FeatureStateNNN.idle() = IdleNNN;
  const factory FeatureStateNNN.loading() = LoadingNNN;
  const factory FeatureStateNNN.loaded(ModelNNN value) = LoadedNNN;
  const factory FeatureStateNNN.failed(String message) = FailedNNN;
  factory FeatureStateNNN.fromJson(Map<String, dynamic> json) =>
      _$FeatureStateNNNFromJson(json);
}

@riverpod
FeatureStateNNN featureNNN(Ref ref) {
  if (!ref.watch(featureEnabledProvider)) return const FeatureStateNNN.idle();
  return FeatureStateNNN.loaded(ModelNNN(
    id: NID, title: 'feature-NNN', createdAt: DateTime.utc(2026, 1, 1),
    address: const Address(street: 'Main', city: 'Example', postalCode: 12345),
    history: const [], amounts: const [1.5, 2.0], attributes: const {'tier': 'basic'},
    lifecycle: Lifecycle.active, enabled: true));
}
"""

SERVICE = """import 'model.dart';

// Ordinary application code participates in scans, but has no generator outputs.
class FeatureServiceNNN {
  String label(ModelNNN model) => '${model.id}: ${model.title}';
  Map<String, dynamic> serialize(ModelNNN model) => model.toJson();
  FeatureStateNNN failure(String message) => FeatureStateNNN.failed(message);
}
"""


def generate(count: int, destination: Path) -> None:
    """Only write into an isolated current-baseline benchmark workspace."""
    destination = destination.resolve()
    scratch_root = Path(tempfile.gettempdir()).resolve()
    if count < 1 or not any(
        p.parent == scratch_root
        and p.name.startswith('build-runner-accelerator-current-baseline-work.')
        for p in destination.parents
    ):
        raise ValueError('requires a positive count and isolated benchmark workspace')
    if (destination / 'lib').exists():
        raise ValueError('destination already contains lib; use a fresh workspace')
    lib = destination / 'lib'
    lib.mkdir(parents=True)
    (lib / 'shared.dart').write_text(SHARED)
    for index in range(1, count + 1):
        number = f'{index:03d}'
        feature = lib / 'features' / f'feature_{number}'
        feature.mkdir(parents=True)
        (feature / 'model.dart').write_text(MODEL.replace('NNN', number).replace('NID', str(index)))
        (feature / 'service.dart').write_text(SERVICE.replace('NNN', number))
    (destination / 'build.yaml').write_text('''targets:
  $default:
    builders:
''' + ''.join(f'''      {builder}:
        generate_for:
          - lib/shared.dart
          - lib/features/**/model.dart
''' for builder in ('freezed', 'json_serializable', 'riverpod_generator')))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('count', type=int, help='number of features; 2*N+1 public outputs')
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    generate(args.count, args.destination)
    print(f'generated {args.count} features, {2 * args.count + 1} Dart sources/public outputs')
