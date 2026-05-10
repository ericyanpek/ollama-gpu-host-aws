# Ollama GPU Host on AWS

一套轻量的基础设施即代码(IaC)工程,用于在 AWS 上按需启动单台 GPU EC2 实例运行
Ollama,托管任意开源大语言模型。面向数据合成、模型评测、临时推理等短期负载
——通过 AWS Systems Manager Session Manager 端口转发访问,全程无公网入站面,
部署在 10 分钟内完成,按需销毁。

## 🎯 设计目标

社区上常见的 Ollama on EC2 部署方案在生产就绪性上通常存在两类问题:

- **过于简化**:对外开放 11434 端口,或通过 SSH 密钥接入,安全边界脆弱
- **过度工程化**:引入 Amazon EKS 或 Amazon ECS + Application Load Balancer,
  运维复杂度与短期任务场景不匹配

本项目的定位是 **Well-Architected 安全基线 + 开发者工作流**,在不牺牲任一侧的前提下
提供可重复、可审计、可一键销毁的部署形态。

## 🏛️ 架构与设计决策

| 维度 | 选择 | 依据 |
|---|---|---|
| 网络边界 | Bring-your-own VPC / Subnet,`deploy.sh` 自动识别 Default VPC 与首个兼容 AZ | 避免在共享账号中创建新 VPC,受 VPC 软限制约束 |
| 入站安全 | Security Group 零 inbound,出站仅放行 443 / 80 / 53 / 123 | 无公开攻击面,符合 Well-Architected Security Pillar "Apply security at all layers" |
| 访问路径 | AWS Systems Manager Session Manager + 端口转发 | 鉴权基于 IAM,操作留痕至 AWS CloudTrail,无需堡垒机、VPN 或公网 EIP |
| AMI | AWS Deep Learning Base GPU AMI(Ubuntu 22.04) | 预置 NVIDIA 驱动与 CUDA,节省约 15 分钟的首次启动时间 |
| 计算 | Amazon EC2 G5 / G6 / G6e 系列,Spot 可选 | 按模型体量选择,Spot 降低约 60% 成本 |
| 存储 | Amazon EBS gp3,100 GB,KMS 加密,`IOPS=3000` / `Throughput=250` | 匹配 Ollama 模型权重首次加载与大文件合成输出的 IO 特征 |
| 实例元数据 | IMDSv2 强制,`HttpPutResponseHopLimit=2` | 兼容容器化负载的同时阻断 SSRF 类攻击 |
| 持久化 | Amazon S3 artifact bucket,`DeletionPolicy: Retain`,TLS 强制 + Block Public Access | 训练 / 合成产物与实例生命周期解耦 |
| IAM | 最小权限:`AmazonSSMManagedInstanceCore` + 单 bucket 读写;不含 `ec2:*` / `iam:*` | 遵循 Principle of Least Privilege |
| 退出策略 | 空闲 1 小时自动 `shutdown -h`,`InstanceInitiatedShutdownBehavior: stop` | 保留 EBS 供快速恢复,防止非预期长时运行 |
| 成本护栏 | Spot + 自动关机 + 小根卷默认 | Well-Architected Cost Optimization Pillar 的多层防线 |

## 🧰 架构图

```
Developer Mac ──SSM port-fwd:11434──> EC2 G5/G6/G6e (Default VPC)
                                        ├─ Ollama runtime
                                        ├─ 127.0.0.1:11434 (loopback only)
                                        └─ IAM Instance Profile
                                            ├─ AmazonSSMManagedInstanceCore
                                            └─ S3 artifact RW (bucket-scoped)
synth outputs ────────────────────────> Amazon S3 (SSE, TLS enforced, versioned)
```

- VPC / Subnet:默认 VPC,首个兼容实例类型 AZ 的子网
- Security Group:零 inbound;egress 仅 443 / 80 / 53 / 123
- 根卷:100 GB gp3,KMS 加密,`DeleteOnTermination=true`
- 观测:Amazon CloudWatch Logs 收集 `user-data` 与 `ollama.service` 日志,
  GPU / 内存 / 磁盘指标经 CloudWatch Agent 上报

