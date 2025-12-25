# ydyl-scripts-lib

该目录用于沉淀可复用的脚本库（后续可独立为单独 repo 供其它仓库引用）。

## `deploy_common.sh`

提供通用的 Kurtosis 部署骨架函数：`ydyl_kurtosis_deploy`（方案B：使用 `DEPLOY_*` 环境变量，避免长参数列表）。

### 命名规范（全量使用 `-`）

- `DEPLOY_NETWORK` 统一使用连字符风格：`eth`、`cfx-dev`、`cfx-test`、`gen` ...
- 部署 enclave 名由公共库推导：

```bash
ENCLAVE_NAME="${DEPLOY_L2_TYPE}-${DEPLOY_NETWORK}"
```

### 必需环境变量

- `DEPLOY_L2_TYPE`: `cdk` 或 `op`
- `DEPLOY_NETWORK`: `eth/cfx-dev/cfx-test/gen ...`
- `DEPLOY_TEMPLATE_FILE`: 模板路径
- `DEPLOY_RENDERED_ARGS_FILE`: 渲染后的 args 文件路径
- `DEPLOY_LOG_FILE`: 日志文件路径
- `DEPLOY_PACKAGE_LOCATOR`: Kurtosis package locator

### 可选环境变量

- `DEPLOY_UPDATE_NGINX_SCRIPT`: nginx 更新脚本路径（必填）
- `DEPLOY_DRYRUN`: `true/false`（默认 `false`）
- `DEPLOY_FORCE`: `true/false`（默认 `false`）

### 输出变量（export）

- `YDYL_DEPLOY_ENCLAVE_NAME`
- `YDYL_DEPLOY_STATUS`: `dryrun/ran/skipped`

### 用法示例

```bash
export DEPLOY_L2_TYPE=cdk
export DEPLOY_NETWORK=eth
export DEPLOY_TEMPLATE_FILE=/path/to/params.template.yml
export DEPLOY_RENDERED_ARGS_FILE=/path/to/params-eth.yml
export DEPLOY_LOG_FILE=/path/to/deploy-eth.log
export DEPLOY_PACKAGE_LOCATOR=github.com/Pana/kurtosis-cdk@<commit>
export DEPLOY_UPDATE_NGINX_SCRIPT=/path/to/update_nginx_ports.sh

source /path/to/ydyl-scripts-lib/deploy_common.sh
ydyl_kurtosis_deploy
```


