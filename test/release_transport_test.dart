import 'dart:async';
import 'dart:io';

import 'package:build_runner_accelerator/src/release_downloader.dart';
import 'package:build_runner_accelerator/src/release_transport.dart';
import 'package:test/test.dart';

void main() {
  test('builds release URLs below the versioned release prefix', () {
    final client = ReleaseDownloadClient(
      baseUrl: 'https://mirror.example/releases',
      requireHttps: true,
      requestTimeout: const Duration(seconds: 1),
    );

    expect(
      client.releaseUri('0.3.0', 'release-manifest.json').toString(),
      'https://mirror.example/releases/v0.3.0/release-manifest.json',
    );
  });

  test('rejects non-HTTPS downloads when HTTPS is required', () {
    final client = ReleaseDownloadClient(
      baseUrl: 'https://mirror.example/releases',
      requireHttps: true,
      requestTimeout: const Duration(seconds: 1),
    );

    expect(
      () => client.download(
        Uri.parse('http://mirror.example/file'),
        maxBytes: 1024,
      ),
      throwsA(isA<ReleaseDownloadException>()),
    );
  });

  test(
    'rejects an HTTPS-to-HTTP redirect before contacting the target',
    () async {
      final start = Uri.parse('https://mirror.example/start');
      final cleartext = Uri.parse('http://mirror.example/cleartext');
      final httpClient = _RedirectingHttpClient({
        start: _ResponseSpec.redirect(cleartext.toString()),
        cleartext: _ResponseSpec.ok(utf8Bytes('downloaded')),
      });
      final client = ReleaseDownloadClient(
        baseUrl: 'https://mirror.example/releases',
        requireHttps: true,
        requestTimeout: const Duration(seconds: 1),
        httpClient: httpClient,
      );

      await expectLater(
        client.download(start, maxBytes: 1024),
        throwsA(isA<ReleaseDownloadException>()),
      );
      expect(httpClient.requestedUris, [start]);
    },
  );
}

class _ResponseSpec {
  const _ResponseSpec.ok(List<int> body)
    : statusCode = HttpStatus.ok,
      location = null,
      this.body = body;

  const _ResponseSpec.redirect(String location)
    : statusCode = HttpStatus.movedTemporarily,
      this.location = location,
      body = const <int>[];

  final int statusCode;
  final String? location;
  final List<int> body;

  bool get isRedirect => location != null;
}

class _RedirectingHttpClient implements HttpClient {
  _RedirectingHttpClient(this.responses);

  final Map<Uri, _ResponseSpec> responses;
  final requestedUris = <Uri>[];

  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requestedUris.add(uri);
    return _RedirectingHttpClientRequest(this, uri);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RedirectingHttpClientRequest implements HttpClientRequest {
  _RedirectingHttpClientRequest(this.client, this.uri);

  final _RedirectingHttpClient client;
  final Uri uri;
  final _TestHttpHeaders _headers = _TestHttpHeaders();

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async {
    final response = _response();
    if (!followRedirects || !response.isRedirect) return response;
    final location = response.location;
    if (location == null) return response;
    final redirected = await client.getUrl(uri.resolve(location));
    return redirected.close();
  }

  _RedirectingHttpClientResponse _response() {
    final response = client.responses[uri];
    if (response == null) {
      throw StateError('unexpected request: $uri');
    }
    return _RedirectingHttpClientResponse(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RedirectingHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _RedirectingHttpClientResponse(this.spec)
    : _headers = _TestHttpHeaders(location: spec.location);

  final _ResponseSpec spec;
  final _TestHttpHeaders _headers;

  @override
  int get statusCode => spec.statusCode;

  @override
  int get contentLength => spec.body.length;

  @override
  bool get isRedirect => spec.isRedirect;

  String? get location => spec.location;

  @override
  HttpHeaders get headers => _headers;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([spec.body]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHttpHeaders implements HttpHeaders {
  _TestHttpHeaders({this.location});

  final String? location;

  @override
  String? value(String name) =>
      name.toLowerCase() == HttpHeaders.locationHeader ? location : null;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<int> utf8Bytes(String value) => value.codeUnits;
