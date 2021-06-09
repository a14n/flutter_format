import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/syntactic_entity.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/file_system/file_system.dart' hide File;
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as path;
import 'package:surveyor/src/driver.dart';
import 'package:surveyor/src/visitors.dart';

Iterable<File> findDartFile(
  Directory dir, {
  required bool allowDartIgnore,
}) sync* {
  if (allowDartIgnore &&
      File(path.join(dir.path, '.dartignore')).existsSync()) {
    return;
  }
  for (var e in dir.listSync()) {
    if (e is File && path.extension(e.path) == '.dart') {
      yield e;
    } else if (e is Directory) {
      yield* findDartFile(e, allowDartIgnore: allowDartIgnore);
    }
  }
}

Future<void> formatFiles(List<String> files) async {
  var collector = FlutterFormat();

  var driver = Driver.forArgs(files);
  driver.forceSkipInstall = true;
  driver.showErrors = false;
  driver.resolveUnits = false;
  driver.visitor = collector;

  await driver.analyze();
}

class FlutterFormat extends GeneralizingAstVisitor<void>
    implements PostVisitCallback, PostAnalysisCallback, AstContext {
  late Folder currentFolder;
  late String filePath;
  late LineInfo lineInfo;
  Set<Folder> contextRoots = <Folder>{};
  final changesByFile = <String, List<Change>>{};

  void addChange(Change change) {
    changesByFile.putIfAbsent(filePath, () => []).add(change);
  }

  @override
  void onVisitFinished() {}

  @override
  void postAnalysis(SurveyorContext context, DriverCommands cmd) {
    for (var e in changesByFile.entries) {
      var changes = e.value..sort((c1, c2) => c1.offset >= c2.offset ? -1 : 1);
      if (changes.isEmpty) {
        continue;
      }
      var file = File(e.key);
      var content = file.readAsStringSync();
      for (var change in changes) {
        if (false) {
          print([
            'apply change at ${lineInfo.getLocation(change.offset)} ',
            '(offset: ${change.offset}) ',
            if (change.deleteBlankUntil != null)
              'delete:${change.deleteBlankUntil} ',
            if (change.insertion != null)
              'insertion: -->${change.insertion}<--',
          ].join());
        }
        content = change.applyTo(content);
      }
      file.writeAsStringSync(content);
    }
    changesByFile.clear();
  }

  @override
  void setFilePath(String filePath) {
    this.filePath = filePath;
  }

  @override
  void setLineInfo(LineInfo lineInfo) {
    this.lineInfo = lineInfo;
  }

  @override
  void visitAnnotatedNode(AnnotatedNode node) {
    bool isSuperseedByAncestor<T>(
      AnnotatedNode node,
      T Function(AnnotatedNode) extract, [
      AnnotatedNode? current,
    ]) {
      var parent = (current ?? node).parent;
      return parent is AnnotatedNode &&
          (extract(parent) == extract(node) ||
              isSuperseedByAncestor(node, extract, parent));
    }

    var comment = node.documentationComment;
    var metadata = node.metadata;
    var elements = <SyntacticEntity>[
      if (comment != null &&
          !isSuperseedByAncestor(node, (e) => e.documentationComment))
        ...comment.tokens,
      if (metadata.isNotEmpty &&
          !isSuperseedByAncestor(node, (e) => e.metadata))
        ...metadata,
    ];
    if (elements.isNotEmpty) {
      var locNode =
          lineInfo.getLocation(node.firstTokenAfterCommentAndMetadata.offset);
      for (var element in elements) {
        var loc = lineInfo.getLocation(element.offset);
        var colDelta = locNode.columnNumber - loc.columnNumber;
        if (colDelta != 0) {
          addChange(Change.shift(element.offset, colDelta));
        }
      }
    }
    super.visitAnnotatedNode(node);
  }

  @override
  void visitCompilationUnitMember(CompilationUnitMember node) {
    if (node.parent is! Statement) {
      var offset = node.firstTokenAfterCommentAndMetadata.offset;
      var loc = lineInfo.getLocation(offset);
      if (loc.columnNumber > 1) {
        addChange(Change.shift(offset, 1 - loc.columnNumber));
      }
    }
    super.visitCompilationUnitMember(node);
  }
}

class Change {
  Change.shift(this.offset, int newOffsetDelta)
      : assert(newOffsetDelta != 0),
        deleteBlankUntil = newOffsetDelta > 0 ? null : newOffsetDelta,
        insertion = newOffsetDelta > 0 ? ' ' * newOffsetDelta : null;
  final int offset;
  final int? deleteBlankUntil;
  final String? insertion;

  String applyTo(String s) {
    var deleteDelta = deleteBlankUntil;
    if (deleteDelta != null) {
      var start = offset + (deleteDelta < 0 ? deleteDelta : 0);
      var end = offset + (deleteDelta < 0 ? 0 : deleteDelta);
      assert(s.substring(start, end).trim().isEmpty);
      s = s.substring(0, start) + s.substring(end);
    }
    if (insertion != null) {
      s = s.substring(0, offset) + insertion! + s.substring(offset);
    }
    return s;
  }
}
