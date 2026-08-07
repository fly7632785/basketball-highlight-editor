import json
import sys

from .protocol import ProtocolError, error_response, parse_request, response
from .service import EngineService


def main() -> int:
    service = EngineService()
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        request_id = None
        try:
            request = parse_request(line)
            request_id = request.get("request_id")
            result = service.handle(request["command"], request.get("payload", {}))
            output = response(request_id, result)
        except ProtocolError as exc:
            output = error_response(request_id, exc.code, exc.message, exc.details)
        except Exception as exc:
            output = error_response(request_id, "ENGINE_ERROR", str(exc))
        sys.stdout.write(json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

