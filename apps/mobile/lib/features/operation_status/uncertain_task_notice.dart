part of '../../mobile_ui.dart';

class _UncertainTaskNotice extends StatelessWidget {
  const _UncertainTaskNotice({
    required this.keyName,
    required this.operation,
    required this.explanation,
    required this.guidance,
    required this.busy,
    required this.status,
    required this.error,
    required this.onStop,
    required this.onCheck,
  });
  final String keyName;
  final String operation;
  final String explanation;
  final String guidance;
  final bool busy;
  final String? status;
  final DiagnosticErrorRecord? error;
  final Future<TaskStopStatus> Function() onStop;
  final Future<TaskStopStatus> Function() onCheck;

  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey(keyName),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.bheText(operation),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(context.bheText(explanation)),
          const SizedBox(height: 8),
          Text(context.bheText(guidance)),
          if (status case final message?) ...[
            const SizedBox(height: 8),
            Text(context.bheText(message)),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: busy ? null : () => unawaited(onStop()),
                child: Text(context.bheText('再次尝试停止')),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: busy ? null : () => unawaited(onCheck()),
                child: Text(context.bheText('检查停止状态')),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () =>
                    unawaited(showMobileDiagnostics(context, error: error)),
                child: Text(context.bheText('诊断与复制')),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _UncertainExportNotice extends StatelessWidget {
  const _UncertainExportNotice({required this.state, this.forExport = false});
  final MobileAppState state;
  final bool forExport;
  @override
  Widget build(BuildContext context) => _UncertainTaskNotice(
    keyName: 'uncertain-export-notice',
    operation: '导出',
    explanation: forExport
        ? _exportL10n(context).mobileExportCanQueue
        : '上次任务尚未确认结束，暂时不能开始新的同类任务。',
    guidance: '请先复制诊断信息；若仍无法确认，请在系统设置中强制停止 BHE，重新打开后检查项目和已导出文件。',
    busy: state.checkingUncertainExport,
    status: state.uncertainExportStatus,
    error: state.uncertainExportDiagnostic,
    onStop: () => state.checkUncertainExport(stopFirst: true),
    onCheck: () => state.checkUncertainExport(),
  );
}

class _UncertainAnalysisNotice extends StatelessWidget {
  const _UncertainAnalysisNotice({required this.state});
  final MobileAppState state;
  @override
  Widget build(BuildContext context) => _UncertainTaskNotice(
    keyName: 'uncertain-analysis-notice',
    operation: '分析',
    explanation: '上次分析尚未确认停止，暂时不能开始新分析。',
    guidance: '请先复制诊断信息；若仍无法确认，请在系统设置中强制停止 BHE，重新打开后检查项目。',
    busy: state.checkingUncertainAnalysis,
    status: state.uncertainAnalysisStatus,
    error: state.uncertainAnalysisDiagnostic,
    onStop: () => state.checkUncertainAnalysis(stopFirst: true),
    onCheck: () => state.checkUncertainAnalysis(),
  );
}
