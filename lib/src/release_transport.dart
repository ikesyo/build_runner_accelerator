import 'dart:async';
import 'dart:io';

import 'release_manifest.dart';

class ReleaseDownloadClient {
  ReleaseDownloadClient({
    required this.baseUrl,
    required this.requireHttps,
    required this.requestTimeout,
    HttpClient? httpClient,
  }) : _httpClient = httpClient;

  final String baseUrl;
  final bool requireHttps;
  final Duration requestTimeout;
  final HttpClient? _httpClient;

  Uri releaseUri(String version, String filename) {
    final base = Uri.parse(baseUrl);
    final segments = <String>[
      ...base.pathSegments.where((segment) => segment.isNotEmpty),
      'v$version',
      filename,
    ];
    return base.replace(
      path: '/${segments.map(Uri.encodeComponent).join('/')}',
    );
  }

  Future<List<int>> download(Uri uri, {required int maxBytes}) async {
    if (requireHttps && uri.scheme != 'https') {
      throw ReleaseDownloadException('refusing non-HTTPS download: $uri');
    }
    final client = _httpClient ?? HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(requestTimeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'build_runner_accelerator',
      );
      final response = await request.close().timeout(requestTimeout);
      for (final redirect in response.redirects) {
        if (requireHttps && redirect.location.scheme != 'https') {
          throw ReleaseDownloadException(
            'refusing non-HTTPS release redirect: ${redirect.location}',
          );
        }
      }
      if (response.statusCode != HttpStatus.ok) {
        throw ReleaseDownloadException(
          'release download failed with HTTP ${response.statusCode}: $uri',
        );
      }
      if (response.contentLength > maxBytes) {
        throw ReleaseDownloadException(
          'release response is too large: ${response.contentLength} bytes',
        );
      }

      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.timeout(requestTimeout)) {
        length += chunk.length;
        if (length > maxBytes) {
          throw ReleaseDownloadException(
            'release response exceeded $maxBytes bytes',
          );
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } on ReleaseDownloadException {
      rethrow;
    } on TimeoutException {
      throw ReleaseDownloadException('release download timed out: $uri');
    } on Object catch (error) {
      throw ReleaseDownloadException(
        'release download failed for $uri: $error',
      );
    } finally {
      if (_httpClient == null) client.close(force: true);
    }
  }
}
