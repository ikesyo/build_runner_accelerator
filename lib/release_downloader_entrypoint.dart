import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'release_downloader.dart';

Future<void> main(List<String> arguments, Object? message) async {
  void sendResponse(Map<String, Object> response, {bool failure = false}) {
    if (message is SendPort) {
      message.send(response);
    } else {
      stdout.writeln(jsonEncode(response));
      if (failure) exitCode = 1;
    }
  }

  if (arguments.length != 5) {
    sendResponse(<String, Object>{
      'ok': false,
      'error': 'invalid release downloader invocation',
    }, failure: true);
    return;
  }

  try {
    final downloader = ReleaseDownloader(
      cacheDirectory: arguments[0],
      baseUrl: arguments[1],
    );
    final path = await downloader.ensureInstalled(
      version: arguments[2],
      target: arguments[3],
      binaryName: arguments[4],
    );
    sendResponse(<String, Object>{'ok': true, 'path': path});
  } on Object catch (error, stackTrace) {
    sendResponse(<String, Object>{
      'ok': false,
      'error': error.toString(),
      'stack': stackTrace.toString(),
    }, failure: true);
  }
}
