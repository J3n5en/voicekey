# -*- coding: utf-8 -*-
"""SenseVoice 常驻识别服务。

协议（一行一个 JSON，UTF-8）：
  请求  {"id": "1", "pcm": "<base64 16kHz mono int16>"}   或  {"id": "1", "ping": true}
  响应  {"id": "1", "text": "..."}                         或  {"id": "1", "error": "..."}
启动后先输出一行 {"ready": true, "device": "..."}。
"""
import base64
import json
import logging
import os
import re
import sys

# sentencepiece 打不开含中文的路径，模型放在纯英文目录下
MODEL_DIR = os.environ.get(
    "SENSEVOICE_MODEL",
    os.path.join(os.environ.get("APPDATA", ""), "VoiceKey", "sensevoice"),
)
DEVICE = os.environ.get("SENSEVOICE_DEVICE", "cuda:0")

TAG = re.compile(r"<\|[^|>]*\|>")
WS = re.compile(r"\s+")
# use_itn 会把缩写拆成单个字母（a p i → 需要合并回 api），这是 funasr 已知的副作用
SPELLED = re.compile(r"(?<![A-Za-z])(?:[A-Za-z]\s+){1,}[A-Za-z](?![A-Za-z])")


def clean(text: str) -> str:
    text = TAG.sub("", text)
    # 只合并 2~5 个单字母组成的串，避免把真正的短句（如 "I a"）误合
    def join(m: re.Match) -> str:
        letters = m.group(0).split()
        return "".join(letters) if 2 <= len(letters) <= 5 else m.group(0)
    text = SPELLED.sub(join, text)
    return WS.sub(" ", text).strip()


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    logging.basicConfig(stream=sys.stderr, level=logging.INFO, force=True)
    import numpy as np
    import torch
    # funasr 启动横幅直接 print 到 stdout，会污染协议，导入前改走 stderr
    import funasr.utils.version_checker as vc

    vc.print = lambda *a, **k: print(*a, file=sys.stderr, **k)
    from funasr import AutoModel

    device = DEVICE if torch.cuda.is_available() or not DEVICE.startswith("cuda") else "cpu"
    # 该模型的 bpe 文件名不是 funasr 默认的 bpe.model，必须显式指定
    bpe = os.path.join(MODEL_DIR, "chn_jpn_yue_eng_ko_spectok.bpe.model")
    model = AutoModel(
        model=MODEL_DIR,
        device=device,
        disable_update=True,
        tokenizer_conf={"bpemodel": bpe},
    )
    emit({"ready": True, "device": device})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            emit({"id": None, "error": f"bad json: {e}"})
            continue
        rid = req.get("id")
        try:
            if req.get("ping"):
                emit({"id": rid, "text": "pong"})
                continue
            pcm = np.frombuffer(base64.b64decode(req["pcm"]), dtype=np.int16)
            if pcm.size == 0:
                emit({"id": rid, "text": ""})
                continue
            audio = pcm.astype(np.float32) / 32768.0
            res = model.generate(
                input=audio,
                language="auto",
                use_itn=True,
                batch_size_s=300,
            )
            text = clean(res[0]["text"]) if res else ""
            emit({"id": rid, "text": text})
        except Exception as e:  # 单次失败不能拖垮服务
            emit({"id": rid, "error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        emit({"ready": False, "error": f"{type(e).__name__}: {e}"})
        sys.exit(1)
