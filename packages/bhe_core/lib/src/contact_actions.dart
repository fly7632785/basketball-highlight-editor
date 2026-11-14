const feedbackEmail = 'hanzexi0411@gmail.com';

String feedbackMailto({String? appVersion, bool english = false}) {
  final subject = Uri.encodeComponent(english ? 'BHE feedback' : 'BHE 反馈');
  final body = Uri.encodeComponent(
    english
        ? 'Description:\n\nSteps to reproduce:\n\nEnvironment: ${appVersion ?? 'Not provided'}\n'
        : '问题描述：\n\n复现步骤：\n\n环境信息：${appVersion ?? '未填写'}\n',
  );
  return 'mailto:$feedbackEmail?subject=$subject&body=$body';
}

const githubIssueUrl =
    'https://github.com/fly7632785/basketball-highlight-editor/issues/new?template=bug_report.yml';
