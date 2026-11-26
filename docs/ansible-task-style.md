# Ansible 任务书写规范

适用于 `k8s-cluster-deployer` 仓库里所有 role 与 playbook。目的：让每个任务的写法一致，第二次执行 `changed=0`，`--check` 与 `--tags` 都能正常工作。其他 AI 或同事写任务时按本文执行，提交前对照第 12 节自检。

---

## 1. 文件组织

- 每个 role 的 `tasks/main.yml` 只做 `import_tasks`，具体任务放在按用途命名的文件里：`install.yml`（流程）、`verify.yml`（只读验证）。
- 一个文件只做一件事，文件顶部第一行 `---`，紧接一行注释说明"阶段、手册章节、在哪些主机上执行"。
- 文件里每个任务都放在一个 `block` 下（第 4 节），不要出现顶层的零散任务。
- 模板放 `templates/`，一次性脚本放 `files/`，role 内部变量默认值放 `defaults/main.yml`，不放 `vars/`（除非不希望被覆盖）。

## 2. 任务头：命名、键顺序、引号

**命名**

- 任务名用英文祈使句，首字母大写，以动词开头（`Create`、`Render`、`Wait for`、`Verify`）。
- 任务名里的 Jinja 变量放在末尾（`Verify images point at {{ registry }}`），不要放在开头或中间。
- 手册章节写在任务**上方**的注释里（`# 手册 6.4：……`），不写在行尾，也不拼进任务名。
- 注释用中文，说明"为什么这么做"，不要复述任务名。

**键的固定顺序**

```
name
when
vars
<module>（连同它的参数）
loop / loop_control
register
until / retries / delay
changed_when
failed_when
check_mode
no_log
notify
tags          # 只在 block 上写，个别任务例外见第 3 节
```

**引号与格式**

- 任务名、普通字符串不加引号；含 `{{`、冒号开头、或 `*`、`&` 等特殊字符时才加双引号。
- `mode` 永远写成带双引号的字符串（`"0644"`），否则 YAML 会当成数字。
- 布尔值只用 `true` / `false`。
- 缩进 2 空格；列表在键下面缩进两格；一行不超过 160 字符，长命令用 `>-` 折行。
- 全部使用 FQCN（`ansible.builtin.copy`）。

## 3. 标签

- 标签只写在 `block` 上，任务里不再重复。
- 标签分三类：
  - **阶段标签**：`os`、`ha`、`runtime`、`kubeadm`、`cni`、`lb`、`gateway`；
  - **验证标签**：`verify`，只用于只读的检查任务，放在独立的 `verify.yml` 里，不与流程任务混在同一个 `block`；
  - **危险标签**：`never`，用于默认不执行的任务（内核固定、重置、漂移演练、外网探测）。
- **流程里的"等待"任务（如等 Pod Ready）属于流程，只打阶段标签，不打 `verify`**，否则 `--skip-tags verify` 会跳过它们，后面的步骤接着失败。
- 想要"无论加什么 `--tags` 都必须执行"的守卫任务，才用 `always`，并且要克制。
- `include_role` 的标签不会传给被包含的任务，需要继承标签时用 `import_role`，或写 `apply: { tags: [...] }`。优先 `import_role`。

## 4. block 模板

每个流程文件都用下面的外壳。它统一设置标签、`KUBECONFIG`、shell 解释器，任务里不再逐个写：

```yaml
---
# 阶段 60：Calico（手册第 6 章），只在 first_master 上执行
- name: Install Calico
  tags: [cni]
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  module_defaults:
    ansible.builtin.shell:
      executable: /bin/bash
  block:
    - name: ...
```

- 需要 `kubectl` / `helm` 的 block 都设置 `KUBECONFIG`，不依赖 `~/.kube/config`。
- 只在 master01 执行的阶段，用 playbook 的 `hosts: first_master` 控制，不在任务里写 `assert inventory_hostname == …`。

## 5. command 与 shell

1. **能用模块就不用命令**：文件、包、服务、模板、下载、sysctl 都用对应模块。只有 `kubeadm`、`kubectl`、`helm`、`nerdctl`、`containerd` 这类才用命令。
2. **统一用 `command` + `cmd:`**，需要管道、重定向、`&&` 才用 `shell`，同样写 `cmd:`。
3. **多行脚本用 `|`**（保留换行），单条命令折行才用 `>-`。多行脚本第一行写 `set -euo pipefail`。
4. **带管道的 shell 必须有 `set -o pipefail`**，解释器由 block 的 `module_defaults` 提供（`/bin/bash`）。
5. **每个命令任务都必须显式写 `changed_when`**：
   - 只读命令（`get`、`list`、`wait`、`version`、`template`）写 `changed_when: false`；
   - 会修改系统的命令，要么写能判断"是否真的改了"的条件，要么用 `creates` / `removes` / `when` 保护。
