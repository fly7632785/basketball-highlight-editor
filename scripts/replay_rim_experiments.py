"""Replay private rim caches without video/model access; compare defaults to a git baseline."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import sys
import types

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from basketball_highlight.rim_experiments import RimExperiments, judge_candidates, load_config


def replay(cache_root, config, reference_ref="cb8de11"):
    source = subprocess.check_output(["git", "show", f"{reference_ref}:src/basketball_highlight/rim_check.py"], cwd=ROOT, text=True)
    baseline = types.ModuleType("rim_reference")
    exec(compile(source, "rim_reference.py", "exec"), baseline.__dict__)
    runs = total = dense = differences = 0
    changed = []
    for path in sorted(Path(cache_root).rglob("rim_check_*.input.json")):
        output_path = path.with_name(path.name.replace(".input.json", ".json"))
        if not output_path.is_file():
            continue
        inputs = json.loads(path.read_text(encoding="utf-8"))["candidates"]
        output = json.loads(output_path.read_text(encoding="utf-8"))
        results = output["results"]
        assert len(inputs) == len(results)
        old = []
        for item, result in zip(inputs, results):
            frames = result.get("frames")
            if result.get("status")=="skipped" or not isinstance(frames,list) or item.get("rim") is None:
                old.append({key:result.get(key) for key in ("version","status","reason","rim_width_px")})
            else:
                old.append(baseline.assess_rim_crossing(frames,item["rim"],result.get("net_motion_series")))
                dense += 1
        expected = [baseline.keep_unless_seen(c,True) for c in baseline.apply_video_occlusion(old)]
        untouched = copy.deepcopy(results)
        actual = judge_candidates(inputs,results,config=config,fps=output.get("fps"))
        assert results == untouched, "Replay mutated the original cache"
        for index,(a,b) in enumerate(zip(actual,expected)):
            core = {key:value for key,value in a.items() if key!="experiment"}
            if core != b:
                differences += 1
                changed.append({"cache":str(path.relative_to(cache_root)),"candidate_index":index,"time":inputs[index]["time"],"before":b,"after":a})
        runs += 1
        total += len(inputs)
    if not runs:
        raise ValueError("No rim cache pairs found")
    return {"runs":runs,"candidates":total,"dense_frames_candidates":dense,"differences":differences,"config":config.to_dict(),"config_hash":config.config_hash,"reference_ref":reference_ref,"changed":changed}


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root",type=Path,required=True)
    parser.add_argument("--config",help="JSON; otherwise BHE_RIM_EXPERIMENTS")
    parser.add_argument("--reference-ref",default="cb8de11")
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    config=load_config(args.config)
    report=replay(args.cache_root,config,args.reference_ref)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({key:value for key,value in report.items() if key!="changed"},ensure_ascii=False))
    sys.exit(1 if config.is_default and report["differences"] else 0)
