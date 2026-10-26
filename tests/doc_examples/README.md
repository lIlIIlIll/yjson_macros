# 运行宏 API 文档示例

四个宏的 `@example` 正文来自源码注释。本目录提供编译这些函数体片段所需的
导入和顶层模型，避免把消费者代码放进宏包编译。

[profile.json](profile.json) 按声明的限定名绑定消费方配置；
[prelude.cj](prelude.cj) 定义带宏标注的 `DocRecord`、`DocCustomCodec`、`DocAnimal` 和 `DocDog`。
消费方导入 `std.collection.*`、`yjson.*` 和 `yjson_macros.*`。
`@JsonUsing` 与 `@JsonSubtype` 的实际调用位于前置模型中。

在 STS 1.2.0 环境中，从宏仓库根目录运行：

```sh
ulimit -s 131072
python3 tests/run_characterization.py --runtime ../yjson --consumer-only --output-dir "$TMPDIR/macro-doc-examples"
```

`--runtime` 指向待验证运行时的本地源码目录，`--output-dir` 必须尚不存在。
请先把 `TMPDIR`、`TMP` 和 `TEMP` 设置为磁盘上的专用临时目录。
脚本冻结运行时与宏源码，编译 11 个消费方测试（包含可变 struct 的多读取路径回归）和删除旧宏的失败用例，
随后编译并运行四个文档示例，逐一比较注释中的 `output` 块。

成功输出 `PASS`。产物目录中每个 `example-<宏名>/src/main.cj` 都是完整消费方，
可以与对应 manifest 一起下载查看。`report.json` 关联限定名、完整代码摘要和执行日志。
本脚本从源码注释提取示例，用于本仓库开发验证；发布站点另从 cjdoc Doc IR 提取相同正文，
结合本 profile 验证。两条路径的正文应一致，不能用常规宏包编译代替外部消费方验证。
