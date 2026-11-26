import 'dart:io';

import 'frontend_binary_resolver.dart' show buildRunnerAcceleratorVersion;

typedef JsonMap = Map<String, dynamic>;

/// Typed messages received by the resident worker from the Rust frontend.
///
/// JSON is decoded and validated once at the IPC boundary. The execution
/// layer should consume these values instead of repeatedly inspecting maps.
sealed class WorkerMessage {
  const WorkerMessage({required this.id});

  final Object? id;

  static WorkerMessage decode(
    JsonMap message, {
    List<String>? previousBatchBlockedAssets,
    List<String>? assetDictionary,
  }) {
    validateProtocolVersion(message);
    switch (message['type']) {
      case 'initialize':
        return WorkerInitializeMessage.fromJson(message);
      case 'reset':
        return WorkerResetMessage.fromJson(message);
      case 'api_fingerprint_query':
        return WorkerApiFingerprintQueryMessage.fromJson(message);
      case 'reset_resolver':
        return WorkerResetResolverMessage.fromJson(
          message,
          dictionary: _messageDictionary(message, assetDictionary),
        );
      case 'build':
        return WorkerBuildMessage(decodeBuildRequest(message));
      case 'build_batch':
        return WorkerBuildBatchMessage.fromJson(
          message,
          previousBlockedAssets: previousBatchBlockedAssets,
          dictionary: _messageDictionary(message, assetDictionary),
        );
      default:
        return UnsupportedWorkerMessage(
          id: message['id'],
          type: message['type'],
        );
    }
  }
}

class WorkerInitializeMessage extends WorkerMessage {
  WorkerInitializeMessage({
    required int id,
    required this.package,
    required this.root,
    required this.phaseCount,
    required this.inputRestrictions,
    this.retainedOutputGuard = false,
  }) : super(id: id);

  factory WorkerInitializeMessage.fromJson(JsonMap message) {
    if (message['accelerator_version'] != buildRunnerAcceleratorVersion) {
      throw const FormatException('initialize accelerator_version mismatch');
    }
    final phaseCount = _requiredInt(message, 'phase_count', 'initialize');
    if (phaseCount < 1) {
      throw const FormatException('initialize phase_count must be positive');
    }
    final root = _requiredString(message, 'root', 'initialize');
    if (!Directory(root).isAbsolute ||
        message['resolver_mode'] != 'dart_local') {
      throw const FormatException(
        'initialize requires absolute root and dart_local resolver_mode',
      );
    }
    final package = _requiredString(message, 'package', 'initialize');
    if (package.isEmpty) {
      throw const FormatException('initialize requires a non-empty package');
    }
    return WorkerInitializeMessage(
      id: _requiredInt(message, 'id', 'initialize'),
      package: package,
      root: root,
      phaseCount: phaseCount,
      inputRestrictions: {
        for (final entry in _stringKeyedMap(
          message['input_restrictions'],
          'initialize input_restrictions',
        ).entries)
          entry.key: _stringList(entry.value, 'input restriction patterns'),
      },
      retainedOutputGuard: message.containsKey('retained_output_guard')
          ? _requiredBool(message, 'retained_output_guard', 'initialize')
          : false,
    );
  }

  final String package;
  final String root;
  final int phaseCount;
  final Map<String, List<String>> inputRestrictions;
  final bool retainedOutputGuard;
}

class WorkerResetMessage extends WorkerMessage {
  WorkerResetMessage({required int id}) : super(id: id);

  factory WorkerResetMessage.fromJson(JsonMap message) =>
      WorkerResetMessage(id: _requiredInt(message, 'id', 'reset'));
}

/// One unit of an ADR 0056 preflight query: the asset and the content
/// digest the frontend's snapshot recorded for it. The worker answers
/// with the unit's current API fingerprint and direct resolver deps,
/// computed from content it reads itself and verified against this
/// digest.
typedef ApiFingerprintQueryEntry = ({String asset, String digest});

class WorkerApiFingerprintQueryMessage extends WorkerMessage {
  WorkerApiFingerprintQueryMessage({required int id, required this.entries})
    : super(id: id);

  final List<ApiFingerprintQueryEntry> entries;

  factory WorkerApiFingerprintQueryMessage.fromJson(JsonMap message) {
    final rawEntries = message['entries'];
    if (rawEntries is! List) {
      throw const FormatException(
        'api_fingerprint_query entries must be a list',
      );
    }
    return WorkerApiFingerprintQueryMessage(
      id: _requiredInt(message, 'id', 'api_fingerprint_query'),
      entries: <ApiFingerprintQueryEntry>[
        for (final raw in rawEntries)
          if (raw is Map<String, dynamic>)
            (
              asset: _requiredString(
                raw,
                'asset',
                'api_fingerprint_query entry',
              ),
              digest: _requiredString(
                raw,
                'digest',
                'api_fingerprint_query entry',
              ),
            )
          else
            throw const FormatException(
              'api_fingerprint_query entry must be an object',
            ),
      ],
    );
  }
}

