import 'dart:io';
import 'dart:mirrors';

import 'package:flutter_format/flutter_format.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

const actualSuffix = '_actual.dart';

void main() async {
  // prepare tmp formatting dir
  var analyzeDir = path.join(Directory.systemTemp.path,
      DateTime.now().microsecondsSinceEpoch.toString());
  File(path.join(analyzeDir, '.packages')).createSync(recursive: true);
  String toTmp(File file) =>
      path.normalize(path.join(analyzeDir, '.${file.path}'));

  // read tests
  var casesDir = path.join(path.dirname(currentFile.path), 'cases');
  var files = Directory(casesDir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith(actualSuffix));

  // copy test to tmp dir
  var filesToAnalyze = <String>[];
  for (var file in files) {
    var tmpFile = toTmp(file);
    File(tmpFile).createSync(recursive: true);
    file.copySync(tmpFile);
    filesToAnalyze.add(tmpFile);
  }

  // format
  await formatFiles(filesToAnalyze);

  // compare them
  for (var file in files) {
    test('format of $file', () {
      var tmpFile = toTmp(file);
      var actual = File(tmpFile).readAsStringSync();
      var expected = File(
        '${file.path.substring(0, file.path.length - actualSuffix.length)}_expected.dart',
      ).readAsStringSync();
      expect(actual, equals(expected));
    });
  }
}

// TODO(aar): replace with something else once https://github.com/dart-lang/test/issues/110 is fixed
Uri get currentFile => (reflectClass(_TestUtils).owner as LibraryMirror).uri;

class _TestUtils {}
