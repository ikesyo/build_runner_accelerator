import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/indexed_blob_store.dart';

Future<void> main(List<String> args) async {
  final store = IndexedBlobStore(args[0], maxRecords: int.parse(args[1]));
  store.get('prime');
  stdout.writeln('ready');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final command = jsonDecode(line) as List;
    switch (command[0]) {
      case 'put':
        var stored = false;
        for (var i = 0; i < 1000 && !stored; i++) {
          stored = store.put(
            command[1] as String,
            Uint8List.fromList([command[2] as int]),
          );
          if (!stored)
            await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        stdout.writeln(jsonEncode(stored));
      case 'get':
        stdout.writeln(jsonEncode(store.get(command[1] as String)?.toList()));
      case 'refresh':
        store.refresh();
        stdout.writeln('true');
      case 'partial-record':
        final root = '${args[0]}.generations';
        final name = ascii.decode(
          File('$root/current').readAsBytesSync().sublist(0, 32),
        );
        final data = File('$root/$name/data').openSync(mode: FileMode.append);
        data.lockSync(FileLock.exclusive);
        data.setPositionSync(data.lengthSync());
        data.writeFromSync([4, 0, 0]);
        final journal = File(
          '$root/$name/data.index',
        ).openSync(mode: FileMode.append);
        journal.setPositionSync(journal.lengthSync());
        journal.writeFromSync([3, 0]);
        stdout.writeln('true');
        await Future<void>.delayed(const Duration(days: 1));
      case 'partial-reclaim':
        final root = '${args[0]}.generations';
        final lock = File('$root/control').openSync(mode: FileMode.append);
        lock.lockSync(FileLock.blockingExclusive);
        File('$root/${command[1]}/data').deleteSync();
        stdout.writeln('true');
        await Future<void>.delayed(const Duration(days: 1));
      case 'hold-control':
        final control = File(
          '${args[0]}.generations/control',
        ).openSync(mode: FileMode.append);
        control.lockSync(FileLock.blockingExclusive);
        stdout.writeln('true');
        await Future<void>.delayed(const Duration(days: 1));
      case 'partial-seed':
        final root = '${args[0]}.generations';
        final lock = File('$root/control').openSync(mode: FileMode.append);
        lock.lockSync(FileLock.blockingExclusive);
        final directory = Directory('$root/${command[1]}')..createSync();
        final seed = IndexedBlobPack('${directory.path}/data');
        if (!seed.put('unpublished', Uint8List.fromList([99]))) {
          throw StateError('Cannot seed unpublished generation');
        }
        final data = File(
          '${directory.path}/data',
        ).openSync(mode: FileMode.append);
        data.lockSync(FileLock.exclusive);
        data.setPositionSync(data.lengthSync());
        data.writeFromSync([4, 0, 0]);
        stdout.writeln('true');
        await Future<void>.delayed(const Duration(days: 1));
      case 'tear-pointer':
        final lock = File(
          '${args[0]}.generations/control',
        ).openSync(mode: FileMode.append);
        lock.lockSync(FileLock.blockingExclusive);
        File('${args[0]}.generations/current').writeAsBytesSync([1, 2, 3]);
        stdout.writeln('true');
        await Future<void>.delayed(const Duration(days: 1));
      case 'exit-without-close':
        stdout.writeln('true');
        await stdout.flush();
        exit(0);
      case 'exit':
        store.close();
        stdout.writeln('true');
        await stdout.flush();
        // This test peer has completed all work. Explicit exit avoids waiting
        // for Windows stdin subscription cancellation after the reply.
        exit(0);
    }
  }
  store.close();
}
