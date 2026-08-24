import json

from cache_io import read_json_cache, write_json_cache


def test_read_json_cache_returns_none_and_removes_invalid_json(tmp_path):
    cache_path = tmp_path / "broken.json"
    cache_path.write_text("{broken", encoding="utf-8")

    assert read_json_cache(cache_path, lambda value: isinstance(value, list)) is None
    assert not cache_path.exists()


def test_read_json_cache_rejects_unexpected_shape(tmp_path):
    cache_path = tmp_path / "wrong-shape.json"
    cache_path.write_text(json.dumps({"records": []}), encoding="utf-8")

    assert read_json_cache(cache_path, lambda value: isinstance(value, list)) is None
    assert not cache_path.exists()


def test_write_json_cache_round_trips_without_leaving_temp_file(tmp_path):
    cache_path = tmp_path / "nested" / "records.json"
    records = [{"time": 1.2, "detections": []}]

    write_json_cache(cache_path, records)

    assert read_json_cache(cache_path, lambda value: isinstance(value, list)) == records
    assert not cache_path.with_suffix(".json.tmp").exists()