6. **只读命令必须加 `check_mode: false`**：`command` / `shell` 在 `--check` 下默认被整体跳过，不加的话预演时验证类任务全部不运行。
7. **会修改系统的命令不加 `check_mode: false`**，让它在 `--check` 下被跳过。
8. 命令的输出不要用 `debug` 逐行打印后就算验证了；验证要用 `assert`，或用 `failed_when` 让任务失败。

## 6. 幂等判断：常用操作的固定写法

| 操作 | 判断"是否改变"的写法 |
| --- | --- |
| 文件、包、服务、sysctl、模板 | 使用对应模块，模块自己判断 |
| `kubeadm init` / `join` | `creates: /etc/kubernetes/admin.conf` / `kubelet.conf` |
| `kubectl apply`（客户端） | 输出里出现 `created` 或 `configured` |
| `kubectl apply --server-side` | **输出永远是 `serverside-applied`，不能靠输出判断**。先 `kubectl diff --server-side`，返回码 1 表示有差异，再 `apply` |
| `helm upgrade --install` | **每次都会产生新 revision，输出永远含 `deployed`，不能靠输出判断**。先用 `helm list -o json` 比较 chart 版本，用 `helm get values -o json` 与渲染后的 values 比较，不一致才执行 |
| `kubectl create ns … --dry-run=client -o yaml \| kubectl apply -f -` | 输出里出现 `created` |
| `kubectl wait` / `get` / `rollout status` | `changed_when: false` |
| 下载并校验文件 | 统一用公共的"获取并校验"任务，不在各 role 里重写 |

## 7. 等待与重试

需要等集群状态收敛的任务，用 `until` + `retries` + `delay`，不要写 `pause` 或 `sleep`：

- 超时时间写成 `retries × delay`，注释里写明大约是多少分钟；
- `until` 的条件里要先判断"有结果"，再判断"结果正确"（刚创建的资源可能还不存在，`wait` 会直接报"没有匹配的资源"）；
- 对象名、条件名、命名空间必须与实际一致：`tigerastatus`（不是 `tigerstatus`），条件 `Available`，Calico 的 Pod 在 `calico-system`。

## 8. 变量、密钥、handler

**变量**

- role 自己定义的变量加 role 前缀（`calico_xxx`、`haproxy_xxx`）；`register` 的变量也一样，命名为 `<role>_<含义>`。
- role 里不出现任何集群专属的值，全部来自 `group_vars`、`host_vars`、`config/versions.yml`。
- 默认值写在 `defaults/main.yml`；必填项不给默认值，由预检阶段统一断言。

**密钥**

- token、certificate-key、密码、私钥所在的任务写 `no_log: true`；`register` 保存了这类输出时，使用它的后续任务也要 `no_log: true`。
- 临时落盘的密钥文件只写 `/dev/shm`，权限 `"0600"`，放在 `block` 的 `always` 里删除。

**handler**

- 任务里不直接重启服务，只写 `notify`；重启逻辑集中在 handler。
- handler 名统一为 `Restart <服务>` / `Reload <服务>`；多个任务触发同一动作时用 `listen`。
- 需要在 handler 执行前就生效的场景，用 `ansible.builtin.meta: flush_handlers` 明确写出来。

**断言**

- `assert` 必须写 `fail_msg`（说明哪台、哪个变量、期望什么），建议加 `quiet: true`。

## 9. YAML 与 lint 配置

仓库根目录放两个配置文件，CI 与本地都运行 `ansible-lint`、`yamllint`。

`.ansible-lint`：

```yaml
profile: production
exclude_paths:
  - collections/
  - artifacts/
```

`.yamllint`：

```yaml
extends: default
rules:
  line-length:
    max: 160
  truthy:
    allowed-values: ["true", "false"]
  comments:
    min-spaces-from-content: 2
  indentation:
    indent-sequences: true
```

## 10. 反例与正例对照（来自 Calico 阶段任务）

