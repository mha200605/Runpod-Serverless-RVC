# RVC v2 voice conversion on RunPod Serverless

File/API-based RVC v2 conversion (no real-time audio). Send audio + a model id, get converted audio back
(base64 now; a pre-signed URL once S3-compatible storage is configured, **same API**).

Engine: [Applio](https://github.com/IAHispano/Applio) (MIT) pinned to commit
`29b4a00e4be209f9aac51cd9ccffcc632dfb2973`, RMVPE pitch extraction, ContentVec embedder.

## Verification status (read this first)

| Item | Status |
|---|---|
| `VoiceConverter.convert_audio(...)` exists with the parameters this worker passes | **Verified** by reading `rvc/infer/infer.py` and `core.py` at the pinned commit |
| Prerequisite downloader import path + 6-bool signature | **Verified** in `core.py` |
| Worker logic (validation, SSRF guard, model store, sinks, error mapping, client) | **Unit-tested offline**: `python -m unittest discover -s tests -v` (28 tests, fake engine) |
| Docker image builds; Applio's `requirements.txt` at that commit installs next to `runpod` | **Not yet run.** Needs the RunPod/GitHub build |
| RMVPE + ContentVec weights land where Applio expects them | **Not yet run.** `build_prereqs.py` fails the build with a file listing if not |
| Real GPU conversion with a real `.pth`/`.index`; timings; cost per conversion | **Not yet run** |
| S3/R2/B2 output | Code written, **untested** (no bucket yet) |
| `schemas/*.json` validated against examples | JSON parses; **not** validated with a JSON-Schema library |

## Layout

```
Dockerfile                 pinned Applio + deps + baked base models (RMVPE, ContentVec)
requirements-worker.txt    runpod SDK pin      requirements-s3.txt  (only with --build-arg INSTALL_S3=1)
scripts/                   build-time prerequisite download + smoke test
src/                       handler.py (entrypoint) service.py rvc_engine.py model_store.py sinks.py schemas.py security.py config.py
schemas/                   input.schema.json, output.schema.json
client/rvc_client.py       Python client + CLI
examples/                  request payloads        deploy/  proposed endpoint config (not applied)
tests/test_core.py         offline unit tests
```

## Deploy (GitHub build)

1. Put this folder at the **root** of a new GitHub repo and push (the Dockerfile must be at the repo root).
2. RunPod console -> Serverless -> New Endpoint -> **GitHub repo**; pick the repo/branch.
3. Use the values in `deploy/endpoint.proposed.json`: GPU pools `AMPERE_16` + `AMPERE_24`, 1 GPU, **max workers 1**,
   min workers 0, idle timeout 60 s (test) / 5 s (later), execution timeout 300 s, FlashBoot on, container disk 20 GB,
   env vars as listed. Do **not** attach a network volume yet.
4. Watch the build log. Copy the `pip freeze` block it prints into `requirements.lock.txt` and commit it.
5. Give the endpoint id to Claude to run the test plan below (the RunPod MCP can read logs, submit jobs, and adjust the endpoint).

## API

POST `https://api.runpod.ai/v2/<ENDPOINT_ID>/run` (async) or `/runsync`, header `Authorization: Bearer <RUNPOD_API_KEY>`,
body `{"input": {...}}`. Poll `GET /status/<job_id>`. Full schemas: `schemas/`.

**Convert** (default action)

```json
{"input": {
  "model_id": "my_voice",
  "audio_url": "https://host/in.wav",          // or "audio_b64": "<base64>"  (exactly one)
  "pth_url": "https://host/my_voice.pth",       // only needed the first time for this model_id
  "index_url": "https://host/my_voice.index",   // optional
  "pitch": 0, "f0_method": "rmvpe", "filter_radius": 3,
  "f0_autotune": false, "f0_autotune_strength": 1.0,
  "index_rate": 0.75, "protect": 0.33, "volume_envelope": 1.0,
  "split_audio": false, "clean_audio": false, "clean_strength": 0.7,
  "export_format": "WAV", "return_mode": "auto"
}}
```

**Success output** (`output` of the completed job)

```json
{"status": "ok", "action": "convert", "model_id": "my_voice", "delivery": "base64",
 "audio_b64": "UklGR...", "audio_url": null, "expires_in_s": null,
 "audio_format": "wav", "content_type": "audio/wav", "sample_rate": 40000, "duration_s": 12.3, "size_bytes": 984044,
 "model": {"registered_now": false, "has_index": true, "index_used": true, "version": "v2"},
 "worker": {"cold_start": false, "device": "cuda", "storage_mode": "ephemeral"},
 "timings": {"model_fetch_s": 0.0, "input_fetch_s": 0.4, "convert_s": 2.1, "publish_s": 0.0, "total_s": 2.6},
 "warnings": []}
```

**Errors** return `{"status":"error","error_code":"...","error":"CODE: message"}`; RunPod reports the job as `FAILED`.
Codes: `INVALID_INPUT`, `DOWNLOAD_FAILED`, `MODEL_NOT_FOUND`, `CONVERSION_FAILED`, `OUTPUT_FAILED`, `INTERNAL_ERROR`.

**Other actions:** `ping` (versions, GPU, storage mode; no inference), `register_model`, `list_models`, `delete_model`.
Unknown fields are rejected so typos fail loudly.

## Python client

```python
# pip install requests ; export RUNPOD_API_KEY=...   (never put the key in code)
from client.rvc_client import RvcClient
c = RvcClient("YOUR_ENDPOINT_ID")
print(c.ping())
c.register_model("my_voice", "https://host/my_voice.pth", "https://host/my_voice.index")
res = c.convert(model_id="my_voice", audio_path="in.wav", out_path="out.wav", pitch=0, index_rate=0.75)
print(res["timings"])
```
CLI: `python client/rvc_client.py --endpoint ID convert my_voice in.wav out.wav --pitch 2`

## Models: upload and adding more

The worker keeps one directory per voice: `<models_dir>/<model_id>/{model.pth, model.index, meta.json}`.
There is no file-upload API: you give the worker **URLs** and it downloads once.

1. Host the `.pth` (and `.index`) somewhere the worker can fetch with a plain GET: a pre-signed S3/R2/B2 URL, a public
   Hugging Face `resolve/` link, etc. (No auth headers are sent; share-page links such as Google Drive viewers return HTML and are rejected.)
2. Register: `action=register_model` with `model_id`, `pth_url`, optional `index_url` - or just include the URLs on the first `convert`.
3. Later requests send only `model_id`. To add another voice, repeat with a new `model_id`. To replace one, pass `overwrite`
   (`register_model`) / `overwrite_model` (`convert`). `delete_model` removes one.

`model_id`: letters, digits, `_`, `-`, max 64, must **not** contain "trained" (Applio rewrites that word inside index paths).
Only **RVC v2** checkpoints are accepted; v1 is rejected with a clear error.

**Persistence.** Without a network volume the store lives in `/tmp` (`storage_mode: "ephemeral"`) and is lost when a worker is
recycled, so the first request on a new worker re-downloads. Attaching a RunPod network volume makes the worker automatically use
`/runpod-volume/rvc/models` (`storage_mode: "network-volume"`) - no code change. A network volume pins the endpoint to that volume's data center.

## S3-compatible output (later, no API change)

Rebuild with `--build-arg INSTALL_S3=1` (pin boto3 in `requirements-s3.txt` first), set env `S3_BUCKET`, `S3_ACCESS_KEY_ID`,
`S3_SECRET_ACCESS_KEY` (as RunPod secrets), optional `S3_ENDPOINT_URL`, `S3_REGION`, `S3_PREFIX`, `S3_PRESIGN_TTL_S`.
`return_mode: "auto"` then returns `audio_url`; `base64` still works. `url` without S3 configured returns `OUTPUT_FAILED`.

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `RVC_MODELS_DIR` | auto | force the model directory |
| `DEFAULT_RETURN_MODE` | `auto` | `auto` / `base64` / `url` |
| `MAX_INLINE_OUTPUT_MB` | 7 | refuse larger base64 responses (RunPod response size limits apply) |
| `MAX_AUDIO_MB` / `MAX_PTH_MB` / `MAX_INDEX_MB` | 100 / 512 / 1024 | download caps |
| `DOWNLOAD_TIMEOUT_S` | 120 | wall-clock cap per download |
| `ALLOW_PRIVATE_URLS` | 0 | allow URLs resolving to private IPs (leave off) |
| `ALLOWED_URL_HOSTS` | (empty) | comma list; if set, only these hosts may be fetched |
| `ALLOWED_F0_METHODS` | `rmvpe` | other Applio methods exist but are untested here |
| `PRELOAD_ENGINE` | 1 | load Applio + ContentVec at worker start |
| `LOG_LEVEL` | INFO | |

## Security notes

- A `.pth` is a pickle-based PyTorch file. **Only register models you trust.** Anyone with your RunPod API key can call the endpoint.
- Downloads block private/loopback/link-local addresses (including redirects) and cap size and time. DNS rebinding is not fully
  excluded; use `ALLOWED_URL_HOSTS` if the endpoint serves untrusted callers.
- Stored source URLs have their query strings removed (pre-signed URLs carry secrets).

## Known limitations

- Applio keeps **one** checkpoint loaded per worker; switching voices costs a model load (no multi-voice LRU in VRAM).
- WAV output is native; MP3/FLAC/OGG go through Applio's converter, which loads **mono**. M4A is not supported.
- Image is large (Applio installs its full training requirements). Slimming is possible later once the build is proven.
- Applio is in maintenance mode upstream; the commit is pinned on purpose.

## Local checks

```
python -m unittest discover -s tests -v     # no GPU / network needed
```

## First-test plan (after you approve the deployment)

1. `ping` - confirms GPU, torch/CUDA, Applio commit, storage mode.
2. `register_model` with your `.pth` + `.index` URLs.
3. `convert` with your test audio URL (or small base64) - check output audio, `timings`, `cold_start`.
4. Repeat `convert` with only `model_id` - confirms the cache (`registered_now: false`, `model_fetch_s ~ 0`).
5. Read worker logs; fix anything; then scale to the final settings (idle timeout 5 s).
