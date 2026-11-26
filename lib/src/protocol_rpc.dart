import 'protocol_framing.dart' show FrameReader, FrameWriter;
import 'protocol_messages.dart'
    show
        JsonMap,
        WorkerBuildRequest,
        decodeBuildRequest,
        validateProtocolVersion;

typedef RpcControlMessageHandler =
    Future<void> Function(WorkerBuildRequest message);

class RpcSession {
  RpcSession(
    this.reader,
    this.writer, {
    required this.buildId,
    required this.phase,
    required this.postProcess,
    this.onControlMessage,
  });

  final FrameReader reader;
  final FrameWriter writer;
  final int buildId;
  final int phase;
  final bool postProcess;
  final RpcControlMessageHandler? onControlMessage;
  int _nextId = 1000;
  Future<void> _pending = Future<void>.value();

  /// Serializes round trips within this action, including nested demand.
  /// Nested actions own another session, so they can use the shared transport
  /// while this session is suspended in its control-message handler.
  Future<JsonMap> call(String op, Map<String, dynamic> parameters) {
    final id = _nextId++;
    final request = <String, dynamic>{
      'v': 1,
      'type': 'asset_request',
      'id': id,
      'op': op,
      ...parameters,
      'build_id': buildId,
      // Rust applies the same phase-aware logical view as the Dart adapter.
      // Each asset request carries the context Rust needs to enforce
      // visibility independently of the worker-side blocked_assets hint.
      'phase': phase,
      'kind': postProcess ? 'post_process' : 'normal',
    };
    final result = _pending.then((_) => _call(request, id));
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Owns the frame reader until this request and any nested actions complete.
  Future<JsonMap> _call(JsonMap request, int id) async {
    await writer.send(request);
    while (true) {
      final response = await reader.next();
      if (response == null) {
        throw const FormatException('Rust frontend exited during RPC');
      }
      validateProtocolVersion(response);
      if (response['type'] == 'build') {
        final handler = onControlMessage;
        if (handler == null) {
          throw StateError('Unexpected nested build request during asset RPC');
        }
        await handler(decodeBuildRequest(response));
        continue;
      }
      if (response['type'] != 'asset_response' || response['id'] != id) {
        throw StateError(
          'Unexpected message while waiting for asset RPC: $response',
        );
      }
      if (response['ok'] != true) {
        throw StateError(response['error']?.toString() ?? 'Asset RPC failed');
      }
      return response;
    }
  }
}