| 问题 | 反例 | 正例 |
| --- | --- | --- |
| 标签不统一 | 个别任务没有 `tags`，其余各写 `tags: [cni]` | 只在 `block` 上写一次 |
| `include_role` 丢标签 | `include_role` + `tags: [cni]` | `import_role`，或 `apply: { tags: [...] }`。优先 `import_role` |
| 等待任务打 `verify` | `tags: [cni, verify]` | 只打 `cni`；纯展示任务放进独立的 `verify` block |
| shell / command 写法混用 | `shell: >-` + `args: executable` | `cmd:`，解释器由 `module_defaults` 设置 |
| 管道没有 pipefail | `helm template … \| kubectl apply …` | 多行 `\|` 脚本，第一行 `set -euo pipefail` |
| 只读命令不加 `check_mode: false` | `--check` 时全部被跳过 | 只读命令加 `check_mode: false` |
| 多余的 `failed_when` | `failed_when: x.rc != 0` | 删除（`command` 默认就是） |
| 靠输出判断 SSA 是否改变 | `changed_when: "'created' in stdout"` | `kubectl diff --server-side` 返回码判断 |
| `helm upgrade` 每次都 changed | `changed_when: "'deployed' in stdout"` | 先比较 chart 与 values，再决定是否执行 |
| 资源名与条件名写错 | `tigerstatus/default`，condition=Ready | `tigerastatus --all`，condition=Available |
| 命名空间写错 | `-n kube-system -l k8s-app=calico-node` | `-n calico-system` |
| 重复打印 | 一个任务取状态，一个任务 `debug` 打印 | `register` 后 `debug: var=` 一个任务即可 |
| 守卫写成任务 | 每个 role 里 `assert inventory_hostname == …` | playbook 里 `hosts: first_master` |

## 11. 完整示例（Calico 阶段，按本规范改写）

`roles/calico/tasks/main.yml`：

```yaml
---
- name: Import the install tasks
  ansible.builtin.import_tasks: install.yml

- name: Import the verify tasks
  ansible.builtin.import_tasks: verify.yml
```

`roles/calico/tasks/install.yml`：

```yaml
---
# 阶段 60：Calico（版本见 config/versions.yml；手册第 6 章），只在 first_master 上执行
- name: Install Calico
  tags: [cni]
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  module_defaults:
    ansible.builtin.shell:
      executable: /bin/bash
  block:
    # 手册 6.2：获取两个 Chart（获取即校验）
    - name: Fetch the Calico charts
      ansible.builtin.import_role:
        name: artifact
      vars:
        artifact_files:
          - "tigera-operator-v{{ calico_version }}.tgz"
          - "crd.projectcalico.org.v1-v{{ calico_version }}.tgz"

    # 手册 6.4：安装前预检，calico/node 镜像内的 nft 必须可用（3.32.0 曾在此崩溃）
    - name: Run the nft preflight
      ansible.builtin.command:
        cmd: >-
          nerdctl -n k8s.io run --rm --privileged --net=host --entrypoint nft
          {{ registry }}/calico/node:v{{ calico_version }} list tables
      changed_when: false
      check_mode: false

    # 手册 6.3：CRD 必须 server-side apply；先渲染到文件，再比较差异
    - name: Render the CRD chart
      ansible.builtin.shell:
        cmd: |
          set -euo pipefail
          helm template calico-crds {{ package_dir }}/charts/crd.projectcalico.org.v1-v{{ calico_version }}.tgz \
            > {{ package_dir }}/charts/calico-crds.yaml
      changed_when: false
      check_mode: false

    - name: Diff the CRDs against the cluster
      ansible.builtin.command:
        cmd: kubectl diff --server-side -f {{ package_dir }}/charts/calico-crds.yaml
      register: calico_crd_diff
      changed_when: calico_crd_diff.rc == 1
      failed_when: calico_crd_diff.rc not in [0, 1]
      check_mode: false

    - name: Apply the CRDs server-side
      ansible.builtin.command:
        cmd: kubectl apply --server-side --force-conflicts -f {{ package_dir }}/charts/calico-crds.yaml
      when: calico_crd_diff.rc == 1
      changed_when: true

    - name: Create the tigera-operator namespace
      ansible.builtin.shell:
        cmd: |
          set -euo pipefail
          kubectl create namespace tigera-operator --dry-run=client -o yaml | kubectl apply -f -
      register: calico_namespace
      changed_when: "'created' in calico_namespace.stdout"

    # 手册 6.4：渲染 values，并核对渲染出的镜像都来自 Harbor
    - name: Render calico-values.yaml
      ansible.builtin.template:
        src: calico-values.yaml.j2
        dest: "{{ package_dir }}/charts/calico-values.yaml"
        mode: "0644"

    - name: Verify the rendered images point at {{ registry }}
      ansible.builtin.shell:
        cmd: |
          set -euo pipefail
          helm template calico {{ package_dir }}/charts/tigera-operator-v{{ calico_version }}.tgz \
            -n tigera-operator -f {{ package_dir }}/charts/calico-values.yaml | grep -E 'image:' | sort -u
      register: calico_images
      changed_when: false
      failed_when: >-
        calico_images.stdout_lines | length == 0
        or (calico_images.stdout_lines | reject('search', registry | regex_escape) | list | length) > 0
      check_mode: false

    # 手册 6.5：helm upgrade 每次都会产生新 revision，先比较 chart 与 values 再决定是否执行
    - name: Read the current Calico release
      ansible.builtin.command:
        cmd: helm list -n tigera-operator --filter '^calico$' -o json
      register: calico_release
      changed_when: false
      check_mode: false

    - name: Read the current Calico release values
      ansible.builtin.command:
        cmd: helm get values calico -n tigera-operator -o json
      register: calico_release_values
      changed_when: false
      failed_when: false
      check_mode: false

    - name: Install or upgrade the Calico operator
      ansible.builtin.command:
        cmd: >-
          helm upgrade --install calico {{ package_dir }}/charts/tigera-operator-v{{ calico_version }}.tgz
          -n tigera-operator -f {{ package_dir }}/charts/calico-values.yaml
      when: >-
        (calico_release.stdout | from_json | length) == 0
        or (calico_release.stdout | first).chart != 'tigera-operator-v' ~ calico_version
        or (calico_release_values.stdout | from_json) != (lookup('ansible.builtin.template', 'calico-values.yaml.j2') | from_yaml)
      changed_when: true

    - name: Wait for the tigera-operator deployment
      ansible.builtin.command:
        cmd: kubectl -n tigera-operator rollout status deployment/tigera-operator --timeout=5m
      changed_when: false
      check_mode: false

    # 约 10 分钟：60 次 × 10 秒。TigeraStatus 对象刚创建时可能还不存在，所以先要求有结果
    - name: Wait for every TigeraStatus to be Available
      ansible.builtin.command:
        cmd: >-
          kubectl get tigerastatus -o
          jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Available")].status}{"\n"}{end}'
      register: calico_tigerastatus
      until: >-
        calico_tigerastatus.stdout_lines | length > 0
        and (calico_tigerastatus.stdout_lines | reject('search', '=True$') | list | length) == 0
      retries: 60
      delay: 10
      changed_when: false
      check_mode: false

    - name: Wait for every node to be Ready
      ansible.builtin.command:
        cmd: kubectl wait --for=condition=Ready nodes --all --timeout=10m
      changed_when: false
      check_mode: false
```

