# self-host buildkite agent搭建指南

# 背景

buildkite self-host agent基础知识见文档：[buildkite self-host agent基础知识](https://docs.google.com/document/d/1JN_AA-TnhTQSVem9s6ipg9IBwW_gyKxUzyDApz7aLbk/edit?tab=t.0#heading=h.2w6xtdrxm05f)

# 安装

## 2.1 安装self-host buildkite agent

以下以华为云上采购的EulerOS2.0 SP8为例，但OpenEuler也适用。
详细也可以参见官方Guide：[https://buildkite.com/docs/agent/v3/installation](https://buildkite.com/docs/agent/v3/installation)。
``` bash
TOKEN="bkct_xxx.xxxoxxxxxxx" bash -c "`curl -sL https://raw.githubusercontent.com/buildkite/agent/main/install.sh`"
```

其中TOKEN为buildkite Agents->Agent Tokens下创建的属于某一个Cluster的Token。将来这个Agent启动后就会连接到这个Cluster。

## 2.2 配置buildkite-agent配置文件
``` ini
# The name of the agent
name="%hostname-%spawn-2cards"
# The number of agents to spawn in parallel (default is "1")
spawn=4
# Tags for the agent (default is "queue=default")
tags="queue=ascend"
# Flags to pass to the `git clone` command
git-clone-flags="--depth=1"
git-fetch-flags="--depth=1"
```

最后产生的BUILDKITE_AGENT_NAME示例："modelfoundry-prod-node-0008-4-2cards"，其中4为build-agent的idx，从1开始到4。`2cards`这是2卡的Agent。

## 2.3 配置buildkite-agent system deamon service

提示：前期测试与buildkite服务的连通性可以直接用本文[附录1：命令行启动buildkite-agent直接测试](#附录1命令行启动buildkite-agent直接测试)。

### 2.3.1 配置deamon service

新建deamon service定义文件：/usr/lib/systemd/system/buildkite-agent.service，内容如下，其中特别之处如下：
- buildkite相关的路经为build-agent安装路经下的对应的文件或者文件夹  
- PYPI_CACHE_*为PYPI Cache服务的IP和Port  
- Environment=HOME=/root 为buildkite-agent运行用户的主目录，并且要求主目录的.  
- ssh目录下要生产一个ssh 公钥和私钥
   ``` bash
   $ mkdir -p ~/.ssh && cd ~/.ssh
   $ ssh-keygen -t rsa -b 4096 -C "dev+build@myorg.com"
   ```

buildkite-agent.service内容：
``` ini
[Unit]
Description=Buildkite Agent
After=network.target
Wants=network-online.target

[Service]
Environment=HOME=/root
Environment=BUILDKITE_BUILD_PATH=/root/.buildkite-agent/builds
Environment=BUILDKITE_HOOKS_PATH=/root/.buildkite-agent/hooks
Environment=PYPI_CACHE_HOST=# Replace with ip
Environment=PYPI_CACHE_PORT=# Replace with port
# start command
ExecStart=/root/.buildkite-agent/bin/buildkite-agent start --config /root/.buildkite-agent/buildkite-agent.cfg

# restart on failuer
Restart=on-failure
# restart interval
RestartSec=10

StandardOutput=journal
StandardError=journal

# start Timeout
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
```

### 2.3.2 创建和启动服务：
``` bash
sudo systemctl daemon-reload
sudo systemctl enable buildkite-agent
sudo systemctl start buildkite-agent
```

启动服务后可在buildkite网址的工作空间下(Organization)->Agents->ascend queue下看到成功建连Agents  
提示：如果未建连，可通过下面命令查看各级别日志
``` bash
systemctl status buildkite-agent.service
journalctl -u buildkite-agent.service -b
journalctl -u buildkite-agent.service -xe
```


## 2.4 docker buildx环境搭建

### 2.4.1 基础环境连通性配置

找基础设施责任人（赵春江/李超然）配置白名单，白名单list：

- 个人便携访问的3级网段，如：139.159.170.*  
- nigix的pypi cache服务访问白名单IP（为host主机对外访问IP）  
- github代理白名单

1）pypi cache检查方法：curl PYPI cache:

``` bash
如：PYPI_CACHE_HOST为172.22.0.xx，PYPI_CACHE_PORT为3036
curl -L http://172.22.0.xx:3036
```

2）github 代理配置  
如果没有安装github先安装git，之后再配置。
``` bash
git config --global url."https://gh-proxy.test.osinfra.cn/https://github.com/".insteadOf "https://github.com/"
```

检查方法：git clone一个public仓

### 2.4.2 docker环境搭建

#### 2.4.2.1 Docker检查和搭建
检查当前主机Docker版本号，docker 25.x有大变动，建议docker为版本为26+，目前已验证过的docker版本26.1.3和27.5.1。

``` bash
docker --version
Docker version 26.1.3, build b72abbb
```

Docker未安装或者版本不相符需要进行Docker的升级/安装。安装和升级指南见本文[附录2：Docker环境搭建》](#附录2docker环境搭建)

#### 2.4.2.2 Docker buildx检查和搭建

buildx为Docker加速构建插件，目前的构建脚本在使用。  
检查docker buildx插件版本号，命令如下，如果执行失败说明buildx不存在，需要安装。

``` bash 
docker buildx version
```

安装指导见本文[附录3: Docker buildx搭建](#24-docker-buildx环境搭建)

#### 2.4.2.3 docker buildx builder 创建

创建每个Agent需要的buildx builder，之前host上配置的agent数量为4，所以创建4个，命令如下：

``` bash
docker buildx create --name cachebuilder1 --driver docker-container --use
docker buildx create --name cachebuilder2 --driver docker-container --use
docker buildx create --name cachebuilder3 --driver docker-container --use
docker buildx create --name cachebuilder4 --driver docker-container --use
```

### 2.5 提前下载和缓存

测试用例中基础镜像和模型提前下载和缓存，避免每个buildkite-agent第一次构建时时间过长而超时。  
缓存方法为手动执行vllm中构建和运行测试用例的脚本，步骤如下：  
Step 1th: 
   clone vllm代码，如果是私仓见[附录4:私仓调试](#附录4-私仓调试)在有github代理情形下也能clone 私仓代码。  
Step 2nd: 
   安装vllm,源码安装如下，亦可[官方指导](https://vllm-ascend.readthedocs.io/en/latest/installation.html)安装：
   ```bash
   cd vllm
   VLLM_TARGET_DEVICE=empty pip install -v -e .
   ```


Step 3rd: 针对buildkite agent处理缓存  
针对第一个buildkite-agent先进行缓存，在vllm目录下执行，进行第一个Agent的缓存：
``` bash
export BUILDKITE_COMMIT=v
export PYPI_CACHE_HOST=# IP
export PYPI_CACHE_PORT=# Port
export BUILDKITE_AGENT_NAME="modelfoundry-prod-node-0008-1-2cards"
```

同步镜像到其他Agent的缓存目录，目标目录不存在则先创建：(Src) -> (Dest)
``` bash
rsync -av /mnt/docker-cache4/*  /mnt/docker-cache1/
rsync -av /mnt/docker-cache4/*  /mnt/docker-cache2/
rsync -av /mnt/docker-cache4/*  /mnt/docker-cache3/
```

同步模型到其他Agent的缓存目录，目标目录不存在则先创建：(Src) -> (Dest)
``` bash
rsync -av /mnt/modelscope4/*  /mnt/modelscope1/
rsync -av /mnt/modelscope4/*  /mnt/modelscope2/
rsync -av /mnt/modelscope4/*  /mnt/modelscope3/
```

# 附录1：命令行启动buildkite-agent直接测试

其中：PYPI_CACHE_HOST=，PYPI_CACHE_PORT=，为niginx pypi 缓存的host ip和端口，命令如下：
``` bash
PYPI_CACHE_HOST=172.22.0.80  PYPI_CACHE_PORT=30367 ~/.buildkite-agent/bin/buildkite-agent start --spawn 4
```

# 附录2：Docker环境搭建

## 1.Docker build cache高速NVMe Cache挂载搭建

查看Host的NVMe盘是否挂载到目录，如/mnt目录。
``` bash
df -h
```

输出如下：
``` bash
文件系统        容量  已用  可用 已用% 挂载点
/dev/sda2       147G  9.7G  131G    7% /
/dev/nvme1n1    7.0T  1.9T  4.8T   28% /mnt
```

**如果有挂载则跳过本步骤**，没有挂载到目录，则需要进行接下来的nvme盘分区的初始化和盘挂载到目录

1) nvme 分区初始化

blkid命令查看nvme磁盘列表：  
输出如下：

``` bash
$ blkid
/dev/nvme0n1: UUID="85805e4a-f02a-45a8-bd72-d090fde75dd3" BLOCK_SIZE="512" TYPE="xfs"
/dev/nvme1n1: UUID="600d2860-2279-4366-9903-aae4525139d0" BLOCK_SIZE="4096" TYPE="ext4"
```

fdisk检查nvme盘的是否有分区，如下，没有分区，但nvme盘的大小为7T，只挂载一个就可以了。
``` bash
$ fdisk -l /dev/nvme0n1
Disk /dev/nvme0n1：6.99 TiB，7681501126656 字节，15002931888 个扇区
磁盘型号：RP2017T6RK004MX
单元：扇区 / 1 * 512 = 512 字节
扇区大小(逻辑/物理)：512 字节 / 512 字节
I/O 大小(最小/最佳)：512 字节 / 512 字节
```

先初始化为etx4的文件系统：
``` bash
mkfs.ext4 /dev/nvme0n1
```

2) 挂载到目录

把这个nvme盘进行挂载到/mnt,然后把挂载信息写到/etc/fstab，写入后使用mount命令验证是否正常执行。  
以上面的分区0为例，内容如下，其中UUID为blkid得到的对应分区的UUID：
```
UUID=85805e4a-f02a-45a8-bd72-d090fde75dd3 /mnt                       ext4    defaults        0 0
```

写入后使用mount命令验证是否正常执行，mount输出如下：
```
/dev/nvme1n1 on /mnt type ext4 (rw,relatime)
```

## 2.Docker环境搭建

### 2.1 Docker 安装

1) 如果已经安装的Docker是26之下的先进行卸载，否则不需要执行本步骤。  
2) 以下是EulerOS2.0/OpenEuler上的安装方式，Ubuntu和其他流行发行版的安装方式不需要使用下面的安装方式。  
   安装指导见：[https://docs.docker.com/engine/install/binaries/\#install-daemon-and-client-binaries-on-linux](https://docs.docker.com/engine/install/binaries/#install-daemon-and-client-binaries-on-linux)

### 2.2 Docker服务deamon service配置

在目录/usr/lib/systemd/system/新建以下文件，内容可以从其他相同OS已经搭建号的目录下拷贝，或者直接在网上搜。
``` bash
-rw-r--r--  1 root root 1264  5月 23  2024 containerd.service
-rw-r--r--  1 root root 1709  5月 16  2024 docker.service
-rw-r--r--  1 root root  295  5月 16  2024 docker.socket 
```

### 2.3 配置高速docker build work目录

编辑或创建 /etc/docker/daemon.json（如果不存在就创建）
``` bash
sudo mkdir -p /etc/docker
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "data-root": "/mnt/docker-data/docker"
}
EOF
```

重启动docker服务：
``` bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```

# 附录3: Docker buildx插件搭建

docker版本和buildx的版本需要有配套关系，配套关系和最佳配套可以从docker的版本记录中查询。目前验证过的配套版本如下：  
（Docker）27.5.1：(buildx) v0.20.0  
（Docker）26.1.3：(buildx) v0.13.1  
buildx下载地址，按照对应CPU架构下载：  
[https://github.com/docker/buildx/releases?page=3](https://github.com/docker/buildx/releases?page=3)  
将buildx安装在对应目录，目录及buildx安装文件名如下：

``` bash
$ ll $HOME/.docker/cli-plugins/
-rwx------ 1 root root 63373464  9月 25 15:40 docker-buildx
```

# 附录4: 私仓调试

对于github代理需要访问个人私仓时，需要添加Token头给git请求。  
其中Token来自，个人github TOKEN的来源：  
https://github.com/settings/personal-access-tokens

``` bash
TOKEN=`echo -n "x-access-token:ghp_xxxxxxxxxxxxxxx" | base64`
git config --global http.https://gh-proxy.test.osinfra.cn/.extraheader "AUTHORIZATION: basic $TOKEN"
```