class WorkerResetResolverMessage extends WorkerMessage {
  /// Describes a committed phase delta and its explicit blob/memory transport.
  WorkerResetResolverMessage({
    required int id,
    required this.updatedSources,
    required this.deletedSources,
    required this.updatedCache,
    required this.deletedCache,
    required this.incremental,
    required this.overlayBlob,
  }) : super(id: id);

  /// Assets whose overlay content changed since the last phase commit.
  final List<String> updatedSources;

  /// Assets removed from the overlay since the last phase commit.
  final List<String> deletedSources;

  /// Changed cache-tree assets. These are applied to the worker's asset view
  /// and generated Dart/part files remain Analyzer-visible.
  final List<String> updatedCache;

  /// Cache-tree assets removed from the overlay.
  final List<String> deletedCache;

  /// Whether the worker may keep its resolver state and apply source changes
  /// incrementally. False when a clean resolver rebuild is required.
  final bool incremental;

  /// Required reset-scoped transport descriptor; null uses single-worker memory.
  final Map<String, Object?>? overlayBlob;

  /// Validates required reset fields and normalizes the nullable descriptor.
  factory WorkerResetResolverMessage.fromJson(
    JsonMap message, {
    List<String>? dictionary,
  }) {
    if (!message.containsKey('overlay_blob')) {
      throw const FormatException('reset_resolver requires overlay_blob');
    }
    final overlayBlob = message['overlay_blob'];
    return WorkerResetResolverMessage(
      id: _requiredInt(message, 'id', 'reset_resolver'),
      updatedSources: _assetList(
        message['updated_sources'],
        dictionary,
        'reset_resolver updated_sources',
      ),
      deletedSources: _assetList(
        message['deleted_sources'],
        dictionary,
        'reset_resolver deleted_sources',
      ),
      updatedCache: _assetList(
        message['updated_cache'],
        dictionary,
        'reset_resolver updated_cache',
      ),
      deletedCache: _assetList(
        message['deleted_cache'],
        dictionary,
        'reset_resolver deleted_cache',
      ),
      incremental: _requiredBool(message, 'incremental', 'reset_resolver'),
      overlayBlob: overlayBlob == null
          ? null
          : _resolveOverlayBlob(
              _jsonMap(overlayBlob, 'reset_resolver overlay_blob'),
              dictionary,
            ),
    );
  }
}

class WorkerBuildMessage extends WorkerMessage {
  WorkerBuildMessage(this.request) : super(id: request.id);

  final WorkerBuildRequest request;
}

class WorkerBuildBatchMessage extends WorkerMessage {
  /// The visibility hint is shared by every child request in the batch.
  WorkerBuildBatchMessage({
    required int id,
    required this.blockedAssets,
    required this.requests,
    this.assetDigestUpdates = const <String, String?>{},
  }) : super(id: id);

  factory WorkerBuildBatchMessage.fromJson(
    JsonMap message, {
    List<String>? previousBlockedAssets,
    List<String>? dictionary,
  }) {
    final reuse = message.containsKey('blocked_assets_reuse')
        ? _requiredBool(message, 'blocked_assets_reuse', 'build_batch')
        : false;
    final suppliedAssets = _assetList(
      message['blocked_assets'],
      dictionary,
      'build_batch blocked_assets',
    );
    if (reuse && (previousBlockedAssets == null || suppliedAssets.isNotEmpty)) {
      throw const FormatException(
        'blocked_assets_reuse requires a prior batch list and an empty list',
      );
    }
    final blockedAssets = reuse
        ? previousBlockedAssets!
        : List<String>.unmodifiable(suppliedAssets);
    final rawRequests = message['requests'];
    if (rawRequests is! List) {
      throw const FormatException('build_batch requests must be a list');
    }
    final rawShared = message['shared'];
    final sharedFields = rawShared == null
        ? null
        : _jsonMap(rawShared, 'build_batch shared');
    final requests = [
      for (final rawRequest in rawRequests)
        WorkerBuildRequest.fromJson(
          sharedFields == null
              ? _jsonMap(rawRequest, 'build_batch request')
              : <String, dynamic>{
                  ...sharedFields,
                  ..._jsonMap(rawRequest, 'build_batch request'),
                },
          blockedAssets: blockedAssets,
          dictionary: dictionary,
        ),
    ];
    if (requests.isNotEmpty &&
        requests.any(
          (request) =>
              request.phase != requests.first.phase ||
              request.kind != requests.first.kind,
        )) {
      throw const FormatException(
        'build_batch requires one phase and builder kind',
      );
    }
    return WorkerBuildBatchMessage(
      id: _requiredInt(message, 'id', 'build_batch'),
      blockedAssets: blockedAssets,
      requests: requests,
      assetDigestUpdates: _assetDigestUpdates(
        message['asset_digests'],
        dictionary,
      ),
    );
  }

