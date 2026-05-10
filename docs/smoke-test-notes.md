# Smoke test notes

两次 end-to-end smoke test(2026-05-10,us-east-1 g5.xlarge On-Demand)。
记录踩过的坑和固化的修复,便于下次部署时不再重复。

## 验证通过的能力

- CloudFormation 单文件 stack 自动起 g5.xlarge,默认 VPC + 自动子网
- DLAMI Base GPU (Ubuntu 22.04) 预装驱动,A10G 即开即用
- UserData 自动装 Ollama、systemd 隔离(`OLLAMA_HOST=127.0.0.1`)
- `gemma4:26b` (Q4_K_M, 17GB) 完整下载,digest `5571076f3d70...` 与 Mac 本地一致
- 模型载入 21.2 GB VRAM / 24 GB,利用率 72%
- SSM 端口转发 Mac ↔ EC2:11434 正常,端到端 chat 约 0.9–1.0 秒
- A10G 单流 decode ~96 tok/s(关 thinking 模式后)

## 踩过的坑及固化修复

### 1. SSM AMI 参数名有版本差异

用 `/aws/service/deeplearning/ami/x86_64/oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id`
会返回 null。正确路径要带 `base-` 前缀:

```
/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id
```

已固化到模板默认参数。

### 2. `ollama pull` 在 root 上下文崩溃

`panic: $HOME is not defined` — Ollama CLI 硬性读 `$HOME/.ollama`。解决:切到
`ollama` 服务用户并带 `-H` 重置环境。

```bash
sudo -u ollama -H ollama pull "$MODEL"
```

已固化到 UserData。

### 3. `ollama pull` 客户端在非 TTY 环境下 verify 阶段不退出

**这是最诡异的一个**。现象:

- Ollama 0.23.2,stdout 被 `tee` 截获(cloud-init 环境典型)
- 17GB blob 完整下载、SHA256 磁盘上正确
- 客户端 `epoll_pwait` 循环,`futex_wait` 阻塞,收不到 server 的 "done" 信号
- Manifest 一直没注册 → `/api/tags` 看不到模型

第一次 pull 卡住 → shell 的 retry fallback 触发 → 第二次 pull 识别 blob 存在
后秒完成注册。但原 UserData 的 `pull || (sleep 10; pull)` 本意是"失败重试",第一次
并没有失败,只是卡住,导致 retry 永远不触发。

修复:**第一次 pull 加 900s timeout + `|| true` 吞掉 exit code,第二次 pull 无条件
再跑一次触发注册**。如果 blob 齐全,第二次数秒完成。再加一个 `grep /api/tags` 校验
后写 ready marker。

```bash
timeout --preserve-status 900 sudo -u ollama -H ollama pull "$MODEL" || true
for attempt in 1 2 3; do
  sudo -u ollama -H ollama pull "$MODEL" && break
  sleep 10
done
curl -fs http://127.0.0.1:11434/api/tags | grep -q "\"$MODEL\"" \
  && touch /var/lib/cloud/instance/ollama-ready
```

已固化到 UserData。未验证固化版本,下次真正部署时验证。

### 4. Gemma 4 默认开启 thinking mode

默认 `/v1/chat/completions` 或 `/api/chat` 请求会进 reasoning 分支,输出全部吐到
`message.reasoning` 字段,`content` 可能为空,首 token 延迟飙到数十秒。

合成必须传 `"think": false`,**仅支持 Ollama 原生 `/api/chat`**,OpenAI 兼容端点
(`/v1/chat/completions`)目前不透传这个参数。

已在 README 说明、warm-up 脚本、以及未来合成脚本都应遵守。

### 5. CloudFormation EarlyValidation 对 Retain 资源敏感

`ArtifactBucket` 设 `DeletionPolicy: Retain` 的初衷是保护合成结果。但这导致:

- 删 stack 时 bucket 不删
- 下次部署同名 stack 时,EarlyValidation hook 报"已存在"拒绝 change set
- 只能手动 `aws s3 rb` 删桶再部署

**当前取舍**:保留 Retain(保护数据),接受"重建前手动清空桶"的流程;`destroy.sh`
已经在提示里写清楚。将来如果真要全自动,两个选项:

- 改成 `DeletionPolicy: Delete`(简单但丢数据)
- bucket 名里加 stack creation 时间戳 suffix(每次 stack 独立 bucket)

暂不改,下次 pain point 够明显再说。

### 6. SSM RunShellScript 默认是 dash 不是 bash

documents 里直接写 `(subshell)` 会 `Syntax error: "(" unexpected`。要 bash 语法就
套 `bash -c "..."`。这个只影响运维 Run Command,不影响 UserData(UserData 有
`#!/bin/bash` 头)。记录下来避免以后遇到再查。

## 性能参考

A10G 24GB + gemma4:26b (Q4_K_M) + Ollama 0.23.2,实测:

| 场景 | 耗时 |
|---|---|
| 本机 chat(关 thinking,6 输出 token) | 513 ms(含 398 ms 调度) |
| 本机 decode 速度 | ~96 tok/s |
| Mac 经 SSM 隧道 chat | 940 ms |
| 模型 VRAM 占用 | 21.2 GB / 24 GB |
| CFN stack 创建到 EC2 Running | ~2 min |
| UserData 完整 bootstrap(到 ready marker) | ~8–10 min(包含 17GB 下载) |

## 成本数据

两次 smoke test,g5.xlarge On-Demand,总计约 90 分钟:**约 $1.50**。
