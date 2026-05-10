# Ollama GPU Host on AWS

一个通用的、短期运行的 GPU EC2 + Ollama 栈,用来托管任意 Ollama 兼容模型。
零公网端口、SSM 访问、加密 EBS、可一键销毁,便于按需起停。

> 历史原因,仓库文件夹仍叫 `gemma-synth-host/`——因为最初是为 Gemma 4 数据合成
> 任务搭的。stack / project / AMI 等内部命名已经改成中性名(`ollama-host`),
> 想换模型改一个 env var 即可。

## 适用场景

- **数据合成**:用一个较大的 teacher 模型(Gemma 4 / Llama 3.1 70B / Qwen 2.5 72B
  量化版等)批量生成训练或偏好数据
- **临时推理**:App 还没上生产,又想在云上跑模型做评测、demo、写 prompt
- **单 GPU 够用**的任何 Ollama 工作流,时间从几小时到几天

不适用:
- 生产级高并发(Ollama 没有 continuous batching,建议 vLLM / SGLang)
- 模型训练(微调用专门的训练环境)
- 长期 7×24(这时候 Bedrock / 托管 API 往往更便宜)

## 架构

```
MacBook  ──SSM port-fwd:11434──>  EC2 g5.xlarge (默认 VPC 内)
                                     └─ Ollama + <your model>
                                     └─ 127.0.0.1:11434 (不对公网)
                                     └─ IAM: SSM + S3 写
artifacts ───────────────────────>  S3 bucket
```

- 默认 VPC、第一个兼容 AZ 的子网
- 零 inbound 的 Security Group,出口仅放行 443 / 80 / 53 / 123
- 根卷 100 GB gp3、加密、IMDSv2 required
- 空闲 1 小时自动关机

## 前置

```bash
brew install awscli
brew install --cask session-manager-plugin

aws sts get-caller-identity
aws configure get region
```

## 用法

### 默认:Gemma 4 26B(已 smoke-tested)

```bash
./scripts/deploy.sh                       # us-east-1、g5.xlarge、gemma4:26b
USE_SPOT=true ./scripts/deploy.sh         # Spot 省 ~60%
```

### 换模型

```bash
OLLAMA_MODEL=llama3.1:8b ./scripts/deploy.sh

# 大模型需要更大 GPU
INSTANCE_TYPE=g6e.xlarge \
OLLAMA_MODEL=llama3.1:70b-instruct-q4_K_M \
ROOT_VOLUME_GB=200 \
./scripts/deploy.sh
```

`OLLAMA_MODEL` 可以是 [ollama.com/library](https://ollama.com/library) 任何 tag。
配对 GPU 时按 "**模型磁盘大小 × 1.1 ≈ VRAM 需求**" 估一下,留 2GB 给 KV cache:

| 模型体积 | 合适机型 |
|---|---|
| ≤ 9GB | g5.xlarge / g6.xlarge(24GB) |
| 9–20GB | g5.xlarge / g6.xlarge(24GB),单流;推荐 g5.2xlarge 留多点 CPU |
| 20–40GB | g6e.xlarge(48GB L40S) |
| 40–70GB | 需要量化版,或 `g5.12xlarge`/`g6e.12xlarge` 多卡(本模板未适配多卡) |

### 部署后

```bash
./scripts/status.sh                       # 轮询到 ollama-ready 出现(8–12 分钟)
./scripts/tunnel.sh                       # 开 SSM 端口转发 11434
curl http://localhost:11434/api/tags      # 从 Mac 端验证
```

合成/推理脚本用 OpenAI 兼容 client,或者 Ollama 原生 API:

```python
# 普通模型
from openai import OpenAI
client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")
resp = client.chat.completions.create(
    model="gemma4:26b",                   # 或任何已 pull 的 tag
    messages=[...],
    temperature=0.8,
)

# 对于带 thinking/reasoning 模式的模型(Gemma 4、DeepSeek-R1 等),
# 合成数据时需要关闭 reasoning,OpenAI endpoint 不透传这个参数,
# 改用 Ollama 原生 API:
import requests
r = requests.post("http://localhost:11434/api/chat", json={
    "model": "gemma4:26b",
    "messages": [...],
    "think": False,                       # Gemma 4 必须关,否则 content 为空
    "stream": False,
    "options": {"temperature": 0.8, "num_predict": 512},
})
print(r.json()["message"]["content"])
```

### 销毁

```bash
./scripts/destroy.sh                      # EC2、SG、IAM 都删;S3 桶是 Retain,需要的话手动删
```

## 机型参考(us-east-1 价格)

| 机型 | GPU | VRAM | On-Demand | Spot | 适用 |
|---|---|---|---|---|---|
| `g5.xlarge`(默认) | A10G | 24 GB | ~$1.0/h | ~$0.35–0.50/h | 7B–26B 量化 |
| `g5.2xlarge` | A10G | 24 GB | ~$1.2/h | ~$0.40–0.55/h | 同上,多 CPU 对数据处理更舒服 |
| `g6.xlarge` | L4 | 24 GB | ~$0.8/h | ~$0.30–0.45/h | 同档,L4 比 A10G 略慢一点 |
| `g6e.xlarge` | L40S | 48 GB | ~$1.9/h | ~$0.70–1.00/h | 30B 满精度 / 70B 量化 / FP8 |

## 安全基线

- 零 inbound SG
- `OLLAMA_HOST=127.0.0.1:11434`,即使 VPC 内其他主机也打不到
- IMDSv2 required,`HttpPutResponseHopLimit: 2`
- EBS 加密,S3 强制 TLS + block public
- IAM 最小权限:SSM core + 单 bucket 读写;无 `ec2:*`、无 `iam:*`

## 成本快算

A10G Spot 单流 ~60–100 tok/s、`NUM_PARALLEL=4` 聚合 80–120 tok/s:

- 1 千条多轮对话 ≈ 1.5M 输出 tok ≈ 3.5–5h ≈ **$1.5–2.5**
- 1 万条 ≈ 15M 输出 tok ≈ 35–50h ≈ **$15–25**

EBS 100 GB gp3 $0.008/h,可忽略。

## 文件

```
ollama-host/                              # 文件夹目前叫 gemma-synth-host/(历史)
├── README.md                             # 本文件
├── cloudformation/
│   └── ollama-host.yaml
├── docs/
│   └── smoke-test-notes.md               # smoke test 的发现和修复记录
└── scripts/
    ├── deploy.sh / destroy.sh
    ├── tunnel.sh / ssm-shell.sh
    └── status.sh
```

## 注意事项

- **首次 deploy 后要清 S3 桶才能 re-deploy**:桶是 `DeletionPolicy: Retain`,
  stack 删了它不删;再次 `deploy.sh` 前手动 `aws s3 rb s3://<name> --force`。
  `destroy.sh` 会提示桶名。
- **Thinking-mode 模型默认有大量 reasoning token**:合成场景用 `/api/chat` +
  `think:false`。详见 [docs/smoke-test-notes.md](./docs/smoke-test-notes.md) 第 4 节。
- **Ollama pull 在非 TTY 可能卡在 verify**:UserData 已做 timeout+retry 兜底,
  血泪史见 smoke-test-notes 第 3 节。
