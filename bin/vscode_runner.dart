import 'dart:io';

import 'package:krunner/krunner.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:vscode_runner/storage.dart';
import 'package:xdg_directories/xdg_directories.dart';

Future<void> main(List<String> arguments) async {
  await checkIfAlreadyRunning();

  print('Starting VSCode runner.');

  final runner = KRunnerPlugin(
    identifier: 'codes.merritt.vscode_runner',
    name: '/vscode_runner',
    matchQuery: matchQuery,
    retrieveActions: retrieveActions,
    runAction: runAction,
  );

  await runner.init();
}

/// Check if an instance of this plugin is already running.
///
/// If we don't check KRunner will just launch a new instance every time.
Future<void> checkIfAlreadyRunning() async {
  final result = await Process.run('pidof', ['vscode_runner']);
  final hasError = result.stderr != '';
  if (hasError) {
    print('Issue checking for existing process: ${result.stderr}');
    return;
  }
  final output = result.stdout as String;
  final runningInstanceCount = output.trim().split(' ').length;
  if (runningInstanceCount != 1) {
    print('An instance of vscode_runner appears to already be running. '
        'Aborting run of new instance.');
    exit(0);
  }
}

/// Load VSCode's globalStorage database and retrieve recent paths.
List<String> fetchPaths() {
  final dbFile = '${configHome.path}/Code/User/globalStorage/state.vscdb';
  final Database db;

  try {
    db = sqlite3.open(dbFile, mode: OpenMode.readOnly);
  } catch (e) {
    print('Unable to open VSCode database file.\n'
        '$e');
    return const [];
  }

  final rows = db.select(
    "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'",
  );
  db.dispose();

  final jsonString = rows.first.values.first as String;
  final recentPaths = Storage.fromJson(jsonString).recentPaths;

  return recentPaths;
}

Future<List<QueryMatch>> matchQuery(String query) async {
  final recentWorkspacePaths = fetchPaths();
  recentWorkspacePaths.removeWhere((element) => !element.contains(query));

  final matches = recentWorkspacePaths.map((path) {
    final uri = pathToUri(path);
    final relativePath = parseRelativePath(uri);
    final projectName = path.split('/').last;
    return QueryMatch(
      id: path,  // id is the raw folderUri starting with file:// or vscode-remote://
      title: projectName,
      icon: 'com.visualstudio.code',
      rating: QueryMatchRating.exact,
      relevance: 1.0,
      properties: QueryMatchProperties(subtitle: relativePath ?? uri.path),
    );
  }).toList();

  return matches;
}

Uri pathToUri(String path) {
  // Remove the leading "file://" or "vscode-remote://"
  final trimmed = path.replaceFirst('file://', '').replaceFirst('vscode-remote://', '');
  final uri = Uri.directory(trimmed);
  return uri;
}

String? parseRelativePath(Uri uri) {
  var homeDir = Process.runSync('xdg-user-dir', []).stdout as String;
  homeDir = homeDir.trim();
  final pathIsUnderHome = uri.path.contains(homeDir);
  if (pathIsUnderHome) {
    // If the path is under the user's home directory, we return
    // the relative path so that the subtitle in KRunner can be a shorter
    // path that will fit better in limited space, eg:
    // `~/Development/project` rather than `/home/user/Development/project`.
    final withoutHomePrefix = uri.path.substring(homeDir.length);
    final relativePath = '~' + withoutHomePrefix;
    return relativePath;
  } else {
    return null;
  }
}

Future<List<SecondaryAction>> retrieveActions() async {
  return [
    SecondaryAction(
      id: 'openContainingFolder',
      text: 'Open Containing Folder',
      icon: 'document-open-folder',
    ),
  ];
}

String dbusToString(String dbusStr) {
  // Remove the `DBusString('')`
  String str;
  if (dbusStr.startsWith("DBusString")) {
    str = dbusStr.substring(12);
    str = str.substring(0, str.length - 2);
  } else {
    str = dbusStr;
  }
  return str;
}

Future<void> runAction({
  required String actionId,
  required String matchId,
}) async {
  final isOpenFolderRequest =
      (dbusToString(actionId) == "openContainingFolder") ? true : false;
  final path = dbusToString(matchId);
  if (isOpenFolderRequest) {
    openContainingFolder(path);
  } else {
    final trimmed =
        path.replaceFirst('file://', '').replaceFirst('vscode-remote://', '');
    openWorkspace(trimmed);
  }
}

Future<void> openWorkspace(String path) async {
  // just pass the raw path as --folder-uri, VSCode will handle it
  // see https://stackoverflow.com/questions/60144074/how-to-open-a-remote-folder-from-command-line-in-vs-code
  await Process.run('code', ['--folder-uri=' + path]);
}

Future<void> openContainingFolder(String path) async {
  await Process.run('xdg-open', [path]);
}
