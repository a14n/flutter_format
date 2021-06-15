import 'dart:io';
import 'dart:math';

import 'package:_fe_analyzer_shared/src/scanner/token.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/syntactic_entity.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/generated/source.dart';
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

const indentation = 2;

class FlutterFormat extends GeneralizingAstVisitor<void>
    implements PostVisitCallback, PostAnalysisCallback, AstContext {
  final updatersByFile = <String, ContentUpdater>{};
  bool skipChildren = false;
  late String filePath;

  ContentUpdater get content {
    return updatersByFile.putIfAbsent(
      filePath,
      () => ContentUpdater(File(filePath).readAsStringSync()),
    );
  }

  @override
  void onVisitFinished() {}

  @override
  void postAnalysis(SurveyorContext context, DriverCommands cmd) {
    for (var e in updatersByFile.entries) {
      var updater = e.value;
      if (!updater.hasContentChanged) {
        continue;
      }
      File(e.key).writeAsStringSync(updater.content);
    }
    updatersByFile.clear();
  }

  @override
  void setFilePath(String filePath) {
    this.filePath = filePath;
    updatersByFile[filePath] =
        ContentUpdater(File(filePath).readAsStringSync());
  }

  @override
  void setLineInfo(LineInfo lineInfo) {}

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
      for (var element in elements) {
        var locNode = locOfNode(node);
        var loc = locOfEntity(element);
        content.moveToColumn(loc, locNode.columnNumber);
      }
    }
    super.visitAnnotatedNode(node);
  }

  @override
  void visitCompilationUnitMember(CompilationUnitMember node) {
    // TODO(a14n): remove once function in bodies are not used as parameters
    if (node.parent is Statement) {
      super.visitCompilationUnitMember(node);
      return;
    }

    var loc = locOfNode(node);
    content.moveToColumn(loc, 1);

    super.visitCompilationUnitMember(node);
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    var columnRef = content.getStartColumnOfLine(node.beginToken.offset);
    if (hasTrailingComma(node.parameters)) {
      visitNodeListWithTrailingComma(
        lineNumber: locOfEntity(node.leftParenthesis).lineNumber,
        newColumn: columnRef + indentation,
        nodes: node.parameters,
      );
      visitEndOfNodeListWithTrailingComma(
        columnRef,
        rightDelimiter: node.rightDelimiter,
        rightParenthesis: node.rightParenthesis,
      );
    }
    super.visitFormalParameterList(node);
  }

  @override
  void visitArgumentList(ArgumentList node) {
    var columnRef = content.getStartColumnOfLine(node.beginToken.offset);
    if (hasTrailingComma(node.arguments)) {
      visitNodeListWithTrailingComma(
        lineNumber: locOfEntity(node.leftParenthesis).lineNumber,
        newColumn: columnRef + indentation,
        nodes: node.arguments,
      );
      visitEndOfNodeListWithTrailingComma(
        columnRef,
        rightParenthesis: node.rightParenthesis,
      );
    }
    super.visitArgumentList(node);
  }

  void visitNodeListWithTrailingComma({
    required int lineNumber,
    required int newColumn,
    required NodeList nodes,
  }) {
    CharacterLocation locOfNodeWithComments(AstNode node) {
      var begin = node.beginToken;
      var comments = begin.precedingComments;

      // if commment start the line, we return it
      if (comments != null) {
        var commentLoc = locOfEntity(comments);
        var startLineCol = content.getStartColumnOfLine(comments.offset);
        if (commentLoc.columnNumber == startLineCol &&
            commentLoc.columnNumber != 1) {
          return commentLoc;
        }
      }

      return locOfEntity(begin);
    }

    for (var node in nodes) {
      var newLoc = CharacterLocation(
        locOfEntity(node.beginToken.previous!).lineNumber + 1,
        newColumn,
      );
      var locFull = locOfNodeWithComments(node);
      content.move(locFull, newLoc);
      var loc = locOfNode(node);
      content.moveToColumn(loc, newColumn);
    }
  }

  void visitEndOfNodeListWithTrailingComma(
    int columnRef, {
    Token? rightDelimiter,
    required Token rightParenthesis,
  }) {
    var endToken = rightDelimiter ?? rightParenthesis;
    var endTokenLoc = content.locOfOldOffset(endToken.offset);
    var precedingComments = endToken.precedingComments;
    visitComments(precedingComments, columnRef + indentation);
    var newLoc = CharacterLocation(
      locOfEntity(lastTokenBefore(endToken)!).lineNumber + 1,
      columnRef,
    );
    content.move(endTokenLoc, newLoc);
    if (rightDelimiter != null && rightParenthesis.precedingComments == null) {
      content.move(
        locOfEntity(rightParenthesis),
        CharacterLocation(
          newLoc.lineNumber,
          newLoc.columnNumber + 1,
        ),
      );
    }
  }

  @override
  void visitBlock(Block node) {
    var locLeftBracket = content.locOfOldOffset(node.leftBracket.offset);
    var locRightBracket = content.locOfOldOffset(node.rightBracket.offset);

    // column ref is harder to get
    if (locLeftBracket.lineNumber != locOfNode(node.parent!).lineNumber) {
      super.visitBlock(node);
      return;
    }

    // one liner
    if (locLeftBracket.lineNumber == locRightBracket.lineNumber) {
      super.visitBlock(node);
      return;
    }

    // statements
    var columnRef = content.getStartColumnOfLine(node.beginToken.offset);
    for (var statement in node.statements) {
      var loc = locOfNode(statement);
      content.moveToColumn(loc, columnRef + indentation);
    }

    // end bracket
    content.moveToColumn(locRightBracket, columnRef);

    super.visitBlock(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    skipChildren = true;
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    var locNode = locOfNode(node);
    for (var member in node.members) {
      var loc = locOfNode(member);
      content.moveToColumn(loc, locNode.columnNumber + indentation);
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitNode(AstNode node) {
    visitComments(
      node.beginToken.precedingComments,
      locOfNode(node).columnNumber,
    );

    if (skipChildren) {
      skipChildren = false;
      return;
    }
    super.visitNode(node);
  }

  void visitComments(CommentToken? comments, int columnRef) {
    while (comments != null) {
      var commentLoc = locOfEntity(comments);
      var startLineCol = content.getStartColumnOfLine(comments.offset);
      if (commentLoc.columnNumber == startLineCol &&
          commentLoc.columnNumber != 1) {
        content.moveToColumn(commentLoc, columnRef);
      }
      comments = comments.next as CommentToken?;
    }
  }

  Token? lastTokenBefore(Token token) {
    var comments = token.precedingComments;
    if (comments == null) return token.previous;
    while (true) {
      var next = comments?.next;
      if (next == null) {
        return comments;
      }
      comments = next as CommentToken?;
    }
  }

  bool hasTrailingComma(NodeList parameters) {
    if (parameters.isEmpty) return false;
    return parameters.last.endToken.next?.type == TokenType.COMMA;
  }

  CharacterLocation locOfNode(AstNode node) {
    final SyntacticEntity entity;
    if (node is AnnotatedNode) {
      entity = node.firstTokenAfterCommentAndMetadata;
    } else if (node is FormalParameter) {
      entity = node.childEntities
          .firstWhere((e) => e is! Comment && e is! Annotation);
    } else {
      entity = node;
    }
    return locOfEntity(entity);
  }

  CharacterLocation locOfEntity(SyntacticEntity entity) =>
      content.locOfOldOffset(entity.offset);
}

class ContentUpdater {
  ContentUpdater(this.initialContent)
      : content = initialContent,
        initialLineInfo = LineInfo.fromContent(initialContent) {
    lineInfo = initialLineInfo;
  }
  final String initialContent;
  final LineInfo initialLineInfo;
  String content;
  late LineInfo lineInfo;
  final changes = <Change>[];

  bool get hasContentChanged => initialContent != content;

  void move(CharacterLocation loc, CharacterLocation newLoc) {
    var locOffset = getOffsetOfLocation(loc);
    var deltaLine = newLoc.lineNumber - loc.lineNumber;
    if (deltaLine > 0) {
      makeChange(Change(
        locOffset,
        insertion: '\n' * deltaLine + ' ' * (newLoc.columnNumber - 1),
      ));
    } else if (deltaLine < 0) {
      var newLocOffset = getOffsetOfLocation(newLoc);
      makeChange(Change.shift(locOffset, newLocOffset - locOffset));
    } else {
      var deltaColumn = newLoc.columnNumber - loc.columnNumber;
      if (deltaColumn != 0) {
        makeChange(Change.shift(locOffset, deltaColumn));
      }
    }
  }

  void moveToColumn(CharacterLocation loc, int column) {
    move(loc, CharacterLocation(loc.lineNumber, column));
  }

  void makeChange(Change change) {
    changes.add(change);
    content = change.applyTo(content);
    lineInfo = LineInfo.fromContent(content);
  }

  CharacterLocation _locOfOffset(int offset) {
    var loc = lineInfo.getLocation(offset);
    return CharacterLocation(loc.lineNumber, loc.columnNumber);
  }

  int getOffsetOfLocation(CharacterLocation loc) {
    return lineInfo.lineStarts
            .asMap()
            .entries
            .lastWhere((e) => e.key + 1 <= loc.lineNumber)
            .value +
        loc.columnNumber -
        1;
  }

  int getStartColumnOfLine(int oldOffset) {
    var loc = locOfOldOffset(oldOffset);
    var lineNumber = loc.lineNumber;
    var lineOffset = lineInfo.getOffsetOfLine(lineNumber - 1);
    var contentAfter = content.substring(lineOffset);
    for (var i = 0; i < contentAfter.length; i++) {
      if (contentAfter[i] != ' ') return i + 1;
    }
    return 1;
  }

  CharacterLocation locOfOldOffset(int oldOffset) =>
      _locOfOffset(getCurrentOffset(oldOffset));

  int getCurrentOffset(int oldOffset) {
    var offset = oldOffset;
    for (var change in changes) {
      offset = change.updateOffset(offset);
    }
    return offset;
  }
}

class Change {
  Change(
    this.offset, {
    this.deleteBlankUntil,
    this.insertion,
  });

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
      if (s.substring(start, end).trim().isNotEmpty) {
        throw StateError(
          'attempt to delete : \n'
          '"${s.substring(max(0, start - 10), start)}'
          '>>>${s.substring(start, end)}<<<'
          '${s.substring(end, min(end + 10, s.length))}"',
        );
      }
      s = s.substring(0, start) + s.substring(end);
    }
    if (insertion != null) {
      s = s.substring(0, offset) + insertion! + s.substring(offset);
    }
    return s;
  }

  int updateOffset(int oldOffset) {
    if (oldOffset < offset + (min(deleteBlankUntil ?? 0, 0))) {
      return oldOffset;
    }
    if (oldOffset >= offset + max(deleteBlankUntil ?? 0, 0)) {
      return oldOffset -
          (deleteBlankUntil ?? 0).abs() +
          (insertion?.length ?? 0);
    }
    throw StateError('old offset was removed');
  }
}
