# SenseVoice 本地识别渠道

用阿里 [SenseVoiceSmall](https://github.com/FunAudioLLM/SenseVoice) 在本机做语音识别，音频不出本机。

- 支持中文、英文、粤语、日语、韩语
- **边说边出字**：录音过程中约每 700ms 把"到此为止"的音频重识别一次，结果直接上屏
- GPU 可用时自动用 GPU（CUDA），否则回落 CPU

## 工作方式

SenseVoiceSmall 是非自回归模型，一次前向吃掉整段音频、直接吐出整句，**没有增量解码**。所以这里的"实时出字"不是流式解码，而是：

1. 录音时持续累积 PCM
2. 每 700ms 取一份快照，整段送给推理服务
3. 拿到文本后与已上屏内容比对，只接受"不产生回退"的结果，交给 `Typer` 上屏
4. 松手后再识别一次作为定稿

这个做法能成立的关键是 **推理耗时与音频长度几乎无关**（1 秒音频和 8 秒音频都在 50ms 上下），所以反复重识别的开销可以忽略。

由于模型对同一段音频的多次识别在尾部可能波动（中英混句尤其明显），中间结果做了"只前推不回退"的过滤：末尾允许继续增长，出现回退的识别结果会被丢弃，避免上屏文字来回跳。

## 依赖

需要一个带 `funasr` 和 `torch` 的 Python 环境，且 `python` 在 PATH 中：

```bash
pip install funasr torch numpy
```

推理服务脚本 `sensevoice_server.py` 会随应用一起打包，运行时从程序所在目录加载。

## 模型

从 [HuggingFace](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) 或 [ModelScope](https://modelscope.cn/models/iic/SenseVoiceSmall) 下载 `SenseVoiceSmall`，在设置页点击「下载模型」选择该目录，程序会把必需文件拷到 `%APPDATA%\VoiceKey\sensevoice`。

> 模型不能放在含中文的路径下：sentencepiece 打开 bpe 文件时会因为路径编码报 `Not found`，所以必须落到纯英文目录。

## 限制

- **整段识别**：没有真正的流式解码，中间结果靠反复重识别近似
- **中英混句**：模型在混说场景下准确率一般，`use_itn` 开启时更明显（会把 `optimize` 识别成 `ize`）
- **多渠道模式**：SenseVoice 不参与「多渠道同时识别」，因为它是整段出字，与流式候选面板的交互不一致