## 🔬 工程决策记录

模板中的以下配置均经过 smoke test 验证并固化。保留这份清单是为了让后续维护者
理解"为什么这样写",而不是被 UserData 的细节迷惑。

1. **DLAMI SSM Parameter 路径**:正确值为
   `/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id`;
   少掉 `base-` 前缀会解析为空,模板参数已固化
2. **`ollama pull` 在 root 上下文崩溃**:Ollama CLI 硬依赖 `$HOME/.ollama`;
   UserData 通过 `sudo -u ollama -H` 切换到服务账户执行,避免 `panic: $HOME is not defined`
3. **`ollama pull` 在非 TTY 环境 verify 阶段不退出**:blob 下载与 SHA256 校验均已完成,
   但客户端 epoll 循环等待服务端 "done" 信号,manifest 无法注册。模板采用
   "超时容忍 + 二次 pull + `/api/tags` 实际存在性校验"三步兜底,确认模型对外可达
   后再写 ready marker
4. **Gemma 4 / DeepSeek-R1 等 thinking mode 模型**:默认输出会进入 `message.reasoning`
   而非 `content`;Warm-up 与示例代码显式传 `"think": false`,对不支持该字段的
   模型为 no-op

完整记录参见 [docs/smoke-test-notes.md](./docs/smoke-test-notes.md)。

## ✅ 适用场景

- **训练数据合成**:Teacher 模型批量生成 SFT / DPO 语料
- **模型评测与原型**:评测 harness、prompt 迭代、Demo 演示
- **其他单 GPU 可承载的 Ollama 工作流**,运行周期数小时至数天

## 🚫 不适用场景

- 高并发生产推理:Ollama 无 continuous batching,建议采用 vLLM 或 SGLang,
  配合 Amazon ECS 或 Amazon EKS
- 模型训练:请使用专用的训练栈(例如 AWS Deep Learning Containers、
  Amazon SageMaker Training、或独立的 LLaMA-Factory 环境)
- 长期 7×24 托管:此场景下 Amazon Bedrock 托管模型或 SageMaker Endpoint
  通常更具成本与可用性优势

## 📦 前置

```bash
brew install awscli
brew install --cask session-manager-plugin

aws sts get-caller-identity
aws configure get region
```

账号需具备 "Running On-Demand G and VT instances" vCPU 配额 ≥ 4(`g5.xlarge`)。

## 🚀 使用

### 默认部署:Gemma 4 26B

```bash
./scripts/deploy.sh                        # us-east-1 / g5.xlarge / On-Demand / gemma4:26b
USE_SPOT=true ./scripts/deploy.sh          # 启用 Spot,约 60% 成本
```

### 切换模型

```bash
OLLAMA_MODEL=llama3.1:8b ./scripts/deploy.sh

INSTANCE_TYPE=g6e.xlarge \
OLLAMA_MODEL=llama3.1:70b-instruct-q4_K_M \
ROOT_VOLUME_GB=200 \
./scripts/deploy.sh
```

