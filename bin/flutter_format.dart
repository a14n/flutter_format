//  Copyright 2019 Google LLC
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import 'dart:io';

import 'package:flutter_format/flutter_format.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    args = ['.'];
  }
  args = args
      .expand<File>((e) {
        var dir = Directory(e);
        var file = File(e);
        if (dir.existsSync()) {
          return findDartFile(dir, allowDartIgnore: true);
        } else if (file.existsSync()) {
          return [file];
        }
        throw ArgumentError.value(
          e,
          null,
          'this is not a valid file/directory',
        );
      })
      .map((f) => f.path)
      .toList()
        ..sort();
  await formatFiles(args);
}
