import 'dart:io';

Future<void> main(List<String> arguments) async {
  final handle = await File(arguments.single).open(mode: FileMode.append);
  await handle.lock(FileLock.blockingExclusive);
  stdout.writeln('ready');
  await stdout.flush();
  await stdin.drain();
  await handle.unlock();
  await handle.close();
}