`OLLAMA_MODEL` 支持 [ollama.com/library](https://ollama.com/library) 的任意 tag。
GPU 选型经验法则:**模型磁盘大小 × 1.1 ≈ VRAM 占用**,再为 KV cache 预留 2 GB。

| 模型体积 | 推荐实例 |
|---|---|
| ≤ 9 GB | `g5.xlarge` / `g6.xlarge`(24 GB) |
| 9–20 GB | `g5.xlarge` / `g6.xlarge`(24 GB);`g5.2xlarge` CPU 更充裕 |
| 20–40 GB | `g6e.xlarge`(L40S 48 GB) |
| 40–70 GB | 选量化版本,或 `g5.12xlarge` / `g6e.12xlarge` 多 GPU(当前模板未适配多卡) |

### 部署后

```bash
./scripts/status.sh                        # 轮询 ollama-ready marker,约 8–12 分钟
./scripts/tunnel.sh                        # 新终端启动 SSM 端口转发
curl http://localhost:11434/api/tags
```

### 客户端调用

```python
# 通用模型走 OpenAI 兼容端点
from openai import OpenAI
client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")
resp = client.chat.completions.create(
    model="gemma4:26b",
    messages=[...],
    temperature=0.8,
)

# 带 thinking mode 的模型合成数据时需显式禁用 reasoning;
# /v1/chat/completions 不透传 think 字段,使用 Ollama 原生 API:
import requests
r = requests.post("http://localhost:11434/api/chat", json={
    "model": "gemma4:26b",
    "messages": [...],
    "think": False,
    "stream": False,
    "options": {"temperature": 0.8, "num_predict": 512},
})
print(r.json()["message"]["content"])
```

### 销毁

```bash
./scripts/destroy.sh                       # EC2 / SG / IAM 清理;S3 bucket 为 Retain,需按需手动删除
```

## 💰 实例与成本参考(`us-east-1`)

| 实例 | GPU | VRAM | On-Demand | Spot | 说明 |
|---|---|---|---|---|---|
| `g5.xlarge`(默认) | NVIDIA A10G | 24 GB | ~$1.0/h | ~$0.35–0.50/h | 7B–26B 量化模型的默认选择 |
| `g5.2xlarge` | NVIDIA A10G | 24 GB | ~$1.2/h | ~$0.40–0.55/h | vCPU 翻倍,数据前处理更从容 |
| `g6.xlarge` | NVIDIA L4 | 24 GB | ~$0.8/h | ~$0.30–0.45/h | 成本更低,decode 吞吐略逊于 A10G |
| `g6e.xlarge` | NVIDIA L40S | 48 GB | ~$1.9/h | ~$0.70–1.00/h | 30B 满精度 / 70B 量化 / FP8 |

## 📊 性能基线

在 `g5.xlarge`(A10G 24 GB)+ Gemma 4 26B(Q4_K_M)+ Ollama 0.23.2,
关闭 thinking mode 的实测数据:

| 指标 | 数值 |
|---|---|
| 模型 VRAM 占用 | 21.2 GB / 24 GB |
| 单流 decode 吞吐 | ~96 tok/s |
| `OLLAMA_NUM_PARALLEL=4` 聚合吞吐 | ~80–120 tok/s |
| 本地 chat(EC2 loopback) | 513 ms |
| Mac 端 chat(经 SSM 隧道) | 940 ms |
| CFN 到 EC2 Running | ~2 分钟 |
| UserData 完成到 ready marker | ~8–10 分钟(含 17 GB 模型下载) |

合成工作负载成本估算(Spot + 平均每条 1.5K 输出 token):

- 1,000 条多轮对话 ≈ 3.5–5 小时 ≈ **$1.5–2.5**
- 10,000 条多轮对话 ≈ 35–50 小时 ≈ **$15–25**

EBS 100 GB gp3 约 $0.008/h,可忽略。

## 🗂️ 文件结构

```
.
├── README.md
├── cloudformation/
│   └── ollama-host.yaml          # 单文件 stack:SG / IAM / Launch Template / UserData / S3
├── docs/
│   └── smoke-test-notes.md       # smoke test 记录与性能数据
└── scripts/
    ├── deploy.sh                 # 创建 / 更新 stack,自动识别 VPC 与 Subnet
    ├── destroy.sh                # 带确认的 delete-stack
    ├── tunnel.sh                 # SSM 端口转发 11434
    ├── ssm-shell.sh              # SSM 交互式 shell
    └── status.sh                 # 轮询 bootstrap 进度 / API / GPU 状态
```

## ⚠️ 注意事项

- **重新部署前需清理 artifact bucket**:`DeletionPolicy: Retain` 保护合成产物,
  同名 stack 再次创建时 EarlyValidation 会拒绝。`destroy.sh` 会打印桶名提示
- **Thinking mode 模型合成数据**:使用 `/api/chat` 并显式传 `think: false`;
  `/v1/chat/completions` 目前不透传该字段
- **Spot 中断**:EBS 卷在 stack 生命周期内保留,模型权重不丢失;客户端脚本
  应自行实现 checkpoint 与断点续跑

---

> 仓库目录名沿用 `gemma-synth-host/`,保留 git 历史的同时,stack、project、
> CloudWatch namespace 等内部命名已通用化为 `ollama-host`。
