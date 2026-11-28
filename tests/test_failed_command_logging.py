import subprocess
import sys

import pytest

from engine.python.basketball_engine.adapters import export
from engine.python.basketball_engine.adapters.analysis import run_pipeline, PipelineCancelled
from engine.python.basketball_engine.diagnostics import log_failed_command


def test_failed_commands_are_single_line_and_bounded(capsys):
    log_failed_command('media command failed', ['ffmpeg', 'a\nb', 'x' * 3000], 1)
    text = capsys.readouterr().err
    assert len(text.splitlines()) == 1
    assert r'a\nb' in text
    assert '[truncated original_chars=' in text
    assert len(text.split('argv=', 1)[1].rstrip()) == 1500


def test_real_failed_process_records_every_encoder_attempt_and_decision(tmp_path, capsys):
    output = tmp_path / 'out.mp4'
    with pytest.raises(subprocess.CalledProcessError):
        export.run_encoded_ffmpeg(
            lambda codec: [sys.executable, '-c', 'import sys; sys.exit(1)', codec, str(output)],
            output, ['first', 'second'],
        )
    text = capsys.readouterr().err
    assert text.count('media command failed') == 2
    assert text.count('encoder first failed, trying second') == 1
    assert '"first"' in text and '"second"' in text
    assert '.part.mp4' in text


def test_analysis_failure_records_argv_and_stage(tmp_path, capsys):
    with pytest.raises(RuntimeError):
        run_pipeline([[sys.executable, '-c', "raise ValueError('failure')", 'x' * 3000]],
                     tmp_path / 'out.json')
    text = capsys.readouterr().err
    assert text.count('pipeline command failed stage=prepare_proxy') == 1
    assert 'truncated original_chars=' in text
    assert len(text.splitlines()) == 1


def test_success_does_not_log_argv(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(export, 'validate_media_file', lambda _, **kwargs: None)
    output = tmp_path / 'out.mp4'
    export.run_atomic_ffmpeg([
        sys.executable, '-c', "import sys; from pathlib import Path; Path(sys.argv[-1]).write_bytes(b'video')",
        str(output),
    ], output)
    assert output.read_bytes() == b'video'
    assert 'command failed' not in capsys.readouterr().err


def test_cancel_is_not_logged_as_a_command_failure(tmp_path, capsys):
    with pytest.raises(PipelineCancelled):
        export.run_atomic_ffmpeg([sys.executable, '-c', 'import time; time.sleep(30)', str(tmp_path/'out.mp4')],
                                 tmp_path/'out.mp4', cancel_check=lambda: True)
    assert 'command failed' not in capsys.readouterr().err
