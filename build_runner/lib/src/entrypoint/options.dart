// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:build_runner/build_runner.dart';
import 'package:meta/meta.dart';
import 'package:shelf/shelf_io.dart';

const _assumeTty = 'assume-tty';
const _deleteFilesByDefault = 'delete-conflicting-outputs';
const _hostname = 'hostname';

/// Unified command runner for all build_runner commands.
class BuildCommandRunner extends CommandRunner {
  final List<BuilderApplication> builderApplications;

  BuildCommandRunner(List<BuilderApplication> builderApplications)
      : this.builderApplications = new List.unmodifiable(builderApplications),
        super('build_runner', 'Unified interface for running Dart builds.') {
    addCommand(new _BuildCommand());
    addCommand(new _WatchCommand());
    addCommand(new _ServeCommand());
  }
}

/// Base options that are shared among all commands.
class _SharedOptions {
  /// Skip the `stdioType()` check and assume the output is going to a terminal
  /// and that we can accept input on stdin.
  final bool assumeTty;

  /// By default, the user will be prompted to delete any files which already
  /// exist but were not generated by this specific build script.
  ///
  /// This option can be set to `true` to skip this prompt.
  final bool deleteFilesByDefault;

  _SharedOptions._(
      {@required this.assumeTty, @required this.deleteFilesByDefault});

  factory _SharedOptions.fromParsedArgs(ArgResults argResults) {
    return new _SharedOptions._(
        assumeTty: argResults[_assumeTty] as bool,
        deleteFilesByDefault: argResults[_deleteFilesByDefault] as bool);
  }
}

/// Options specific to the [_ServeCommand].
class _ServeOptions extends _SharedOptions {
  final String hostName;
  final List<_ServeTarget> serveTargets;

  _ServeOptions._({
    @required this.hostName,
    @required this.serveTargets,
    @required bool assumeTty,
    @required bool deleteFilesByDefault,
  })
      : super._(
            assumeTty: assumeTty, deleteFilesByDefault: deleteFilesByDefault);

  factory _ServeOptions.fromParsedArgs(ArgResults argResults) {
    var serveTargets = <_ServeTarget>[];
    for (var arg in argResults.rest) {
      var parts = arg.split(':');
      var path = parts.first;
      var port = parts.length == 2 ? int.parse(parts[1]) : 8080;
      serveTargets.add(new _ServeTarget(path, port));
    }
    if (serveTargets.isEmpty) {
      serveTargets.addAll([
        new _ServeTarget('web', 8080),
        new _ServeTarget('test', 8081),
      ]);
    }
    return new _ServeOptions._(
        hostName: argResults[_hostname] as String,
        serveTargets: serveTargets,
        assumeTty: argResults[_assumeTty] as bool,
        deleteFilesByDefault: argResults[_deleteFilesByDefault] as bool);
  }
}

/// A target to serve, representing a directory and a port.
class _ServeTarget {
  final String dir;
  final int port;

  _ServeTarget(this.dir, this.port);
}

abstract class _BaseCommand extends Command {
  List<BuilderApplication> get builderApplications =>
      (runner as BuildCommandRunner).builderApplications;

  _BaseCommand() {
    argParser
      ..addFlag(_assumeTty,
          help: 'Enables colors and interactive input when the script does not'
              ' appear to be running directly in a terminal, for instance when it'
              ' is a subprocess',
          defaultsTo: null,
          negatable: true)
      ..addFlag(_deleteFilesByDefault,
          help:
              'By default, the user will be prompted to delete any files which '
              'already exist but were not known to be generated by this '
              'specific build script.\n\n'
              'Enabling this option skips the prompt and deletes the files. '
              'This should typically be used in continues integration servers '
              'and tests, but not otherwise.',
          negatable: false,
          defaultsTo: false);
  }

  /// Must be called inside [run] so that [argResults] is non-null.
  ///
  /// You may override this to return more specific options if desired, but they
  /// must extend [_SharedOptions].
  _SharedOptions _readOptions() =>
      new _SharedOptions.fromParsedArgs(argResults);
}

/// A [Command] that does a single build and then exits.
class _BuildCommand extends _BaseCommand {
  @override
  String get name => 'build';

  @override
  String get description =>
      'Performs a single build on the specified targets and then exits.';

  @override
  Future<Null> run() async {
    var options = _readOptions();
    await build(builderApplications,
        deleteFilesByDefault: options.deleteFilesByDefault,
        assumeTty: options.assumeTty);
  }
}

/// A [Command] that watches the file system for updates and rebuilds as
/// appropriate.
class _WatchCommand extends _BaseCommand {
  @override
  String get name => 'watch';

  @override
  String get description =>
      'Builds the specified targets, watching the file system for updates and '
      'rebuilding as appropriate.';

  @override
  Future<Null> run() async {
    var options = _readOptions();
    var handler = await watch(builderApplications,
        deleteFilesByDefault: options.deleteFilesByDefault,
        assumeTty: options.assumeTty);
    await handler.currentBuild;
    await handler.buildResults.drain();
  }
}

/// Extends [_WatchCommand] with dev server functionality.
class _ServeCommand extends _WatchCommand {
  _ServeCommand() {
    argParser
      ..addOption(_hostname,
          help: 'Specify the hostname to serve on', defaultsTo: 'localhost');
  }

  @override
  String get name => 'serve';

  @override
  String get description =>
      'Runs a development server that serves the specified targets and runs '
      'builds based on file system updates.';

  @override
  _ServeOptions _readOptions() => new _ServeOptions.fromParsedArgs(argResults);

  @override
  Future<Null> run() async {
    var options = _readOptions();
    var handler = await watch(builderApplications,
        deleteFilesByDefault: options.deleteFilesByDefault,
        assumeTty: options.assumeTty);
    var servers = await Future.wait(options.serveTargets.map((target) =>
        serve(handler.handlerFor(target.dir), options.hostName, target.port)));
    await handler.currentBuild;
    for (var target in options.serveTargets) {
      stdout.writeln('Serving `${target.dir}` on port ${target.port}');
    }
    await handler.buildResults.drain();
    await Future.wait(servers.map((server) => server.close()));
  }
}
