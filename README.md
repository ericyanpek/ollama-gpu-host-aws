# Gemma Synth Host

EC2 + Ollama 托管 **Gemma 4 26B-A4B**,用于数据合成等旁路任务。

和主微调项目 [`llm-fine-tune-research`](../llm-fine-tune-research) 解耦——不共享
stack、不共享代码、不共享 IAM/S3 资源。只共享一份设计哲学:零公网端口、SSM 访问、
加密 EBS、可一键销毁。

## 适用场景

- 用本地已验证的 Gemma 4 26B(Q4_K_M, 17 GB)批量生成训练 / 偏好数据
- 短期(几小时到一两天)任务,跑完就销毁
- 单 GPU 足够,不需要分布式

## 不适用场景

- 高并发生产服务(Ollama 没有 continuous batching,应改用 vLLM)
- 模型训练(用主项目的 training-env)
- 长期持续运行(此时 Bedrock on-demand API 通常更便宜)

## 架构

```
MacBook  ──SSM port-fwd:11434──>  EC2 g5.xlarge (默认 VPC 内)
                                     └─ Ollama + gemma4:26b (Q4_K_M)
                                     └─ 127.0.0.1:11434 (不对公网)
                                     └─ IAM: SSM + S3 写
结果 JSONL  ──────────────────────>  S3 artifact bucket
```

- 默认 VPC、第一个兼容 AZ 的子网
- 零 inbound 的 Security Group,出口仅放行 443 / 80 / 53 / 123
- 根卷 100 GB gp3、加密、IMDSv2 required
- 空闲 1 小时自动关机(避免跑完没人关机)

## 前置

```bash
# AWS CLI v2 + Session Manager plugin
brew install awscli
brew install --cask session-manager-plugin

# 确认账号和默认 region
aws sts get-caller-identity
aws configure get region
```

## 用法

```bash
# 1) 部署(默认 us-east-1、g5.xlarge On-Demand)
./scripts/deploy.sh

# Spot(省 ~60%,合成任务推荐)
USE_SPOT=true ./scripts/deploy.sh

# 换 region / 机型
AWS_REGION=us-west-2 INSTANCE_TYPE=g6e.xlarge ./scripts/deploy.sh
```

UserData 会自动完成:装 Ollama → `ollama pull gemma4:26b` → 预热一次,整体 8–12 分钟。
看进度:

```bash
./scripts/status.sh
```

模型就绪后,本地起 SSM 转发:

```bash
./scripts/tunnel.sh
# 本地 curl http://localhost:11434/api/tags 能看到 gemma4:26b
```

合成脚本里用 OpenAI-兼容 client:

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")
resp = client.chat.completions.create(
    model="gemma4:26b",
    messages=[{"role": "system", "content": "..."},
              {"role": "user", "content": "..."}],
    temperature=1.0, top_p=0.95,
    # Gemma 4 defaults to thinking mode, which dumps reasoning tokens
    # instead of the answer. OpenAI endpoint does not expose `think`, so
    # use Ollama's /api/chat directly (see below) or set a system prompt
    # that discourages reasoning.
)
```

**Gemma 4 thinking mode 必须显式关闭**——默认开启时,模型会把几百 token 的思考链写进
`message.reasoning` 字段,`content` 可能为空。合成数据要的是直接回答,用 Ollama 原生 API:

```python
import requests
r = requests.post("http://localhost:11434/api/chat", json={
    "model": "gemma4:26b",
    "messages": [{"role": "user", "content": "..."}],
    "think": False,                              # 关键
    "stream": False,
    "options": {"temperature": 1.0, "top_p": 0.95, "num_predict": 512},
})
print(r.json()["message"]["content"])
```

合成结果传 S3:

```bash
aws s3 cp data/synth/sft_v1.jsonl s3://$ARTIFACT_BUCKET/synth/
```

用完一定销毁:

```bash
./scripts/destroy.sh
```

## 机型推荐

| 机型 | GPU | VRAM | Spot 估价 | 适用 |
|---|---|---|---|---|
| `g5.xlarge`(默认) | A10G | 24 GB | ~$0.35–0.50/h | 够用,性价比最高 |
| `g6.xlarge` | L4 | 24 GB | ~$0.30–0.45/h | 更便宜,decode 略慢 |
| `g6e.xlarge` | L40S | 48 GB | ~$0.70–1.00/h | 想跑 BF16 / FP8、吞吐翻倍 |

Gemma 4 26B-A4B Q4_K_M 约 17 GB VRAM,24 GB 够带 32K context 和
`OLLAMA_NUM_PARALLEL=4`。

## 成本估算

A10G Spot + Ollama `NUM_PARALLEL=4` 聚合约 80–120 tok/s。

- 1 千条种子多轮对话 ≈ 1.5M 输出 token ≈ 3.5–5 小时 ≈ **$1.5–2.5**
- 1 万条 ≈ 15M 输出 token ≈ 35–50 小时 ≈ **$15–25**

EBS 卷 100 GB gp3 $0.008/h,可忽略。

## 安全基线

- **零 inbound**:Security Group 不开任何入站端口;访问必须经 SSM
- **Ollama bind 127.0.0.1**:即使有人闯进子网也打不到 API
- **IMDSv2 required**,`HttpPutResponseHopLimit: 2`(容器兼容)
- **EBS 加密**,S3 bucket 强制 TLS、全部 block public
- **IAM** 最小权限:SSM core + 写 artifact bucket;无 `ec2:*`、无 `iam:*`

## 销毁注意

- `./scripts/destroy.sh` 走 `cloudformation delete-stack`
- **artifact bucket 是 Retain**,不会被 stack 删除(合成结果宝贵);想彻底删自己
  `aws s3 rb --force`
- EBS 卷随 EC2 一并销毁

## 文件

```
gemma-synth-host/
├── README.md                      # 本文件
├── cloudformation/
│   └── ollama-host.yaml           # 单文件 stack
└── scripts/
    ├── deploy.sh                  # 创建 / 更新
    ├── destroy.sh                 # 销毁
    ├── tunnel.sh                  # SSM 端口转发 11434
    ├── ssm-shell.sh               # SSM 交互式 shell
    └── status.sh                  # 查看 bootstrap 进度 / 模型就绪状态
```
