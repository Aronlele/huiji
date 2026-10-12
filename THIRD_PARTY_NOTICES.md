# 第三方组件

本仓库发布应用源码和图标，不包含下载的模型及运行库。`prepare-speaker-models.sh` 从下列上游下载固定版本并校验 SHA256。已有许可证文件保留在 `Resources/SpeakerModels/`。

| 组件 | 用途 | 上游 | 许可证文件 |
| --- | --- | --- | --- |
| sherpa-onnx 1.13.8 | 本地推理及 C API；`Native/c-api.h` 为上游接口头文件 | https://github.com/k2-fsa/sherpa-onnx | `Resources/SpeakerModels/sherpa-LICENSE`（Apache 2.0） |
| ONNX Runtime | 本地 ONNX 执行 | https://github.com/microsoft/onnxruntime | `Resources/SpeakerModels/onnxruntime-LICENSE`（MIT） |
| ERes2NetV2 中文说话人模型 | 声纹提取 | https://github.com/modelscope/3D-Speaker | `Resources/SpeakerModels/embedding-LICENSE`（Apache 2.0） |
| pyannote segmentation 3.0 | 声音变化与重叠检测 | https://huggingface.co/pyannote/segmentation-3.0 | `Resources/SpeakerModels/segmentation-LICENSE`（MIT） |
| Silero VAD | 停顿检测 | https://github.com/snakers4/silero-vad | `Resources/SpeakerModels/vad-LICENSE`（MIT） |

Apple 系统框架由 macOS 提供。系统中文语音识别与可用的 Foundation Models 在本机运行。可选的 Ollama 和 Qwen3 需另行安装下载，不包含在本仓库；各组件及模型遵循其上游许可。

真人会议验证使用 AliMeeting 官方公开数据集（https://www.openslr.org/119/，CC BY-SA 4.0），仅下载至本机评估；本仓库不重新分发录音、人工会议文本或声纹。合成测试中的文本由项目生成，语音测试资料未包含在仓库。
