# 分档与多标签迁移：备份及回滚

首页列出最近项目只读数据库元数据，不创建目录、备份或执行兼容迁移。旧库缺少新字段时仅在返回值中使用默认值；封面只使用已有图片，不启动媒体处理。为保证扫描连 SQLite 的日志/共享内存文件也不改写，无 WAL 时只读主库，有非空 WAL 时将数据库和日志/共享内存复制到临时目录，仅读取副本中的已提交数据。复制期间源文件变化或副本读取失败时，卡片计数显示“—／待同步”，不将未知数量显示成 0；临时副本自动清理。真正打开时仍按下文先备份再迁移。

本机旧项目首次打开时，任何兼容迁移之前先用 SQLite 在线备份生成项目目录内的 `project.db.pre-tiers-v1.bak`。在线备份包含已提交的 WAL（尚未合入主文件的数据库日志）数据。新空项目不备份；旧项目的已有备份不覆盖。备份不能建立、损坏或项目身份不符时停止迁移。请保留该文件，不要将它当缓存清理。

迁移完成仍保留原证据、人工结论、片段范围及草稿；标签只从旧单标签迁移一次。备份保存迁移当时的状态，回滚将放弃之后的修改；以下步骤会另存当前数据库和日志，方便找回。旧版本程序再次打开备份后不理解新增多标签，建议只在确认需要回退时使用。

## 回滚步骤

1. 退出所有打开此项目的 BHE 窗口、后台引擎和 SQLite 工具，确认没有写入者。**不能在程序仍打开项目时替换数据库。**
2. 记录实际项目目录，确认固定备份属于该项目；下面将当前数据库、`-wal`、`-shm` 一起移到新建的 `tiers-rollback-state-*` 文件夹，保留当前状态。
3. 在退出程序后运行下方脚本。`BHE_PROJECT` 必须指向准备回滚的那个项目；验收时只指定真实旧项目的测试副本。脚本先检查备份完整性，再准备还原文件，不删除原始备份。

```sh
export BHE_PROJECT='/实际的项目目录'
python3 /保存下方Python代码的路径/rollback_tiers.py
```

```python
import os
import shutil
import sqlite3
import tempfile
from pathlib import Path
from uuid import uuid4

root = Path(os.environ['BHE_PROJECT']).expanduser().resolve()
backup = root / 'project.db.pre-tiers-v1.bak'
assert backup.is_file() and not backup.is_symlink(), '缺少普通备份文件'
with sqlite3.connect(backup.as_uri() + '?mode=ro&immutable=1', uri=True) as source:
    assert source.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    saved_ids = sorted(r[0] for r in source.execute('SELECT id FROM projects'))
with sqlite3.connect((root / 'project.db').as_uri() + '?mode=ro', uri=True) as current:
    assert sorted(r[0] for r in current.execute('SELECT id FROM projects')) == saved_ids
# sqlite3上下文仅提交/回滚，不自动关闭连接；Windows移动前必须显式关闭。
source.close()
current.close()
handle, name = tempfile.mkstemp(prefix='.restore-tiers-', dir=root)
os.close(handle)
temporary = Path(name)
try:
    shutil.copy2(backup, temporary)
    saved = root / ('tiers-rollback-state-' + uuid4().hex)
    saved.mkdir()
    for suffix in ['', '-wal', '-shm']:
        path = root / ('project.db' + suffix)
        if path.exists():
            path.rename(saved / path.name)
    temporary.replace(root / 'project.db')
finally:
    temporary.unlink(missing_ok=True)
with sqlite3.connect((root / 'project.db').as_uri() + '?mode=ro&immutable=1', uri=True) as restored:
    assert restored.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
restored.close()
print('ROLLBACK_EXIT=0')
```

4. 先用旧版本程序或只读 SQLite 检查项目。不要立刻用新版程序打开来验证旧结构：新版会再次迁移（固定备份仍不覆盖）。如需找回回滚前的修改，退出程序后，从 `tiers-rollback-state-*` 中恢复对应的整组数据库文件。移动/替换意外中断时，当前状态也在该文件夹内，先检查文件再处理，不反复覆盖。

## 本卡验证

实际旧项目原件只读，复制整个项目后才运行迁移。验收脚本从本页提取Python段原样执行，核对回滚后所有原表、原列、原行及旧结构；保留副本、自动备份和回滚前状态。项目副本的再次打开只用于证明迁移幂等。真实数据明细不放公开仓库，证据位置见 L428 汇报附录。
