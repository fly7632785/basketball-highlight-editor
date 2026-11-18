# 分档与多标签接口（L428，r2-v1）

面向 L429 桌面界面；本卡只改引擎、存储与共享项目包模型。档位是读取时计算的结果，不改原分析判定、原始证据或人工审核。项目 `tier_rule_version` 固定为 `r2-v1`，显式 `set_tier_rule_version` 才能切换受支持规则。

## 分档

纯函数 `classify(evidence, mode, rule_version)` 返回 `{tier, reason, source}`；列表映射为 `tier/tier_reason/tier_source`。人工判断通过 evidence 的 `review_status/review_reason` 输入：人工 goal→must、非 auto_rim_check 的人工 excluded→excluded；pending/deferred/second_review 撤销覆盖并按算法重算。auto_rim_check 不是人工。

列表另返回只读布尔值 `likely_miss`（可能没进，仅供审核队列折叠）。只对疑似档位计算：复核 unsure/rejected 且原因 no_crossing/no_entry/no_exit，已存非空有效 overlay.trajectory 在同一 overlay.rim 的筐宽归一化区域（左右0.6，上0.6下1.2）内点数为0时为true；缺失/异常几何不满足上述几何判据；另有复核status=unsure且reason=no_crossing时也为true，不要求轨迹几何。no_entry/no_exit/not_occluded不因新增条件而改变。此标记不写库、不修改档位/来源/规则版本、不影响导出范围；轨迹漏点可能包括真进球，不能当作排除证据。人工✓/✕后不再标记。桌面疑似及全部队列将其沉底、默认折叠，展开后才加入快捷键审核顺序。

算法：fast/coarse/manual/来源缺失→suspect；refined 有已证实反弹/侧出且自动排除→excluded；正负冲突→suspect；否则仅复核 made、明确无反弹且无侧出反证、网动有限，校准样本≥8且中位数>0，并且网动≥中位数×0.30→must；其余suspect。未知规则保守suspect。理由是稳定英文代码；source为algorithm/user。

校准必须属于同次分析：`replace_candidates` 对本批 refined 且 rim_check.status=made 的有限网动计算中位数，记录 `evidence.tier_calibration={samples,median}` 与 `analysis_run_id/analysis_mode`。若现有逐帧复核已携带 scope=analysis_run_baseline_made 的 experiment.net_calibration，优先复用该次默认made标定，避免对已经筛过的结果再次标定。原证据保留。历史无校准数据不拼凑跨次分析中位数，只进suspect。直接调用纯函数时传同样校准对象。

`list_candidates` 返回 candidates，每项包含：

```json
{"tier":"suspect","tier_reason":"missing_calibration","tier_source":"algorithm","tags":[{"id":"p1","name":"小王"}],"players":[{"id":"p1","name":"小王"}],"player_id":"p1","player_name":"小王"}
```

`tags`/`players` 是同序标签对象数组；旧player_id/name是首标签投影。`selection_status` 对 must/suspect/excluded 分别为 included/pending/excluded，不再把所有未打叉当保留。原 `review_status` 保留。响应附项目 `tier_rule_version`。可选 `tiers` 和 `tags` 的列表过滤与导出共用集合函数；列表未传tiers表示全部。

## 标签写入（均带 project_root）

- `set_candidate_players {candidate_id,player_ids:[id,…]}` / `set_candidates_players {candidate_ids:[id,…],player_ids:[id,…]}` 整组替换，重复ID去重保序，空数组清空。
- `add_candidate_player/remove_candidate_player {candidate_id,player_id}`；批量 `add_candidates_player/remove_candidates_player {candidate_ids,player_id}`。在引擎事务内增删，避免界面读后覆盖其他写入。
- 返回 `{updated:N}`（单条N=1；批量按不同候选数）。批量任何候选/标签无效，整批回滚，INVALID_REQUEST。
- 旧 `set_candidate_player/set_candidates_player` 保留设置成唯一标签的语义（null清空）。
- `candidate_tags(candidate_id,player_id,position)` 为唯一来源，外键级联清理。旧player_id列同步首标签供兼容。迁移标记一次提交；重新打开不会把已移除旧标签加回。重分析优先保留同ID，其余按双向唯一最近事件匹配整组继承标签、人工结论与调整范围；歧义不自动继承。

## 导出筛选

`start_export` 新请求带 `tiers:["must",…]`（三种值，OR关系，空数组表示空集合）和 `tags:null|[id,…]`（null不限；非空数组任一标签命中；空数组无标签可命中）。集合是 `(tier∈tiers) AND (tags不限 OR 标签交集)`。指定 `tiers:["excluded"],tags:[囧的ID]` 可导出打叉片段。快照固定档位、理由、全部标签和规则版本，后续审核/换标签不改变已启动导出。

过渡兼容：**旧请求完全不带tiers** 时保留旧review_status非excluded范围；新界面默认显式发 `tiers:["must"],tags:null`。旧player_ids/include_unassigned仅在不带tags时作为旧标签过滤，仍按任意标签匹配；新tags优先。同一份筛选函数用于列表与导出，避免预览数量不一致。

`merge_by_player` 对筛选结果按每个匹配标签分别分组，每组每候选只出现一次；tags不限时全部标签各出一组；没标签的候选在未标记组。总candidate_count是独立片段数，不是各标签组之和。失败重试保留tiers/tags和规则版本。

## 项目包

共享 Candidate 新增 `players:List<String>` 名称数组；写包同时写 `player=首标签`。读包players存在时优先（空数组清空也优先），否则读旧player。copyWith未改标签时完整保留数组；旧单标签写入明确替换整组。手机本期不改界面；旧版手机软件读再写可能只保留首标签，无法承诺旧二进制无损。

## 验证与边界

覆盖缺失/NaN、人工覆盖及撤销、快速分析、反证/冲突、校准7/8样本/零中位数/30%边界；真实旧schema迁移重复打开及清空后不复活；事务失败/并发增删、级联删除、重分析整组继承及歧义；档位OR+标签OR+两者AND、排除+囧、分组去重；新旧项目包往返。规则r2-v1不承诺全场景误判率，L426统计不是独立真值保证。

迁移前自动备份与离线回滚：[TIERS_MIGRATION.md](TIERS_MIGRATION.md)。备份失败阻止迁移；真实旧项目只在完整副本上测试。