`roles/calico/tasks/verify.yml`（只读，单独的 block，只带 `verify` 标签）：

```yaml
---
# 阶段 60 验证：只读
- name: Verify Calico
  tags: [verify]
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  block:
    - name: Get the calico-node pods
      ansible.builtin.command:
        cmd: kubectl -n calico-system get pods -l k8s-app=calico-node -o wide
      register: calico_pods
      changed_when: false
      check_mode: false

    - name: Show the calico-node pods
      ansible.builtin.debug:
        var: calico_pods.stdout_lines
```

> 示例中 `kubectl diff --server-side` 与 helm values 比较两种写法，需要在测试机上确认行为（CRD 体积大、`helm get values` 在无自定义 values 时返回 `null`）后再固化。`lookup` 在控制机上执行，所以 values 的比较用 `lookup('ansible.builtin.template', …)` 渲染模板，而不是读目标机上的文件。

## 12. 提交前自检清单

- [ ] 文件顶部有 `---` 和一行说明注释；任务都在 `block` 里。
- [ ] 标签只写在 `block` 上；等待类任务没有 `verify`；验证任务在独立的 block。
- [ ] 任务名英文、动词开头、首字母大写，Jinja 在末尾；手册章节在上方注释里。
- [ ] 键的顺序符合第 2 节；`mode` 是带引号的字符串；布尔值是 `true` / `false`。
- [ ] 全部使用 FQCN；能用模块的没有用命令。
- [ ] 每个 `command` / `shell` 都有明确的 `changed_when`；只读的有 `check_mode: false`。
- [ ] 带管道的 shell 有 `set -o pipefail`；多行脚本用 `|`。
- [ ] `kubectl apply --server-side` 与 `helm upgrade` 没有靠输出判断是否改变。
- [ ] 等待任务用 `until`，没有 `pause`、`sleep`；对象名、条件名、命名空间与实际一致。
- [ ] 变量带 role 前缀；没有硬编码的集群值；敏感任务有 `no_log: true`。
- [ ] 重启服务只通过 handler。
- [ ] `ansible-lint` 与 `yamllint` 无告警；第二次执行 `changed=0`；`--check --diff` 不报错。