  final List<String> blockedAssets;
  final List<WorkerBuildRequest> requests;

  /// The `asset-digests-v1` delta carried by this batch, keyed by asset
  /// id: a digest string updates the worker's digest map, a null removes
  /// the id. Empty when the message carries no delta. See ADR 0054.
  final Map<String, String?> assetDigestUpdates;
}

class UnsupportedWorkerMessage extends WorkerMessage {
  const UnsupportedWorkerMessage({required super.id, required this.type});

  final Object? type;
}

/// A validated build request, including nested optional-build requests.
class WorkerBuildRequest {
  WorkerBuildRequest({
    required this.id,
    required this.builder,
    required this.input,
    required this.kind,
    required this.allowedOutputs,
    required this.options,
    required this.phase,
    required this.instanceKey,
    required this.isRoot,
    required this.blockedAssets,
    required this.triggers,
    this.partPhaseIndex,
    this.traceparent,
    this.otelReportId,
    this.apiCutoff = false,
  });

  factory WorkerBuildRequest.fromJson(
    JsonMap message, {
    required List<String> blockedAssets,
    List<String>? dictionary,
  }) {
    final kind = _requiredString(message, 'kind', 'build');
    if (kind != 'normal' && kind != 'post_process') {
      throw FormatException('unsupported build kind: $kind');
    }
    final instanceKey = _requiredString(message, 'instance_key', 'build');
    final phase = _requiredInt(message, 'phase', 'build');
    final partPhaseIndex = message['part_phase_index'];
    if (partPhaseIndex != null &&
        (partPhaseIndex is! int || partPhaseIndex < 0 || kind != 'normal')) {
      throw const FormatException(
        'build part_phase_index requires a nonnegative normal-builder phase',
      );
    }
    if (instanceKey.isEmpty || phase < 0) {
      throw const FormatException(
        'build requires non-empty instance_key and nonnegative phase',
      );
    }
    return WorkerBuildRequest(
      id: _requiredInt(message, 'id', 'build'),
      builder: _requiredString(message, 'builder', 'build'),
      input: dictionary == null
          ? _requiredString(message, 'input', 'build')
          : _resolveAssetRef(message['input'], dictionary, 'build input'),
      kind: kind,
      allowedOutputs: _assetList(
        message['allowed_outputs'],
        dictionary,
        'build allowed_outputs',
      ),
      options: _stringKeyedMap(message['options'], 'build options'),
      phase: phase,
      partPhaseIndex: partPhaseIndex as int?,
      instanceKey: instanceKey,
      isRoot: _requiredBool(message, 'is_root', 'build'),
      apiCutoff: message.containsKey('api_cutoff')
          ? _requiredBool(message, 'api_cutoff', 'build')
          : false,
      blockedAssets: blockedAssets,
      triggers: _triggerList(message['triggers'], 'build triggers'),
      otelReportId:
          message['otel_report_id'] is int &&
              (message['otel_report_id'] as int) > 0
          ? message['otel_report_id'] as int
          : null,
      traceparent: message['traceparent'] is String
          ? message['traceparent'] as String
          : null,
    );
  }

  final int id;
  final String builder;
  final String input;
  final String kind;
  final List<String> allowedOutputs;
  final Map<String, dynamic> options;
  final int phase;
  final String instanceKey;
  final bool isRoot;
  final List<String> blockedAssets;
  final List<WorkerBuildTrigger> triggers;
  final int? partPhaseIndex;
  final String? traceparent;
  final int? otelReportId;

  /// Whether the builder opted into API-signature early cutoff
  /// (ADR 0056). Carried for the result assembly; recording and
  /// classification do not depend on it yet.
  final bool apiCutoff;

  bool get isPostProcess => kind == 'post_process';
}

class WorkerBuildTrigger {
  const WorkerBuildTrigger({required this.kind, required this.value});

  factory WorkerBuildTrigger.fromJson(Object? raw) {
    final message = _jsonMap(raw, 'build trigger');
    return WorkerBuildTrigger(
      kind: _requiredString(message, 'kind', 'build trigger'),
      value: _requiredString(message, 'value', 'build trigger'),
    );
  }

  final String kind;
  final String value;
}

