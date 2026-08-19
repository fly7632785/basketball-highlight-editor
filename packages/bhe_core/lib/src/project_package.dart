import 'dart:convert';

import 'models.dart';

class ProjectPackageCodec {
  const ProjectPackageCodec();

  String encode(ProjectSnapshot project) => const JsonEncoder.withIndent('  ').convert({
        'format': 'bhe-project',
        'version': 1,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'project': project.toJson(),
      });

  ProjectSnapshot decode(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) throw const FormatException('项目包格式无效');
    if (decoded['format'] != 'bhe-project') throw const FormatException('不是 BHE 项目包');
    final project = decoded['project'];
    if (project is! Map) throw const FormatException('项目数据缺失');
    return ProjectSnapshot.fromJson(project.cast<String, dynamic>());
  }
}
