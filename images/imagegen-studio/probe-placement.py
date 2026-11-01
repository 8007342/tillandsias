# @trace order:1921-vkrr
# Placement probe for the ComfyUI studio: start ComfyUI, run ONE one-step
# SDXL-Lightning generation through its own API, and report where it ran.
#
#   backend=cuda ...  exit 0   the generation ran on an NVIDIA card
#   backend=cpu  ...  exit 1   it silently fell back to the CPU (the failure
#                              this probe exists to catch: device nodes are not
#                              placement, 917-zkge)
#   could-not-run:... exit 2   no checkpoint, server never came up, no image
#
# Runs inside the studio image with --network=none; the checkpoint comes from
# the shared cache mounted read-only at /models.
import json
import os
import subprocess
import sys
import time
import urllib.request

CKPT = os.environ.get("PROBE_CKPT", "sdxl_lightning_4step.safetensors")
BASE = "http://127.0.0.1:8188"


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=10) as r:
        return json.load(r)


def post(path, body):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def fail(msg, code=2):
    print(msg, flush=True)
    sys.exit(code)


if not os.path.isfile(os.path.join("/models/I1", CKPT)):
    fail(f"could-not-run:studio-placement:no-checkpoint:/models/I1/{CKPT}")

# Ask torch first. ComfyUI v0.40.0 does not fall back on its own: with no CUDA
# device it exits at start unless run with --cpu (measured on lenovinha), so
# a host without placement is named here as backend=cpu, not a server crash.
import torch  # noqa: E402

if not torch.cuda.is_available():
    print(f"backend=cpu reason=no-cuda-device torch={torch.__version__}", flush=True)
    sys.exit(1)

server = subprocess.Popen(
    [sys.executable, "/opt/comfyui/main.py", "--listen", "127.0.0.1", "--port", "8188",
     "--output-directory", "/out", "--user-directory", "/home/studio/user",
     "--temp-directory", "/home/studio/tmp", "--disable-auto-launch"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
try:
    stats = None
    for _ in range(180):
        if server.poll() is not None:
            fail(f"could-not-run:studio-placement:server-exited:{server.returncode}")
        try:
            stats = get("/system_stats")
            break
        except OSError:
            time.sleep(1)
    if stats is None:
        fail("could-not-run:studio-placement:server-never-answered")
    device = stats["devices"][0]
    backend = "cuda" if device.get("type") == "cuda" else "cpu"

    graph = {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": CKPT}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "a red fox in snow", "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["1", 1]}},
        "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 1024, "height": 1024, "batch_size": 1}},
        "5": {"class_type": "KSampler", "inputs": {
            "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["4", 0],
            "seed": 7, "steps": 1, "cfg": 1.0, "sampler_name": "euler", "scheduler": "sgm_uniform",
            "denoise": 1.0}},
        "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
        "7": {"class_type": "SaveImage", "inputs": {"images": ["6", 0], "filename_prefix": "probe"}},
    }

    def run_once():
        pid = post("/prompt", {"prompt": graph})["prompt_id"]
        t0 = time.monotonic()
        while time.monotonic() - t0 < 900:
            hist = get(f"/history/{pid}")
            if pid in hist:
                entry = hist[pid]
                if entry.get("status", {}).get("status_str") == "error":
                    fail("could-not-run:studio-placement:generation-error")
                images = [i for o in entry.get("outputs", {}).values() for i in o.get("images", [])]
                if not images:
                    fail("could-not-run:studio-placement:no-image")
                return time.monotonic() - t0
            time.sleep(0.25)
        fail("could-not-run:studio-placement:generation-timeout")

    cold = run_once()
    graph["5"]["inputs"]["seed"] = 8
    warm = run_once()
    line = (f"backend={backend} device={device.get('name', '?').replace(' ', '_')} "
            f"steps=1 size=1024 cold_s={cold:.2f} warm_s={warm:.2f} "
            f"vram_total_mib={int(device.get('vram_total', 0)) // 1048576}")
    print(line, flush=True)
    sys.exit(0 if backend == "cuda" else 1)
finally:
    server.terminate()
    try:
        server.wait(timeout=20)
    except subprocess.TimeoutExpired:
        server.kill()
