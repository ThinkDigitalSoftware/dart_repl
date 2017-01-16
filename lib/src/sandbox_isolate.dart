// Copyright (c) 2016, Andreas 'blackhc' Kirsch. All rights reserved. Use of
// this source code is governed by a BSD-style license that can be found in the
// LICENSE file.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:package_resolver/package_resolver.dart';

/// Simple queue of future messages.
///
/// Every time I try to use Streams, I feel stupid :( So let's not do that.
class MessageQueue {
  final messageQueue = new Queue<Object>();
  final receiverQueue = new Queue<Completer<Object>>();

  void addMessage(Object message) {
    if (receiverQueue.isNotEmpty) {
      final completer = receiverQueue.removeFirst();
      completer.complete(message);
      return;
    }
    messageQueue.addLast(message);
  }

  Future<Object> receive() async {
    if (messageQueue.isNotEmpty) {
      return messageQueue.removeFirst();
    }
    final completer = new Completer<Object>();
    receiverQueue.addLast(completer);
    return completer.future;
  }
}

class SandboxIsolate {
  final Isolate isolate;
  final SendPort sendPort;
  final MessageQueue receiverQueue;
  final Future onExit;

  SandboxIsolate(
      {this.isolate, this.sendPort, this.receiverQueue, this.onExit});
}

/// Copies the template files, installs the adhoc imports, and returns
/// the running `SandboxIsolate`.
Future<SandboxIsolate> bootstrapIsolate(
    {String packageDir, List<String> imports = const <String>[]}) async {
  final packageConfig = await createPackageConfig(packageDir);
  final packageConfigUri = await packageConfig.packageConfigUri;

  final baseDynamicEnvironmentUri = await resolvePackageFile(
      'package:dart_repl/src/template/dynamic_environment.dart');
  final baseIsolateUri =
      await resolvePackageFile('package:dart_repl/src/template/isolate.dart');

  final instanceDir = Directory.systemTemp.createTempSync('custom_dart_repl');
  final dynamicEnvironmentFile =
      new File(instanceDir.path + '/dynamic_environment.dart');
  final isolateFile = new File(instanceDir.path + '/isolate.dart');

  // Copy isolate.dart.
  isolateFile.writeAsStringSync(await readUrl(baseIsolateUri));

  // Copy dynamic_environment.dart and update imports in the
  // dynamic environment.
  final customImports = imports
      .map((import) => 'import \'${getImportPath(import, packageDir)}\';')
      .join('\n');
  dynamicEnvironmentFile.writeAsStringSync(
      (await readUrl(baseDynamicEnvironmentUri))
          .replaceAll('/*\${IMPORTS}*/', customImports));

  // Setup communication channels.
  final receiverQueue = new MessageQueue();
  final receivePort = new ReceivePort();
  receivePort.listen(receiverQueue.addMessage);

  final onExitPort = new ReceivePort();
  final onExitCompleter = new Completer<Null>();
  onExitPort.listen((dynamic unused) {
    onExitPort.close();
    onExitCompleter.complete();
    receivePort.close();
  });

  final isolate = await Isolate.spawnUri(
      isolateFile.uri, [], receivePort.sendPort,
      onExit: onExitPort.sendPort,
      checked: true,
      packageConfig: packageConfigUri);

  final sendPort = await receiverQueue.receive() as SendPort;

  return new SandboxIsolate(
      isolate: isolate,
      receiverQueue: receiverQueue,
      sendPort: sendPort,
      onExit: onExitCompleter.future);
}

Future<String> readUrl(Uri uri) async {
  if (uri.scheme == 'file') {
    return new File(uri.toFilePath()).readAsStringSync();
  }
  final request = await new HttpClient().getUrl(uri);
  final response = await request.close();
  final contentPieces = await response.transform(new Utf8Decoder()).toList();
  final content = contentPieces.join();
  return content;
}

Future<PackageResolver> createPackageConfig(String otherPackageDir) async {
  final otherConfig = await loadPackageConfigMap(otherPackageDir);
  // Safe copy.
  final config = new Map<String, Uri>.from(otherConfig);
  config.addAll(otherConfig);
  // We only need to add a dependency on the dart_repl_sandbox virtual package.
  final thisPackageUri = await getThisPackageUri();
  final sandboxPackageUri =
      thisPackageUri.replace(path: '${thisPackageUri.path}/src/sandbox/');
  config['dart_repl_sandbox'] = sandboxPackageUri;
  return new PackageResolver.config(config);
}

Future<Map<String, Uri>> loadPackageConfigMap(String packageDir) async {
  if (packageDir != null) {
    // Only try to load it if the .packages file exists.
    final packagesFilePath = packageDir + '/.packages';
    if (new File(packagesFilePath).existsSync()) {
      return (await SyncPackageResolver.loadConfig(packagesFilePath))
          .packageConfigMap;
    }
  }
  return <String, Uri>{};
}

Future<Uri> getThisPackageUri() async {
  final entryLibrary =
      await resolvePackageFile('package:dart_repl/dart_repl.dart');
  final thisPackage = entryLibrary.replace(
      pathSegments: entryLibrary.pathSegments
          .sublist(0, entryLibrary.pathSegments.length - 1));
  return thisPackage;
}

Future<Uri> resolvePackageFile(String packagePath) async {
  return await Isolate.resolvePackageUri(Uri.parse(packagePath));
}

String getImportPath(String import, String packageDir) {
  if (import.startsWith('package:') || import.startsWith('dart:')) {
    return import;
  }
  return '$packageDir/$import';
}