void validateProtocolVersion(JsonMap message) {
  if (message['v'] is! int || message['v'] != 1) {
    throw const FormatException('unsupported or missing IPC protocol version');
  }
}

WorkerBuildRequest decodeBuildRequest(JsonMap message) {
  return WorkerBuildRequest.fromJson(
    message,
    blockedAssets: _stringList(
      message['blocked_assets'],
      'build blocked_assets',
    ),
  );
}

int _requiredInt(JsonMap message, String key, String type) {
  final value = message[key];
  if (value is! int) {
    throw FormatException('$type requires an integer $key');
  }
  return value;
}

bool _requiredBool(JsonMap message, String key, String type) {
  final value = message[key];
  if (value is! bool) {
    throw FormatException('$type requires a boolean $key');
  }
  return value;
}

String _requiredString(JsonMap message, String key, String type) =>
    _requiredStringValue(message[key], '$type $key');

String _requiredStringValue(Object? value, String label) {
  if (value is! String) {
    throw FormatException('$label must be a string');
  }
  return value;
}

JsonMap _jsonMap(Object? value, String label) {
  if (value is! Map) {
    throw FormatException('$label must be an object');
  }
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$label keys must be strings');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, dynamic> _stringKeyedMap(Object? value, String label) =>
    _jsonMap(value, label);

List<String> _stringList(Object? value, String label) {
  if (value is! List) {
    throw FormatException('$label must be a list');
  }
  return [for (final item in value) _requiredStringValue(item, '$label item')];
}

/// Applies a message's `asset_dict_add` list to the connection dictionary
/// and returns the dictionary to resolve this message's id references
/// with, or null when the message uses the plain string form. The
/// additions are appended before any other field is interpreted, matching
/// the sender's encoding order. See ADR 0053.
List<String>? _messageDictionary(JsonMap message, List<String>? dictionary) {
  if (!message.containsKey('asset_dict_add')) return null;
  if (dictionary == null) {
    throw const FormatException(
      'asset_dict_add requires a worker asset dictionary',
    );
  }
  dictionary.addAll(_stringList(message['asset_dict_add'], 'asset_dict_add'));
  return dictionary;
}

String _resolveAssetRef(Object? value, List<String> dictionary, String label) {
  if (value is! int || value < 0 || value >= dictionary.length) {
    throw FormatException('$label requires an in-range dictionary index');
  }
  return dictionary[value];
}

/// Decodes an `asset_digests` delta in either form: keyed by asset id, or
/// by decimal dictionary index when [dictionary] is the message's active
/// dictionary. Values are digest strings, or null for a removal.
Map<String, String?> _assetDigestUpdates(
  Object? value,
  List<String>? dictionary,
) {
  if (value == null) return const <String, String?>{};
  if (value is! Map) {
    throw const FormatException('build_batch asset_digests must be an object');
  }
  final updates = <String, String?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException(
        'build_batch asset_digests key must be a string',
      );
    }
    final asset = dictionary == null
        ? key
        : _resolveAssetRef(
            int.tryParse(key),
            dictionary,
            'build_batch asset_digests key',
          );
    final digest = entry.value;
    if (digest != null && digest is! String) {
      throw const FormatException(
        'build_batch asset_digests value must be a string or null',
      );
    }
    updates[asset] = digest as String?;
  }
  return updates;
}

/// Decodes an asset id list in either form: plain strings, or dictionary
/// indexes when [dictionary] is the message's active dictionary.
List<String> _assetList(Object? value, List<String>? dictionary, String label) {
  if (dictionary == null) return _stringList(value, label);
  if (value is! List) {
    throw FormatException('$label must be a list');
  }
  return [
    for (final item in value) _resolveAssetRef(item, dictionary, '$label item'),
  ];
}

/// Rewrites an interned overlay blob descriptor's `index` keys, which are
/// decimal dictionary indexes, back to asset ids. Other descriptors and
/// fields pass through unchanged.
Map<String, Object?> _resolveOverlayBlob(
  Map<String, Object?> blob,
  List<String>? dictionary,
) {
  if (dictionary == null) return blob;
  final index = blob['index'];
  if (index is! Map) return blob;
  final resolved = <String, dynamic>{
    for (final entry in index.entries)
      _resolveAssetRef(
        int.tryParse('${entry.key}'),
        dictionary,
        'reset_resolver overlay_blob index key',
      ): entry.value,
  };
  return <String, Object?>{...blob, 'index': resolved};
}

List<WorkerBuildTrigger> _triggerList(Object? value, String label) {
  if (value is! List) {
    throw FormatException('$label must be a list');
  }
  return [for (final item in value) WorkerBuildTrigger.fromJson(item)];
}
