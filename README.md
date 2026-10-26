# yjson_macros

`yjson_macros` 为 yjson 生成 JSON codec，并提供 JSON 字面量宏。
它是独立的仓颉 `macro package`，需要与普通运行时包分开编译。
当前候选版本为 **0.2.0**，使用 **Cangjie STS 1.2.0**。

公开入口包括：

- `@JsonCodec`：为 class、struct 和 enum 生成 codec。
- `@Json({...})`：在编译时检查 JSON 字面量，生成可修改的 `JsonNode` 树。
- `@JsonUsing[codecExpression]`：为字段选择自定义 codec。
- `@JsonSubtype[wireName, ConcreteType]`：为多态基类登记判别值和具体子类型。

`@Json` 支持对象、数组、双引号字符串、布尔值、`null` 和 JSON 数字。
使用 `$()` 插入运行时值和动态字符串键。插值从左到右各求值一次；
动态键重复时保留最后一个成员。对象成员必须有逗号，允许尾逗号。

## 依赖与升级

应用需要同时声明配套的 yjson 运行时和宏包，并导入 `yjson.*` 与 `yjson_macros.*`。
当前生成代码使用 `generated-support v1`，运行时仍会检查协议版本。

0.x 阶段不承诺跨版本源码、ABI、生成代码或旧 SDK 兼容。
升级时同步第一方依赖，重新生成并编译消费方。
从 0.1.x 升级到 0.2.0 时，把 `@JsonValue(...)` 改为 `@Json(...)`；
旧宏已删除。用户自定义的 `JsonValue` 类型按普通模型处理，可以使用自己的生成 codec。

## 验证消费方

先启用 STS 1.2.0，再为测试设置位于磁盘文件系统上的临时目录。
以下命令检查你显式选择的运行时源码，不会下载或退回历史版本：

```sh
cjc -v
cjpm --version
ulimit -s 131072
python3 tests/run_characterization.py --runtime ../yjson --output-dir "$TMPDIR/macro-acceptance"
```

`--output-dir` 必须尚不存在。成功时输出 `PASS`，目录内保留源码副本、文件清单、
日志、完整文档消费方和 `report.json`。脚本默认在隔离 manifest 中使用 `-O2`。
`--consumer-only` 跳过运行时自身测试，只证明独立消费方、删除宏诊断和文档示例。

`--runtime-sha256` 可固定选定运行时的 `yjson.package-source/1` 摘要。
该摘要绑定 `cjpm.toml`、存在的 `cjpm.lock` 和 `build.cj`，以及全部 `src/**/*.cj`。
完整文件清单和每个文件的 SHA-256 写入 `report.json`，复制前后会检查内容一致。

四个宏的完整示例上下文见[文档消费方示例](tests/doc_examples/README.md)。
